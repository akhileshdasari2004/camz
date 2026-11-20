import CoreGraphics

/// Chooses which zoom preset (1× = main lens, 0.5× = ultra-wide, 2× and 3× = telephoto) frames the scene.
/// It only ever picks presets the camera offers, so Auto never adds digital zoom on its own.
enum LensSelector {
    /// A face narrower than this share of the frame is too small to read as a portrait.
    static let smallFaceArea: Float = 0.06
    /// A face wider than this share of the frame is cramped; step back to the main lens.
    static let largeFaceArea: Float = 0.35

    /// Returns the zoom to use: a preset from `presets`, or `current` when no change helps.
    /// Changes happen only for confident scene decisions, so a guess never moves the lens.
    static func recommendedZoom(
        scene: SceneKind,
        faceAreaFraction: Float,
        current: CGFloat,
        presets: [CGFloat],
        isConfident: Bool = true
    ) -> CGFloat {
        guard isConfident else { return current }

        func offered(_ zoom: CGFloat) -> Bool {
            presets.contains { abs($0 - zoom) < 0.01 }
        }

        switch scene {
        case .portrait:
            if faceAreaFraction < smallFaceArea, current < 1.5, offered(2) { return 2 }
            if faceAreaFraction > largeFaceArea, current > 1.5, offered(1) { return 1 }
            return current

        case .landscape, .architecture, .indoor, .outdoor:
            // Wide scenes read best at the main lens; pull back from telephoto.
            if current > 1.5, offered(1) { return 1 }
            return current

        case .food:
            // Close subjects are framed best at the main lens so the crop stays natural.
            if current > 2.5, offered(1) { return 1 }
            return current

        case .night:
            // Telephoto at night amplifies noise; step back to the main lens.
            if current > 2.5, offered(1) { return 1 }
            return current

        case .general:
            return current
        }
    }
}
