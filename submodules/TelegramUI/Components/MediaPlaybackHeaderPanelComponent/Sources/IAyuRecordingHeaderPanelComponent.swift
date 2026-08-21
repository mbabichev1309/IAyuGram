import Foundation
import UIKit
import Display
import TelegramPresentationData
import ComponentFlow
import AccountContext
import TelegramCore
import GlobalControlPanelsContext
import SwiftSignalKit
import SGSimpleSettings

// MARK: IAyuGram — the panel for a voice recording that is running outside its chat.
//
// It lives in this module rather than one of its own because it is the same panel slot as
// music: both render through HeaderPanelContainerComponent at the two sites that host
// header panels (the chat list and the chat), and this module is already a dependency of
// both. It also takes that slot when both apply — recording wins, and the music it
// interrupted is paused anyway, since the audio session has a single active holder.
//
// The panel is the only pult for a recording whose chat is off screen: it shows the
// elapsed time, sends, discards, and tapping it goes back to the chat that owns it.

public final class IAyuRecordingHeaderPanelComponent: Component {
    public let context: AccountContext
    public let theme: PresentationTheme
    public let data: IAyuGlobalRecordingState
    public let controller: () -> ViewController?

    public init(
        context: AccountContext,
        theme: PresentationTheme,
        data: IAyuGlobalRecordingState,
        controller: @escaping () -> ViewController?
    ) {
        self.context = context
        self.theme = theme
        self.data = data
        self.controller = controller
    }

    public static func ==(lhs: IAyuRecordingHeaderPanelComponent, rhs: IAyuRecordingHeaderPanelComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.theme !== rhs.theme {
            return false
        }
        if lhs.data != rhs.data {
            return false
        }
        return true
    }

    public final class View: UIView {
        private let micIcon = UIImageView()
        private let durationLabel = UILabel()
        private let titleLabel = UILabel()
        private let discardButton = UIButton(type: .system)
        private let sendButton = UIButton(type: .system)
        private let separatorLine = UIView()

        private var component: IAyuRecordingHeaderPanelComponent?
        private var recordingStateDisposable: Disposable?
        private var currentDuration: Double = 0.0

        public override init(frame: CGRect) {
            super.init(frame: frame)

            self.durationLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15.0, weight: .semibold)
            self.titleLabel.font = Font.regular(13.0)
            self.titleLabel.lineBreakMode = .byTruncatingTail

            self.discardButton.titleLabel?.font = Font.regular(15.0)
            self.sendButton.titleLabel?.font = Font.semibold(15.0)
            self.discardButton.addTarget(self, action: #selector(self.discardPressed), for: .touchUpInside)
            self.sendButton.addTarget(self, action: #selector(self.sendPressed), for: .touchUpInside)

            self.addSubview(self.separatorLine)
            self.addSubview(self.micIcon)
            self.addSubview(self.durationLabel)
            self.addSubview(self.titleLabel)
            self.addSubview(self.discardButton)
            self.addSubview(self.sendButton)

            // Tapping the panel itself — anywhere but the two buttons, which are subviews
            // and get the touch first — returns to the chat being recorded into.
            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.panelTapped))
            self.addGestureRecognizer(tapRecognizer)
        }

