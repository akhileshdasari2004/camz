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
    private(set) var saved: [Data] = []

    func save(_ data: Data) async throws {
        if let error { throw error }
        saved.append(data)
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
