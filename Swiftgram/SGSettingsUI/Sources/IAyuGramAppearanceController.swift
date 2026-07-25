import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGSimpleSettings

// Retains the color-picker delegate for the picker's lifetime (delegate is weak).
private final class IAyuObjectHolder {
    var object: AnyObject?
}

@available(iOS 14.0, *)
private final class IAyuColorPickerDelegate: NSObject, UIColorPickerViewControllerDelegate {
    private let onPick: (UIColor) -> Void
    init(onPick: @escaping (UIColor) -> Void) {
        self.onPick = onPick
        super.init()
    }
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        self.onPick(viewController.selectedColor)
    }
}

private func iAyuRGBValue(from color: UIColor) -> Int32 {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    let ri = Int32(max(0.0, min(255.0, r * 255.0)))
    let gi = Int32(max(0.0, min(255.0, g * 255.0)))
    let bi = Int32(max(0.0, min(255.0, b * 255.0)))
    return (ri << 16) | (gi << 8) | bi
}

private func iAyuHexString(_ rgb: Int32) -> String {
    return String(format: "%06X", UInt32(truncatingIfNeeded: rgb) & 0xffffff)
}

// IAyuGram → "Appearance": user-editable labels for preserved messages and how the
// edit-history screen shows text. All values persist in SGSimpleSettings and are
// read at render time (deleted badge in ChatMessageDateAndStatusNode, edited badge
// and date toggle in the edit-history screen).

private final class IAyuAppearanceArguments {
    let updateDeletedBadge: (String) -> Void
    let updateEditedBadge: (String) -> Void
    let toggleTintDeleted: (Bool) -> Void
    let pickTintColor: () -> Void
    let toggleShowDates: (Bool) -> Void

    init(updateDeletedBadge: @escaping (String) -> Void, updateEditedBadge: @escaping (String) -> Void, toggleTintDeleted: @escaping (Bool) -> Void, pickTintColor: @escaping () -> Void, toggleShowDates: @escaping (Bool) -> Void) {
        self.updateDeletedBadge = updateDeletedBadge
        self.updateEditedBadge = updateEditedBadge
        self.toggleTintDeleted = toggleTintDeleted
        self.pickTintColor = pickTintColor
        self.toggleShowDates = toggleShowDates
    }
}

private enum IAyuAppearanceSection: Int32 {
    case badges
    case editHistory
}

private enum IAyuAppearanceEntry: ItemListNodeEntry {
    case badgesHeader(String)
    case deletedBadge(String, String)
    case editedBadge(String, String)
    case badgesInfo(String)
    case tintDeleted(String, Bool)
    case tintColor(String, Int32)
    case editHistoryHeader(String)
    case showDates(String, Bool)

    var section: ItemListSectionId {
        switch self {
        case .badgesHeader, .deletedBadge, .editedBadge, .badgesInfo, .tintDeleted, .tintColor:
            return IAyuAppearanceSection.badges.rawValue
        case .editHistoryHeader, .showDates:
            return IAyuAppearanceSection.editHistory.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .badgesHeader: return 0
        case .deletedBadge: return 1
        case .editedBadge: return 2
        case .badgesInfo: return 3
        case .tintDeleted: return 4
        case .tintColor: return 5
        case .editHistoryHeader: return 6
        case .showDates: return 7
        }
    }

