import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import CamZ

/// Regression tests for the photo files the app writes: a merged photo must be upright, keep its capture date, and a
/// stopped merge must give up cleanly rather than return a finished photo.
final class PhotoOutputRegressionTests: XCTestCase {

    private let width = 200
    private let height = 100

    /// Deterministic texture in 8-pixel cells. It never repeats, so alignment cannot mistake a pattern for a shift.
    private func texture(x: Int, y: Int) -> UInt8 {
        var hash = (x / 8) &* 73_856_093 ^ (y / 8) &* 19_349_663
        hash = (hash ^ (hash >> 13)) &* 1_274_126_177
        return UInt8(40 + ((hash >> 8) & 0xBF))
    }

    /// A textured JPEG of 200 × 100 pixels recorded with EXIF orientation 6, so it displays as 100 × 200 once upright.
    /// `shift` moves the texture sideways, as if the camera had moved between frames.
    private func sidewaysJPEG(date: String, shift: Int = 0) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = texture(x: x + shift, y: y)
                let index = (y * width + x) * 4
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: date]
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: exif
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "the test frame should encode")
        return output as Data
    }

    func testMergedPhotoIsUprightAndKeepsItsCaptureDate() throws {
        let frame = try sidewaysJPEG(date: "2024:05:01 12:00:00")
        let merged = try XCTUnwrap(
            ComputedPhoto.night(
                frames: [frame, frame, frame],
                look: FilterEngine(),
                iso: 50,
                highlightClipping: 0,
                shadowClipping: 0,
                context: CIContext()
            ),
            "three identical frames should merge"
        )

        let source = try XCTUnwrap(CGImageSourceCreateWithData(merged as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])

        // The pixels are already upright, so the file must not rotate them a second time.
        let orientation = (properties[kCGImagePropertyOrientation as String] as? Int) ?? 1
        XCTAssertEqual(orientation, 1, "the merged pixels are upright, so the orientation must be reset")
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 100, "upright width")
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 200, "upright height")

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(
            exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            "2024:05:01 12:00:00",
            "the capture date survives the merge"
        )
    }

    func testFramesMovedFarApartAreRefusedRatherThanCroppedAway() throws {
        // A 40-pixel shift is far beyond handheld shake. The merge refuses it instead of cropping the frames down.
        let steady = try sidewaysJPEG(date: "2024:05:01 12:00:00")
        let moved = try sidewaysJPEG(date: "2024:05:01 12:00:00", shift: 40)
        let result = ComputedPhoto.night(
            frames: [steady, moved, steady],
            look: FilterEngine(),
            iso: 50,
            highlightClipping: 0,
            shadowClipping: 0,
            context: CIContext()
        )
        XCTAssertNil(result, "a shake far beyond handheld movement is refused, so the caller keeps one photo")
    }

    func testAMergeThatIsStoppedGivesNoPhoto() async throws {
        let frame = try sidewaysJPEG(date: "2024:05:01 12:00:00")
        let frames = [frame, frame, frame]
        // The task is cancelled while it waits, so the merge starts already stopped and must give up rather than finish.
        let task = Task.detached { () -> Data? in
            while !Task.isCancelled { await Task.yield() }
            return ComputedPhoto.hdr(
                frames: frames,
                reference: 1,
                look: FilterEngine(),
                iso: 50,
                highlightClipping: 0,
                shadowClipping: 0,
                context: CIContext()
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result, "a stopped merge returns no photo, so the caller keeps the normal exposure")
    }
}
