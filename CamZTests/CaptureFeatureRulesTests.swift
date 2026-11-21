import CoreGraphics
import Foundation
import XCTest
@testable import CamZ

/// Pure rules for RAW, HDR and night capture, image quality, white balance, the top bar, the hands-free bound and configuration.
/// None of these needs a camera, so they run the same way in CI and on a simulator.
final class CaptureFeatureRulesTests: XCTestCase {

    private let bayer = RawFormatCandidate(code: 1, kind: .bayer)
    private let proRAW = RawFormatCandidate(code: 2, kind: .appleProRAW)

    // MARK: RAW and ProRAW selection

    func testProcessedRequestNeverUsesRAW() {
        let choice = CaptureFormatSelector.choose(format: .processed, alongsideProcessed: true, candidates: [bayer, proRAW], proRAWAllowed: true)
        XCTAssertNil(choice.raw)
        XCTAssertTrue(choice.savesProcessed)
        XCTAssertNil(choice.fallbackReason)
    }

    func testRAWUsesBayerWhenTheCameraOffersIt() {
        let choice = CaptureFormatSelector.choose(format: .raw, alongsideProcessed: false, candidates: [bayer], proRAWAllowed: false)
        XCTAssertEqual(choice.raw, bayer)
        XCTAssertFalse(choice.savesProcessed, "RAW alone saves no processed photo")
        XCTAssertNil(choice.fallbackReason)
    }

    func testRAWKeepsAProcessedCompanionWhenAsked() {
        let choice = CaptureFormatSelector.choose(format: .raw, alongsideProcessed: true, candidates: [bayer], proRAWAllowed: false)
        XCTAssertEqual(choice.raw, bayer)
        XCTAssertTrue(choice.savesProcessed)
    }

    func testRAWFallsBackToProcessedWithAReasonWhenUnsupported() {
        let choice = CaptureFormatSelector.choose(format: .raw, alongsideProcessed: false, candidates: [], proRAWAllowed: false)
        XCTAssertNil(choice.raw)
        XCTAssertTrue(choice.savesProcessed)
        XCTAssertEqual(choice.fallbackReason, CaptureFormatSelector.noRawReason)
    }

    func testProRAWIsUsedOnlyWhenAllowed() {
        let choice = CaptureFormatSelector.choose(format: .proRAW, alongsideProcessed: false, candidates: [bayer, proRAW], proRAWAllowed: true)
        XCTAssertEqual(choice.raw, proRAW)
        XCTAssertNil(choice.fallbackReason)
    }

    func testProRAWFallsBackToBayerWithAReasonWhenNotAllowed() {
        let choice = CaptureFormatSelector.choose(format: .proRAW, alongsideProcessed: false, candidates: [bayer, proRAW], proRAWAllowed: false)
        XCTAssertEqual(choice.raw, bayer)
        XCTAssertEqual(choice.fallbackReason, CaptureFormatSelector.noProRAWReason)
    }

    func testProRAWWithOnlyBayerOnOfferFallsBackWithAReason() {
        let choice = CaptureFormatSelector.choose(format: .proRAW, alongsideProcessed: true, candidates: [bayer], proRAWAllowed: true)
        XCTAssertEqual(choice.raw, bayer)
        XCTAssertTrue(choice.savesProcessed)
        XCTAssertEqual(choice.fallbackReason, CaptureFormatSelector.noProRAWReason)
    }

    func testProRAWWithNothingOnOfferFallsBackToProcessed() {
        let choice = CaptureFormatSelector.choose(format: .proRAW, alongsideProcessed: false, candidates: [], proRAWAllowed: false)
        XCTAssertNil(choice.raw)
        XCTAssertTrue(choice.savesProcessed)
        XCTAssertEqual(choice.fallbackReason, CaptureFormatSelector.noRawReason)
    }

    // MARK: Capture plan (HDR and night)

    private func scene(
        meanLuma: Float = 0.5,
        highlightClipping: Float = 0,
        shadowClipping: Float = 0,
        moving: Bool = false,
        zoom: CGFloat = 1,
        exposure: Double? = 1.0 / 30,
        focal: Float? = 26
    ) -> CaptureScene {
        CaptureScene(
            meanLuma: meanLuma,
            highlightClipping: highlightClipping,
            shadowClipping: shadowClipping,
            subjectMoving: moving,
            displayZoom: zoom,
            exposureSeconds: exposure,
            focalLength35mm: focal
        )
    }

