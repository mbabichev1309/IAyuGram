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
    let forceDegraded: () -> Void
    let forceStorageLow: () -> Void

    init(updateServerURL: @escaping (String) -> Void, updateToken: @escaping (String) -> Void, connectLive: @escaping () -> Void, forceDegraded: @escaping () -> Void, forceStorageLow: @escaping () -> Void) {
        self.updateServerURL = updateServerURL
        self.updateToken = updateToken
        self.connectLive = connectLive
        self.forceDegraded = forceDegraded
        self.forceStorageLow = forceStorageLow
    }
}

private enum IAyuConnectionSection: Int32 {
    case connection
    case live
    case diagnostics
}

// Bumped by hand whenever this file changes in a way worth confirming on-device. CI
// numbers every branch from the same base, so two different builds can carry the same
// CFBundleVersion and there is otherwise no way to tell from the phone which binary is
// actually installed — which is exactly the ambiguity that stalled the capture-health
// investigation.
private let iAyuBuildMarker = "global-round-2"

// The reported figure, not a verdict: on a box with hundreds of free gigabytes the
// warning will never fire by itself, so this is what tells "arriving, plenty of room"
// apart from "nothing is arriving".
private func iAyuStorageDescription() -> String {
    guard let free = IAyuCaptureHealth.shared.lastStorageFreeBytes else {
        return "not reported yet"
    }
    let gb = Double(free) / 1073741824.0
    let suffix = IAyuCaptureHealth.shared.isStorageLow ? " — LOW" : ""
    return String(format: "%.1f GB free%@", gb, suffix)
}

private func iAyuCaptureStateDescription(_ state: IAyuCaptureState) -> String {
    switch state {
    case .notConfigured: return "not configured (no server URL/token)"
    case .healthy: return "healthy"
    case .unreachable: return "UNREACHABLE — server not answering"
    case .sessionLost: return "SESSION LOST — server up, Telegram session revoked"
    }
}

private enum IAyuConnectionEntry: ItemListNodeEntry {
    case connectionHeader(String)
    case serverURL(String, String)
    case token(String, String)
    case connect(String)
    case status(String)
    case liveHeader(String)
    case event(Int, String)
    case diagHeader(String)
    case diagState(String)
    case diagForce(String)
    case diagForceStorage(String)

    var section: ItemListSectionId {
        switch self {
        case .connectionHeader, .serverURL, .token, .connect, .status:
            return IAyuConnectionSection.connection.rawValue
        case .liveHeader, .event:
            return IAyuConnectionSection.live.rawValue
        case .diagHeader, .diagState, .diagForce, .diagForceStorage:
            return IAyuConnectionSection.diagnostics.rawValue
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
        case .diagHeader: return 10000
        case .diagState: return 10001
        case .diagForce: return 10002
        case .diagForceStorage: return 10003
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
        case let (.diagHeader(a), .diagHeader(b)):
            return a == b
        case let (.diagState(a), .diagState(b)):
            return a == b
        case let (.diagForceStorage(a), .diagForceStorage(b)):
            return a == b
        case let (.diagForce(a), .diagForce(b)):
            return a == b
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
            return iAyuTextFieldItem(presentationData: presentationData, title: title, value: value, placeholder: "https://…ts.net", sectionId: self.section, textUpdated: { text in
                arguments.updateServerURL(text)
            })
        case let .token(title, value):
            return iAyuTextFieldItem(presentationData: presentationData, title: title, value: value, placeholder: "client token", sectionId: self.section, textUpdated: { text in
                arguments.updateToken(text)
            })
        case let .connect(title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.connectLive()
            })
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .diagHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .diagState(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .diagForce(title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.forceDegraded()
            })
        case let .diagForceStorage(title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.forceStorageLow()
            })
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
    // Bumped to force a re-render after the diagnostics row's value changes underneath
    // it — the health state lives outside this screen's state, so nothing else would.
    var diagTick: Int
}

private func iAyuConnectionEventDescription(_ event: IAyuMessageEvent) -> String {
    let content = event.text ?? IAyuStrings.text(.connectionEventNoContent)
    return "\(event.kind) #\(event.messageId): \(content)"
}

public func iAyuGramConnectionController(context: AccountContext) -> ViewController {
    let initialState = IAyuConnectionState(
        serverURL: SGSimpleSettings.shared.iaSyncServerURL,
        token: SGSimpleSettings.shared.iaSyncClientToken,
        status: "",
        events: [],
        diagTick: 0
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
            state.status = IAyuStrings.text(.connectionStatusConnecting)
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
                state.status = IAyuStrings.text(.connectionStatusInvalidURL)
                return state
            }
        }
    }, forceDegraded: {
        // Drives the published state directly, bypassing detection entirely, so the
        // chat-list marker can be verified independently of whether an outage is
        // correctly noticed. If the dot appears after this and not during a real
        // outage, the bug is in detection; if it never appears, it is in the UI.
        IAyuCaptureHealth.shared.update(.unreachable)
        updateState { state in
            var state = state
            state.diagTick += 1
            return state
        }
    }, forceStorageLow: {
        // Same idea for the storage warning, and here it is the only way to see it at
        // all: the box has hundreds of gigabytes free, so the real threshold cannot be
        // reached on demand. Note the capture warning outranks this one, so check this
        // with capture healthy or the title will show the other message.
        IAyuCaptureHealth.shared.forceStorageLow()
        updateState { state in
            var state = state
            state.diagTick += 1
            return state
        }
    })

    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
    |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [IAyuConnectionEntry] = []
        entries.append(.connectionHeader(IAyuStrings.text(.connectionServerHeader)))
        entries.append(.serverURL(IAyuStrings.text(.connectionURL), state.serverURL))
        entries.append(.token(IAyuStrings.text(.connectionToken), state.token))
        entries.append(.connect(IAyuStrings.text(.connectionConnect)))
        if !state.status.isEmpty {
            entries.append(.status(state.status))
        }
        if !state.events.isEmpty {
            entries.append(.liveHeader(IAyuStrings.text(.connectionLiveHeader)))
            for (index, event) in state.events.enumerated() {
                entries.append(.event(index, iAyuConnectionEventDescription(event)))
            }
        }
        entries.append(.diagHeader("DIAGNOSTICS"))
        entries.append(.diagState("Build: \(iAyuBuildMarker)\nCapture health: \(iAyuCaptureStateDescription(IAyuCaptureHealth.shared.state))\nServer free space: \(iAyuStorageDescription())"))
        entries.append(.diagForce("Force the warning on"))
        entries.append(.diagForceStorage("Force the storage warning on"))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(IAyuStrings.text(.connectionTitle)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    // sessionBox is retained through `arguments` for the controller's lifetime; the
    // WebSocket is cancelled when the screen is dismissed and the controller released.
    return ItemListController(context: context, state: signal)
}
