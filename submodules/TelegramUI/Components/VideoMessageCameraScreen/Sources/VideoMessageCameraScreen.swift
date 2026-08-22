import SGSimpleSettings
import Foundation
import UIKit
import Display
import AsyncDisplayKit
import ComponentFlow
import SwiftSignalKit
import ViewControllerComponent
import ComponentDisplayAdapters
import TelegramPresentationData
import AccountContext
import TelegramCore
import PresentationDataUtils
import Camera
import MultilineTextComponent
import BlurredBackgroundComponent
import PlainButtonComponent
import Photos
import TooltipUI
import BundleIconComponent
import CameraButtonComponent
import TelegramNotices
import DeviceAccess
import MediaEditor
import MediaResources
import LocalMediaResources
import ImageCompression
import LegacyMediaPickerUI
import TelegramAudio
import ChatSendMessageActionUI
import ChatControllerInteraction
import LottieComponent
import GlassBackgroundComponent

struct CameraState: Equatable {
    enum Recording: Equatable {
        case none
        case holding
        case handsFree
    }
    enum FlashTint: Equatable {
        case white
        case yellow
        case blue
        
        var color: UIColor {
            switch self {
            case .white:
                return .white
            case .yellow:
                return UIColor(rgb: 0xffed8c)
            case .blue:
                return UIColor(rgb: 0x8cdfff)
            }
        }
    }
    
    let position: Camera.Position
    let flashMode: Camera.FlashMode
    let flashModeDidChange: Bool
    let flashTint: FlashTint
    let flashTintSize: CGFloat
    let recording: Recording
    let duration: Double
    let isDualCameraEnabled: Bool
    let isViewOnceEnabled: Bool
    
    func updatedPosition(_ position: Camera.Position) -> CameraState {
        return CameraState(position: position, flashMode: self.flashMode, flashModeDidChange: self.flashModeDidChange, flashTint: self.flashTint, flashTintSize: self.flashTintSize, recording: self.recording, duration: self.duration, isDualCameraEnabled: self.isDualCameraEnabled, isViewOnceEnabled: self.isViewOnceEnabled)
    }
    
    func updatedFlashMode(_ flashMode: Camera.FlashMode) -> CameraState {
        return CameraState(position: self.position, flashMode: flashMode, flashModeDidChange: self.flashMode != flashMode, flashTint: self.flashTint, flashTintSize: self.flashTintSize, recording: self.recording, duration: self.duration, isDualCameraEnabled: self.isDualCameraEnabled, isViewOnceEnabled: self.isViewOnceEnabled)
    }
    
    func updatedFlashTint(_ flashTint: FlashTint) -> CameraState {
        return CameraState(position: self.position, flashMode: self.flashMode, flashModeDidChange: self.flashModeDidChange, flashTint: flashTint, flashTintSize: self.flashTintSize, recording: self.recording, duration: self.duration, isDualCameraEnabled: self.isDualCameraEnabled, isViewOnceEnabled: self.isViewOnceEnabled)
    }
    
    func updatedFlashTintSize(_ flashTintSize: CGFloat) -> CameraState {
        return CameraState(position: self.position, flashMode: self.flashMode, flashModeDidChange: self.flashModeDidChange, flashTint: self.flashTint, flashTintSize: flashTintSize, recording: self.recording, duration: self.duration, isDualCameraEnabled: self.isDualCameraEnabled, isViewOnceEnabled: self.isViewOnceEnabled)
    }

    func updatedRecording(_ recording: Recording) -> CameraState {
        var flashModeDidChange = self.flashModeDidChange
        if case .none = self.recording {
            flashModeDidChange = false
        }
        return CameraState(position: self.position, flashMode: self.flashMode, flashModeDidChange: flashModeDidChange, flashTint: self.flashTint, flashTintSize: self.flashTintSize, recording: recording, duration: self.duration, isDualCameraEnabled: self.isDualCameraEnabled, isViewOnceEnabled: self.isViewOnceEnabled)
    }
    
    func updatedDuration(_ duration: Double) -> CameraState {
        return CameraState(position: self.position, flashMode: self.flashMode, flashModeDidChange: self.flashModeDidChange, flashTint: self.flashTint, flashTintSize: self.flashTintSize, recording: self.recording, duration: duration, isDualCameraEnabled: self.isDualCameraEnabled, isViewOnceEnabled: self.isViewOnceEnabled)
    }
    
    func updatedIsViewOnceEnabled(_ isViewOnceEnabled: Bool) -> CameraState {
        return CameraState(position: self.position, flashMode: self.flashMode, flashModeDidChange: self.flashModeDidChange, flashTint: self.flashTint, flashTintSize: self.flashTintSize, recording: self.recording, duration: self.duration, isDualCameraEnabled: self.isDualCameraEnabled, isViewOnceEnabled: isViewOnceEnabled)
    }
}

struct PreviewState: Equatable {
    let composition: AVComposition
    let trimRange: Range<Double>?
    let isMuted: Bool
}

enum CameraScreenTransition {
    case animateIn
    case animateOut
    case finishedAnimateIn
}

private let viewOnceButtonTag = GenericComponentViewTag()

private final class VideoMessageCameraScreenComponent: CombinedComponent {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment
    
    let context: AccountContext
    let cameraState: CameraState
    let containerSize: CGSize
    let previewFrame: CGRect
    let safeInsets: UIEdgeInsets
    let isPreviewing: Bool
    let isMuted: Bool
    let totalDuration: Double
    let getController: () -> VideoMessageCameraScreen?
    let present: (ViewController) -> Void
    let push: (ViewController) -> Void
    let startRecording: ActionSlot<Void>
    let stopRecording: ActionSlot<Void>
    let cancelRecording: ActionSlot<Void>
    let completion: ActionSlot<VideoMessageCameraScreen.CaptureResult>
    
    init(
        context: AccountContext,
        cameraState: CameraState,
        containerSize: CGSize,
        previewFrame: CGRect,
        safeInsets: UIEdgeInsets,
        isPreviewing: Bool,
        isMuted: Bool,
        totalDuration: Double,
        getController: @escaping () -> VideoMessageCameraScreen?,
        present: @escaping (ViewController) -> Void,
        push: @escaping (ViewController) -> Void,
        startRecording: ActionSlot<Void>,
        stopRecording: ActionSlot<Void>,
        cancelRecording: ActionSlot<Void>,
        completion: ActionSlot<VideoMessageCameraScreen.CaptureResult>
    ) {
        self.context = context
        self.cameraState = cameraState
        self.containerSize = containerSize
        self.previewFrame = previewFrame
        self.safeInsets = safeInsets
        self.isPreviewing = isPreviewing
        self.isMuted = isMuted
        self.totalDuration = totalDuration
        self.getController = getController
        self.present = present
        self.push = push
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.cancelRecording = cancelRecording
        self.completion = completion
    }
    
    static func ==(lhs: VideoMessageCameraScreenComponent, rhs: VideoMessageCameraScreenComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.previewFrame != rhs.previewFrame {
            return false
        }
        if lhs.safeInsets != rhs.safeInsets {
            return false
        }
        if lhs.cameraState != rhs.cameraState {
            return false
        }
        if lhs.containerSize != rhs.containerSize {
            return false
        }
        if lhs.isPreviewing != rhs.isPreviewing {
            return false
        }
        if lhs.isMuted != rhs.isMuted {
            return false
        }
        if lhs.totalDuration != rhs.totalDuration {
            return false
        }
        return true
    }
    