    private let capable = BracketCapability(supported: true, maxFrames: 3)

    func testOrdinaryCaptureStaysSingleWhenNothingIsRequested() {
        let plan = CapturePlanner.plan(scene: scene(), wantsHDR: false, wantsNight: false, capability: capable)
        XCTAssertEqual(plan.strategy, .single)
    }

    func testDarkStillSceneGetsANightBurst() {
        let plan = CapturePlanner.plan(scene: scene(meanLuma: 0.1), wantsHDR: false, wantsNight: true, capability: capable)
        XCTAssertEqual(plan.strategy, .nightBurst(frames: 3), "the burst is capped at what the camera allows")
    }

    func testNightBurstIsRefusedWhenTheSubjectMoves() {
        let plan = CapturePlanner.plan(scene: scene(meanLuma: 0.1, moving: true), wantsHDR: false, wantsNight: true, capability: capable)
        XCTAssertEqual(plan.strategy, .single)
        XCTAssertTrue(plan.reason.contains("moving"))
    }

    func testNightBurstUsesTheMainLensOnly() {
        let plan = CapturePlanner.plan(scene: scene(meanLuma: 0.1, zoom: 2), wantsHDR: false, wantsNight: true, capability: capable)
        XCTAssertEqual(plan.strategy, .single)
        XCTAssertTrue(plan.reason.contains("main lens"))
    }

    func testNightBurstIsRefusedWhenEachFrameWouldBlur() {
        // A 1/4 s exposure on a 26 mm lens is far beyond the handheld limit.
        let plan = CapturePlanner.plan(scene: scene(meanLuma: 0.1, exposure: 0.25), wantsHDR: false, wantsNight: true, capability: capable)
        XCTAssertEqual(plan.strategy, .single)
        XCTAssertTrue(plan.reason.contains("blur"))
    }

    func testNightBurstIsRefusedWithoutAKnownExposure() {
        let plan = CapturePlanner.plan(scene: scene(meanLuma: 0.1, exposure: nil), wantsHDR: false, wantsNight: true, capability: capable)
        XCTAssertEqual(plan.strategy, .single)
    }

    func testNightBurstIsRefusedWithoutBracketSupport() {
        let plan = CapturePlanner.plan(scene: scene(meanLuma: 0.1), wantsHDR: false, wantsNight: true, capability: .none)
        XCTAssertEqual(plan.strategy, .single)
        XCTAssertTrue(plan.reason.contains("bracketed capture"))
    }

    func testStrongContrastGetsAnHDRBracket() {
        let plan = CapturePlanner.plan(
            scene: scene(highlightClipping: 0.05, shadowClipping: 0.2),
            wantsHDR: true,
            wantsNight: false,
            capability: capable
        )
        XCTAssertEqual(plan.strategy, .hdrBracket(evOffsets: [-2, 0, 2]))
    }

    func testFlatSceneDoesNotGetHDR() {
        let plan = CapturePlanner.plan(scene: scene(highlightClipping: 0, shadowClipping: 0), wantsHDR: true, wantsNight: false, capability: capable)
        XCTAssertEqual(plan.strategy, .single)
    }

    func testHDRNeedsThreeBracketFrames() {
        let plan = CapturePlanner.plan(
            scene: scene(highlightClipping: 0.05, shadowClipping: 0.2),
            wantsHDR: true,
            wantsNight: false,
            capability: BracketCapability(supported: true, maxFrames: 2)
        )
        XCTAssertEqual(plan.strategy, .single)
    }

    // MARK: Image quality

    func testCleanImagesGetNoNoiseReduction() {
        XCTAssertEqual(ImageQualityPolicy.noiseLevel(iso: 100), 0)
        XCTAssertEqual(ImageQualityPolicy.noiseLevel(iso: 400), 0)
    }

    func testNoiseReductionGrowsWithIsoButStaysGentle() {
        let mid = ImageQualityPolicy.noiseLevel(iso: 1600)
        let high = ImageQualityPolicy.noiseLevel(iso: 6400)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThanOrEqual(mid, high)
        XCTAssertLessThanOrEqual(high, 0.02, "stronger smoothing would erase detail")
    }

    func testComputedPhotosAreNeverSharpened() {
        XCTAssertEqual(ImageQualityPolicy.sharpness, 0)
    }

