import Foundation
import Postbox
import TelegramCore
import SGSimpleSettings

// IAyuGram — "first listened at" for our own voice and round messages.
//
// Telegram answers a different question. In a private chat the context menu shows
// messages.getOutboxReadDate, i.e. when the message was READ; for a voice message or a
// round video that is not what anyone means by "listened to". The signal that does mean
// it is updateReadMessagesContents, and the iOS client throws its timestamp away —
// ConsumableContentMessageAttribute stores a single Bool. So the companion server
// records it (it sees every update, including while the phone is asleep) and this asks
// for it on demand.
//
// On demand, rather than through the event log: the question is asked at most once per
// message, when its context menu opens, so there is nothing worth streaming and no
// client-side store to keep in sync.

private struct IAyuListenedResponse: Codable {
    let listenedAt: Int32?

    enum CodingKeys: String, CodingKey {
        case listenedAt = "listened_at"
    }
}

// The feature covers private chats only, which is the one case where the id maps
// straight across: the server speaks Telethon's marked-peer convention, where a user is
// its bare positive id.
public func iAyuServerChatId(privateChatPeerId peerId: PeerId) -> Int64? {
    guard peerId.namespace == Namespaces.Peer.CloudUser else {
        return nil
    }
    return peerId.id._internalGetInt64Value()
}

/// Ask the companion server when this message was first played. `nil` means "no answer" —
/// server unset, unreachable, or simply never having seen the update, which is the case
/// for everything sent before this shipped. Callers must fall back to Telegram's own row
/// rather than claiming the message was never played.
///
/// Returns the task so a caller whose UI disappears can cancel it.
@discardableResult
public func iAyuFetchListenedAt(chatId: Int64, messageId: Int32, completion: @escaping (Int32?) -> Void) -> URLSessionDataTask? {
    let serverURL = SGSimpleSettings.shared.iaSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = SGSimpleSettings.shared.iaSyncClientToken
    guard !serverURL.isEmpty, !token.isEmpty else {
        completion(nil)
        return nil
    }
    guard var components = URLComponents(string: serverURL.contains("://") ? serverURL : "https://\(serverURL)") else {
        completion(nil)
        return nil
    }
    components.path = "/listened"
    components.queryItems = [
        URLQueryItem(name: "chat_id", value: "\(chatId)"),
        URLQueryItem(name: "message_id", value: "\(messageId)")
    ]
    guard let url = components.url else {
        completion(nil)
        return nil
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    // Short: this is racing a context menu the user is already looking at. Better to
    // fall back to the built-in row than to leave a stale one and swap it out late.
    request.timeoutInterval = 6.0

    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data = data, let response = try? JSONDecoder().decode(IAyuListenedResponse.self, from: data) else {
            completion(nil)
            return
        }
        completion(response.listenedAt)
    }
    task.resume()
    return task
}
