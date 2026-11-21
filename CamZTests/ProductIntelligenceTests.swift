import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import CamZ

/// Pure product-intelligence rules: blur, white balance, heat, hands-free, best of three, focus, guidance, lens and
/// Pro entitlements. No camera is needed.
final class ProductIntelligencePureTests: XCTestCase {

    // MARK: Blur and white balance

    func testBlurRiskFollowsTheHandheldLimit() {
        let fov: Float = 69.4 // main lens, about 26 mm equivalent
        func level(_ seconds: Double, moving: Bool = false) -> MotionBlurRisk.Level {
            MotionBlurRisk.level(
                snapshot: ExposureSnapshot(exposureSeconds: seconds, iso: 100, fieldOfViewDegrees: fov),
                subjectMoving: moving
            )
        }
        XCTAssertEqual(level(1.0 / 30), .low)
        XCTAssertEqual(level(1.0 / 15), .medium)
        XCTAssertEqual(level(1.0 / 8), .high)
        XCTAssertEqual(level(1.0 / 20, moving: true), .high)
        XCTAssertEqual(MotionBlurRisk.level(snapshot: nil, subjectMoving: false), .unknown)
    }

    func testWhiteBalanceStaysAutomaticWhileLockingIsOff() {
        XCTAssertFalse(WhiteBalanceAdvisor.lockingEnabled)
        XCTAssertEqual(
            WhiteBalanceAdvisor.mode(source: .tungsten, atmosphericScene: true, stableFrames: 100),
            .continuousAuto
        )
    }

    func testLightSourceComesFromTheColourCast() {
        XCTAssertEqual(WhiteBalanceAdvisor.classify(AverageColor(red: 0.8, green: 0.5, blue: 0.25), meanLuma: 0.5), .tungsten)
        XCTAssertEqual(WhiteBalanceAdvisor.classify(AverageColor(red: 0.5, green: 0.5, blue: 0.5), meanLuma: 0.5), .daylight)
        XCTAssertEqual(WhiteBalanceAdvisor.classify(AverageColor(red: 0.45, green: 0.6, blue: 0.5), meanLuma: 0.52), .fluorescent)
    }

    // MARK: Heat

    func testHeatSlowsAnalysisAndPausesProAutomation() {
        XCTAssertEqual(ThermalPolicy.analysisInterval(for: .nominal), 0.2)
        XCTAssertEqual(ThermalPolicy.analysisInterval(for: .critical), 1.0)
        XCTAssertTrue(ThermalPolicy.allowsHandsFree(.fair))
        XCTAssertFalse(ThermalPolicy.allowsHandsFree(.serious))
        XCTAssertFalse(ThermalPolicy.allowsBestOfThree(.critical))
    }

    // MARK: Hands-free

    func testHandsFreeHoldsCountsDownAndCapturesOnce() {
        var controller = HandsFreeController()
        controller.enable()
        XCTAssertEqual(controller.update(conditionsGood: true, now: 0), .none)
        XCTAssertEqual(controller.update(conditionsGood: true, now: 1.0), .none) // hold finished: countdown starts
        XCTAssertEqual(controller.secondsRemaining(now: 1.0), 3)
        XCTAssertEqual(controller.update(conditionsGood: true, now: 3.9), .none)
        XCTAssertEqual(controller.update(conditionsGood: true, now: 4.0), .capture)
        XCTAssertEqual(controller.update(conditionsGood: true, now: 4.1), .none, "one capture per countdown")
        controller.didCapture(now: 4.1)
        XCTAssertEqual(controller.captures, 1)
    }

    func testHandsFreeCancelsWhenConditionsBreakAndNeverFiresWhenOff() {
        var controller = HandsFreeController()
        controller.enable()
        _ = controller.update(conditionsGood: true, now: 0)
        _ = controller.update(conditionsGood: true, now: 1.0)
        XCTAssertEqual(controller.update(conditionsGood: false, now: 2.0), .none)
        XCTAssertEqual(controller.update(conditionsGood: true, now: 10), .none)
        controller.disable()
        XCTAssertEqual(controller.update(conditionsGood: true, now: 100), .none)
    }

    func testARefusedCaptureIsNotCountedAsAShot() {
        var controller = HandsFreeController()
        controller.enable()
        controller.holdDuration = 0
        controller.countdownDuration = 0
        _ = controller.update(conditionsGood: true, now: 0)
        _ = controller.update(conditionsGood: true, now: 0)
        XCTAssertEqual(controller.update(conditionsGood: true, now: 0), .capture)
        controller.skipCapture()
        XCTAssertEqual(controller.captures, 0)
        XCTAssertEqual(controller.state, .watching)
    }

