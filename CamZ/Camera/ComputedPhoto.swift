import CoreImage
import Foundation
import ImageIO
import Vision

/// Reads the exposure bias the camera recorded for a frame, so bracketed frames can be put in order.
enum ExposureBias {
    /// The EV bias from the frame's EXIF data, or nil when the file does not record it.
    static func read(from data: Data) -> Double? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
            let bias = exif[kCGImagePropertyExifExposureBiasValue as String] as? Double
        else { return nil }
        return bias
    }
}

/// Aligns handheld frames to one another. Translation only: a few pixels of hand shake. Rotation between frames is not
/// corrected, so the merge fails rather than ghosting when the shake is larger than that.
enum FrameAligner {
    /// The transform that moves `target` onto `reference`, or nil when Vision cannot align the pair.
    static func transform(for target: CIImage, onto reference: CIImage) -> CGAffineTransform? {
        // Vision allocates heavily per request. A pool per frame releases that memory before the next frame.
        autoreleasepool { () -> CGAffineTransform? in
            let request = VNTranslationalImageRegistrationRequest(targetedCIImage: target, options: [:])
            let handler = VNImageRequestHandler(ciImage: reference, options: [:])
            guard (try? handler.perform([request])) != nil, let observation = request.results?.first else { return nil }
            return observation.alignmentTransform
        }
    }

    /// Largest shift accepted, as a share of the shorter side. Handheld shake is a few pixels, so a larger shift is a false match,
    /// such as a repeating pattern, and the merge is refused rather than cropped down to almost nothing.
    static let maximumShiftFraction: CGFloat = 0.1

    /// Aligned frames, all cropped to the area every frame covers and moved to the origin, so later steps share one
    /// coordinate system. Nil when a frame cannot be aligned or the shared area is too small.
    static func aligned(_ frames: [CIImage], reference: Int) -> [CIImage]? {
        guard frames.count >= 2, frames.indices.contains(reference) else { return nil }
        let anchor = frames[reference]
        let maximumShift = maximumShiftFraction * min(anchor.extent.width, anchor.extent.height)
        var moved: [CIImage] = []
        for (index, frame) in frames.enumerated() {
            // A stopped capture gives up between frames rather than finishing the whole merge.
            guard !Task.isCancelled else { return nil }
            if index == reference {
                moved.append(frame)
                continue
            }
            guard let transform = transform(for: frame, onto: anchor) else { return nil }
            guard abs(transform.tx) <= maximumShift, abs(transform.ty) <= maximumShift else { return nil }
            moved.append(frame.transformed(by: transform))
        }
        let common = moved.dropFirst().reduce(moved[0].extent) { $0.intersection($1.extent) }
        guard !common.isEmpty, common.width > 16, common.height > 16 else { return nil }
        let toOrigin = CGAffineTransform(translationX: -common.minX, y: -common.minY)
        return moved.map { $0.cropped(to: common).transformed(by: toOrigin) }
    }
}

