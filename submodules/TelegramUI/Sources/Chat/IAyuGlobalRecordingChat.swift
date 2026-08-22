import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ChatInterfaceState
import ChatPresentationInterfaceState
import AudioWaveform
import VideoMessageCameraScreen
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

        IAyuGlobalRecordingManager.shared.adopt(
            recorder: recorder,
            target: self.iAyuRecordingTarget(peerId: peerId),
            account: self.context.account
        )

        self.audioRecorderStatusDisposable?.dispose()
        self.audioRecorderStatusDisposable = nil
        self.recorderFeedback = nil
        self.audioRecorder.set(.single(nil))
        self.lockOrientation = false

        // The mic button's pulsing decoration is not drawn in the input panel — the legacy
        // button presents it in the keyboard window (or in a controller of its own), and it
        // is taken down only when the button's own recording ends. Walking away is not an
        // ending it knows about, so the blobs outlive the chat and end up parked in the top
        // left of whatever comes next. Ending the button's interaction takes them with it.
        self.chatDisplayNode.textInputPanelNode?.micButton?.cancelRecording()
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

// MARK: IAyuGram — the same trick for a round video.
//
// Structurally simpler than voice, because the camera screen already builds its own
// message and is already presented on the root window rather than inside the chat. What it
// is NOT is leavable: it covers the chat completely, so no back gesture can even start
// while it is up. Leaving is therefore always explicit — the minimize button or a swipe
// down on the circle — and the screen only asks; the handover happens here, because half
// of it is the chat letting go of its own recorder state.

extension ChatControllerImpl {
    /// Off by default, like the voice counterpart: it takes a screen that used to be modal
    /// and makes it dismissable, so the user should be the one to ask for that.
    var iAyuGlobalRoundRecordingEnabled: Bool {
        return SGSimpleSettings.shared.iaGlobalRoundRecording
    }

