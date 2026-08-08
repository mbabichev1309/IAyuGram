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

    private let lock = NSLock()
    private var currentState: IAyuCaptureState = .notConfigured

    private init() {
    }

    public var state: IAyuCaptureState {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.currentState
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
        self.lock.lock()
        let changed = self.currentState != state
        self.currentState = state
        self.lock.unlock()

        guard changed else {
            return
        }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: IAyuCaptureHealth.changedNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: IAyuCaptureHealth.changedNotification, object: nil)
            }
        }
    }
}
