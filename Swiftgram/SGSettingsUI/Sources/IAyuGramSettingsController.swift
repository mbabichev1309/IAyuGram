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
    // True if the message was sent by the account owner (outgoing) — so the copy is
    // rendered on the correct side.
    let fromMe: Bool?
    // Media metadata, when the message carried media the server captured. Bytes are
    // fetched separately from GET /media?chat_id=..&message_id=.. .
    let mediaKind: String?
    let mediaMime: String?
    let mediaSize: Int?
    let mediaWidth: Int?
    let mediaHeight: Int?
    let mediaDuration: Int?
    let mediaViewOnce: Bool?
    // Original document name, for kinds that have one (document/audio).
    let mediaFileName: String?

    enum CodingKeys: String, CodingKey {
        case cursor
        case kind
        case chatId = "chat_id"
        case messageId = "message_id"
        case text
        case oldText = "old_text"
        case date
        case fromMe = "from_me"
        case mediaKind = "media_kind"
        case mediaMime = "media_mime"
        case mediaSize = "media_size"
        case mediaWidth = "media_width"
        case mediaHeight = "media_height"
        case mediaDuration = "media_duration"
        case mediaViewOnce = "media_view_once"
        case mediaFileName = "media_file_name"
    }
}

// Owns a WebSocket to <server>/live?token=…, decodes events, calls onEvent on the
// main queue for each. Cancels the socket on deinit (i.e. when the screen closes).
final class IAyuLiveSession {
    private let task: URLSessionWebSocketTask
    private let onEvent: (IAyuMessageEvent) -> Void
    private let onStatus: (String) -> Void
    // Whether the socket is up, as a value rather than as prose. The status strings are
    // user-editable and localized, so matching on them is unreliable — and literally
    // wrong for "connected", which is a substring of "disconnected".
    private let onConnected: ((Bool) -> Void)?
    // Called once when the socket closes/fails, so the owner can reconnect.
    private let onClosed: (() -> Void)?
    private var active = true
    private var didNotifyClosed = false

    init?(serverURL: String, token: String, onEvent: @escaping (IAyuMessageEvent) -> Void, onStatus: @escaping (String) -> Void, onConnected: ((Bool) -> Void)? = nil, onClosed: (() -> Void)? = nil) {
        guard let url = IAyuLiveSession.liveURL(serverURL: serverURL, token: token) else {
            return nil
        }
        self.onEvent = onEvent
        self.onStatus = onStatus
        self.onConnected = onConnected
        self.onClosed = onClosed
        self.task = URLSession.shared.webSocketTask(with: url)
        self.task.resume()
        onStatus(IAyuStrings.text(.connectionStatusConnecting))
        self.receiveLoop()
        // /live sends nothing until an event occurs, so confirm the connection
        // (handshake + token auth) with a ping instead of waiting for a message.
        self.task.sendPing { [weak self] error in
            Queue.mainQueue().async {
                guard let self = self, self.active else { return }
                if let error = error {
                    self.onStatus(IAyuStrings.text(.connectionStatusFailed, ["error": error.localizedDescription]))
                    self.notifyClosed()
                } else {
                    self.onStatus(IAyuStrings.text(.connectionStatusConnected))
                    self.onConnected?(true)
                }
            }
        }
        // Keepalive: /live is silent until an event, so an idle socket gets closed by
        // proxies (Tailscale Funnel) after ~30–60s. Periodic pings keep it alive.
        self.scheduleKeepalive()
    }

    private func scheduleKeepalive() {
        Queue.mainQueue().after(20.0, { [weak self] in
            guard let self = self, self.active else { return }
            self.task.sendPing { [weak self] error in
                guard let self = self, self.active else { return }
                if error != nil {
                    Queue.mainQueue().async {
                        self.notifyClosed()
                    }
                }
            }
            self.scheduleKeepalive()
        })
    }

