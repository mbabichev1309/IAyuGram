import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore

// MARK: IAyuGram — a voice recording that outlives the chat it started in.
//
// Upstream ties a recording to its chat controller. Not because the recorder needs it:
// ManagedAudioRecorder runs on its own queue and its deinit releases the audio session,
// so it is already self-contained. It is `ChatControllerImpl.audioRecorderValue` being
// the ONLY strong reference — plus `attemptNavigation` refusing to let you leave — that
// makes leaving the chat end the recording. Holding that reference here instead is the
// whole trick; everything else in this file exists because the SEND then has to work
// without a chat controller to read state from.
//
// Deliberately ONE slot. The audio session is a stack with a single active holder
// (ManagedAudioSession.push), so a second recording does not coexist with the first —
// it steals the microphone and the first dies silently.

/// Voice and round video share this one slot — there is one microphone, and the audio
/// session is a stack with a single active holder — but they share almost nothing else,
/// so everything that acts on a session branches on this.
public enum IAyuGlobalRecordingKind {
    case voice
    case video
}

/// The round-video camera screen, seen from here.
///
/// It lives in TelegramUI/Components, which AccountContext must not depend on, so the
/// manager holds it through this instead of by its own type. Unlike the voice recorder,
/// this object is a whole ViewController that knows how to build its own message — so the
/// manager never touches the video itself, it only decides when and where.
public protocol IAyuGlobalVideoRecorder: AnyObject {
    /// The live preview circle, lifted out of the camera screen and put into the panel.
    /// The panel scales it down; its internal layout stays at full size.
    var iAyuPreviewView: UIView { get }
    var iAyuRecordingDuration: Signal<TimeInterval, NoError> { get }
    /// True once the take has ended — the one-minute cap, or an interruption — and only a
    /// finished recording is left to send or throw away.
    var iAyuIsFinished: Bool { get }
    func iAyuSendFromPanel()
    func iAyuCancelFromPanel()
    /// End the take without discarding it. The camera stops; what was filmed is kept and
    /// becomes the chat's preview when it is next opened.
    func iAyuStopRecordingKeepingTake()
}

/// Everything the send needs to know about where the recording is going, snapshotted when
/// it starts. It has to be a snapshot: the chat controller that knew all this may be gone
/// by the time the user hits send, and re-reading it later would read some other chat.
public final class IAyuGlobalRecordingTarget {
    public let accountId: AccountRecordId
    public let peerId: PeerId
    public let threadId: Int64?
    public let replySubject: EngineMessageReplySubject?
    public let silentPosting: Bool
    public let viewOnceAvailable: Bool
    /// For the panel's subtitle — resolving the peer again from here would mean a
    /// database round-trip for a string the chat already had.
    public let peerTitle: String

    public init(
        accountId: AccountRecordId,
        peerId: PeerId,
        threadId: Int64?,
        replySubject: EngineMessageReplySubject?,
        silentPosting: Bool,
        viewOnceAvailable: Bool,
        peerTitle: String
    ) {
        self.accountId = accountId
        self.peerId = peerId
        self.threadId = threadId
        self.replySubject = replySubject
        self.silentPosting = silentPosting
        self.viewOnceAvailable = viewOnceAvailable
        self.peerTitle = peerTitle
    }

    public func matches(peerId: PeerId, threadId: Int64?) -> Bool {
        return self.peerId == peerId && self.threadId == threadId
    }
}

/// Why a recording ended. Only `.send` produces a message; everything else keeps the
/// audio as a draft, because the alternative is silently throwing away something the
/// user recorded.
public enum IAyuGlobalRecordingStopReason {
    case send(viewOnce: Bool)
    case cancel
    /// The microphone was taken away — a story reply, a call, another app. The recorder
    /// reports `.stopped` and there is nothing to resume.
    case preempted
    case accountSwitched
    case applicationBackgrounded
}

