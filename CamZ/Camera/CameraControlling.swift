import AVFoundation
import CoreImage

/// Why the camera stopped delivering frames while the app is still on screen.
enum CameraInterruption: Equatable, Sendable {
    case inUseByAnotherApp
    case multitasking
    case systemPressure
    case other

    var message: String {
        switch self {
        case .inUseByAnotherApp: "The camera is being used by another app."
        case .multitasking: "The camera isn't available while multitasking."
        case .systemPressure: "The camera paused because the device is too warm."
        case .other: "The camera is paused."
        }
    }

    /// Maps AVFoundation's reason. Background interruptions return nil because
    /// nobody can see the screen, so there's nothing to show.
    init?(reason: AVCaptureSession.InterruptionReason) {
        switch reason {
        case .videoDeviceInUseByAnotherClient: self = .inUseByAnotherApp
        case .videoDeviceNotAvailableWithMultipleForegroundApps: self = .multitasking
        case .videoDeviceNotAvailableDueToSystemPressure: self = .systemPressure
        case .videoDeviceNotAvailableInBackground: return nil
        default: self = .other
        }
    }
}

/// Everything the UI needs from the camera. `CameraService` is the real
/// implementation; tests use a mock so the view model runs without hardware.
protocol CameraControlling: AnyObject, Sendable {
    var engine: FilterEngine { get set }
    /// Filtered, upright preview frames, delivered on a background queue.
    var onFrame: (@Sendable (CIImage) -> Void)? { get set }
    /// Unfiltered, upright preview frames for analysis, plus whether focus or exposure is still settling.
    var onAnalysisFrame: (@Sendable (CIImage, Bool) -> Void)? { get set }
    /// `nil` when an interruption ends. Delivered on any queue.
    var onInterruption: (@Sendable (CameraInterruption?) -> Void)? { get set }

    func requestAccess() async -> Bool
    func start() async throws -> CameraCapabilities
    func stop()
    func switchCamera() async throws -> CameraCapabilities

    func setZoom(_ factor: CGFloat)
    func focus(at point: CGPoint)
    func setExposureBias(_ bias: Float)
    /// Re-aims continuous autofocus at a point of interest (AVFoundation space) without touching exposure.
    func trackFocus(at point: CGPoint)
    /// Returns focus to the centre with continuous autofocus. Exposure is left alone.
    func releaseTrackingFocus()
    /// Moves zoom smoothly toward `factor` where the hardware supports it.
    func rampZoom(to factor: CGFloat)
    /// Exposure settings of the active camera, for blur-risk judgements. Nil when unavailable. Safe from any thread.
    func exposureSnapshot() -> ExposureSnapshot?

    func capturePhoto(
        flash: AVCaptureDevice.FlashMode,
        willCapture: @escaping @Sendable () -> Void
    ) async throws -> Data
}

/// Default behaviour for the newer camera controls, so existing implementations and test doubles keep working.
/// `CameraService` overrides each of these with the real hardware calls.
extension CameraControlling {
    func trackFocus(at point: CGPoint) {}
    func releaseTrackingFocus() {}
    func rampZoom(to factor: CGFloat) { setZoom(factor) }
    func exposureSnapshot() -> ExposureSnapshot? { nil }
}

/// Where finished photos go.
protocol PhotoSaving: Sendable {
    func save(_ data: Data) async throws
}
