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

    private init() {
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
