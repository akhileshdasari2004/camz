import CoreImage
import Foundation

/// Measures one captured photo for best-of-three: how sharp the subject is, and whether every measured eye is open.
/// It decodes the photo and runs Vision, so call it off the main thread.
enum ShotAnalyzer {
    /// Side length, in pixels, of the grid the subject region is measured on.
    static let measureSide = 512

    // Shared by every measurement. Core Image contexts can be used from several threads.
    private static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

    /// Nil when the photo cannot be decoded or measured. The caller must treat nil as "not scored", never as a pass.
    static func measure(_ data: Data) -> ShotMeasurement? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let extent = image.extent
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return nil }

        let faces = VisionDetector.faces(in: image)
        let region = subjectRegion(faces: faces, extent: extent)
        guard let grid = ShotSharpness.grayscaleGrid(
            of: image.cropped(to: region),
            side: measureSide,
            context: context
        ) else { return nil }

        return ShotMeasurement(
            sharpness: ShotSharpness.laplacianVariance(grid, width: measureSide, height: measureSide),
            faceCount: faces.count,
            eyesOpen: EyeOpenness.allOpen(faces.map(\.eyeOpenness))
        )
    }

    /// The largest face with a margin around it, or the central half of the frame when there is no face. In pixels.
    static func subjectRegion(faces: [FaceInfo], extent: CGRect) -> CGRect {
        guard let face = faces.first else {
            let side = min(extent.width, extent.height) * 0.5
            return CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
        }
        let box = face.box
        let rect = CGRect(
            x: extent.minX + box.minX * extent.width,
            y: extent.minY + box.minY * extent.height,
            width: box.width * extent.width,
            height: box.height * extent.height
        )
        return rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25).intersection(extent)
    }
}
