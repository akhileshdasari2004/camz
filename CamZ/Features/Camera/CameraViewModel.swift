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
    /// Decides when a suggested exposure change is applied: agreement first, then spacing and a deadband.
    private var exposureGovernor = ExposureGovernor()
    /// Decides when autofocus follows the subject. Pauses for a few seconds after a user tap.
    private var focusPlanner = FocusPlanner()
    private var lastAutoZoomChange = Date.distantPast
    /// When the director last reported. Old or missing decisions mean the AI has stalled.
    private var lastDecisionAt: Date?
    /// Auto leaves zoom alone for a while after the user pinches or picks a lens.
    private var userZoomedAt = Date.distantPast

    /// Monotonic clock for the director's throttles, unaffected by changes to the system date.
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

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
            director.setActive(mode == .auto)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        camera.stop()
        director.setActive(false)
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
        director.setActive(mode == .auto && status == .running)
    }

    func focus(atTap tap: CGPoint, in size: CGSize) {
        let point = CameraMath.pointOfInterest(
            forTap: tap,
            in: size,
            isMirrored: capabilities.position == .front
        )
        camera.focus(at: point)
        focusPlanner.noteUserTap(now: uptime)
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

    /// Applies the director's suggestions in Auto mode. Every change is checked for stability and spacing,
    /// and the user's manual settings always win.
    func apply(_ decision: PhotoDecision) {
        self.decision = decision
        lastDecisionAt = Date.now
        guard mode == .auto, status == .running, interruption == nil else { return }
        let now = Date.now
        let clock = uptime

        // Exposure: only after the same direction is suggested twice, at most once a second, and never when locked.
        if !isExposureLocked,
           let delta = decision.exposure?.suggestedBiasDelta,
           let step = exposureGovernor.propose(delta, now: clock) {
            let target = CameraMath.clampedBias(exposureBias + step, min: capabilities.minBias, max: capabilities.maxBias)
            if target != exposureBias {
                applyBias(target)
            }
        }

        // Focus: follow the subject's eyes or face, without refocusing loops or fighting a recent tap.
        if let point = decision.focusTarget,
           let planned = focusPlanner.target(for: point, now: clock) {
            camera.trackFocus(at: CameraMath.pointOfInterest(
                forNormalizedImagePoint: planned,
                isMirrored: capabilities.position == .front
            ))
        }

        // Lens: a smooth ramp to the recommended zoom, paused for a while after the user zooms by hand.
        if let target = decision.recommendedZoom,
           abs(target - displayZoom) > 0.05,
           now.timeIntervalSince(lastAutoZoomChange) > 2.0,
           now.timeIntervalSince(userZoomedAt) > 5.0 {
            let factor = CameraMath.clampedZoom(
                target * capabilities.baseZoom,
                min: capabilities.minZoom,
                max: capabilities.maxZoom
            )
            zoom = factor
            camera.rampZoom(to: factor)
            director.updateZoom(displayZoom, presets: zoomPresets)
            lastAutoZoomChange = now
        }
    }

    /// In Auto, waits briefly for a steady preview so the shot is sharp. The wait is bounded, and it never holds
    /// the shutter for a stalled AI.
    private func waitForSteadyFrame() async {
        let started = Date.now
        while true {
            let elapsed = Date.now.timeIntervalSince(started)
            let age = lastDecisionAt.map { Date.now.timeIntervalSince($0) }
            guard CaptureWaitPolicy.shouldKeepWaiting(readiness: decision.readiness, decisionAge: age, elapsed: elapsed) else {
                return
            }
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
