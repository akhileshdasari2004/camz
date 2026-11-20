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

    var title: String {
        switch self {
        case .dark: "Low light"
        case .dim: "Dim"
        case .balanced: "Good light"
        case .bright: "Bright"
        case .harsh: "Harsh light"
        }
    }
}

struct ClassifiedLabel: Equatable, Sendable {
    let identifier: String
    let confidence: Float
}

/// Decides what the scene is from Apple's on-device classifier labels plus measured face and brightness data.
/// The scene rules are pure and unit tested; `classifyLabels` is the only part that runs Vision.
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

    /// Light quality from measured brightness. Dark frames are "low light" first, not "harsh".
    static func lighting(frameMean: Float, highlightClipping: Float, shadowClipping: Float) -> LightingCondition {
        if frameMean < nightMean { return .dark }
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
