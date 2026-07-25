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

final class IAyuSessionBox {
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

// IAyuGram hub (root screen): a ghost-mode section (placeholder toggles, wired to
// behavior later) plus navigation into the Appearance and Connection-keys screens.

private final class IAyuHubArguments {
    let toggleHideReadReceipts: (Bool) -> Void
    let toggleStayOffline: (Bool) -> Void
    let toggleHideTyping: (Bool) -> Void
    let openAppearance: () -> Void
    let openConnection: () -> Void

    init(toggleHideReadReceipts: @escaping (Bool) -> Void, toggleStayOffline: @escaping (Bool) -> Void, toggleHideTyping: @escaping (Bool) -> Void, openAppearance: @escaping () -> Void, openConnection: @escaping () -> Void) {
        self.toggleHideReadReceipts = toggleHideReadReceipts
        self.toggleStayOffline = toggleStayOffline
        self.toggleHideTyping = toggleHideTyping
        self.openAppearance = openAppearance
        self.openConnection = openConnection
    }
}

private enum IAyuHubSection: Int32 {
    case ghost
    case screens
}

private enum IAyuHubEntry: ItemListNodeEntry {
    case ghostHeader(String)
    case ghostHideReadReceipts(String, Bool)
    case ghostStayOffline(String, Bool)
    case ghostHideTyping(String, Bool)
    case ghostInfo(String)
    case appearance(String)
    case connection(String)

    var section: ItemListSectionId {
        switch self {
        case .ghostHeader, .ghostHideReadReceipts, .ghostStayOffline, .ghostHideTyping, .ghostInfo:
            return IAyuHubSection.ghost.rawValue
        case .appearance, .connection:
            return IAyuHubSection.screens.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .ghostHeader: return 0
        case .ghostHideReadReceipts: return 1
        case .ghostStayOffline: return 2
        case .ghostHideTyping: return 3
        case .ghostInfo: return 4
        case .appearance: return 5
        case .connection: return 6
        }
    }

    static func <(lhs: IAyuHubEntry, rhs: IAyuHubEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: IAyuHubEntry, rhs: IAyuHubEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.ghostHeader(a), .ghostHeader(b)):
            return a == b
        case let (.ghostHideReadReceipts(a1, a2), .ghostHideReadReceipts(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.ghostStayOffline(a1, a2), .ghostStayOffline(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.ghostHideTyping(a1, a2), .ghostHideTyping(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.ghostInfo(a), .ghostInfo(b)):
            return a == b
        case let (.appearance(a), .appearance(b)):
            return a == b
        case let (.connection(a), .connection(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! IAyuHubArguments
        switch self {
        case let .ghostHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .ghostHideReadReceipts(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, enabled: false, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleHideReadReceipts(newValue)
            })
        case let .ghostStayOffline(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, enabled: false, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleStayOffline(newValue)
            })
        case let .ghostHideTyping(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, enabled: false, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleHideTyping(newValue)
            })
        case let .ghostInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .appearance(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openAppearance()
            })
        case let .connection(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openConnection()
            })
        }
    }
}

private struct IAyuHubState: Equatable {
    var hideReadReceipts: Bool
    var stayOffline: Bool
    var hideTyping: Bool
}

public func iAyuGramSettingsController(context: AccountContext) -> ViewController {
    let initialState = IAyuHubState(
        hideReadReceipts: SGSimpleSettings.shared.iaGhostHideReadReceipts,
        stayOffline: SGSimpleSettings.shared.iaGhostStayOffline,
        hideTyping: SGSimpleSettings.shared.iaGhostHideTyping
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuHubState) -> IAyuHubState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var pushControllerImpl: ((ViewController) -> Void)?

    let arguments = IAyuHubArguments(toggleHideReadReceipts: { value in
        SGSimpleSettings.shared.iaGhostHideReadReceipts = value
        updateState { state in
            var state = state
            state.hideReadReceipts = value
            return state
        }
    }, toggleStayOffline: { value in
        SGSimpleSettings.shared.iaGhostStayOffline = value
        updateState { state in
            var state = state
            state.stayOffline = value
            return state
        }
    }, toggleHideTyping: { value in
        SGSimpleSettings.shared.iaGhostHideTyping = value
        updateState { state in
            var state = state
            state.hideTyping = value
            return state
        }
    }, openAppearance: {
        pushControllerImpl?(iAyuGramAppearanceController(context: context))
    }, openConnection: {
        pushControllerImpl?(iAyuGramConnectionController(context: context))
    })

    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
    |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [IAyuHubEntry] = []
        entries.append(.ghostHeader("GHOST MODE"))
        entries.append(.ghostHideReadReceipts("Don't send read receipts", state.hideReadReceipts))
        entries.append(.ghostStayOffline("Stay offline", state.stayOffline))
        entries.append(.ghostHideTyping("Don't send typing", state.hideTyping))
        entries.append(.ghostInfo("Ghost mode is not active yet — coming soon."))
        entries.append(.appearance("Appearance"))
        entries.append(.connection("Connection keys"))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("IAyuGram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}
