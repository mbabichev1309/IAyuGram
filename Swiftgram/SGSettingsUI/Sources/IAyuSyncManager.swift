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
    // gap-sync backfill isn't processed twice.
    private var processedCursors = Set<Int>()
    // Message ids already materialized this session, so one deleted message yields at
    // most one placeholder even if the server re-emits it under a new cursor.
    private var materializedMessageIds = Set<Int64>()

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
                if !self.materializedMessageIds.contains(event.messageId) {
                    self.materializedMessageIds.insert(event.messageId)
                    iAyuMaterializeDeleted(context: self.context, event: event)
                }
            } else if event.kind == "edited" {
                self.applyEdit(event)
            }
            if event.cursor > Int(SGSimpleSettings.shared.iaSyncCursor) {
                SGSimpleSettings.shared.iaSyncCursor = Int32(clamping: event.cursor)
            }
        }
    }

    // Append the pre-edit text to the existing cloud message's edit history so it can
    // be shown later via the "Edit history" action. No-op if the message isn't in the
    // local Postbox (updateMessage's closure only runs when it exists) or if we've
    // already recorded this edit (matched by cursor).
    private func applyEdit(_ event: IAyuMessageEvent) {
        guard let oldText = event.oldText, !oldText.isEmpty else {
            return
        }
        let peerId = iAyuPeerId(fromServerChatId: event.chatId)
        let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(clamping: event.messageId))
        let version = EditHistoryMessageAttribute.Version(cursor: event.cursor, date: Int32(clamping: event.date ?? 0), text: oldText)
        let _ = (self.context.account.postbox.transaction { transaction -> Void in
            transaction.updateMessage(messageId, update: { currentMessage in
                var versions: [EditHistoryMessageAttribute.Version] = []
                var attributes = currentMessage.attributes
                if let index = attributes.firstIndex(where: { $0 is EditHistoryMessageAttribute }) {
                    if let existing = attributes[index] as? EditHistoryMessageAttribute {
                        if existing.versions.contains(where: { $0.cursor == event.cursor }) {
                            return .skip
                        }
                        versions = existing.versions
                    }
                    attributes.remove(at: index)
                }
                versions.append(version)
                attributes.append(EditHistoryMessageAttribute(versions: versions))

                var storeForwardInfo: StoreMessageForwardInfo?
                if let forwardInfo = currentMessage.forwardInfo {
                    storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
                }
                return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
            })
        }).start()
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
            } else {
                // Caught up: advance the persisted cursor to the server's latest.
                Queue.mainQueue().async {
                    guard self.active else { return }
                    if response.latestCursor > Int(SGSimpleSettings.shared.iaSyncCursor) {
                        SGSimpleSettings.shared.iaSyncCursor = Int32(clamping: response.latestCursor)
                    }
                }
            }
        }
        task.resume()
    }
}