/// What the panel renders. `version` makes equality cheap the way MediaPlayback does it:
/// the panel only needs to know that something changed, not what.
public final class IAyuGlobalRecordingState: Equatable {
    public let kind: IAyuGlobalRecordingKind
    public let target: IAyuGlobalRecordingTarget
    public let startedAt: Double
    /// A video take that has ended but has not been sent yet. The panel keeps its buttons
    /// and stops counting.
    public let isFinished: Bool
    public let version: Int

    init(kind: IAyuGlobalRecordingKind, target: IAyuGlobalRecordingTarget, startedAt: Double, isFinished: Bool, version: Int) {
        self.kind = kind
        self.target = target
        self.startedAt = startedAt
        self.isFinished = isFinished
        self.version = version
    }

    public static func ==(lhs: IAyuGlobalRecordingState, rhs: IAyuGlobalRecordingState) -> Bool {
        return lhs.version == rhs.version
    }
}

public final class IAyuGlobalRecordingManager {
    public static let shared = IAyuGlobalRecordingManager()

    private final class Session {
        let recorder: ManagedAudioRecorder
        let target: IAyuGlobalRecordingTarget
        let account: Account
        let startedAt: Double
        var stateDisposable: Disposable?

        init(recorder: ManagedAudioRecorder, target: IAyuGlobalRecordingTarget, account: Account, startedAt: Double) {
            self.recorder = recorder
            self.target = target
            self.account = account
            self.startedAt = startedAt
        }

        deinit {
            self.stateDisposable?.dispose()
        }
    }

    /// The round-video counterpart of Session. It is much thinner because the camera
    /// screen owns the recording, the results and the message building; all that is kept
    /// here is where it is going and whether it is still running.
    private final class VideoSession {
        let controller: IAyuGlobalVideoRecorder
        let target: IAyuGlobalRecordingTarget
        let account: Account
        let startedAt: Double
        var isFinished: Bool = false
        /// A round video past the one-minute cap goes out as a series of messages, and
        /// only the first of them answers the reply the chat was holding.
        var didUseReply: Bool = false

        init(controller: IAyuGlobalVideoRecorder, target: IAyuGlobalRecordingTarget, account: Account, startedAt: Double) {
            self.controller = controller
            self.target = target
            self.account = account
            self.startedAt = startedAt
        }
    }

    private var session: Session?
    private var videoSession: VideoSession?
    private var nextVersion: Int = 0
    private let statePromise = Promise<IAyuGlobalRecordingState?>(nil)
    /// Recorded audio whose chat was not on screen when the recording ended. The chat
    /// installs it as its media draft the next time it opens, so nothing is lost when the
    /// microphone is preempted or the account switched.
    private var pendingDrafts: [(target: IAyuGlobalRecordingTarget, data: RecordedAudioData)] = []

    private init() {
    }

    /// For the panel: nil when nothing is being recorded outside a chat.
    public var state: Signal<IAyuGlobalRecordingState?, NoError> {
        return self.statePromise.get()
    }

    public private(set) var stateValue: IAyuGlobalRecordingState?

    /// The live recorder, so the panel can show the running duration and mic level
    /// without a second source of truth.
    public var activeRecorder: ManagedAudioRecorder? {
        return self.session?.recorder
    }

    public var activeTarget: IAyuGlobalRecordingTarget? {
        return self.session?.target ?? self.videoSession?.target
    }

    /// The live camera screen, so the panel can mount its preview and drive its buttons.
    public var activeVideoRecorder: IAyuGlobalVideoRecorder? {
        return self.videoSession?.controller
    }

    /// True while a recording is held here — i.e. one is running outside its chat. Used
    /// for the single-slot rule: no second recording may start anywhere.
    public var isRecording: Bool {
        return self.session != nil || self.videoSession != nil
    }

    // MARK: - Ownership handover

