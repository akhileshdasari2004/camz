import Foundation
import XCTest
@testable import CamZ

/// The rules behind the photo review: what can be compared, how far the divider and zoom move, what a shared file is
/// called, and what the save status says. Pure, so they are tested without a screen.
final class PhotoReviewLogicTests: XCTestCase {

    func testAComparisonNeedsTwoDifferentPictures() {
        XCTAssertFalse(PhotoReviewLogic.canCompare(enhanced: nil, original: Data([1])))
        XCTAssertFalse(PhotoReviewLogic.canCompare(enhanced: Data([1]), original: nil))
        XCTAssertFalse(PhotoReviewLogic.canCompare(enhanced: Data([1]), original: Data([1])), "identical pictures have nothing to compare")
        XCTAssertFalse(PhotoReviewLogic.canCompare(enhanced: Data(), original: Data([2])), "an empty picture cannot be shown")
        XCTAssertTrue(PhotoReviewLogic.canCompare(enhanced: Data([1]), original: Data([2])))
    }

    func testTheDividerStaysBetweenAllOriginalAndAllEnhanced() {
        XCTAssertEqual(PhotoReviewLogic.clampedSplit(-0.4), 0)
        XCTAssertEqual(PhotoReviewLogic.clampedSplit(1.7), 1)
        XCTAssertEqual(PhotoReviewLogic.clampedSplit(0.25), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PhotoReviewLogic.clampedSplit(.nan), 0.5, "a broken reading centres the divider")
    }

    func testZoomStaysBetweenOneAndFourTimes() {
        XCTAssertEqual(PhotoReviewLogic.clampedZoom(0.2), PhotoReviewLogic.minimumZoom)
        XCTAssertEqual(PhotoReviewLogic.clampedZoom(9), PhotoReviewLogic.maximumZoom)
        XCTAssertEqual(PhotoReviewLogic.clampedZoom(2.5), 2.5, accuracy: 0.0001)
        XCTAssertEqual(PhotoReviewLogic.clampedZoom(.infinity), PhotoReviewLogic.minimumZoom)
    }

    func testTheLeadPictureIsAlwaysThePhotoThatWasTaken() {
        XCTAssertEqual(PhotoReviewLogic.lead(processed: Data([1]), raw: Data([2])), .processed)
        XCTAssertEqual(PhotoReviewLogic.lead(processed: nil, raw: Data([2])), .rawOnly)
        XCTAssertEqual(PhotoReviewLogic.lead(processed: Data(), raw: Data([2])), .rawOnly, "an empty processed photo is not shown")
        XCTAssertEqual(PhotoReviewLogic.lead(processed: nil, raw: nil), .nothing)
    }

    func testSharedFilesGetARealExtension() {
        XCTAssertEqual(PhotoReviewLogic.fileExtension(for: Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        XCTAssertEqual(PhotoReviewLogic.fileExtension(for: Data([0x49, 0x49, 0x2A, 0x00, 0x08])), "dng")
        var heic = Data([0x00, 0x00, 0x00, 0x18])
        heic.append(contentsOf: Array("ftypheic".utf8))
        heic.append(0)
        XCTAssertEqual(PhotoReviewLogic.fileExtension(for: heic), "heic")
        XCTAssertEqual(PhotoReviewLogic.fileExtension(for: Data([1, 2, 3])), "img", "unknown data gets a neutral name")
        XCTAssertEqual(
            PhotoReviewLogic.shareFileName(for: Data([0xFF, 0xD8, 0xFF]), capturedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            "CamZ-1700000000.jpg"
        )
    }

    func testTheSaveStatusSaysWhatToDo() {
        XCTAssertEqual(PhotoReviewLogic.saveStatusText(saved: true, unsavedCount: 0), "Saved to Photos.")
        XCTAssertEqual(PhotoReviewLogic.saveStatusText(saved: false, unsavedCount: 1), "1 photo is not saved yet. Retry to save it to Photos.")
        XCTAssertEqual(PhotoReviewLogic.saveStatusText(saved: false, unsavedCount: 3), "3 photos are not saved yet. Retry to save them to Photos.")
        XCTAssertTrue(
            PhotoReviewLogic.saveStatusText(saved: false, unsavedCount: 1, accessDenied: true).contains("Settings"),
            "a refused permission points at Settings"
        )
    }

    func testTheTitleNamesWhatTheUserSees() {
        XCTAssertEqual(PhotoReviewLogic.title(hasOriginal: true, isRawOnly: false), "AI-enhanced photo")
        XCTAssertEqual(PhotoReviewLogic.title(hasOriginal: false, isRawOnly: false), "Photo")
        XCTAssertEqual(PhotoReviewLogic.title(hasOriginal: false, isRawOnly: true), "RAW file")
    }
}
