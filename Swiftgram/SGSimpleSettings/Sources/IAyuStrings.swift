import Foundation

// Every user-facing string IAyuGram adds to the app, in one table, so the Localization
// screen can rewrite any of them on the device — the app ships English only and there is
// no .strings pipeline for our additions.
//
// Lives in SGSimpleSettings because that is the lowest module every caller already
// depends on: TelegramCore, TelegramUI, PeerInfoScreen and SGSettingsUI all import it.
//
// Strings that take values use {named} tokens rather than printf specifiers on purpose:
// these defaults are editable by hand, and a mistyped %@ can garble output or trap,
// while an unknown {token} is simply left in place.

public enum IAyuStringKey: String, CaseIterable {
    // Settings root (Telegram's own settings list)
    case settingsGhostSwitch
    case settingsRow

    // IAyuGram hub
    case hubTitle
    case hubGhostHeader
    case hubGhostHideReadReceipts
    case hubGhostStayOffline
    case hubGhostHideTyping
    case hubGhostHideConsumed
    case hubGhostHideStoryViews
    case hubGhostInfo
    case hubGhostLockHint
    case hubSendHeader
    case hubGhostInvisibleSend
    case hubSendInfo
    case hubPreserveHeader
    case hubRestoreOwnDeletes
    case hubPreserveInfo

    // Per-chat exceptions
    case chatExceptionsMenuItem
    case chatExceptionsTitle
    case chatExceptionsGhostDisabled
    case chatExceptionsGhostInfo
    case chatExceptionsPreservationDisabled
    case chatExceptionsPreservationInfo
    case hubMediaHeader
    case hubMediaCap
    case hubMediaCapUnlimited
    case hubMediaInfo
    case hubAppearance
    case hubLocalization
    case hubConnection

    // Appearance
    case appearanceTitle
    case appearanceBadgesHeader
    case appearanceDeletedBadge
    case appearanceEditedBadge
    case appearanceBadgesInfo
    case appearanceTintDeleted
    case appearanceTintColor
    case appearanceEditHistoryHeader
    case appearanceShowDates
    case appearancePlaybackHeader
    case appearanceVoiceElapsed
    case appearancePlaybackInfo

    // Localization (this screen itself)
    case localizationTitle
    case localizationInfo
    case localizationReset

    // Connection keys
    case connectionTitle
    case connectionServerHeader
    case connectionURL
    case connectionToken
    case connectionConnect
    case connectionLiveHeader
    case connectionStatusConnecting
    case connectionStatusConnected
    case connectionStatusFailed
    case connectionStatusDisconnected
    case connectionStatusInvalidURL
    case connectionEventNoContent

    // Capture health — replaces the chat list title while capture is down
    case captureWarningTitle

    // Edit history
    case editHistoryMenuItem
    case editHistoryTitle
    case editHistoryPreviousHeader
    case editHistoryPreviousHeaderWithBadge
    case editHistoryCurrentHeader

    // Preserved media (kind names used in a deleted message's note)
    case mediaPhoto
    case mediaVideo
    case mediaVoice
    case mediaRound
    case mediaAudio
    case mediaGif
    case mediaFile
    case mediaGeneric
    case mediaSkippedNote

    // Mass deletions — a whole chat's worth of deletes, collapsed into one message
    case hubMassDeleteHeader
    case hubMassDeleteThreshold
    case hubMassDeleteNever
    case hubMassDeleteInfo
    case massDeletePlaque
    case massDeleteShowAll
    case massDeleteTitle
    case massDeleteHeader
    case massDeleteFromMe
    case massDeleteRestore
    case massDeleteRestored
    case massDeleteShowMore
    case massDeleteMissing
    case massDeleteCollapseExisting
    case massDeleteCollapseExistingConfirm
    case massDeleteCollapseExistingNothing
    case massDeleteCollapseExistingDone

    // Round videos — recording past the 60s cap
    case hubRoundVideoHeader
    case hubRoundVideoInfinite
    case hubRoundVideoInfo

    // Home-screen quick action
    case shortcutGhostTitle
    case shortcutGhostSubtitle

    // My Profile header
    case myProfileStatusGhost
}

public final class IAyuStrings {
    private static let overridesDefaultsKey = "iaStringOverrides"
    private static let lock = NSLock()
    private static var cachedOverrides: [String: String]?

