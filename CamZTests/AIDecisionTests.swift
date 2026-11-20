import CoreImage
import XCTest
@testable import CamZ

/// Pure AI decision logic: exposure, stability, focus, guidance, scene fallbacks, readiness and lens rules.
final class AIDecisionLogicTests: XCTestCase {

    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

    private func solid(_ grey: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: grey, green: grey, blue: grey))
            .cropped(to: CGRect(x: 0, y: 0, width: 120, height: 120))
    }

    private func histogram(_ grey: CGFloat) -> LuminanceHistogram {
        ExposureAnalyzer.histogram(of: solid(grey), context: context)!
    }

    // MARK: Exposure intent and protection

    func testNightKeepsItsDarkness() {
        let assessment = ExposureAnalyzer.assess(frame: histogram(0.08), subject: nil, scene: .night)
        XCTAssertEqual(assessment.suggestedBiasDelta, 0)
        XCTAssertEqual(assessment.status, .balanced)
    }

    func testSunsetIsNotLiftedButHighlightsAreProtected() {
        let calm = ExposureAnalyzer.assess(frame: histogram(0.5), subject: nil, scene: .landscape, warm: true)
        XCTAssertEqual(calm.suggestedBiasDelta, 0)
        let blown = ExposureAnalyzer.assess(frame: histogram(1.0), subject: nil, scene: .landscape, warm: true)
        XCTAssertEqual(blown.status, .highlightsClipping)
        XCTAssertLessThan(blown.suggestedBiasDelta, 0)
    }

    func testDarkGeneralFrameAsksForMoreExposureWithinTheLimit() {
        let assessment = ExposureAnalyzer.assess(frame: histogram(0.08), subject: nil)
        XCTAssertGreaterThan(assessment.suggestedBiasDelta, 0)
        XCTAssertLessThanOrEqual(assessment.suggestedBiasDelta, ExposureAnalyzer.maxStep)
    }

    func testClippedSkinHighlightsReduceExposure() {
        let assessment = ExposureAnalyzer.assess(frame: histogram(0.42), subject: histogram(1.0), scene: .portrait)
        XCTAssertEqual(assessment.status, .highlightsClipping)
        XCTAssertLessThan(assessment.suggestedBiasDelta, 0)
    }

    func testWarmColourReadsAsWarm() {
        let warm = CIImage(color: CIColor(red: 0.8, green: 0.5, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertGreaterThan(ColorProbe.redMinusBlue(of: warm, context: context) ?? 0, 0.4)
    }

    // MARK: Stability

    func testGovernorNeedsAgreementAndHonoursTheCooldown() {
        var governor = ExposureGovernor()
        XCTAssertNil(governor.propose(0.8, now: 10))
        XCTAssertEqual(governor.propose(0.8, now: 10.1), 0.8)
        XCTAssertNil(governor.propose(0.8, now: 10.3), "no change during the cooldown")
        XCTAssertNil(governor.propose(0.8, now: 11.5), "fresh suggestions must agree again")
        XCTAssertEqual(governor.propose(0.8, now: 11.6), 0.8)
    }

    func testGovernorIgnoresSmallSuggestionsAndSignFlips() {
        var governor = ExposureGovernor()
        XCTAssertNil(governor.propose(0.1, now: 0))
        XCTAssertNil(governor.propose(0.1, now: 0.1))
        _ = governor.propose(0.8, now: 5)
        XCTAssertNil(governor.propose(-0.8, now: 5.1), "a sign flip resets agreement")
    }

    func testFocusFollowsTheSubjectWithoutLooping() {
        var planner = FocusPlanner()
        XCTAssertEqual(planner.target(for: CGPoint(x: 0.5, y: 0.5), now: 0), CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(planner.target(for: CGPoint(x: 0.52, y: 0.5), now: 2), "small movement does not refocus")
        XCTAssertNil(planner.target(for: CGPoint(x: 0.7, y: 0.5), now: 0.5), "refocus is throttled")
        XCTAssertEqual(planner.target(for: CGPoint(x: 0.7, y: 0.5), now: 2.5), CGPoint(x: 0.7, y: 0.5))
    }

    func testUserTapPausesAIFocusTracking() {
        var planner = FocusPlanner()
        planner.noteUserTap(now: 5)
        XCTAssertNil(planner.target(for: CGPoint(x: 0.2, y: 0.5), now: 6), "the user's tap wins")
        XCTAssertEqual(planner.target(for: CGPoint(x: 0.2, y: 0.5), now: 9.5), CGPoint(x: 0.2, y: 0.5))
    }

    // MARK: Guidance

    func testGuidanceGivesOneUsefulMessage() {
        let steady = CaptureReadiness.steady
        let centred = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)
        XCTAssertEqual(GuidanceEngine.advice(readiness: .moving, horizonDegrees: 5, faces: [centred], scene: .portrait), .holdSteady)
        XCTAssertEqual(GuidanceEngine.advice(readiness: steady, horizonDegrees: 5, faces: [centred], scene: .portrait), .levelPhone)
        XCTAssertEqual(GuidanceEngine.advice(readiness: steady, horizonDegrees: nil, faces: [CGRect(x: 0, y: 0.3, width: 0.3, height: 0.4)], scene: .portrait), .moveLeft)
        XCTAssertEqual(GuidanceEngine.advice(readiness: steady, horizonDegrees: nil, faces: [CGRect(x: 0.35, y: 0.6, width: 0.3, height: 0.4)], scene: .portrait), .stepBack)
        XCTAssertEqual(GuidanceEngine.advice(readiness: steady, horizonDegrees: nil, faces: [CGRect(x: 0.48, y: 0.45, width: 0.06, height: 0.08)], scene: .portrait), .moveCloser)
        XCTAssertEqual(GuidanceEngine.advice(readiness: steady, horizonDegrees: nil, faces: [CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.4)], scene: .portrait), .greatFraming)
        XCTAssertEqual(GuidanceEngine.advice(readiness: steady, horizonDegrees: 0.5, faces: [], scene: .landscape), Guidance.none)
    }

    // MARK: Scene fallbacks

    func testUnlabelledFramesFallBackWithLowConfidence() {
        let daylight = SceneClassifier.decide(labels: [], faceCount: 0, faceAreaFraction: 0, frameMean: 0.7, redMinusBlue: -0.1)
        XCTAssertEqual(daylight.kind, .outdoor)
        XCTAssertFalse(daylight.isConfident)
        let unknown = SceneClassifier.decide(labels: [], faceCount: 0, faceAreaFraction: 0, frameMean: 0.5, redMinusBlue: 0)
        XCTAssertEqual(unknown.kind, .general)
        XCTAssertFalse(unknown.isConfident)
    }

    func testConfidentLabelsWin() {
        let food = SceneClassifier.decide(
            labels: [ClassifiedLabel(identifier: "food_and_drink", confidence: 0.6)],
            faceCount: 0, faceAreaFraction: 0, frameMean: 0.5, redMinusBlue: 0
        )
        XCTAssertEqual(food.kind, .food)
        XCTAssertTrue(food.isConfident)
    }

    func testBacklitSubjectIsDetected() {
        XCTAssertEqual(SceneClassifier.lighting(frameMean: 0.6, highlightClipping: 0.05, shadowClipping: 0, subjectMean: 0.2), .backlit)
    }

    // MARK: Lens

    func testGuessedScenesNeverMoveTheLens() {
        let presets: [CGFloat] = [0.5, 1, 2, 3]
        XCTAssertEqual(LensSelector.recommendedZoom(scene: .landscape, faceAreaFraction: 0, current: 2, presets: presets, isConfident: false), 2)
        XCTAssertEqual(LensSelector.recommendedZoom(scene: .landscape, faceAreaFraction: 0, current: 2, presets: presets), 1)
    }

    func testPortraitStaysAtMainLensWhenTelephotoIsNotOffered() {
        XCTAssertEqual(LensSelector.recommendedZoom(scene: .portrait, faceAreaFraction: 0.03, current: 1, presets: [0.5, 1]), 1)
    }

    // MARK: Capture readiness

    func testLowLightNeedsMoreCalmFrames() {
        var engine = CaptureDecisionEngine()
        for _ in 0..<4 { _ = engine.ingest(motion: 0, settling: false, lowLight: true) }
        XCTAssertEqual(engine.ingest(motion: 0, settling: false, lowLight: true), .steady)
    }

    // MARK: Capture wait bounds

    func testCaptureWaitIsBoundedAndNeverHoldsForAStalledAI() {
        XCTAssertTrue(CaptureWaitPolicy.shouldKeepWaiting(readiness: .moving, decisionAge: 0.2, elapsed: 0.5))
        XCTAssertFalse(CaptureWaitPolicy.shouldKeepWaiting(readiness: .steady, decisionAge: 0.2, elapsed: 0.5))
        XCTAssertFalse(CaptureWaitPolicy.shouldKeepWaiting(readiness: .moving, decisionAge: nil, elapsed: 0))
        XCTAssertFalse(CaptureWaitPolicy.shouldKeepWaiting(readiness: .moving, decisionAge: 2.0, elapsed: 0.1))
        XCTAssertFalse(CaptureWaitPolicy.shouldKeepWaiting(readiness: .moving, decisionAge: 0.2, elapsed: 1.5))
    }

    // MARK: Point of interest

    func testVisionPointsMapToFocusSpace() {
        XCTAssertEqual(CameraMath.pointOfInterest(forNormalizedImagePoint: CGPoint(x: 0.5, y: 0.5), isMirrored: false), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(CameraMath.pointOfInterest(forNormalizedImagePoint: CGPoint(x: 0, y: 1), isMirrored: false), CGPoint(x: 0, y: 1))
        XCTAssertEqual(CameraMath.pointOfInterest(forNormalizedImagePoint: CGPoint(x: 0, y: 1), isMirrored: true), CGPoint(x: 0, y: 0))
    }
}

/// View-model behaviour in Auto and Pro modes, with the mock camera.
@MainActor
final class AutoModeViewModelTests: XCTestCase {

    private var camera: MockCamera!
    private var library: MockLibrary!
    private var model: CameraViewModel!

    override func setUp() async throws {
        camera = MockCamera()
        library = MockLibrary()
        model = CameraViewModel(camera: camera, library: library, renderer: nil)
    }

    private func decision(delta: Float) -> PhotoDecision {
        PhotoDecision(
            exposure: ExposureAssessment(
                subjectMean: 0.2,
                frameMean: 0.2,
                highlightClipping: 0,
                shadowClipping: 0.5,
                status: .underexposed,
                suggestedBiasDelta: delta
            ),
            readiness: .steady
        )
    }

    func testAutoAppliesExposureOnlyAfterTwoAgreeingSuggestions() async {
        await model.start()
        model.apply(decision(delta: 0.8))
        XCTAssertTrue(camera.biasCalls.isEmpty, "a single suggestion is not applied")
        model.apply(decision(delta: 0.8))
        XCTAssertEqual(camera.biasCalls.count, 1)
        XCTAssertEqual(camera.biasCalls.first ?? 0, 0.8, accuracy: 0.001)
    }

    func testManualExposureLocksAutoExposure() async {
        await model.start()
        model.setExposure(1.0)
        model.apply(decision(delta: 0.8))
        model.apply(decision(delta: 0.8))
        XCTAssertEqual(camera.biasCalls, [1.0], "only the user's change reaches the camera")
    }

    func testProModeLeavesExposureToTheUser() async {
        await model.start()
        model.toggleMode()
        model.apply(decision(delta: 0.8))
        model.apply(decision(delta: 0.8))
        XCTAssertTrue(camera.biasCalls.isEmpty)
    }

    func testPresetsOnlyOfferLensesTheHardwareHas() async {
        camera.capabilities = CameraCapabilities(
            position: .back, minZoom: 1, maxZoom: 2, baseZoom: 1,
            minBias: -8, maxBias: 8, hasFlash: false
        )
        await model.start()
        XCTAssertEqual(model.zoomPresets, [1, 2])
        XCTAssertFalse(model.capabilities.hasUltraWide)
    }

    func testCaptureStillSucceedsWhenNoSteadyFrameArrives() async {
        await model.start()
        let started = Date()
        await model.capture()
        XCTAssertEqual(library.saved.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0, "the wait is bounded")
    }
}
