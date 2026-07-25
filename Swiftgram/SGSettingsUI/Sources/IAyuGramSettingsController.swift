import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGSimpleSettings

// IAyuGram settings hub.
// Phase 1: Connection section (companion server URL + token, Test connection).
// Phase 2a: a live listener — while this screen is open it keeps a WebSocket to
// /live and shows incoming delete/edit events in real time (proves the end-to-end
// pipeline with real events before Postbox materialization in Phase 2b).

// Wire contract — keep in sync with the server (server/models.py MessageEvent).
struct IAyuMessageEvent: Codable, Equatable {
    let cursor: Int
    let kind: String
    let chatId: Int64
    let messageId: Int64
    let text: String?
    let oldText: String?
    let date: Int?

    enum CodingKeys: String, CodingKey {
        case cursor
        case kind
        case chatId = "chat_id"
        case messageId = "message_id"
        case text
        case oldText = "old_text"
        case date
    }
}

// Owns a WebSocket to <server>/live?token=…, decodes events, calls onEvent on the
// main queue for each. Cancels the socket on deinit (i.e. when the screen closes).
final class IAyuLiveSession {
    private let task: URLSessionWebSocketTask
    private let onEvent: (IAyuMessageEvent) -> Void
    private let onStatus: (String) -> Void
    private var active = true

    init?(serverURL: String, token: String, onEvent: @escaping (IAyuMessageEvent) -> Void, onStatus: @escaping (String) -> Void) {
        guard let url = IAyuLiveSession.liveURL(serverURL: serverURL, token: token) else {
            return nil
        }
        self.onEvent = onEvent
        self.onStatus = onStatus
        self.task = URLSession.shared.webSocketTask(with: url)
        self.task.resume()
        onStatus("Live: connecting…")
        self.receiveLoop()
        // /live sends nothing until an event occurs, so confirm the connection
        // (handshake + token auth) with a ping instead of waiting for a message.
        self.task.sendPing { [weak self] error in
            Queue.mainQueue().async {
                guard let self = self, self.active else { return }
                if let error = error {
                    self.onStatus("Live: failed — \(error.localizedDescription)")
                } else {
                    self.onStatus("Live: connected ✅ (listening for events)")
                }
            }
        }
    }

    static func liveURL(serverURL: String, token: String) -> URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") else {
            return nil
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "ws"
        } else {
            components.scheme = "wss"
        }
        components.path = "/live"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    private func receiveLoop() {
        self.task.receive { [weak self] result in
            guard let self = self, self.active else { return }
            switch result {
            case let .success(message):
                if case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(IAyuMessageEvent.self, from: data) {
                    Queue.mainQueue().async {
                        self.onEvent(event)
                    }
                }
                self.receiveLoop()
            case let .failure(error):
                Queue.mainQueue().async {
                    self.onStatus("Live: disconnected — \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        self.active = false
        self.task.cancel(with: .goingAway, reason: nil)
    }

    deinit {
        self.stop()
    }
}

private final class IAyuSessionBox {
    var session: IAyuLiveSession?
}

// Map a companion-server chat_id (Telethon "marked" id convention) to a Telegram
// PeerId: positive → user DM; -100…​ → channel/supergroup; other negative → basic group.
func iAyuPeerId(fromServerChatId chatId: Int64) -> PeerId {
    if chatId >= 0 {
        return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(chatId))
    }
    let channelBase: Int64 = 1_000_000_000_000
    if chatId <= -channelBase {
        let realId = -chatId - channelBase
        return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(realId))
    }
    return PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(-chatId))
}

// Phase 2b step 4: insert a synthetic local message carrying DeletedMessageAttribute
// so a chat the server reported a delete in keeps the message (with the "🗑 deleted"
// badge) instead of it silently vanishing. Text-only for v1.
func iAyuMaterializeDeleted(context: AccountContext, event: IAyuMessageEvent) {
    let peerId = iAyuPeerId(fromServerChatId: event.chatId)
    let isSelf = peerId == context.account.peerId
    // For a DM, the message we're recovering was almost always sent by the other
    // party (that's the whole point of catching deletes), so render it incoming.
    var flags = StoreMessageFlags()
    var authorId = context.account.peerId
    if !isSelf && peerId.namespace == Namespaces.Peer.CloudUser {
        flags.insert(.Incoming)
        authorId = peerId
    }
    // Prefer the original message time so the placeholder lands in place; fall back
    // to now (bottom of the chat) rather than epoch (which would bury it at the top).
    let timestamp = event.date.map { Int32(clamping: $0) } ?? Int32(Date().timeIntervalSince1970)
    let message = StoreMessage(
        peerId: peerId,
        namespace: Namespaces.Message.Local,
        customStableId: nil,
        globallyUniqueId: nil,
        groupingKey: nil,
        threadId: nil,
        timestamp: timestamp,
        flags: flags,
        tags: [],
        globalTags: [],
        localTags: [],
        forwardInfo: nil,
        authorId: authorId,
        text: event.text ?? "",
        attributes: [DeletedMessageAttribute(date: timestamp)],
        media: []
    )
    let _ = (context.account.postbox.transaction { transaction -> Void in
        let _ = transaction.addMessages([message], location: .Random)
    }).start()
}

private final class IAyuGramControllerArguments {
    let updateServerURL: (String) -> Void
    let updateToken: (String) -> Void
    let connectLive: () -> Void

    init(updateServerURL: @escaping (String) -> Void, updateToken: @escaping (String) -> Void, connectLive: @escaping () -> Void) {
        self.updateServerURL = updateServerURL
        self.updateToken = updateToken
        self.connectLive = connectLive
    }
}

private enum IAyuGramSection: Int32 {
    case connection
    case live
}

private enum IAyuGramEntry: ItemListNodeEntry {
    case connectionHeader(String)
    case serverURL(String, String)
    case token(String, String)
    case connect(String)
    case status(String)
    case liveHeader(String)
    case event(Int, String)   // stableIndex, text

    var section: ItemListSectionId {
        switch self {
        case .connectionHeader, .serverURL, .token, .connect, .status:
            return IAyuGramSection.connection.rawValue
        case .liveHeader, .event:
            return IAyuGramSection.live.rawValue
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

private struct IAyuGramControllerState: Equatable {
    var serverURL: String
    var token: String
    var status: String
    var events: [IAyuMessageEvent]
}

private func eventDescription(_ event: IAyuMessageEvent) -> String {
    let content = event.text ?? "<no content>"
    return "\(event.kind) #\(event.messageId): \(content)"
}

public func iAyuGramSettingsController(context: AccountContext) -> ViewController {
    let initialState = IAyuGramControllerState(
        serverURL: SGSimpleSettings.shared.iaSyncServerURL,
        token: SGSimpleSettings.shared.iaSyncClientToken,
        status: "",
        events: []
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuGramControllerState) -> IAyuGramControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let sessionBox = IAyuSessionBox()

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
            // Materialization into Postbox is owned by the app-launch IAyuSyncManager
            // (step 5); this screen is just a live viewer to avoid double-inserting.
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
        var entries: [IAyuGramEntry] = []
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
                entries.append(.event(index, eventDescription(event)))
            }
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("IAyuGram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    // sessionBox is retained through `arguments` (the map closure) for the
    // controller's lifetime; when the screen is dismissed and the controller is
    // released, the session deinits and cancels its WebSocket.
    return controller
}
