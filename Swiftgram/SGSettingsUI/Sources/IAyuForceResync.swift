import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SGSimpleSettings

// IAyuGram forced re-sync.
//
// The normal path is cursor-driven: /live delivers events as they happen, gap-sync
// catches up from the last persisted cursor, and both mark what they handled so it is
// never done twice. That bookkeeping is exactly what makes one failure unrecoverable —
// an event that was received and settled but whose message never reached Postbox (a
// transaction that lost its race with something else, a kill between settle and flush,
// a materialization that threw away its item) is, as far as every stored marker is
// concerned, already done. Nothing will offer it again.
//
// So this replays a window of the server's log outright, ignores the cursor and the
// dedup store, and decides what is missing by looking at the chats themselves. Only
// what is genuinely absent is inserted, which is why it can be run twice with no
// consequence.

private struct IAyuReplayResponse: Codable {
    let events: [IAyuMessageEvent]

    enum CodingKeys: String, CodingKey {
        case events
    }
}

private let iAyuReplayPageLimit = 500
// A ceiling on one run. The window is chosen by the user and "last 24 hours" can cover
// a wiped chat, i.e. thousands of events; restoring all of them silently would be a
// worse surprise than being told the run was truncated.
private let iAyuReplayRestoreCap = 1000
// Same budget as the sync manager's — preserved media is fetched over HTTP and written
// into the media box, and a hundred concurrent transfers is how that goes wrong.
private let iAyuReplayConcurrentFetches = 3
// Restored copies per transaction, same size the live path settled on.
private let iAyuReplayFlushThreshold = 200

public struct IAyuForceResyncResult {
    public let events: Int
    public let restored: Int
    public let alreadyPresent: Int
    // Missing, but past the per-run cap — run it again to take the next batch.
    public let overCap: Int
    public let error: String?
}

/// Replay the last `window` seconds of the companion server's log and restore whatever
/// is missing from the chats. `completion` is called on the main queue.
public func iAyuForceResync(context: AccountContext, window: Int, completion: @escaping (IAyuForceResyncResult) -> Void) {
    let serverURL = SGSimpleSettings.shared.iaSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = SGSimpleSettings.shared.iaSyncClientToken
    let finish: (IAyuForceResyncResult) -> Void = { result in
        Queue.mainQueue().async {
            completion(result)
        }
    }
    guard !serverURL.isEmpty, !token.isEmpty else {
        finish(IAyuForceResyncResult(events: 0, restored: 0, alreadyPresent: 0, overCap: 0, error: IAyuStrings.text(.forceResyncNotConfigured)))
        return
    }
    let sinceTs = Int(Date().timeIntervalSince1970) - window

    iAyuReplayFetch(serverURL: serverURL, token: token, sinceTs: sinceTs, since: 0, collected: []) { events, error in
        if let error = error {
            finish(IAyuForceResyncResult(events: 0, restored: 0, alreadyPresent: 0, overCap: 0, error: error))
            return
        }
        // Edits are replayed too, and cost nothing: the edit-history store dedups by
        // cursor, so re-offering one that was already recorded is a no-op.
        for event in events where event.kind == "edited" {
            iAyuReplayEdit(event)
        }
        let deletes = events.filter { $0.kind == "deleted" && iAyuReplayShouldRestore(event: $0) }
        guard !deletes.isEmpty else {
            finish(IAyuForceResyncResult(events: events.count, restored: 0, alreadyPresent: 0, overCap: 0, error: nil))
            return
        }
        let _ = (iAyuReplayMissing(context: context, events: deletes)
        |> deliverOnMainQueue).start(next: { missing in
            let present = deletes.count - missing.count
            let batch = Array(missing.suffix(iAyuReplayRestoreCap))
            let overCap = missing.count - batch.count
            guard !batch.isEmpty else {
                finish(IAyuForceResyncResult(events: events.count, restored: 0, alreadyPresent: present, overCap: 0, error: nil))
                return
            }
            iAyuReplayMaterialize(context: context, events: batch) {
                finish(IAyuForceResyncResult(events: events.count, restored: batch.count, alreadyPresent: present, overCap: overCap, error: nil))
            }
        })
    }
}

// Page the window, cursor by cursor, exactly as a normal catch-up does — the server
// applies the time filter on top of the cursor, so nothing here has to know how its
// cursors are numbered.
private func iAyuReplayFetch(serverURL: String, token: String, sinceTs: Int, since: Int, collected: [IAyuMessageEvent], completion: @escaping ([IAyuMessageEvent], String?) -> Void) {
    guard var components = URLComponents(string: serverURL.contains("://") ? serverURL : "https://\(serverURL)") else {
        completion([], IAyuStrings.text(.forceResyncBadServer))
        return
    }
    components.path = "/gap-sync"
    components.queryItems = [
        URLQueryItem(name: "since", value: "\(since)"),
        URLQueryItem(name: "since_ts", value: "\(sinceTs)"),
        URLQueryItem(name: "limit", value: "\(iAyuReplayPageLimit)")
    ]
    guard let url = components.url else {
        completion([], IAyuStrings.text(.forceResyncBadServer))
        return
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            completion([], error.localizedDescription)
            return
        }
        // An old server ignores since_ts and answers the whole log from cursor 0, which
        // would look like a successful run over a window it never applied. The status
        // code can't tell us that, so the count is capped below either way and the run
        // stays correct — it restores what is missing, whatever the window turned out
        // to be.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            completion([], IAyuStrings.text(.forceResyncHTTPError, ["code": "\(http.statusCode)"]))
            return
        }
        guard let data = data, let parsed = try? JSONDecoder().decode(IAyuReplayResponse.self, from: data) else {
            completion([], IAyuStrings.text(.forceResyncBadResponse))
            return
        }
        let total = collected + parsed.events
        if parsed.events.count >= iAyuReplayPageLimit, let lastCursor = parsed.events.last?.cursor {
            iAyuReplayFetch(serverURL: serverURL, token: token, sinceTs: sinceTs, since: lastCursor, collected: total, completion: completion)
        } else {
            completion(total, nil)
        }
    }
    task.resume()
}