    func testHandsFreeGateRefusesBlurMovementAndATiltedHorizon() {
        XCTAssertTrue(HandsFreeGate.conditionsGood(
            readiness: .steady, guidance: .greatFraming, exposure: .balanced, blurRisk: .low, thermalAllows: true
        ))
        XCTAssertFalse(HandsFreeGate.conditionsGood(
            readiness: .steady, guidance: .greatFraming, exposure: .balanced, blurRisk: .high, thermalAllows: true
        ))
        XCTAssertFalse(HandsFreeGate.conditionsGood(
            readiness: .steady, guidance: .levelPhone, exposure: .balanced, blurRisk: .low, thermalAllows: true
        ))
        XCTAssertFalse(HandsFreeGate.conditionsGood(
            readiness: .moving, guidance: .none, exposure: .balanced, blurRisk: .low, thermalAllows: true
        ))
    }

    // MARK: Best of three

    func testBestShotPrefersOpenEyesThenSharpness() {
        func shot(_ sharpness: Float, _ eyes: Bool?) -> ShotMeasurement {
            ShotMeasurement(sharpness: sharpness, faceCount: eyes == nil ? 0 : 1, eyesOpen: eyes)
        }
        XCTAssertNil(BestShotRanker.bestIndex(of: []))
        XCTAssertEqual(BestShotRanker.bestIndex(of: [shot(0.2, true), shot(0.5, true), shot(0.4, true)]), 1)
        XCTAssertEqual(BestShotRanker.bestIndex(of: [shot(0.9, false), shot(0.4, true)]), 1)
        XCTAssertEqual(BestShotRanker.bestIndex(of: [shot(0.5, true), shot(0.5, true)]), 0, "ties keep the earlier shot")
    }

    func testEyeOpennessReadsTheShapeOfTheEye() {
        let open = [
            CGPoint(x: 0, y: 0.5), CGPoint(x: 0.25, y: 0.8), CGPoint(x: 0.75, y: 0.8),
            CGPoint(x: 1, y: 0.5), CGPoint(x: 0.75, y: 0.2), CGPoint(x: 0.25, y: 0.2)
        ]
        let ratio = EyeOpenness.ratio(of: open) ?? -1
        XCTAssertEqual(ratio, 0.6, accuracy: 0.001)
        XCTAssertTrue(EyeOpenness.isOpen(ratio))
        let flat = [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0.5)]
        XCTAssertFalse(EyeOpenness.isOpen(EyeOpenness.ratio(of: flat) ?? 0))
        XCTAssertNil(EyeOpenness.allOpen([nil, nil]), "nothing measured is not 'open'")
        XCTAssertEqual(EyeOpenness.allOpen([0.5, 0.05]), false)
    }

    func testShotAnalyzerScoresSharpnessFromARealPhoto() throws {
        let sharp = try XCTUnwrap(ShotAnalyzer.measure(try XCTUnwrap(TestPhotos.stripes(blurRadius: 0))))
        let blurred = try XCTUnwrap(ShotAnalyzer.measure(try XCTUnwrap(TestPhotos.stripes(blurRadius: 6))))
        XCTAssertGreaterThan(sharp.sharpness, blurred.sharpness)
        XCTAssertNil(sharp.eyesOpen, "a stripe pattern has no face, so no eye measurement")
        XCTAssertNil(ShotAnalyzer.measure(Data([0x1])), "data that is not a photo cannot be scored")
    }

    func testSharpEdgesScoreAboveFlatImages() {
        let stripes: [Float] = (0..<64).map { ($0 % 8) % 2 == 0 ? 0 : 1 }
        let flat = [Float](repeating: 0.5, count: 64)
        XCTAssertGreaterThan(ShotSharpness.laplacianVariance(stripes, width: 8, height: 8), 1)
        XCTAssertEqual(ShotSharpness.laplacianVariance(flat, width: 8, height: 8), 0)
    }

    // MARK: Focus, guidance and lens

    func testFocusLetsGoAfterTwoSecondsWithoutASubject() {
        var planner = FocusPlanner()
        XCTAssertEqual(planner.command(for: CGPoint(x: 0.5, y: 0.5), now: 0), .focus(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(planner.command(for: nil, now: 1), .none)
        XCTAssertEqual(planner.command(for: nil, now: 2.1), .release)
        XCTAssertEqual(planner.command(for: nil, now: 3), .none)
    }

    func testGuidanceJudgesGroupsAndCameraHeight() {
        let steady = CaptureReadiness.steady
        let group = [CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.4), CGRect(x: 0.6, y: 0.3, width: 0.2, height: 0.4)]
        XCTAssertEqual(GuidanceEngine.advice(readiness: steady, horizonDegrees: nil, faces: group, scene: .general), .greatFraming)
        XCTAssertEqual(
            GuidanceEngine.advice(readiness: steady, horizonDegrees: nil, faces: [CGRect(x: 0.35, y: 0, width: 0.3, height: 0.2)], scene: .portrait),
            .lowerCamera
        )
        XCTAssertEqual(
            GuidanceEngine.advice(readiness: steady, horizonDegrees: nil, faces: [CGRect(x: 0.35, y: 0.72, width: 0.3, height: 0.2)], scene: .portrait),
            .raiseCamera
        )
        XCTAssertEqual(
            GuidanceEngine.advice(readiness: steady, horizonDegrees: nil, faces: [CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)], scene: .portrait, blurRisk: .high),
            .holdSteady
        )
        XCTAssertEqual(Guidance.greatFraming.message, "Perfect framing")
    }

    func testLowLightKeepsTheMainLens() {
        let presets: [CGFloat] = [0.5, 1, 2, 3]
        XCTAssertEqual(
            LensSelector.recommendedZoom(scene: .portrait, faceAreaFraction: 0.03, current: 1, presets: presets, lowLight: true),
            1
        )
        XCTAssertEqual(
            LensSelector.recommendedZoom(scene: .landscape, faceAreaFraction: 0, current: 2, presets: presets, lowLight: true),
            1
        )
    }

    // MARK: Entitlements

    func testProAccessSurvivesOfflineForTwoWeeksOnly() {
        let now = Date()
        let recent = CachedEntitlement(productID: "p", verifiedAt: now.addingTimeInterval(-86_400))
        let stale = CachedEntitlement(productID: "p", verifiedAt: now.addingTimeInterval(-40 * 86_400))
        XCTAssertTrue(EntitlementPolicy.isPro(storeAnswer: nil, cached: recent, now: now))
        XCTAssertFalse(EntitlementPolicy.isPro(storeAnswer: nil, cached: stale, now: now))
        XCTAssertFalse(EntitlementPolicy.isPro(storeAnswer: false, cached: recent, now: now), "the store's answer wins over the cache")
    }

    func testProductIDsComeOnlyFromConfiguration() {
        XCTAssertTrue(EntitlementPolicy.productIDs(from: [nil, " "]).isEmpty)
        XCTAssertEqual(EntitlementPolicy.productIDs(from: ["a.monthly", ""]), ["a.monthly"])
    }
}

