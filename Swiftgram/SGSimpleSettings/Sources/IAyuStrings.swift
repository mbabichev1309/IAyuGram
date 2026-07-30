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
    case hubGhostInvisibleSend
    case hubGhostInfo
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
        .hubGhostInvisibleSend: "Invisible send",
        .hubGhostInfo: "Others won't see your read receipts, online status, typing, or when you play their voice/video messages. Invisible send delays your messages ~12s (sent as scheduled) so sending doesn't show you online — expect the ~12s delay.",
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

        .shortcutGhostTitle: "Ghost mode",
        .shortcutGhostSubtitle: "Enter with all signals hidden",

        .myProfileStatusGhost: "Offline (ghost mode)"
    ]

    /// Human-readable grouping for the Localization screen, in display order.
    public static let groups: [(title: String, keys: [IAyuStringKey])] = [
        ("SETTINGS LIST", [.settingsGhostSwitch, .settingsRow]),
        ("HUB", [.hubTitle, .hubGhostHeader, .hubGhostHideReadReceipts, .hubGhostStayOffline,
                 .hubGhostHideTyping, .hubGhostHideConsumed, .hubGhostInvisibleSend,
                 .hubGhostInfo, .hubAppearance, .hubLocalization, .hubConnection]),
        ("APPEARANCE", [.appearanceTitle, .appearanceBadgesHeader, .appearanceDeletedBadge,
                        .appearanceEditedBadge, .appearanceBadgesInfo, .appearanceTintDeleted,
                        .appearanceTintColor, .appearanceEditHistoryHeader, .appearanceShowDates]),
        ("LOCALIZATION", [.localizationTitle, .localizationInfo, .localizationReset]),
        ("CONNECTION", [.connectionTitle, .connectionServerHeader, .connectionURL, .connectionToken,
                        .connectionConnect, .connectionLiveHeader, .connectionStatusConnecting,
                        .connectionStatusConnected, .connectionStatusFailed,
                        .connectionStatusDisconnected, .connectionStatusInvalidURL,
                        .connectionEventNoContent]),
        ("EDIT HISTORY", [.editHistoryMenuItem, .editHistoryTitle, .editHistoryPreviousHeader,
                          .editHistoryPreviousHeaderWithBadge, .editHistoryCurrentHeader]),
        ("PRESERVED MEDIA", [.mediaPhoto, .mediaVideo, .mediaVoice, .mediaRound, .mediaAudio,
                             .mediaGif, .mediaFile, .mediaGeneric, .mediaSkippedNote]),
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
        case .hubGhostInvisibleSend: return "Invisible send"
        case .hubGhostInfo: return "Ghost footnote"
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
