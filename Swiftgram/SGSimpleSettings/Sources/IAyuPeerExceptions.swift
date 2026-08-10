import Foundation

// IAyuGram per-chat exceptions.
//
// Ghost mode and message preservation are global switches; this is the per-chat escape
// hatch for both — "behave normally in this one chat" for ghost, "don't bring deleted
// messages back here" for preservation.
//
// Stored in UserDefaults rather than in a stored property because the readers live in
// several modules (TelegramCore's signal seams, the sync manager, the chat UI) and a
// statically linked module can be given one copy of its globals per link unit. That is
// not hypothetical here: it is exactly what made the capture-health state read healthy
// in the chat list while the settings screen read otherwise.
//
// Keyed by `PeerId.toInt64()` as a string, since UserDefaults dictionaries need string
// keys. Only chats the user has actually touched appear, so the dictionary stays small.
public enum IAyuPeerExceptionFlag: Int {
    /// Ghost signals behave normally in this chat — read receipts, typing, consumed
    /// marks and story views are reported as they would be with ghost off.
    ///
    /// NOTE: "stay offline" is deliberately NOT covered. Online is an account-level
    /// flag, not a per-chat one — Telegram has no way to be online for one conversation
    /// and offline for another, so no client-side gate could honour it per chat.
    case ghostDisabled = 1
    /// Deleted messages from this chat are not brought back. The companion server still
    /// captures and stores them — this is a display filter, not a privacy control.
    case preservationDisabled = 2
}

public final class IAyuPeerExceptions {
    public static let shared = IAyuPeerExceptions()

    /// Posted on the main queue when any chat's flags change, so open screens refresh.
    public static let changedNotification = Notification.Name("IAyuPeerExceptionsChanged")

    private static let defaultsKey = "iaPeerExceptions"

    private init() {
    }

    private var stored: [String: Int] {
        return UserDefaults.standard.dictionary(forKey: IAyuPeerExceptions.defaultsKey) as? [String: Int] ?? [:]
    }

    public func flags(peerId: Int64) -> Int {
        return self.stored["\(peerId)"] ?? 0
    }

    public func isSet(_ flag: IAyuPeerExceptionFlag, peerId: Int64) -> Bool {
        return self.flags(peerId: peerId) & flag.rawValue != 0
    }

    public func set(_ flag: IAyuPeerExceptionFlag, peerId: Int64, value: Bool) {
        var dictionary = self.stored
        let key = "\(peerId)"
        var flags = dictionary[key] ?? 0
        if value {
            flags |= flag.rawValue
        } else {
            flags &= ~flag.rawValue
        }
        // Drop the entry entirely once nothing is set, so the dictionary does not grow a
        // row for every chat the user ever opened the screen on and then reset.
        if flags == 0 {
            dictionary.removeValue(forKey: key)
        } else {
            dictionary[key] = flags
        }
        UserDefaults.standard.set(dictionary, forKey: IAyuPeerExceptions.defaultsKey)

        if Thread.isMainThread {
            NotificationCenter.default.post(name: IAyuPeerExceptions.changedNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: IAyuPeerExceptions.changedNotification, object: nil)
            }
        }
    }

    /// Convenience for the signal seams, which all ask the same question.
    public static func ghostApplies(peerId: Int64) -> Bool {
        return !IAyuPeerExceptions.shared.isSet(.ghostDisabled, peerId: peerId)
    }

    public static func preservationApplies(peerId: Int64) -> Bool {
        return !IAyuPeerExceptions.shared.isSet(.preservationDisabled, peerId: peerId)
    }
}
