import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGSimpleSettings

// IAyuGram → "Appearance": user-editable labels for preserved messages and how the
// edit-history screen shows text. All values persist in SGSimpleSettings and are
// read at render time (deleted badge in ChatMessageDateAndStatusNode, edited badge
// and date toggle in the edit-history screen).

private final class IAyuAppearanceArguments {
    let updateDeletedBadge: (String) -> Void
    let updateEditedBadge: (String) -> Void
    let toggleTintDeleted: (Bool) -> Void
    let toggleShowDates: (Bool) -> Void

    init(updateDeletedBadge: @escaping (String) -> Void, updateEditedBadge: @escaping (String) -> Void, toggleTintDeleted: @escaping (Bool) -> Void, toggleShowDates: @escaping (Bool) -> Void) {
        self.updateDeletedBadge = updateDeletedBadge
        self.updateEditedBadge = updateEditedBadge
        self.toggleTintDeleted = toggleTintDeleted
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
    case editHistoryHeader(String)
    case showDates(String, Bool)

    var section: ItemListSectionId {
        switch self {
        case .badgesHeader, .deletedBadge, .editedBadge, .badgesInfo, .tintDeleted:
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
        case .editHistoryHeader: return 5
        case .showDates: return 6
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
    var showDates: Bool
}

public func iAyuGramAppearanceController(context: AccountContext) -> ViewController {
    let initialState = IAyuAppearanceState(
        deletedBadge: SGSimpleSettings.shared.iaDeletedBadge,
        editedBadge: SGSimpleSettings.shared.iaEditedBadge,
        tintDeleted: SGSimpleSettings.shared.iaTintDeleted,
        showDates: SGSimpleSettings.shared.iaEditHistoryShowDates
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuAppearanceState) -> IAyuAppearanceState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

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
        entries.append(.editHistoryHeader("EDIT HISTORY"))
        entries.append(.showDates("Show version dates", state.showDates))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Appearance"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}
