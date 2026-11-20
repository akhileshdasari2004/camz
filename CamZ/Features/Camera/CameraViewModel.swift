import AVFoundation
import Observation
import UIKit

@MainActor
@Observable
final class CameraViewModel {

    enum Status: Equatable {
        case idle
        case running
        case denied
        case failed(String)
    }

    /// Auto lets the AI director choose exposure, lens and timing. Pro leaves every control to the user.
    enum Mode: Equatable {
        case auto
        case pro
    }

    /// Longest a shot waits for the preview to settle before it is taken anyway.
    static let maxSteadyWait: TimeInterval = 1.5

    // MARK: State

    var mode: Mode = .auto
    /// Latest result from `PhotographyDirector`.
    private(set) var decision = PhotoDecision()
    /// True once the user sets exposure by hand. Auto stops adjusting exposure until Auto is re-enabled.
    private(set) var isExposureLocked = false

    private(set) var status: Status = .idle
    private(set) var capabilities = CameraCapabilities()
    private(set) var isCapturing = false
    private(set) var shutterFlash = false
    private(set) var captureCount = 0
    private(set) var lastThumbnail: UIImage?
    private(set) var focusPoint: CGPoint?
    /// Set while the system has taken the camera away (call, another app, heat).
    private(set) var interruption: CameraInterruption?
    var toast: String?

    var filter: FilterKind = .original {
        didSet {
            if filter != oldValue {
                intensity = 1 // every look starts at full strength
                isComparing = false
            }
            syncEngine()
        }
    }
    var intensity: Double = 1.0 { didSet { syncEngine() } }
    /// While true the viewfinder shows the unfiltered frame (hold-to-compare).
    var isComparing = false { didSet { syncEngine() } }
    var flashMode: AVCaptureDevice.FlashMode = .off
    var showGrid = false
    var showExposure = false

    private(set) var zoom: CGFloat = 1
    private(set) var exposureBias: Float = 0

    // MARK: Dependencies

    let renderer: PreviewRenderer?
    let director = PhotographyDirector()
    private let camera: CameraControlling
    private let library: PhotoSaving
    private var zoomAtGestureStart: CGFloat = 1
    private var focusResetTask: Task<Void, Never>?
    private var lastAutoExposureChange = Date.distantPast
    private var lastAutoZoomChange = Date.distantPast
    /// Auto leaves zoom alone for a while after the user pinches or picks a lens.
    private var userZoomedAt = Date.distantPast

    init(
        camera: CameraControlling = CameraService(),
        library: PhotoSaving = PhotoLibraryService(),
        renderer: PreviewRenderer? = PreviewRenderer()
    ) {
        self.camera = camera
        self.library = library
        self.renderer = renderer

        camera.onFrame = { image in renderer?.enqueue(image) }
        camera.onAnalysisFrame = { [director] image, settling in
            director.submit(image, settling: settling)
        }
        camera.onInterruption = { [weak self] interruption in
            Task { @MainActor in self?.interruption = interruption }
        }
        director.onDecision = { [weak self] decision in
            Task { @MainActor in self?.apply(decision) }
        }
    }

    // MARK: Lifecycle

