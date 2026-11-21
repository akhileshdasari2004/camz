import AVFoundation
import Foundation
import Observation

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
    private(set) var lastThumbnail: PlatformImage?
    private(set) var focusPoint: CGPoint?
    /// Set while the system has taken the camera away (call, another app, heat).
    private(set) var interruption: CameraInterruption?
    var toast: String?

    /// Pro: the AI shoots by itself after a countdown, only when the shot is steady, framed and well exposed.
    var isHandsFreeOn: Bool { handsFree.isEnabled }
    /// Pro: the shutter takes three shots and keeps only the sharpest one with open eyes.
    private(set) var isBestOfThreeArmed = false
    /// Which of the three shots is being taken (1…3), while a best-of-three runs.
    private(set) var bestOfThreeProgress: Int?
    /// True while the three shots are measured and the best one is chosen.
    private(set) var isChoosingBestShot = false
    /// Seconds left before a hands-free shot, while the countdown runs.
    private(set) var handsFreeCountdown: Int?
    /// What hands-free is doing right now, in words.
    private(set) var handsFreeMessage: String?
    /// Set when a feature needs Cam Z Pro. The screen shows the paywall while it is true.
    var isPaywallPresented = false
    /// Thermal state from the public API. Heat slows analysis and pauses the Pro automatic features.
    private(set) var thermalState: ProcessInfo.ThermalState

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
    /// The Cam Z Pro subscription. The paywall and the launch checks use it.
    let store: StoreService
    private let camera: CameraControlling
    private let library: PhotoSaving
    /// Who has Pro: the store in the app, a fixed answer in tests.
    private let pro: ProAccessing
    private let clock: @Sendable () -> TimeInterval
    private var zoomAtGestureStart: CGFloat = 1
    private var focusResetTask: Task<Void, Never>?
    /// Decides when a suggested exposure change is applied: agreement first, then spacing and a deadband.
    private var exposureGovernor = ExposureGovernor()
    /// Decides when autofocus follows the subject, and lets go once the subject has been gone for a while.
    private var focusPlanner = FocusPlanner()
    /// Hands-free AI capture: countdown, pause between shots and a cap.
    private var handsFree = HandsFreeController()
    private var lastAutoZoomChange = Date.distantPast
    /// When the director last reported. Old or missing decisions mean the AI has stalled.
    private var lastDecisionAt: Date?
    /// Auto leaves zoom alone for a while after the user pinches or picks a lens.
    private var userZoomedAt = Date.distantPast
    private var thermalObserver: NSObjectProtocol?

    /// Clock for the director's throttles and hands-free timing, in wall-clock seconds. Avoids the boot-time API, which needs a privacy declaration.
    private var throttleClock: TimeInterval { clock() }

    init(
        camera: CameraControlling = CameraService(),
        library: PhotoSaving = PhotoLibraryService(),
        renderer: PreviewRenderer? = PreviewRenderer(),
        store: StoreService? = nil,
        pro: ProAccessing? = nil,
        clock: @escaping @Sendable () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
    ) {
        // Built here rather than in a default argument: the store is main-actor isolated.
        let resolvedStore = store ?? StoreService()
        self.camera = camera
        self.library = library
        self.renderer = renderer
        self.store = resolvedStore
        self.pro = pro ?? resolvedStore
        self.clock = clock
        self.thermalState = ProcessInfo.processInfo.thermalState

        director.setAnalysisInterval(ThermalPolicy.analysisInterval(for: thermalState))
        director.setExposureSnapshotProvider { [camera] in camera.exposureSnapshot() }

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
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.thermalChanged() }
        }
    }

    /// Whether the user has Cam Z Pro. Reads the store, so the screens update when access changes.
    var isPro: Bool { pro.isPro }

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
        disarmHandsFree()
        if status == .running { status = .idle }
    }

    // MARK: Controls

    func flipCamera() async {
        disarmHandsFree()
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

    /// Switches between Auto and Pro. Pro (manual controls) needs Cam Z Pro; without it, the paywall opens instead.
    func toggleMode() {
        if mode == .auto {
            guard EntitlementPolicy.allows(.manualControls, isPro: isPro) else {
                isPaywallPresented = true
                return
            }
            mode = .pro
            disarmHandsFree()
        } else {
            mode = .auto
            isExposureLocked = false
        }
        director.setActive(mode == .auto && status == .running)
    }

    /// Turns hands-free capture on or off. Turning it on needs Cam Z Pro, Auto mode, a cool phone and a running camera.
    func toggleHandsFree() {
        if isHandsFreeOn {
            disarmHandsFree()
            return
        }
        guard EntitlementPolicy.allows(.handsFree, isPro: isPro) else {
            isPaywallPresented = true
            return
        }
        guard mode == .auto else {
            toast = "Hands-free works in Auto mode."
            return
        }
        guard ThermalPolicy.allowsHandsFree(thermalState) else {
            toast = "Let the phone cool down before hands-free capture."
            return
        }
        guard status == .running, interruption == nil else {
            toast = "The camera is not ready yet."
            return
        }
        isBestOfThreeArmed = false
        handsFree.enable()
        handsFreeMessage = Self.handsFreeText(for: handsFree.state)
    }

    /// Arms or disarms best of three. While armed, the shutter takes three shots and keeps the sharpest. Needs Cam Z Pro.
    func toggleBestOfThree() {
        if isBestOfThreeArmed {
            isBestOfThreeArmed = false
            return
        }
        guard EntitlementPolicy.allows(.bestOfThree, isPro: isPro) else {
            isPaywallPresented = true
            return
        }
        guard ThermalPolicy.allowsBestOfThree(thermalState) else {
            toast = "Let the phone cool down before best of three."
            return
        }
        disarmHandsFree()
        isBestOfThreeArmed = true
    }

    func focus(atTap tap: CGPoint, in size: CGSize) {
        let point = CameraMath.pointOfInterest(
            forTap: tap,
            in: size,
            isMirrored: capabilities.position == .front
        )
        camera.focus(at: point)
        focusPlanner.noteUserTap(now: throttleClock)
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

    /// The shutter. Routes to best of three when it is armed; otherwise takes one photo, waiting briefly for a steady frame in Auto.
    /// Returns true when a photo was taken and saved, and false when the shutter was refused or the capture failed.
    @discardableResult
    func capture() async -> Bool {
        if isBestOfThreeArmed {
            await captureBestOfThree()
            return false
        }
        guard status == .running, interruption == nil, !isCapturing else { return false }
        isComparing = false // always save the look the user chose
        isCapturing = true
        defer { isCapturing = false }

        #if DEBUG
        let waitStarted = Date.now
        #endif
        if mode == .auto { await waitForSteadyFrame() }
        #if DEBUG
        let waited = Date.now.timeIntervalSince(waitStarted)
        #endif

        do {
            let data = try await camera.capturePhoto(flash: flashMode) { [weak self] in
                Task { @MainActor in self?.flashShutter() }
            }
            try await record(data)
            #if DEBUG
            DeviceLog.capture(waited: waited, outcome: "saved")
            #endif
            return true
        } catch {
            toast = error.localizedDescription
            #if DEBUG
            DeviceLog.capture(waited: waited, outcome: "failed")
            #endif
            return false
        }
    }

    /// Takes three shots in a row, measures each for sharpness and open eyes, and keeps only the best. The other two are
    /// discarded. If the shots cannot be scored, the last shot is kept and the toast says so.
    func captureBestOfThree() async {
        guard EntitlementPolicy.allows(.bestOfThree, isPro: isPro) else {
            isPaywallPresented = true
            return
        }
        guard ThermalPolicy.allowsBestOfThree(thermalState) else {
            toast = "Let the phone cool down before best of three."
            return
        }
        guard status == .running, interruption == nil, !isCapturing else { return }
        guard flashMode == .off else {
            toast = "Turn the flash off to use best of three."
            return
        }
        isComparing = false
        isCapturing = true
        defer {
            isCapturing = false
            bestOfThreeProgress = nil
            isChoosingBestShot = false
        }

        if mode == .auto { await waitForSteadyFrame() }

        var shots: [Data] = []
        for index in 1...3 {
            bestOfThreeProgress = index
            do {
                let data = try await camera.capturePhoto(flash: .off) { [weak self] in
                    Task { @MainActor in self?.flashShutter() }
                }
                shots.append(data)
            } catch {
                toast = error.localizedDescription
                break
            }
        }
        guard !shots.isEmpty else { return }

        bestOfThreeProgress = nil
        isChoosingBestShot = true
        let frames = shots
        let measured = await Task.detached(priority: .userInitiated) {
            frames.map { ShotAnalyzer.measure($0) }
        }.value
        isChoosingBestShot = false

        let scored = measured.enumerated().compactMap { offset, value in value.map { (offset, $0) } }
        let chosen: Int
        if let best = BestShotRanker.bestIndex(of: scored.map(\.1)) {
            chosen = scored[best].0
        } else {
            chosen = shots.count - 1
        }
        let chosenScore = measured[chosen]

        #if DEBUG
        DeviceLog.bestOfThree(sharpness: measured.map { $0?.sharpness }, chosen: chosen, eyesOpen: chosenScore?.eyesOpen)
        #endif

        let count = "\(shots.count) shot\(shots.count == 1 ? "" : "s")"
        do {
            try await record(shots[chosen])
            if scored.isEmpty {
                toast = "Saved one of \(count). Scoring was unavailable."
            } else if chosenScore?.eyesOpen == false {
                toast = "Saved the sharpest of \(count). No shot had open eyes."
            } else {
                toast = "Saved the sharpest of \(count). The others were discarded."
            }
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
        #if DEBUG
        DeviceLog.decision(decision, bias: exposureBias, zoom: zoom)
        #endif
        guard mode == .auto, status == .running, interruption == nil else { return }
        let now = Date.now
        let stamp = throttleClock

        // Exposure: only after the same direction is suggested twice, at most once a second, and never when locked.
        if !isExposureLocked,
           let delta = decision.exposure?.suggestedBiasDelta,
           let step = exposureGovernor.propose(delta, now: stamp) {
            let target = CameraMath.clampedBias(exposureBias + step, min: capabilities.minBias, max: capabilities.maxBias)
            if target != exposureBias {
                applyBias(target)
            }
        }

        // Focus: follow the subject's eyes or face, let go after it has been gone for two seconds, and never fight a tap.
        switch focusPlanner.command(for: decision.focusTarget, now: stamp) {
        case .focus(let planned):
            camera.trackFocus(at: CameraMath.pointOfInterest(
                forNormalizedImagePoint: planned,
                isMirrored: capabilities.position == .front
            ))
        case .release:
            camera.releaseTrackingFocus()
        case .none:
            break
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

        // Hands-free: after a countdown, the AI shoots when the shot is steady, framed and well exposed.
        if isHandsFreeOn {
            let shotIsReady = HandsFreeGate.conditionsGood(
                readiness: decision.readiness,
                guidance: decision.guidance,
                exposure: decision.exposure?.status,
                blurRisk: decision.blurRisk,
                thermalAllows: ThermalPolicy.allowsHandsFree(thermalState)
            )
            let action = handsFree.update(conditionsGood: shotIsReady, now: stamp)
            handsFreeCountdown = handsFree.secondsRemaining(now: stamp)
            handsFreeMessage = Self.handsFreeText(for: handsFree.state)
            if action == .capture {
                Task { @MainActor in
                    #if DEBUG
                    DeviceLog.handsFree("capture")
                    #endif
                    let took = await self.capture()
                    if took {
                        self.handsFree.didCapture(now: self.throttleClock)
                    } else {
                        self.handsFree.skipCapture()
                    }
                    self.handsFreeCountdown = nil
                    self.afterHandsFreeShot()
                }
            }
        }
    }

    // MARK: Private

    /// Saves a photo, then counts it and updates the shutter thumbnail. A failed save is not counted.
    private func record(_ data: Data) async throws {
        try await library.save(data)
        captureCount += 1
        lastThumbnail = await Thumbnail.make(from: data, shortSide: 200)
    }

    private func disarmHandsFree() {
        handsFree.disable()
        handsFreeCountdown = nil
        handsFreeMessage = nil
    }

    private func afterHandsFreeShot() {
        guard handsFree.state == .finished else {
            handsFreeMessage = Self.handsFreeText(for: handsFree.state)
            return
        }
        toast = "Hands-free stopped after \(handsFree.captures) shots."
        disarmHandsFree()
    }

    /// Heat changes the analysis pace, and it pauses the Pro automatic features when the phone is too warm.
    private func thermalChanged() {
        thermalState = ProcessInfo.processInfo.thermalState
        director.setAnalysisInterval(ThermalPolicy.analysisInterval(for: thermalState))
        if isHandsFreeOn, !ThermalPolicy.allowsHandsFree(thermalState) {
            disarmHandsFree()
            toast = "Hands-free paused while the phone is warm."
        }
        if isBestOfThreeArmed, !ThermalPolicy.allowsBestOfThree(thermalState) {
            isBestOfThreeArmed = false
            toast = "Best of three paused while the phone is warm."
        }
    }

    private static func handsFreeText(for state: HandsFreeController.State) -> String? {
        switch state {
        case .off: nil
        case .watching: "Hands-free on · waiting for a steady, well-framed shot"
        case .ready: "Hands-free on · hold steady"
        case .countdown: "Hands-free on · capturing soon"
        case .capturing: "Hands-free on · capturing"
        case .cooldown: "Hands-free on · paused after a shot"
        case .finished: nil
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
}
