import Foundation
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
    public let target: IAyuGlobalRecordingTarget
    public let startedAt: Double
    public let version: Int

    init(target: IAyuGlobalRecordingTarget, startedAt: Double, version: Int) {
        self.target = target
        self.startedAt = startedAt
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

    private var session: Session?
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
        return self.session?.target
    }

    /// True while a recording is held here — i.e. one is running outside its chat. Used
    /// for the single-slot rule: no second recording may start anywhere.
    public var isRecording: Bool {
        return self.session != nil
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
        guard let session = self.session, session.target.accountId != accountId else {
            return
        }
        self.stop(reason: .accountSwitched)
    }

    /// The app left the foreground. Recording in the background needs an audio-mode
    /// entitlement and a different session policy, so for now this ends the recording —
    /// but keeps it, which is the part upstream does not do.
    public func handleApplicationBackgrounded() {
        assert(Queue.mainQueue().isCurrent())
        guard self.session != nil else {
            return
        }
        self.stop(reason: .applicationBackgrounded)
    }

    private func pushState() {
        if let session = self.session {
            let version = self.nextVersion
            self.nextVersion += 1
            self.stateValue = IAyuGlobalRecordingState(
                target: session.target,
                startedAt: session.startedAt,
                version: version
            )
        } else {
            self.stateValue = nil
        }
        self.statePromise.set(.single(self.stateValue))
    }
}