    func testHighlightsAreLeftAloneWithoutClipping() {
        XCTAssertEqual(ImageQualityPolicy.highlightAmount(highlightClipping: 0), 1)
        XCTAssertEqual(ImageQualityPolicy.shadowAmount(shadowClipping: 0), 0)
    }

    func testHighlightRecoveryAndShadowLiftAreBounded() {
        XCTAssertGreaterThanOrEqual(ImageQualityPolicy.highlightAmount(highlightClipping: 1), 0.6, "highlights never go grey")
        XCTAssertLessThanOrEqual(ImageQualityPolicy.shadowAmount(shadowClipping: 1), 0.3, "blacks stay black")
    }

    // MARK: Colour temperature and white balance

    func testNeutralLightIsAboutSixThousandFiveHundredKelvin() throws {
        let kelvin = try XCTUnwrap(ColorTemperature.kelvin(AverageColor(red: 0.5, green: 0.5, blue: 0.5)))
        XCTAssertEqual(kelvin, 6500, accuracy: 300)
    }

    func testWarmLightReadsLowerThanNeutral() throws {
        let warm = try XCTUnwrap(ColorTemperature.kelvin(AverageColor(red: 0.8, green: 0.5, blue: 0.2)))
        XCTAssertLessThan(warm, 4000)
    }

    func testDarkFramesHaveNoTemperature() {
        XCTAssertNil(ColorTemperature.kelvin(AverageColor(red: 0, green: 0, blue: 0)))
    }

    private func steadyWarm(_ controller: inout WhiteBalanceController, atmospheric: Bool = true, faces: Int = 0, kelvin: Double = 3000) -> WhiteBalanceDecision {
        var decision = WhiteBalanceDecision.continuousAuto(reason: "")
        for _ in 0..<WhiteBalanceController.requiredStableFrames {
            decision = controller.ingest(kelvin: kelvin, atmosphericScene: atmospheric, faceCount: faces)
        }
        return decision
    }

    func testStableWarmSunsetKeepsHalfItsWarmth() {
        var controller = WhiteBalanceController()
        let decision = steadyWarm(&controller)
        guard case .lock(let target, _) = decision else {
            return XCTFail("a stable warm sunset should lock, got \(decision)")
        }
        XCTAssertEqual(target, 4750, accuracy: 1, "half of the 3500 K gap to neutral is kept")
    }

    func testWhiteBalanceWaitsForAStableRun() {
        var controller = WhiteBalanceController()
        let decision = controller.ingest(kelvin: 3000, atmosphericScene: true, faceCount: 0)
        guard case .continuousAuto = decision else { return XCTFail("one frame is not enough to lock") }
    }

    func testChangingLightNeverLocks() {
        var controller = WhiteBalanceController()
        var decision = WhiteBalanceDecision.continuousAuto(reason: "")
        for index in 0..<WhiteBalanceController.requiredStableFrames {
            decision = controller.ingest(kelvin: index.isMultiple(of: 2) ? 2500 : 4500, atmosphericScene: true, faceCount: 0)
        }
        guard case .continuousAuto = decision else { return XCTFail("a light that keeps changing must not lock") }
    }

    func testPeopleInFrameKeepSkinOnAutoWhiteBalance() {
        var controller = WhiteBalanceController()
        guard case .continuousAuto = steadyWarm(&controller, faces: 1) else {
            return XCTFail("skin tones stay on auto")
        }
    }

    func testNonAtmosphericLightKeepsAutoWhiteBalance() {
        var controller = WhiteBalanceController()
        guard case .continuousAuto = steadyWarm(&controller, atmospheric: false) else {
            return XCTFail("indoor warm light is corrected by auto")
        }
    }

    func testNeutralLightKeepsAutoWhiteBalance() {
        var controller = WhiteBalanceController()
        guard case .continuousAuto = steadyWarm(&controller, kelvin: 6500) else {
            return XCTFail("neutral light needs no lock")
        }
    }

    func testDisabledLockingNeverLocks() {
        var controller = WhiteBalanceController()
        controller.lockingEnabled = false
        guard case .continuousAuto = steadyWarm(&controller) else { return XCTFail("locking is switched off") }
    }

    // MARK: Best-first ranking

    func testRankingPutsOpenEyesThenSharpestFirst() {
        func shot(_ sharpness: Float, _ eyes: Bool?) -> ShotMeasurement {
            ShotMeasurement(sharpness: sharpness, faceCount: eyes == nil ? 0 : 1, eyesOpen: eyes)
        }
        let shots = [shot(0.9, false), shot(0.2, true), shot(0.5, true), shot(0.4, nil)]
        XCTAssertEqual(BestShotRanker.ranking(of: shots), [2, 3, 1, 0])
        XCTAssertEqual(BestShotRanker.ranking(of: shots).first, BestShotRanker.bestIndex(of: shots))
    }

