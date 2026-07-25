import Foundation
import Postbox

// IAyuGram: marks a message that the companion server reported as deleted, so it
// can be kept in the chat with a "deleted" indicator instead of disappearing.
public class DeletedMessageAttribute: MessageAttribute {
    public let date: Int32

    public init(date: Int32) {
        self.date = date
    }

    required public init(decoder: PostboxDecoder) {
        self.date = decoder.decodeInt32ForKey("d", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.date, forKey: "d")
    }
}