        required public init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            self.recordingStateDisposable?.dispose()
        }

        @objc private func discardPressed() {
            IAyuGlobalRecordingManager.shared.stop(reason: .cancel)
        }

        @objc private func sendPressed() {
            IAyuGlobalRecordingManager.shared.stop(reason: .send(viewOnce: false))
        }

        @objc private func panelTapped() {
            guard let component = self.component else {
                return
            }
            let target = component.data.target
            component.context.sharedContext.navigateToChat(
                accountId: target.accountId,
                peerId: target.peerId,
                messageId: nil
            )
        }

        private func updateDurationText() {
            let seconds = Int(self.currentDuration)
            self.durationLabel.text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        }

        func update(component: IAyuRecordingHeaderPanelComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            let previousData = self.component?.data
            self.component = component

            let theme = component.theme
            self.backgroundColor = theme.rootController.navigationBar.opaqueBackgroundColor
            self.separatorLine.backgroundColor = theme.rootController.navigationBar.separatorColor
            self.micIcon.image = generateTintedImage(
                image: UIImage(systemName: "mic.fill")?.withRenderingMode(.alwaysTemplate),
                color: theme.list.itemDestructiveColor
            )
            self.durationLabel.textColor = theme.rootController.navigationBar.primaryTextColor
            self.titleLabel.textColor = theme.rootController.navigationBar.secondaryTextColor
            self.discardButton.setTitleColor(theme.list.itemDestructiveColor, for: .normal)
            self.sendButton.setTitleColor(theme.rootController.navigationBar.accentTextColor, for: .normal)
            self.discardButton.setTitle(IAyuStrings.text(.recordingPanelCancel), for: .normal)
            self.sendButton.setTitle(IAyuStrings.text(.recordingPanelSend), for: .normal)

            let peerTitle = component.data.target.peerTitle
            if peerTitle.isEmpty {
                self.titleLabel.text = IAyuStrings.text(.recordingPanelTitle)
            } else {
                self.titleLabel.text = "\(IAyuStrings.text(.recordingPanelTitle)) · \(peerTitle)"
            }

            // Resubscribe only when the recording itself changed: the signal is the live
            // recorder's, and re-subscribing on every layout pass would churn it.
            if previousData == nil || previousData != component.data {
                self.recordingStateDisposable?.dispose()
                self.currentDuration = 0.0
                self.updateDurationText()
                if let recorder = IAyuGlobalRecordingManager.shared.activeRecorder {
                    self.recordingStateDisposable = (recorder.recordingState
                    |> deliverOnMainQueue).start(next: { [weak self] recordingState in
                        guard let self else {
                            return
                        }
                        switch recordingState {
                        case let .paused(duration):
                            self.currentDuration = duration
                        case let .recording(duration, _):
                            self.currentDuration = duration
                        case .stopped:
                            break
                        }
                        self.updateDurationText()
                    })
                }
            }

            let size = CGSize(width: availableSize.width, height: 40.0)
            let sideInset: CGFloat = 16.0
            let spacing: CGFloat = 8.0

            self.separatorLine.frame = CGRect(
                origin: CGPoint(x: 0.0, y: size.height - UIScreenPixel),
                size: CGSize(width: size.width, height: UIScreenPixel)
            )

            let iconSize = CGSize(width: 14.0, height: 18.0)
            self.micIcon.frame = CGRect(
                origin: CGPoint(x: sideInset, y: floorToScreenPixels((size.height - iconSize.height) / 2.0)),
                size: iconSize
            )

            let durationSize = CGSize(width: 44.0, height: size.height)
            self.durationLabel.frame = CGRect(
                origin: CGPoint(x: self.micIcon.frame.maxX + 6.0, y: 0.0),
                size: durationSize
            )

            // Buttons are laid out from the right edge, and the title takes what is left —
            // a long chat name must not push "Send" off the screen.
            let sendSize = self.sendButton.sizeThatFits(CGSize(width: size.width, height: size.height))
            let discardSize = self.discardButton.sizeThatFits(CGSize(width: size.width, height: size.height))
            self.sendButton.frame = CGRect(
                origin: CGPoint(x: size.width - sideInset - sendSize.width, y: 0.0),
                size: CGSize(width: sendSize.width, height: size.height)
            )
            self.discardButton.frame = CGRect(
                origin: CGPoint(x: self.sendButton.frame.minX - spacing - discardSize.width, y: 0.0),
                size: CGSize(width: discardSize.width, height: size.height)
            )

            let titleOriginX = self.durationLabel.frame.maxX + spacing
            let titleWidth = max(0.0, self.discardButton.frame.minX - spacing - titleOriginX)
            self.titleLabel.frame = CGRect(
                origin: CGPoint(x: titleOriginX, y: 0.0),
                size: CGSize(width: titleWidth, height: size.height)
            )

            return size
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