    final class State: ComponentState {
        enum ImageKey: Hashable {
            case flip
            case flash
            case flashImage
        }
        private var cachedImages: [ImageKey: UIImage] = [:]
        func image(_ key: ImageKey, theme: PresentationTheme) -> UIImage {
            if let image = self.cachedImages[key] {
                return image
            } else {
                var image: UIImage
                switch key {
                case .flip:
                    image = UIImage(bundleImageName: "Camera/VideoMessageFlip")!.withRenderingMode(.alwaysTemplate)
                case .flash:
                    image = UIImage(bundleImageName: "Camera/VideoMessageFlash")!.withRenderingMode(.alwaysTemplate)
                case .flashImage:
                    image = generateImage(CGSize(width: 393.0, height: 852.0), rotatedContext: { size, context in
                        context.clear(CGRect(origin: .zero, size: size))
                        
                        var locations: [CGFloat] = [0.0, 0.2, 0.6, 1.0]
                        let colors: [CGColor] = [UIColor(rgb: 0xffffff, alpha: 0.25).cgColor, UIColor(rgb: 0xffffff, alpha: 0.25).cgColor, UIColor(rgb: 0xffffff, alpha: 1.0).cgColor, UIColor(rgb: 0xffffff, alpha: 1.0).cgColor]
                        let colorSpace = CGColorSpaceCreateDeviceRGB()
                        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: &locations)!
                        
                        let center = CGPoint(x: size.width / 2.0, y: size.height / 2.0 - 10.0)
                        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0.0, endCenter: center, endRadius: size.width, options: .drawsAfterEndLocation)
                    })!.withRenderingMode(.alwaysTemplate)
                }
                cachedImages[key] = image
                return image
            }
        }
                
        private let context: AccountContext
        private let present: (ViewController) -> Void
        private let startRecording: ActionSlot<Void>
        private let stopRecording: ActionSlot<Void>
        private let cancelRecording: ActionSlot<Void>
        private let completion: ActionSlot<VideoMessageCameraScreen.CaptureResult>
        private let getController: () -> VideoMessageCameraScreen?
        
        private var resultDisposable = MetaDisposable()
        // Kept apart from resultDisposable: closing a chunk has to dispose the stop
        // subscription without touching the recording subscription that replaces it.
        private let flushDisposable = MetaDisposable()

        var cameraState: CameraState?
        
        var didDisplayViewOnce = false
        
        var displayingFlashTint = false
                    
        private let hapticFeedback = HapticFeedback()
        
        init(
            context: AccountContext,
            present: @escaping (ViewController) -> Void,
            startRecording: ActionSlot<Void>,
            stopRecording: ActionSlot<Void>,
            cancelRecording: ActionSlot<Void>,
            completion: ActionSlot<VideoMessageCameraScreen.CaptureResult>,
            getController: @escaping () -> VideoMessageCameraScreen? = {
                return nil
            }
        ) {
            self.context = context
            self.present = present
            self.startRecording = startRecording
            self.stopRecording = stopRecording
            self.cancelRecording = cancelRecording
            self.completion = completion
            self.getController = getController
            
            super.init()
            
            self.startRecording.connect({ [weak self] _ in
                if let self, let controller = getController() {
                    self.startVideoRecording(pressing: !controller.scheduledLock)
                    controller.scheduledLock = false
                    if controller.recordingStartTime == nil {
                        controller.recordingStartTime = CACurrentMediaTime()
                    }
                }
            })
            self.stopRecording.connect({ [weak self] _ in
                self?.stopVideoRecording()
            })
            
            self.cancelRecording.connect({ [weak self] _ in
                self?.cancelVideoRecording()
            })
        }
        
        deinit {
            self.resultDisposable.dispose()
            self.flushDisposable.dispose()
        }
        
        func toggleViewOnce() {
            guard let controller = self.getController() else {
                return
            }
            controller.updateCameraState({ $0.updatedIsViewOnceEnabled(!$0.isViewOnceEnabled) }, transition: .easeInOut(duration: 0.2))
        }
        
        private var lastFlipTimestamp: Double?
        func togglePosition() {
            guard let controller = self.getController(), let camera = controller.camera else {
                return
            }
            let currentTimestamp = CACurrentMediaTime()
            if let lastFlipTimestamp = self.lastFlipTimestamp, currentTimestamp - lastFlipTimestamp < 1.0 {
                return
            }
            self.lastFlipTimestamp = currentTimestamp
            
            let isFrontCamera = controller.cameraState.position == .back
            camera.togglePosition()
                                    
            self.hapticFeedback.impact(.veryLight)
            
            self.updateScreenBrightness(isFrontCamera: isFrontCamera)
            
            if isFrontCamera {
                camera.setTorchActive(false)
            } else {
                camera.setTorchActive(controller.cameraState.flashMode == .on)
            }
        }
        
        func toggleFlashMode() {
            guard let controller = self.getController(), let camera = controller.camera else {
                return
            }
            var isFlashOn = false
            switch controller.cameraState.flashMode {
            case .off:
                isFlashOn = true
                camera.setFlashMode(.on)
            case .on:
                camera.setFlashMode(.off)
            default:
                camera.setFlashMode(.off)
            }
            self.hapticFeedback.impact(.light)
            
            self.updateScreenBrightness(isFlashOn: isFlashOn)
            
            if controller.cameraState.position == .back {
                camera.setTorchActive(isFlashOn)
            }
        }
        
        private var initialBrightness: CGFloat?
        private var brightnessArguments: (Double, Double, CGFloat, CGFloat)?
        private var brightnessAnimator: ConstantDisplayLinkAnimator?
        
        func updateScreenBrightness(isFrontCamera: Bool? = nil, isFlashOn: Bool? = nil) {
            guard let controller = self.getController() else {
                return
            }
            let isFrontCamera = isFrontCamera ?? (controller.cameraState.position == .front)
            let isFlashOn = isFlashOn ?? (controller.cameraState.flashMode == .on)
            
            if isFrontCamera && isFlashOn {
                if self.initialBrightness == nil {
                    self.initialBrightness = UIScreen.main.brightness
                    self.brightnessArguments = (CACurrentMediaTime(), 0.2, UIScreen.main.brightness, 1.0)
                    self.animateBrightnessChange()
                }
            } else {
                if let initialBrightness = self.initialBrightness {
                    self.initialBrightness = nil
                    self.brightnessArguments = (CACurrentMediaTime(), 0.2, UIScreen.main.brightness, initialBrightness)
                    self.animateBrightnessChange()
                }
            }
        }
        
        private func animateBrightnessChange() {
            if self.brightnessAnimator == nil {
                self.brightnessAnimator = ConstantDisplayLinkAnimator(update: { [weak self] in
                    self?.animateBrightnessChange()
                })
                self.brightnessAnimator?.isPaused = true
            }
            
            if let (startTime, duration, initial, target) = self.brightnessArguments {
                self.brightnessAnimator?.isPaused = false
                
                let t = CGFloat(max(0.0, min(1.0, (CACurrentMediaTime() - startTime) / duration)))
                let value = initial + (target - initial) * t
                
                UIScreen.main.brightness = value
                
                if t >= 1.0 {
                    self.brightnessArguments = nil
                    self.brightnessAnimator?.isPaused = true
                    self.brightnessAnimator?.invalidate()
                    self.brightnessAnimator = nil
                }
            } else {
                self.brightnessAnimator?.isPaused = true
                self.brightnessAnimator?.invalidate()
                self.brightnessAnimator = nil
            }
        }
        
        // `skipCameraWarmUp` starts writing without waiting on the preview: it is only for
        // IAyuGram's chunk restart, where capture was never paused, so the readiness wait
        // (0.3s inside withReadyCamera plus the 0.15s hop) would be dead time in the seam.
        func startVideoRecording(pressing: Bool, skipCameraWarmUp: Bool = false) {
            guard let controller = self.getController(), let camera = controller.camera else {
                return
            }
            guard case .none = controller.cameraState.recording else {
                return
            }

            let currentTimestamp = CACurrentMediaTime()
            if let lastActionTimestamp = controller.lastActionTimestamp, currentTimestamp - lastActionTimestamp < 0.5 {
                return
            }
            controller.lastActionTimestamp = currentTimestamp

            let initialDuration = controller.node.previewState?.composition.duration.seconds ?? 0.0
            let isFirstRecording = initialDuration.isZero
            controller.node.resumeCameraCapture()

            controller.node.dismissAllTooltips()
            controller.updateCameraState({ $0.updatedRecording(pressing ? .holding : .handsFree).updatedDuration(initialDuration) }, transition: .spring(duration: 0.4))

            controller.updatePreviewState({ _ in return nil }, transition: .spring(duration: 0.4))

            let beginRecording: () -> Void = { [weak self] in
                guard let self else {
                    return
                }
                self.resultDisposable.set((camera.startRecording()
                |> deliverOnMainQueue).startStrict(next: { [weak self] recordingData in
                    let duration = initialDuration + recordingData.duration
                    if let self, let controller = self.getController() {
                        controller.updateCameraState({ $0.updatedDuration(duration) }, transition: .easeInOut(duration: 0.1))
                        if isFirstRecording {
                            controller.node.setupLiveUpload(filePath: recordingData.filePath)
                        }
                        if duration > 59.5 {
                            // IAyuGram: past the cap, either send the finished chunk and carry
                            // straight on recording, or fall back to stock behaviour — pause
                            // and wait for the user to send. This fires on every tick past the
                            // cap, so a flush already under way has to swallow the rest:
                            // falling through to onStop would pause mid-chunk.
                            if !controller.iAyuIsFlushingChunk {
                                if controller.iAyuShouldFlushChunk {
                                    self.iAyuFlushChunk()
                                } else {
                                    controller.onStop()
                                }
                            }
                        }
                    }
                }, error: { [weak self] _ in
                    if let self, let controller = self.getController() {
                        controller.completion(nil, nil, nil, nil)
                    }
                }))
            }

            if skipCameraWarmUp {
                beginRecording()
            } else {
                controller.node.withReadyCamera(isFirstTime: !controller.node.cameraIsActive) {
                    Queue.mainQueue().after(0.15) {
                        beginRecording()
                    }
                }
            }

            if initialDuration > 0.0 {
                controller.onResume()
            }

            if controller.cameraState.position == .front && controller.cameraState.flashMode == .on {
                self.updateScreenBrightness()
            }
        }
        
        func stopVideoRecording() {
            guard let controller = self.getController(), let camera = controller.camera else {
                return
            }
            // Letting go of the button inside a chunk flush would stop a camera that is
            // already stopping. Hold the action and run it once the next chunk is recording.
            if controller.iAyuIsFlushingChunk {
                controller.iAyuPendingFlushAction = { [weak self] in
                    self?.stopVideoRecording()
                }
                return
            }
            let currentTimestamp = CACurrentMediaTime()
            if let lastActionTimestamp = controller.lastActionTimestamp, currentTimestamp - lastActionTimestamp < 0.5 {
                return
            }
            controller.lastActionTimestamp = currentTimestamp
            
            self.resultDisposable.set((camera.stopRecording()
            |> deliverOnMainQueue).startStrict(next: { [weak self] result in
                if let self, let controller = self.getController(), case let .finished(mainResult, _, duration, _, _) = result {
                    self.completion.invoke(
                        .video(VideoMessageCameraScreen.CaptureResult.Video(
                            videoPath: mainResult.path,
                            dimensions: PixelDimensions(mainResult.dimensions),
                            duration: duration,
                            thumbnail: mainResult.thumbnail
                        ))
                    )
                    controller.updateCameraState({ $0.updatedRecording(.none) }, transition: .spring(duration: 0.4))
                }
            }))
            
            if let initialBrightness = self.initialBrightness {
                self.initialBrightness = nil
                self.brightnessArguments = (CACurrentMediaTime(), 0.2, UIScreen.main.brightness, initialBrightness)
                self.animateBrightnessChange()
            }
        }

        // IAyuGram: close the current chunk of a long round video, send it on its own, and
        // start the next one. Deliberately does NOT go through the component's `completion`
        // slot: that lands in addCaptureResult, which stops capture and swaps the live camera
        // for a preview of what was just shot. Here the camera has to keep running, so the
        // finished segment is handed straight to the controller and never enters `results`.
        func iAyuFlushChunk() {
            guard let controller = self.getController(), let camera = controller.camera else {
                return
            }
            guard !controller.iAyuIsFlushingChunk else {
                return
            }
            controller.iAyuIsFlushingChunk = true

            // The next chunk has to resume in the mode the user is actually in — a held
            // button must not come back as hands-free, or letting go would do nothing.
            // Held on the controller because the lock button can still be tapped while the
            // flush is in flight.
            if case .holding = controller.cameraState.recording {
                controller.iAyuChunkResumePressing = true
            } else {
                controller.iAyuChunkResumePressing = false
            }

            // The cap is noticed from inside the running recording's own callback, and the
            // stop below replaces that very subscription. Take the flag now so nothing
            // re-enters, then do the work off the callback.
            Queue.mainQueue().justDispatch { [weak self] in
                guard let self else {
                    return
                }
                self.iAyuBeginFlush(camera: camera)
            }
        }

        private func iAyuBeginFlush(camera: Camera) {
            // Drop the finished recording's progress subscription, the way upstream's stop
            // does by overwriting it. Left alive it keeps reporting a duration past the cap.
            // The recorder itself is unaffected — it writes until stopRecording below.
            self.resultDisposable.set(nil)

            self.flushDisposable.set((camera.stopRecording()
            |> deliverOnMainQueue).startStrict(next: { [weak self] result in
                guard let self, let controller = self.getController() else {
                    return
                }
                // CameraOutput releases its recorder in the stop signal's afterDisposed, and
                // startRecording refuses to start while that recorder is still around. So the
                // subscription is dropped here rather than left to complete on its own —
                // otherwise whether the next chunk records at all comes down to which main
                // queue block happens to run first, and a loss is silent.
                self.flushDisposable.set(nil)

                guard case let .finished(mainResult, _, duration, _, _) = result else {
                    controller.iAyuIsFlushingChunk = false
                    return
                }

                controller.iAyuSendChunk(video: VideoMessageCameraScreen.CaptureResult.Video(
                    videoPath: mainResult.path,
                    dimensions: PixelDimensions(mainResult.dimensions),
                    duration: duration,
                    thumbnail: mainResult.thumbnail
                ))

                // Back to a clean slate: no accumulated segments, so the next chunk records
                // from zero and a final send only carries the tail.
                controller.updateCameraState({ $0.updatedRecording(.none).updatedDuration(0.0) }, transition: .immediate)
                controller.lastActionTimestamp = nil

                // Hop off this signal's own callback before replacing resultDisposable with
                // the next recording's subscription. The flush flag stays up across the hop:
                // a touch delivered in between would otherwise stop a camera that has no
                // recorder yet, which leaves the panel recording forever.
                Queue.mainQueue().justDispatch { [weak self] in
                    guard let self, let controller = self.getController() else {
                        return
                    }
                    if case .none = controller.cameraState.recording {
                        self.startVideoRecording(pressing: controller.iAyuChunkResumePressing, skipCameraWarmUp: true)
                    }
                    controller.iAyuIsFlushingChunk = false

                    // A stop or send that landed inside the flush window was held back rather
                    // than run against a camera that was mid-restart. Run it now, against the
                    // recording that just started. Clearing the timestamp matters: the restart
                    // stamped it, and both of those paths debounce on it for half a second.
                    if let pendingAction = controller.iAyuPendingFlushAction {
                        controller.iAyuPendingFlushAction = nil
                        controller.lastActionTimestamp = nil
                        pendingAction()
                    }
                }
            }))
        }

        func lockVideoRecording() {
            guard let controller = self.getController() else {
                return
            }
            // Locking inside a chunk flush would otherwise be undone by the restart, which
            // resumes in whatever mode was captured when the flush began.
            if controller.iAyuIsFlushingChunk {
                controller.iAyuChunkResumePressing = false
            }
            controller.updateCameraState({ $0.updatedRecording(.handsFree) }, transition: .spring(duration: 0.4))
        }
        
        func cancelVideoRecording() {
            if let initialBrightness = self.initialBrightness {
                self.initialBrightness = nil
                self.brightnessArguments = (CACurrentMediaTime(), 0.2, UIScreen.main.brightness, initialBrightness)
                self.animateBrightnessChange()
            }
        }
        
        func updateZoom(fraction: CGFloat) {
            guard let camera = self.getController()?.camera else {
                return
            }
            camera.setZoomLevel(fraction)
        }
    }
    
    func makeState() -> State {
        return State(context: self.context, present: self.present, startRecording: self.startRecording, stopRecording: self.stopRecording, cancelRecording: self.cancelRecording, completion: self.completion, getController: self.getController)
    }
    
    static var body: Body {
        let frontFlash = Child(Image.self)
        let flipButtonBackground = Child(GlassBackgroundComponent.self)
        let flipButton = Child(CameraButton.self)
        let flashButtonBackground = Child(GlassBackgroundComponent.self)
        let flashButton = Child(CameraButton.self)
        
        let viewOnceButton = Child(PlainButtonComponent.self)
        let recordMoreButton = Child(PlainButtonComponent.self)
        // IAyuGram: leave the chat, keep recording.
        let minimizeButton = Child(PlainButtonComponent.self)
        
        let muteIcon = Child(ZStack<Empty>.self)
        
        let flashAction = ActionSlot<Void>()
                        
        return { context in
            let environment = context.environment[ViewControllerComponentContainer.Environment.self].value
            let component = context.component
            let state = context.state
            let availableSize = context.component.containerSize
            
            var sideInset: CGFloat = 8.0
            if component.safeInsets.bottom <= 32.0 && environment.inputHeight == 0.0 {
                sideInset += 18.0
            }
            
            state.cameraState = component.cameraState
            
            var viewOnceOffset: CGFloat = 102.0
            
            var showViewOnce = false
            var showRecordMore = false
            if component.isPreviewing {
                showViewOnce = true
                if component.totalDuration < 59.0 {
                    showRecordMore = true
                    viewOnceOffset = 67.0
                } else {
                    viewOnceOffset = 14.0
                }
            } else if case .handsFree = component.cameraState.recording {
                showViewOnce = true
            }
            
            if let controller = component.getController() {
                if controller.scheduledLock {
                    showViewOnce = true
                }
                if !controller.viewOnceAvailable {
                    showViewOnce = false
                }
            }
            
            if state.didDisplayViewOnce {
                showViewOnce = true
            } else if showViewOnce {
                state.didDisplayViewOnce = true
            }
            
            if !component.isPreviewing {
                if case .on = component.cameraState.flashMode, case .front = component.cameraState.position {
                    let frontFlashPosition = CGPoint(x: component.previewFrame.midX, y: component.previewFrame.midY)
                    let frontFlashSize = CGSize(
                        width: max(abs(frontFlashPosition.x), abs(context.availableSize.width - frontFlashPosition.x)) * 2.0,
                        height: max(abs(frontFlashPosition.y), abs(context.availableSize.height - frontFlashPosition.y)) * 2.0
                    )
                    let frontFlash = frontFlash.update(
                        component: Image(image: state.image(.flashImage, theme: environment.theme), tintColor: component.cameraState.flashTint.color, contentMode: .scaleAspectFill),
                        availableSize: frontFlashSize,
                        transition: .easeInOut(duration: 0.2)
                    )
                    context.add(frontFlash
                        .position(frontFlashPosition)
                        .scale(1.5 - component.cameraState.flashTintSize * 0.5)
                        .appear(.default(alpha: true))
                        .disappear(ComponentTransition.Disappear({ view, transition, completion in
                            view.superview?.sendSubviewToBack(view)
                            transition.setAlpha(view: view, alpha: 0.0, completion: { _ in
                                completion()
                            })
                        }))
                    )
                }
                
                let flipButtonBackground = flipButtonBackground.update(
                    component: GlassBackgroundComponent(
                        size: CGSize(width: 40.0, height: 40.0),
                        cornerRadius: 40.0 * 0.5,
                        isDark: environment.theme.overallDarkAppearance,
                        tintColor: .init(kind: .panel)
                    ),
                    availableSize: CGSize(width: 40.0, height: 40.0),
                    transition: .immediate
                )
                
                let flipButton = flipButton.update(
                    component: CameraButton(
                        content: AnyComponentWithIdentity(
                            id: "flip",
                            component: AnyComponent(
                                Image(
                                    image: state.image(.flip, theme: environment.theme),
                                    tintColor: environment.theme.chat.inputPanel.panelControlColor,
                                    size: CGSize(width: 30.0, height: 30.0)
                                )
                            )
                        ),
                        minSize: CGSize(width: 40.0, height: 40.0),
                        isExclusive: false,
                        action: { [weak state] in
                            if let state {
                                state.togglePosition()
                            }
                        }
                    ),
                    availableSize: availableSize,
                    transition: context.transition
                )
                
                context.add(flipButtonBackground
                    .position(CGPoint(x: flipButton.size.width / 2.0 + sideInset, y: availableSize.height - flipButton.size.height / 2.0 - 8.0))
                    .appear(.default(scale: true, alpha: true))
                    .disappear(.default(scale: true, alpha: true))
                )
                context.add(flipButton
                    .position(CGPoint(x: flipButton.size.width / 2.0 + sideInset, y: availableSize.height - flipButton.size.height / 2.0 - 8.0))
                    .appear(.default(scale: true, alpha: true))
                    .disappear(.default(scale: true, alpha: true))
                )
                
                let flashContentComponent: AnyComponentWithIdentity<Empty>
                if "".isEmpty {
                    let flashIconName: String
                    switch component.cameraState.flashMode {
                    case .off:
                        flashIconName = "roundFlash_off"
                    case .on:
                        flashIconName = "roundFlash_on"
                    default:
                        flashIconName = "roundFlash_off"
                    }
                    
                    flashContentComponent = AnyComponentWithIdentity(
                        id: "animatedIcon",
                        component: AnyComponent(
                            LottieComponent(
                                content: LottieComponent.AppBundleContent(name: flashIconName),
                                color: environment.theme.chat.inputPanel.panelControlColor,
                                startingPosition: !component.cameraState.flashModeDidChange ? .end : .begin,
                                size: CGSize(width: 40.0, height: 40.0),
                                loop: false,
                                playOnce: flashAction
                            )
                        )
                    )
                } else {
                    flashContentComponent = AnyComponentWithIdentity(
                        id: "staticIcon",
                        component: AnyComponent(
                            Image(
                                image: state.image(.flash, theme: environment.theme),
                                tintColor: environment.theme.chat.inputPanel.panelControlColor,
                                size: CGSize(width: 30.0, height: 30.0)
                            )
                        )
                    )
                }
                
                if !environment.metrics.isTablet {
                    let flashButton = flashButton.update(
                        component: CameraButton(
                            content: flashContentComponent,
                            minSize: CGSize(width: 40.0, height: 40.0),
                            isExclusive: false,
                            action: { [weak state] in
                                if let state {
                                    state.toggleFlashMode()
                                    Queue.mainQueue().justDispatch {
                                        flashAction.invoke(Void())
                                    }
                                }
                            }
                        ),
                        availableSize: availableSize,
                        transition: context.transition
                    )
                    
                    let flashButtonBackground = flashButtonBackground.update(
                        component: GlassBackgroundComponent(
                            size: CGSize(width: 40.0, height: 40.0),
                            cornerRadius: 40.0 * 0.5,
                            isDark: environment.theme.overallDarkAppearance,
                            tintColor: .init(kind: .panel)
                        ),
                        availableSize: CGSize(width: 40.0, height: 40.0),
                        transition: .immediate
                    )
                    
                    context.add(flashButtonBackground
                        .position(CGPoint(x: flipButton.size.width + sideInset + flashButton.size.width / 2.0 + 11.0, y: availableSize.height - flashButton.size.height / 2.0 - 8.0))
                        .appear(.default(scale: true, alpha: true))
                        .disappear(.default(scale: true, alpha: true))
                    )
                    
                    context.add(flashButton
                        .position(CGPoint(x: flipButton.size.width + sideInset + flashButton.size.width / 2.0 + 11.0, y: availableSize.height - flashButton.size.height / 2.0 - 8.0))
                        .appear(.default(scale: true, alpha: true))
                        .disappear(.default(scale: true, alpha: true))
                    )
                }
            }
            
            // IAyuGram: the minimize control, third in the bottom-left row after flip and
            // flash. Only while the recording is locked and this chat allows the handover,
            // so it never appears where pressing it would strand a recording.
            if let controller = component.getController(), controller.iAyuMinimizeAvailable {
                let getController = component.getController
                let buttonSide: CGFloat = 40.0
                let minimizeButton = minimizeButton.update(
                    component: PlainButtonComponent(
                        content: AnyComponent(
                            ZStack([
                                AnyComponentWithIdentity(
                                    id: "background",
                                    component: AnyComponent(GlassBackgroundComponent(
                                        size: CGSize(width: buttonSide, height: buttonSide),
                                        cornerRadius: buttonSide * 0.5,
                                        isDark: environment.theme.overallDarkAppearance,
                                        tintColor: .init(kind: .panel)
                                    ))
                                ),
                                AnyComponentWithIdentity(
                                    id: "icon",
                                    component: AnyComponent(
                                        BundleIconComponent(
                                            name: "Media Gallery/Minimize",
                                            tintColor: environment.theme.chat.inputPanel.panelControlColor
                                        )
                                    )
                                )
                            ])
                        ),
                        effectAlignment: .center,
                        action: {
                            getController()?.iAyuRequestMinimize()
                        }
                    ),
                    availableSize: availableSize,
                    transition: context.transition
                )
                context.add(minimizeButton
                    .position(CGPoint(x: sideInset + buttonSide * 2.5 + 22.0, y: availableSize.height - buttonSide / 2.0 - 8.0))
                    .appear(.default(scale: true, alpha: true))
                    .disappear(.default(scale: true, alpha: true))
                )
            }

            if showViewOnce {
                let viewOnceButton = viewOnceButton.update(
                    component: PlainButtonComponent(
                        content: AnyComponent(
                            ZStack([
                                AnyComponentWithIdentity(
                                    id: "background",
                                    component: AnyComponent(
                                        GlassBackgroundComponent(
                                            size: CGSize(width: 40.0, height: 40.0),
                                            cornerRadius: 40.0 * 0.5,
                                            isDark: environment.theme.overallDarkAppearance,
                                            tintColor: .init(kind: .panel)
                                        )
                                    )
                                ),
                                AnyComponentWithIdentity(
                                    id: "icon",
                                    component: AnyComponent(
                                        BundleIconComponent(
                                            name: component.cameraState.isViewOnceEnabled ? "Media Gallery/ViewOnceEnabled" : "Media Gallery/ViewOnce",
                                            tintColor: environment.theme.chat.inputPanel.panelControlColor
                                        )
                                    )
                                )
                            ])
                        ),
                        effectAlignment: .center,
                        action: { [weak state] in
                            if let state {
                                state.toggleViewOnce()
                            }
                        },
                        animateAlpha: false,
                        tag: viewOnceButtonTag
                    ),
                    availableSize: availableSize,
                    transition: context.transition
                )
                context.add(viewOnceButton
                    .position(CGPoint(x: availableSize.width - viewOnceButton.size.width / 2.0 - sideInset, y: availableSize.height - viewOnceButton.size.height / 2.0 - 8.0 - viewOnceOffset))
                    .appear(.default(scale: true, alpha: true))
                    .disappear(.default(scale: true, alpha: true))
                )
            }
            
            if showRecordMore {
                let recordMoreButton = recordMoreButton.update(
                    component: PlainButtonComponent(
                        content: AnyComponent(
                            ZStack([
                                AnyComponentWithIdentity(
                                    id: "background",
                                    component: AnyComponent(GlassBackgroundComponent(
                                        size: CGSize(width: 40.0, height: 40.0),
                                        cornerRadius: 40.0 * 0.5,
                                        isDark: environment.theme.overallDarkAppearance,
                                        tintColor: .init(kind: .panel)
                                    ))
                                ),
                                AnyComponentWithIdentity(
                                    id: "icon",
                                    component: AnyComponent(
                                        BundleIconComponent(
                                            name: "Chat/Input/Text/IconVideo",
                                            tintColor: environment.theme.chat.inputPanel.panelControlColor
                                        )
                                    )
                                )
                            ])
                        ),
                        effectAlignment: .center,
                        action: { [weak state] in
                            state?.startVideoRecording(pressing: false)
                        }
                    ),
                    availableSize: availableSize,
                    transition: context.transition
                )
                context.add(recordMoreButton
                    .position(CGPoint(x: availableSize.width - recordMoreButton.size.width / 2.0 - sideInset, y: availableSize.height - recordMoreButton.size.height / 2.0 - 22.0))
                    .appear(.default(scale: true, alpha: true))
                    .disappear(.default(scale: true, alpha: true))
                )
            }
            
            if component.isPreviewing && component.isMuted {
                let muteIcon = muteIcon.update(
                    component: ZStack([
                        AnyComponentWithIdentity(
                            id: "background",
                            component: AnyComponent(
                                RoundedRectangle(color: UIColor(rgb: 0x000000, alpha: 0.3), cornerRadius: 24.0)
                            )
                        ),
                        AnyComponentWithIdentity(
                            id: "icon",
                            component: AnyComponent(
                                BundleIconComponent(
                                    name: "Chat/Message/InstantVideoMute",
                                    tintColor: .white
                                )
                            )
                        )
                    ]),
                    availableSize: CGSize(width: 24.0, height: 24.0),
                    transition: context.transition
                )
                context.add(muteIcon
                    .position(CGPoint(x: component.previewFrame.midX, y: component.previewFrame.maxY - 24.0))
                    .appear(.default(scale: true, alpha: true))
                    .disappear(.default(scale: true, alpha: true))
                )
            }
            
            return context.availableSize
        }
    }
}