    private func notifyClosed() {
        guard self.active, !self.didNotifyClosed else { return }
        self.didNotifyClosed = true
        self.onConnected?(false)
        self.onClosed?()
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
                    self.onStatus(IAyuStrings.text(.connectionStatusDisconnected, ["error": error.localizedDescription]))
                    self.notifyClosed()
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
// badge) instead of it silently vanishing. If the event has photo media, fetch the
// bytes from the companion server and attach them; otherwise text-only.
// Media kinds the server captures and this client can render. Phase 2 added video,
// animations, music and documents to the original photo/sticker/voice/round set.
private let iAyuKnownMediaKinds: Set<String> = [
    "photo", "sticker", "voice", "round", "video", "gif", "audio", "document",
]

func iAyuMaterializeDeleted(context: AccountContext, event: IAyuMessageEvent) {
    guard let kind = event.mediaKind, iAyuKnownMediaKinds.contains(kind) else {
        iAyuInsertDeleted(context: context, event: event, media: [])
        return
    }

    // Phase 2 lifted the server-side size limit, so a delete can now point at a
    // multi-hundred-megabyte video. Downloading that unasked would be hostile, so
    // respect a client-side budget: past it, preserve the message as text with a
    // note naming what was dropped. The bytes stay on the server, so raising the
    // limit later still recovers them via gap-sync.
    let limitBytes = Int(SGSimpleSettings.shared.iaMediaMaxDownloadMB) * 1024 * 1024
    if let size = event.mediaSize, limitBytes > 0, size > limitBytes {
        iAyuInsertDeleted(
            context: context,
            event: event,
            media: [],
            appendedNote: iAyuSkippedMediaNote(event: event, size: size)
        )
        return
    }

    // Fetch to a temp file first, then insert the message with the media attached. If
    // the fetch fails we still insert the text placeholder so the delete is visible.
    iAyuFetchMediaFile(event: event) { path, size in
        var media: [Media] = []
        let postbox = context.account.postbox
        if let path = path {
            if kind == "photo" || kind == "sticker" {
                // Images are small; map the file rather than reading it onto the heap.
                let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                if let data = data {
                    if kind == "photo", let image = iAyuBuildPhotoMedia(postbox: postbox, data: data, event: event) {
                        media = [image]
                    } else if let sticker = iAyuBuildStickerMedia(postbox: postbox, data: data, event: event) {
                        media = [sticker]
                    }
                }
                try? FileManager.default.removeItem(atPath: path)
            } else if let file = iAyuBuildFileMedia(postbox: postbox, path: path, size: size, event: event) {
                // Consumes the temp file (moved into the media box).
                media = [file]
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        iAyuInsertDeleted(context: context, event: event, media: media)
    }
}

// Human-readable note for media that was preserved on the server but not downloaded.
private func iAyuSkippedMediaNote(event: IAyuMessageEvent, size: Int) -> String {
    let megabytes = max(1, size / (1024 * 1024))
    let label: String
    switch event.mediaKind {
    case "video": label = IAyuStrings.text(.mediaVideo)
    case "gif": label = IAyuStrings.text(.mediaGif)
    case "audio": label = IAyuStrings.text(.mediaAudio)
    case "document": label = event.mediaFileName ?? IAyuStrings.text(.mediaFile)
    case "photo": label = IAyuStrings.text(.mediaPhoto)
    case "voice": label = IAyuStrings.text(.mediaVoice)
    case "round": label = IAyuStrings.text(.mediaRound)
    default: label = IAyuStrings.text(.mediaGeneric)
    }
    return IAyuStrings.text(.mediaSkippedNote, ["kind": label, "size": "\(megabytes)"])
}

private func iAyuInsertDeleted(context: AccountContext, event: IAyuMessageEvent, media: [Media], appendedNote: String? = nil) {
    let peerId = iAyuPeerId(fromServerChatId: event.chatId)
    // Render on the correct side: the server tells us whether WE sent the original
    // (from_me). Outgoing → author is us, no Incoming flag. Incoming → author is the
    // DM partner (for groups/channels we don't know the exact sender, best-effort).
    let fromMe = event.fromMe ?? false
    var flags = StoreMessageFlags()
    var authorId = context.account.peerId
    if !fromMe {
        flags.insert(.Incoming)
        authorId = peerId
    }
    // Prefer the original message time so the placeholder lands in place; fall back
    // to now (bottom of the chat) rather than epoch (which would bury it at the top).
    let timestamp = event.date.map { Int32(clamping: $0) } ?? Int32(Date().timeIntervalSince1970)
    var text = event.text ?? ""
    if let appendedNote = appendedNote {
        text = text.isEmpty ? appendedNote : "\(text)\n\(appendedNote)"
    }
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
        text: text,
        attributes: [DeletedMessageAttribute(date: timestamp)],
        media: media
    )
    let _ = (context.account.postbox.transaction { transaction -> Void in
        let _ = transaction.addMessages([message], location: .Random)
    }).start()
}

// Build a local-image media from downloaded bytes: write the bytes into the media
// box under a fresh local resource, then reference it. The image node loads the
// cached bytes when the message is displayed (no Telegram CDN round-trip).
private func iAyuBuildPhotoMedia(postbox: Postbox, data: Data, event: IAyuMessageEvent) -> TelegramMediaImage? {
    let fileId = Int64.random(in: Int64.min ... Int64.max)
    let resource = LocalFileMediaResource(fileId: fileId, size: Int64(data.count))
    postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
    let width = Int32(event.mediaWidth ?? 0)
    let height = Int32(event.mediaHeight ?? 0)
    let representation = TelegramMediaImageRepresentation(
        dimensions: PixelDimensions(width: width > 0 ? width : 1, height: height > 0 ? height : 1),
        resource: resource,
        progressiveSizes: [],
        immediateThumbnailData: nil
    )
    return TelegramMediaImage(
        imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: fileId),
        representations: [representation],
        immediateThumbnailData: nil,
        reference: nil,
        partialReference: nil,
        flags: []
    )
}

// Build a local voice/round-video media from downloaded bytes (same media-box
// caching as photos). Voice → an Audio(isVoice) file; round → a Video with the
// instantRoundVideo flag. Waveform isn't captured, so voice shows a flat one.
// Phase 2: takes the downloaded file's path rather than its bytes and hands it to the
// media box directly, so preserving a large video never loads it into memory. The temp
// file is consumed (moved) on success.
private func iAyuBuildFileMedia(postbox: Postbox, path: String, size: Int64, event: IAyuMessageEvent) -> TelegramMediaFile? {
    let fileId = Int64.random(in: Int64.min ... Int64.max)
    let resource = LocalFileMediaResource(fileId: fileId, size: size)
    postbox.mediaBox.moveResourceData(resource.id, fromTempPath: path)
    let duration = event.mediaDuration ?? 0
    let width = Int32(event.mediaWidth ?? 0)
    let height = Int32(event.mediaHeight ?? 0)
    var attributes: [TelegramMediaFileAttribute] = []
    let mimeType: String

    switch event.mediaKind {
    case "voice":
        attributes.append(.Audio(isVoice: true, duration: duration, title: nil, performer: nil, waveform: nil))
        mimeType = event.mediaMime ?? "audio/ogg"
    case "audio":
        // Music, as opposed to a voice note: keep it a playable audio file.
        attributes.append(.Audio(isVoice: false, duration: duration, title: nil, performer: nil, waveform: nil))
        attributes.append(.FileName(fileName: event.mediaFileName ?? "audio.mp3"))
        mimeType = event.mediaMime ?? "audio/mpeg"
    case "document":
        // No Video/Audio attribute → renders as a file row with the original name.
        attributes.append(.FileName(fileName: event.mediaFileName ?? "file"))
        mimeType = event.mediaMime ?? "application/octet-stream"
    case "gif":
        // .Animated makes it loop silently, the way the original animation did.
        attributes.append(.Animated)
        attributes.append(.Video(
            duration: Double(duration),
            size: PixelDimensions(width: width > 0 ? width : 240, height: height > 0 ? height : 240),
            flags: [],
            preloadSize: nil,
            coverTime: nil,
            videoCodec: nil
        ))
        attributes.append(.FileName(fileName: event.mediaFileName ?? "animation.mp4"))
        mimeType = event.mediaMime ?? "video/mp4"
    default:
        // "video" and "round". A round message is materialized as a plain video:
        // round videos render via a dedicated top-level item node
        // (ChatMessageInstantVideoItemNode) that doesn't handle our synthetic local
        // message, so it wouldn't show at all. A normal video routes through the
        // working media-bubble path — no circle, but the content plays.
        attributes.append(.Video(
            duration: Double(duration),
            size: PixelDimensions(width: width > 0 ? width : 240, height: height > 0 ? height : 240),
            flags: [],
            preloadSize: nil,
            coverTime: nil,
            videoCodec: nil
        ))
        attributes.append(.FileName(fileName: event.mediaFileName ?? "video.mp4"))
        mimeType = event.mediaMime ?? "video/mp4"
    }
    return TelegramMediaFile(
        fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: fileId),
        partialReference: nil,
        resource: resource,
        previewRepresentations: [],
        videoThumbnails: [],
        videoCover: nil,
        immediateThumbnailData: nil,
        mimeType: mimeType,
        size: size,
        attributes: attributes,
        alternativeRepresentations: []
    )
}

// Variant B: materialize a deleted sticker as a real sticker file (TelegramMediaFile
// with a Sticker attribute), so animated/video stickers render properly. If the
// dedicated sticker item node doesn't render our synthetic local message (as with
// round video), fall back to treating it as an image/video.
private func iAyuBuildStickerMedia(postbox: Postbox, data: Data, event: IAyuMessageEvent) -> TelegramMediaFile? {
    let fileId = Int64.random(in: Int64.min ... Int64.max)
    let resource = LocalFileMediaResource(fileId: fileId, size: Int64(data.count))
    postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
    let width = Int32(event.mediaWidth ?? 0)
    let height = Int32(event.mediaHeight ?? 0)
    let mimeType = event.mediaMime ?? "image/webp"
    var attributes: [TelegramMediaFileAttribute] = [
        .Sticker(displayText: "", packReference: nil, maskData: nil),
        .ImageSize(size: PixelDimensions(width: width > 0 ? width : 512, height: height > 0 ? height : 512)),
    ]
    if mimeType.contains("tgsticker") {
        attributes.append(.Animated)
        attributes.append(.FileName(fileName: "sticker.tgs"))
    } else if mimeType.contains("webm") {
        attributes.append(.FileName(fileName: "sticker.webm"))
    } else {
        attributes.append(.FileName(fileName: "sticker.webp"))
    }
    return TelegramMediaFile(
        fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: fileId),
        partialReference: nil,
        resource: resource,
        previewRepresentations: [],
        videoThumbnails: [],
        videoCover: nil,
        immediateThumbnailData: nil,
        mimeType: mimeType,
        size: Int64(data.count),
        attributes: attributes,
        alternativeRepresentations: []
    )
}