    /// Take ownership of a running recorder, so it survives the chat controller going
    /// away. The chat must drop its own reference right after calling this.
    public func adopt(
        recorder: ManagedAudioRecorder,
        target: IAyuGlobalRecordingTarget,
        account: Account
    ) {
        assert(Queue.mainQueue().isCurrent())
        if let session = self.session {
            if session.recorder === recorder {
                return
            }
            // Should not happen — the single-slot rule is enforced before a recording
            // starts — but if it does, the older one is the one already recorded, so it
            // is kept as a draft rather than dropped.
            self.stop(reason: .preempted)
        }
        if self.videoSession != nil {
            self.stopVideo(reason: .preempted)
        }

        let session = Session(
            recorder: recorder,
            target: target,
            account: account,
            startedAt: CFAbsoluteTimeGetCurrent()
        )
        self.session = session

        // The recorder reports `.stopped` when its audio session is deactivated by
        // someone with higher priority (a call, a story reply, another app). Nothing
        // resumes it, so treat it as the end of the recording and keep the audio.
        session.stateDisposable = (recorder.recordingState
        |> deliverOnMainQueue).start(next: { [weak self, weak session] state in
            guard let self, let session, self.session === session else {
                return
            }
            if case .stopped = state {
                self.stop(reason: .preempted)
            }
        })

        self.pushState()
    }

    /// Hand the recorder back to a chat that has become visible again. Returns nil when
    /// the recording belongs to a different chat, which must NOT adopt it.
    public func reclaim(peerId: PeerId, threadId: Int64?) -> ManagedAudioRecorder? {
        assert(Queue.mainQueue().isCurrent())
        guard let session = self.session, session.target.matches(peerId: peerId, threadId: threadId) else {
            return nil
        }
        session.stateDisposable?.dispose()
        session.stateDisposable = nil
        self.session = nil
        self.pushState()
        return session.recorder
    }

    // MARK: - Round video

    /// Take ownership of a minimized round-video recording. The camera screen is already
    /// dismissed from the window by the time this runs; what it needs from here on is a
    /// place to live and somewhere to send to.
    public func adoptVideo(
        controller: IAyuGlobalVideoRecorder,
        target: IAyuGlobalRecordingTarget,
        account: Account
    ) {
        assert(Queue.mainQueue().isCurrent())
        if let existing = self.videoSession {
            if existing.controller === controller {
                return
            }
            self.stopVideo(reason: .preempted)
        }
        if self.session != nil {
            // One microphone. Should be unreachable — the single-slot rule is checked
            // before either recording starts — but the older take is the one that already
            // has audio in it, so it is kept rather than dropped.
            self.stop(reason: .preempted)
        }

        self.videoSession = VideoSession(
            controller: controller,
            target: target,
            account: account,
            startedAt: CFAbsoluteTimeGetCurrent()
        )
        self.pushState()
    }

    /// Hand the camera screen back to a chat that has come into view. Returns nil when the
    /// recording belongs to some other chat, which must not take it.
    public func reclaimVideo(peerId: PeerId, threadId: Int64?) -> (controller: IAyuGlobalVideoRecorder, isFinished: Bool)? {
        assert(Queue.mainQueue().isCurrent())
        guard let session = self.videoSession, session.target.matches(peerId: peerId, threadId: threadId) else {
            return nil
        }
        self.videoSession = nil
        self.pushState()
        return (session.controller, session.isFinished)
    }

    /// The take ended on its own — the one-minute cap with chunking off, or something took
    /// the camera away. The session stays: what was filmed is still there to send, and the
    /// chat turns it into a preview when it is next opened.
    public func videoRecordingDidFinish() {
        assert(Queue.mainQueue().isCurrent())
        guard let session = self.videoSession, !session.isFinished else {
            return
        }
        session.isFinished = true
        self.pushState()
    }

    /// The camera screen is done with itself — it sent, or it was discarded. Only the slot
    /// has to be released; the controller tears itself down.
    public func videoSessionEnded(controller: IAyuGlobalVideoRecorder) {
        assert(Queue.mainQueue().isCurrent())
        guard let session = self.videoSession, session.controller === controller else {
            return
        }
        self.videoSession = nil
        self.pushState()
    }

