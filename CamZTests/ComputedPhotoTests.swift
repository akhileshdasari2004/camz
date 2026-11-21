import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import CamZ

private extension CIImage {
    /// The same image with its extent starting at zero, which the pixel reader expects.
    func movedToOrigin() -> CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}

/// Runs the computed-photo engine on synthetic images with known answers: alignment after a shift, exposure fusion of
/// brackets, ghost rejection for a moving object, and noise reduction by averaging. Images are generated, not photographed.
final class ComputedPhotoTests: XCTestCase {

    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    private let side = 256

    /// Deterministic per-cell pseudo-random value in 0…1, so the texture is the same on every run.
    private func cellValue(_ cellX: Int, _ cellY: Int, salt: Int = 0) -> Float {
        var hash = cellX &* 73_856_093 ^ cellY &* 19_349_663 ^ salt &* 83_492_791
        hash = (hash ^ (hash >> 13)) &* 1_274_126_177
        return Float(hash & 0xFFFF) / 65_535
    }

    /// Dark on the left, bright on the right, with textured blobs so there are features to align.
    private func baseValue(_ x: Int, _ y: Int) -> Float {
        let edge: Float = x < side / 2 ? 0.05 : 0.9
        let texture = cellValue(x / 8, y / 8) * 0.1
        return edge + texture
    }

