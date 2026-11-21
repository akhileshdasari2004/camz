import CoreImage

/// Average colour of a frame, used for warm versus cool light and for white-balance classification.
enum ColorProbe {
    /// The frame's average colour, gamma-encoded, 0…1 per channel. Nil when the frame is empty.
    /// Blocking: call off the main thread.
    static func averageColor(of image: CIImage, context: CIContext) -> AverageColor? {
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
        return AverageColor(red: pixel[0], green: pixel[1], blue: pixel[2])
    }

    /// Red minus blue of the frame's average colour: about −1 (cool) to +1 (warm). Gamma-encoded values.
    /// Blocking: call off the main thread.
    static func redMinusBlue(of image: CIImage, context: CIContext) -> Float? {
        averageColor(of: image, context: context).map { $0.red - $0.blue }
    }
}
