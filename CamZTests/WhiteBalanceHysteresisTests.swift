import XCTest
@testable import CamZ

/// The white-balance lock must hold steady. Ordinary variation keeps it, a sustained change releases it after a full run,
/// and people in frame release it at once. Pure, so the hysteresis is tested without a camera.
final class WhiteBalanceHysteresisTests: XCTestCase {

    /// Feeds the same reading `count` times and returns the last decision.
    private func feed(
        _ controller: inout WhiteBalanceController,
        kelvin: Double?,
        atmospheric: Bool = true,
        faces: Int = 0,
        count: Int = 1
    ) -> WhiteBalanceDecision {
        var decision = WhiteBalanceDecision.continuousAuto(reason: "not fed")
        for _ in 0..<count {
            decision = controller.ingest(kelvin: kelvin, atmosphericScene: atmospheric, faceCount: faces)
        }
        return decision
    }

    private func isLocked(_ decision: WhiteBalanceDecision) -> Bool {
        if case .lock = decision { return true }
        return false
    }

    /// A steady sunset lock: enough agreeing warm frames, with no people and an atmospheric scene.
    private func lockedController() -> WhiteBalanceController {
        var controller = WhiteBalanceController()
        let decision = feed(&controller, kelvin: 3_200, count: WhiteBalanceController.requiredStableFrames)
        XCTAssertTrue(isLocked(decision), "steady warm frames set the lock")
        return controller
    }

    func testOrdinaryVariationKeepsTheLock() {
        var controller = lockedController()
        // Readings swing a couple of hundred kelvin either side of the locked light, inside the held spread.
        let swing: [Double] = [3_000, 3_400, 3_100, 3_350, 3_050, 3_300, 3_150, 3_250]
        for kelvin in swing {
            let decision = feed(&controller, kelvin: kelvin)
            XCTAssertTrue(isLocked(decision), "a reading of \(kelvin) K does not release the lock")
        }
        XCTAssertTrue(controller.isLocked)
    }

    func testASustainedChangeReleasesTheLockOnlyAfterTheFullRun() {
        var controller = lockedController()
        // Neutral light fails the hold rules, so the lock lets go only after the whole run of failures.
        for frame in 1..<WhiteBalanceController.releaseAfterFrames {
            let decision = feed(&controller, kelvin: 6_500)
            XCTAssertTrue(isLocked(decision), "frame \(frame) of the change is still inside the hold run")
        }
        let released = feed(&controller, kelvin: 6_500)
        XCTAssertFalse(isLocked(released), "the lock is released after \(WhiteBalanceController.releaseAfterFrames) frames of change")
        XCTAssertFalse(controller.isLocked)
    }

    func testAPersonInFrameReleasesTheLockAtOnce() {
        var controller = lockedController()
        let decision = feed(&controller, kelvin: 3_200, faces: 1)
        XCTAssertFalse(isLocked(decision), "skin tones return to auto on the same frame")
        XCTAssertFalse(controller.isLocked)
    }

    func testTheSceneLeavingAtmosphericKeepsTheLockOnlyForTheRun() {
        var controller = lockedController()
        for _ in 1..<WhiteBalanceController.releaseAfterFrames {
            XCTAssertTrue(isLocked(feed(&controller, kelvin: 3_200, atmospheric: false)), "the run is not yet complete")
        }
        XCTAssertFalse(isLocked(feed(&controller, kelvin: 3_200, atmospheric: false)), "a full run outside the atmosphere releases the lock")
    }

    func testFewUnmeasurableFramesDoNotReleaseTheLock() {
        var controller = lockedController()
        for _ in 0..<5 {
            XCTAssertTrue(isLocked(feed(&controller, kelvin: nil)), "a frame that cannot be measured is not a change of light")
        }
        XCTAssertTrue(controller.isLocked)
    }
}