// Fetch an event's media from GET /media (Bearer token) into a temp file. Completion
// runs on a background queue with the file's path and size, or (nil, 0) on failure.
// A download task streams to disk, so a large video never sits in memory; the caller
// owns the temp file and must move or delete it.
private func iAyuFetchMediaFile(event: IAyuMessageEvent, completion: @escaping (String?, Int64) -> Void) {
    let serverURL = SGSimpleSettings.shared.iaSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = SGSimpleSettings.shared.iaSyncClientToken
    guard !serverURL.isEmpty, !token.isEmpty,
          var components = URLComponents(string: serverURL.contains("://") ? serverURL : "https://\(serverURL)") else {
        completion(nil, 0)
        return
    }
    components.path = "/media"
    components.queryItems = [
        URLQueryItem(name: "chat_id", value: "\(event.chatId)"),
        URLQueryItem(name: "message_id", value: "\(event.messageId)"),
    ]
    guard let url = components.url else {
        completion(nil, 0)
        return
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    URLSession.shared.downloadTask(with: request) { location, response, _ in
        guard let location = location,
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            completion(nil, 0)
            return
        }
        // URLSession deletes the download's temp file as soon as this handler
        // returns, so move it somewhere we control before doing anything else.
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iayu_media_\(event.chatId)_\(event.messageId)")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            completion(nil, 0)
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        completion(destination.path, size)
    }.resume()
}

