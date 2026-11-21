import Foundation
import XCTest
@testable import CamZ

/// The view model's RAW, HDR, night, best-of-three and gating behaviour, with the mock camera and library.
@MainActor
final class CaptureFeatureModelTests: XCTestCase {

    private var camera: MockCamera!
    private var library: MockLibrary!

    override func setUp() async throws {
        camera = MockCamera()
        library = MockLibrary()
    }

    private func config(gated: Set<ProFeature>) -> AppConfiguration {
        AppConfiguration(gatedFeatures: gated, monthlyProductID: nil, annualProductID: nil, privacyPolicyURL: nil, termsURL: nil)
    }

    private func makeModel(
        pro: Bool = false,
        gated: Set<ProFeature> = AppConfiguration.defaultGatedFeatures,
        store: StoreService? = nil
    ) -> CameraViewModel {
        CameraViewModel(
            camera: camera,
            library: library,
            renderer: nil,
            store: store,
            pro: FixedProAccess(pro),
            configuration: config(gated: gated),
            clock: { 100 }
        )
    }

    /// A frame with strong contrast: both ends clipped, so an HDR bracket is planned.
    private func contrastyDecision() -> PhotoDecision {
        var decision = PhotoDecision()
        decision.readiness = .steady
        decision.exposure = ExposureAssessment(
            subjectMean: 0.5,
            frameMean: 0.5,
            highlightClipping: 0.05,
            shadowClipping: 0.2,
            status: .highlightsClipping,
            suggestedBiasDelta: 0
        )
        return decision
    }

    /// A dark frame, which asks for a night burst when night mode is on.
    private func darkDecision() -> PhotoDecision {
        var decision = PhotoDecision()
        decision.readiness = .steady
        decision.exposure = ExposureAssessment(
            subjectMean: 0.05,
            frameMean: 0.05,
            highlightClipping: 0,
            shadowClipping: 0.5,
            status: .shadowsClipping,
            suggestedBiasDelta: 0
        )
        return decision
    }

    // MARK: Options and defaults

    func testCaptureOptionsDefaultToOneTapCapture() {
        let model = makeModel()
        XCTAssertEqual(model.captureFormat, .processed)
        XCTAssertFalse(model.isHDREnabled)
        XCTAssertFalse(model.isNightModeEnabled)
    }

    // MARK: RAW and ProRAW

    func testRAWFallsBackToAProcessedPhotoWithAReasonWhenTheCameraHasNoRAW() async {
        let model = makeModel()
        await model.start()
        model.captureFormat = .raw
        await model.capture()
        XCTAssertEqual(camera.captureRequests.last, CaptureRequest(format: .raw, alongsideProcessed: true))
        XCTAssertNil(library.savedCaptures.last?.raw)
        XCTAssertNotNil(library.savedCaptures.last?.processed)
        XCTAssertEqual(model.toast, CaptureFormatSelector.noRawReason)
    }

    func testRAWSavesAFileWithItsProcessedPairWhenSupported() async {
        camera.rawSupport = RawCapabilities(candidates: [RawFormatCandidate(code: 1, kind: .bayer)], proRAWAllowed: false)
        let model = makeModel()
        await model.start()
        model.captureFormat = .raw
        await model.capture()
        XCTAssertNotNil(library.savedCaptures.last?.raw)
        XCTAssertNotNil(library.savedCaptures.last?.processed)
        XCTAssertNil(model.toast, "nothing fell back, so nothing needs saying")
    }

    func testProRAWFallsBackToBayerWithAReasonWhenProRAWIsOff() async {
        camera.rawSupport = RawCapabilities(candidates: [RawFormatCandidate(code: 1, kind: .bayer)], proRAWAllowed: false)
        let model = makeModel()
        await model.start()
        model.captureFormat = .proRAW
        XCTAssertEqual(model.formatNote(), CaptureFormatSelector.noProRAWReason)
        await model.capture()
        XCTAssertNotNil(library.savedCaptures.last?.raw)
        XCTAssertEqual(model.toast, CaptureFormatSelector.noProRAWReason)
    }

    func testRAWNeedsNoPurchaseByDefault() async {
        let model = makeModel(pro: false)
        await model.start()
        model.captureFormat = .raw
        await model.capture()
        XCTAssertFalse(model.isPaywallPresented)
    }

    func testRAWCanBeGatedByConfigurationWithoutChangingCameraCode() async {
        let model = makeModel(pro: false, gated: [.rawCapture])
        await model.start()
        model.captureFormat = .raw
        await model.capture()
        XCTAssertTrue(model.isPaywallPresented)
        XCTAssertEqual(camera.captureRequests.last?.format, .processed, "the gated request is replaced by a standard capture")
    }

    func testFormatNoteIsNilWhenTheFormatIsAvailable() {
        camera.rawSupport = RawCapabilities(candidates: [RawFormatCandidate(code: 1, kind: .bayer)], proRAWAllowed: false)
        let model = makeModel()
        model.captureFormat = .raw
        XCTAssertNil(model.formatNote())
    }

    // MARK: HDR and night