    private func makeImage(_ pixel: (Int, Int) -> Float) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let value = UInt8(max(0, min(255, (pixel(x, y) * 255).rounded())))
                let index = (y * side + x) * 4
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return CIImage(cgImage: image)
    }

    private func encode(_ image: CIImage) -> Data {
        context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])!
    }

    /// Mean absolute difference of the red channel, at 128 × 128, over the whole image.
    private func meanDifference(_ a: CIImage, _ b: CIImage) -> Float {
        let first = WorkingPixels.read(a.movedToOrigin(), width: 128, height: 128, context: context)!
        let second = WorkingPixels.read(b.movedToOrigin(), width: 128, height: 128, context: context)!
        var total: Float = 0
        for index in 0..<(128 * 128) {
            total += abs(first[index * 4] - second[index * 4])
        }
        return total / Float(128 * 128)
    }

    /// Mean red value of a rectangle of the 128 × 128 grid.
    private func mean(_ values: [Float], x: Range<Int>, y: Range<Int>) -> Float {
        var total: Float = 0
        var count: Float = 0
        for row in y {
            for column in x {
                total += values[(row * 128 + column) * 4]
                count += 1
            }
        }
        return total / count
    }

    /// Standard deviation of the red channel in the centre 128 × 128 of an image, at native resolution.
    private func standardDeviation(_ image: CIImage) -> Float {
        let centre = image.cropped(to: CGRect(x: 64, y: 64, width: 128, height: 128))
            .transformed(by: CGAffineTransform(translationX: -64, y: -64))
        let values = WorkingPixels.read(centre, width: 128, height: 128, context: context)!
        var total: Float = 0
        var squares: Float = 0
        for index in 0..<(128 * 128) {
            let value = values[index * 4]
            total += value
            squares += value * value
        }
        let count = Float(128 * 128)
        let average = total / count
        return max(0, squares / count - average * average).squareRoot()
    }

    // MARK: Alignment

    func testAlignmentMovesAShiftedFrameBackOntoTheReference() throws {
        let reference = makeImage { x, y in self.baseValue(x, y) }
        let shifted = makeImage { x, y in self.baseValue(x - 6, y + 4) }
        let transform = try XCTUnwrap(FrameAligner.transform(for: shifted, onto: reference), "Vision should find a translation")
        let aligned = shifted.transformed(by: transform).cropped(to: reference.extent)

        // The border is ignored: a shifted frame has no pixels there, which would count as error that alignment cannot remove.
        let inset = CGRect(x: 24, y: 24, width: 208, height: 208)
        let before = meanDifference(reference.cropped(to: inset), shifted.cropped(to: inset))
        let after = meanDifference(reference.cropped(to: inset), aligned.cropped(to: inset))
        XCTAssertLessThan(after, before * 0.5, "alignment should remove most of the shift (before \(before), after \(after))")
    }

    func testAlignedFramesShareOneCommonArea() throws {
        let reference = makeImage { x, y in self.baseValue(x, y) }
        let shifted = makeImage { x, y in self.baseValue(x - 6, y + 4) }
        let aligned = try XCTUnwrap(FrameAligner.aligned([reference, shifted], reference: 0))
        XCTAssertEqual(aligned[0].extent.size, aligned[1].extent.size)
        XCTAssertEqual(aligned[0].extent.origin, .zero, "aligned frames start at the origin")
    }

    // MARK: Exposure fusion

    func testFusionKeepsHighlightsAndLiftsShadows() throws {
        let normal = makeImage { x, y in self.baseValue(x, y) }
        let dark = makeImage { x, y in self.baseValue(x, y) * 0.35 }
        let bright = makeImage { x, y in min(1, self.baseValue(x, y) * 2.2) }
        let fused = try XCTUnwrap(FrameMerge.exposureFusion(frames: [dark, normal, bright], reference: 1, context: context))
        let values = WorkingPixels.read(fused, width: 128, height: 128, context: context)!

        let highlight = mean(values, x: 96..<120, y: 40..<88)
        let shadow = mean(values, x: 8..<32, y: 40..<88)
        XCTAssertLessThan(highlight, 0.97, "bright areas must not be blown out (got \(highlight))")
        XCTAssertGreaterThan(shadow, 0.07, "dark areas must lift above the normal exposure of 0.05 (got \(shadow))")
    }

    func testFusionWithOneFrameIsRefused() {
        let only = makeImage { x, y in self.baseValue(x, y) }
        XCTAssertNil(FrameMerge.exposureFusion(frames: [only], reference: 0, context: context))
    }

    // MARK: Ghosting

    func testAMovingObjectComesFromTheReferenceFrame() {
        // One frame has a bright object that the reference frame does not show. The weights are computed directly on the
        // pixels, so this tests the ghost rule itself and does not depend on what alignment finds in the scene.
        let side = 128
        var withObject = [Float](repeating: 1, count: side * side * 4)
        var background = [Float](repeating: 1, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                let base: Float = x < side / 2 ? 0.2 : 0.7
                let inObject = (20..<40).contains(x) && (40..<60).contains(y)
                let value = inObject ? Float(0.95) : base
                for channel in 0..<3 {
                    withObject[index + channel] = value
                    background[index + channel] = base
                }
            }
        }
        let weights = FusionWeights.compute(pixels: [withObject, background], width: side, height: side, reference: 1)

        let objectPixel = 50 * side + 30
        let backgroundPixel = 10 * side + 10
        XCTAssertLessThan(weights[0][objectPixel], 0.05, "the object frame is not trusted where it differs from the reference")
        XCTAssertGreaterThan(weights[1][objectPixel], 0.95, "the reference frame supplies the object's area")
        XCTAssertEqual(weights[0][backgroundPixel] + weights[1][backgroundPixel], 1, accuracy: 0.001, "weights sum to one")
    }

    // MARK: Night averaging

    func testAveragingFramesReducesNoise() throws {
        // Four frames of one textured scene, each with independent noise. The texture gives Vision features to align on.
        // Averaging should cut the noise, measured against the clean scene, to about half.
        let clean: (Int, Int) -> Float = { x, y in self.baseValue(x, y) }
        let frames = (0..<4).map { salt in
            makeImage { x, y in clean(x, y) + (self.cellValue(x, y, salt: salt + 1) - 0.5) * 0.16 }
        }
        let averaged = try XCTUnwrap(FrameMerge.average(frames: frames))
        let ratio = residual(averaged, clean: clean) / residual(frames[0], clean: clean)
        XCTAssertLessThan(ratio, 0.75, "four frames should cut noise to about half (ratio \(ratio))")
    }

    /// Root-mean-square difference from the clean scene, over the centre 128 × 128 at native resolution.
    private func residual(_ image: CIImage, clean: (Int, Int) -> Float) -> Float {
        let centre = image.cropped(to: CGRect(x: 64, y: 64, width: 128, height: 128))
            .transformed(by: CGAffineTransform(translationX: -64, y: -64))
        let values = WorkingPixels.read(centre, width: 128, height: 128, context: context)!
        var total: Float = 0
        for y in 0..<128 {
            for x in 0..<128 {
                let difference = values[(y * 128 + x) * 4] - clean(x + 64, y + 64)
                total += difference * difference
            }
        }
        return (total / Float(128 * 128)).squareRoot()
    }

    // MARK: Encoded output

    func testMergedPhotoIsEncodedAndDecodes() throws {
        let frames = [
            encode(makeImage { x, y in self.baseValue(x, y) * 0.35 }),
            encode(makeImage { x, y in self.baseValue(x, y) }),
            encode(makeImage { x, y in min(1, self.baseValue(x, y) * 2.2) })
        ]
        let merged = try XCTUnwrap(ComputedPhoto.hdr(
            frames: frames,
            reference: 1,
            look: FilterEngine(),
            iso: 100,
            highlightClipping: 0.05,
            shadowClipping: 0.1,
            context: context
        ))
        let decoded = try XCTUnwrap(CIImage(data: merged))
        XCTAssertEqual(decoded.extent.width, CGFloat(side), accuracy: 1)
        XCTAssertEqual(decoded.extent.height, CGFloat(side), accuracy: 1)
    }

    func testUndecodableFramesGiveNoPhoto() {
        let junk = Data([0x1, 0x2, 0x3])
        XCTAssertNil(ComputedPhoto.hdr(frames: [junk, junk], reference: 0, look: FilterEngine(), iso: 100, highlightClipping: 0, shadowClipping: 0, context: context))
        XCTAssertNil(ComputedPhoto.night(frames: [junk, junk], look: FilterEngine(), iso: 100, highlightClipping: 0, shadowClipping: 0, context: context))
    }

    func testExposureBiasIsReadFromEXIF() {
        XCTAssertNil(ExposureBias.read(from: Data([0x1, 0x2])), "data without EXIF has no bias")
    }
}