    /// Whether the running round video may leave this chat. Same rules as voice — locked
    /// only, and only where the send can be done from a snapshot — with one addition: a
    /// recording that is already minimized is not a candidate again.
    var iAyuCanHandOffVideoRecording: Bool {
        guard self.iAyuGlobalRoundRecordingEnabled, let controller = self.videoRecorderValue else {
            return false
        }
        guard !controller.iAyuIsMinimized else {
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

    /// Where a recording started in this chat is going, snapshotted. Shared by both kinds:
    /// the send happens after the chat may be gone, so nothing here may be re-read later.
    func iAyuRecordingTarget(peerId: PeerId) -> IAyuGlobalRecordingTarget {
        var viewOnceAvailable = false
        if peerId.namespace == Namespaces.Peer.CloudUser, peerId != self.context.account.peerId {
            var isBot = false
            if let user = self.presentationInterfaceState.renderedPeer?.peer as? TelegramUser, user.botInfo != nil {
                isBot = true
            }
            viewOnceAvailable = !isBot
        }

        return IAyuGlobalRecordingTarget(
            accountId: self.context.account.id,
            peerId: peerId,
            threadId: self.chatLocation.threadId,
            replySubject: self.presentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel,
            silentPosting: self.presentationInterfaceState.interfaceState.silentPosting,
            viewOnceAvailable: viewOnceAvailable,
            peerTitle: self.presentationInterfaceState.renderedPeer?.chatMainPeer.flatMap { EnginePeer($0).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder) } ?? ""
        )
    }

    /// Take the camera screen off the window, give it to the manager, and stop being the
    /// chat that owns a recording. Everything the chat taught the screen is replaced first:
    /// every one of those closures reads live chat state, and there will be no chat.
    func iAyuHandOffVideoRecording() {
        guard self.iAyuCanHandOffVideoRecording, let controller = self.videoRecorderValue, let peerId = self.chatLocation.peerId else {
            return
        }

        let manager = IAyuGlobalRecordingManager.shared
        manager.adoptVideo(
            controller: controller,
            target: self.iAyuRecordingTarget(peerId: peerId),
            account: self.context.account
        )

        controller.completion = { [weak controller] message, _, _, _ in
            guard let controller else {
                return
            }
            if let message {
                manager.enqueueFromVideoSession(message, isChunk: false)
            } else {
                manager.videoSessionEnded(controller: controller)
            }
            controller.iAyuTearDown()
        }
        controller.onChunk = { message in
            manager.enqueueFromVideoSession(message, isChunk: true)
        }
        // The chat's version of this asks about slowmode, paid messages and scheduling —
        // all of which were checked before the handover and none of which can change while
        // the chat is not even on screen.
        controller.iAyuCanSendChunk = {
            return true
        }
        // Reaching the one-minute cap with chunking off used to mean "show the preview".
        // There is nowhere to show it, so the take is closed and kept; the chat turns it
        // into a preview the next time it is opened.
        controller.onStop = { [weak controller] in
            guard let controller else {
                return
            }
            controller.iAyuStopRecordingKeepingTake()
            manager.videoRecordingDidFinish()
        }
        controller.onResume = {
        }
        controller.iAyuCanMinimize = {
            return false
        }
        controller.iAyuOnMinimize = {
        }

        // The subscription discards whatever recorder it is replacing. This one is not
        // being replaced, it is being handed over, so it has to be exempted by name.
        self.iAyuHandedOffVideoRecorder = controller
        let previewView = controller.iAyuDetachForMinimize()
        self.recorderFeedback = nil
        self.videoRecorder.set(.single(nil))

        // The circle carries on in the same draggable overlay a round MESSAGE uses when you
        // scroll away from it — dragging, edge snapping and stacking all come from there.
        // Tapping it expands, exactly like tapping the panel.
        let sharedContext = self.context.sharedContext
        let accountId = self.context.account.id
        if let overlayController = sharedContext.mediaManager.overlayMediaManager.controller {
            // Nothing of the chat is captured here: the circle outlives it, and holding a
            // popped chat controller alive through an overlay would be its own bug.
            let overlayNode = IAyuRoundRecordingOverlayNode(previewView: previewView, tapped: {
                if !manager.requestVideoExpand() {
                    // No chat of ours on screen. Go there; the request is honoured on the
                    // way in.
                    sharedContext.navigateToChat(accountId: accountId, peerId: peerId, messageId: nil)
                }
            })
            overlayController.addNode(overlayNode, customTransition: false)
            overlayNode.refreshPreviewLayout()
            manager.setVideoOverlay(node: overlayNode, remove: { [weak overlayController] node in
                overlayController?.removeNode(node, customTransition: false)
            })
        }
    }

    /// Register as the chat that can put a minimized round video back on the full screen,
    /// and honour a request that came in while we were not here. Deliberately NOT an
    /// automatic expand: walking back into the chat is not the same as asking for the camera
    /// screen again, and having it slam back a second after you arrive is exactly what that
    /// felt like.
    func iAyuUpdateVideoRecordingHost(isVisible: Bool) {
        let manager = IAyuGlobalRecordingManager.shared
        guard isVisible else {
            if manager.videoHost === self {
                manager.videoHost = nil
            }
            return
        }
        guard self.iAyuGlobalRoundRecordingEnabled, let peerId = self.chatLocation.peerId else {
            return
        }
        guard let target = manager.activeTarget, target.matches(peerId: peerId, threadId: self.chatLocation.threadId), manager.activeVideoRecorder != nil else {
            if manager.videoHost === self {
                manager.videoHost = nil
            }
            return
        }
        manager.videoHost = self
        if manager.consumePendingVideoExpand() {
            self.iAyuExpandVideoRecording()
        }
    }

    /// Take a minimized round video back onto the full screen. Only ever reached by asking
    /// for it — tapping the panel or the circle — never by merely arriving in the chat. If
    /// the take ended meanwhile it lands in the preview state instead, which is where the
    /// in-chat flow would have put it.
    public func iAyuExpandVideoRecording() {
        guard self.iAyuGlobalRoundRecordingEnabled, let peerId = self.chatLocation.peerId else {
            return
        }
        guard self.videoRecorderValue == nil else {
            return
        }
        guard let reclaimed = IAyuGlobalRecordingManager.shared.reclaimVideo(peerId: peerId, threadId: self.chatLocation.threadId) else {
            return
        }
        guard let controller = reclaimed.controller as? VideoMessageCameraScreen else {
            return
        }

        self.iAyuHandedOffVideoRecorder = nil
        self.iAyuConfigureVideoRecorder(controller)
        controller.iAyuPrepareForRestore()
        // It was handed over locked, and it comes back locked: an unlocked panel would mean
        // "release to send" with no finger anywhere near the button.
        self.lockMediaRecordingRequestId = self.beginMediaRecordingRequestId
        self.videoRecorder.set(.single(controller))

        if reclaimed.isFinished {
            // Deferred, so the promise's subscription has already presented the screen and
            // put the input panel back into its recording state — which is the state the
            // preview transition expects to be leaving.
            Queue.mainQueue().justDispatch { [weak self] in
                self?.dismissMediaRecorder(.pause)
            }
        }
    }
}

// The manager cannot expand a recording on its own — putting the camera screen back means
// re-teaching it everything the chat knows — so it asks the chat, through this.
extension ChatControllerImpl: IAyuGlobalVideoRecordingHost {
}