public class VideoMessageCameraScreen: ViewController {
    public enum CaptureResult {
        public struct Video {
            public let videoPath: String
            public let dimensions: PixelDimensions
            public let duration: Double
            public let thumbnail: UIImage
        }
        
        case video(Video)
    }
    
    fileprivate final class Node: ViewControllerTracingNode, ASGestureRecognizerDelegate {
        private weak var controller: VideoMessageCameraScreen?
        private let context: AccountContext
        fileprivate var camera: Camera?
        private let updateState: ActionSlot<CameraState>
        
        fileprivate var liveUploadInterface: LegacyLiveUploadInterface?
        private var currentLiveUploadPath: String?
        fileprivate var currentLiveUploadData: LegacyLiveUploadInterfaceResult?
                
        fileprivate let backgroundView: UIVisualEffectView
        fileprivate let containerView: UIView
        fileprivate let componentHost: ComponentView<ViewControllerComponentContainer.Environment>
        fileprivate let previewContainerView: UIView
        fileprivate let previewContainerContentView: UIView
        private var previewSnapshotView: UIView?
        private var previewBlurView: BlurView
        
        fileprivate var mainPreviewView: CameraSimplePreviewView
        fileprivate var additionalPreviewView: CameraSimplePreviewView
        private var progressView: RecordingProgressView
        private let loadingView: LoadingEffectView
        
        private var resultPreviewView: ResultPreviewView?
        
        private var cameraStateDisposable: Disposable?
                
        private let idleTimerExtensionDisposable = MetaDisposable()
        
        fileprivate var cameraIsActive = true {
            didSet {
                if self.cameraIsActive {
                    self.idleTimerExtensionDisposable.set(self.context.sharedContext.applicationBindings.pushIdleTimerExtension())
                } else {
                    self.idleTimerExtensionDisposable.set(nil)
                }
            }
        }
        
        private var presentationData: PresentationData
        private var validLayout: ContainerViewLayout?
        
        fileprivate var didAppear: () -> Void = {}
        
        fileprivate let startRecording = ActionSlot<Void>()
        fileprivate let stopRecording = ActionSlot<Void>()
        fileprivate let cancelRecording = ActionSlot<Void>()
        private let completion = ActionSlot<VideoMessageCameraScreen.CaptureResult>()
                
        var cameraState: CameraState {
            didSet {
                if self.cameraState.isViewOnceEnabled != oldValue.isViewOnceEnabled {
                    if self.cameraState.isViewOnceEnabled {
                        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
                        self.displayViewOnceTooltip(text: presentationData.strings.Chat_PlayVideoMessageOnceTooltip, hasIcon: true)
                        
                        let _ = ApplicationSpecificNotice.incrementVideoMessagesPlayOnceSuggestion(accountManager: self.context.sharedContext.accountManager, count: 3).startStandalone()
                    } else {
                        self.dismissAllTooltips()
                    }
                }
            }
        }
        var previewState: PreviewState? {
            didSet {
                self.previewStatePromise.set(.single(self.previewState))
                self.resultPreviewView?.isMuted = self.previewState?.isMuted ?? true
            }
        }
        var previewStatePromise = Promise<PreviewState?>()
        
        var transitioningToPreview = false

        // IAyuGram: while the circle lives in the header panel, or is being dragged towards
        // it, the layout must not reposition it — the panel owns its frame then.
        fileprivate var iAyuIsMinimized = false
        private var iAyuIsDraggingMinimize = false
        private weak var iAyuMinimizePanRecognizer: UIPanGestureRecognizer?
        
        init(controller: VideoMessageCameraScreen) {
            self.controller = controller
            self.context = controller.context
            self.updateState = ActionSlot<CameraState>()
            
            self.presentationData = controller.updatedPresentationData?.initial ?? self.context.sharedContext.currentPresentationData.with { $0 }
            
            self.backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: self.presentationData.theme.overallDarkAppearance ? .dark : .light))
            
