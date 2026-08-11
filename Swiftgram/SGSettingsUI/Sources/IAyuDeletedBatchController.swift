import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import ItemListUI
import TextFormat
import PresentationDataUtils
import AccountContext
import SGSimpleSettings

// IAyuGram: the messages of one collapsed mass deletion. Reached by tapping the summary
// message a wiped chat leaves behind; the contents come from IAyuDeletedBatchStore, not
// from the chat, because putting a few hundred synthetic messages back into the history
// is exactly what this feature exists to avoid. Any single one of them can still be
// restored into the chat from here.

private let iAyuDeletedBatchPageSize = 100

private struct IAyuDeletedBatchState: Equatable {
    var names: [Int64: String]
    // By position in the batch — see IAyuDeletedBatchStore.restoredIndices.
    var restored: Set<Int>
    var limit: Int
}

private final class IAyuDeletedBatchArguments {
    let restore: (Int, IAyuMessageEvent) -> Void
    let showMore: () -> Void

    init(restore: @escaping (Int, IAyuMessageEvent) -> Void, showMore: @escaping () -> Void) {
        self.restore = restore
        self.showMore = showMore
    }
}

private enum IAyuDeletedBatchSection: Int32 {
    case messages
}

private enum IAyuDeletedBatchEntry: ItemListNodeEntry {
    case header(String)
    // index into the batch, the row's text, whether it has already been restored, and
    // the event itself so the row can act on it.
    case message(Int32, String, Bool, IAyuMessageEvent)
    case showMore(String)
    case missing(String)

    var section: ItemListSectionId {
        return IAyuDeletedBatchSection.messages.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case let .message(index, _, _, _):
            return 1 + index
        case .showMore:
            return 1_000_000
        case .missing:
            return 1_000_001
        }
    }

    static func <(lhs: IAyuDeletedBatchEntry, rhs: IAyuDeletedBatchEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: IAyuDeletedBatchEntry, rhs: IAyuDeletedBatchEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a), .header(b)):
            return a == b
        case let (.message(a1, a2, a3, a4), .message(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.showMore(a), .showMore(b)):
            return a == b
        case let (.missing(a), .missing(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! IAyuDeletedBatchArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .message(index, text, restored, event):
            return ItemListMultilineTextItem(
                presentationData: presentationData,
                text: text,
                enabledEntityTypes: [],
                sectionId: self.section,
                style: .blocks,
                // A restored message has nowhere left to go: it is in the chat.
                action: restored ? nil : {
                    arguments.restore(Int(index), event)
                }
            )
        case let .showMore(text):
            return ItemListActionItem(presentationData: presentationData, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.showMore()
            })
        case let .missing(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

public func iAyuDeletedBatchController(context: AccountContext, url: String) -> ViewController? {
    guard let key = iAyuMassDeleteBatchKey(fromURL: url) else {
        return nil
    }
    return iAyuDeletedBatchController(context: context, key: key)
}

func iAyuDeletedBatchController(context: AccountContext, key: IAyuDeletedBatchKey) -> ViewController {
    // Bounded by the batch cap, so this is a few hundred short lines — read once, when
    // the screen opens, rather than per row.
    let events = IAyuDeletedBatchStore.shared.events(key: key)

    let initialState = IAyuDeletedBatchState(
        names: [:],
        restored: IAyuDeletedBatchStore.shared.restoredIndices(key: key),
        limit: iAyuDeletedBatchPageSize
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuDeletedBatchState) -> IAyuDeletedBatchState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var presentControllerImpl: ((ViewController) -> Void)?

    // Senders are stored as ids; the names have to be looked up, and a group message's
    // author may be someone this database has never otherwise seen — those keep the id's
    // absence rather than inventing a name.
    let senderIds = Set(events.compactMap { $0.senderId })
    if !senderIds.isEmpty {
        let _ = (context.account.postbox.transaction { transaction -> [Int64: String] in
            var names: [Int64: String] = [:]
            for senderId in senderIds {
                if let peer = transaction.getPeer(iAyuPeerId(fromServerChatId: senderId)) {
                    names[senderId] = peer.debugDisplayTitle
                }
            }
            return names
        }
        |> deliverOnMainQueue).start(next: { names in
            updateState { state in
                var state = state
                state.names = names
                return state
            }
        })
    }

    let arguments = IAyuDeletedBatchArguments(restore: { index, event in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var dismissImpl: (() -> Void)?
        let actionSheet = ActionSheetController(presentationData: presentationData)
        dismissImpl = { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: IAyuStrings.text(.massDeleteRestore), action: {
                    dismissImpl?()
                    // The normal materialization path: media included, download cap
                    // respected. The bytes were never fetched when the batch was
                    // collapsed, so this is where they arrive.
                    iAyuRestoreArchived(context: context, event: event)
                    IAyuDeletedBatchStore.shared.markRestored(key: key, index: index)
                    updateState { state in
                        var state = state
                        state.restored.insert(index)
                        return state
                    }
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: {
                    dismissImpl?()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }, showMore: {
        updateState { state in
            var state = state
            state.limit += iAyuDeletedBatchPageSize
            return state
        }
    })

    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
    |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        var entries: [IAyuDeletedBatchEntry] = []
        if events.isEmpty {
            entries.append(.missing(IAyuStrings.text(.massDeleteMissing)))
        } else {
            entries.append(.header(IAyuStrings.text(.massDeleteHeader, ["count": "\(events.count)"])))
            for (index, event) in events.prefix(state.limit).enumerated() {
                let restored = state.restored.contains(index)
                entries.append(.message(
                    Int32(index),
                    iAyuDeletedBatchRowText(event: event, state: state, restored: restored, dateFormatter: dateFormatter),
                    restored,
                    event
                ))
            }
            if events.count > state.limit {
                entries.append(.showMore(IAyuStrings.text(.massDeleteShowMore)))
            }
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(IAyuStrings.text(.massDeleteTitle)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}

// One row: who and when on the first line, then the message itself — its text, or a
// label naming the media it was, since a collapsed batch downloads nothing.
private func iAyuDeletedBatchRowText(event: IAyuMessageEvent, state: IAyuDeletedBatchState, restored: Bool, dateFormatter: DateFormatter) -> String {
    var head: [String] = []
    if event.fromMe == true {
        head.append(IAyuStrings.text(.massDeleteFromMe))
    } else if let senderId = event.senderId, let name = state.names[senderId] {
        head.append(name)
    }
    if let date = event.date, date > 0 {
        head.append(dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(date))))
    }
    if restored {
        head.append(IAyuStrings.text(.massDeleteRestored))
    }

    var body: [String] = []
    if let kind = event.mediaKind, !kind.isEmpty {
        body.append("[\(iAyuMediaKindLabel(kind: kind, fileName: event.mediaFileName))]")
    }
    if let text = event.text, !text.isEmpty {
        body.append(text)
    }
    if body.isEmpty {
        body.append(IAyuStrings.text(.connectionEventNoContent))
    }

    let header = head.joined(separator: " · ")
    return header.isEmpty ? body.joined(separator: " ") : "\(header)\n\(body.joined(separator: " "))"
}
