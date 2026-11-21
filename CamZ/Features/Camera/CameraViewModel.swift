import AVFoundation
import CoreImage
import Foundation
import Observation

/// Context for merges and encodes. Colour values stay gamma-encoded, the same as the weight calculations.
private let computedPhotoContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

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

    /// Capture options, set on the options sheet. Standard one-tap capture is the default for each.
    var captureFormat: CaptureFormat = .processed
    /// With RAW, also keep the processed photo as a Photos pair.
    var alsoSavesProcessed = true
    /// Bracket and merge exposures when the scene has strong contrast.
    var isHDREnabled = false
    /// Average several frames in low light.
    var isNightModeEnabled = false
    var isOptionsPresented = false

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
    /// Which features need Pro. Read from configuration, so product decisions do not touch camera code.
    private let gatedFeatures: Set<ProFeature>
    private let clock: @Sendable () -> TimeInterval
    private var zoomAtGestureStart: CGFloat = 1
    private var focusResetTask: Task<Void, Never>?
    /// Decides when a suggested exposure change is applied: agreement first, then spacing and a deadband.
    private var exposureGovernor = ExposureGovernor()
    /// Decides when autofocus follows the subject, and lets go once the subject has been gone for a while.
    private var focusPlanner = FocusPlanner()
    /// Hands-free AI capture: countdown, pause between shots, a cap on shots and a time limit.
    private var handsFree = HandsFreeController()
    /// Decides when a white-balance lock is justified. Locks only after a stable run of warm, atmospheric light.
    private var whiteBalance = WhiteBalanceController()
    /// The white-balance lock last sent to the camera (nil means continuous auto).
    private var appliedKelvin: Double?
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
        configuration: AppConfiguration = AppConfiguration.current,
        clock: @escaping @Sendable () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
    ) {
        // Built here rather than in a default argument: the store is main-actor isolated.
        let resolvedStore = store ?? StoreService()
        self.camera = camera
        self.library = library
        self.renderer = renderer
        self.store = resolvedStore
        self.pro = pro ?? resolvedStore
        self.gatedFeatures = configuration.gatedFeatures
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

    /// Whether a feature may run for this user, under the configured gating.
    func isAllowed(_ feature: ProFeature) -> Bool {
        EntitlementPolicy.allows(feature, isPro: isPro, gated: gatedFeatures)
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
            guard isAllowed(.manualControls) else {
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
        guard isAllowed(.handsFree) else {
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
        handsFree.enable(now: throttleClock)
        handsFreeMessage = Self.handsFreeText(for: handsFree.state)
    }

    /// Arms or disarms best of three. While armed, the shutter takes three shots and keeps the sharpest. Needs Cam Z Pro.
    func toggleBestOfThree() {
        if isBestOfThreeArmed {
            isBestOfThreeArmed = false
            return
        }
        guard isAllowed(.bestOfThree) else {
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

    /// The shutter. Routes to best of three when it is armed. Otherwise it plans the capture (one photo, an HDR bracket,
    /// or a night burst) and falls back to one photo, with the reason, wherever a plan cannot run.
    /// Returns true when a photo was taken and saved; false when the shutter was refused or the capture failed.
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

        let plan = planCapture()
        #if DEBUG
        DeviceLog.plan(plan.reason)
        #endif

        let saved: Bool
        switch plan.strategy {
        case .single:
            let optionsAsked = isHDREnabled || isNightModeEnabled
            saved = await captureSingle(note: optionsAsked ? plan.reason : nil)
        case .hdrBracket(let offsets):
            saved = await captureComputed(evOffsets: offsets, kind: .hdr)
        case .nightBurst(let frames):
            saved = await captureComputed(evOffsets: Array(repeating: 0, count: frames), kind: .night)
        }
        #if DEBUG
        DeviceLog.capture(waited: waited, outcome: saved ? "saved" : "failed")
        #endif
        return saved
    }

    /// Takes three shots in a row, measures each for sharpness and open eyes, and saves the best. The shots are scored
    /// first, and the others are dropped only after the chosen photo is confirmed saved. If the best cannot be saved, the
    /// next best is tried. If none can be saved, the toast says so, rather than dropping them silently.
    func captureBestOfThree() async {
        guard isAllowed(.bestOfThree) else {
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

        let scored: [(index: Int, shot: ShotMeasurement)] = measured.enumerated().compactMap { offset, value in
            value.map { (index: offset, shot: $0) }
        }
        let ranked = BestShotRanker.ranking(of: scored.map(\.shot)).map { scored[$0].index }
        let unscored: [Int] = measured.indices.filter { measured[$0] == nil }.reversed()
        let order = ranked + unscored

        #if DEBUG
        DeviceLog.bestOfThree(sharpness: measured.map { $0?.sharpness }, chosen: order.first ?? 0, eyesOpen: measured[order.first ?? 0]?.eyesOpen)
        #endif

        let count = "\(shots.count) shot\(shots.count == 1 ? "" : "s")"
        var lastError: Error?
        for index in order {
            do {
                try await record(CapturedPhoto(processed: shots[index]))
                if index == order.first {
                    if scored.isEmpty {
                        toast = "Saved one of \(count). Scoring was unavailable."
                    } else if measured[index]?.eyesOpen == false {
                        toast = "Saved the sharpest of \(count). No shot had open eyes."
                    } else {
                        toast = "Saved the sharpest of \(count). The others were discarded."
                    }
                } else {
                    toast = "The sharpest shot could not be saved, so the next best was saved. The others were discarded."
                }
                return
            } catch {
                lastError = error
            }
        }
        toast = "None of the \(count) could be saved. \(lastError?.localizedDescription ?? "")"
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

        // White balance: lock only for stable, warm, atmospheric light with no people in frame. Otherwise continuous auto.
        let whiteBalanceDecision = whiteBalance.ingest(
            kelvin: decision.colorTemperature,
            atmosphericScene: decision.atmosphericLight,
            faceCount: decision.faceCount
        )
        var wantedKelvin: Double?
        if case .lock(let kelvin, _) = whiteBalanceDecision { wantedKelvin = kelvin }
        if Self.shouldApplyWhiteBalance(from: appliedKelvin, to: wantedKelvin) {
            appliedKelvin = wantedKelvin
            camera.setWhiteBalanceLock(kelvin: wantedKelvin)
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

    private enum ComputedKind {
        case hdr
        case night
    }

    /// One ordinary photo in the chosen format. Falls back to a processed photo, and says why, when RAW is unavailable.
    private func captureSingle(note: String? = nil) async -> Bool {
        let request = resolvedRequest()
        do {
            let photo = try await camera.capture(request, flash: flashMode) { [weak self] in
                Task { @MainActor in self?.flashShutter() }
            }
            try await record(photo)
            // Say why, when the request could not be met or when HDR or night was asked for and refused.
            if let reason = photo.fallbackReason ?? note {
                toast = reason
            }
            return true
        } catch {
            toast = error.localizedDescription
            return false
        }
    }

    /// Brackets the exposures and merges them. Any failure falls back to the normal-exposure frame or to one photo, and says so.
    private func captureComputed(evOffsets: [Float], kind: ComputedKind) async -> Bool {
        let frames: [Data]
        do {
            frames = try await camera.captureBracket(evOffsets: evOffsets) { [weak self] in
                Task { @MainActor in self?.flashShutter() }
            }
        } catch {
            toast = "Bracketed capture is not available right now, so one photo was taken."
            return await captureSingle()
        }
        // A merge needs at least two frames. With fewer, one photo is the honest result.
        guard frames.count >= 2 else {
            return await captureSingle(note: "Bracketed capture returned too few frames, so one photo was taken.")
        }

        // Put the frames in exposure order when every frame records its bias. The normal exposure is the one closest to zero.
        let biases = frames.map { ExposureBias.read(from: $0) }
        var order = Array(frames.indices)
        if biases.allSatisfy({ $0 != nil }) {
            order.sort { (biases[$0] ?? 0) < (biases[$1] ?? 0) }
        }
        let ordered = order.map { frames[$0] }
        let orderedBiases = order.map { biases[$0] }
        let reference = orderedBiases.enumerated()
            .min { abs($0.element ?? 0) < abs($1.element ?? 0) }?.offset ?? (ordered.count / 2)

        let snapshot = camera.exposureSnapshot()
        let iso = snapshot.map { Float($0.iso) } ?? 0
        let exposure = decision.exposure
        let highlight = exposure?.highlightClipping ?? 0
        let shadow = exposure?.shadowClipping ?? 0
        let look = camera.engine

        let merged: Data? = await Task.detached(priority: .userInitiated) {
            switch kind {
            case .hdr:
                return ComputedPhoto.hdr(
                    frames: ordered,
                    reference: reference,
                    look: look,
                    iso: iso,
                    highlightClipping: highlight,
                    shadowClipping: shadow,
                    context: computedPhotoContext
                )
            case .night:
                return ComputedPhoto.night(
                    frames: ordered,
                    look: look,
                    iso: iso,
                    highlightClipping: highlight,
                    shadowClipping: shadow,
                    context: computedPhotoContext
                )
            }
        }.value

        do {
            if let merged {
                let label = kind == .hdr ? "Saved an HDR merge of \(ordered.count) exposures." : "Saved a night photo averaged from \(ordered.count) frames."
                try await record(CapturedPhoto(processed: merged, original: ordered[reference]))
                toast = label
            } else {
                // The frames could not be merged. The normal exposure is a native photo, so it is saved, and the toast says why.
                try await record(CapturedPhoto(
                    processed: ordered[reference],
                    fallbackReason: "The frames could not be aligned, so the normal exposure was saved."
                ))
                toast = "The frames could not be aligned, so the normal exposure was saved."
            }
            return true
        } catch {
            toast = error.localizedDescription
            return false
        }
    }

    /// What this shutter press should do, from the scene and what the camera supports. Refusals are kept in the reason.
    private func planCapture() -> CapturePlan {
        let wantsHDR = isHDREnabled && isAllowed(.hdrBracketing)
        let wantsNight = isNightModeEnabled && isAllowed(.nightBurst)
        guard wantsHDR || wantsNight else {
            return CapturePlan(strategy: .single, reason: "Standard one-tap capture.")
        }
        guard let exposure = decision.exposure else {
            return CapturePlan(strategy: .single, reason: "Waiting for the first analysis, so one photo was taken.")
        }
        let snapshot = camera.exposureSnapshot()
        let focal = snapshot?.fieldOfViewDegrees.flatMap { MotionBlurRisk.focalLength35mm(fieldOfViewDegrees: $0) }
        let scene = CaptureScene(
            meanLuma: exposure.frameMean,
            highlightClipping: exposure.highlightClipping,
            shadowClipping: exposure.shadowClipping,
            subjectMoving: decision.readiness == .moving,
            displayZoom: displayZoom,
            exposureSeconds: snapshot?.exposureSeconds,
            focalLength35mm: focal
        )
        return CapturePlanner.plan(
            scene: scene,
            wantsHDR: wantsHDR,
            wantsNight: wantsNight,
            capability: camera.bracketCapability()
        )
    }

    /// Why the chosen format cannot be met on this camera, or nil when it can. Shown on the options sheet.
    func formatNote() -> String? {
        let raw = camera.rawCapabilities()
        return CaptureFormatSelector.choose(
            format: captureFormat,
            alongsideProcessed: alsoSavesProcessed,
            candidates: raw.candidates,
            proRAWAllowed: raw.proRAWAllowed
        ).fallbackReason
    }

    /// The format to request. RAW is a choice the user makes, so it is checked against the configured gating first.
    private func resolvedRequest() -> CaptureRequest {
        guard captureFormat != .processed else { return .processed }
        guard isAllowed(.rawCapture) else {
            isPaywallPresented = true
            return .processed
        }
        return CaptureRequest(format: captureFormat, alongsideProcessed: alsoSavesProcessed)
    }

    /// Saves a photo, then counts it and updates the shutter thumbnail. A failed save is not counted.
    private func record(_ photo: CapturedPhoto) async throws {
        try await library.save(photo)
        captureCount += 1
        if let primary = photo.primaryData {
            lastThumbnail = await Thumbnail.make(from: primary, shortSide: 200)
        }
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

    /// Whether a white-balance command is worth sending: switching the lock on or off, or a change of at least 100 K.
    /// Smaller drift is ignored, so the lock does not churn the device or oscillate.
    private static func shouldApplyWhiteBalance(from current: Double?, to wanted: Double?) -> Bool {
        switch (current, wanted) {
        case (nil, nil): false
        case let (currentKelvin?, wantedKelvin?): abs(currentKelvin - wantedKelvin) >= 100
        default: true
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