    func testHDRIsPlannedAndFallsBackWhenTheMergeCannotRun() async {
        camera.bracketSupport = BracketCapability(supported: true, maxFrames: 3)
        camera.bracketResult = .success([Data([0x1]), Data([0x2])]) // not decodable, so the merge cannot run
        let model = makeModel()
        await model.start()
        model.isHDREnabled = true
        model.apply(contrastyDecision())
        await model.capture()
        XCTAssertEqual(camera.bracketOffsetCalls, [[-2, 0, 2]])
        XCTAssertEqual(library.saved.count, 1, "the normal exposure is saved")
        XCTAssertEqual(model.toast, "The frames could not be aligned, so the normal exposure was saved.")
    }

    func testHDRFallsBackToOnePhotoWhenBracketingFails() async {
        camera.bracketSupport = BracketCapability(supported: true, maxFrames: 3)
        camera.bracketResult = .failure(TestError())
        let model = makeModel()
        await model.start()
        model.isHDREnabled = true
        model.apply(contrastyDecision())
        await model.capture()
        XCTAssertEqual(library.saved.count, 1)
        XCTAssertEqual(model.toast, "Bracketed capture is not available right now, so one photo was taken.")
    }

    func testHDRIsRefusedWithAReasonWhenBracketingIsUnavailable() async {
        let model = makeModel()
        await model.start()
        model.isHDREnabled = true
        model.apply(contrastyDecision())
        await model.capture()
        XCTAssertTrue(camera.bracketOffsetCalls.isEmpty)
        XCTAssertEqual(library.saved.count, 1)
        XCTAssertTrue(model.toast?.contains("not available on this camera") == true, "the reason is shown, got \(model.toast ?? "nil")")
    }

    func testNightBurstIsRefusedWithAReasonWhenTheExposureIsUnknown() async {
        camera.bracketSupport = BracketCapability(supported: true, maxFrames: 3)
        let model = makeModel()
        await model.start()
        model.isNightModeEnabled = true
        model.apply(darkDecision())
        await model.capture()
        XCTAssertTrue(camera.bracketOffsetCalls.isEmpty, "no burst without a known exposure")
        XCTAssertEqual(library.saved.count, 1)
        XCTAssertTrue(model.toast?.contains("exposure time") == true, "got \(model.toast ?? "nil")")
    }

    // MARK: Best of three

    func testBestOfThreeSavesTheNextBestWhenTheSharpestCannotBeSaved() async throws {
        let blurred = try XCTUnwrap(TestPhotos.stripes(blurRadius: 6))
        let medium = try XCTUnwrap(TestPhotos.stripes(blurRadius: 1.5))
        let sharp = try XCTUnwrap(TestPhotos.stripes(blurRadius: 0))
        camera.captureQueue = [blurred, sharp, medium]
        library.failuresBeforeSuccess = 1
        let model = makeModel(pro: true)
        await model.start()
        model.toggleBestOfThree()
        await model.captureBestOfThree()
        XCTAssertEqual(library.saved.count, 1)
        XCTAssertEqual(library.saved.first, medium, "the next best shot is saved when the sharpest fails")
        XCTAssertEqual(model.toast, "The sharpest shot could not be saved, so the next best was saved. The others were discarded.")
    }

    func testBestOfThreeSaysSoWhenNoShotCanBeSaved() async {
        library.failuresBeforeSuccess = 3
        let model = makeModel(pro: true)
        await model.start()
        model.toggleBestOfThree()
        await model.captureBestOfThree()
        XCTAssertTrue(library.saved.isEmpty)
        XCTAssertEqual(model.captureCount, 0)
        XCTAssertTrue(model.toast?.hasPrefix("None of the 3 shots could be saved.") == true, "got \(model.toast ?? "nil")")
    }

    // MARK: Missing product IDs and the free camera

    func testMissingProductIDsNeverBlockTheCamera() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CamZTests.\(UUID().uuidString)"))
        let store = StoreService(productIDs: [], defaults: defaults)
        let model = makeModel(pro: false, store: store)
        await model.start()
        XCTAssertEqual(store.loadState, .notConfigured)
        await model.capture()
        XCTAssertEqual(library.saved.count, 1, "ordinary capture works without a store")
        model.toggleMode()
        XCTAssertTrue(model.isPaywallPresented, "Pro features still show the paywall, which explains that Pro is not set up")
    }

    func testHandsFreeCanBeFreeWhenTheGatingIsRemoved() async {
        let model = makeModel(pro: false, gated: [])
        await model.start()
        model.toggleHandsFree()
        XCTAssertTrue(model.isHandsFreeOn)
        XCTAssertFalse(model.isPaywallPresented)
    }

    // MARK: White balance

    func testWhiteBalanceLockIsSentOnlyWhenItChanges() async {
        let model = makeModel()
        await model.start()
        for _ in 0..<(WhiteBalanceController.requiredStableFrames + 4) {
            var decision = PhotoDecision()
            decision.readiness = .steady
            decision.colorTemperature = 3000
            decision.atmosphericLight = true
            decision.faceCount = 0
            model.apply(decision)
        }
        XCTAssertEqual(camera.whiteBalanceLocks.count, 1, "the lock is sent once, not on every frame")
        if let first = camera.whiteBalanceLocks.first, let kelvin = first {
            XCTAssertEqual(kelvin, 4750, accuracy: 1)
        } else {
            XCTFail("a stable warm sunset should lock white balance")
        }
    }
}