    static func <(lhs: IAyuAppearanceEntry, rhs: IAyuAppearanceEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: IAyuAppearanceEntry, rhs: IAyuAppearanceEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.badgesHeader(a), .badgesHeader(b)):
            return a == b
        case let (.deletedBadge(a1, a2), .deletedBadge(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.editedBadge(a1, a2), .editedBadge(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.badgesInfo(a), .badgesInfo(b)):
            return a == b
        case let (.tintDeleted(a1, a2), .tintDeleted(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.tintColor(a1, a2), .tintColor(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.editHistoryHeader(a), .editHistoryHeader(b)):
            return a == b
        case let (.showDates(a1, a2), .showDates(b1, b2)):
            return a1 == b1 && a2 == b2
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! IAyuAppearanceArguments
        switch self {
        case let .badgesHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .deletedBadge(title, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: title), text: value, placeholder: "🗑 deleted", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { text in
                arguments.updateDeletedBadge(text)
            }, action: {})
        case let .editedBadge(title, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: title), text: value, placeholder: "✏️ edited", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { text in
                arguments.updateEditedBadge(text)
            }, action: {})
        case let .badgesInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .tintDeleted(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleTintDeleted(newValue)
            })
        case let .tintColor(title, rgb):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "#\(iAyuHexString(rgb))", sectionId: self.section, style: .blocks, action: {
                arguments.pickTintColor()
            })
        case let .editHistoryHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .showDates(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleShowDates(newValue)
            })
        }
    }
}

private struct IAyuAppearanceState: Equatable {
    var deletedBadge: String
    var editedBadge: String
    var tintDeleted: Bool
    var tintColorRGB: Int32
    var showDates: Bool
}

public func iAyuGramAppearanceController(context: AccountContext) -> ViewController {
    let initialState = IAyuAppearanceState(
        deletedBadge: SGSimpleSettings.shared.iaDeletedBadge,
        editedBadge: SGSimpleSettings.shared.iaEditedBadge,
        tintDeleted: SGSimpleSettings.shared.iaTintDeleted,
        tintColorRGB: SGSimpleSettings.shared.iaTintColorRGB,
        showDates: SGSimpleSettings.shared.iaEditHistoryShowDates
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuAppearanceState) -> IAyuAppearanceState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    var presentImpl: ((UIViewController) -> Void)?
    let colorPickerHolder = IAyuObjectHolder()

    let arguments = IAyuAppearanceArguments(updateDeletedBadge: { text in
        SGSimpleSettings.shared.iaDeletedBadge = text
        updateState { state in
            var state = state
            state.deletedBadge = text
            return state
        }
    }, updateEditedBadge: { text in
        SGSimpleSettings.shared.iaEditedBadge = text
        updateState { state in
            var state = state
            state.editedBadge = text
            return state
        }
    }, toggleTintDeleted: { value in
        SGSimpleSettings.shared.iaTintDeleted = value
        updateState { state in
            var state = state
            state.tintDeleted = value
            return state
        }
    }, pickTintColor: {
        guard #available(iOS 14.0, *) else {
            return
        }
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        let currentRGB = UInt32(truncatingIfNeeded: SGSimpleSettings.shared.iaTintColorRGB) & 0xffffff
        picker.selectedColor = UIColor(rgb: currentRGB)
        let delegate = IAyuColorPickerDelegate(onPick: { color in
            let rgb = iAyuRGBValue(from: color)
            SGSimpleSettings.shared.iaTintColorRGB = rgb
            updateState { state in
                var state = state
                state.tintColorRGB = rgb
                return state
            }
        })
        colorPickerHolder.object = delegate
        picker.delegate = delegate
        presentImpl?(picker)
    }, toggleShowDates: { value in
        SGSimpleSettings.shared.iaEditHistoryShowDates = value
        updateState { state in
            var state = state
            state.showDates = value
            return state
        }
    })

    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
    |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [IAyuAppearanceEntry] = []
        entries.append(.badgesHeader("MESSAGE BADGES"))
        entries.append(.deletedBadge("Deleted", state.deletedBadge))
        entries.append(.editedBadge("Edited", state.editedBadge))
        entries.append(.badgesInfo("Shown on preserved messages. Leave empty to hide the label."))
        entries.append(.tintDeleted("Tint deleted messages", state.tintDeleted))
        entries.append(.tintColor("Tint color", state.tintColorRGB))
        entries.append(.editHistoryHeader("EDIT HISTORY"))
        entries.append(.showDates("Show version dates", state.showDates))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Appearance"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] viewController in
        controller?.view.window?.rootViewController?.present(viewController, animated: true, completion: nil)
    }
    return controller
}
