import Foundation
import Postbox
import TelegramApi
import SwiftSignalKit
import SGSimpleSettings

// IAyuGram ghost "read on interact".
//
// Ghost mode suppresses readHistory at the network egress, which is what keeps others
// from seeing a "seen" mark. The cost is that replying to someone leaves their messages
// unread on their side — you answered a message you supposedly never read, which is a
// louder tell than the read mark would have been. So an explicit interaction (sending a
// message, adding a reaction) pushes the read position once, for that chat only.
//
// readHistory also bumps you online server-side — that is the very reason ghost gates it
// — so when "don't go online" is on we follow the read with an explicit offline packet,
// the equivalent of AyuGram's "Go Offline Automatically". The blink to online is
// unavoidable: there is no read RPC that doesn't cause it.

// Peers whose read position we have already pushed, and up to which id. In memory on
// purpose: a relaunch re-pushing one redundant readHistory per chat you write into is
// harmless, while a persisted map would be one more thing to keep correct against a
// read state Telegram can move from any other client.
private let iAyuPushedReads = Atomic<[PeerId: Int32]>(value: [:])

/// Whether an interaction with this peer should push the read position.
///
/// Forced on while invisible send diverts this peer's messages: that mode exists to make
/// a message arrive with no trace of you being there, and unread messages sitting under
/// your reply are exactly such a trace. Outside it the user's switch decides.
public func iAyuReadOnInteractApplies(peerId: PeerId) -> Bool {
    // Nothing to compensate for unless the read mark is actually being withheld here.
    guard IAyuGhost.applies(.hideReadReceipts, peerId: peerId.toInt64()) else {
        return false
    }
    // Secret chats read through messages.readEncryptedHistory and are not covered by
    // invisible send either; left alone rather than half-handled.
    guard peerId.namespace != Namespaces.Peer.SecretChat else {
        return false
    }
    return SGSimpleSettings.shared.iaGhostReadOnInteract || iAyuInvisibleSendApplies(peerId: peerId)
}

/// Mark this chat read, locally and on the server, bypassing the ghost gate.
///
/// Fire and forget: the caller's action must not wait on it, and a failed push simply
/// leaves the chat as it was, which is today's behaviour.
public func iAyuReadOnInteract(account: Account, peerId: PeerId) {
    guard iAyuReadOnInteractApplies(peerId: peerId) else {
        return
    }

    let signal = account.postbox.transaction { transaction -> (Peer, Int32)? in
        guard let peer = transaction.getPeer(peerId) else {
            return nil
        }
        // The top CLOUD message: reading "up to what I have" is what the user means by
        // interacting, and it is also the only id the server will accept as a read
        // position. Local-namespace messages (our preserved copies) are invisible to it.
        guard let index = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud) else {
            return nil
        }
        let maxId = index.id.id
        let alreadyPushed = iAyuPushedReads.with { $0[peerId] }
        if let alreadyPushed = alreadyPushed, alreadyPushed >= maxId {
            return nil
        }
        // Locally too, so the chat doesn't keep an unread count the server no longer
        // agrees with. The synchronize operation this enqueues is still gated by ghost
        // — the push below is ours and deliberate, that one is the automatic one.
        let _ = transaction.applyInteractiveReadMaxIndex(index)
        let _ = iAyuPushedReads.modify { current in
            var current = current
            current[peerId] = maxId
            return current
        }
        return (peer, maxId)
    }
    |> mapToSignal { peerAndId -> Signal<Never, NoError> in
        guard let (peer, maxId) = peerAndId else {
            return .complete()
        }
        return iAyuPushRead(account: account, peer: peer, maxId: maxId)
        |> then(iAyuGoOfflineAgain(account: account))
    }

    let _ = signal.start()
}

private func iAyuPushRead(account: Account, peer: Peer, maxId: Int32) -> Signal<Never, NoError> {
    if peer.id.namespace == Namespaces.Peer.CloudChannel {
        guard let inputChannel = apiInputChannel(peer) else {
            return .complete()
        }
        return account.network.request(Api.functions.channels.readHistory(channel: inputChannel, maxId: maxId))
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .complete()
        }
        |> ignoreValues
    } else {
        guard let inputPeer = apiInputPeer(peer) else {
            return .complete()
        }
        return account.network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: maxId))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.messages.AffectedMessages?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<Never, NoError> in
            // Feed the pts back the same way the normal read path does, or the next
            // update would look like a gap and force a full state resync.
            if case let .affectedMessages(data)? = result {
                account.stateManager.addUpdateGroups([.updatePts(pts: data.pts, ptsCount: data.ptsCount)])
            }
            return .complete()
        }
    }
}

/// Undo the online bump the read just caused. Only meaningful while "don't go online" is
/// on — otherwise the user is happy to be seen, and an offline packet would fight the
/// presence manager for no reason.
private func iAyuGoOfflineAgain(account: Account) -> Signal<Never, NoError> {
    guard SGSimpleSettings.shared.iaGhostStayOffline else {
        return .complete()
    }
    return account.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
    |> `catch` { _ -> Signal<Api.Bool, NoError> in
        return .complete()
    }
    |> ignoreValues
}