    public static let defaults: [IAyuStringKey: String] = [
        .settingsGhostSwitch: "Ghost mode",
        .settingsRow: "IAyuGram",

        .hubTitle: "IAyuGram",
        .hubGhostHeader: "GHOST MODE",
        .hubGhostHideReadReceipts: "Don't send read receipts",
        .hubGhostStayOffline: "Stay offline",
        .hubGhostHideTyping: "Don't send typing",
        .hubGhostHideConsumed: "Don't mark voice/video as listened",
        .hubGhostHideStoryViews: "Don't report story views",
        .hubGhostLockHint: "Tap a lock to keep that switch from following the master Ghost mode toggle.",
        .hubSendHeader: "SENDING",
        .hubGhostInvisibleSend: "Invisible send",
        .hubPreserveHeader: "PRESERVED MESSAGES",
        .hubRestoreOwnDeletes: "Restore my own deletions",
        .hubPreserveInfo: "When you delete your own message for everyone, bring it back in the chat. Off means your own deletions stay deleted; messages other people delete are unaffected either way.",

        .chatExceptionsMenuItem: "IAyuGram in this chat",
        .chatExceptionsTitle: "IAyuGram in this chat",
        .chatExceptionsGhostDisabled: "Turn Ghost mode off here",
        .chatExceptionsGhostInfo: "Read receipts, typing, played voice/video and story views are reported normally in this chat. \"Stay offline\" is not included — online is an account-wide flag, so it cannot differ per chat.",
        .chatExceptionsPreservationDisabled: "Don't restore deleted messages here",
        .chatExceptionsPreservationInfo: "Deleted messages in this chat are not brought back. They are still captured and stored on your companion server — this hides them, it does not stop recording them.",

        .hubSendInfo: "Sends your messages as scheduled about 12 seconds out, so sending does not show you online. Expect that delay on every message. Not part of Ghost mode — it stays as you set it.",
        .hubGhostInfo: "Others won't see your read receipts, online status, typing, when you play their voice/video messages, or when you view their stories.",
        .hubMediaHeader: "PRESERVED MEDIA",
        .hubMediaCap: "Download limit",
        .hubMediaCapUnlimited: "Unlimited",
        .hubMediaInfo: "Largest file this device will pull from the companion server. Anything over the limit is preserved as text with a note instead. The file itself stays on the server, so raising the limit brings it back on the next sync.",
        .hubAppearance: "Appearance",
        .hubLocalization: "Localization",
        .hubConnection: "Connection keys",

        .appearanceTitle: "Appearance",
        .appearanceBadgesHeader: "MESSAGE BADGES",
        .appearanceDeletedBadge: "Deleted",
        .appearanceEditedBadge: "Edited",
        .appearanceBadgesInfo: "Shown on preserved messages. Leave empty to hide the label.",
        .appearanceTintDeleted: "Tint deleted messages",
        .appearanceTintColor: "Tint color",
        .appearanceEditHistoryHeader: "EDIT HISTORY",
        .appearanceShowDates: "Show version dates",
        .appearancePlaybackHeader: "PLAYBACK",
        .appearanceVoiceElapsed: "Count voice messages up",
        .appearancePlaybackInfo: "Show how much of a voice message has played instead of how much is left. Video messages already count up.",

        .localizationTitle: "Localization",
        .localizationInfo: "Every text IAyuGram adds to the app. Leave a field empty to fall back to the default shown in grey. {token} placeholders are filled in at runtime — keep them.",
        .localizationReset: "Reset all to defaults",

        .connectionTitle: "Connection keys",
        .connectionServerHeader: "COMPANION SERVER",
        .connectionURL: "URL",
        .connectionToken: "Token",
        .connectionConnect: "Save & Connect (live)",
        .connectionLiveHeader: "LIVE EVENTS",
        .connectionStatusConnecting: "Live: connecting…",
        .connectionStatusConnected: "Live: connected ✅ (listening for events)",
        .connectionStatusFailed: "Live: failed — {error}",
        .connectionStatusDisconnected: "Live: disconnected — {error}",
        .connectionStatusInvalidURL: "Live: invalid URL",
        .connectionEventNoContent: "<no content>",

        .captureWarningTitle: "⚠️ Capture down",

        .editHistoryMenuItem: "Edit history",
        .editHistoryTitle: "Edit history",
        .editHistoryPreviousHeader: "PREVIOUS VERSIONS",
        .editHistoryPreviousHeaderWithBadge: "{badge} — previous versions",
        .editHistoryCurrentHeader: "CURRENT",

        .mediaPhoto: "Photo",
        .mediaVideo: "Video",
        .mediaVoice: "Voice message",
        .mediaRound: "Video message",
        .mediaAudio: "Audio",
        .mediaGif: "GIF",
        .mediaFile: "File",
        .mediaGeneric: "Media",
        .mediaSkippedNote: "[{kind}, {size} MB — not downloaded]",

        .hubMassDeleteHeader: "MASS DELETIONS",
        .hubMassDeleteThreshold: "Collapse from",
        .hubMassDeleteNever: "Never collapse",
        .hubMassDeleteInfo: "When a chat is wiped, bringing every message back one by one is neither readable nor free. Past this many deletions in one burst they are kept aside and the chat gets a single summary instead, which opens the full list.",
        .massDeletePlaque: "{count} messages were deleted",
        .massDeleteShowAll: "Show all",
        .massDeleteTitle: "Deleted messages",
        .massDeleteHeader: "{count} MESSAGES",
        .massDeleteFromMe: "You",
        .massDeleteRestore: "Restore into the chat",
        .massDeleteRestored: "Restored into the chat",
        .massDeleteShowMore: "Show more",
        .massDeleteMissing: "These messages are no longer stored on this device.",
        .massDeleteCollapseExisting: "Collapse preserved deletions",
        .massDeleteCollapseExistingConfirm: "Collapse {count} preserved messages in this chat into a single summary? Nothing is lost — they stay readable from the summary, with their media, and can be restored one at a time.",
        .massDeleteCollapseExistingNothing: "There are no preserved deleted messages in this chat.",
        .massDeleteCollapseExistingDone: "{count} messages collapsed into a summary.",

        .hubRoundVideoHeader: "ROUND VIDEOS",
        .hubRoundVideoInfinite: "Record past one minute",
        .hubRoundVideoInfo: "Telegram stops a round video at one minute. With this on, the finished minute is sent on its own and recording carries straight on, so a long take arrives as a series of messages. There is a short gap at each seam, and the recording still stops for good after ten of them.",

        .shortcutGhostTitle: "Ghost mode",
        .shortcutGhostSubtitle: "Enter with all signals hidden",

        .myProfileStatusGhost: "Offline (ghost mode)"
    ]

