import CoreImage
import Foundation
import Vision

/// Everything the UI and the capture logic need from one analysis pass.
struct PhotoDecision: Equatable, Sendable {
    var scene: SceneKind = .general
    var lighting: LightingCondition = .balanced
    /// `nil` until the first frame has been analysed.
    var exposure: ExposureAssessment?
    /// Stable zoom recommendation (display units, 1× = main lens).
    var recommendedZoom: CGFloat?
    var composition: CompositionAdvice = .none
    var readiness: CaptureReadiness = .moving
    var faceCount = 0
}

/// Runs scene, exposure, lens and composition analysis on live preview frames.
///
/// Frames arrive on the camera's video queue. `submit` returns immediately: it drops a frame when an analysis is
/// already running or when the last one was too recent. Analysis runs on the director's own background queue, and
/// each finished pass is reported through `onDecision`. Nothing here touches the camera or the main thread.
final class PhotographyDirector: @unchecked Sendable {

    /// Called on the director's background queue with every finished analysis.
    var onDecision: (@Sendable (PhotoDecision) -> Void)?

    /// Minimum time between analyses. Five per second is plenty for scene and exposure changes.
    static let analysisInterval: TimeInterval = 0.2
    /// Apple's classifier is the most expensive step, so it runs once every this many analyses (about once a second).
    static let classifyEvery = 5

    private let queue = DispatchQueue(label: "com.akhilesh.camz.director", qos: .utility)
    // Work on gamma-encoded values, not linear light, so luma matches what the eye sees.
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    private let lock = NSLock()

    // Shared with the camera thread (guarded by `lock`).
    private var isBusy = false
    private var lastSubmit: TimeInterval = -.infinity
    private var zoom: CGFloat = 1
    private var zoomPresets: [CGFloat] = [1]

    // Analysis state (touched only on `queue`).
    private var analysisCount = 0
    private var labels: [ClassifiedLabel] = []
    private var previousSignature: [UInt8]?
    private var readiness = CaptureDecisionEngine()
    private var sceneStable = Stabilizer<SceneKind>(required: 3)
    private var zoomStable = Stabilizer<CGFloat>(required: 3)

    /// Tells the director the zoom in use and which presets the camera offers. Safe from any thread.
    func updateZoom(_ current: CGFloat, presets: [CGFloat]) {
        lock.withLock {
            zoom = current
            zoomPresets = presets.isEmpty ? [current] : presets
        }
    }

    /// Offers one preview frame for analysis. Cheap and non-blocking; safe to call on every frame.
    /// - Parameters:
    ///   - image: The raw, unfiltered, upright preview frame.
    ///   - settling: True while the camera is still adjusting focus or exposure.
    func submit(_ image: CIImage, settling: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let accepted = lock.withLock { () -> Bool in
            guard !isBusy, now - lastSubmit >= Self.analysisInterval else { return false }
            isBusy = true
            lastSubmit = now
            return true
        }
        guard accepted else { return }

        queue.async { [self] in
            let decision = analyze(image, settling: settling, now: now)
            lock.withLock { isBusy = false }
            onDecision?(decision)
        }
    }

    // MARK: - Analysis (runs on `queue`)

    private func analyze(_ image: CIImage, settling: Bool, now: TimeInterval) -> PhotoDecision {
        analysisCount += 1
        let extent = image.extent
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else {
            return PhotoDecision(readiness: readiness.ingest(motion: 1, settling: settling))
        }

        // Motion from the change between this frame and the last analysed one.
        let signature = Self.signature(of: image, context: context)
        let motion = previousSignature.map { FrameMotion.difference($0, signature) } ?? 1
        previousSignature = signature

        // Faces (largest first) and the horizon, from Vision.
        let faces = VisionDetector.faceBoxes(in: image)
        let horizon = VisionDetector.horizonDegrees(in: image)
        let faceAreaFraction = faces.first.map { Float($0.width * $0.height) } ?? 0

        if analysisCount % Self.classifyEvery == 1 {
            labels = SceneClassifier.classifyLabels(in: image)
        }

        // Exposure: judge the subject (the largest face, else the centre) rather than the average of the frame.
        let subjectRegion = faces.first.map { box in
            CGRect(
                x: extent.minX + box.minX * extent.width,
                y: extent.minY + box.minY * extent.height,
                width: box.width * extent.width,
                height: box.height * extent.height
            )
        } ?? extent.insetBy(dx: extent.width * 0.25, dy: extent.height * 0.25)

        let frameHistogram = ExposureAnalyzer.histogram(of: image, context: context)
        let subjectHistogram = ExposureAnalyzer.histogram(of: image, in: subjectRegion, context: context)
        let exposure = frameHistogram.map { ExposureAnalyzer.assess(frame: $0, subject: subjectHistogram) }

        let frameMean = frameHistogram?.mean ?? 0.5
        let rawScene = SceneClassifier.scene(
            labels: labels,
            faceCount: faces.count,
            faceAreaFraction: faceAreaFraction,
            frameMean: frameMean
        )
        let scene = sceneStable.ingest(rawScene) ?? .general

        let (currentZoom, presets) = lock.withLock { (zoom, zoomPresets) }
        let wantedZoom = LensSelector.recommendedZoom(
            scene: scene,
            faceAreaFraction: faceAreaFraction,
            current: currentZoom,
            presets: presets
        )
        let recommendedZoom = zoomStable.ingest(wantedZoom)

        let composition = CompositionAnalyzer.advice(
            horizonDegrees: horizon,
            faceCount: faces.count,
            faceCenterX: faces.first.map { Float($0.midX) }
        )

        return PhotoDecision(
            scene: scene,
            lighting: SceneClassifier.lighting(
                frameMean: frameMean,
                highlightClipping: frameHistogram?.highlightClipping ?? 0,
                shadowClipping: frameHistogram?.shadowClipping ?? 0
            ),
            exposure: exposure,
            recommendedZoom: recommendedZoom,
            composition: composition,
            readiness: readiness.ingest(motion: motion, settling: settling),
            faceCount: faces.count
        )
    }

    /// A 16×16 grayscale thumbnail of the frame, used only to measure motion between frames.
    static func signature(of image: CIImage, context: CIContext) -> [UInt8] {
        let size = FrameMotion.gridSize
        let extent = image.extent
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(size) / extent.width,
            y: CGFloat(size) / extent.height
        ))
        var pixels = [UInt8](repeating: 0, count: size * size)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(
                scaled,
                toBitmap: buffer.baseAddress!,
                rowBytes: size,
                bounds: CGRect(origin: scaled.extent.origin, size: CGSize(width: size, height: size)),
                format: .L8,
                colorSpace: nil
            )
        }
        return pixels
    }
}

/// Vision wrappers that return plain values, so the analysis above stays easy to follow.
enum VisionDetector {
    /// Face bounding boxes in normalised image coordinates (origin bottom-left), largest first.
    static func faceBoxes(in image: CIImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .map(\.boundingBox)
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// Horizon tilt in degrees (signed), or nil when no horizon is visible.
    static func horizonDegrees(in image: CIImage) -> Float? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil, let horizon = request.results?.first else { return nil }
        return Float(horizon.angle * 180 / .pi)
    }
}