            self.containerView = UIView()
            
            self.componentHost = ComponentView<ViewControllerComponentContainer.Environment>()
            
            self.previewContainerView = UIView()
            
            self.previewContainerContentView = UIView()
            self.previewContainerContentView.clipsToBounds = true
            self.previewContainerView.addSubview(self.previewContainerContentView)
                        
            let isDualCameraEnabled = Camera.isDualCameraSupported(forRoundVideo: true)
            // MARK: Swiftgram
            let isFrontPosition = !SGSimpleSettings.shared.startTelescopeWithRearCam
            
            self.mainPreviewView = CameraSimplePreviewView(frame: .zero, main: true, roundVideo: true)
            self.additionalPreviewView = CameraSimplePreviewView(frame: .zero, main: false, roundVideo: true)
            
            self.progressView = RecordingProgressView(frame: .zero)
            
            self.loadingView = LoadingEffectView(effectAlpha: 0.1, borderAlpha: 0.25, duration: 1.0)
            
            self.previewBlurView = BlurView()
            self.previewBlurView.isUserInteractionEnabled = false
            
            if isDualCameraEnabled {
                self.mainPreviewView.resetPlaceholder(front: false)
                self.additionalPreviewView.resetPlaceholder(front: true)
            } else {
                self.mainPreviewView.resetPlaceholder(front: isFrontPosition)
            }
            
            self.cameraState = CameraState(
                position: isFrontPosition ? .front : .back,
                flashMode: .off,
                flashModeDidChange: false,
                flashTint: .white,
                flashTintSize: 1.0,
                recording: .none,
                duration: 0.0,
                isDualCameraEnabled: isDualCameraEnabled,
                isViewOnceEnabled: false
            )
            
            self.previewState = nil
            
            super.init()
            
            self.backgroundColor = .clear
            
            self.view.addSubview(self.containerView)
            
            self.containerView.addSubview(self.previewContainerView)

            self.previewContainerContentView.addSubview(self.mainPreviewView)
            if isDualCameraEnabled {
                self.previewContainerContentView.addSubview(self.additionalPreviewView)
            }
            self.previewContainerContentView.addSubview(self.progressView)
            self.previewContainerContentView.addSubview(self.previewBlurView)
            self.previewContainerContentView.addSubview(self.loadingView)
            
            self.completion.connect { [weak self] result in
                if let self {
                    self.addCaptureResult(result)
                }
            }
            if isDualCameraEnabled {
                self.mainPreviewView.removePlaceholder(delay: 0.0)
            }
            self.withReadyCamera(isFirstTime: true, { [weak self] in
                guard let self else {
                    return
                }
                if !isDualCameraEnabled {
                    self.mainPreviewView.removePlaceholder(delay: 0.0)
                }
                self.loadingView.alpha = 0.0
                self.additionalPreviewView.removePlaceholder(delay: 0.0)
            })
                        
