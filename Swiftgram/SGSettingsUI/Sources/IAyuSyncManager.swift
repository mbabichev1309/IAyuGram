import Foundation
import UIKit
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

// How long the live socket may stay down before it is reported as an outage. Long
// enough to cover a reconnect (backoff caps at 60s) and a walk through a dead spot,
// short enough that a genuinely dead server is noticed the same day.
private let iAyuCaptureDegradeGracePeriod = 180.0

private func iAyuHealthzURL(serverURL: String) -> URL? {
    guard var components = URLComponents(string: serverURL.contains("://") ? serverURL : "https://\(serverURL)") else {
        return nil
    }
    components.path = "/healthz"
    return components.url
}

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
    private var serverURL = ""
    private var token = ""
    private var reconnectDelay = 5.0
    private var foregroundObserver: NSObjectProtocol?
    // Capture-health tracking (see IAyuCaptureHealth). The socket dropping is not by
    // itself worth a warning — reconnects are routine, and iOS kills the socket on every
    // backgrounding. Only a drop that outlives the grace period means something is wrong.
    private var isLiveConnected = false
    private var degradeCheckPending = false

    public init(context: AccountContext) {
        self.context = context
        self.start()
        // The iOS app is suspended in the background, killing the socket; reconnect
        // and catch up whenever it returns to the foreground.
        self.foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onForeground()
        }
    }

    deinit {
        self.active = false
        self.liveSession?.stop()
        if let observer = self.foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func start() {
        self.serverURL = SGSimpleSettings.shared.iaSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = SGSimpleSettings.shared.iaSyncClientToken
        guard !self.serverURL.isEmpty, !self.token.isEmpty else {
            // Companion server not configured — nothing to sync, and nothing to warn about.
            IAyuCaptureHealth.shared.update(.notConfigured)
            return
        }
        // Assume healthy until something actually fails, so a cold launch never flashes
        // a warning before the first connection has had a chance to complete.
        IAyuCaptureHealth.shared.update(.healthy)
        // Connect live first so events firing during the gap-sync fetch aren't lost;
        // the cursor dedup below drops any that both paths deliver.
        self.connectLive()
        self.gapSync(serverURL: self.serverURL, token: self.token, since: Int(SGSimpleSettings.shared.iaSyncCursor))
    }

    private func connectLive() {
        self.liveSession?.stop()
        self.liveSession = IAyuLiveSession(serverURL: self.serverURL, token: self.token, onEvent: { [weak self] event in
            self?.handle(event)
        }, onStatus: { _ in
        }, onConnected: { [weak self] connected in
            guard let self = self else { return }
            self.isLiveConnected = connected
            if connected {
                // Reset the backoff once we're actually connected.
                self.reconnectDelay = 5.0
                IAyuCaptureHealth.shared.update(.healthy)
            } else {
                self.scheduleDegradeCheck()
            }
        }, onClosed: { [weak self] in
            self?.scheduleReconnect()
        })
    }

    // A dropped socket only counts as a real outage once it has stayed down past the
    // grace period, so ordinary reconnects and app backgrounding stay silent. When the
    // grace period is up, ask the server directly: it distinguishes "unreachable" from
    // "running but no longer authorized with Telegram", and the second is the one that
    // looks fine from outside while capturing nothing.
    private func scheduleDegradeCheck() {
        // Start the countdown on the transition into "down", NOT on every failure.
        // Reconnect attempts keep failing while the server is off and the backoff caps
        // at 60s, so re-arming the timer per failure meant a grace period longer than
        // the retry interval could never elapse — the check simply never ran.
        guard !self.degradeCheckPending else {
            return
        }
        self.degradeCheckPending = true
        Queue.mainQueue().after(iAyuCaptureDegradeGracePeriod, { [weak self] in
            guard let self = self, self.active else {
                return
            }
            self.degradeCheckPending = false
            guard !self.isLiveConnected else {
                return
            }
            self.probeHealth()
        })
    }

    private func probeHealth() {
        guard let url = iAyuHealthzURL(serverURL: self.serverURL) else {
            IAyuCaptureHealth.shared.update(.unreachable)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            Queue.mainQueue().async {
                guard let self = self, self.active, !self.isLiveConnected else {
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data else {
                    IAyuCaptureHealth.shared.update(.unreachable)
                    self.rearmDegradeCheck()
                    return
                }
                // Older server builds answer /healthz without the field; absence must not
                // read as "session lost", so only an explicit false counts.
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let authorized = json?["session_authorized"] as? Bool, !authorized {
                    IAyuCaptureHealth.shared.update(.sessionLost)
                    self.rearmDegradeCheck()
                } else {
                    // Server up and still authorized: capture is running and nothing is
                    // being lost, whatever our own socket is doing — gap-sync backfills
                    // it. Reporting this as degraded would light up after every return
                    // from the background, when the socket is briefly down by design.
                    IAyuCaptureHealth.shared.update(.healthy)
                }
            }
        }.resume()
    }

    // Keep probing while we stay down, so a server that later loses its session is
    // still noticed rather than being frozen at whatever the first probe found.
    private func rearmDegradeCheck() {
        guard self.active, !self.isLiveConnected else {
            return
        }
        self.scheduleDegradeCheck()
    }

    // Reconnect with exponential backoff (5s → 60s cap) after the socket drops, and
    // gap-sync to catch anything missed while disconnected (dedup guards duplicates).
    private func scheduleReconnect() {
        guard self.active, !self.serverURL.isEmpty else { return }
        let delay = self.reconnectDelay
        self.reconnectDelay = min(self.reconnectDelay * 2.0, 60.0)
        Queue.mainQueue().after(delay, { [weak self] in
            guard let self = self, self.active else { return }
            self.connectLive()
            self.gapSync(serverURL: self.serverURL, token: self.token, since: Int(SGSimpleSettings.shared.iaSyncCursor))
        })
    }

    private func onForeground() {
        guard self.active, !self.serverURL.isEmpty else { return }
        self.reconnectDelay = 5.0
        self.connectLive()
        self.gapSync(serverURL: self.serverURL, token: self.token, since: Int(SGSimpleSettings.shared.iaSyncCursor))
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