// IAyuGram hub (root screen): a ghost-mode section (functional toggles — each gates
// an outgoing-signal seam in TelegramCore/TelegramUI) plus navigation into the
// Appearance and Connection-keys screens.

private final class IAyuHubArguments {
    let toggleHideReadReceipts: (Bool) -> Void
    let toggleStayOffline: (Bool) -> Void
    let toggleHideTyping: (Bool) -> Void
    let toggleHideConsumed: (Bool) -> Void
    let toggleInvisibleSend: (Bool) -> Void
    let pickMediaCap: () -> Void
    let openAppearance: () -> Void
    let openLocalization: () -> Void
    let openConnection: () -> Void

    init(toggleHideReadReceipts: @escaping (Bool) -> Void, toggleStayOffline: @escaping (Bool) -> Void, toggleHideTyping: @escaping (Bool) -> Void, toggleHideConsumed: @escaping (Bool) -> Void, toggleInvisibleSend: @escaping (Bool) -> Void, pickMediaCap: @escaping () -> Void, openAppearance: @escaping () -> Void, openLocalization: @escaping () -> Void, openConnection: @escaping () -> Void) {
        self.toggleHideReadReceipts = toggleHideReadReceipts
        self.toggleStayOffline = toggleStayOffline
        self.toggleHideTyping = toggleHideTyping
        self.toggleHideConsumed = toggleHideConsumed
        self.toggleInvisibleSend = toggleInvisibleSend
        self.pickMediaCap = pickMediaCap
        self.openAppearance = openAppearance
        self.openLocalization = openLocalization
        self.openConnection = openConnection
    }
}