            self.idleTimerExtensionDisposable.set(self.context.sharedContext.applicationBindings.pushIdleTimerExtension())
        }
        
        deinit {
            self.cameraStateDisposable?.dispose()
            self.idleTimerExtensionDisposable.dispose()
            self.backgroundView.removeFromSuperview()
        }
        
        func withReadyCamera(isFirstTime: Bool = false, _ f: @escaping () -> Void) {
            let previewReady: Signal<Bool, NoError>
            if #available(iOS 13.0, *) {
                previewReady = self.cameraState.isDualCameraEnabled ? self.additionalPreviewView.isPreviewing : self.mainPreviewView.isPreviewing |> delay(0.3, queue: Queue.mainQueue())
            } else {
                previewReady = .single(true) |> delay(0.35, queue: Queue.mainQueue())
            }
            
            let _ = (previewReady
            |> filter { $0 }
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { _ in
                f()
            })
        }
        
        func setupLiveUpload(filePath: String) {
            guard let controller = self.controller, controller.allowLiveUpload, self.liveUploadInterface == nil else {
                return
            }
            let liveUploadInterface = LegacyLiveUploadInterface(context: self.context)
            Queue.mainQueue().after(1.5, {
                liveUploadInterface.setup(withFileURL: URL(fileURLWithPath: filePath))
            })
            self.liveUploadInterface = liveUploadInterface
        }
        
        override func didLoad() {
            super.didLoad()
            
            self.view.disablesInteractiveModalDismiss = true
            self.view.disablesInteractiveKeyboardGestureRecognizer = true
            
            let pinchGestureRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(self.handlePinch(_:)))
            self.view.addGestureRecognizer(pinchGestureRecognizer)

            // IAyuGram: drag the circle down to leave the chat with the recording.
            //
            // On the node's own view, NOT on the circle: the component host — the whole
            // button layer — is a sibling stacked above the circle and covers it, so a
            // recognizer attached to the circle never sees the touch. An ancestor does. The
            // gesture is then narrowed back down to touches that start inside the circle
            // and head downward, in gestureRecognizerShouldBegin.
            let minimizePanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.iAyuHandleMinimizePan(_:)))
            minimizePanRecognizer.delegate = self.wrappedGestureRecognizerDelegate
            self.view.addGestureRecognizer(minimizePanRecognizer)
            self.iAyuMinimizePanRecognizer = minimizePanRecognizer
        }

        // MARK: IAyuGram — leaving with the recording

        fileprivate func iAyuPrepareForMinimize() {
            self.iAyuIsMinimized = true
            self.iAyuIsDraggingMinimize = false
            self.iAyuMinimizePanRecognizer?.isEnabled = false
            self.previewContainerView.transform = .identity
            self.backgroundView.removeFromSuperview()
            self.previewContainerView.removeFromSuperview()
        }

        fileprivate func iAyuRestoreAfterMinimize() {
            self.iAyuIsMinimized = false
            self.iAyuMinimizePanRecognizer?.isEnabled = true
            self.previewContainerView.transform = .identity
            // Below the component host, which is where it started: the buttons draw over
            // the circle, not under it.
            self.containerView.insertSubview(self.previewContainerView, at: 0)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === self.iAyuMinimizePanRecognizer else {
                return super.gestureRecognizerShouldBegin(gestureRecognizer)
            }
            guard let controller = self.controller, controller.iAyuMinimizeAvailable else {
                return false
            }
            let location = gestureRecognizer.location(in: self.view)
            guard self.previewContainerView.frame.contains(self.containerView.convert(location, from: self.view)) else {
                return false
            }
            guard let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }
            // Downward only, decided at the first movement — otherwise this would claim
            // every horizontal drag over the circle as well.
            let velocity = panRecognizer.velocity(in: self.view)
            return velocity.y > 0.0 && abs(velocity.y) > abs(velocity.x)
        }

        @objc private func iAyuHandleMinimizePan(_ recognizer: UIPanGestureRecognizer) {
            guard let controller = self.controller, controller.iAyuMinimizeAvailable else {
                return
            }
            let translation = recognizer.translation(in: self.view)
            let isDownward = translation.y > 0.0 && abs(translation.y) > abs(translation.x)

            switch recognizer.state {
            case .changed:
                guard isDownward else {
                    return
                }
                self.iAyuIsDraggingMinimize = true
                self.previewContainerView.transform = CGAffineTransform(translationX: 0.0, y: min(translation.y, 140.0))
            case .ended, .cancelled, .failed:
                guard self.iAyuIsDraggingMinimize else {
                    return
                }
                let velocity = recognizer.velocity(in: self.view)
                if isDownward && (translation.y > 60.0 || velocity.y > 500.0) {
                    self.previewContainerView.transform = .identity
                    self.iAyuIsDraggingMinimize = false
                    controller.iAyuRequestMinimize()
                } else {
                    UIView.animate(withDuration: 0.3, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.0, animations: {
                        self.previewContainerView.transform = .identity
                    }, completion: { [weak self] _ in
                        self?.iAyuIsDraggingMinimize = false
                    })
                }
            default:
                break
            }
        }

        fileprivate var iAyuHoldsPreviewFrame: Bool {
            return self.iAyuIsMinimized || self.iAyuIsDraggingMinimize
        }
                
        fileprivate func setupCamera() {
            guard self.camera == nil else {
                return
            }
            
            let camera = Camera(
                configuration: Camera.Configuration(
                    preset: .hd1920x1080,
                    position: self.cameraState.position,
                    isDualEnabled: self.cameraState.isDualCameraEnabled,
                    audio: true,
                    photo: false,
                    metadata: false,
                    isRoundVideo: true
                ),
                previewView: self.mainPreviewView,
                secondaryPreviewView: self.additionalPreviewView
            )
            
            self.cameraStateDisposable = combineLatest(
                queue: Queue.mainQueue(),
                camera.flashMode,
                camera.position
            ).startStrict(next: { [weak self] flashMode, position in
                guard let self else {
                    return
                }
                self.cameraState = self.cameraState.updatedPosition(position).updatedFlashMode(flashMode)
                
                if !self.cameraState.isDualCameraEnabled {
                    self.animatePositionChange()
                }
                
                self.requestUpdateLayout(transition: .easeInOut(duration: 0.2))
            })
            
            camera.focus(at: CGPoint(x: 0.5, y: 0.5), autoFocus: true)
            camera.startCapture()
            
            self.camera = camera
            
            Queue.mainQueue().justDispatch {
                self.startRecording.invoke(Void())
            }
        }
        
        @objc private func handlePinch(_ gestureRecognizer: UIPinchGestureRecognizer) {
            guard let camera = self.camera else {
                return
            }
            switch gestureRecognizer.state {
            case .changed:
                let scale = gestureRecognizer.scale
                camera.setZoomDelta(scale)
                gestureRecognizer.scale = 1.0
            case .ended, .cancelled:
                camera.rampZoom(1.0, rate: 8.0)
            default:
                break
            }
        }
                
        private var animatingIn = false
        func animateIn() {
            self.animatingIn = true
            
            self.backgroundView.alpha = 0.0
            UIView.animate(withDuration: 0.4, animations: {
                self.backgroundView.alpha = 1.0
            })
            
            let targetPosition = self.previewContainerView.center
            self.previewContainerView.center = CGPoint(x: targetPosition.x, y: self.frame.height + self.previewContainerView.frame.height / 2.0)
            
            UIView.animate(withDuration: 0.5, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.2, animations: {
                self.previewContainerView.center = targetPosition
            }, completion: { [weak self] _ in
                self?.animatingIn = false
            })
            
            if let view = self.componentHost.view {
                view.layer.animateAlpha(from: 0.1, to: 1.0, duration: 0.25)
            }
        }

        func animateOut(completion: @escaping () -> Void) {
            self.camera?.stopCapture(invalidate: true)
                                    
            UIView.animate(withDuration: 0.25, animations: {
                self.backgroundView.alpha = 0.0
            }, completion: { [weak self] _ in
                self?.backgroundView.removeFromSuperview()
                completion()
            })
            
            self.componentHost.view?.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
            self.previewContainerView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25, removeOnCompletion: false)
        }
        
        private func animatePositionChange() {
            if let snapshotView = self.mainPreviewView.snapshotView(afterScreenUpdates: false) {
                self.previewContainerContentView.insertSubview(snapshotView, belowSubview: self.progressView)
                self.previewSnapshotView = snapshotView
                
                let action = { [weak self] in
                    guard let self else {
                        return
                    }
                    UIView.animate(withDuration: 0.2, animations: {
                        self.previewSnapshotView?.alpha = 0.0
                    }, completion: { [weak self] _ in
                        self?.previewSnapshotView?.removeFromSuperview()
                        self?.previewSnapshotView = nil
                    })
                }
                
                Queue.mainQueue().after(1.0) {
                    action()
                }
                
                self.requestUpdateLayout(transition: .immediate)
            }
        }
        
        func pauseCameraCapture() {
            self.mainPreviewView.isEnabled = false
            self.additionalPreviewView.isEnabled = false
            self.camera?.stopCapture()
            
            self.cameraIsActive = false
            self.requestUpdateLayout(transition: .immediate)
        }
        
        func resumeCameraCapture() {
            if !self.mainPreviewView.isEnabled {
                if let snapshotView = self.resultPreviewView?.snapshotView(afterScreenUpdates: false) {
                    self.previewContainerContentView.insertSubview(snapshotView, belowSubview: self.previewBlurView)
                    self.previewSnapshotView = snapshotView
                }
                self.mainPreviewView.isEnabled = true
                self.additionalPreviewView.isEnabled = true
                self.camera?.startCapture()
                
                UIView.animate(withDuration: 0.25, animations: {
                    self.loadingView.alpha = 1.0
                    self.previewBlurView.effect = UIBlurEffect(style: .dark)
                })
                
                let action = { [weak self] in
                    guard let self else {
                        return
                    }
                    UIView.animate(withDuration: 0.4, animations: {
                        self.previewBlurView.effect = nil
                        self.previewSnapshotView?.alpha = 0.0
                    }, completion: { [weak self] _ in
                        self?.previewSnapshotView?.removeFromSuperview()
                        self?.previewSnapshotView = nil
                    })
                }
                let _ = (self.mainPreviewView.isPreviewing
                |> filter { $0 }
                |> take(1)).startStandalone(next: { _ in
                    action()
                })
                
                self.cameraIsActive = true
                self.requestUpdateLayout(transition: .immediate)
            }
        }
        
        fileprivate var results: [VideoMessageCameraScreen.CaptureResult] = []
        fileprivate var resultsPipe = ValuePipe<VideoMessageCameraScreen.CaptureResult>()
        
        func addCaptureResult(_ result: VideoMessageCameraScreen.CaptureResult) {
            guard let controller = self.controller else {
                return
            }
            
            if self.results.isEmpty {
                if let liveUploadData = self.liveUploadInterface?.fileUpdated(true) as? LegacyLiveUploadInterfaceResult {
                    self.currentLiveUploadData = liveUploadData
                }
            } else {
                self.currentLiveUploadData = nil
            }
            
            let _ = ApplicationSpecificNotice.incrementVideoMessagesPauseSuggestion(accountManager: self.context.sharedContext.accountManager, count: 3).startStandalone()
            
            self.pauseCameraCapture()
            
            self.results.append(result)
            self.resultsPipe.putNext(result)
            
            self.transitioningToPreview = false
            
            if !controller.isSendingImmediately {
                let composition = composition(with: self.results)
                controller.updatePreviewState({ _ in
                    return PreviewState(composition: composition, trimRange: nil, isMuted: true)
                }, transition: .spring(duration: 0.4))
            }
        }
        
        private func debugSaveResult(path: String) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
                return
            }
            let id = Int64.random(in: Int64.min ... Int64.max)
            let fileResource = LocalFileReferenceMediaResource(localFilePath: path, randomId: id)
            
            let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: fileResource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "video/mp4", size: Int64(data.count), attributes: [.FileName(fileName: "video.mp4")], alternativeRepresentations: [])
            let message: EnqueueMessage = .message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])

            let _ = enqueueMessages(account: self.context.engine.account, peerId: self.context.engine.account.peerId, messages: [message]).startStandalone()
        }
        
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let result = super.hitTest(point, with: event)
            
            if let resultPreviewView = self.resultPreviewView {
                if resultPreviewView.bounds.contains(self.view.convert(point, to: resultPreviewView)) {
                    return resultPreviewView
                }
            }
            
            if let controller = self.controller, let layout = self.validLayout {
                let insets = layout.insets(options: .input)
                if point.y > layout.size.height - max(insets.bottom, layout.additionalInsets.bottom) - controller.inputPanelFrame.0.height {
                    if layout.metrics.isTablet {
                        if point.x < layout.size.width * 0.33 {
                            return result
                        }
                    }
                    return nil
                }
            }
            
            return result
        }
        
        fileprivate func maybePresentTooltips() {
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            
            let _ = (ApplicationSpecificNotice.getVideoMessagesPauseSuggestion(accountManager: self.context.sharedContext.accountManager)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] pauseCounter in
                guard let self else {
                    return
                }
                
                if pauseCounter >= 3 {
                    let _ = (ApplicationSpecificNotice.getVideoMessagesPlayOnceSuggestion(accountManager: self.context.sharedContext.accountManager)
                    |> deliverOnMainQueue).startStandalone(next: { [weak self] counter in
                        guard let self else {
                            return
                        }
                        if counter >= 3 {
                            return
                        }
                        Queue.mainQueue().after(0.3) {
                            self.displayViewOnceTooltip(text: presentationData.strings.Chat_TapToPlayVideoMessageOnceTooltip, hasIcon: true)
                        }
                        let _ = ApplicationSpecificNotice.incrementVideoMessagesPlayOnceSuggestion(accountManager: self.context.sharedContext.accountManager).startStandalone()
                    })
                } else {
                    Queue.mainQueue().after(0.3) {
                        self.displayPauseTooltip(text: presentationData.strings.Chat_PauseVideoMessageTooltip)
                    }
                    let _ = ApplicationSpecificNotice.incrementVideoMessagesPauseSuggestion(accountManager: self.context.sharedContext.accountManager).startStandalone()
                }
            })
        }
        
        private func displayViewOnceTooltip(text: String, hasIcon: Bool) {
            guard let controller = self.controller, let sourceView = self.componentHost.findTaggedView(tag: viewOnceButtonTag) else {
                return
            }
            
            self.dismissAllTooltips()
            
            let absoluteFrame = sourceView.convert(sourceView.bounds, to: self.view)
            let location = CGRect(origin: CGPoint(x: absoluteFrame.midX - 20.0, y: absoluteFrame.midY), size: CGSize())
            
            let tooltipController = TooltipScreen(
                account: context.account,
                sharedContext: context.sharedContext,
                text: .markdown(text: text),
                balancedTextLayout: true,
                constrainWidth: 240.0,
                style: .customBlur(UIColor(rgb: 0x18181a), 0.0),
                arrowStyle: .small,
                icon: hasIcon ? .animation(name: "anim_autoremove_on", delay: 0.1, tintColor: nil) : nil,
                location: .point(location, .right),
                displayDuration: .default,
                inset: 8.0,
                cornerRadius: 8.0,
                shouldDismissOnTouch: { _, _ in
                    return .ignore
                }
            )
            controller.present(tooltipController, in: .window(.root))
        }
        
        private func displayPauseTooltip(text: String) {
            guard let controller = self.controller, let sourceView = self.componentHost.findTaggedView(tag: viewOnceButtonTag) else {
                return
            }
            
            self.dismissAllTooltips()
            
            let absoluteFrame = sourceView.convert(sourceView.bounds, to: self.view)
            let location = CGRect(origin: CGPoint(x: absoluteFrame.midX - 20.0, y: absoluteFrame.midY + 53.0), size: CGSize())
            
            let tooltipController = TooltipScreen(
                account: context.account,
                sharedContext: context.sharedContext,
                text: .markdown(text: text),
                balancedTextLayout: true,
                constrainWidth: 240.0,
                style: .customBlur(UIColor(rgb: 0x18181a), 0.0),
                arrowStyle: .small,
                icon: nil,
                location: .point(location, .right),
                displayDuration: .default,
                inset: 8.0,
                cornerRadius: 8.0,
                shouldDismissOnTouch: { _, _ in
                    return .ignore
                }
            )
            controller.present(tooltipController, in: .window(.root))
        }

        fileprivate func dismissAllTooltips() {
            guard let controller = self.controller else {
                return
            }
            controller.window?.forEachController({ controller in
                if let controller = controller as? TooltipScreen {
                    controller.dismiss()
                }
            })
            controller.forEachController({ controller in
                if let controller = controller as? TooltipScreen {
                    controller.dismiss()
                }
                return true
            })
        }
        
        func updateTrimRange(start: Double, end: Double, updatedEnd: Bool, apply: Bool) {
            guard let controller = self.controller else {
                return
            }
            self.resultPreviewView?.updateTrimRange(start: start, end: end, updatedEnd: updatedEnd, apply: apply)
            controller.updatePreviewState({ state in
                if let state {
                    return PreviewState(composition: state.composition, trimRange: start..<end, isMuted: state.isMuted)
                } else {
                    return nil
                }
            }, transition: .immediate)
        }
        
        @objc func resultTapped() {
            guard let controller = self.controller else {
                return
            }
            controller.updatePreviewState({ state in
                if let state {
                    return PreviewState(composition: state.composition, trimRange: state.trimRange, isMuted: !state.isMuted)
                } else {
                    return nil
                }
            }, transition: .easeInOut(duration: 0.2))
        }
        
        func requestUpdateLayout(transition: ComponentTransition) {
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout: layout, forceUpdate: true, transition: transition)
            }
        }

        func containerLayoutUpdated(layout: ContainerViewLayout, forceUpdate: Bool = false, transition: ComponentTransition) {
            guard let controller = self.controller else {
                return
            }
            let isFirstTime = self.validLayout == nil
            self.validLayout = layout
            
            let environment = ViewControllerComponentContainer.Environment(
                statusBarHeight: layout.statusBarHeight ?? 0.0,
                navigationHeight: 0.0,
                safeInsets: UIEdgeInsets(
                    top: (layout.statusBarHeight ?? 0.0) + 5.0,
                    left: layout.safeInsets.left,
                    bottom: 44.0,
                    right: layout.safeInsets.right
                ),
                additionalInsets: layout.additionalInsets,
                inputHeight: layout.inputHeight ?? 0.0,
                metrics: layout.metrics,
                deviceMetrics: layout.deviceMetrics,
                orientation: nil,
                isVisible: true,
                theme: self.presentationData.theme,
                strings: self.presentationData.strings,
                dateTimeFormat: self.presentationData.dateTimeFormat,
                controller: { [weak self] in
                    return self?.controller
                }
            )

            if isFirstTime {
                self.didAppear()
            }

            var backgroundFrame = CGRect(origin: .zero, size: CGSize(width: layout.size.width, height: controller.inputPanelFrame.0.minY))
            let actualBackgroundFrame = CGRect(origin: .zero, size: CGSize(width: layout.size.width, height: layout.size.height))
            if backgroundFrame.maxY < layout.size.height - 100.0 && (layout.inputHeight ?? 0.0).isZero && !controller.inputPanelFrame.1 && layout.additionalInsets.bottom.isZero {
                backgroundFrame = CGRect(origin: .zero, size: CGSize(width: layout.size.width, height: layout.size.height - layout.intrinsicInsets.bottom - controller.inputPanelFrame.0.height - 8.0))
            }
                        
            transition.setPosition(view: self.backgroundView, position: actualBackgroundFrame.center)
            transition.setBounds(view: self.backgroundView, bounds: CGRect(origin: .zero, size: actualBackgroundFrame.size))
            
            transition.setPosition(view: self.containerView, position: backgroundFrame.center)
            transition.setBounds(view: self.containerView, bounds: CGRect(origin: .zero, size: backgroundFrame.size))
                        
            let availableHeight = layout.size.height - (layout.inputHeight ?? 0.0)
            let previewSide = min(369.0, layout.size.width - 24.0)
            let previewFrame: CGRect
            if layout.metrics.isTablet {
                let statusBarOrientation: UIInterfaceOrientation
                if #available(iOS 13.0, *) {
                    statusBarOrientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation ?? .portrait
                } else {
                    statusBarOrientation = UIApplication.shared.statusBarOrientation
                }
                
                if statusBarOrientation == .landscapeLeft {
                    previewFrame = CGRect(origin: CGPoint(x: layout.size.width - 44.0 - previewSide, y: floorToScreenPixels((layout.size.height - previewSide) / 2.0)), size: CGSize(width: previewSide, height: previewSide))
                } else if statusBarOrientation == .landscapeRight {
                    previewFrame = CGRect(origin: CGPoint(x: 44.0, y: floorToScreenPixels((layout.size.height - previewSide) / 2.0)), size: CGSize(width: previewSide, height: previewSide))
                } else {
                    previewFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((layout.size.width - previewSide) / 2.0), y: max(layout.statusBarHeight ?? 0.0 + 24.0, availableHeight * 0.2 - previewSide / 2.0)), size: CGSize(width: previewSide, height: previewSide))
                }
            } else {
                previewFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((layout.size.width - previewSide) / 2.0), y: max(layout.statusBarHeight ?? 0.0 + 24.0, availableHeight * 0.4 - previewSide / 2.0)), size: CGSize(width: previewSide, height: previewSide))
            }
            if !self.animatingIn {
                // IAyuGram: the inner content keeps its full-size layout even while the
                // circle sits in the header panel — the panel scales the whole thing down —
                // but its position there is not ours to set.
                if !self.iAyuHoldsPreviewFrame {
                    transition.setFrame(view: self.previewContainerView, frame: previewFrame)
                }
                transition.setFrame(view: self.previewContainerContentView, frame: CGRect(origin: CGPoint(), size: previewFrame.size))
            }
            transition.setCornerRadius(layer: self.previewContainerContentView.layer, cornerRadius: previewSide / 2.0)
                        
            let previewBounds = CGRect(origin: .zero, size: previewFrame.size)
           
            let previewInnerSize: CGSize
            let additionalPreviewInnerSize: CGSize
            
            if self.cameraState.isDualCameraEnabled {
                previewInnerSize = CGSize(width: previewFrame.size.width, height: previewFrame.size.width / 9.0 * 16.0)
                additionalPreviewInnerSize = CGSize(width: previewFrame.size.width, height: previewFrame.size.width / 3.0 * 4.0)
            } else {
                previewInnerSize = CGSize(width: previewFrame.size.width, height: previewFrame.size.width / 3.0 * 4.0)
                additionalPreviewInnerSize = CGSize(width: previewFrame.size.width, height: previewFrame.size.width / 3.0 * 4.0)
            }
            
            let previewInnerFrame = CGRect(origin: CGPoint(x: 0.0, y: floorToScreenPixels((previewFrame.height - previewInnerSize.height) / 2.0)), size: previewInnerSize)
            
            let additionalPreviewInnerFrame = CGRect(origin: CGPoint(x: 0.0, y: floorToScreenPixels((previewFrame.height - additionalPreviewInnerSize.height) / 2.0)), size: additionalPreviewInnerSize)
            if self.cameraState.isDualCameraEnabled {
                self.mainPreviewView.frame = previewInnerFrame
                self.additionalPreviewView.frame = additionalPreviewInnerFrame
            } else {
                self.mainPreviewView.frame = self.cameraState.position == .front ? additionalPreviewInnerFrame : previewInnerFrame
            }
            
            self.progressView.frame = previewBounds
            self.progressView.value = CGFloat(self.cameraState.duration / 60.0)
            
            transition.setAlpha(view: self.additionalPreviewView, alpha: self.cameraState.position == .front ? 1.0 : 0.0)
            
            self.previewBlurView.frame = previewBounds
            self.previewSnapshotView?.center = previewBounds.center
            self.loadingView.update(size: previewBounds.size, transition: .immediate)
            
            let componentSize = self.componentHost.update(
                transition: transition,
                component: AnyComponent(
                    VideoMessageCameraScreenComponent(
                        context: self.context,
                        cameraState: self.cameraState,
                        containerSize: backgroundFrame.size,
                        previewFrame: previewFrame,
                        safeInsets: layout.safeInsets,
                        isPreviewing: self.previewState != nil || self.transitioningToPreview,
                        isMuted: self.previewState?.isMuted ?? true,
                        totalDuration: self.previewState?.composition.duration.seconds ?? 0.0,
                        getController: { [weak self] in
                            return self?.controller
                        },
                        present: { [weak self] c in
                            self?.controller?.present(c, in: .window(.root))
                        },
                        push: { [weak self] c in
                            self?.controller?.push(c)
                        },
                        startRecording: self.startRecording,
                        stopRecording: self.stopRecording,
                        cancelRecording: self.cancelRecording,
                        completion: self.completion
                    )
                ),
                environment: {
                    environment
                },
                forceUpdate: forceUpdate,
                containerSize: actualBackgroundFrame.size
            )
            if let componentView = self.componentHost.view {
                if componentView.superview == nil {
                    self.containerView.addSubview(componentView)
                }
            
                let componentFrame = CGRect(origin: .zero, size: componentSize)
                transition.setFrame(view: componentView, frame: componentFrame)
            }
            
            if let previewState = self.previewState {
                if previewState.composition !== self.resultPreviewView?.composition {
                    self.resultPreviewView?.removeFromSuperview()
                    self.resultPreviewView = nil
                }
                
                let resultPreviewView: ResultPreviewView
                if let current = self.resultPreviewView {
                    resultPreviewView = current
                } else {
                    resultPreviewView = ResultPreviewView(composition: previewState.composition)
                    resultPreviewView.onLoop = { [weak self] in
                        if let self, let controller = self.controller {
                            controller.updatePreviewState({ state in
                                if let state {
                                    return PreviewState(composition: state.composition, trimRange: state.trimRange, isMuted: true)
                                }
                                return nil
                            }, transition: .easeInOut(duration: 0.2))
                        }
                    }
                    self.previewContainerContentView.addSubview(resultPreviewView)
                    
                    self.resultPreviewView = resultPreviewView
                    resultPreviewView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                    
                    resultPreviewView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.resultTapped)))
                }
                resultPreviewView.frame = previewBounds
            } else if let resultPreviewView = self.resultPreviewView {
                self.resultPreviewView = nil
                resultPreviewView.removeFromSuperview()
            }
            
            if isFirstTime {
                self.animateIn()
            }
        }
    }

    fileprivate var node: Node {
        return self.displayNode as! Node
    }

    private let context: AccountContext
    private let updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)?
    private let inputPanelFrame: (CGRect, Bool)
    fileprivate var allowLiveUpload: Bool
    fileprivate var viewOnceAvailable: Bool
    
    // IAyuGram: a var, not a let. A minimized recording has no chat controller left to
    // answer to, so the global manager puts its own handler here.
    public var completion: (EnqueueMessage?, Bool?, Int32?, Int32?) -> Void
    
    private var audioSessionDisposable: Disposable?
    
    private let hapticFeedback = HapticFeedback()
    
    private var validLayout: ContainerViewLayout?
    
    public var camera: Camera? {
        return self.node.camera
    }
    
    fileprivate var cameraState: CameraState {
        return self.node.cameraState
    }
    
    fileprivate func updateCameraState(_ f: (CameraState) -> CameraState, transition: ComponentTransition) {
        self.node.cameraState = f(self.node.cameraState)
        self.node.requestUpdateLayout(transition: transition)
        self.durationValue.set(self.cameraState.duration)
    }
    
    fileprivate func updatePreviewState(_ f: (PreviewState?) -> PreviewState?, transition: ComponentTransition) {
        self.node.previewState = f(self.node.previewState)
        self.node.requestUpdateLayout(transition: transition)
    }
    
    public final class RecordingStatus {
        public let micLevel: Signal<Float, NoError>
        public let duration: Signal<TimeInterval, NoError>
        
        public init(micLevel: Signal<Float, NoError>, duration: Signal<TimeInterval, NoError>) {
            self.micLevel = micLevel
            self.duration = duration
        }
    }
    
    private let micLevelValue = ValuePromise<Float>(0.0)
    private let durationValue = ValuePromise<TimeInterval>(0.0)
    public let recordingStatus: RecordingStatus

    public var onStop: () -> Void = {
    }

    public var onResume: () -> Void = {
    }

    // IAyuGram: a finished chunk of a long round video, to be sent on its own while the
    // recorder stays up. Separate from `completion`, which tears the camera down.
    public var onChunk: (EnqueueMessage) -> Void = { _ in
    }

    // Asked at each cap: is sending a message right now acceptable in this chat? Slowmode,
    // paid messages and the scheduled-messages view all say no.
    public var iAyuCanSendChunk: () -> Bool = {
        return true
    }

    fileprivate var iAyuChunksSent = 0
    fileprivate var iAyuIsFlushingChunk = false
    // Whether the next chunk resumes as a held button rather than hands-free.
    fileprivate var iAyuChunkResumePressing = false
    // A stop or send that arrived while a chunk was being closed, deferred until the next
    // chunk is recording so it never runs against a camera that is mid-restart.
    fileprivate var iAyuPendingFlushAction: (() -> Void)?

    fileprivate var iAyuShouldFlushChunk: Bool {
        guard SGSimpleSettings.shared.iaInfiniteRoundVideos else {
            return false
        }
        guard !self.iAyuIsFlushingChunk, !self.didSend else {
            return false
        }
        // A view-once round video cut into a series of separately expiring messages is not
        // what "view once" means, so the cap goes back to being a hard stop.
        guard !self.cameraState.isViewOnceEnabled else {
            return false
        }
        guard self.iAyuChunksSent < SGSimpleSettings.iaInfiniteRoundVideoMaxChunks else {
            return false
        }
        return self.iAyuCanSendChunk()
    }

    // MARK: IAyuGram — recording a round video outside the chat it started in.
    //
    // Unlike a voice recording, this screen cannot simply be left behind: it covers the
    // whole chat, so no back gesture can even begin while it is up. Leaving is therefore an
    // explicit act — the minimize button, or a swipe down on the circle — and what it does
    // is take this controller off the window while the capture session keeps running. The
    // preview circle is handed to the header panel, which is the only pult from then on.

    /// Asked before the minimize control is offered at all: the chat says whether this
    /// recording is one that may leave (see `iAyuCanHandOffVideoRecording`).
    public var iAyuCanMinimize: () -> Bool = { return false }
    /// Actually leave. The chat performs the handover — only it can clear its own recorder
    /// state — so this is a request, not the act.
    public var iAyuOnMinimize: () -> Void = {}

    public private(set) var iAyuIsMinimized = false
    fileprivate var iAyuDidFinishTake = false

    /// Locked recordings only, for the same reason as voice: an unlocked one is a finger
    /// held on a button, and letting go sends it.
    public var iAyuMinimizeAvailable: Bool {
        guard !self.didSend, !self.iAyuIsMinimized else {
            return false
        }
        guard case .handsFree = self.cameraState.recording else {
            return false
        }
        return self.iAyuCanMinimize()
    }

    fileprivate func iAyuRequestMinimize() {
        guard self.iAyuMinimizeAvailable else {
            return
        }
        self.hapticFeedback.impact(.light)
        self.iAyuOnMinimize()
    }

    /// Take the screen off the window and give up the preview circle, WITHOUT stopping the
    /// camera — `requestDismiss` is the path that stops it, and this deliberately is not
    /// that path. The caller must already hold this controller (the manager does) or it
    /// deallocates the moment the presentation context lets go.
    public func iAyuDetachForMinimize() -> UIView {
        self.iAyuIsMinimized = true
        self.node.iAyuPrepareForMinimize()
        self.dismiss(animated: false)
        return self.node.previewContainerView
    }

    /// Put the circle back where the layout expects it. The chat re-presents the screen
    /// straight after, which lays everything else out again.
    public func iAyuPrepareForRestore() {
        self.iAyuIsMinimized = false
        self.node.iAyuRestoreAfterMinimize()
    }

    fileprivate func iAyuSendChunk(video: VideoMessageCameraScreen.CaptureResult.Video) {
        self.iAyuChunksSent += 1

        // Finalize this chunk's live upload and disarm the interface, so the recording that
        // starts next re-arms it against its own file. Carrying it over would attach this
        // chunk's uploaded bytes to the next chunk's message.
        let liveUploadData = self.node.liveUploadInterface?.fileUpdated(true) as? LegacyLiveUploadInterfaceResult
        self.node.liveUploadInterface = nil
        self.node.currentLiveUploadData = nil

        self.buildMessage(results: [.video(video)], liveUploadData: liveUploadData, messageEffect: nil, completion: { [weak self] message in
            guard let self, let message else {
                return
            }
            self.onChunk(message)
        })
    }

    public var backgroundView: UIVisualEffectView {
        return self.node.backgroundView
    }
    
    public struct RecordedVideoData {
        public let duration: Double
        public let frames: [UIImage]
        public let framesUpdateTimestamp: Double
        public let trimRange: Range<Double>?
    }
    
    private var currentResults: Signal<[VideoMessageCameraScreen.CaptureResult], NoError> {
        var results: Signal<[VideoMessageCameraScreen.CaptureResult], NoError> = .single(self.node.results)
        if self.waitingForNextResult {
            results = results
            |> mapToSignal { initial in
                return self.node.resultsPipe.signal()
                |> take(1)
                |> map { next in
                    var updatedResults = initial
                    updatedResults.append(next)
                    return updatedResults
                }
            }
        }
        self.waitingForNextResult = false
        return results
    }
        
    public func takenRecordedData() -> Signal<RecordedVideoData?, NoError> {
        let previewState = self.node.previewStatePromise.get()
        let count = 13
        
        let initialPlaceholder: Signal<UIImage?, NoError>
        if let firstResult = self.node.results.first {
            if case let .video(video) = firstResult {
                initialPlaceholder = .single(video.thumbnail)
            } else {
                initialPlaceholder = .single(nil)
            }
        } else {
            initialPlaceholder = self.camera?.transitionImage ?? .single(nil)
        }
        
        var approximateDuration: Double
        if let recordingStartTime = self.recordingStartTime {
            approximateDuration = CACurrentMediaTime() - recordingStartTime
        } else {
            approximateDuration = 1.0
        }
        
        let immediateResult: Signal<RecordedVideoData?, NoError> = initialPlaceholder
        |> take(1)
        |> mapToSignal { initialPlaceholder in
            return videoFrames(asset: nil, count: count, initialPlaceholder: initialPlaceholder)
            |> map { framesAndUpdateTimestamp in
                return RecordedVideoData(
                    duration: approximateDuration,
                    frames: framesAndUpdateTimestamp.0,
                    framesUpdateTimestamp: framesAndUpdateTimestamp.1,
                    trimRange: nil
                )
            }
        }
        
        return immediateResult
        |> mapToSignal { immediateResult in
            return .single(immediateResult)
            |> then(
                self.currentResults
                |> take(1)
                |> mapToSignal { results in
                    var totalDuration: Double = 0.0
                    for result in results {
                        if case let .video(video) = result {
                            totalDuration += video.duration
                        }
                    }
                    let composition = composition(with: results)
                    return combineLatest(
                        queue: Queue.mainQueue(),
                        videoFrames(asset: composition, count: count, initialTimestamp: immediateResult?.framesUpdateTimestamp),
                        previewState
                    )
                    |> map { framesAndUpdateTimestamp, previewState in
                        return RecordedVideoData(
                            duration: totalDuration,
                            frames: framesAndUpdateTimestamp.0,
                            framesUpdateTimestamp: framesAndUpdateTimestamp.1,
                            trimRange: previewState?.trimRange
                        )
                    }
                }
            )
        }
    }
    
    fileprivate weak var chatNode: ASDisplayNode?
    
    public init(
        context: AccountContext,
        updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)?,
        allowLiveUpload: Bool,
        viewOnceAvailable: Bool,
        inputPanelFrame: (CGRect, Bool),
        chatNode: ASDisplayNode?,
        completion: @escaping (EnqueueMessage?, Bool?, Int32?, Int32?) -> Void
    ) {
        self.context = context
        self.updatedPresentationData = updatedPresentationData
        self.allowLiveUpload = allowLiveUpload
        self.viewOnceAvailable = viewOnceAvailable
        self.inputPanelFrame = inputPanelFrame
        self.chatNode = chatNode
        self.completion = completion
        
        self.recordingStatus = RecordingStatus(micLevel: self.micLevelValue.get(), duration: self.durationValue.get())

        super.init(navigationBarPresentationData: nil)

        self.statusBar.statusBarStyle = .Ignore
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        
        self.navigationPresentation = .flatModal
        
        self.requestAudioSession()
    }

    required public init(coder: NSCoder) {
        preconditionFailure()
    }
    
    deinit {
        self.audioSessionDisposable?.dispose()
    }

    override public func loadDisplayNode() {
        self.displayNode = Node(controller: self)

        super.displayNodeDidLoad()
    }
        
    fileprivate var didSend = false
    fileprivate var lastActionTimestamp: Double?
    fileprivate var isSendingImmediately = false
    public func sendVideoRecording(silentPosting: Bool? = nil, scheduleTime: Int32? = nil, repeatPeriod: Int32? = nil, messageEffect: ChatSendMessageEffect? = nil) {
        guard !self.didSend else {
            return
        }

        // Same reason as in stopVideoRecording: a send that lands inside a chunk flush waits
        // for the next chunk to be recording rather than racing the restart.
        if self.iAyuIsFlushingChunk {
            self.iAyuPendingFlushAction = { [weak self] in
                self?.sendVideoRecording(silentPosting: silentPosting, scheduleTime: scheduleTime, repeatPeriod: repeatPeriod, messageEffect: messageEffect)
            }
            return
        }

        var skipAction = false
        let currentTimestamp = CACurrentMediaTime()
        if let lastActionTimestamp = self.lastActionTimestamp, currentTimestamp - lastActionTimestamp < 0.5 {
            skipAction = true
        }
        
        if case .none = self.cameraState.recording, self.node.results.isEmpty {
            self.completion(nil, nil, nil, nil)
            return
        }
        
        if case .none = self.cameraState.recording {
        } else {
            if self.cameraState.duration > 0.5 {
                if skipAction {
                    return
                }
                self.isSendingImmediately = true
                self.waitingForNextResult = true
                self.node.stopRecording.invoke(Void())
            } else {
                self.completion(nil, nil, nil, nil)
                return
            }
        }
        
        guard !skipAction else {
            return
        }
        
        self.didSend = true
        
        let _ = (self.currentResults
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] results in
            guard let self else {
                return
            }

            let liveUploadData: LegacyLiveUploadInterfaceResult?
            if let current = self.node.currentLiveUploadData {
                liveUploadData = current
            } else {
                liveUploadData = self.node.liveUploadInterface?.fileUpdated(true) as? LegacyLiveUploadInterfaceResult
            }

            self.buildMessage(results: results, liveUploadData: liveUploadData, messageEffect: messageEffect, completion: { [weak self] message in
                guard let self else {
                    return
                }
                if let message {
                    self.completion(message, silentPosting, scheduleTime, repeatPeriod)
                } else {
                    self.completion(nil, nil, nil, nil)
                }
            })
        })
    }

    // Turns finished segments into the round-video message. Extracted from
    // sendVideoRecording so IAyuGram's auto-sent chunks can build theirs exactly the same
    // way; what differs between the two callers is only where the message goes and which
    // live-upload result belongs to it, so both are passed in.
    private func buildMessage(results: [VideoMessageCameraScreen.CaptureResult], liveUploadData: LegacyLiveUploadInterfaceResult?, messageEffect: ChatSendMessageEffect?, completion: @escaping (EnqueueMessage?) -> Void) {
        guard let firstResult = results.first, case let .video(video) = firstResult else {
            completion(nil)
            return
        }

        var videoPaths: [String] = []
        var duration: Double = 0.0

        var hasAdjustments = results.count > 1
        for result in results {
            if case let .video(video) = result {
                videoPaths.append(video.videoPath)
                duration += video.duration
            }
        }

        if duration < 1.0 {
            completion(nil)
            return
        }

        var startTime: Double = 0.0
        let finalDuration: Double
        if let trimRange = self.node.previewState?.trimRange {
            startTime = trimRange.lowerBound
            finalDuration = trimRange.upperBound - trimRange.lowerBound
            if finalDuration != duration {
                hasAdjustments = true
            }
        } else {
            finalDuration = duration
        }

        let dimensions = PixelDimensions(width: 400, height: 400)

        let thumbnailImage: Signal<UIImage, NoError>
        if startTime > 0.0 {
            thumbnailImage = Signal { subscriber in
                let composition = composition(with: results)
                let imageGenerator = AVAssetImageGenerator(asset: composition)
                imageGenerator.maximumSize = dimensions.cgSize
                imageGenerator.appliesPreferredTrackTransform = true

                imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: startTime, preferredTimescale: composition.duration.timescale))], completionHandler: { _, image, _, _, _ in
                    if let image {
                        subscriber.putNext(UIImage(cgImage: image))
                    } else {
                        subscriber.putNext(video.thumbnail)
                    }
                    subscriber.putCompletion()
                })

                return ActionDisposable {
                    imageGenerator.cancelAllCGImageGeneration()
                }
            }
        } else {
            thumbnailImage = .single(video.thumbnail)
        }

        let _ = (thumbnailImage
        |> deliverOnMainQueue).startStandalone(next: { [weak self] thumbnailImage in
            guard let self else {
                return
            }
            let values = MediaEditorValues(
                peerId: self.context.account.peerId,
                originalDimensions: dimensions,
                cropOffset: .zero,
                cropRect: CGRect(origin: .zero, size: dimensions.cgSize),
                cropScale: 1.0,
                cropRotation: 0.0,
                cropMirroring: false,
                cropOrientation: nil,
                gradientColors: nil,
                videoTrimRange: self.node.previewState?.trimRange,
                videoBounce: false,
                videoIsMuted: false,
                videoIsFullHd: false,
                videoIsMirrored: false,
                videoVolume: nil,
                additionalVideoPath: nil,
                additionalVideoIsDual: false,
                additionalVideoMirroringChanges: [],
                additionalVideoPosition: nil,
                additionalVideoScale: nil,
                additionalVideoRotation: nil,
                additionalVideoPositionChanges: [],
                additionalVideoTrimRange: nil,
                additionalVideoOffset: nil,
                additionalVideoVolume: nil,
                collage: [],
                nightTheme: false,
                drawing: nil,
                maskDrawing: nil,
                entities: [],
                toolValues: [:],
                audioTrack: nil,
                audioTrackTrimRange: nil,
                audioTrackOffset: nil,
                audioTrackVolume: nil,
                audioTrackSamples: nil,
                collageTrackSamples: nil,
                coverImageTimestamp: nil,
                coverDimensions: nil,
                qualityPreset: .videoMessage
            )
            
            var resourceAdjustments: VideoMediaResourceAdjustments? = nil
            if let valuesData = try? JSONEncoder().encode(values) {
                let data = EngineMemoryBuffer(data: valuesData)
                let digest = EngineMemoryBuffer(data: data.md5Digest())
                resourceAdjustments = VideoMediaResourceAdjustments(data: data, digest: digest, isStory: false)
            }
 
            let resource: TelegramMediaResource
            if !hasAdjustments, let liveUploadData, let data = try? Data(contentsOf: URL(fileURLWithPath: video.videoPath)) {
                resource = LocalFileMediaResource(fileId: liveUploadData.id)
                self.context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data, synchronous: true)
            } else {
                resource = LocalFileVideoMediaResource(randomId: Int64.random(in: Int64.min ... Int64.max), paths: videoPaths, adjustments: resourceAdjustments)
            }
            
            var previewRepresentations: [TelegramMediaImageRepresentation] = []
                        
            let thumbnailResource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
            let thumbnailSize = video.dimensions.cgSize.aspectFitted(CGSize(width: 320.0, height: 320.0))
            if let thumbnailData = scaleImageToPixelSize(image: thumbnailImage, size: thumbnailSize)?.jpegData(compressionQuality: 0.4) {
                self.context.engine.resources.storeResourceData(id: EngineMediaResource.Id(thumbnailResource.id), data: thumbnailData)
                previewRepresentations.append(TelegramMediaImageRepresentation(dimensions: PixelDimensions(thumbnailSize), resource: thumbnailResource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false))
            }
            
            let tempFile = EngineTempBox.shared.tempFile(fileName: "file")
            defer {
                EngineTempBox.shared.dispose(tempFile)
            }
            if let data = compressImageToJPEG(thumbnailImage, quality: 0.7, tempFilePath: tempFile.path) {
                context.account.postbox.mediaBox.storeCachedResourceRepresentation(resource, representation: CachedVideoFirstFrameRepresentation(), data: data)
            }

            let media = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: previewRepresentations, videoThumbnails: [], immediateThumbnailData: nil, mimeType: "video/mp4", size: nil, attributes: [.FileName(fileName: "video.mp4"), .Video(duration: finalDuration, size: video.dimensions, flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)], alternativeRepresentations: [])
            
            var attributes: [EngineMessage.Attribute] = []
            if self.cameraState.isViewOnceEnabled {
                attributes.append(AutoremoveTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil))
            }
            if let messageEffect {
                attributes.append(EffectMessageAttribute(id: messageEffect.id))
            }
    
            completion(.message(
                text: "",
                attributes: attributes,
                inlineStickers: [:],
                mediaReference: .standalone(media: media),
                threadId: nil,
                replyToMessageId: nil,
                replyToStoryId: nil,
                localGroupingKey: nil,
                correlationId: nil,
                bubbleUpEmojiOrStickersets: []
            ))
        })
    }

    private var waitingForNextResult = false
    public func stopVideoRecording() -> Bool {
        guard !self.didSend else {
            return false
        }
        
        self.node.dismissAllTooltips()
        
        self.waitingForNextResult = true
        self.node.transitioningToPreview = true
        self.node.requestUpdateLayout(transition: .spring(duration: 0.4))
        
        self.node.stopRecording.invoke(Void())
        
        return true
    }

    fileprivate var recordingStartTime: Double?
    fileprivate var scheduledLock = false
    public func lockVideoRecording() {
        guard !self.didSend else {
            return
        }
        
        if case .none = self.cameraState.recording {
            self.scheduledLock = true
            self.node.requestUpdateLayout(transition: .spring(duration: 0.4))
        } else {
            self.updateCameraState({ $0.updatedRecording(.handsFree) }, transition: .spring(duration: 0.4))
        }
        
        self.node.maybePresentTooltips()
    }
    
    public func discardVideo() {
        self.node.cancelRecording.invoke(Void())
        
        self.requestDismiss(animated: true)
    }
    
    public func extractVideoSnapshot() -> UIView? {
        if let snapshotView = self.node.previewContainerView.snapshotView(afterScreenUpdates: false) {
            snapshotView.frame = self.node.previewContainerView.convert(self.node.previewContainerView.bounds, to: nil)
            return snapshotView
        }
        return nil
    }

    public func hideVideoSnapshot() {
        self.node.previewContainerView.isHidden = true
    }
    
    public func updateTrimRange(start: Double, end: Double, updatedEnd: Bool, apply: Bool) {
        self.node.updateTrimRange(start: start, end: end, updatedEnd: updatedEnd, apply: apply)
    }
    
    private func requestAudioSession() {
        let audioSessionType: ManagedAudioSessionType
        if self.context.sharedContext.currentMediaInputSettings.with({ $0 }).pauseMusicOnRecording { 
            audioSessionType = .record(speaker: false, video: false, withOthers: false)
        } else {
            audioSessionType = .record(speaker: false, video: false, withOthers: true)
        }
      
        self.audioSessionDisposable = self.context.sharedContext.mediaManager.audioSession.push(audioSessionType: audioSessionType, activate: { [weak self] _ in
            if let self {
                Queue.mainQueue().after(0.05) {
                    self.node.setupCamera()
                }
            }
        }, deactivate: { _ in
            return .single(Void())
        })
    }
            
    private var isDismissed = false
    fileprivate func requestDismiss(animated: Bool) {
        guard !self.isDismissed else {
            return
        }
        
        self.node.dismissAllTooltips()
        
        self.node.camera?.stopCapture(invalidate: true)
        self.isDismissed = true
        if animated {
            self.node.animateOut(completion: {
                self.dismiss(animated: false)
            })
        } else {
            self.dismiss(animated: false)
        }
    }
        
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout
        
        super.containerLayoutUpdated(layout, transition: transition)

        if !self.isDismissed {
            (self.displayNode as! Node).containerLayoutUpdated(layout: layout, transition: ComponentTransition(transition))
        }
    }
    
    public func makeSendMessageContextPreview() -> ChatSendMessageContextScreenMediaPreview? {
        return VideoMessageSendMessageContextPreview(node: self.node)
    }
}

