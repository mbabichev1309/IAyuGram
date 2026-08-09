import Foundation
import UIKit
import TelegramPresentationData
import DeviceAccess
import SGSimpleSettings

enum ApplicationShortcutItemType: String {
    case search
    case compose
    case camera
    case savedMessages
    case account
    case appIcon
    case iAyuGhostMode
}

/// Turn every ghost signal on at once — the same set as the master switch in Settings.
///
/// The whole point of the Home-screen quick action is to enter the app with ghost
/// ALREADY forced, so this must run before the account announces itself online:
/// once presence has gone online, last-seen is bumped and enabling ghost afterwards
/// no longer hides that you opened the app.
func iAyuForceGhostModeOn() {
    // Locked signals are left alone here too. A lock is the user saying "this one is
    // mine to set", and honouring it only in Settings while the quick action overrode it
    // would make the lock unreliable in exactly the situation it is used for.
    // Invisible send is not included: it is no longer part of ghost mode.
    IAyuGhost.setAll(true)
}

struct ApplicationShortcutItem: Equatable {
    let type: ApplicationShortcutItemType
    let title: String
    let subtitle: String?
}

@available(iOS 9.1, *)
extension ApplicationShortcutItem {
    func shortcutItem() -> UIApplicationShortcutItem {
        let icon: UIApplicationShortcutIcon
        switch self.type {
            case .search:
                icon = UIApplicationShortcutIcon(type: .search)
            case .compose:
                icon = UIApplicationShortcutIcon(type: .compose)
            case .camera:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/Camera")
            case .savedMessages:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/SavedMessages")
            case .account:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/Account")
            case .appIcon:
                icon = UIApplicationShortcutIcon(templateImageName: "Shortcuts/AppIcon")
            case .iAyuGhostMode:
                icon = UIApplicationShortcutIcon(type: .prohibit)
        }
        return UIApplicationShortcutItem(type: self.type.rawValue, localizedTitle: self.title, localizedSubtitle: self.subtitle, icon: icon, userInfo: nil)
    }
}

func applicationShortcutItems(strings: PresentationStrings, otherAccountName: String?) -> [ApplicationShortcutItem] {
    // iOS shows at most 4 quick actions, so ghost mode takes the slot of the least
    // useful one: "Change app icon" (also reachable from Appearance), or, when a second
    // account exists, Saved Messages — switching account is the point of that menu.
    let ghost = ApplicationShortcutItem(
        type: .iAyuGhostMode,
        title: IAyuStrings.text(.shortcutGhostTitle),
        subtitle: IAyuStrings.text(.shortcutGhostSubtitle)
    )
    if let otherAccountName = otherAccountName {
        return [
            ghost,
            ApplicationShortcutItem(type: .search, title: strings.Common_Search, subtitle: nil),
            ApplicationShortcutItem(type: .compose, title: strings.Compose_NewMessage, subtitle: nil),
            ApplicationShortcutItem(type: .account, title: strings.Shortcut_SwitchAccount, subtitle: otherAccountName)
        ]
    } else {
        return [
            ghost,
            ApplicationShortcutItem(type: .search, title: strings.Common_Search, subtitle: nil),
            ApplicationShortcutItem(type: .compose, title: strings.Compose_NewMessage, subtitle: nil),
            ApplicationShortcutItem(type: .savedMessages, title: strings.Conversation_SavedMessages, subtitle: nil)
        ]
    }
}
