import CoreImage
import Vision

enum SceneKind: String, Equatable, Sendable, CaseIterable {
    case portrait
    case food
    case architecture
    case landscape
    case night
    case indoor
    case outdoor
    case general

    var title: String {
        switch self {
        case .portrait: "Portrait"
        case .food: "Food"
        case .architecture: "Architecture"
        case .landscape: "Landscape"
        case .night: "Night"
        case .indoor: "Indoor"
        case .outdoor: "Outdoor"
        case .general: "Scene"
        }
    }
}

enum LightingCondition: Equatable, Sendable {
    case dark
    case dim
    case balanced
    case bright
    case harsh
    case backlit

    var title: String {
        switch self {
        case .dark: "Low light"
        case .dim: "Dim"
        case .balanced: "Good light"
        case .bright: "Bright"
        case .harsh: "Harsh light"
        case .backlit: "Backlit"
        }
    }
}

struct ClassifiedLabel: Equatable, Sendable {
    let identifier: String
    let confidence: Float
}

/// A scene decision and how sure we are of it. Fallback decisions are not confident,
/// and never move the lens.
struct SceneDecision: Equatable, Sendable {
    let kind: SceneKind
    let isConfident: Bool
}

/// Decides what the scene is from Apple's on-device classifier labels, face detection and brightness.
/// The rules are pure and unit tested; `classifyLabels` is the only part that runs Vision.
enum SceneClassifier {
    /// Keywords per scene, matched as substrings of Vision's lowercased label identifiers.
    /// Order matters only for ties: earlier entries win.
    static let keywords: [(scene: SceneKind, words: [String])] = [
        (.architecture, ["architecture", "building", "house", "bridge", "skyscraper", "church", "tower", "castle", "monument", "city"]),
        (.food, ["food", "dish", "meal", "cuisine", "drink", "dessert", "pizza", "sushi", "salad", "bread", "fruit", "vegetable"]),
        (.landscape, ["landscape", "mountain", "beach", "sky", "sea", "ocean", "forest", "lake", "river", "field", "nature", "sunset", "waterfall", "desert", "snow"]),
        (.indoor, ["indoor", "room", "kitchen", "office", "interior", "restaurant", "store", "library"]),
        (.outdoor, ["outdoor", "outside", "street", "park", "garden", "road", "tree"]),
    ]

    /// Minimum classifier confidence for a label to count toward a scene.
    static let minimumConfidence: Float = 0.2
    /// Faces covering at least this share of the frame make it a portrait.
    static let portraitFaceArea: Float = 0.03
    /// Frames darker than this (mean luma, 0…1) are treated as night.
    static let nightMean: Float = 0.15
    /// Red minus blue above this counts as warm light (tungsten, sunset).
    static let warmThreshold: Float = 0.06

    static func isWarm(redMinusBlue: Float) -> Bool {
        redMinusBlue > warmThreshold
    }

    /// Scene from labels, faces and brightness. Returns `.general` when nothing identifies the scene.
    static func scene(
        labels: [ClassifiedLabel],
        faceCount: Int,
        faceAreaFraction: Float,
        frameMean: Float
    ) -> SceneKind {
        if faceCount > 0, faceAreaFraction >= portraitFaceArea { return .portrait }
        if frameMean < nightMean { return .night }

        var best: (scene: SceneKind, score: Float)?
        for entry in keywords {
            let score = labels
                .filter { label in
                    let identifier = label.identifier.lowercased()
                    return entry.words.contains { identifier.contains($0) }
                }
                .map(\.confidence)
                .max() ?? 0
            guard score >= minimumConfidence else { continue }
            if let current = best, current.score >= score { continue }
            best = (entry.scene, score)
        }
        return best?.scene ?? .general
    }

    /// Full decision: confident when labels, faces or brightness identify the scene, otherwise a low-confidence
    /// fallback from brightness and colour cast.
    static func decide(
        labels: [ClassifiedLabel],
        faceCount: Int,
        faceAreaFraction: Float,
        frameMean: Float,
        redMinusBlue: Float?
    ) -> SceneDecision {
        let kind = scene(labels: labels, faceCount: faceCount, faceAreaFraction: faceAreaFraction, frameMean: frameMean)
        if kind != .general {
            return SceneDecision(kind: kind, isConfident: true)
        }
        return SceneDecision(kind: fallback(frameMean: frameMean, redMinusBlue: redMinusBlue), isConfident: false)
    }

    /// Used when labels and faces don't identify the scene. It judges only brightness and colour cast.
    static func fallback(frameMean: Float, redMinusBlue: Float?) -> SceneKind {
        guard let warmth = redMinusBlue else { return .general }
        if frameMean > 0.5, warmth < -0.04 { return .outdoor }                    // bright, blue-tinted daylight
        if frameMean > 0.25, frameMean <= 0.5, warmth > 0.12 { return .indoor }   // dim and strongly warm: artificial light
        return .general
    }

    /// Light quality from measured brightness. Dark frames are "low light" first, not "harsh".
    /// Backlit means a subject darker than a bright background.
    static func lighting(
        frameMean: Float,
        highlightClipping: Float,
        shadowClipping: Float,
        subjectMean: Float? = nil
    ) -> LightingCondition {
        if frameMean < nightMean { return .dark }
        if let subjectMean, subjectMean < 0.35, frameMean - subjectMean > 0.2, highlightClipping > 0.01 {
            return .backlit
        }
        if highlightClipping > 0.05 || shadowClipping > 0.4 { return .harsh }
        if frameMean < 0.3 { return .dim }
        if frameMean > 0.7 { return .bright }
        return .balanced
    }

    /// Runs Apple's image classifier on an upright frame. Blocking: call off the main thread.
    static func classifyLabels(in image: CIImage) -> [ClassifiedLabel] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .prefix(40)
            .map { ClassifiedLabel(identifier: $0.identifier, confidence: $0.confidence) }
    }
}