private func composition(with results: [VideoMessageCameraScreen.CaptureResult]) -> AVComposition {
    let composition = AVMutableComposition()
    var currentTime = CMTime.zero
    
    for result in results {
        guard case let .video(video) = result else {
            continue
        }
        let asset = AVAsset(url: URL(fileURLWithPath: video.videoPath))
        let duration = asset.duration
        do {
            try composition.insertTimeRange(
                CMTimeRangeMake(start: .zero, duration: duration),
                of: asset,
                at: currentTime
            )
            currentTime = CMTimeAdd(currentTime, duration)
        } catch {
        }
    }
    return composition
}

private class BlurView: UIVisualEffectView {
    private func setup() {
        for subview in self.subviews {
            if subview.description.contains("VisualEffectSubview") {
                subview.isHidden = true
            }
        }
        
        if let sublayer = self.layer.sublayers?[0], let filters = sublayer.filters {
            sublayer.backgroundColor = nil
            sublayer.isOpaque = false
            let allowedKeys: [String] = [
                "gaussianBlur"
            ]
            sublayer.filters = filters.filter { filter in
                guard let filter = filter as? NSObject else {
                    return true
                }
                let filterName = String(describing: filter)
                if !allowedKeys.contains(filterName) {
                    return false
                }
                return true
            }
        }
    }
    