    /// Human-readable grouping for the Localization screen, in display order.
    public static let groups: [(title: String, keys: [IAyuStringKey])] = [
        ("SETTINGS LIST", [.settingsGhostSwitch, .settingsRow]),
        ("HUB", [.hubTitle, .hubGhostHeader, .hubGhostHideReadReceipts, .hubGhostStayOffline,
                 .hubGhostHideTyping, .hubGhostHideConsumed, .hubGhostHideStoryViews,
                 .hubGhostInfo, .hubGhostLockHint, .hubSendHeader, .hubGhostInvisibleSend,
                 .hubSendInfo, .hubPreserveHeader, .hubRestoreOwnDeletes, .hubPreserveInfo, .hubMediaHeader, .hubMediaCap, .hubMediaCapUnlimited,
                 .hubMediaInfo, .hubAppearance, .hubLocalization, .hubConnection]),
        ("APPEARANCE", [.appearanceTitle, .appearanceBadgesHeader, .appearanceDeletedBadge,
                        .appearanceEditedBadge, .appearanceBadgesInfo, .appearanceTintDeleted,
                        .appearanceTintColor, .appearanceEditHistoryHeader, .appearanceShowDates,
                        .appearancePlaybackHeader, .appearanceVoiceElapsed, .appearancePlaybackInfo]),
        ("LOCALIZATION", [.localizationTitle, .localizationInfo, .localizationReset]),
        ("CONNECTION", [.connectionTitle, .connectionServerHeader, .connectionURL, .connectionToken,
                        .connectionConnect, .connectionLiveHeader, .connectionStatusConnecting,
                        .connectionStatusConnected, .connectionStatusFailed,
                        .connectionStatusDisconnected, .connectionStatusInvalidURL,
                        .connectionEventNoContent]),
        ("CAPTURE HEALTH", [.captureWarningTitle]),
        ("PER-CHAT EXCEPTIONS", [.chatExceptionsMenuItem, .chatExceptionsTitle,
                                 .chatExceptionsGhostDisabled, .chatExceptionsGhostInfo,
                                 .chatExceptionsPreservationDisabled, .chatExceptionsPreservationInfo]),
        ("EDIT HISTORY", [.editHistoryMenuItem, .editHistoryTitle, .editHistoryPreviousHeader,
                          .editHistoryPreviousHeaderWithBadge, .editHistoryCurrentHeader]),
        ("PRESERVED MEDIA", [.mediaPhoto, .mediaVideo, .mediaVoice, .mediaRound, .mediaAudio,
                             .mediaGif, .mediaFile, .mediaGeneric, .mediaSkippedNote]),
        ("MASS DELETIONS", [.hubMassDeleteHeader, .hubMassDeleteThreshold, .hubMassDeleteNever,
                            .hubMassDeleteInfo, .massDeletePlaque, .massDeleteShowAll,
                            .massDeleteTitle, .massDeleteHeader, .massDeleteFromMe, .massDeleteRestore,
                            .massDeleteRestored, .massDeleteShowMore, .massDeleteMissing,
                            .massDeleteCollapseExisting, .massDeleteCollapseExistingConfirm,
                            .massDeleteCollapseExistingNothing, .massDeleteCollapseExistingDone]),
        ("ROUND VIDEOS", [.hubRoundVideoHeader, .hubRoundVideoInfinite, .hubRoundVideoInfo]),
        ("QUICK ACTION", [.shortcutGhostTitle, .shortcutGhostSubtitle]),
        ("MY PROFILE", [.myProfileStatusGhost])
    ]