    public func stopVideo(reason: IAyuGlobalRecordingStopReason) {
        assert(Queue.mainQueue().isCurrent())
        guard let session = self.videoSession else {
            return
        }
        switch reason {
        case .send:
            // The controller answers through its completion, which routes back into
            // enqueueFromVideoSession and releases the slot there.
            session.controller.iAyuSendFromPanel()
        case .cancel:
            self.videoSession = nil
            self.pushState()
            session.controller.iAyuCancelFromPanel()
        case .preempted, .accountSwitched, .applicationBackgrounded:
            session.controller.iAyuStopRecordingKeepingTake()
            self.videoRecordingDidFinish()
        }
    }

    /// Send a message the camera screen built into the chat the recording started in.
    /// `isChunk` is a long take being cut at the cap: the camera keeps running, so the slot
    /// must survive it.
    public func enqueueFromVideoSession(_ message: EnqueueMessage, isChunk: Bool) {
        assert(Queue.mainQueue().isCurrent())
        guard let session = self.videoSession else {
            return
        }
        var message = message
        if !session.didUseReply, let replySubject = session.target.replySubject {
            session.didUseReply = true
            message = message.withUpdatedReplyToMessageId(replySubject)
        }
        if session.target.silentPosting {
            message = message.withUpdatedAttributes { attributes in
                var attributes = attributes
                attributes.removeAll(where: { $0 is NotificationInfoMessageAttribute })
                attributes.append(NotificationInfoMessageAttribute(flags: .muted))
                return attributes
            }
        }
        if let threadId = session.target.threadId {
            message = message.withUpdatedThreadId(threadId)
        }
        let _ = enqueueMessages(account: session.account, peerId: session.target.peerId, messages: [message]).start()

        if !isChunk {
            self.videoSession = nil
            self.pushState()
        }
    }

    // MARK: - Ending a recording

    public func stop(reason: IAyuGlobalRecordingStopReason) {
        assert(Queue.mainQueue().isCurrent())
        guard let session = self.session else {
            return
        }
        session.stateDisposable?.dispose()
        session.stateDisposable = nil
        self.session = nil
        self.pushState()

        let target = session.target
        let account = session.account
        let recorder = session.recorder

        if case .cancel = reason {
            recorder.stop()
            return
        }

        recorder.stop()
        // takenRecordedData() is the only way to get the encoded ogg out, and it answers
        // asynchronously — hold the recorder until it does, or it deallocates mid-answer
        // and the recording is lost.
        let _ = (recorder.takenRecordedData()
        |> deliverOnMainQueue).start(next: { [weak self] data in
            withExtendedLifetime(recorder) {
                guard let data, data.duration >= 0.5 else {
                    // Under half a second is a mis-tap, the same threshold the in-chat
                    // path uses.
                    return
                }
                if case let .send(viewOnce) = reason {
                    IAyuGlobalRecordingManager.send(data: data, target: target, account: account, viewOnce: viewOnce)
                } else {
                    self?.storePendingDraft(target: target, data: data)
                }
            }
        })
    }

    /// Stop and send, from outside the chat. This is the whole reason the target is a
    /// snapshot: `transformEnqueueMessages` and `sendMessages` live on the chat
    /// controller and read a dozen pieces of live chat state, none of which exists here.
    /// Ghost mode still applies — invisible send is inside `enqueueMessages` itself.
    private static func send(
        data: RecordedAudioData,
        target: IAyuGlobalRecordingTarget,
        account: Account,
        viewOnce: Bool
    ) {
        let randomId = Int64.random(in: Int64.min ... Int64.max)
        let resource = LocalFileMediaResource(fileId: randomId)
        account.postbox.mediaBox.storeResourceData(resource.id, data: data.compressedData)

        var attributes: [MessageAttribute] = []
        if viewOnce && target.viewOnceAvailable {
            attributes.append(AutoremoveTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil))
        }
        if target.silentPosting {
            attributes.append(NotificationInfoMessageAttribute(flags: .muted))
        }

