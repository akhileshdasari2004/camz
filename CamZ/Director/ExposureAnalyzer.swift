import CoreImage
import CoreImage.CIFilterBuiltins

/// Brightness distribution of a frame, or of one region of it, in 256 bins.
struct LuminanceHistogram: Equatable, Sendable {
    static let binCount = 256

    /// Fraction of pixels in each bin. Sums to 1 for a non-empty region.
    let bins: [Float]

    init(bins: [Float]) {
        precondition(bins.count == Self.binCount, "A luminance histogram has 256 bins")
        self.bins = bins
    }

    /// Average brightness from 0 (black) to 1 (white).
    var mean: Float {
        var total: Float = 0
        for (index, weight) in bins.enumerated() {
            total += weight * Float(index)
        }
        return total / Float(Self.binCount - 1)
    }

    /// Share of pixels at 98 % brightness or above: blown highlights.
    var highlightClipping: Float { bins[250...].reduce(0, +) }

    /// Share of pixels at 2 % brightness or below: crushed shadows.
    var shadowClipping: Float { bins[...5].reduce(0, +) }
}

enum ExposureStatus: Equatable, Sendable {
    case balanced
    case underexposed
    case overexposed
    case highlightsClipping
    case shadowsClipping

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .underexposed: "Underexposed"
        case .overexposed: "Overexposed"
        case .highlightsClipping: "Highlights clipping"
        case .shadowsClipping: "Shadows clipping"
        }
    }
}

struct ExposureAssessment: Equatable, Sendable {
    /// Brightness of the region that matters: the subject when one is found, otherwise the frame.
    var subjectMean: Float
    var frameMean: Float
    var highlightClipping: Float
    var shadowClipping: Float
    var status: ExposureStatus
    /// Suggested change to the exposure target bias, in EV, relative to the current bias.
    /// Zero means leave it alone.
    var suggestedBiasDelta: Float
}

/// How exposure should treat the scene.
enum ExposureIntent: Equatable, Sendable {
    /// Subject-led exposure toward a brightness suited to the scene.
    case standard
    /// Night and sunset. Keep the mood: only protect highlights, never lift toward mid-grey.
    case atmospheric
}

/// Turns luminance histograms into an exposure judgement. Pure, so it is tested without a camera.
enum ExposureAnalyzer {
    /// General target brightness on the 0…1 scale (a little below middle grey).
    static let targetMean: Float = 0.42
    /// Changes smaller than this (EV) are ignored, so exposure does not hunt back and forth.
    static let deadband: Float = 0.3
    /// Largest single correction we will ask for, in EV.
    static let maxStep: Float = 1.5
    /// Fraction of the computed correction suggested per analysis. Less than 1 avoids overshoot.
    static let damping: Float = 0.6

    static func intent(for scene: SceneKind, warm: Bool, frameMean: Float) -> ExposureIntent {
        if scene == .night { return .atmospheric }
        // Warm outdoor light that isn't blown out reads as sunset or golden hour.
        if warm, frameMean < 0.6, scene == .landscape || scene == .outdoor { return .atmospheric }
        return .standard
    }

    /// Brightness the subject should land at, on the 0…1 scale.
    static func target(for scene: SceneKind, intent: ExposureIntent) -> Float {
        switch intent {
        case .atmospheric:
            return scene == .night ? 0.22 : 0.34
        case .standard:
            switch scene {
            case .portrait: return 0.46              // slightly brighter, so skin tones stay open
            case .food: return 0.44
            case .landscape, .outdoor: return 0.40  // leave room for sky and highlights
            case .architecture, .indoor, .general, .night: return targetMean
            }
        }
    }

    static func assess(
        frame: LuminanceHistogram,
        subject: LuminanceHistogram?,
        scene: SceneKind = .general,
        warm: Bool = false
    ) -> ExposureAssessment {
        let reference = subject ?? frame
        let mean = max(reference.mean, 0.01)
        let intent = intent(for: scene, warm: warm, frameMean: frame.mean)
        let goal = target(for: scene, intent: intent)

        var delta = log2(goal / mean) * damping
        var status: ExposureStatus

        if reference.highlightClipping > 0.02 || frame.highlightClipping > 0.05 {
            // Protect highlights first, even when the subject itself is still a little dark.
            status = .highlightsClipping
            delta = min(delta, -deadband)
        } else if intent == .standard, reference.shadowClipping > 0.25, mean < goal {
            status = .shadowsClipping
            delta = max(delta, deadband)
        } else if delta > 0.5 {
            status = .underexposed
        } else if delta < -0.5 {
            status = .overexposed
        } else {
            status = .balanced
        }

        if intent == .atmospheric, status != .highlightsClipping {
            // Night and sunset are intentional: no correction, and no under- or overexposed label.
            delta = 0
            status = .balanced
        }
        if abs(delta) < deadband {
            delta = 0
        }
        delta = min(max(delta, -maxStep), maxStep)

        return ExposureAssessment(
            subjectMean: subject?.mean ?? frame.mean,
            frameMean: frame.mean,
            highlightClipping: frame.highlightClipping,
            shadowClipping: frame.shadowClipping,
            status: status,
            suggestedBiasDelta: delta
        )
    }

    /// Builds a luminance histogram of `region` (the whole image when nil) with Core Image.
    /// Blocking: call off the main thread.
    static func histogram(of image: CIImage, in region: CGRect? = nil, context: CIContext) -> LuminanceHistogram? {
        let extent = region.map { image.extent.intersection($0) } ?? image.extent
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return nil }

        // Rec. 709 luma, copied into all channels so the red channel is the luma histogram.
        let luma = CIFilter.colorMatrix()
        luma.inputImage = image.cropped(to: extent)
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luma.rVector = weights
        luma.gVector = weights
        luma.bVector = weights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let gray = luma.outputImage else { return nil }

        guard let histogram = CIFilter(name: "CIAreaHistogram", parameters: [
            kCIInputImageKey: gray,
            "inputExtent": CIVector(cgRect: extent),
            "inputCount": LuminanceHistogram.binCount,
            "inputScale": 1.0
        ]), let output = histogram.outputImage else { return nil }

        var raw = [Float](repeating: 0, count: LuminanceHistogram.binCount * 4)
        raw.withUnsafeMutableBytes { buffer in
            context.render(
                output,
                toBitmap: buffer.baseAddress!,
                rowBytes: LuminanceHistogram.binCount * 16,
                bounds: CGRect(x: 0, y: 0, width: LuminanceHistogram.binCount, height: 1),
                format: .RGBAf,
                colorSpace: nil
            )
        }

        let counts = (0..<LuminanceHistogram.binCount).map { raw[$0 * 4] }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        return LuminanceHistogram(bins: counts.map { $0 / total })
    }
}
