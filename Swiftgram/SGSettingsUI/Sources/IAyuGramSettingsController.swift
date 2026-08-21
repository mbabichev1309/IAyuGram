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
// One file of a multi-media message (server models.py EventMediaItem). Only a paid
// post the account has bought carries more than one: such a post is a single message
// holding an album, and each file is fetched from /media by its idx.
struct IAyuMediaItem: Codable, Equatable {
    let idx: Int
    let kind: String
    let mime: String?
    let size: Int?
    let width: Int?
    let height: Int?
    let duration: Int?
    let fileName: String?

    enum CodingKeys: String, CodingKey {
        case idx
        case kind
        case mime
        case size
        case width
        case height
        case duration
        case fileName = "file_name"
    }
}

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
    // Who sent it, as a marked peer id. fromMe alone only says "mine or not", which is
    // enough for a DM but leaves a group message with no author. Absent for events the
    // server captured before it recorded senders — those stay attributed to the chat.
    let senderId: Int64?
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
    // Every file of the message, sent only when there is more than one — i.e. for a
    // paid post the account bought, which is one message carrying an album of up to
    // ten. The flattened media_* fields above are this list's first item, so an event
    // without it behaves exactly as before.
    let mediaItems: [IAyuMediaItem]?
    // LOCAL ONLY — the server never sends this. When a batch is made by collapsing
    // messages that were already in the chat, the media has already been downloaded and
    // there is no server message id left to fetch it by, so the media object itself is
    // carried here (PostboxEncoder, base64). Restoring such an entry needs no network.
    let mediaBlob: String?

    enum CodingKeys: String, CodingKey {
        case cursor
        case kind
        case chatId = "chat_id"
        case messageId = "message_id"
        case text
        case oldText = "old_text"
        case date
        case fromMe = "from_me"
        case senderId = "sender_id"
        case mediaKind = "media_kind"
        case mediaMime = "media_mime"
        case mediaSize = "media_size"
        case mediaWidth = "media_width"
        case mediaHeight = "media_height"
        case mediaDuration = "media_duration"
        case mediaViewOnce = "media_view_once"
        case mediaFileName = "media_file_name"
        case mediaItems = "media_items"
        case mediaBlob = "media_blob"
    }
}

