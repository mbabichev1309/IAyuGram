import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGSimpleSettings

// IAyuGram → "Localization": every string IAyuGram adds to the app, editable on the
// device. The app ships English only and our additions never went through a .strings
// pipeline, so this screen is the translation mechanism. Values live in IAyuStrings
// (SGSimpleSettings) and are read wherever the string is used; an empty field means
// "use the default", which is shown as the field's placeholder.

private final class IAyuLocalizationArguments {
    let updateString: (IAyuStringKey, String) -> Void
    let resetAll: () -> Void

    init(updateString: @escaping (IAyuStringKey, String) -> Void, resetAll: @escaping () -> Void) {
        self.updateString = updateString
        self.resetAll = resetAll
    }
}

private enum IAyuLocalizationEntry: ItemListNodeEntry {
    // The ids are carried rather than derived: the list is generated from
    // IAyuStrings.groups, so a new string must not force a hand-written switch to grow.
    case info(Int32, Int32, String)
    case header(Int32, Int32, String)
    case string(Int32, Int32, IAyuStringKey, String)
    case reset(Int32, Int32, String)

    var section: ItemListSectionId {
        switch self {
        case let .info(_, section, _), let .header(_, section, _),
             let .string(_, section, _, _), let .reset(_, section, _):
            return section
        }
    }

    var stableId: Int32 {
        switch self {
        case let .info(id, _, _), let .header(id, _, _),
             let .string(id, _, _, _), let .reset(id, _, _):
            return id
        }
    }

    static func <(lhs: IAyuLocalizationEntry, rhs: IAyuLocalizationEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: IAyuLocalizationEntry, rhs: IAyuLocalizationEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.info(a1, a2, a3), .info(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.header(a1, a2, a3), .header(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.string(a1, a2, a3, a4), .string(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.reset(a1, a2, a3), .reset(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! IAyuLocalizationArguments
        switch self {
        case let .info(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(_, _, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .string(_, _, key, value):
            return iAyuTextFieldItem(
                presentationData: presentationData,
                title: IAyuStrings.editorLabel(key),
                value: value,
                placeholder: IAyuStrings.defaultText(key),
                sectionId: self.section,
                textUpdated: { text in
                    arguments.updateString(key, text)
                }
            )
        case let .reset(_, _, text):
            return ItemListActionItem(presentationData: presentationData, title: text, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.resetAll()
            })
        }
    }
}

private struct IAyuLocalizationState: Equatable {
    // Only the strings that differ from their default; everything else renders empty and
    // shows the default as a placeholder.
    var overrides: [String: String]
}

public func iAyuGramLocalizationController(context: AccountContext) -> ViewController {
    var initialOverrides: [String: String] = [:]
    for key in IAyuStringKey.allCases {
        if let override = IAyuStrings.override(key) {
            initialOverrides[key.rawValue] = override
        }
    }
    let initialState = IAyuLocalizationState(overrides: initialOverrides)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuLocalizationState) -> IAyuLocalizationState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let arguments = IAyuLocalizationArguments(updateString: { key, text in
        IAyuStrings.setOverride(key, text)
        updateState { state in
            var state = state
            if text.isEmpty {
                state.overrides.removeValue(forKey: key.rawValue)
            } else {
                state.overrides[key.rawValue] = text
            }
            return state
        }
    }, resetAll: {
        IAyuStrings.resetAll()
        updateState { state in
            var state = state
            state.overrides = [:]
            return state
        }
    })

    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
    |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [IAyuLocalizationEntry] = []
        var id: Int32 = 0
        var section: Int32 = 0

        entries.append(.info(id, section, IAyuStrings.text(.localizationInfo)))
        id += 1
        section += 1

        for group in IAyuStrings.groups {
            entries.append(.header(id, section, group.title))
            id += 1
            for key in group.keys {
                entries.append(.string(id, section, key, state.overrides[key.rawValue] ?? ""))
                id += 1
            }
            section += 1
        }

        entries.append(.reset(id, section, IAyuStrings.text(.localizationReset)))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(IAyuStrings.text(.localizationTitle)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}
