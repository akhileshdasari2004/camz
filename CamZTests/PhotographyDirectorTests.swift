import CoreImage
import XCTest
@testable import CamZ

final class PhotographyDirectorTests: XCTestCase {

    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

    private func solid(_ grey: CGFloat, size: CGFloat = 120) -> CIImage {
        CIImage(color: CIColor(red: grey, green: grey, blue: grey))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func histogram(_ grey: CGFloat) -> LuminanceHistogram {
        ExposureAnalyzer.histogram(of: solid(grey), context: context)!
    }

    // MARK: Exposure

    func testHistogramMeanMatchesGrey() {
        XCTAssertEqual(histogram(0.42).mean, 0.42, accuracy: 0.01)
    }

    func testMidGreyIsBalancedWithNoChange() {
        let assessment = ExposureAnalyzer.assess(frame: histogram(0.42), subject: nil)
        XCTAssertEqual(assessment.status, .balanced)
        XCTAssertEqual(assessment.suggestedBiasDelta, 0)
    }

    func testDarkFrameAsksForMoreExposure() {
        let assessment = ExposureAnalyzer.assess(frame: histogram(0.08), subject: nil)
        XCTAssertTrue(assessment.status == .underexposed || assessment.status == .shadowsClipping)
        XCTAssertGreaterThan(assessment.suggestedBiasDelta, 0)
        XCTAssertLessThanOrEqual(assessment.suggestedBiasDelta, ExposureAnalyzer.maxStep)
    }

    func testBlownFrameProtectsHighlights() {
        let assessment = ExposureAnalyzer.assess(frame: histogram(1.0), subject: nil)
        XCTAssertEqual(assessment.status, .highlightsClipping)
        XCTAssertLessThanOrEqual(assessment.suggestedBiasDelta, -ExposureAnalyzer.deadband)
    }

    func testDarkSubjectRaisesExposureEvenWhenFrameAverageIsFine() {
        let assessment = ExposureAnalyzer.assess(frame: histogram(0.42), subject: histogram(0.1))
        XCTAssertGreaterThan(assessment.suggestedBiasDelta, 0)
        XCTAssertEqual(assessment.subjectMean, 0.1, accuracy: 0.02)
    }

    func testRegionHistogramOnlyCountsTheRegion() throws {
        let left = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 60, height: 120))
        let frame = left.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 60, y: 0, width: 60, height: 120)))
        let region = try XCTUnwrap(ExposureAnalyzer.histogram(of: frame, in: CGRect(x: 0, y: 0, width: 60, height: 120), context: context))
        XCTAssertGreaterThan(region.highlightClipping, 0.95)
    }

    // MARK: Scene and lighting

    func testLargeFaceIsPortrait() {
        XCTAssertEqual(SceneClassifier.scene(labels: [], faceCount: 1, faceAreaFraction: 0.1, frameMean: 0.5), .portrait)
    }

    func testTinyFaceIsNotPortrait() {
        XCTAssertNotEqual(SceneClassifier.scene(labels: [], faceCount: 1, faceAreaFraction: 0.01, frameMean: 0.5), .portrait)
    }

    func testLabelsDriveSceneAndDarkFramesAreNight() {
        let food = [ClassifiedLabel(identifier: "food_and_drink", confidence: 0.6)]
        XCTAssertEqual(SceneClassifier.scene(labels: food, faceCount: 0, faceAreaFraction: 0, frameMean: 0.5), .food)
        XCTAssertEqual(SceneClassifier.scene(labels: food, faceCount: 0, faceAreaFraction: 0, frameMean: 0.05), .night)
    }

    func testWeakLabelsAreIgnored() {
        let weak = [ClassifiedLabel(identifier: "food", confidence: 0.05)]
        XCTAssertEqual(SceneClassifier.scene(labels: weak, faceCount: 0, faceAreaFraction: 0, frameMean: 0.5), .general)
    }

    func testHarshLightNeedsClippingNotDarkness() {
        XCTAssertEqual(SceneClassifier.lighting(frameMean: 0.1, highlightClipping: 0, shadowClipping: 0.9), .dark)
        XCTAssertEqual(SceneClassifier.lighting(frameMean: 0.5, highlightClipping: 0.2, shadowClipping: 0), .harsh)
    }

    // MARK: Lens

    func testSmallFaceMovesToTelephoto() {
        let presets: [CGFloat] = [0.5, 1, 2, 3]
        XCTAssertEqual(LensSelector.recommendedZoom(scene: .portrait, faceAreaFraction: 0.03, current: 1, presets: presets), 2)
        XCTAssertEqual(LensSelector.recommendedZoom(scene: .portrait, faceAreaFraction: 0.03, current: 1, presets: [0.5, 1]), 1)
    }

    func testWideScenesReturnToMainLens() {
        let presets: [CGFloat] = [0.5, 1, 2, 3]
        XCTAssertEqual(LensSelector.recommendedZoom(scene: .landscape, faceAreaFraction: 0, current: 2, presets: presets), 1)
        XCTAssertEqual(LensSelector.recommendedZoom(scene: .general, faceAreaFraction: 0, current: 3, presets: presets), 3)
    }

    // MARK: Composition

    func testTiltedHorizonIsLevelled() {
        XCTAssertEqual(CompositionAnalyzer.advice(horizonDegrees: 5, faceCount: 0, faceCenterX: nil), .levelHorizon(degrees: 5))
        XCTAssertEqual(CompositionAnalyzer.advice(horizonDegrees: 0.5, faceCount: 0, faceCenterX: nil), .none)
        XCTAssertEqual(CompositionAnalyzer.advice(horizonDegrees: 40, faceCount: 0, faceCenterX: nil), .none)
    }

    func testCentredSingleFaceGetsOffsetAdvice() {
        XCTAssertEqual(CompositionAnalyzer.advice(horizonDegrees: nil, faceCount: 1, faceCenterX: 0.5), .offsetSubject)
        XCTAssertEqual(CompositionAnalyzer.advice(horizonDegrees: nil, faceCount: 1, faceCenterX: 0.3), .none)
    }

    // MARK: Stability and readiness

    func testStabilizerNeedsConsistentValues() {
        var stabilizer = Stabilizer<SceneKind>(required: 3)
        XCTAssertNil(stabilizer.ingest(.food))
        XCTAssertNil(stabilizer.ingest(.food))
        XCTAssertEqual(stabilizer.ingest(.food), .food)
        XCTAssertEqual(stabilizer.ingest(.portrait), .food, "one noisy value does not flip the decision")
    }

    func testMotionMeasuresChange() {
        let grey = [UInt8](repeating: 128, count: 256)
        XCTAssertEqual(FrameMotion.difference(grey, grey), 0)
        XCTAssertGreaterThan(FrameMotion.difference(grey, [UInt8](repeating: 0, count: 256)), 0.4)
    }

    func testReadinessNeedsCalmFramesAndNoSettling() {
        var engine = CaptureDecisionEngine()
        XCTAssertEqual(engine.ingest(motion: 0.5, settling: false), .moving)
        XCTAssertEqual(engine.ingest(motion: 0, settling: false), .moving)
        XCTAssertEqual(engine.ingest(motion: 0, settling: false), .moving)
        XCTAssertEqual(engine.ingest(motion: 0, settling: false), .steady)
        XCTAssertEqual(engine.ingest(motion: 0, settling: true), .settling)
    }

    // MARK: Director

    /// The throttle is tested directly. The Vision pipeline is too slow on simulators to test within a unit-test timeout.
    func testThrottleAdmitsOneAnalysisAtATimeAndPacesThem() {
        var throttle = AnalysisThrottle(interval: 0.2)
        XCTAssertTrue(throttle.tryStart(now: 1))
        XCTAssertFalse(throttle.tryStart(now: 1.05), "busy: the next frame is dropped")
        throttle.finish()
        XCTAssertFalse(throttle.tryStart(now: 1.1), "too soon after the last analysis")
        XCTAssertTrue(throttle.tryStart(now: 1.3))
    }
}