        let file = TelegramMediaFile(
            fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: randomId),
            partialReference: nil,
            resource: resource,
            previewRepresentations: [],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: "audio/ogg",
            size: Int64(data.compressedData.count),
            attributes: [.Audio(isVoice: true, duration: Int(data.duration), title: nil, performer: nil, waveform: data.waveform)],
            alternativeRepresentations: []
        )

        let message: EnqueueMessage = .message(
            text: "",
            attributes: attributes,
            inlineStickers: [:],
            mediaReference: .standalone(media: file),
            threadId: target.threadId,
            replyToMessageId: target.replySubject,
            replyToStoryId: nil,
            localGroupingKey: nil,
            correlationId: nil,
            bubbleUpEmojiOrStickersets: []
        )
        let _ = enqueueMessages(account: account, peerId: target.peerId, messages: [message]).start()
    }

    // MARK: - Drafts left behind

    private func storePendingDraft(target: IAyuGlobalRecordingTarget, data: RecordedAudioData) {
        self.pendingDrafts.removeAll(where: { $0.target.matches(peerId: target.peerId, threadId: target.threadId) })
        self.pendingDrafts.append((target, data))
        // One is enough: this exists to survive the trip back to one chat, not to be an
        // archive. Keeping every abandoned take would pin their audio in memory.
        if self.pendingDrafts.count > 4 {
            self.pendingDrafts.removeFirst()
        }
    }

    /// Claim the audio of a recording that ended while this chat was off screen. Removes
    /// it, so it is installed as a draft exactly once.
    public func takePendingDraft(peerId: PeerId, threadId: Int64?) -> RecordedAudioData? {
        assert(Queue.mainQueue().isCurrent())
        guard let index = self.pendingDrafts.firstIndex(where: { $0.target.matches(peerId: peerId, threadId: threadId) }) else {
            return nil
        }
        let data = self.pendingDrafts[index].data
        self.pendingDrafts.remove(at: index)
        return data
    }

    // MARK: - App-level events

    /// The active account changed. The recording belongs to the account it started in,
    /// and sending into an account the user has walked away from would be a surprise, so
    /// it is stopped and kept as a draft in its own chat.
    public func handleAccountSwitch(to accountId: AccountRecordId) {
        assert(Queue.mainQueue().isCurrent())
        if let session = self.session, session.target.accountId != accountId {
            self.stop(reason: .accountSwitched)
        }
        if let videoSession = self.videoSession, videoSession.target.accountId != accountId {
            self.stopVideo(reason: .accountSwitched)
        }
    }

    /// The app left the foreground. Recording in the background needs an audio-mode
    /// entitlement and a different session policy, so for now this ends the recording —
    /// but keeps it, which is the part upstream does not do.
    public func handleApplicationBackgrounded() {
        assert(Queue.mainQueue().isCurrent())
        if self.session != nil {
            self.stop(reason: .applicationBackgrounded)
        }
        if self.videoSession != nil {
            // iOS suspends the capture session anyway; this only makes sure the take is
            // closed rather than left half-written.
            self.stopVideo(reason: .applicationBackgrounded)
        }
    }

    private func pushState() {
        let version = self.nextVersion
        self.nextVersion += 1
        if let session = self.session {
            self.stateValue = IAyuGlobalRecordingState(
                kind: .voice,
                target: session.target,
                startedAt: session.startedAt,
                isFinished: false,
                version: version
            )
        } else if let videoSession = self.videoSession {
            self.stateValue = IAyuGlobalRecordingState(
                kind: .video,
                target: videoSession.target,
                startedAt: videoSession.startedAt,
                isFinished: videoSession.isFinished,
                version: version
            )
        } else {
            self.stateValue = nil
        }
        self.statePromise.set(.single(self.stateValue))
    }
}