private enum IAyuHubSection: Int32 {
    case ghost
    case media
    case screens
}

// Offered download caps, in MB; 0 means no limit. Kept in one place so the row's label and
// the picker can't disagree about what the stored value means.
private let iAyuMediaCapOptions: [Int32] = [16, 32, 64, 128, 256, 512, 0]

private func iAyuMediaCapLabel(_ mb: Int32) -> String {
    if mb <= 0 {
        return IAyuStrings.text(.hubMediaCapUnlimited)
    }
    return "\(mb) MB"
}

private enum IAyuHubEntry: ItemListNodeEntry {
    case ghostHeader(String)
    case ghostHideReadReceipts(String, Bool)
    case ghostStayOffline(String, Bool)
    case ghostHideTyping(String, Bool)
    case ghostHideConsumed(String, Bool)
    case ghostInvisibleSend(String, Bool)
    case ghostInfo(String)
    case mediaHeader(String)
    case mediaCap(String, Int32)
    case mediaInfo(String)
    case appearance(String)
    case localization(String)
    case connection(String)

    var section: ItemListSectionId {
        switch self {
        case .ghostHeader, .ghostHideReadReceipts, .ghostStayOffline, .ghostHideTyping, .ghostHideConsumed, .ghostInvisibleSend, .ghostInfo:
            return IAyuHubSection.ghost.rawValue
        case .mediaHeader, .mediaCap, .mediaInfo:
            return IAyuHubSection.media.rawValue
        case .appearance, .localization, .connection:
            return IAyuHubSection.screens.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .ghostHeader: return 0
        case .ghostHideReadReceipts: return 1
        case .ghostStayOffline: return 2
        case .ghostHideTyping: return 3
        case .ghostHideConsumed: return 4
        case .ghostInvisibleSend: return 5
        case .ghostInfo: return 6
        case .mediaHeader: return 7
        case .mediaCap: return 8
        case .mediaInfo: return 9
        case .appearance: return 10
        case .localization: return 11
        case .connection: return 12
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
        case let (.ghostHideConsumed(a1, a2), .ghostHideConsumed(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.ghostInvisibleSend(a1, a2), .ghostInvisibleSend(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.ghostInfo(a), .ghostInfo(b)):
            return a == b
        case let (.mediaHeader(a), .mediaHeader(b)):
            return a == b
        case let (.mediaCap(a1, a2), .mediaCap(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.mediaInfo(a), .mediaInfo(b)):
            return a == b
        case let (.appearance(a), .appearance(b)):
            return a == b
        case let (.localization(a), .localization(b)):
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
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleHideReadReceipts(newValue)
            })
        case let .ghostStayOffline(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleStayOffline(newValue)
            })
        case let .ghostHideTyping(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleHideTyping(newValue)
            })
        case let .ghostHideConsumed(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleHideConsumed(newValue)
            })
        case let .ghostInvisibleSend(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleInvisibleSend(newValue)
            })
        case let .ghostInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .mediaHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .mediaCap(title, mb):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: iAyuMediaCapLabel(mb), sectionId: self.section, style: .blocks, action: {
                arguments.pickMediaCap()
            })
        case let .mediaInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .appearance(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openAppearance()
            })
        case let .localization(title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openLocalization()
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
    var hideConsumed: Bool
    var invisibleSend: Bool
    var mediaCapMB: Int32
}