    /// Short label naming the key on the Localization screen (the row's own title).
    public static func editorLabel(_ key: IAyuStringKey) -> String {
        switch key {
        case .settingsGhostSwitch: return "Ghost switch"
        case .settingsRow: return "IAyuGram row"
        case .hubTitle: return "Title"
        case .hubGhostHeader: return "Ghost header"
        case .hubGhostHideReadReceipts: return "Read receipts"
        case .hubGhostStayOffline: return "Stay offline"
        case .hubGhostHideTyping: return "Typing"
        case .hubGhostHideConsumed: return "Consumed"
        case .hubGhostHideStoryViews: return "Hide story views"
        case .hubGhostLockHint: return "Lock hint"
        case .hubSendHeader: return "Sending header"
        case .hubSendInfo: return "Sending footnote"
        case .hubPreserveHeader: return "Preserved header"
        case .hubRestoreOwnDeletes: return "Restore own deletions"
        case .hubPreserveInfo: return "Preserved footnote"
        case .chatExceptionsMenuItem: return "Chat menu item"
        case .chatExceptionsTitle: return "Screen title"
        case .chatExceptionsGhostDisabled: return "Ghost off here"
        case .chatExceptionsGhostInfo: return "Ghost footnote"
        case .chatExceptionsPreservationDisabled: return "No restore here"
        case .chatExceptionsPreservationInfo: return "Preservation footnote"
        case .hubGhostInvisibleSend: return "Invisible send"
        case .hubGhostInfo: return "Ghost footnote"
        case .hubMediaHeader: return "Media header"
        case .hubMediaCap: return "Download limit"
        case .hubMediaCapUnlimited: return "Unlimited value"
        case .hubMediaInfo: return "Media footnote"
        case .hubAppearance: return "Appearance row"
        case .hubLocalization: return "Localization row"
        case .hubConnection: return "Connection row"
        case .appearanceTitle: return "Title"
        case .appearanceBadgesHeader: return "Badges header"
        case .appearanceDeletedBadge: return "Deleted field"
        case .appearanceEditedBadge: return "Edited field"
        case .appearanceBadgesInfo: return "Badges footnote"
        case .appearanceTintDeleted: return "Tint switch"
        case .appearanceTintColor: return "Tint colour"
        case .appearanceEditHistoryHeader: return "History header"
        case .appearanceShowDates: return "Dates switch"
        case .appearancePlaybackHeader: return "Playback header"
        case .appearanceVoiceElapsed: return "Voice count-up switch"
        case .appearancePlaybackInfo: return "Playback footnote"
        case .localizationTitle: return "Title"
        case .localizationInfo: return "Footnote"
        case .localizationReset: return "Reset action"
        case .connectionTitle: return "Title"
        case .connectionServerHeader: return "Server header"
        case .connectionURL: return "URL field"
        case .connectionToken: return "Token field"
        case .connectionConnect: return "Connect action"
        case .connectionLiveHeader: return "Live header"
        case .connectionStatusConnecting: return "Connecting"
        case .connectionStatusConnected: return "Connected"
        case .connectionStatusFailed: return "Failed"
        case .connectionStatusDisconnected: return "Disconnected"
        case .connectionStatusInvalidURL: return "Invalid URL"
        case .connectionEventNoContent: return "No content"
        case .captureWarningTitle: return "Chat list title while capture is down"
        case .editHistoryMenuItem: return "Menu item"
        case .editHistoryTitle: return "Title"
        case .editHistoryPreviousHeader: return "Previous header"
        case .editHistoryPreviousHeaderWithBadge: return "Previous (badge)"
        case .editHistoryCurrentHeader: return "Current header"
        case .mediaPhoto: return "Photo"
        case .mediaVideo: return "Video"
        case .mediaVoice: return "Voice"
        case .mediaRound: return "Round video"
        case .mediaAudio: return "Audio"
        case .mediaGif: return "GIF"
        case .mediaFile: return "File"
        case .mediaGeneric: return "Generic"
        case .mediaSkippedNote: return "Skipped note"
        case .hubMassDeleteHeader: return "Section header"
        case .hubMassDeleteThreshold: return "Threshold row"
        case .hubMassDeleteNever: return "Never value"
        case .hubMassDeleteInfo: return "Section footnote"
        case .massDeletePlaque: return "Summary message"
        case .massDeleteShowAll: return "Summary link"
        case .massDeleteTitle: return "Screen title"
        case .massDeleteHeader: return "List header"
        case .massDeleteFromMe: return "Own message"
        case .massDeleteRestore: return "Restore action"
        case .massDeleteRestored: return "Restored label"
        case .massDeleteShowMore: return "Show more"
        case .massDeleteMissing: return "Missing batch"
        case .massDeleteCollapseExisting: return "Collapse existing"
        case .massDeleteCollapseExistingConfirm: return "Collapse confirm"
        case .massDeleteCollapseExistingNothing: return "Nothing to collapse"
        case .massDeleteCollapseExistingDone: return "Collapse done"
        case .hubRoundVideoHeader: return "Section header"
        case .hubRoundVideoInfinite: return "Record past one minute"
        case .hubRoundVideoInfo: return "Section footnote"
        case .shortcutGhostTitle: return "Title"
        case .shortcutGhostSubtitle: return "Subtitle"
        case .myProfileStatusGhost: return "Ghost status"
        }
    }

