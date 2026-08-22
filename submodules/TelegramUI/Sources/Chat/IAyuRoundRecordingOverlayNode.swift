import Foundation
import UIKit
import AsyncDisplayKit
import Display
import AccountContext

// MARK: IAyuGram — a minimized round-video recording, as the draggable circle.
//
// The same overlay Telegram already uses to keep a round MESSAGE on screen while you scroll
// away from it: OverlayMediaController owns the dragging, the edge snapping and the
// stacking, so all this has to do is hold the borrowed preview and answer a tap.
//
// The preview circle is the camera screen's own view, on loan. It keeps its full-size
// internal layout — the recording progress ring is drawn against it — and is scaled as a
// whole, so nothing inside has to know it is being shown at 150 points. It goes back the
// moment the recording is expanded again, which is also what takes it out of here.
final class IAyuRoundRecordingOverlayNode: OverlayMediaItemNode {
    private let previewView: UIView
    private let containerView: UIView
    private let tapped: () -> Void

    private var validLayoutSize: CGSize?

    /// The same group as the round-message overlay: only one circle at a time, and it takes
    /// the position the previous one had.
    override var group: OverlayMediaItemNodeGroup? {
        return OverlayMediaItemNodeGroup(rawValue: 1)
    }

    /// Deliberately not minimizeable. Hiding a running recording off the edge of the screen
    /// is a good way to forget it is running.
    override var isMinimizeable: Bool {
        return false
    }

    init(previewView: UIView, tapped: @escaping () -> Void) {
        self.previewView = previewView
        self.containerView = UIView()
        self.tapped = tapped

        super.init()

        // Without this the controller node parks the circle off-screen: it treats a node
        // with no attached context as one whose content is not ready.
        self.hasAttachedContext = true

        self.containerView.clipsToBounds = true
        self.view.addSubview(self.containerView)
        self.containerView.addSubview(previewView)
    }

    override func didLoad() {
        super.didLoad()

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTap))
        self.view.addGestureRecognizer(tapRecognizer)
    }

    @objc private func handleTap() {
        self.tapped()
    }

    override func preferredSizeForOverlayDisplay(boundingSize: CGSize) -> CGSize {
        let side: CGFloat = min(boundingSize.width, boundingSize.height) > 320.0 ? 150.0 : 120.0
        return CGSize(width: side, height: side)
    }

    override func layout() {
        self.updateLayout(self.bounds.size)
    }

    override func updateLayout(_ size: CGSize) {
        guard size != self.validLayoutSize else {
            return
        }
        self.validLayoutSize = size

        self.containerView.frame = CGRect(origin: CGPoint(), size: size)
        self.containerView.layer.cornerRadius = size.width / 2.0

        self.layoutPreview(in: size)
    }

    /// Re-run the scaling without waiting for a size change. The preview's own bounds are
    /// set by the camera screen, which may not have laid out yet when the circle is added.
    func refreshPreviewLayout() {
        if let size = self.validLayoutSize {
            self.layoutPreview(in: size)
        }
    }

    private func layoutPreview(in size: CGSize) {
        guard self.previewView.superview === self.containerView else {
            return
        }
        self.previewView.transform = .identity
        let naturalSide = max(self.previewView.bounds.width, 1.0)
        self.previewView.center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
        let scale = size.width / naturalSide
        self.previewView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// The overlay is not a pult — it has no buttons — so the close action the container
    /// offers must not throw a recording away. Expanding is the only thing a gesture here
    /// can mean.
    override func dismiss() {
        self.tapped()
    }
}
