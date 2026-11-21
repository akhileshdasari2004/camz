import AVFoundation
import CoreImage
@testable import CamZ

struct TestError: LocalizedError {
    var errorDescription: String? { "Something went wrong." }
}

/// Stands in for the real camera so the view model can be tested without hardware.
final class MockCamera: CameraControlling, @unchecked Sendable {

    // Configuration
    var accessGranted = true
    var capabilities = CameraCapabilities(
        position: .back, minZoom: 1, maxZoom: 20, baseZoom: 2,
        minBias: -8, maxBias: 8, hasFlash: true
    )
    var frontCapabilities = CameraCapabilities(
        position: .front, minZoom: 1, maxZoom: 5, baseZoom: 1,
        minBias: -8, maxBias: 8, hasFlash: false
    )
    var startError: Error?
    var captureResult: Result<Data, Error> = .success(Data([0x1]))
    /// Photos returned in order by the next captures, before `captureResult` is used. Lets a test give each shot its own photo.
    var captureQueue: [Data] = []

    // Recorded calls
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var zoomCalls: [CGFloat] = []
    private(set) var focusPoints: [CGPoint] = []
    private(set) var biasCalls: [Float] = []
    private(set) var capturedFlashModes: [AVCaptureDevice.FlashMode] = []
    private var isFront = false

    // CameraControlling
    var engine = FilterEngine()
    var onFrame: (@Sendable (CIImage) -> Void)?
    var onAnalysisFrame: (@Sendable (CIImage, Bool) -> Void)?
    var onInterruption: (@Sendable (CameraInterruption?) -> Void)?

    func requestAccess() async -> Bool { accessGranted }

    func start() async throws -> CameraCapabilities {
        startCount += 1
        if let startError { throw startError }
        return isFront ? frontCapabilities : capabilities
    }

    func stop() { stopCount += 1 }

    func switchCamera() async throws -> CameraCapabilities {
        isFront.toggle()
        return isFront ? frontCapabilities : capabilities
    }

    func setZoom(_ factor: CGFloat) { zoomCalls.append(factor) }
    func focus(at point: CGPoint) { focusPoints.append(point) }
    func setExposureBias(_ bias: Float) { biasCalls.append(bias) }
    private(set) var trackedFocusPoints: [CGPoint] = []
    private(set) var focusReleaseCount = 0
    func trackFocus(at point: CGPoint) { trackedFocusPoints.append(point) }
    func releaseTrackingFocus() { focusReleaseCount += 1 }

    // RAW, bracketing and white balance. The format choice uses the real selector, so tests exercise the real fallbacks.
    var rawSupport = RawCapabilities.none
    var bracketSupport = BracketCapability.none
    /// Frames returned by the next bracketed capture.
    var bracketResult: Result<[Data], Error> = .success([])
    private(set) var captureRequests: [CaptureRequest] = []
    private(set) var bracketOffsetCalls: [[Float]] = []
    private(set) var whiteBalanceLocks: [Double?] = []

    func capture(
        _ request: CaptureRequest,
        flash: AVCaptureDevice.FlashMode,
        willCapture: @escaping @Sendable () -> Void
    ) async throws -> CapturedPhoto {
        captureRequests.append(request)
        let choice = CaptureFormatSelector.choose(
            format: request.format,
            alongsideProcessed: request.alongsideProcessed,
            candidates: rawSupport.candidates,
            proRAWAllowed: rawSupport.proRAWAllowed
        )
        let data = try await capturePhoto(flash: flash, willCapture: willCapture)
        return CapturedPhoto(
            processed: choice.savesProcessed ? data : nil,
            raw: choice.raw == nil ? nil : Data([0x52, 0x41, 0x57]),
            rawIsProRAW: choice.raw?.kind == .appleProRAW,
            fallbackReason: choice.fallbackReason
        )
    }

    func captureBracket(
        evOffsets: [Float],
        willCapture: @escaping @Sendable () -> Void
    ) async throws -> [Data] {
        bracketOffsetCalls.append(evOffsets)
        willCapture()
        return try bracketResult.get()
    }

    func rawCapabilities() -> RawCapabilities { rawSupport }
    func bracketCapability() -> BracketCapability { bracketSupport }
    func setWhiteBalanceLock(kelvin: Double?) { whiteBalanceLocks.append(kelvin) }

    func capturePhoto(
        flash: AVCaptureDevice.FlashMode,
        willCapture: @escaping @Sendable () -> Void
    ) async throws -> Data {
        capturedFlashModes.append(flash)
        willCapture()
        if !captureQueue.isEmpty { return captureQueue.removeFirst() }
        return try captureResult.get()
    }
}

final class MockLibrary: PhotoSaving, @unchecked Sendable {
    var error: Error?
    /// Saves that fail before the library starts working, to test save fallbacks.
    var failuresBeforeSuccess = 0
    private(set) var saved: [Data] = []
    /// Captures handed to the library, with their companion files, for pairing tests.
    private(set) var savedCaptures: [CapturedPhoto] = []

    func save(_ data: Data) async throws {
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw error ?? TestError()
        }
        if let error { throw error }
        saved.append(data)
    }

    func save(_ photo: CapturedPhoto) async throws {
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw error ?? TestError()
        }
        if let error { throw error }
        savedCaptures.append(photo)
        if let primary = photo.primaryData { saved.append(primary) }
    }
}

/// A fixed answer for Pro access, so tests can run as a Pro user or as a free one.
@MainActor
final class FixedProAccess: ProAccessing {
    let isPro: Bool

    init(_ isPro: Bool) {
        self.isPro = isPro
    }
}
