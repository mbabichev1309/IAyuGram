import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ChatInterfaceState
import ChatPresentationInterfaceState
import AudioWaveform
import SGSimpleSettings

// MARK: IAyuGram — handing a voice recording to and from IAyuGlobalRecordingManager.
//
// The chat keeps doing everything it did; it just stops being the only place a recording
// can live. On the way out it hands the recorder over, on the way back in it takes it
// back, and if the recording ended while the chat was off screen it picks the audio up as
// a draft instead of letting it disappear.

extension ChatControllerImpl {
    /// Out-of-chat recording is off by default: it removes navigation guards that have
    /// been there forever, so it has to be something the user turns on knowingly and can
    /// turn off when something misbehaves.
    var iAyuGlobalRecordingEnabled: Bool {
        return SGSimpleSettings.shared.iaGlobalVoiceRecording
    }

    /// Whether the running recording may leave this chat.
    ///
    /// Locked only, and that is not a limitation: an unlocked recording is one the user is
    /// holding a finger on, and letting go sends it — you cannot navigate anywhere without
    /// letting go, so there is nothing to preserve.
    ///
    /// The excluded chats are the ones whose send needs state the snapshot does not carry:
    /// a scheduled send needs a picked time, slowmode needs its countdown, paid messages
    /// need their confirmation, and custom contents (quick replies, hashtag search) are not
    /// a peer at all.
    var iAyuCanHandOffAudioRecording: Bool {
        guard self.iAyuGlobalRecordingEnabled, self.audioRecorderValue != nil else {
            return false
        }
        guard self.lockMediaRecordingRequestId == self.beginMediaRecordingRequestId else {
            return false
        }
        guard self.chatLocation.peerId != nil else {
            return false
        }
        if case .scheduledMessages = self.presentationInterfaceState.subject {
            return false
        }
        if case .customChatContents = self.chatLocation {
            return false
        }
        if self.presentationInterfaceState.slowmodeState != nil {
            return false
        }
        if self.presentationInterfaceState.sendPaidMessageStars != nil {
            return false
        }
        if self.presentationInterfaceState.interfaceState.mediaDraftState != nil {
            return false
        }
        return true
    }

    /// Give the recorder to the global manager and let go of it WITHOUT stopping it.
    ///
    /// Two things have to happen in this order or the recording dies on the way out: the
    /// status subscription has to go first (it turns a `.stopped` into `stopMediaRecorder`,
    /// and the manager is about to own that responsibility), and only then may our own
    /// reference be cleared — which is safe precisely because the adoption block never
    /// calls `stop()`, it only drops the object.
    func iAyuHandOffAudioRecording() {
        guard let recorder = self.audioRecorderValue, let peerId = self.chatLocation.peerId else {
            return
        }

        var viewOnceAvailable = false
        if peerId.namespace == Namespaces.Peer.CloudUser, peerId != self.context.account.peerId {
            var isBot = false
            if let user = self.presentationInterfaceState.renderedPeer?.peer as? TelegramUser, user.botInfo != nil {
                isBot = true
            }
            viewOnceAvailable = !isBot
        }

        let target = IAyuGlobalRecordingTarget(
            accountId: self.context.account.id,
            peerId: peerId,
            threadId: self.chatLocation.threadId,
            replySubject: self.presentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel,
            silentPosting: self.presentationInterfaceState.interfaceState.silentPosting,
            viewOnceAvailable: viewOnceAvailable,
            peerTitle: self.presentationInterfaceState.renderedPeer?.chatMainPeer.flatMap { EnginePeer($0).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder) } ?? ""
        )

        IAyuGlobalRecordingManager.shared.adopt(
            recorder: recorder,
            target: target,
            account: self.context.account
        )

        self.audioRecorderStatusDisposable?.dispose()
        self.audioRecorderStatusDisposable = nil
        self.recorderFeedback = nil
        self.audioRecorder.set(.single(nil))
        self.lockOrientation = false
    }

    /// Take back a recording that is still running for this chat, or pick up the audio of
    /// one that ended while we were away. Called every time the chat appears, so both the
    /// "came back to finish it" and the "it got interrupted meanwhile" cases resolve
    /// without the user having to do anything.
    func iAyuReclaimAudioRecording() {
        guard self.iAyuGlobalRecordingEnabled, let peerId = self.chatLocation.peerId else {
            return
        }
        let manager = IAyuGlobalRecordingManager.shared
        let threadId = self.chatLocation.threadId

        if self.audioRecorderValue == nil, let recorder = manager.reclaim(peerId: peerId, threadId: threadId) {
            // Keep it locked: it was handed over locked, and an unlocked panel here would
            // mean "release to send" with no finger on the button.
            self.lockMediaRecordingRequestId = self.beginMediaRecordingRequestId
            self.audioRecorder.set(.single(recorder))
            return
        }

        if self.presentationInterfaceState.interfaceState.mediaDraftState == nil,
           let data = manager.takePendingDraft(peerId: peerId, threadId: threadId) {
            self.iAyuInstallRecordedDraft(data)
        }
    }

    /// Install already-recorded audio as this chat's media draft — the same state the
    /// in-chat preview panel produces, so the existing send/trim/delete controls work on
    /// it with no further plumbing.
    private func iAyuInstallRecordedDraft(_ data: RecordedAudioData) {
        guard let waveform = data.waveform, data.duration >= 0.5 else {
            return
        }
        let resource = LocalFileMediaResource(
            fileId: Int64.random(in: Int64.min ... Int64.max),
            size: Int64(data.compressedData.count)
        )
        self.context.engine.resources.storeResourceData(
            id: EngineMediaResource.Id(resource.id),
            data: data.compressedData
        )
        self.updateChatPresentationInterfaceState(animated: true, interactive: false, {
            $0.updatedInterfaceState {
                $0.withUpdatedMediaDraftState(.audio(
                    ChatInterfaceMediaDraftState.Audio(
                        resource: resource,
                        fileSize: Int32(data.compressedData.count),
                        duration: data.duration,
                        waveform: AudioWaveform(bitstream: waveform, bitsPerSample: 5),
                        trimRange: data.trimRange,
                        resumeData: data.resumeData
                    )
                ))
            }
        })
    }

    /// The single-slot rule, checked before a new recording starts anywhere: one
    /// microphone, one recording. Returns true when this chat must NOT begin one.
    var iAyuBlockedByGlobalRecording: Bool {
        guard IAyuGlobalRecordingManager.shared.isRecording else {
            return false
        }
        // A recording belonging to this very chat is not a conflict — it is reclaimed on
        // appear, and the mic button should not be starting a second one anyway.
        if let target = IAyuGlobalRecordingManager.shared.activeTarget,
           let peerId = self.chatLocation.peerId,
           target.matches(peerId: peerId, threadId: self.chatLocation.threadId) {
            return false
        }
        return true
    }
}