// The same two rules the live path applies, so a forced run can't bring back what the
// user has told the app not to restore.
private func iAyuReplayShouldRestore(event: IAyuMessageEvent) -> Bool {
    let peerId = iAyuPeerId(fromServerChatId: event.chatId)
    guard IAyuPeerExceptions.preservationApplies(peerId: peerId.toInt64()) else {
        return false
    }
    if event.fromMe == true, !SGSimpleSettings.shared.iaRestoreOwnDeletes {
        return false
    }
    return true
}

private func iAyuReplayEdit(_ event: IAyuMessageEvent) {
    guard let oldText = event.oldText, !oldText.isEmpty else {
        return
    }
    let peerId = iAyuPeerId(fromServerChatId: event.chatId)
    let version = IAyuEditVersion(cursor: event.cursor, date: Int32(clamping: event.date ?? 0), text: oldText)
    IAyuEditHistoryStore.shared.append(peerId: peerId.toInt64(), messageId: Int32(clamping: event.messageId), version: version)
}

// Which of these events have no copy in the chat. Answered from Postbox rather than
// from the dedup store on purpose: the store records what we believed we inserted, and
// the whole point here is that the belief can be wrong.
private func iAyuReplayMissing(context: AccountContext, events: [IAyuMessageEvent]) -> Signal<[IAyuMessageEvent], NoError> {
    return context.account.postbox.transaction { transaction -> [IAyuMessageEvent] in
        var byPeer: [PeerId: [IAyuMessageEvent]] = [:]
        for event in events {
            byPeer[iAyuPeerId(fromServerChatId: event.chatId), default: []].append(event)
        }
        var missing: [IAyuMessageEvent] = []
        for (peerId, peerEvents) in byPeer {
            var origins = Set<Int32>()
            // Copies made before DeletedMessageAttribute carried an origin id can only
            // be recognised by when the original was sent, which is the timestamp we
            // gave them. Coarse, and deliberately so: a false "already here" costs one
            // message that stays lost, a false "missing" puts a duplicate in the chat.
            var legacyTimestamps = Set<Int32>()
            transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Local) { message in
                for attribute in message.attributes {
                    if let attribute = attribute as? DeletedMessageAttribute {
                        if let originId = attribute.originId {
                            origins.insert(originId)
                        } else {
                            legacyTimestamps.insert(message.timestamp)
                        }
                        break
                    }
                }
                return true
            }
            for event in peerEvents {
                let messageId = Int32(clamping: event.messageId)
                if origins.contains(messageId) {
                    continue
                }
                if let date = event.date, legacyTimestamps.contains(Int32(clamping: date)) {
                    continue
                }
                missing.append(event)
            }
        }
        // Oldest first. The caller restores the newest capful of these — that is the
        // part of the chat the user is actually looking at — and a second run finds the
        // rest still missing and takes the next capful, so repeating converges.
        return missing.sorted { $0.cursor < $1.cursor }
    }
}

// Fetch each event's media and insert the copies. Mirrors the sync manager's pipeline
// (bounded concurrency, batched insert) without going through it: the manager's queue
// owns cursor bookkeeping this run must not touch.
private func iAyuReplayMaterialize(context: AccountContext, events: [IAyuMessageEvent], completion: @escaping () -> Void) {
    let queue = Queue(name: "org.iayugram.forceResync", qos: .utility)
    var remaining = events
    var items: [IAyuPendingDelete] = []
    var active = 0

    // Committed in chunks for the same reason the live path buffers: one transaction
    // per message recomputes the history view per message, and one transaction for a
    // thousand of them is a long stall at the end.
    func flush(final: Bool) {
        let batch = items
        items = []
        Queue.mainQueue().async {
            if !batch.isEmpty {
                iAyuInsertDeleted(context: context, items: batch)
                for item in batch {
                    let peerId = iAyuPeerId(fromServerChatId: item.event.chatId)
                    IAyuMaterializedDeletesStore.shared.insert(peerId: peerId.toInt64(), messageId: item.event.messageId)
                }
            }
            if final {
                completion()
            }
        }
    }

    func pump() {
        while active < iAyuReplayConcurrentFetches, !remaining.isEmpty {
            let event = remaining.removeFirst()
            active += 1
            iAyuFetchAndBuildMedia(context: context, event: event) { item in
                queue.async {
                    active -= 1
                    items.append(item)
                    if remaining.isEmpty, active == 0 {
                        flush(final: true)
                    } else {
                        if items.count >= iAyuReplayFlushThreshold {
                            flush(final: false)
                        }
                        pump()
                    }
                }
            }
        }
    }

    queue.async {
        pump()
    }
}
