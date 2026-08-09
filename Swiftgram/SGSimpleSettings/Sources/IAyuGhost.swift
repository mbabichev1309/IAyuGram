import Foundation

// IAyuGram ghost mode — the master switch's rules, in one place.
//
// Three callers act on "ghost mode" as a whole: the switch in Telegram's own settings
// list, the hub screen, and the home-screen quick action. They must agree on which
// signals the master owns and on what a lock means, and the only way to guarantee that
// is to keep the rules here rather than repeating the list at each call site.
//
// Invisible send is deliberately NOT part of this: it delays every message by ~12s, so
// it is a separate opt-in with its own section rather than something a single tap turns
// on along with the rest.
public enum IAyuGhostSignal: CaseIterable {
    case hideReadReceipts
    case stayOffline
    case hideTyping
    case hideConsumed
    case hideStoryViews

    public var isEnabled: Bool {
        let settings = SGSimpleSettings.shared
        switch self {
        case .hideReadReceipts: return settings.iaGhostHideReadReceipts
        case .stayOffline: return settings.iaGhostStayOffline
        case .hideTyping: return settings.iaGhostHideTyping
        case .hideConsumed: return settings.iaGhostHideConsumed
        case .hideStoryViews: return settings.iaGhostHideStoryViews
        }
    }

    public func setEnabled(_ value: Bool) {
        let settings = SGSimpleSettings.shared
        switch self {
        case .hideReadReceipts: settings.iaGhostHideReadReceipts = value
        case .stayOffline: settings.iaGhostStayOffline = value
        case .hideTyping: settings.iaGhostHideTyping = value
        case .hideConsumed: settings.iaGhostHideConsumed = value
        case .hideStoryViews: settings.iaGhostHideStoryViews = value
        }
    }

    /// A locked signal ignores the master switch and keeps whatever the user set.
    public var isLocked: Bool {
        let settings = SGSimpleSettings.shared
        switch self {
        case .hideReadReceipts: return settings.iaGhostLockHideReadReceipts
        case .stayOffline: return settings.iaGhostLockStayOffline
        case .hideTyping: return settings.iaGhostLockHideTyping
        case .hideConsumed: return settings.iaGhostLockHideConsumed
        case .hideStoryViews: return settings.iaGhostLockHideStoryViews
        }
    }

    public func setLocked(_ value: Bool) {
        let settings = SGSimpleSettings.shared
        switch self {
        case .hideReadReceipts: settings.iaGhostLockHideReadReceipts = value
        case .stayOffline: settings.iaGhostLockStayOffline = value
        case .hideTyping: settings.iaGhostLockHideTyping = value
        case .hideConsumed: settings.iaGhostLockHideConsumed = value
        case .hideStoryViews: settings.iaGhostLockHideStoryViews = value
        }
    }
}

public enum IAyuGhost {
    /// Whether the master switch reads as on.
    ///
    /// Locked signals are excluded from the answer, not just from writes. Counting them
    /// would let one signal locked OFF hold the master at "off" no matter what the user
    /// does with the rest — the switch would look broken. With every signal locked there
    /// is nothing left for the master to own, so it reads off.
    public static var isOn: Bool {
        let governed = IAyuGhostSignal.allCases.filter { !$0.isLocked }
        guard !governed.isEmpty else {
            return false
        }
        return governed.allSatisfy { $0.isEnabled }
    }

    /// Apply the master switch, leaving locked signals untouched.
    public static func setAll(_ value: Bool) {
        for signal in IAyuGhostSignal.allCases where !signal.isLocked {
            signal.setEnabled(value)
        }
    }
}
