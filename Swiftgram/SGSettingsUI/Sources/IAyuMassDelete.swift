import Foundation
import Postbox
import TelegramCore
import SGSimpleSettings

// IAyuGram: the summary message a collapsed mass deletion leaves in the chat, and the
// link that opens the full list. See IAyuDeletedBatchStore for why the messages are
// kept aside rather than brought back one by one.

// A scheme of our own, so the tap can be recognized and handled before anything tries
// to treat it as a web address. ChatController intercepts it where message links are
// opened; nothing outside the app ever sees it.
public let iAyuMassDeleteURLScheme = "iayugram-deleted-batch"

// Matched anywhere in the string rather than only at the front: a URL that travels
// through a link renderer can come back with a scheme prepended or a slash appended,
// and the key itself is validated on the way out, so being tolerant here costs nothing.
public func iAyuIsMassDeleteURL(_ url: String) -> Bool {
    return url.contains("\(iAyuMassDeleteURLScheme):")
}

func iAyuMassDeleteBatchKey(fromURL url: String) -> IAyuDeletedBatchKey? {
    guard let range = url.range(of: "\(iAyuMassDeleteURLScheme):") else {
        return nil
    }
    var raw = String(url[range.upperBound...])
    if let slash = raw.firstIndex(of: "/") {
        raw = String(raw[raw.startIndex ..< slash])
    }
    return IAyuDeletedBatchKey(rawValue: raw)
}

// The summary itself: an ordinary preserved-delete message (so it carries the badge and
// the tint like every other one) whose second line is a link into the batch.
func iAyuMassDeletePlaqueItem(key: IAyuDeletedBatchKey, chatId: Int64, count: Int, timestamp: Int32?) -> IAyuPendingDelete {
    let head = IAyuStrings.text(.massDeletePlaque, ["count": "\(count)"])
    let tail = IAyuStrings.text(.massDeleteShowAll)
    // Entity offsets are in UTF-16 units, and both halves are user-editable strings —
    // so the range is measured, never assumed. If the link text has been blanked, the
    // whole summary becomes the link rather than leaving the batch unreachable.
    let linkRange: Range<Int>
    if tail.isEmpty {
        linkRange = 0 ..< head.utf16.count
    } else {
        let linkStart = head.utf16.count + 1
        linkRange = linkStart ..< (linkStart + tail.utf16.count)
    }
    let entity = MessageTextEntity(
        range: linkRange,
        type: .TextUrl(url: "\(iAyuMassDeleteURLScheme):\(key.rawValue)")
    )
    let event = IAyuMessageEvent(
        cursor: 0,
        kind: "deleted",
        chatId: chatId,
        messageId: 0,
        text: tail.isEmpty ? head : "\(head)\n\(tail)",
        oldText: nil,
        // Sits where the messages it stands for were, rather than at the bottom.
        date: timestamp.map { Int($0) },
        // Attributed to the chat, like a preserved delete whose sender we don't know.
        fromMe: false,
        senderId: nil,
        mediaKind: nil,
        mediaMime: nil,
        mediaSize: nil,
        mediaWidth: nil,
        mediaHeight: nil,
        mediaDuration: nil,
        mediaViewOnce: nil,
        mediaFileName: nil
    )
    return IAyuPendingDelete(event: event, extraAttributes: [TextEntitiesMessageAttribute(entities: [entity])])
}