/// Real JPEG photos for the best-of-three tests: vertical stripes, sharp or blurred.
enum TestPhotos {
    static func stripes(blurRadius: CGFloat) -> Data? {
        let width = 256
        let height = 256
        let period = 4
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }
        for x in stride(from: 0, to: width, by: period * 2) {
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: period, height: height))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: x + period, y: 0, width: period, height: height))
        }
        guard let cgImage = context.makeImage() else { return nil }
        var image = CIImage(cgImage: cgImage)
        if blurRadius > 0 {
            image = image
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(blurRadius))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
    }
}

/// Clock the tests control, so hands-free timing does not depend on real time.
private final class TestClock: @unchecked Sendable {
    var now: TimeInterval = 100
}

/// View-model gating and the automatic features, with the mock camera.
@MainActor
final class ProductIntelligenceModelTests: XCTestCase {

    private var camera: MockCamera!
    private var library: MockLibrary!
    private let clock = TestClock()

    override func setUp() async throws {
        camera = MockCamera()
        library = MockLibrary()
        clock.now = 100
    }

    private func makeModel(pro: Bool) -> CameraViewModel {
        let clock = clock
        return CameraViewModel(
            camera: camera,
            library: library,
            renderer: nil,
            pro: FixedProAccess(pro),
            clock: { clock.now }
        )
    }

    /// A frame that is steady, well framed, well exposed and low blur: everything hands-free needs.
    private func steadyGoodDecision() -> PhotoDecision {
        PhotoDecision(
            exposure: ExposureAssessment(
                subjectMean: 0.4,
                frameMean: 0.4,
                highlightClipping: 0,
                shadowClipping: 0,
                status: .balanced,
                suggestedBiasDelta: 0
            ),
            guidance: .greatFraming,
            readiness: .steady,
            blurRisk: .low
        )
    }

