import Foundation
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGSimpleSettings

// IAyuGram — per-chat exceptions, opened from a chat's "..." menu.
//
// Ghost mode and preservation are global switches; this screen is the escape hatch for
// one conversation. The flags live in IAyuPeerExceptions (UserDefaults) because the
// readers are spread across TelegramCore's signal seams and the sync manager.

private final class IAyuChatExceptionsArguments {
    let toggleGhostDisabled: (Bool) -> Void
    let togglePreservationDisabled: (Bool) -> Void

    init(toggleGhostDisabled: @escaping (Bool) -> Void, togglePreservationDisabled: @escaping (Bool) -> Void) {
        self.toggleGhostDisabled = toggleGhostDisabled
        self.togglePreservationDisabled = togglePreservationDisabled
    }
}

private enum IAyuChatExceptionsSection: Int32 {
    case ghost
    case preservation
}

private enum IAyuChatExceptionsEntry: ItemListNodeEntry {
    case ghostDisabled(String, Bool)
    case ghostInfo(String)
    case preservationDisabled(String, Bool)
    case preservationInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .ghostDisabled, .ghostInfo:
            return IAyuChatExceptionsSection.ghost.rawValue
        case .preservationDisabled, .preservationInfo:
            return IAyuChatExceptionsSection.preservation.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .ghostDisabled: return 0
        case .ghostInfo: return 1
        case .preservationDisabled: return 2
        case .preservationInfo: return 3
        }
    }

    static func <(lhs: IAyuChatExceptionsEntry, rhs: IAyuChatExceptionsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: IAyuChatExceptionsEntry, rhs: IAyuChatExceptionsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.ghostDisabled(a1, a2), .ghostDisabled(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.ghostInfo(a), .ghostInfo(b)):
            return a == b
        case let (.preservationDisabled(a1, a2), .preservationDisabled(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.preservationInfo(a), .preservationInfo(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! IAyuChatExceptionsArguments
        switch self {
        case let .ghostDisabled(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleGhostDisabled(newValue)
            })
        case let .ghostInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .preservationDisabled(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.togglePreservationDisabled(newValue)
            })
        case let .preservationInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct IAyuChatExceptionsState: Equatable {
    var ghostDisabled: Bool
    var preservationDisabled: Bool
}

public func iAyuChatExceptionsController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let key = peerId.toInt64()
    let initialState = IAyuChatExceptionsState(
        ghostDisabled: IAyuPeerExceptions.shared.isSet(.ghostDisabled, peerId: key),
        preservationDisabled: IAyuPeerExceptions.shared.isSet(.preservationDisabled, peerId: key)
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuChatExceptionsState) -> IAyuChatExceptionsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let arguments = IAyuChatExceptionsArguments(toggleGhostDisabled: { value in
        IAyuPeerExceptions.shared.set(.ghostDisabled, peerId: key, value: value)
        updateState { state in
            var state = state
            state.ghostDisabled = value
            return state
        }
    }, togglePreservationDisabled: { value in
        IAyuPeerExceptions.shared.set(.preservationDisabled, peerId: key, value: value)
        updateState { state in
            var state = state
            state.preservationDisabled = value
            return state
        }
    })

    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
    |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [IAyuChatExceptionsEntry] = []
        entries.append(.ghostDisabled(IAyuStrings.text(.chatExceptionsGhostDisabled), state.ghostDisabled))
        entries.append(.ghostInfo(IAyuStrings.text(.chatExceptionsGhostInfo)))
        entries.append(.preservationDisabled(IAyuStrings.text(.chatExceptionsPreservationDisabled), state.preservationDisabled))
        entries.append(.preservationInfo(IAyuStrings.text(.chatExceptionsPreservationInfo)))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(IAyuStrings.text(.chatExceptionsTitle)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}