    // MARK: Hands-free time bound

    func testHandsFreeEndsAfterItsSessionTime() {
        var controller = HandsFreeController()
        controller.maxSessionDuration = 10
        controller.enable(now: 100)
        XCTAssertEqual(controller.update(conditionsGood: false, now: 109), .none)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.update(conditionsGood: false, now: 110), .none)
        XCTAssertFalse(controller.isEnabled, "the session time is up")
        XCTAssertEqual(controller.state, .finished)
    }

    // MARK: Top bar fit

    func testTopBarFitsEachCommonIPhoneWidth() {
        // The bar's own width is the screen width minus the 20-point padding on each side.
        let full = TopBarLayout.Style(buttonSize: 44, spacing: 4, showsWordmark: true)
        let narrow = TopBarLayout.Style(buttonSize: 44, spacing: 4, showsWordmark: false)
        XCTAssertEqual(TopBarLayout.style(availableWidth: 430 - 40, rightButtons: 3), full)
        XCTAssertEqual(TopBarLayout.style(availableWidth: 390 - 40, rightButtons: 3), full)
        XCTAssertEqual(TopBarLayout.style(availableWidth: 375 - 40, rightButtons: 3), full)
        XCTAssertEqual(TopBarLayout.style(availableWidth: 320 - 40, rightButtons: 3), full, "the smallest iPhone keeps the wordmark")
        XCTAssertEqual(TopBarLayout.style(availableWidth: 300 - 40, rightButtons: 3), narrow, "narrower than any iPhone drops the wordmark")
    }

    func testTopBarNeverOverflowsItsWidth() {
        // The smallest iPhone is 320 points wide, so the layout is checked from there up.
        for width in stride(from: CGFloat(320), through: 440, by: 5) {
            let style = TopBarLayout.style(availableWidth: width - 40, rightButtons: TopBarLayout.rightButtonCount)
            XCTAssertGreaterThanOrEqual(style.buttonSize, TopBarLayout.minimumTouchTarget, "width \(width)")
            let needed = TopBarLayout.contentWidth(
                buttonSize: style.buttonSize,
                spacing: style.spacing,
                rightButtons: TopBarLayout.rightButtonCount,
                centreWidth: style.showsWordmark ? TopBarLayout.wordmarkWidth : TopBarLayout.zoomReadoutWidth
            )
            XCTAssertLessThanOrEqual(needed, width - 40 - TopBarLayout.safetyGap, "width \(width)")
        }
    }

    // MARK: Configuration

    func testConfigurationDefaultsKeepTodaysProSplit() {
        let config = AppConfiguration.parse([:])
        XCTAssertEqual(config.gatedFeatures, AppConfiguration.defaultGatedFeatures)
        XCTAssertNil(config.monthlyProductID, "missing IDs mean the store is not configured")
        XCTAssertNil(config.privacyPolicyURL, "no legal link is shown until one is configured")
    }

    func testConfigurationReadsGatingLinksAndIDs() {
        let config = AppConfiguration.parse([
            "CamZProMonthlyProductID": " com.example.monthly ",
            "CamZProAnnualProductID": "",
            "CamZPrivacyPolicyURL": "https://example.com/privacy",
            "CamZTermsURL": "http://example.com/terms",
            "CamZProGatedFeatures": ["handsFree", "rawCapture", "nonsense"]
        ])
        XCTAssertEqual(config.monthlyProductID, "com.example.monthly")
        XCTAssertNil(config.annualProductID)
        XCTAssertEqual(config.privacyPolicyURL, URL(string: "https://example.com/privacy"))
        XCTAssertNil(config.termsURL, "only secure links are accepted")
        XCTAssertEqual(config.gatedFeatures, [.handsFree, .rawCapture])
    }

    func testEmptyGatingListGatesNothing() {
        XCTAssertEqual(AppConfiguration.gatedFeatures(from: []), [])
        XCTAssertTrue(EntitlementPolicy.allows(.handsFree, isPro: false, gated: []))
        XCTAssertFalse(EntitlementPolicy.allows(.handsFree, isPro: false, gated: [.handsFree]))
    }
}
