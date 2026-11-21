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

/// What the user asked one shutter press to save.
struct CaptureRequest: Equatable, Sendable {
    var format: CaptureFormat
    /// Keep a processed photo as well as the RAW file, saved as a Photos pair.
    var alongsideProcessed: Bool

    static let processed = CaptureRequest(format: .processed, alongsideProcessed: false)
}

/// The RAW formats this camera offers right now.
struct RawCapabilities: Equatable, Sendable {
    var candidates: [RawFormatCandidate]
    /// True when ProRAW is enabled on the photo output for this device.
    var proRAWAllowed: Bool

    static let none = RawCapabilities(candidates: [], proRAWAllowed: false)
}

/// What one shutter press produced. A plain capture fills `processed`. A RAW capture fills `raw`, and `processed` too when
/// requested. A computed photo (HDR merge or night average) fills `processed` and keeps the camera's own frame in `original`.
struct CapturedPhoto: Sendable {
    /// Identifies this capture, so the review can tell whether the photo on screen has been saved.
    let id = UUID()
    var processed: Data?
    var raw: Data?
    /// The unprocessed, camera-native frame kept beside a computed photo, so the original can be compared or restored.
    var original: Data?
    /// True when `raw` is Apple ProRAW rather than Bayer RAW.
    var rawIsProRAW = false
    /// Why the request could not be met exactly. Nil when it was.
    var fallbackReason: String?

    init(
        processed: Data? = nil,
        raw: Data? = nil,
        original: Data? = nil,
        rawIsProRAW: Bool = false,
        fallbackReason: String? = nil
    ) {
        self.processed = processed
        self.raw = raw
        self.original = original
        self.rawIsProRAW = rawIsProRAW
        self.fallbackReason = fallbackReason
    }

    /// The photo used for scoring and the thumbnail: the processed photo when there is one, otherwise the RAW file.
    var primaryData: Data? { processed ?? raw }
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

    /// One processed photo, with the look applied. Used by the standard one-tap capture and by best of three.
    func capturePhoto(
        flash: AVCaptureDevice.FlashMode,
        willCapture: @escaping @Sendable () -> Void
    ) async throws -> Data

    /// One shutter press in the requested format. RAW formats are used only where the camera offers them.
    func capture(
        _ request: CaptureRequest,
        flash: AVCaptureDevice.FlashMode,
        willCapture: @escaping @Sendable () -> Void
    ) async throws -> CapturedPhoto

    /// Bracketed exposures at these EV offsets, in capture order. Processed frames only.
    func captureBracket(
        evOffsets: [Float],
        willCapture: @escaping @Sendable () -> Void
    ) async throws -> [Data]

    /// The RAW formats this camera offers right now.
    func rawCapabilities() -> RawCapabilities
    /// Whether bracketed capture is available and how many frames one bracket may hold.
    func bracketCapability() -> BracketCapability
    /// Holds white balance at this colour temperature, or returns to continuous auto when nil.
    func setWhiteBalanceLock(kelvin: Double?)
}

/// Default behaviour for the newer camera controls, so existing implementations and test doubles keep working.
/// `CameraService` overrides each of these with the real hardware calls.
extension CameraControlling {
    func trackFocus(at point: CGPoint) {}
    func releaseTrackingFocus() {}
    func rampZoom(to factor: CGFloat) { setZoom(factor) }
    func exposureSnapshot() -> ExposureSnapshot? { nil }

    func capture(
        _ request: CaptureRequest,
        flash: AVCaptureDevice.FlashMode,
        willCapture: @escaping @Sendable () -> Void
    ) async throws -> CapturedPhoto {
        let data = try await capturePhoto(flash: flash, willCapture: willCapture)
        return CapturedPhoto(processed: data)
    }

    func captureBracket(
        evOffsets: [Float],
        willCapture: @escaping @Sendable () -> Void
    ) async throws -> [Data] {
        throw CameraError.captureFailed
    }

    func rawCapabilities() -> RawCapabilities { .none }
    func bracketCapability() -> BracketCapability { .none }
    func setWhiteBalanceLock(kelvin: Double?) {}
}

/// Where finished photos go.
protocol PhotoSaving: Sendable {
    func save(_ data: Data) async throws
    /// Saves a capture as one Photos asset. Companion files (a RAW file with its processed photo, or the original beside
    /// a computed photo) are paired with the primary photo.
    func save(_ photo: CapturedPhoto) async throws
}

extension PhotoSaving {
    func save(_ photo: CapturedPhoto) async throws {
        guard let primary = photo.primaryData else { throw CameraError.captureFailed }
        try await save(primary)
    }
}