    override var effect: UIVisualEffect? {
        get {
            return super.effect
        }
        set {
            super.effect = newValue
            self.setup()
        }
    }
    
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        self.setup()
    }
}

private final class VideoMessageSendMessageContextPreview: UIView, ChatSendMessageContextScreenMediaPreview {
    var isReady: Signal<Bool, NoError> {
        return .single(true)
    }
    
    var view: UIView {
        return self
    }
    
    var globalClippingRect: CGRect? {
        return nil
    }
    
    var layoutType: ChatSendMessageContextScreenMediaPreviewLayoutType {
        return .videoMessage
    }
    
    private weak var previewContainerContentParentView: UIView?
    private let previewContainerContentView: UIView
    
    init(node: VideoMessageCameraScreen.Node) {
        self.previewContainerContentParentView = node.previewContainerView
        self.previewContainerContentView = node.previewContainerContentView
        
        super.init(frame: CGRect())
    }
    
    required init(coder: NSCoder) {
        preconditionFailure()
    }
    
    func animateIn(transition: ComponentTransition) {
        self.addSubview(self.previewContainerContentView)
        
        guard let previewContainerContentParentView = self.previewContainerContentParentView else {
            return
        }
        
        let fromFrame = previewContainerContentParentView.convert(CGRect(origin: CGPoint(), size: self.previewContainerContentView.bounds.size), to: self)
        let toFrame = self.previewContainerContentView.frame
        
        transition.animatePosition(view: self.previewContainerContentView, from: CGPoint(x: fromFrame.midX - toFrame.midX, y: fromFrame.midY - toFrame.midY), to: CGPoint(), additive: true)
    }
    