    /// Waits, briefly, for work a view-model task started.
    private func waitUntil(_ condition: () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 100 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Gating

    func testFreeUsersSeeThePaywallInsteadOfProMode() async {
        let model = makeModel(pro: false)
        await model.start()
        model.toggleMode()
        XCTAssertEqual(model.mode, .auto)
        XCTAssertTrue(model.isPaywallPresented)
    }

    func testProUsersCanEnterProMode() async {
        let model = makeModel(pro: true)
        await model.start()
        model.toggleMode()
        XCTAssertEqual(model.mode, .pro)
        XCTAssertFalse(model.isPaywallPresented)
    }

    func testHandsFreeNeedsPro() async {
        let model = makeModel(pro: false)
        await model.start()
        model.toggleHandsFree()
        XCTAssertFalse(model.isHandsFreeOn)
        XCTAssertTrue(model.isPaywallPresented)
    }

    func testBestOfThreeNeedsPro() async {
        let model = makeModel(pro: false)
        await model.start()
        model.toggleBestOfThree()
        XCTAssertFalse(model.isBestOfThreeArmed)
        XCTAssertTrue(model.isPaywallPresented)
    }

    func testFreeUsersGetNoBestOfThreeShots() async {
        let model = makeModel(pro: false)
        await model.start()
        await model.captureBestOfThree()
        XCTAssertTrue(camera.capturedFlashModes.isEmpty)
        XCTAssertTrue(model.isPaywallPresented)
    }

    // MARK: Hands-free

    func testHandsFreeCountsDownCapturesOnceAndCanBeCancelled() async {
        let model = makeModel(pro: true)
        await model.start()
        model.toggleHandsFree()
        XCTAssertTrue(model.isHandsFreeOn)

        model.apply(steadyGoodDecision()) // starts the hold
        clock.now = 101.2
        model.apply(steadyGoodDecision()) // hold finished: countdown starts
        XCTAssertEqual(model.handsFreeCountdown, 3)

        clock.now = 104.3
        model.apply(steadyGoodDecision()) // countdown finished: one automatic shot
        await waitUntil { self.library.saved.count == 1 }
        XCTAssertEqual(library.saved.count, 1)

        model.toggleHandsFree() // cancel
        XCTAssertFalse(model.isHandsFreeOn)
    }

    // MARK: Best of three

    func testBestOfThreeTakesThreeShotsAndSavesOnlyOne() async {
        let model = makeModel(pro: true)
        await model.start()
        model.toggleBestOfThree()
        XCTAssertTrue(model.isBestOfThreeArmed)

        await model.captureBestOfThree()
        XCTAssertEqual(camera.capturedFlashModes.count, 3, "three shots are taken")
        XCTAssertEqual(library.saved.count, 1, "only the chosen shot is saved")
        XCTAssertEqual(model.captureCount, 1)
        XCTAssertNil(model.bestOfThreeProgress)
        XCTAssertFalse(model.isCapturing)
        // The mock returns data that is not a photo, so nothing can be scored. The app must say so, not claim a choice.
        XCTAssertEqual(model.toast, "Saved one of 3 shots. Scoring was unavailable.")
    }

    // MARK: Focus

    func testFocusFollowsTheSubjectAndIsReleasedWhenItIsGone() async {
        let model = makeModel(pro: false)
        await model.start()
        var withSubject = PhotoDecision()
        withSubject.focusTarget = CGPoint(x: 0.5, y: 0.5)

        clock.now = 100
        model.apply(withSubject)
        XCTAssertEqual(camera.trackedFocusPoints.count, 1)

        clock.now = 101
        model.apply(PhotoDecision())
        XCTAssertEqual(camera.focusReleaseCount, 0, "not released after one second")

        clock.now = 102.5
        model.apply(PhotoDecision())
        XCTAssertEqual(camera.focusReleaseCount, 1, "released after two seconds without a subject")
    }

    func testBestOfThreeKeepsTheSharpestRealPhoto() async throws {
        let blurred = try XCTUnwrap(TestPhotos.stripes(blurRadius: 6))
        let medium = try XCTUnwrap(TestPhotos.stripes(blurRadius: 1.5))
        let sharp = try XCTUnwrap(TestPhotos.stripes(blurRadius: 0))
        camera.captureQueue = [blurred, sharp, medium]
        let model = makeModel(pro: true)
        await model.start()
        model.toggleBestOfThree()
        await model.captureBestOfThree()
        XCTAssertEqual(library.saved.count, 1)
        XCTAssertEqual(library.saved.first, sharp, "the sharpest of the three photos is the one kept")
        XCTAssertEqual(model.toast, "Saved the sharpest of 3 shots. The others were discarded.")
    }

    func testBestOfThreeWaitsForTheFlashToBeOff() async {
        let model = makeModel(pro: true)
        await model.start()
        model.toggleBestOfThree()
        model.flashMode = .on
        await model.captureBestOfThree()
        XCTAssertTrue(camera.capturedFlashModes.isEmpty)
        XCTAssertEqual(model.toast, "Turn the flash off to use best of three.")
    }
}
