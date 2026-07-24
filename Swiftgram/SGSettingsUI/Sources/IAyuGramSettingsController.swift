import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGSimpleSettings

// IAyuGram settings hub. Phase 1: the "Connection" section — the URL + token of
// the companion capture server, plus a live "Test connection" that opens a
// WebSocket to /live and reports success/failure right on screen.

private final class IAyuGramControllerArguments {
    let updateServerURL: (String) -> Void
    let updateToken: (String) -> Void
    let saveAndTest: () -> Void

    init(updateServerURL: @escaping (String) -> Void, updateToken: @escaping (String) -> Void, saveAndTest: @escaping () -> Void) {
        self.updateServerURL = updateServerURL
        self.updateToken = updateToken
        self.saveAndTest = saveAndTest
    }
}

private enum IAyuGramSection: Int32 {
    case connection
}

private enum IAyuGramEntry: ItemListNodeEntry {
    case connectionHeader(String)
    case serverURL(String, String)   // title, value
    case token(String, String)       // title, value
    case test(String)                // title
    case status(String)              // text

    var section: ItemListSectionId {
        return IAyuGramSection.connection.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .connectionHeader: return 0
        case .serverURL: return 1
        case .token: return 2
        case .test: return 3
        case .status: return 4
        }
    }

    static func <(lhs: IAyuGramEntry, rhs: IAyuGramEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: IAyuGramEntry, rhs: IAyuGramEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.connectionHeader(a), .connectionHeader(b)):
            return a == b
        case let (.serverURL(a1, a2), .serverURL(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.token(a1, a2), .token(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.test(a), .test(b)):
            return a == b
        case let (.status(a), .status(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! IAyuGramControllerArguments
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
        case let .test(title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.saveAndTest()
            })
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private struct IAyuGramControllerState: Equatable {
    var serverURL: String
    var token: String
    var status: String
}

// Opens a WebSocket to <server>/live?token=<token> and pings once to confirm the
// full path (Tailscale Funnel + token auth) works end to end.
private func testIAyuConnection(serverURL: String, token: String, completion: @escaping (Bool, String) -> Void) {
    let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") else {
        completion(false, "Invalid URL")
        return
    }
    switch components.scheme {
    case "http": components.scheme = "ws"
    default: components.scheme = "wss"
    }
    components.path = "/live"
    components.queryItems = [URLQueryItem(name: "token", value: token)]
    guard let url = components.url else {
        completion(false, "Invalid URL")
        return
    }
    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()
    task.sendPing { error in
        let finish: (Bool, String) -> Void = { ok, message in
            Queue.mainQueue().async { completion(ok, message) }
        }
        if let error = error {
            finish(false, error.localizedDescription)
        } else {
            finish(true, "")
        }
        task.cancel(with: .goingAway, reason: nil)
    }
}

public func iAyuGramSettingsController(context: AccountContext) -> ViewController {
    let initialState = IAyuGramControllerState(
        serverURL: SGSimpleSettings.shared.iaSyncServerURL,
        token: SGSimpleSettings.shared.iaSyncClientToken,
        status: ""
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuGramControllerState) -> IAyuGramControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let arguments = IAyuGramControllerArguments(updateServerURL: { text in
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
    }, saveAndTest: {
        let current = stateValue.with { $0 }
        SGSimpleSettings.shared.iaSyncServerURL = current.serverURL
        SGSimpleSettings.shared.iaSyncClientToken = current.token
        updateState { state in
            var state = state
            state.status = "Connecting…"
            return state
        }
        testIAyuConnection(serverURL: current.serverURL, token: current.token) { ok, message in
            updateState { state in
                var state = state
                state.status = ok ? "Connected ✅" : "Failed ❌: \(message)"
                return state
            }
        }
    })

    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
    |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [IAyuGramEntry] = []
        entries.append(.connectionHeader("COMPANION SERVER"))
        entries.append(.serverURL("URL", state.serverURL))
        entries.append(.token("Token", state.token))
        entries.append(.test("Save & Test connection"))
        if !state.status.isEmpty {
            entries.append(.status(state.status))
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("IAyuGram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    return controller
}