/// Reads an image into a small float grid, for the weight calculations. Values are gamma-encoded, 0…1.
enum WorkingPixels {
    /// RGBA floats, four per pixel, row by row. Renders with the same colour handling as the rest of the app.
    static func read(_ image: CIImage, width: Int, height: Int, context: CIContext) -> [Float]? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        var buffer = [Float](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            context.render(
                scaled,
                toBitmap: raw.baseAddress!,
                rowBytes: width * 16,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        return buffer
    }

    /// A grayscale-valued image (alpha 1) built from per-pixel values, in the same row order `read` uses.
    static func image(fromValues values: [Float], width: Int, height: Int) -> CIImage {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for index in 0..<(width * height) {
            rgba[index * 4] = values[index]
            rgba[index * 4 + 1] = values[index]
            rgba[index * 4 + 2] = values[index]
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
    }
}

/// Exposure-fusion weights for bracketed frames. Pure arithmetic over the working grid, so it is tested directly.
enum FusionWeights {
    /// Per-frame weights, normalised so that the frames sum to one at every pixel.
    ///
    /// Each frame is scored on contrast, colour saturation and how well exposed it is (Mertens et al.). A frame that
    /// disagrees with the reference frame in a spot (a moving person, a passing car) is trusted less there, so that spot
    /// comes from the reference frame and does not ghost.
    static func compute(pixels: [[Float]], width: Int, height: Int, reference: Int) -> [[Float]] {
        let count = width * height
        var lumas: [[Float]] = []
        for values in pixels {
            var luma = [Float](repeating: 0, count: count)
            for index in 0..<count {
                let r: Float = values[index * 4]
                let g: Float = values[index * 4 + 1]
                let b: Float = values[index * 4 + 2]
                luma[index] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
            lumas.append(luma)
        }

        var weights: [[Float]] = []
        for (frame, values) in pixels.enumerated() {
            let luma = lumas[frame]
            var weight = [Float](repeating: 0, count: count)
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let r = values[index * 4]
                    let g = values[index * 4 + 1]
                    let b = values[index * 4 + 2]
                    let mean = (r + g + b) / 3
                    let spread = square(r - mean) + square(g - mean) + square(b - mean)
                    let saturation = (spread / 3).squareRoot()
                    let distance = square(r - 0.5) + square(g - 0.5) + square(b - 0.5)
                    let exposure = exp(-distance / 0.08)
                    let left = luma[y * width + max(x - 1, 0)]
                    let right = luma[y * width + min(x + 1, width - 1)]
                    let up = luma[max(y - 1, 0) * width + x]
                    let down = luma[min(y + 1, height - 1) * width + x]
                    let contrast = abs(4 * luma[index] - left - right - up - down)
                    weight[index] = (contrast + 1e-3) * (saturation + 1e-3) * (exposure + 1e-3)
                }
            }
            weights.append(weight)
        }

        for frame in 0..<pixels.count where frame != reference {
            for index in 0..<count {
                let disagreement = abs(lumas[frame][index] - lumas[reference][index])
                weights[frame][index] *= 1 - smoothStep(0.06, 0.18, disagreement)
            }
        }

        for index in 0..<count {
            var total: Float = 0
            for frame in 0..<weights.count { total += weights[frame][index] }
            for frame in 0..<weights.count {
                weights[frame][index] = total > 0 ? weights[frame][index] / total : (frame == reference ? 1 : 0)
            }
        }
        return weights
    }

    private static func square(_ value: Float) -> Float {
        value * value
    }

    static func smoothStep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Merges bracketed exposures and averages night frames.
enum FrameMerge {
    /// Longest side of the grid the weights are computed on. Weights are smooth, so this loses no visible detail.
    static let workingSide: CGFloat = 640

    /// Exposure fusion of aligned frames. Nil when the frames cannot be aligned or merged.
    static func exposureFusion(frames: [CIImage], reference: Int, context: CIContext) -> CIImage? {
        guard let aligned = FrameAligner.aligned(frames, reference: reference) else { return nil }
        let extent = aligned[0].extent
        let scale = min(1, workingSide / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))

        var pixels: [[Float]] = []
        for frame in aligned {
            guard !Task.isCancelled else { return nil }
            // Each frame is rendered inside its own pool, so the working copies do not pile up across frames.
            guard let values = autoreleasepool(invoking: { WorkingPixels.read(frame, width: width, height: height, context: context) }) else { return nil }
            pixels.append(values)
        }
        guard !Task.isCancelled else { return nil }
        let weights = FusionWeights.compute(pixels: pixels, width: width, height: height, reference: reference)

        var total: CIImage?
        for (index, frame) in aligned.enumerated() {
            guard !Task.isCancelled else { return nil }
            let weightImage = WorkingPixels.image(fromValues: weights[index], width: width, height: height)
                .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            guard let product = CIFilter(name: "CIMultiplyBlendMode", parameters: [
                kCIInputImageKey: frame,
                kCIInputBackgroundImageKey: weightImage
            ])?.outputImage else { return nil }
            if let running = total {
                total = CIFilter(name: "CIAdditionCompositing", parameters: [
                    kCIInputImageKey: product,
                    kCIInputBackgroundImageKey: running
                ])?.outputImage
            } else {
                total = product
            }
        }
        return total?.cropped(to: extent)
    }

    /// Average of aligned frames taken at the same exposure. Averaging N frames lowers random noise by about the square root of N.
    static func average(frames: [CIImage]) -> CIImage? {
        guard let aligned = FrameAligner.aligned(frames, reference: 0) else { return nil }
        let scale = 1 / CGFloat(aligned.count)
        var total: CIImage?
        for frame in aligned {
            guard !Task.isCancelled else { return nil }
            let scaled = frame.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            if let running = total {
                total = CIFilter(name: "CIAdditionCompositing", parameters: [
                    kCIInputImageKey: scaled,
                    kCIInputBackgroundImageKey: running
                ])?.outputImage
            } else {
                total = scaled
            }
        }
        return total?.cropped(to: aligned[0].extent)
    }
}

/// Turns merged frames into a photo file: decodes the frames, applies the look and the quality policy, and encodes the
/// result with the reference frame's metadata. Every entry point returns nil rather than a partial photo.
enum ComputedPhoto {
    /// Merges bracketed frames (encoded data) into one processed photo. `reference` is the index of the normal-exposure frame.
    static func hdr(
        frames: [Data],
        reference: Int,
        look: FilterEngine,
        iso: Float,
        highlightClipping: Float,
        shadowClipping: Float,
        context: CIContext
    ) -> Data? {
        let images = decode(frames)
        guard images.count == frames.count, reference < images.count, !Task.isCancelled else { return nil }
        guard let merged = FrameMerge.exposureFusion(frames: images, reference: reference, context: context) else { return nil }
        guard !Task.isCancelled else { return nil }
        return finish(merged, look: look, iso: iso, highlightClipping: highlightClipping, shadowClipping: shadowClipping,
                      metadataFrom: frames[reference], context: context)
    }

