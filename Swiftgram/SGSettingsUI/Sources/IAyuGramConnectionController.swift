import Foundation
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGSimpleSettings

// IAyuGram → "Connection keys": companion-server URL + client token, and a live
// test that opens the /live WebSocket and shows incoming events. The real always-on
// sync is owned by IAyuSyncManager; this screen only edits the keys and verifies them.

private final class IAyuConnectionArguments {
    let updateServerURL: (String) -> Void
    let updateToken: (String) -> Void
    let connectLive: () -> Void

    init(updateServerURL: @escaping (String) -> Void, updateToken: @escaping (String) -> Void, connectLive: @escaping () -> Void) {
        self.updateServerURL = updateServerURL
        self.updateToken = updateToken
        self.connectLive = connectLive
    }
}

private enum IAyuConnectionSection: Int32 {
    case connection
    case live
}

private enum IAyuConnectionEntry: ItemListNodeEntry {
    case connectionHeader(String)
    case serverURL(String, String)
    case token(String, String)
    case connect(String)
    case status(String)
    case liveHeader(String)
    case event(Int, String)

    var section: ItemListSectionId {
        switch self {
        case .connectionHeader, .serverURL, .token, .connect, .status:
            return IAyuConnectionSection.connection.rawValue
        case .liveHeader, .event:
            return IAyuConnectionSection.live.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .connectionHeader: return 0
        case .serverURL: return 1
        case .token: return 2
        case .connect: return 3
        case .status: return 4
        case .liveHeader: return 5
        case let .event(index, _): return 100 + Int32(index)
        }
    }

    static func <(lhs: IAyuConnectionEntry, rhs: IAyuConnectionEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: IAyuConnectionEntry, rhs: IAyuConnectionEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.connectionHeader(a), .connectionHeader(b)):
            return a == b
        case let (.serverURL(a1, a2), .serverURL(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.token(a1, a2), .token(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.connect(a), .connect(b)):
            return a == b
        case let (.status(a), .status(b)):
            return a == b
        case let (.liveHeader(a), .liveHeader(b)):
            return a == b
        case let (.event(a1, a2), .event(b1, b2)):
            return a1 == b1 && a2 == b2
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! IAyuConnectionArguments
        switch self {
        case let .connectionHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .serverURL(title, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: title), text: value, placeholder: "https://…ts.net", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { text in
                arguments.updateServerURL(text)
            }, action: {})
        case let .token(title, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: title), text: value, placeholder: "client token", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { text in
                arguments.updateToken(text)
            }, action: {})
        case let .connect(title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.connectLive()
            })
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .liveHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .event(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct IAyuConnectionState: Equatable {
    var serverURL: String
    var token: String
    var status: String
    var events: [IAyuMessageEvent]
}

private func iAyuConnectionEventDescription(_ event: IAyuMessageEvent) -> String {
    let content = event.text ?? "<no content>"
    return "\(event.kind) #\(event.messageId): \(content)"
}

public func iAyuGramConnectionController(context: AccountContext) -> ViewController {
    let initialState = IAyuConnectionState(
        serverURL: SGSimpleSettings.shared.iaSyncServerURL,
        token: SGSimpleSettings.shared.iaSyncClientToken,
        status: "",
        events: []
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuConnectionState) -> IAyuConnectionState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let sessionBox = IAyuSessionBox()

    let arguments = IAyuConnectionArguments(updateServerURL: { text in
        updateState { state in
            var state = state
            state.serverURL = text
            return state
        }
    }, updateToken: { text in
        updateState { state in
            var state = state
            state.token = text
            return state
        }
    }, connectLive: {
        let current = stateValue.with { $0 }
        SGSimpleSettings.shared.iaSyncServerURL = current.serverURL
        SGSimpleSettings.shared.iaSyncClientToken = current.token
        sessionBox.session?.stop()
        updateState { state in
            var state = state
            state.events = []
            state.status = "Live: connecting…"
            return state
        }
        sessionBox.session = IAyuLiveSession(serverURL: current.serverURL, token: current.token, onEvent: { event in
            // Viewer only — the app-launch IAyuSyncManager owns materialization.
            updateState { state in
                var state = state
                state.events.insert(event, at: 0)
                if state.events.count > 20 {
                    state.events.removeLast(state.events.count - 20)
                }
                return state
            }
        }, onStatus: { status in
            updateState { state in
                var state = state
                state.status = status
                return state
            }
        })
        if sessionBox.session == nil {
            updateState { state in
                var state = state
                state.status = "Live: invalid URL"
                return state
            }
        }
    })

    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
    |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [IAyuConnectionEntry] = []
        entries.append(.connectionHeader("COMPANION SERVER"))
        entries.append(.serverURL("URL", state.serverURL))
        entries.append(.token("Token", state.token))
        entries.append(.connect("Save & Connect (live)"))
        if !state.status.isEmpty {
            entries.append(.status(state.status))
        }
        if !state.events.isEmpty {
            entries.append(.liveHeader("LIVE EVENTS"))
            for (index, event) in state.events.enumerated() {
                entries.append(.event(index, iAyuConnectionEventDescription(event)))
            }
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Connection keys"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    // sessionBox is retained through `arguments` for the controller's lifetime; the
    // WebSocket is cancelled when the screen is dismissed and the controller released.
    return ItemListController(context: context, state: signal)
}