    public static func defaultText(_ key: IAyuStringKey) -> String {
        return IAyuStrings.defaults[key] ?? key.rawValue
    }

    /// The override the user typed, if any. Empty overrides are not stored, so this being
    /// nil means "showing the default".
    public static func override(_ key: IAyuStringKey) -> String? {
        IAyuStrings.lock.lock()
        defer { IAyuStrings.lock.unlock() }
        if IAyuStrings.cachedOverrides == nil {
            IAyuStrings.cachedOverrides =
                UserDefaults.standard.dictionary(forKey: IAyuStrings.overridesDefaultsKey) as? [String: String] ?? [:]
        }
        return IAyuStrings.cachedOverrides?[key.rawValue]
    }

    /// The text to display. Cached in memory because some of these are read per message
    /// while a chat scrolls, and hitting UserDefaults on every cell would be wasteful.
    public static func text(_ key: IAyuStringKey) -> String {
        if let override = IAyuStrings.override(key), !override.isEmpty {
            return override
        }
        return IAyuStrings.defaultText(key)
    }

    /// Same, with {token} substitution. Unknown tokens in the text are left alone, and a
    /// value whose token was deleted by the user simply doesn't appear — never a crash.
    public static func text(_ key: IAyuStringKey, _ values: [String: String]) -> String {
        var result = IAyuStrings.text(key)
        for (token, value) in values {
            result = result.replacingOccurrences(of: "{\(token)}", with: value)
        }
        return result
    }

    /// Store an override. Empty (or identical to the default) removes it, so the row falls
    /// back to the default instead of persisting a copy that would never track future
    /// changes to it.
    public static func setOverride(_ key: IAyuStringKey, _ value: String) {
        IAyuStrings.lock.lock()
        var overrides = IAyuStrings.cachedOverrides
            ?? (UserDefaults.standard.dictionary(forKey: IAyuStrings.overridesDefaultsKey) as? [String: String] ?? [:])
        if value.isEmpty || value == IAyuStrings.defaultText(key) {
            overrides.removeValue(forKey: key.rawValue)
        } else {
            overrides[key.rawValue] = value
        }
        IAyuStrings.cachedOverrides = overrides
        IAyuStrings.lock.unlock()
        UserDefaults.standard.set(overrides, forKey: IAyuStrings.overridesDefaultsKey)
    }

    public static func resetAll() {
        IAyuStrings.lock.lock()
        IAyuStrings.cachedOverrides = [:]
        IAyuStrings.lock.unlock()
        UserDefaults.standard.removeObject(forKey: IAyuStrings.overridesDefaultsKey)
    }

    public static var hasOverrides: Bool {
        IAyuStrings.lock.lock()
        defer { IAyuStrings.lock.unlock() }
        if IAyuStrings.cachedOverrides == nil {
            IAyuStrings.cachedOverrides =
                UserDefaults.standard.dictionary(forKey: IAyuStrings.overridesDefaultsKey) as? [String: String] ?? [:]
        }
        return !(IAyuStrings.cachedOverrides?.isEmpty ?? true)
    }
}
