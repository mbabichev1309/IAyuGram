import Foundation

// IAyuGram: one preserved version of an edited message (text as it was BEFORE that
// edit), captured from the companion server.
public struct IAyuEditVersion: Codable, Equatable {
    public let cursor: Int
    public let date: Int32
    public let text: String

    public init(cursor: Int, date: Int32, text: String) {
        self.cursor = cursor
        self.date = date
        self.text = text
    }
}

// Persistent record of which deleted messages we've already materialized, keyed by
// (peerId, messageId). Prevents duplicate placeholders when gap-sync re-delivers an
// already-applied event across launches (which happens by design when the persisted
// cursor lags behind a gap). Bounded FIFO — old keys are dropped once capped; a very
// old re-delivery could in theory re-materialize, but the cursor makes that unlikely.
public final class IAyuMaterializedDeletesStore {
    public static let shared = IAyuMaterializedDeletesStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "iaMaterializedDeletes"
    private let cap = 8000
    private var order: [String]
    private var present: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: "iaMaterializedDeletes") ?? []
        self.order = stored
        self.present = Set(stored)
    }

    private func key(peerId: Int64, messageId: Int64) -> String {
        return "\(peerId):\(messageId)"
    }

    public func contains(peerId: Int64, messageId: Int64) -> Bool {
        return self.present.contains(self.key(peerId: peerId, messageId: messageId))
    }

    public func insert(peerId: Int64, messageId: Int64) {
        let k = self.key(peerId: peerId, messageId: messageId)
        if self.present.contains(k) {
            return
        }
        self.present.insert(k)
        self.order.append(k)
        if self.order.count > self.cap {
            let removeCount = self.order.count - self.cap
            for old in self.order.prefix(removeCount) {
                self.present.remove(old)
            }
            self.order.removeFirst(removeCount)
        }
        self.defaults.set(self.order, forKey: self.storageKey)
    }
}

// Edit history lives OUTSIDE Postbox on purpose: Telegram's own edit/resync path
// rebuilds a cloud message from server data and would wipe any custom attribute we
// attached. This side store, keyed by (peerId, messageId), is untouched by that
// sync, so the "Edit history" action survives across further edits and relaunches.
public final class IAyuEditHistoryStore {
    public static let shared = IAyuEditHistoryStore()

    private let defaults = UserDefaults.standard
    private let prefix = "iaEditHistory:"

    private func key(peerId: Int64, messageId: Int32) -> String {
        return "\(self.prefix)\(peerId):\(messageId)"
    }

    public func versions(peerId: Int64, messageId: Int32) -> [IAyuEditVersion] {
        guard let data = self.defaults.data(forKey: self.key(peerId: peerId, messageId: messageId)),
              let decoded = try? JSONDecoder().decode([IAyuEditVersion].self, from: data) else {
            return []
        }
        return decoded
    }

    // Append a version, deduped by cursor so replays (live + gap-sync overlap, or a
    // relaunch re-fetching) never double-record the same edit.
    public func append(peerId: Int64, messageId: Int32, version: IAyuEditVersion) {
        var current = self.versions(peerId: peerId, messageId: messageId)
        if current.contains(where: { $0.cursor == version.cursor }) {
            return
        }
        current.append(version)
        if let data = try? JSONEncoder().encode(current) {
            self.defaults.set(data, forKey: self.key(peerId: peerId, messageId: messageId))
        }
    }
}
