import Foundation

// IAyuGram — shared health of the companion capture pipeline.
//
// Everything the fork preserves depends on the capture server being alive and its
// Telegram session still authorized. Both can die silently: systemd can be down, the
// box can be off, or Telegram can invalidate the companion session (a password change,
// "terminate all other sessions"). Nothing on the phone would notice, and the loss is
// unrecoverable — the deletes that happen during the outage are never replayed.
//
// So the sync manager publishes a coarse state here and the chat list shows a marker
// when it is degraded. Kept in SGSimpleSettings because it is the lowest module both
// the sync manager (SGSettingsUI) and the chat list title (ChatListTitleView) already
// depend on.
//
// NOTE: "no events for a while" is deliberately NOT a signal. Nobody deletes anything
// overnight, so a quiet stretch is normal and would produce a red marker on a perfectly
// healthy system. The live socket carries a 20s keepalive, so its state is the honest
// signal for reachability, and /healthz reports whether the session is still authorized.
public enum IAyuCaptureState: Int {
    // No companion server configured — the feature is off, never warn.
    case notConfigured
    case healthy
    // The live socket has been down past the grace period.
    case unreachable
    // The server answers, but its Telegram session is no longer authorized: the process
    // is alive and capturing nothing, which is the most dangerous state of the three.
    case sessionLost
}

// Warn below this much free space on the server. Absolute rather than a percentage on
// purpose: 10% of a large disk is tens of spare gigabytes and would never fire, while
// 10% of a small one can be less than a single capture (media_max_bytes is 512 MB).
public let iAyuStorageWarningFreeBytes: Int64 = 5 * 1024 * 1024 * 1024

public final class IAyuCaptureHealth {
    public static let shared = IAyuCaptureHealth()

    // Posted on the main queue whenever `state` changes.
    public static let changedNotification = Notification.Name("IAyuCaptureHealthChanged")

    // The state lives in UserDefaults rather than in a stored property, deliberately.
    // The writer (IAyuSyncManager, in SGSettingsUI) and the reader (the chat list title,
    // in ChatListTitleView) are different modules, and a statically linked module can
    // end up with one copy of its globals per link unit — so `shared` is not necessarily
    // the same object on both sides. NotificationCenter.default IS process-wide, which
    // produced exactly the symptom that cost a build cycle here: the notification
    // arrived, the reader re-read ITS copy, found it healthy, and drew nothing while the
    // settings screen was reporting UNREACHABLE. UserDefaults is shared by construction.
    private static let stateKey = "ia_capture_state"
    // Same UserDefaults reasoning as `state` above — the writer and the reader are in
    // different modules and cannot rely on sharing an instance.
    private static let storageLowKey = "ia_storage_low"
    private static let storageFreeKey = "ia_storage_free_bytes"

    private init() {
    }

    // Kept apart from `state` rather than added to IAyuCaptureState: the two are
    // independent (capture can be down while the disk is fine, and both can be true at
    // once), and folding them into one enum would make `isDegraded` mean two things.
    // The chat list prefers the capture warning — that one means data is being lost
    // right now, this one means it may be lost later.
    public var isStorageLow: Bool {
        return UserDefaults.standard.bool(forKey: IAyuCaptureHealth.storageLowKey)
    }

    // Last figure the server reported, or nil if none has arrived yet. Diagnostics only.
    public var lastStorageFreeBytes: Int64? {
        guard UserDefaults.standard.object(forKey: IAyuCaptureHealth.storageFreeKey) != nil else {
            return nil
        }
        return Int64(UserDefaults.standard.integer(forKey: IAyuCaptureHealth.storageFreeKey))
    }

    // Diagnostics: drive the warning directly, the way forceDegraded does for capture.
    // A box with hundreds of free gigabytes cannot produce this state on demand.
    public func forceStorageLow() {
        UserDefaults.standard.set(true, forKey: IAyuCaptureHealth.storageLowKey)
        NotificationCenter.default.post(name: IAyuCaptureHealth.changedNotification, object: nil)
    }

    // Which warning the chat list title should carry, if any. Both renderers ask this
    // one question so the priority is decided in a single place: capture-down wins,
    // because it means data is being lost right now, while low storage only means it
    // may be lost later.
    public var chatListWarningKey: IAyuStringKey? {
        if self.isDegraded {
            return .captureWarningTitle
        }
        if self.isStorageLow {
            return .storageWarningTitle
        }
        return nil
    }

    // `nil` means the server did not report a figure (an older build, or it could not
    // read the volume). Unknown must not clear an existing warning, so it is ignored.
    public func updateStorage(freeBytes: Int64?) {
        guard let freeBytes = freeBytes else {
            return
        }
        // Kept for the Connection screen's diagnostics. A disk with hundreds of free
        // gigabytes will never trip the threshold on its own, so showing the figure the
        // server actually reported is the only way to tell "the wiring works and there
        // is plenty of room" from "nothing is arriving at all".
        UserDefaults.standard.set(Int(freeBytes), forKey: IAyuCaptureHealth.storageFreeKey)

        let low = freeBytes < iAyuStorageWarningFreeBytes
        guard low != self.isStorageLow else {
            return
        }
        UserDefaults.standard.set(low, forKey: IAyuCaptureHealth.storageLowKey)

        if Thread.isMainThread {
            NotificationCenter.default.post(name: IAyuCaptureHealth.changedNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: IAyuCaptureHealth.changedNotification, object: nil)
            }
        }
    }

    public var state: IAyuCaptureState {
        let raw = UserDefaults.standard.integer(forKey: IAyuCaptureHealth.stateKey)
        return IAyuCaptureState(rawValue: raw) ?? .notConfigured
    }

    // True when the user should be told something is wrong.
    public var isDegraded: Bool {
        switch self.state {
        case .notConfigured, .healthy:
            return false
        case .unreachable, .sessionLost:
            return true
        }
    }

    public func update(_ state: IAyuCaptureState) {
        guard self.state != state else {
            return
        }
        UserDefaults.standard.set(state.rawValue, forKey: IAyuCaptureHealth.stateKey)

        if Thread.isMainThread {
            NotificationCenter.default.post(name: IAyuCaptureHealth.changedNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: IAyuCaptureHealth.changedNotification, object: nil)
            }
        }
    }
}