    /// Safe to call repeatedly: also restarts a session the system stopped.
    func start() async {
        guard await camera.requestAccess() else {
            status = .denied
            return
        }
        do {
            let wasRunning = status == .running
            capabilities = try await camera.start()
            if !wasRunning { setZoom(capabilities.baseZoom) }
            interruption = nil
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        camera.stop()
        if status == .running { status = .idle }
    }

    // MARK: Controls

    func flipCamera() async {
        do {
            capabilities = try await camera.switchCamera()
            setZoom(capabilities.baseZoom)
            exposureBias = 0
            isExposureLocked = false
            focusPoint = nil
            if !capabilities.hasFlash { flashMode = .off }
        } catch {
            toast = error.localizedDescription
        }
    }

    func cycleFlash() {
        flashMode = switch flashMode {
        case .off: .auto
        case .auto: .on
        default: .off
        }
    }

    func beginZoom() {
        zoomAtGestureStart = zoom
    }

    func updateZoom(magnification: CGFloat) {
        userZoomedAt = Date.now
        setZoom(zoomAtGestureStart * magnification)
    }

    func setZoom(_ factor: CGFloat) {
        zoom = CameraMath.clampedZoom(factor, min: capabilities.minZoom, max: capabilities.maxZoom)
        camera.setZoom(zoom)
        director.updateZoom(displayZoom, presets: zoomPresets)
    }

    /// Zoom as the user thinks of it: 1× = main lens, 0.5× = ultra-wide.
    var displayZoom: CGFloat { zoom / capabilities.baseZoom }

    /// Lens shortcuts shown above the shutter.
    var zoomPresets: [CGFloat] {
        let base = capabilities.baseZoom
        return [0.5, 1, 2, 3].filter { preset in
            let factor = preset * base
            return factor >= capabilities.minZoom - 0.001 && factor <= capabilities.maxZoom + 0.001
        }
    }

    func selectZoomPreset(_ preset: CGFloat) {
        userZoomedAt = Date.now
        setZoom(preset * capabilities.baseZoom)
    }

    /// Manual exposure from the user. It locks exposure so Auto stops adjusting it.
    func setExposure(_ bias: Float) {
        isExposureLocked = true
        applyBias(bias)
    }

    private func applyBias(_ bias: Float) {
        exposureBias = CameraMath.clampedBias(bias, min: capabilities.minBias, max: capabilities.maxBias)
        camera.setExposureBias(exposureBias)
    }

    func toggleMode() {
        mode = mode == .auto ? .pro : .auto
        if mode == .auto { isExposureLocked = false }
    }

    func focus(atTap tap: CGPoint, in size: CGSize) {
        let point = CameraMath.pointOfInterest(
            forTap: tap,
            in: size,
            isMirrored: capabilities.position == .front
        )
        camera.focus(at: point)
        exposureBias = 0
        focusPoint = tap

        focusResetTask?.cancel()
        focusResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            focusPoint = nil
        }
    }

    // MARK: Capture

    func capture() async {
        guard status == .running, interruption == nil, !isCapturing else { return }
        isComparing = false // always save the look the user chose
        isCapturing = true
        defer { isCapturing = false }

        if mode == .auto { await waitForSteadyFrame() }

        do {
            let data = try await camera.capturePhoto(flash: flashMode) { [weak self] in
                Task { @MainActor in self?.flashShutter() }
            }
            captureCount += 1
            lastThumbnail = await Self.makeThumbnail(from: data)
            try await library.save(data)
        } catch {
            toast = error.localizedDescription
        }
    }

    // MARK: AI direction

    /// Applies the director's suggestions in Auto mode. Each change is throttled so the camera can settle between them.
    private func apply(_ decision: PhotoDecision) {
        self.decision = decision
        guard mode == .auto, status == .running, interruption == nil else { return }
        let now = Date.now

        if !isExposureLocked,
           let delta = decision.exposure?.suggestedBiasDelta, delta != 0,
           now.timeIntervalSince(lastAutoExposureChange) > 1.0 {
            let target = CameraMath.clampedBias(exposureBias + delta, min: capabilities.minBias, max: capabilities.maxBias)
            if target != exposureBias {
                applyBias(target)
                lastAutoExposureChange = now
            }
        }

        if let target = decision.recommendedZoom,
           abs(target - displayZoom) > 0.05,
           now.timeIntervalSince(lastAutoZoomChange) > 2.0,
           now.timeIntervalSince(userZoomedAt) > 5.0 {
            setZoom(target * capabilities.baseZoom)
            lastAutoZoomChange = now
        }
    }

    /// In Auto, gives the preview a short, bounded time to settle so the shot is sharp and correctly exposed.
    private func waitForSteadyFrame() async {
        let deadline = Date.now.addingTimeInterval(Self.maxSteadyWait)
        while !decision.readiness.isSteady, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Private

    private func syncEngine() {
        camera.engine = isComparing
            ? FilterEngine(filter: .original)
            : FilterEngine(filter: filter, intensity: intensity)
    }

    private func flashShutter() {
        shutterFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            shutterFlash = false
        }
    }

    /// Decodes off the main actor and keeps the aspect ratio (the button crops it).
    nonisolated private static func makeThumbnail(from data: Data) async -> UIImage? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = 200 / min(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return await image.byPreparingThumbnail(ofSize: size)
    }
}
