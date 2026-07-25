import Foundation
import Postbox

// IAyuGram: preserves previous versions of an edited message (captured by the
// companion server), shown on demand via the message's "Edit history" action.
// One Version per edit — text is the message content BEFORE that edit.
public final class EditHistoryMessageAttribute: MessageAttribute {
    public struct Version: Codable, Equatable {
        public let cursor: Int
        public let date: Int32
        public let text: String

        public init(cursor: Int, date: Int32, text: String) {
            self.cursor = cursor
            self.date = date
            self.text = text
        }
    }

    public let versions: [Version]

    public init(versions: [Version]) {
        self.versions = versions
    }

    required public init(decoder: PostboxDecoder) {
        let raw = decoder.decodeStringForKey("v", orElse: "")
        if let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode([Version].self, from: data) {
            self.versions = decoded
        } else {
            self.versions = []
        }
    }

    public func encode(_ encoder: PostboxEncoder) {
        if let data = try? JSONEncoder().encode(self.versions), let string = String(data: data, encoding: .utf8) {
            encoder.encodeString(string, forKey: "v")
        } else {
            encoder.encodeString("", forKey: "v")
        }
    }
}