extension IAyuMessageEvent {
    // The album this event has to materialize, or empty for the ordinary case of a
    // single file (which the flattened media_* fields already describe).
    var mediaAlbum: [IAyuMediaItem] {
        guard let items = self.mediaItems, items.count > 1 else {
            return []
        }
        return items
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

    // Tear the socket down BEFORE telling anyone it is gone. Without this the dead
    // session kept its task alive and its receive loop running: the server went on
    // counting the subscriber, and the old session kept delivering events beside its
    // replacement, until the reconnect timer got round to it 5–60s later. That is also
    // why the server's "disconnected" line marked the moment of cleanup rather than the
    // moment of the drop.
    private func notifyClosed() {
        guard self.active, !self.didNotifyClosed else { return }
        self.didNotifyClosed = true
        self.active = false
        self.task.cancel(with: .goingAway, reason: nil)
        self.onConnected?(false)
        self.onClosed?()
    }

    // Ask the socket, right now, whether it is still there. The keepalive runs on a 20s
    // cadence, which is too long to sit on when the app has just come back and the owner
    // is deciding whether to keep this socket or replace it — iOS can have killed it
    // while we were suspended with no error having surfaced yet.
    func probeAlive() {
        guard self.active else { return }
        self.task.sendPing { [weak self] error in
            guard let self = self, self.active, error != nil else { return }
            Queue.mainQueue().async {
                self.notifyClosed()
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

// The metadata one media builder needs, decoupled from where it came from: an
// ordinary event describes its single file in flattened media_* fields, while each
// file of a paid album describes itself in media_items.
struct IAyuMediaSpec {
    let idx: Int
    let kind: String
    let mime: String?
    let size: Int?
    let width: Int?
    let height: Int?
    let duration: Int?
    let fileName: String?

    init(event: IAyuMessageEvent) {
        self.idx = 0
        self.kind = event.mediaKind ?? ""
        self.mime = event.mediaMime
        self.size = event.mediaSize
        self.width = event.mediaWidth
        self.height = event.mediaHeight
        self.duration = event.mediaDuration
        self.fileName = event.mediaFileName
    }

    init(item: IAyuMediaItem) {
        self.idx = item.idx
        self.kind = item.kind
        self.mime = item.mime
        self.size = item.size
        self.width = item.width
        self.height = item.height
        self.duration = item.duration
        self.fileName = item.fileName
    }
}

// One preserved delete, ready to be written into Postbox. Media (if any) has already
// been fetched and stored in the media box by the time an item exists.
struct IAyuPendingDelete {
    let event: IAyuMessageEvent
    let media: [Media]
    let appendedNote: String?
    // Anything to carry beyond DeletedMessageAttribute. Used by the mass-deletion
    // summary, whose text entities hold the link that opens the collapsed batch.
    let extraAttributes: [MessageAttribute]
    // One entry per file of a paid album, when this delete is one. Telegram renders an
    // album as several messages sharing a groupingKey rather than as one message with
    // several media, so this becomes that many synthetic messages. Empty for everything
    // else, which stays exactly one message with `media`.
    let albumMedia: [[Media]]

    init(event: IAyuMessageEvent, media: [Media] = [], appendedNote: String? = nil, extraAttributes: [MessageAttribute] = [], albumMedia: [[Media]] = []) {
        self.event = event
        self.media = media
        self.appendedNote = appendedNote
        self.extraAttributes = extraAttributes
        self.albumMedia = albumMedia
    }
}

// What has to happen before an event can be materialized, decided without touching
// the network — so a caller draining a mass delete can insert everything cheap at
// once and pace only the downloads.
enum IAyuMaterializePlan {
    // Nothing to download: insert straight away, carrying an optional note in place
    // of media we deliberately skipped.
    case ready(String?)
    // Bytes have to come from the server's /media first.
    case needsMedia
}

func iAyuMaterializePlan(event: IAyuMessageEvent) -> IAyuMaterializePlan {
    guard let kind = event.mediaKind, iAyuKnownMediaKinds.contains(kind) else {
        return .ready(nil)
    }
    // A paid album is weighed as a whole: downloading half of one would be a worse
    // answer than describing it, and the parts stay on the server either way.
    let album = event.mediaAlbum
    if !album.isEmpty {
        let limitBytes = Int(SGSimpleSettings.shared.iaMediaMaxDownloadMB) * 1024 * 1024
        let total = album.reduce(0) { $0 + ($1.size ?? 0) }
        if limitBytes > 0, total > limitBytes {
            return .ready(iAyuSkippedMediaNote(event: event, size: total))
        }
        return .needsMedia
    }
    // Phase 2 lifted the server-side size limit, so a delete can now point at a
    // multi-hundred-megabyte video. Downloading that unasked would be hostile, so
    // respect a client-side budget: past it, preserve the message as text with a
    // note naming what was dropped. The bytes stay on the server, so raising the
    // limit later still recovers them via gap-sync.
    let limitBytes = Int(SGSimpleSettings.shared.iaMediaMaxDownloadMB) * 1024 * 1024
    if let size = event.mediaSize, limitBytes > 0, size > limitBytes {
        return .ready(iAyuSkippedMediaNote(event: event, size: size))
    }
    return .needsMedia
}

func iAyuMaterializeDeleted(context: AccountContext, event: IAyuMessageEvent) {
    switch iAyuMaterializePlan(event: event) {
    case let .ready(note):
        iAyuInsertDeleted(context: context, items: [IAyuPendingDelete(event: event, appendedNote: note)])
    case .needsMedia:
        iAyuFetchAndBuildMedia(context: context, event: event) { item in
            iAyuInsertDeleted(context: context, items: [item])
        }
    }
}

// Fetch an event's media to a temp file and turn it into Postbox media, calling back
// with an item ready to insert. A failed fetch still yields an item (without media),
// so the delete stays visible either way. The callback runs on a background queue.
func iAyuFetchAndBuildMedia(context: AccountContext, event: IAyuMessageEvent, completion: @escaping (IAyuPendingDelete) -> Void) {
    let album = event.mediaAlbum
    if album.isEmpty {
        iAyuFetchAndBuildOne(context: context, event: event, spec: IAyuMediaSpec(event: event)) { media in
            completion(IAyuPendingDelete(event: event, media: media))
        }
        return
    }
    // A paid album, one file at a time rather than all at once: ten videos in flight
    // for a single preserved post is the same mistake mass deletion already taught us,
    // and the album has to be assembled in order anyway.
    var built: [[Media]] = []
    func fetchNext(_ index: Int) {
        guard index < album.count else {
            // Files that failed to download leave empty entries; drop them so the
            // album is what actually arrived, and fall back to a plain (media-less)
            // message when nothing did.
            let usable = built.filter { !$0.isEmpty }
            completion(IAyuPendingDelete(
                event: event,
                media: usable.first ?? [],
                albumMedia: usable.count > 1 ? usable : []
            ))
            return
        }
        iAyuFetchAndBuildOne(context: context, event: event, spec: IAyuMediaSpec(item: album[index])) { media in
            built.append(media)
            fetchNext(index + 1)
        }
    }
    fetchNext(0)
}

// Fetch one file of an event and turn it into Postbox media. The callback runs on a
// background queue, with an empty array when the download or the decode failed — the
// delete still has to appear either way.
private func iAyuFetchAndBuildOne(context: AccountContext, event: IAyuMessageEvent, spec: IAyuMediaSpec, completion: @escaping ([Media]) -> Void) {
    iAyuFetchMediaFile(event: event, idx: spec.idx) { path, size in
        var media: [Media] = []
        let postbox = context.account.postbox
        if let path = path {
            if spec.kind == "photo" || spec.kind == "sticker" {
                // Images are small; map the file rather than reading it onto the heap.
                let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                if let data = data {
                    if spec.kind == "photo", let image = iAyuBuildPhotoMedia(postbox: postbox, data: data, spec: spec) {
                        media = [image]
                    } else if let sticker = iAyuBuildStickerMedia(postbox: postbox, data: data, spec: spec) {
                        media = [sticker]
                    }
                }
                try? FileManager.default.removeItem(atPath: path)
            } else if let file = iAyuBuildFileMedia(postbox: postbox, path: path, size: size, spec: spec) {
                // Consumes the temp file (moved into the media box).
                media = [file]
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        completion(media)
    }
}

// What to call a piece of media we are describing rather than showing — because it was
// too big to download, or because it belongs to a collapsed mass deletion.
func iAyuMediaKindLabel(kind: String?, fileName: String?) -> String {
    switch kind {
    case "video": return IAyuStrings.text(.mediaVideo)
    case "gif": return IAyuStrings.text(.mediaGif)
    case "audio": return IAyuStrings.text(.mediaAudio)
    case "document": return fileName ?? IAyuStrings.text(.mediaFile)
    case "photo": return IAyuStrings.text(.mediaPhoto)
    case "voice": return IAyuStrings.text(.mediaVoice)
    case "round": return IAyuStrings.text(.mediaRound)
    default: return IAyuStrings.text(.mediaGeneric)
    }
}

// Human-readable note for media that was preserved on the server but not downloaded.
private func iAyuSkippedMediaNote(event: IAyuMessageEvent, size: Int) -> String {
    let megabytes = max(1, size / (1024 * 1024))
    let label = iAyuMediaKindLabel(kind: event.mediaKind, fileName: event.mediaFileName)
    return IAyuStrings.text(.mediaSkippedNote, ["kind": label, "size": "\(megabytes)"])
}

// Insert preserved deletes. Everything handed in goes into ONE postbox transaction:
// a transaction per message is what made deleting a whole chat unusable, because each
// commit re-runs the history view and the chat-list counters, so a few hundred deletes
// meant a few hundred full view recomputations back to back.
func iAyuInsertDeleted(context: AccountContext, items: [IAyuPendingDelete]) {
    if items.isEmpty {
        return
    }
    let accountPeerId = context.account.peerId
    let _ = (context.account.postbox.transaction { transaction -> Void in
        let messages = items.flatMap { item -> [StoreMessage] in
            guard item.albumMedia.count > 1 else {
                return [iAyuDeletedStoreMessage(item: item, accountPeerId: accountPeerId, transaction: transaction)]
            }
            // An album is N messages sharing a groupingKey — that is how Telegram
            // itself renders one, and a single message holding N media would draw
            // only the first. The caption goes on the first message alone, the way
            // an album's caption does.
            let groupingKey = Int64.random(in: 1 ... Int64.max)
            return item.albumMedia.enumerated().map { index, media in
                iAyuDeletedStoreMessage(
                    item: item, accountPeerId: accountPeerId, transaction: transaction,
                    mediaOverride: media, groupingKey: groupingKey, includeText: index == 0
                )
            }
        }
        let _ = transaction.addMessages(messages, location: .Random)
    }).start()
}

// Build the synthetic local message for one preserved delete. Takes the transaction
// because resolving the author needs a database lookup.
func iAyuDeletedStoreMessage(item: IAyuPendingDelete, accountPeerId: PeerId, transaction: Transaction, mediaOverride: [Media]? = nil, groupingKey: Int64? = nil, includeText: Bool = true) -> StoreMessage {
    let event = item.event
    let media = mediaOverride ?? item.media
    let appendedNote = item.appendedNote
    let peerId = iAyuPeerId(fromServerChatId: event.chatId)
    // Render on the correct side: the server tells us whether WE sent the original
    // (from_me). Outgoing → author is us, no Incoming flag. Incoming → author is the
    // DM partner (for groups/channels we don't know the exact sender, best-effort).
    let fromMe = event.fromMe ?? false
    var flags = StoreMessageFlags()
    var authorId = accountPeerId
    if !fromMe {
        flags.insert(.Incoming)
        // Attribute the copy to whoever actually sent it. In a DM the chat and the
        // sender are the same peer, but in a group they are not — without a sender the
        // preserved message was authored by the group itself, which is what the user
        // saw. Events captured before the server recorded senders have none, so those
        // keep the old behaviour rather than losing an author entirely.
        authorId = event.senderId.map { iAyuPeerId(fromServerChatId: $0) } ?? peerId
    }
    // Prefer the original message time so the placeholder lands in place; fall back
    // to now (bottom of the chat) rather than epoch (which would bury it at the top).
    let timestamp = event.date.map { Int32(clamping: $0) } ?? Int32(Date().timeIntervalSince1970)
    var text = includeText ? (event.text ?? "") : ""
    if includeText, let appendedNote = appendedNote {
        text = text.isEmpty ? appendedNote : "\(text)\n\(appendedNote)"
    }
    // The author has to be a peer this database actually knows, or the bubble draws
    // a blank name. A group member we have never otherwise seen is exactly that
    // case, and attributing to the chat is a better answer than to nobody.
    var resolvedAuthorId = authorId
    if resolvedAuthorId != peerId, transaction.getPeer(resolvedAuthorId) == nil {
        resolvedAuthorId = peerId
    }
    return StoreMessage(
        peerId: peerId,
        namespace: Namespaces.Message.Local,
        customStableId: nil,
        globallyUniqueId: nil,
        groupingKey: groupingKey,
        threadId: nil,
        timestamp: timestamp,
        flags: flags,
        tags: [],
        globalTags: [],
        localTags: [],
        forwardInfo: nil,
        authorId: resolvedAuthorId,
        text: text,
        attributes: [DeletedMessageAttribute(date: timestamp)] + item.extraAttributes,
        media: media
    )
}

// Build a local-image media from downloaded bytes: write the bytes into the media
// box under a fresh local resource, then reference it. The image node loads the
// cached bytes when the message is displayed (no Telegram CDN round-trip).
private func iAyuBuildPhotoMedia(postbox: Postbox, data: Data, spec: IAyuMediaSpec) -> TelegramMediaImage? {
    let fileId = Int64.random(in: Int64.min ... Int64.max)
    let resource = LocalFileMediaResource(fileId: fileId, size: Int64(data.count))
    postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
    let width = Int32(spec.width ?? 0)
    let height = Int32(spec.height ?? 0)
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
private func iAyuBuildFileMedia(postbox: Postbox, path: String, size: Int64, spec: IAyuMediaSpec) -> TelegramMediaFile? {
    let fileId = Int64.random(in: Int64.min ... Int64.max)
    let resource = LocalFileMediaResource(fileId: fileId, size: size)
    postbox.mediaBox.moveResourceData(resource.id, fromTempPath: path)
    let duration = spec.duration ?? 0
    let width = Int32(spec.width ?? 0)
    let height = Int32(spec.height ?? 0)
    var attributes: [TelegramMediaFileAttribute] = []
    let mimeType: String

    switch spec.kind {
    case "voice":
        attributes.append(.Audio(isVoice: true, duration: duration, title: nil, performer: nil, waveform: nil))
        mimeType = spec.mime ?? "audio/ogg"
    case "audio":
        // Music, as opposed to a voice note: keep it a playable audio file.
        attributes.append(.Audio(isVoice: false, duration: duration, title: nil, performer: nil, waveform: nil))
        attributes.append(.FileName(fileName: spec.fileName ?? "audio.mp3"))
        mimeType = spec.mime ?? "audio/mpeg"
    case "document":
        // No Video/Audio attribute → renders as a file row with the original name.
        attributes.append(.FileName(fileName: spec.fileName ?? "file"))
        mimeType = spec.mime ?? "application/octet-stream"
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
        attributes.append(.FileName(fileName: spec.fileName ?? "animation.mp4"))
        mimeType = spec.mime ?? "video/mp4"
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
        attributes.append(.FileName(fileName: spec.fileName ?? "video.mp4"))
        mimeType = spec.mime ?? "video/mp4"
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
private func iAyuBuildStickerMedia(postbox: Postbox, data: Data, spec: IAyuMediaSpec) -> TelegramMediaFile? {
    let fileId = Int64.random(in: Int64.min ... Int64.max)
    let resource = LocalFileMediaResource(fileId: fileId, size: Int64(data.count))
    postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
    let width = Int32(spec.width ?? 0)
    let height = Int32(spec.height ?? 0)
    let mimeType = spec.mime ?? "image/webp"
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
private func iAyuFetchMediaFile(event: IAyuMessageEvent, idx: Int = 0, completion: @escaping (String?, Int64) -> Void) {
    let serverURL = SGSimpleSettings.shared.iaSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = SGSimpleSettings.shared.iaSyncClientToken
    guard !serverURL.isEmpty, !token.isEmpty,
          var components = URLComponents(string: serverURL.contains("://") ? serverURL : "https://\(serverURL)") else {
        completion(nil, 0)
        return
    }
    components.path = "/media"
    var queryItems = [
        URLQueryItem(name: "chat_id", value: "\(event.chatId)"),
        URLQueryItem(name: "message_id", value: "\(event.messageId)"),
    ]
    if idx != 0 {
        // Only a paid album goes past 0, and omitting it keeps the request identical
        // to what servers older than album support answer.
        queryItems.append(URLQueryItem(name: "idx", value: "\(idx)"))
    }
    components.queryItems = queryItems
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
            .appendingPathComponent("iayu_media_\(event.chatId)_\(event.messageId)_\(idx)")
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
    let toggleSignal: (IAyuGhostSignal, Bool) -> Void
    let toggleLock: (IAyuGhostSignal) -> Void
    let toggleInvisibleSend: (Bool) -> Void
    let toggleRestoreOwnDeletes: (Bool) -> Void
    let pickMediaCap: () -> Void
    let pickMassDeleteThreshold: () -> Void
    let pickMassDeleteGlobalThreshold: () -> Void
    let togglePinnedOverBot: (Bool) -> Void
    let toggleHideBotPanel: (Bool) -> Void
    let explainBotPanelLock: () -> Void
    let toggleInfiniteRoundVideos: (Bool) -> Void
    let toggleGlobalVoiceRecording: (Bool) -> Void
    let openAppearance: () -> Void
    let openLocalization: () -> Void
    let openConnection: () -> Void

    init(toggleSignal: @escaping (IAyuGhostSignal, Bool) -> Void, toggleLock: @escaping (IAyuGhostSignal) -> Void, toggleInvisibleSend: @escaping (Bool) -> Void, toggleRestoreOwnDeletes: @escaping (Bool) -> Void, pickMediaCap: @escaping () -> Void, pickMassDeleteThreshold: @escaping () -> Void, pickMassDeleteGlobalThreshold: @escaping () -> Void, togglePinnedOverBot: @escaping (Bool) -> Void, toggleHideBotPanel: @escaping (Bool) -> Void, explainBotPanelLock: @escaping () -> Void, toggleInfiniteRoundVideos: @escaping (Bool) -> Void, toggleGlobalVoiceRecording: @escaping (Bool) -> Void, openAppearance: @escaping () -> Void, openLocalization: @escaping () -> Void, openConnection: @escaping () -> Void) {
        self.toggleSignal = toggleSignal
        self.toggleLock = toggleLock
        self.toggleInvisibleSend = toggleInvisibleSend
        self.toggleRestoreOwnDeletes = toggleRestoreOwnDeletes
        self.pickMediaCap = pickMediaCap
        self.pickMassDeleteThreshold = pickMassDeleteThreshold
        self.pickMassDeleteGlobalThreshold = pickMassDeleteGlobalThreshold
        self.togglePinnedOverBot = togglePinnedOverBot
        self.toggleHideBotPanel = toggleHideBotPanel
        self.explainBotPanelLock = explainBotPanelLock
        self.toggleInfiniteRoundVideos = toggleInfiniteRoundVideos
        self.toggleGlobalVoiceRecording = toggleGlobalVoiceRecording
        self.openAppearance = openAppearance
        self.openLocalization = openLocalization
        self.openConnection = openConnection
    }
}

// The five ghost signals in display order, with their row titles. Order is fixed here
// so the entry ids stay stable.
private let iAyuGhostRows: [(signal: IAyuGhostSignal, key: IAyuStringKey)] = [
    (.hideReadReceipts, .hubGhostHideReadReceipts),
    (.stayOffline, .hubGhostStayOffline),
    (.hideTyping, .hubGhostHideTyping),
    (.hideConsumed, .hubGhostHideConsumed),
    (.hideStoryViews, .hubGhostHideStoryViews)
]

// The padlock shown to the left of a locked signal. Drawn from an SF Symbol rather than
// a bundled asset: it is the one glyph we need and it already matches the system look.
private func iAyuLockIcon(locked: Bool, theme: PresentationTheme) -> UIImage? {
    guard locked else {
        return nil
    }
    let image = UIImage(systemName: "lock.fill")?.withRenderingMode(.alwaysTemplate)
    return generateTintedImage(image: image, color: theme.list.itemSecondaryTextColor)
}

private enum IAyuHubSection: Int32 {
    case ghost
    case send
    case preserve
    case media
    case massDelete
    case botPanel
    case roundVideo
    case voiceRecording
    case screens
}

// Offered collapse thresholds: how many deletes in one burst make a mass deletion.
// 0 disables collapsing, which brings back the old behaviour of materializing every
// single message — including the whole of a wiped chat.
private let iAyuMassDeleteOptions: [Int32] = [0, 25, 50, 100, 200]

private func iAyuMassDeleteLabel(_ count: Int32) -> String {
    if count <= 0 {
        return IAyuStrings.text(.hubMassDeleteNever)
    }
    return "\(count)"
}

// Deletes counted across ALL chats in one sync run, past which collapsing arms
// everywhere. 0 leaves only the per-chat rule. The small values are here on purpose:
// the case this defends against — many chats, few deletes each — is impractical to
// reproduce at its real size, so the threshold has to be lowerable enough that three
// chats with two deletes apiece exercise the same code path.
private let iAyuMassDeleteGlobalOptions: [Int32] = [0, 5, 100, 300, 1000]

private func iAyuMassDeleteGlobalLabel(_ count: Int32) -> String {
    if count <= 0 {
        return IAyuStrings.text(.hubMassDeleteGlobalNever)
    }
    return "\(count)"
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
    // One case for all five signals: index into iAyuGhostRows, title, value, locked.
    case ghostSignal(Int32, String, Bool, Bool)
    case ghostInfo(String)
    case ghostLockHint(String)
    case sendHeader(String)
    case sendInvisible(String, Bool)
    case sendInfo(String)
    case preserveHeader(String)
    case restoreOwnDeletes(String, Bool)
    case preserveInfo(String)
    case mediaHeader(String)
    case mediaCap(String, Int32)
    case mediaInfo(String)
    case massDeleteHeader(String)
    case massDeleteThreshold(String, Int32)
    case massDeleteGlobalThreshold(String, Int32)
    case massDeleteInfo(String)
    case botPanelHeader(String)
    // Title, value, and whether the row is still meaningful (it is not once the panel
    // is hidden outright).
    case botPanelPinnedFirst(String, Bool, Bool)
    case botPanelHide(String, Bool)
    case botPanelInfo(String)
    case roundVideoHeader(String)
    case infiniteRoundVideos(String, Bool)
    case roundVideoInfo(String)
    case voiceRecordingHeader(String)
    case globalVoiceRecording(String, Bool)
    case voiceRecordingInfo(String)
    case appearance(String)
    case localization(String)
    case connection(String)

    var section: ItemListSectionId {
        switch self {
        case .ghostHeader, .ghostSignal, .ghostInfo, .ghostLockHint:
            return IAyuHubSection.ghost.rawValue
        case .sendHeader, .sendInvisible, .sendInfo:
            return IAyuHubSection.send.rawValue
        case .preserveHeader, .restoreOwnDeletes, .preserveInfo:
            return IAyuHubSection.preserve.rawValue
        case .mediaHeader, .mediaCap, .mediaInfo:
            return IAyuHubSection.media.rawValue
        case .massDeleteHeader, .massDeleteThreshold, .massDeleteGlobalThreshold, .massDeleteInfo:
            return IAyuHubSection.massDelete.rawValue
        case .botPanelHeader, .botPanelPinnedFirst, .botPanelHide, .botPanelInfo:
            return IAyuHubSection.botPanel.rawValue
        case .roundVideoHeader, .infiniteRoundVideos, .roundVideoInfo:
            return IAyuHubSection.roundVideo.rawValue
        case .voiceRecordingHeader, .globalVoiceRecording, .voiceRecordingInfo:
            return IAyuHubSection.voiceRecording.rawValue
        case .appearance, .localization, .connection:
            return IAyuHubSection.screens.rawValue
        }
    }

    // Ten per section, so a new row never needs a fractional id. These had drifted out of
    // display order — sections appended later carried ids larger than the screens below
    // them, which only stayed invisible because the order comes from the entries array
    // rather than from sorting. Renumbered rather than extended a fourth time.
    var stableId: Int32 {
        switch self {
        case .ghostHeader: return 0
        // 1...19 belong to the ghost signals.
        case let .ghostSignal(index, _, _, _): return 1 + index
        case .ghostInfo: return 20
        case .ghostLockHint: return 21
        case .sendHeader: return 30
        case .sendInvisible: return 31
        case .sendInfo: return 32
        case .preserveHeader: return 40
        case .restoreOwnDeletes: return 41
        case .preserveInfo: return 42
        case .mediaHeader: return 50
        case .mediaCap: return 51
        case .mediaInfo: return 52
        case .massDeleteHeader: return 60
        case .massDeleteThreshold: return 61
        case .massDeleteGlobalThreshold: return 62
        case .massDeleteInfo: return 63
        case .botPanelHeader: return 70
        case .botPanelPinnedFirst: return 71
        case .botPanelHide: return 72
        case .botPanelInfo: return 73
        case .roundVideoHeader: return 80
        case .infiniteRoundVideos: return 81
        case .roundVideoInfo: return 82
        case .voiceRecordingHeader: return 85
        case .globalVoiceRecording: return 86
        case .voiceRecordingInfo: return 87
        case .appearance: return 90
        case .localization: return 91
        case .connection: return 92
        }
    }

    static func <(lhs: IAyuHubEntry, rhs: IAyuHubEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: IAyuHubEntry, rhs: IAyuHubEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.ghostHeader(a), .ghostHeader(b)):
            return a == b
        case let (.ghostSignal(a1, a2, a3, a4), .ghostSignal(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.ghostInfo(a), .ghostInfo(b)):
            return a == b
        case let (.ghostLockHint(a), .ghostLockHint(b)):
            return a == b
        case let (.sendHeader(a), .sendHeader(b)):
            return a == b
        case let (.sendInvisible(a1, a2), .sendInvisible(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.sendInfo(a), .sendInfo(b)):
            return a == b
        case let (.preserveHeader(a), .preserveHeader(b)):
            return a == b
        case let (.restoreOwnDeletes(a1, a2), .restoreOwnDeletes(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.preserveInfo(a), .preserveInfo(b)):
            return a == b
        case let (.mediaHeader(a), .mediaHeader(b)):
            return a == b
        case let (.mediaCap(a1, a2), .mediaCap(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.mediaInfo(a), .mediaInfo(b)):
            return a == b
        case let (.massDeleteHeader(a), .massDeleteHeader(b)):
            return a == b
        case let (.massDeleteThreshold(a1, a2), .massDeleteThreshold(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.massDeleteGlobalThreshold(a1, a2), .massDeleteGlobalThreshold(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.massDeleteInfo(a), .massDeleteInfo(b)):
            return a == b
        case let (.botPanelHeader(a), .botPanelHeader(b)):
            return a == b
        case let (.botPanelPinnedFirst(a1, a2, a3), .botPanelPinnedFirst(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.botPanelHide(a1, a2), .botPanelHide(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.botPanelInfo(a), .botPanelInfo(b)):
            return a == b
        case let (.roundVideoHeader(a), .roundVideoHeader(b)):
            return a == b
        case let (.infiniteRoundVideos(a1, a2), .infiniteRoundVideos(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.roundVideoInfo(a), .roundVideoInfo(b)):
            return a == b
        case let (.voiceRecordingHeader(a), .voiceRecordingHeader(b)):
            return a == b
        case let (.globalVoiceRecording(a1, a2), .globalVoiceRecording(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.voiceRecordingInfo(a), .voiceRecordingInfo(b)):
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
        case let .ghostSignal(index, title, value, locked):
            let signal = iAyuGhostRows[Int(index)].signal
            // The switch changes the signal; tapping the row toggles the lock, and the
            // padlock in the icon slot is what shows the lock is on. Two actions on one
            // row is unusual, so the footnote below the section spells it out.
            return ItemListSwitchItem(
                presentationData: presentationData,
                icon: iAyuLockIcon(locked: locked, theme: presentationData.theme),
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { newValue in
                    arguments.toggleSignal(signal, newValue)
                },
                action: {
                    arguments.toggleLock(signal)
                }
            )
        case let .ghostInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .ghostLockHint(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .sendHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .sendInvisible(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleInvisibleSend(newValue)
            })
        case let .sendInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .preserveHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .restoreOwnDeletes(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleRestoreOwnDeletes(newValue)
            })
        case let .preserveInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .mediaHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .mediaCap(title, mb):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: iAyuMediaCapLabel(mb), sectionId: self.section, style: .blocks, action: {
                arguments.pickMediaCap()
            })
        case let .mediaInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .massDeleteHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .massDeleteThreshold(title, count):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: iAyuMassDeleteLabel(count), sectionId: self.section, style: .blocks, action: {
                arguments.pickMassDeleteThreshold()
            })
        case let .massDeleteGlobalThreshold(title, count):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: iAyuMassDeleteGlobalLabel(count), sectionId: self.section, style: .blocks, action: {
                arguments.pickMassDeleteGlobalThreshold()
            })
        case let .massDeleteInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .botPanelHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .botPanelPinnedFirst(title, value, enabled):
            // Greyed out, not hidden, once the panel is gone entirely: the row would
            // otherwise appear and disappear as the switch below is flipped. Tapping it
            // while disabled explains why instead of doing nothing.
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.togglePinnedOverBot(newValue)
            }, activatedWhileDisabled: {
                arguments.explainBotPanelLock()
            })
        case let .botPanelHide(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleHideBotPanel(newValue)
            })
        case let .botPanelInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .roundVideoHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .infiniteRoundVideos(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleInfiniteRoundVideos(newValue)
            })
        case let .roundVideoInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .voiceRecordingHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .globalVoiceRecording(title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { newValue in
                arguments.toggleGlobalVoiceRecording(newValue)
            })
        case let .voiceRecordingInfo(text):
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
    // Indexed by iAyuGhostRows, so adding a signal does not mean adding a field here
    // and then remembering to wire it in four other places.
    var signals: [Bool]
    var locks: [Bool]
    var invisibleSend: Bool
    var restoreOwnDeletes: Bool
    var mediaCapMB: Int32
    var massDeleteThreshold: Int32
    var massDeleteGlobalThreshold: Int32
    var pinnedOverBot: Bool
    var hideBotPanel: Bool
    var infiniteRoundVideos: Bool
    var globalVoiceRecording: Bool
}

public func iAyuGramSettingsController(context: AccountContext) -> ViewController {
    let initialState = IAyuHubState(
        signals: iAyuGhostRows.map { $0.signal.isEnabled },
        locks: iAyuGhostRows.map { $0.signal.isLocked },
        invisibleSend: SGSimpleSettings.shared.iaGhostInvisibleSend,
        restoreOwnDeletes: SGSimpleSettings.shared.iaRestoreOwnDeletes,
        mediaCapMB: SGSimpleSettings.shared.iaMediaMaxDownloadMB,
        massDeleteThreshold: SGSimpleSettings.shared.iaMassDeleteCollapse,
        massDeleteGlobalThreshold: SGSimpleSettings.shared.iaMassDeleteGlobalCollapse,
        pinnedOverBot: SGSimpleSettings.shared.iaPinnedOverBusinessBot,
        hideBotPanel: SGSimpleSettings.shared.iaHideBusinessBotPanel,
        infiniteRoundVideos: SGSimpleSettings.shared.iaInfiniteRoundVideos,
        globalVoiceRecording: SGSimpleSettings.shared.iaGlobalVoiceRecording
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((IAyuHubState) -> IAyuHubState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?

    let arguments = IAyuHubArguments(toggleSignal: { signal, value in
        signal.setEnabled(value)
        updateState { state in
            var state = state
            if let index = iAyuGhostRows.firstIndex(where: { $0.signal == signal }) {
                state.signals[index] = value
            }
            return state
        }
    }, toggleLock: { signal in
        let newValue = !signal.isLocked
        signal.setLocked(newValue)
        updateState { state in
            var state = state
            if let index = iAyuGhostRows.firstIndex(where: { $0.signal == signal }) {
                state.locks[index] = newValue
            }
            return state
        }
    }, toggleInvisibleSend: { value in
        SGSimpleSettings.shared.iaGhostInvisibleSend = value
        updateState { state in
            var state = state
            state.invisibleSend = value
            return state
        }
    }, toggleRestoreOwnDeletes: { value in
        SGSimpleSettings.shared.iaRestoreOwnDeletes = value
        updateState { state in
            var state = state
            state.restoreOwnDeletes = value
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
    }, pickMassDeleteThreshold: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var dismissImpl: (() -> Void)?
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: IAyuStrings.text(.hubMassDeleteThreshold))]
        for option in iAyuMassDeleteOptions {
            items.append(ActionSheetButtonItem(title: iAyuMassDeleteLabel(option), action: {
                dismissImpl?()
                SGSimpleSettings.shared.iaMassDeleteCollapse = option
                updateState { state in
                    var state = state
                    state.massDeleteThreshold = option
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
    }, pickMassDeleteGlobalThreshold: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var dismissImpl: (() -> Void)?
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: IAyuStrings.text(.hubMassDeleteGlobalThreshold))]
        for option in iAyuMassDeleteGlobalOptions {
            items.append(ActionSheetButtonItem(title: iAyuMassDeleteGlobalLabel(option), action: {
                dismissImpl?()
                SGSimpleSettings.shared.iaMassDeleteGlobalCollapse = option
                updateState { state in
                    var state = state
                    state.massDeleteGlobalThreshold = option
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
    }, togglePinnedOverBot: { value in
        SGSimpleSettings.shared.iaPinnedOverBusinessBot = value
        updateState { state in
            var state = state
            state.pinnedOverBot = value
            return state
        }
    }, toggleHideBotPanel: { value in
        SGSimpleSettings.shared.iaHideBusinessBotPanel = value
        updateState { state in
            var state = state
            state.hideBotPanel = value
            return state
        }
    }, explainBotPanelLock: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(context: context, title: nil, text: IAyuStrings.text(.hubBotPanelLockedHint), actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]))
    }, toggleInfiniteRoundVideos: { value in
        SGSimpleSettings.shared.iaInfiniteRoundVideos = value
        updateState { state in
            var state = state
            state.infiniteRoundVideos = value
            return state
        }
    }, toggleGlobalVoiceRecording: { value in
        SGSimpleSettings.shared.iaGlobalVoiceRecording = value
        updateState { state in
            var state = state
            state.globalVoiceRecording = value
            return state
        }
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
        for (index, row) in iAyuGhostRows.enumerated() {
            entries.append(.ghostSignal(Int32(index), IAyuStrings.text(row.key), state.signals[index], state.locks[index]))
        }
        entries.append(.ghostInfo(IAyuStrings.text(.hubGhostInfo)))
        entries.append(.ghostLockHint(IAyuStrings.text(.hubGhostLockHint)))
        entries.append(.sendHeader(IAyuStrings.text(.hubSendHeader)))
        entries.append(.sendInvisible(IAyuStrings.text(.hubGhostInvisibleSend), state.invisibleSend))
        entries.append(.sendInfo(IAyuStrings.text(.hubSendInfo)))
        entries.append(.preserveHeader(IAyuStrings.text(.hubPreserveHeader)))
        entries.append(.restoreOwnDeletes(IAyuStrings.text(.hubRestoreOwnDeletes), state.restoreOwnDeletes))
        entries.append(.preserveInfo(IAyuStrings.text(.hubPreserveInfo)))
        entries.append(.mediaHeader(IAyuStrings.text(.hubMediaHeader)))
        entries.append(.mediaCap(IAyuStrings.text(.hubMediaCap), state.mediaCapMB))
        entries.append(.mediaInfo(IAyuStrings.text(.hubMediaInfo)))
        entries.append(.massDeleteHeader(IAyuStrings.text(.hubMassDeleteHeader)))
        entries.append(.massDeleteThreshold(IAyuStrings.text(.hubMassDeleteThreshold), state.massDeleteThreshold))
        entries.append(.massDeleteGlobalThreshold(IAyuStrings.text(.hubMassDeleteGlobalThreshold), state.massDeleteGlobalThreshold))
        entries.append(.massDeleteInfo(IAyuStrings.text(.hubMassDeleteInfo)))
        entries.append(.botPanelHeader(IAyuStrings.text(.hubBotPanelHeader)))
        entries.append(.botPanelPinnedFirst(IAyuStrings.text(.hubBotPanelPinnedFirst), state.pinnedOverBot, !state.hideBotPanel))
        entries.append(.botPanelHide(IAyuStrings.text(.hubBotPanelHide), state.hideBotPanel))
        entries.append(.botPanelInfo(IAyuStrings.text(.hubBotPanelInfo)))
        entries.append(.roundVideoHeader(IAyuStrings.text(.hubRoundVideoHeader)))
        entries.append(.infiniteRoundVideos(IAyuStrings.text(.hubRoundVideoInfinite), state.infiniteRoundVideos))
        entries.append(.roundVideoInfo(IAyuStrings.text(.hubRoundVideoInfo)))
        entries.append(.voiceRecordingHeader(IAyuStrings.text(.hubVoiceRecordingHeader)))
        entries.append(.globalVoiceRecording(IAyuStrings.text(.hubVoiceRecordingGlobal), state.globalVoiceRecording))
        entries.append(.voiceRecordingInfo(IAyuStrings.text(.hubVoiceRecordingInfo)))
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
