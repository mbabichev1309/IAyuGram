import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SGSimpleSettings

// IAyuGram: collapse preserved messages that are ALREADY in a chat into one summary,
// the same shape the live path produces. Needed because collapsing was added after the
// damage: a chat wiped before this existed came back as a few thousand bubbles, and
// nothing retroactive would have removed them.
//
// The messages are not thrown away. Each one is archived into the same batch store the
// live path writes, carrying its media with it (there is no server message id left to
// fetch that media by, so the media object itself is encoded into the entry), then the
// local messages are removed and a single summary is inserted in their place. Every one
// of them can still be read and restored from the summary's screen.

// The inverse of iAyuPeerId(fromServerChatId:) — the batch store speaks the server's
// marked-id convention, and an archived entry has to look like any other.
func iAyuServerChatId(fromPeerId peerId: PeerId) -> Int64 {
    let id = peerId.id._internalGetInt64Value()
    switch peerId.namespace {
    case Namespaces.Peer.CloudChannel:
        return -(1_000_000_000_000 + id)
    case Namespaces.Peer.CloudGroup:
        return -id
    default:
        return id
    }
}

// What to call the media of an already-materialized message. The wire "kind" is not
// stored on the message, so it is read back off the media itself.
private func iAyuMediaKind(_ media: Media) -> (kind: String, fileName: String?)? {
    if media is TelegramMediaImage {
        return ("photo", nil)
    }
    guard let file = media as? TelegramMediaFile else {
        return nil
    }
    if file.isSticker || file.isAnimatedSticker || file.isVideoSticker {
        return ("sticker", nil)
    }
    if file.isVoice {
        return ("voice", nil)
    }
    if file.isInstantVideo {
        return ("round", nil)
    }
    if file.isAnimated {
        return ("gif", file.fileName)
    }
    if file.isMusic {
        return ("audio", file.fileName)
    }
    if file.isVideo {
        return ("video", file.fileName)
    }
    return ("document", file.fileName)
}

// A preserved message is one of ours: local namespace, carrying DeletedMessageAttribute.
// A summary is one too, so it is recognized by its link entity and left alone — otherwise
// collapsing twice would swallow the previous summary and orphan its batch.
private func iAyuIsCollapsible(_ message: Message) -> Bool {
    var isPreserved = false
    for attribute in message.attributes {
        if attribute is DeletedMessageAttribute {
            isPreserved = true
        }
        if let entities = attribute as? TextEntitiesMessageAttribute {
            for entity in entities.entities {
                if case let .TextUrl(url) = entity.type, iAyuIsMassDeleteURL(url) {
                    return false
                }
            }
        }
    }
    return isPreserved
}

// How many preserved messages this chat holds — what the confirmation is about.
public func iAyuCountCollapsibleDeletes(context: AccountContext, peerId: PeerId, completion: @escaping (Int) -> Void) {
    let _ = (context.account.postbox.transaction { transaction -> Int in
        var count = 0
        transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Local, reversed: false, { message in
            if iAyuIsCollapsible(message) {
                count += 1
            }
            return true
        })
        return count
    }
    |> deliverOnMainQueue).start(next: completion)
}

// Archive, remove, summarize. Reports how many were collapsed.
public func iAyuCollapseExistingDeletes(context: AccountContext, peerId: PeerId, completion: @escaping (Int) -> Void) {
    let chatId = iAyuServerChatId(fromPeerId: peerId)
    let accountPeerId = context.account.peerId

    // Read first, write the files, then mutate — file I/O has no business running
    // inside a postbox transaction, and a wiped chat is a few thousand entries.
    let _ = (context.account.postbox.transaction { transaction -> [(MessageId, IAyuMessageEvent)] in
        var result: [(MessageId, IAyuMessageEvent)] = []
        transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Local, reversed: false, { message in
            if iAyuIsCollapsible(message) {
                result.append((message.id, iAyuArchivedEvent(message: message, chatId: chatId)))
            }
            return true
        })
        return result
    }
    |> deliverOnMainQueue).start(next: { archived in
        guard !archived.isEmpty else {
            completion(0)
            return
        }
        let batch = IAyuDeletedBatchKey(peerId: peerId.toInt64(), batchId: Int64(Date().timeIntervalSince1970 * 1000.0))
        for (_, event) in archived {
            IAyuDeletedBatchStore.shared.append(key: batch, event: event)
        }
        IAyuDeletedBatchStore.shared.close(key: batch)

        let timestamp = archived.compactMap { $0.1.date }.max().map { Int32(clamping: $0) }
        let plaque = iAyuMassDeletePlaqueItem(key: batch, chatId: chatId, count: archived.count, timestamp: timestamp)
        let ids = archived.map { $0.0 }
        let _ = (context.account.postbox.transaction { transaction -> Void in
            // forEachMedia is nil on purpose: the archived entries reference exactly
            // these resources by id, so nothing here may take the bytes away.
            transaction.deleteMessages(ids, forEachMedia: nil)
            let _ = transaction.addMessages([iAyuDeletedStoreMessage(item: plaque, accountPeerId: accountPeerId, transaction: transaction)], location: .Random)
            // The summary is an incoming local message like any other preserved copy,
            // so it lands in the chat's unread count unless it is read right here.
            iAyuClearPreservedUnread(transaction: transaction, peerId: peerId)
        }
        |> deliverOnMainQueue).start(completed: {
            completion(archived.count)
        })
    })
}

// One already-materialized message, as a batch-store entry. messageId is 0: the server
// id it once had was never kept, which is why the media travels inside the entry.
private func iAyuArchivedEvent(message: Message, chatId: Int64) -> IAyuMessageEvent {
    var mediaKind: String?
    var mediaFileName: String?
    var mediaBlob: String?
    if let media = message.media.first {
        if let described = iAyuMediaKind(media) {
            mediaKind = described.kind
            mediaFileName = described.fileName
        }
        let encoder = PostboxEncoder()
        encoder.encodeRootObject(media)
        mediaBlob = encoder.makeData().base64EncodedString()
    }
    let fromMe = !message.flags.contains(.Incoming)
    return IAyuMessageEvent(
        cursor: 0,
        kind: "deleted",
        chatId: chatId,
        messageId: 0,
        text: message.text,
        oldText: nil,
        date: Int(message.timestamp),
        fromMe: fromMe,
        senderId: message.author.map { iAyuServerChatId(fromPeerId: $0.id) },
        mediaKind: mediaKind,
        mediaMime: nil,
        mediaSize: nil,
        mediaWidth: nil,
        mediaHeight: nil,
        mediaDuration: nil,
        mediaViewOnce: nil,
        mediaFileName: mediaFileName,
        mediaItems: nil,
        mediaBlob: mediaBlob
    )
}
