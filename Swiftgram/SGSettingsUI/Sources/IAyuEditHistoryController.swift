import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGSimpleSettings

// IAyuGram: read-only "Edit history" screen for a single message. Lists the
// captured previous versions (oldest first) followed by the current text. Opened
// from the message context menu when the side store has versions for the message.

private enum IAyuEditHistorySection: Int32 {
    case previous
    case current
}

private enum IAyuEditHistoryEntry: ItemListNodeEntry {
    case previousHeader(String)
    case previous(Int, String)
    case currentHeader(String)
    case current(String)

    var section: ItemListSectionId {
        switch self {
        case .previousHeader, .previous:
            return IAyuEditHistorySection.previous.rawValue
        case .currentHeader, .current:
            return IAyuEditHistorySection.current.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .previousHeader:
            return 0
        case let .previous(index, _):
            return 1 + Int32(index)
        case .currentHeader:
            return 1_000_000
        case .current:
            return 1_000_001
        }
    }

    static func <(lhs: IAyuEditHistoryEntry, rhs: IAyuEditHistoryEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: IAyuEditHistoryEntry, rhs: IAyuEditHistoryEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.previousHeader(a), .previousHeader(b)):
            return a == b
        case let (.previous(a1, a2), .previous(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.currentHeader(a), .currentHeader(b)):
            return a == b
        case let (.current(a), .current(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .previousHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .previous(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .currentHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .current(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

public func iAyuEditHistoryController(context: AccountContext, versions: [IAyuEditVersion], currentText: String) -> ViewController {
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let showDates = SGSimpleSettings.shared.iaEditHistoryShowDates
        let editedBadge = SGSimpleSettings.shared.iaEditedBadge
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        var entries: [IAyuEditHistoryEntry] = []
        if !versions.isEmpty {
            let header = editedBadge.isEmpty
                ? IAyuStrings.text(.editHistoryPreviousHeader)
                : IAyuStrings.text(.editHistoryPreviousHeaderWithBadge, ["badge": editedBadge])
            entries.append(.previousHeader(header))
            for (index, version) in versions.enumerated() {
                var text = version.text
                if showDates && version.date > 0 {
                    let dateString = dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(version.date)))
                    text = "\(dateString)\n\(version.text)"
                }
                entries.append(.previous(index, text))
            }
        }
        entries.append(.currentHeader(IAyuStrings.text(.editHistoryCurrentHeader)))
        entries.append(.current(currentText))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(IAyuStrings.text(.editHistoryTitle)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, IAyuEditHistoryEmptyArguments()))
    }

    return ItemListController(context: context, state: signal)
}

// ItemListController threads an `arguments: Any` value through to each entry; this
// screen is static and needs none, but the type must be non-nil.
private final class IAyuEditHistoryEmptyArguments {
}
