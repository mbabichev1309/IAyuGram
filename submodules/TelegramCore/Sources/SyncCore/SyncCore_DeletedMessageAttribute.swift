import Foundation
import Postbox

// IAyuGram: marks a message that the companion server reported as deleted, so it
// can be kept in the chat with a "deleted" indicator instead of disappearing.
public class DeletedMessageAttribute: MessageAttribute {
    public let date: Int32
    // The id of the cloud message this copy stands in for. Only used to recognise our
    // own work later — a forced re-sync replays a window of the event log and must tell
    // an event it never materialized from one it already did. Optional because copies
    // made before this existed have none; those fall back to matching on date and text.
    public let originId: Int32?

    public init(date: Int32, originId: Int32? = nil) {
        self.date = date
        self.originId = originId
    }

    required public init(decoder: PostboxDecoder) {
        self.date = decoder.decodeInt32ForKey("d", orElse: 0)
        self.originId = decoder.decodeOptionalInt32ForKey("o")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.date, forKey: "d")
        if let originId = self.originId {
            encoder.encodeInt32(originId, forKey: "o")
        }
    }
}