public func iAyuGramSettingsController(context: AccountContext) -> ViewController {
    let initialState = IAyuHubState(
        hideReadReceipts: SGSimpleSettings.shared.iaGhostHideReadReceipts,
        stayOffline: SGSimpleSettings.shared.iaGhostStayOffline,
        hideTyping: SGSimpleSettings.shared.iaGhostHideTyping,
        hideConsumed: SGSimpleSettings.shared.iaGhostHideConsumed,
        invisibleSend: SGSimpleSettings.shared.iaGhostInvisibleSend,
        mediaCapMB: SGSimpleSettings.shared.iaMediaMaxDownloadMB
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuHubState) -> IAyuHubState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?

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
    }, toggleHideConsumed: { value in
        SGSimpleSettings.shared.iaGhostHideConsumed = value
        updateState { state in
            var state = state
            state.hideConsumed = value
            return state
        }
    }, toggleInvisibleSend: { value in
        SGSimpleSettings.shared.iaGhostInvisibleSend = value
        updateState { state in
            var state = state
            state.invisibleSend = value
            return state
        }
    }, pickMediaCap: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var dismissImpl: (() -> Void)?
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: IAyuStrings.text(.hubMediaCap))]
        for option in iAyuMediaCapOptions {
            items.append(ActionSheetButtonItem(title: iAyuMediaCapLabel(option), action: {
                dismissImpl?()
                SGSimpleSettings.shared.iaMediaMaxDownloadMB = option
                updateState { state in
                    var state = state
                    state.mediaCapMB = option
                    return state
                }
            }))
        }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        dismissImpl = { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: {
                    dismissImpl?()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }, openAppearance: {
        pushControllerImpl?(iAyuGramAppearanceController(context: context))
    }, openLocalization: {
        pushControllerImpl?(iAyuGramLocalizationController(context: context))
    }, openConnection: {
        pushControllerImpl?(iAyuGramConnectionController(context: context))
    })

    let signal = combineLatest(statePromise.get(), context.sharedContext.presentationData)
    |> map { state, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [IAyuHubEntry] = []
        entries.append(.ghostHeader(IAyuStrings.text(.hubGhostHeader)))
        entries.append(.ghostHideReadReceipts(IAyuStrings.text(.hubGhostHideReadReceipts), state.hideReadReceipts))
        entries.append(.ghostStayOffline(IAyuStrings.text(.hubGhostStayOffline), state.stayOffline))
        entries.append(.ghostHideTyping(IAyuStrings.text(.hubGhostHideTyping), state.hideTyping))
        entries.append(.ghostHideConsumed(IAyuStrings.text(.hubGhostHideConsumed), state.hideConsumed))
        entries.append(.ghostInvisibleSend(IAyuStrings.text(.hubGhostInvisibleSend), state.invisibleSend))
        entries.append(.ghostInfo(IAyuStrings.text(.hubGhostInfo)))
        entries.append(.mediaHeader(IAyuStrings.text(.hubMediaHeader)))
        entries.append(.mediaCap(IAyuStrings.text(.hubMediaCap), state.mediaCapMB))
        entries.append(.mediaInfo(IAyuStrings.text(.hubMediaInfo)))
        entries.append(.appearance(IAyuStrings.text(.hubAppearance)))
        entries.append(.localization(IAyuStrings.text(.hubLocalization)))
        entries.append(.connection(IAyuStrings.text(.hubConnection)))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(IAyuStrings.text(.hubTitle)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
