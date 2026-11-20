import CoreImage

/// Average colour of a frame, used only to judge warm versus cool light.
enum ColorProbe {
    /// Red minus blue of the frame's average colour: about −1 (cool) to +1 (warm). Gamma-encoded values.
    /// Blocking: call off the main thread.
    static func redMinusBlue(of image: CIImage, context: CIContext) -> Float? {
        let extent = image.extent
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return nil }
        guard let average = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])?.outputImage else { return nil }

        var pixel = [Float](repeating: 0, count: 4)
        let target = average.extent
        pixel.withUnsafeMutableBytes { buffer in
            context.render(
                average,
                toBitmap: buffer.baseAddress!,
                rowBytes: 16,
                bounds: CGRect(origin: target.origin, size: CGSize(width: 1, height: 1)),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        return pixel[0] - pixel[2]
    }
}
