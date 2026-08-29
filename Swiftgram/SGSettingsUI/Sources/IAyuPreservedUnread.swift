import Foundation
import Postbox
import TelegramCore
import AccountContext
import SwiftSignalKit

// IAyuGram: keep preserved copies out of the unread badge.
//
// A materialized delete is a copy of a message the user has already seen, but Postbox
// counts it as fresh incoming mail. The seed configuration gives the LOCAL message
// namespace a read state of its own (`defaultMessageNamespaceReadStates` in
// SyncCore_StandaloneAccountTransaction.swift), and MessageHistoryTable adds every
// incoming message in a chat namespace to the read state of ITS namespace — so each
// preserved delete that wasn't ours (`.Incoming`, because that is what puts the bubble
// on the left) adds one to the chat's unread count. Upstream never creates an incoming
// local message, so the path is effectively dead code there; for us it runs on every
// capture.
//
// The count that results is unreadable in the ordinary sense. Reading a chat applies
// the maximum VISIBLE index, which is a cloud index, and Postbox carries that over to
// another namespace only if the namespace holds a message at an OLDER timestamp
// (the cross-namespace loop in `Postbox.applyInteractiveReadMaxIndex`). A copy of the
// newest message in a chat is not older than the newest cloud message, and a copy whose
// message has since gone (a batch collapsed into its summary, a preserved copy deleted
// by hand) leaves a count with nothing behind it at all. Either way the badge sits
// there until something newer arrives and is read — for a quiet chat, indefinitely.
//
// So the local namespace is marked read where the copies are inserted, and a repair
// pass at launch clears whatever earlier builds left behind.

// The local namespace's own read state for a peer, if it has one.
func iAyuLocalReadState(transaction: Transaction, peerId: PeerId) -> PeerReadState? {
    guard let states = transaction.getPeerReadStates(peerId) else {
        return nil
    }
    for (namespace, state) in states where namespace == Namespaces.Message.Local {
        return state
    }
    return nil
}

// Mark everything preserved in this chat as read. Namespace-scoped on purpose:
// `applyIncomingReadMaxId` touches one namespace's read state and nothing else, so no
// genuinely unread cloud message is marked read and no read position is pushed to the
// server (which ghost mode would suppress anyway, but the local side matters too).
func iAyuClearPreservedUnread(transaction: Transaction, peerId: PeerId) {
    guard let state = iAyuLocalReadState(transaction: transaction, peerId: peerId) else {
        return
    }
    guard case let .idBased(_, maxOutgoingReadId, maxKnownId, count, markedUnread) = state else {
        return
    }
    if count == 0 && !markedUnread {
        return
    }
    if let topLocal = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Local) {
        // Reading up to the TOP of the namespace is what makes this exact: Postbox
        // forces the count to zero when the id it is handed is the top one, instead of
        // subtracting the messages it can still find. A count left over from copies
        // that no longer exist is cleared by the same call.
        transaction.applyIncomingReadMaxId(topLocal.id)
    } else {
        // Nothing left in the namespace to read up to. `applyIncomingReadMaxId` can
        // only subtract messages it finds, so it cannot help here; replace the state.
        // Note this also clears the peer's pending read-state synchronization — with
        // nothing local left, there is no chat-list count to preserve, and the cloud
        // state itself is untouched.
        transaction.resetIncomingReadStates([peerId: [Namespaces.Message.Local: .idBased(
            maxIncomingReadId: maxKnownId,
            maxOutgoingReadId: maxOutgoingReadId,
            maxKnownId: maxKnownId,
            count: 0,
            markedUnread: false
        )]])
    }
}

private let iAyuUnreadRepairKey = "iaPreservedUnreadRepair"

// What the last repair pass found, for the diagnostics screen. Written even when it
// found nothing, so "the pass ran and the chat was clean" can be told apart from "the
// pass never ran".
public func iAyuPreservedUnreadRepairReport() -> String {
    return UserDefaults.standard.string(forKey: iAyuUnreadRepairKey) ?? "not run yet"
}

// Clear preserved unread counts left by earlier builds. Runs once per launch over the
// chats that actually show as unread, so a clean database costs one transaction and a
// handful of read-state lookups.
public func iAyuRepairPreservedUnread(context: AccountContext) {
    let _ = (context.account.postbox.transaction { transaction -> String in
        var repaired: [String] = []
        for groupId in [PeerGroupId.root, Namespaces.PeerGroup.archive] {
            for peerId in transaction.getUnreadChatListPeerIds(groupId: groupId, filterPredicate: nil, additionalFilter: nil, stopOnFirstMatch: false) {
                guard let state = iAyuLocalReadState(transaction: transaction, peerId: peerId), state.count != 0 || state.markedUnread else {
                    continue
                }
                let title = transaction.getPeer(peerId)?.debugDisplayTitle ?? "\(peerId)"
                let orphan = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Local) == nil
                repaired.append("\(title): \(state.count)\(orphan ? " (no messages left)" : "")")
                iAyuClearPreservedUnread(transaction: transaction, peerId: peerId)
            }
        }
        if repaired.isEmpty {
            return "nothing to clear"
        }
        return repaired.joined(separator: ", ")
    }
    |> deliverOnMainQueue).start(next: { report in
        UserDefaults.standard.set(report, forKey: iAyuUnreadRepairKey)
    })
}
