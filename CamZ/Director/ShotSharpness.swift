import CoreImage
import CoreImage.CIFilterBuiltins

/// How sharp a frame is, measured on a small grayscale grid. Used only to rank the frames of one burst.
/// The score is relative: compare frames of the same scene, not frames from different scenes.
enum ShotSharpness {
    /// Side length of the grid the frame is reduced to before measuring.
    static let gridSize = 128

    /// Variance of a 4-neighbour Laplacian over a grayscale grid (values 0…1). Flat images score 0; crisp edges score
    /// high. Returns 0 when the grid is too small or does not match its size. Pure.
    static func laplacianVariance(_ pixels: [Float], width: Int, height: Int) -> Float {
        guard width >= 3, height >= 3, pixels.count == width * height else { return 0 }
        var sum: Double = 0
        var sumOfSquares: Double = 0
        var count: Double = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let response = Double(pixels[index - width] + pixels[index + width] + pixels[index - 1] + pixels[index + 1] - 4 * pixels[index])
                sum += response
                sumOfSquares += response * response
                count += 1
            }
        }
        let mean = sum / count
        return Float(max(0, sumOfSquares / count - mean * mean))
    }

    /// The frame as a `side` × `side` grayscale grid (0…1, Rec. 709 luma), or nil when the frame is empty.
    /// Blocking: call off the main thread.
    static func grayscaleGrid(of image: CIImage, side: Int = gridSize, context: CIContext) -> [Float]? {
        let extent = image.extent
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return nil }

        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let luma = CIFilter.colorMatrix()
        luma.inputImage = image.cropped(to: extent)
        luma.rVector = weights
        luma.gVector = weights
        luma.bVector = weights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let gray = luma.outputImage else { return nil }

        // Move the frame to the origin and scale it onto the grid.
        let size = CGFloat(side)
        let placed = gray
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size / extent.width, y: size / extent.height))

        var raw = [Float](repeating: 0, count: side * side * 4)
        raw.withUnsafeMutableBytes { buffer in
            context.render(
                placed,
                toBitmap: buffer.baseAddress!,
                rowBytes: side * 16,
                bounds: CGRect(x: 0, y: 0, width: size, height: size),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        return (0..<(side * side)).map { raw[$0 * 4] }
    }
}
