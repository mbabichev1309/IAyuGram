import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SGSimpleSettings

// Response of the companion server's REST /gap-sync (server models.py GapSyncResponse).
private struct IAyuGapSyncResponse: Codable {
    let events: [IAyuMessageEvent]
    let latestCursor: Int

    enum CodingKeys: String, CodingKey {
        case events
        case latestCursor = "latest_cursor"
    }
}

private let iAyuGapSyncPageLimit = 500

// Phase 2b step 5: the always-on sync engine. Instantiated once per authorized
// account at app launch (from AuthorizedApplicationContext), independent of the
// settings screen. It opens the /live WebSocket for real-time events and runs REST
// /gap-sync from the last persisted cursor to catch up on anything missed while the
// app was closed, materializing each event into Postbox. The cursor is persisted so
// we never re-scan already-applied events.
public final class IAyuSyncManager {
    private let context: AccountContext
    private var liveSession: IAyuLiveSession?
    private var active = true
    // Cursors seen this session, so an event that arrives on both /live and the
    // gap-sync backfill isn't processed twice, and so the persisted cursor can be
    // advanced only along a contiguous prefix (no gaps → no missed events on crash).
    private var processedCursors = Set<Int>()

    public init(context: AccountContext) {
        self.context = context
        self.start()
    }

    deinit {
        self.active = false
        self.liveSession?.stop()
    }

    private func start() {
        let serverURL = SGSimpleSettings.shared.iaSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = SGSimpleSettings.shared.iaSyncClientToken
        guard !serverURL.isEmpty, !token.isEmpty else {
            // Companion server not configured — nothing to sync.
            return
        }
        // Connect live first so events firing during the gap-sync fetch aren't lost;
        // the cursor dedup below drops any that both paths deliver.
        self.liveSession = IAyuLiveSession(serverURL: serverURL, token: token, onEvent: { [weak self] event in
            self?.handle(event)
        }, onStatus: { _ in })
        self.gapSync(serverURL: serverURL, token: token, since: Int(SGSimpleSettings.shared.iaSyncCursor))
    }

    private func handle(_ event: IAyuMessageEvent) {
        Queue.mainQueue().async {
            guard self.active else { return }
            if self.processedCursors.contains(event.cursor) {
                return
            }
            self.processedCursors.insert(event.cursor)
            if event.kind == "deleted" {
                // Persistent dedup by peerId+messageId: gap-sync can re-deliver an
                // already-applied delete across launches (when the cursor lags a
                // gap), and this stops it from inserting a second placeholder.
                let peerId = iAyuPeerId(fromServerChatId: event.chatId).toInt64()
                if !IAyuMaterializedDeletesStore.shared.contains(peerId: peerId, messageId: event.messageId) {
                    IAyuMaterializedDeletesStore.shared.insert(peerId: peerId, messageId: event.messageId)
                    iAyuMaterializeDeleted(context: self.context, event: event)
                }
            } else if event.kind == "edited" {
                self.applyEdit(event)  // IAyuEditHistoryStore dedups by cursor persistently
            }
            self.advancePersistedCursor()
        }
    }

    // Advance the persisted cursor only along the CONTIGUOUS processed prefix. If a
    // later event (e.g. live cursor 105) is processed while an earlier one (100) is
    // still in flight, the cursor stays put until the gap fills — so a crash never
    // skips 100. On the next launch gap-sync re-fetches from the persisted point and
    // the dedup above/edit store drop anything already applied. Must run on the main
    // queue (called only from handle()).
    private func advancePersistedCursor() {
        var cursor = Int(SGSimpleSettings.shared.iaSyncCursor)
        while self.processedCursors.contains(cursor + 1) {
            cursor += 1
        }
        if cursor > Int(SGSimpleSettings.shared.iaSyncCursor) {
            SGSimpleSettings.shared.iaSyncCursor = Int32(clamping: cursor)
            // Cursors at/below the persisted point are settled — drop them to keep
            // the in-memory set bounded (re-delivery is caught by the persistent dedup).
            self.processedCursors = self.processedCursors.filter { $0 > cursor }
        }
    }

    // Record the pre-edit text in the side store (keyed by peerId+messageId) so it
    // can be shown later via the "Edit history" action. Kept out of Postbox on
    // purpose — Telegram's own edit/resync would wipe a message attribute. Deduped
    // by cursor inside the store, so replays never double-record an edit.
    private func applyEdit(_ event: IAyuMessageEvent) {
        guard let oldText = event.oldText, !oldText.isEmpty else {
            return
        }
        let peerId = iAyuPeerId(fromServerChatId: event.chatId)
        let version = IAyuEditVersion(cursor: event.cursor, date: Int32(clamping: event.date ?? 0), text: oldText)
        IAyuEditHistoryStore.shared.append(peerId: peerId.toInt64(), messageId: Int32(clamping: event.messageId), version: version)
    }

    private func gapSync(serverURL: String, token: String, since: Int) {
        guard self.active else { return }
        guard var components = URLComponents(string: serverURL.contains("://") ? serverURL : "https://\(serverURL)") else {
            return
        }
        components.path = "/gap-sync"
        components.queryItems = [
            URLQueryItem(name: "since", value: "\(since)"),
            URLQueryItem(name: "limit", value: "\(iAyuGapSyncPageLimit)")
        ]
        guard let url = components.url else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, self.active else { return }
            guard let data = data, let response = try? JSONDecoder().decode(IAyuGapSyncResponse.self, from: data) else {
                return
            }
            for event in response.events {
                self.handle(event)
            }
            if response.events.count >= iAyuGapSyncPageLimit, let lastCursor = response.events.last?.cursor {
                // A full page — more may remain; keep paging from the last cursor.
                self.gapSync(serverURL: serverURL, token: token, since: lastCursor)
            } else if let maxReceived = response.events.map({ $0.cursor }).max() {
                // Fully caught up. Everything the server had up to maxReceived has now
                // been delivered, so advance the cursor to it — this closes PERMANENT
                // gaps in the historical cursor sequence (sqlite AUTOINCREMENT can skip
                // values, and a fresh client starts at 0 far below the first cursor)
                // that the contiguous advance would otherwise stall on forever. Only
                // up to maxReceived (not the server's latest) so a delete racing in
                // between the query's two statements isn't skipped — it re-syncs next
                // launch or arrives on /live.
                Queue.mainQueue().async {
                    guard self.active else { return }
                    if maxReceived > Int(SGSimpleSettings.shared.iaSyncCursor) {
                        SGSimpleSettings.shared.iaSyncCursor = Int32(clamping: maxReceived)
                        self.processedCursors = self.processedCursors.filter { $0 > maxReceived }
                    }
                }
            }
        }
        task.resume()
    }
}