    func animateOut(transition: ComponentTransition) {
        guard let previewContainerContentParentView = self.previewContainerContentParentView else {
            return
        }
        
        let toFrame = previewContainerContentParentView.convert(CGRect(origin: CGPoint(), size: self.previewContainerContentView.bounds.size), to: self)
        
        let previewContainerContentView = self.previewContainerContentView
        transition.setPosition(view: self.previewContainerContentView, position: toFrame.center, completion: { [weak previewContainerContentParentView, weak previewContainerContentView] _ in
            guard let previewContainerContentParentView, let previewContainerContentView else {
                return
            }
            
            previewContainerContentView.frame = CGRect(origin: CGPoint(), size: previewContainerContentView.bounds.size)
            previewContainerContentParentView.addSubview(previewContainerContentView)
        })
    }
    
    func animateOutOnSend(transition: ComponentTransition) {
        guard let previewContainerContentParentView = self.previewContainerContentParentView else {
            return
        }
        
        if let snapshotView = self.previewContainerContentView.snapshotView(afterScreenUpdates: false) {
            self.addSubview(snapshotView)
            transition.setAlpha(view: snapshotView, alpha: 0.0)
        }
        
        self.previewContainerContentView.frame = CGRect(origin: CGPoint(), size: self.previewContainerContentView.bounds.size)
        previewContainerContentParentView.addSubview(self.previewContainerContentView)
    }
    
    func update(containerSize: CGSize, transition: ComponentTransition) -> CGSize {
        return self.previewContainerContentView.bounds.size
    }
}

// MARK: IAyuGram — what the global recording manager is allowed to do with this screen.
//
// The manager lives in AccountContext and cannot name this type, so this is the whole of
// the surface it sees. Note that sending is still this screen's own job: it holds the
// results and knows how to turn them into a message. All the manager decides is where the
// message goes.
extension VideoMessageCameraScreen: IAyuGlobalVideoRecorder {
    public var iAyuPreviewView: UIView {
        return self.node.previewContainerView
    }

    public var iAyuRecordingDuration: Signal<TimeInterval, NoError> {
        return self.recordingStatus.duration
    }

    public var iAyuIsFinished: Bool {
        return self.iAyuDidFinishTake
    }

    public func iAyuSendFromPanel() {
        self.sendVideoRecording()
    }

    public func iAyuCancelFromPanel() {
        self.iAyuTearDown()
    }

    /// Stop the camera and let this controller go. The same thing `discardVideo` does for
    /// an on-screen recorder, minus the animation: there is nothing on screen to animate,
    /// this controller was taken off the window when it was minimized.
    public func iAyuTearDown() {
        self.node.cancelRecording.invoke(Void())
        self.requestDismiss(animated: false)
    }

    public func iAyuStopRecordingKeepingTake() {
        guard !self.iAyuDidFinishTake else {
            return
        }
        self.iAyuDidFinishTake = true
        let _ = self.stopVideoRecording()
    }
}
