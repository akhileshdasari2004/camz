import CoreImage
import Foundation
import Vision

/// Everything the UI and the capture logic need from one analysis pass.
struct PhotoDecision: Equatable, Sendable {
    var scene: SceneKind = .general
    /// False when the scene is a brightness and colour guess rather than a confident identification.
    var sceneIsConfident = false
    var lighting: LightingCondition = .balanced
    /// `nil` until the first frame has been analysed.
    var exposure: ExposureAssessment?
    /// Stable zoom recommendation (display units, 1× = main lens).
    var recommendedZoom: CGFloat?
    /// Where autofocus should aim: the eye midpoint when visible, else the face centre.
    /// Normalised image coordinates (origin bottom-left). `nil` when no face is found.
    var focusTarget: CGPoint?
    /// The single most useful piece of guidance right now.
    var guidance: Guidance = .none
    var readiness: CaptureReadiness = .moving
    var faceCount = 0
}

/// Runs scene, exposure, lens, focus and guidance analysis on live preview frames.
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
    private var throttle = AnalysisThrottle(interval: PhotographyDirector.analysisInterval)
    private var zoom: CGFloat = 1
    private var zoomPresets: [CGFloat] = [1]

    // Analysis state (touched only on `queue`).
    private var analysisCount = 0
    private var labels: [ClassifiedLabel] = []
    private var previousSignature: [UInt8]?
    private var readiness = CaptureDecisionEngine()
    private var sceneStable = Stabilizer<SceneKind>(required: 3)
    private var zoomStable = Stabilizer<CGFloat>(required: 3)
    private var guidanceStable = Stabilizer<Guidance>(required: 2)

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
        let accepted = lock.withLock { throttle.tryStart(now: now) }
        guard accepted else { return }

        queue.async { [self] in
            let decision = analyze(image, settling: settling, now: now)
            lock.withLock { throttle.finish() }
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

        // Motion between this frame and the last analysed one.
        let signature = Self.signature(of: image, context: context)
        let motion = previousSignature.map { FrameMotion.difference($0, signature) } ?? 1
        previousSignature = signature

        // Faces (largest first, with eye points when Vision finds them) and the horizon.
        let faces = VisionDetector.faces(in: image)
        let horizon = VisionDetector.horizonDegrees(in: image)
        let mainFace = faces.first
        let faceAreaFraction = mainFace.map { Float($0.box.width * $0.box.height) } ?? 0

        if analysisCount % Self.classifyEvery == 1 {
            labels = SceneClassifier.classifyLabels(in: image)
        }

        // Brightness of the frame and of the subject: the largest face, or the centre when there is none.
        let subjectRegion: CGRect
        if let face = mainFace {
            subjectRegion = CGRect(
                x: extent.minX + face.box.minX * extent.width,
                y: extent.minY + face.box.minY * extent.height,
                width: face.box.width * extent.width,
                height: face.box.height * extent.height
            )
        } else {
            subjectRegion = extent.insetBy(dx: extent.width * 0.25, dy: extent.height * 0.25)
        }

        let frameHistogram = ExposureAnalyzer.histogram(of: image, context: context)
        let subjectHistogram = ExposureAnalyzer.histogram(of: image, in: subjectRegion, context: context)
        let frameMean = frameHistogram?.mean ?? 0.5
        let warmth = ColorProbe.redMinusBlue(of: image, context: context)
        let warm = warmth.map { SceneClassifier.isWarm(redMinusBlue: $0) } ?? false

        // Scene: labels and faces first, then brightness and colour cast as a low-confidence fallback.
        let sceneDecision = SceneClassifier.decide(
            labels: labels,
            faceCount: faces.count,
            faceAreaFraction: faceAreaFraction,
            frameMean: frameMean,
            redMinusBlue: warmth
        )
        let scene = sceneStable.ingest(sceneDecision.kind) ?? .general

        // Exposure: judge the subject, with a target that suits the scene and protects highlights and atmosphere.
        let exposure = frameHistogram.map {
            ExposureAnalyzer.assess(frame: $0, subject: subjectHistogram, scene: scene, warm: warm)
        }
        let lighting = SceneClassifier.lighting(
            frameMean: frameMean,
            highlightClipping: frameHistogram?.highlightClipping ?? 0,
            shadowClipping: frameHistogram?.shadowClipping ?? 0,
            subjectMean: subjectHistogram?.mean
        )

        // Lens: the best zoom for the scene, stabilised so it doesn't flip.
        let (currentZoom, presets) = lock.withLock { (zoom, zoomPresets) }
        let wantedZoom = LensSelector.recommendedZoom(
            scene: scene,
            faceAreaFraction: faceAreaFraction,
            current: currentZoom,
            presets: presets,
            isConfident: sceneDecision.isConfident
        )
        let recommendedZoom = zoomStable.ingest(wantedZoom)

        // Focus: the eye midpoint when visible, otherwise the face centre.
        let focusTarget = mainFace.map { $0.eyeCenter ?? CGPoint(x: $0.box.midX, y: $0.box.midY) }

        // Readiness: motion, focus and exposure settling, and light level (low light needs a longer calm period).
        let lowLight = frameMean < SceneClassifier.nightMean * 1.5
        let readinessNow = readiness.ingest(motion: motion, settling: settling, lowLight: lowLight)

        // Guidance: one message, stabilised so it doesn't flicker.
        let advice = GuidanceEngine.advice(
            readiness: readinessNow,
            horizonDegrees: horizon,
            faces: faces.map(\.box),
            scene: scene
        )
        let guidance = guidanceStable.ingest(advice) ?? Guidance.none

        return PhotoDecision(
            scene: scene,
            sceneIsConfident: sceneDecision.isConfident,
            lighting: lighting,
            exposure: exposure,
            recommendedZoom: recommendedZoom,
            focusTarget: focusTarget,
            guidance: guidance,
            readiness: readinessNow,
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

/// A detected face: its box (normalised, origin bottom-left) and the eye midpoint when landmarks are found.
struct FaceInfo: Sendable {
    let box: CGRect
    let eyeCenter: CGPoint?
}

/// Vision wrappers that return plain values, so the analysis above stays easy to follow.
enum VisionDetector {
    /// Faces, largest first. Uses the landmarks request so eyes come from the same pass.
    static func faces(in image: CIImage) -> [FaceInfo] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
            .map { FaceInfo(box: $0.boundingBox, eyeCenter: eyeCenter(of: $0)) }
    }

    /// Midpoint of the two eyes in normalised image coordinates, when landmarks are available.
    private static func eyeCenter(of face: VNFaceObservation) -> CGPoint? {
        guard
            let landmarks = face.landmarks,
            let leftEye = landmarks.leftEye,
            let rightEye = landmarks.rightEye,
            let left = centre(of: leftEye),
            let right = centre(of: rightEye)
        else { return nil }

        // Landmark points are normalised to the face's bounding box, so map them back into image coordinates.
        let box = face.boundingBox
        let midX = (left.x + right.x) / 2
        let midY = (left.y + right.y) / 2
        return CGPoint(x: box.minX + midX * box.width, y: box.minY + midY * box.height)
    }

    private static func centre(of region: VNFaceLandmarkRegion2D) -> CGPoint? {
        let points = region.normalizedPoints
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Horizon tilt in degrees (signed), or nil when no horizon is visible.
    static func horizonDegrees(in image: CIImage) -> Float? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil, let horizon = request.results?.first else { return nil }
        return Float(horizon.angle * 180 / .pi)
    }
}
