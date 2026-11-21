import Foundation
import XCTest
@testable import CamZ

/// Capture safety: one shutter press at a time, heavy modes switching off under memory pressure, and Stop AI being harmless
/// when no merge runs. The camera and library are mocks, so these run without hardware.
@MainActor
final class CaptureSafetyTests: XCTestCase {

    private var camera: MockCamera!
    private var library: MockLibrary!

    override func setUp() async throws {
        camera = MockCamera()
        library = MockLibrary()
    }

    private func makeModel(pro: Bool = false) -> CameraViewModel {
        CameraViewModel(
            camera: camera,
            library: library,
            renderer: nil,
            store: nil,
            pro: FixedProAccess(pro),
            configuration: AppConfiguration(
                gatedFeatures: AppConfiguration.defaultGatedFeatures,
                monthlyProductID: nil,
                annualProductID: nil,
                privacyPolicyURL: nil,
                termsURL: nil
            ),
            clock: { 100 }
        )
    }

    func testTwoOverlappingShuttersTakeOnePhoto() async {
        // A slow capture, so the second press arrives while the first is still in flight.
        camera.captureDelay = 50_000_000
        let model = makeModel()
        await model.start()
        async let first = model.capture()
        async let second = model.capture()
        let outcomes = await [first, second]
        XCTAssertEqual(library.saved.count, 1, "the second press is refused while the first is in progress")
        XCTAssertEqual(outcomes.filter { $0 }.count, 1, "exactly one press reports a saved photo")
        XCTAssertEqual(model.captureCount, 1)
    }

    func testMemoryWarningSwitchesTheHeavyModesOff() async {
        let model = makeModel(pro: true)
        await model.start()
        model.isHDREnabled = true
        model.isNightModeEnabled = true
        model.handleMemoryWarning()
        XCTAssertFalse(model.isHDREnabled, "HDR is off after a memory warning")
        XCTAssertFalse(model.isNightModeEnabled, "night is off after a memory warning")
        XCTAssertTrue(model.toast?.contains("Memory is low") == true, "the user is told why, got \(model.toast ?? "nil")")
    }

    func testStopAIWithNoMergeRunningChangesNothing() async {
        let model = makeModel()
        await model.start()
        XCTAssertFalse(model.canStopProcessing, "there is nothing to stop before a merge starts")
        model.cancelProcessing()
        await model.capture()
        XCTAssertEqual(library.saved.count, 1, "a press after an ignored stop still takes a photo")
    }
}