    /// Averages a night burst of encoded frames into one processed photo.
    static func night(
        frames: [Data],
        look: FilterEngine,
        iso: Float,
        highlightClipping: Float,
        shadowClipping: Float,
        context: CIContext
    ) -> Data? {
        let images = decode(frames)
        guard images.count == frames.count, !Task.isCancelled, let averaged = FrameMerge.average(frames: images) else { return nil }
        guard !Task.isCancelled else { return nil }
        return finish(averaged, look: look, iso: iso, highlightClipping: highlightClipping, shadowClipping: shadowClipping,
                      metadataFrom: frames[0], context: context)
    }

    private static func decode(_ frames: [Data]) -> [CIImage] {
        frames.compactMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
    }

    private static func finish(
        _ image: CIImage,
        look: FilterEngine,
        iso: Float,
        highlightClipping: Float,
        shadowClipping: Float,
        metadataFrom reference: Data,
        context: CIContext
    ) -> Data? {
        var output = look.apply(to: image)
        let noise = ImageQualityPolicy.noiseLevel(iso: iso)
        if noise > 0, let filter = CIFilter(name: "CINoiseReduction") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(noise, forKey: "inputNoiseLevel")
            filter.setValue(ImageQualityPolicy.sharpness, forKey: "inputSharpness")
            output = filter.outputImage ?? output
        }
        if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(ImageQualityPolicy.highlightAmount(highlightClipping: highlightClipping), forKey: "inputHighlightAmount")
            filter.setValue(ImageQualityPolicy.shadowAmount(shadowClipping: shadowClipping), forKey: "inputShadowAmount")
            output = filter.outputImage ?? output
        }

        let properties = metadata(of: reference)
        let stamped = output.settingProperties(PhotoCaptureProcessor.metadata(from: properties))
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // Encoding allocates the most memory of the whole pipeline, so it runs inside its own pool.
        return autoreleasepool { () -> Data? in
            context.heifRepresentation(of: stamped, format: .RGBA8, colorSpace: colorSpace, options: [:])
                ?? context.jpegRepresentation(of: stamped, colorSpace: colorSpace, options: [:])
        }
    }

    private static func metadata(of data: Data) -> [String: Any] {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [:] }
        return properties
    }
}
