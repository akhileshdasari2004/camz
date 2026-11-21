import CoreGraphics

/// What was measured on one frame of a burst.
struct ShotMeasurement: Equatable, Sendable {
    /// Relative sharpness (higher is sharper). Only comparable within one burst.
    var sharpness: Float
    /// Faces found in the frame.
    var faceCount: Int
    /// True when every measured eye is open. Nil when no eye could be measured.
    var eyesOpen: Bool?
}

/// Eye openness from the height and width of an eye outline. Pure.
enum EyeOpenness {
    /// Open eyes measure about 0.3 or more; a closed eye is nearly flat. Tune this on a device before relying on it.
    static let openThreshold: Float = 0.18

    /// Height over width of one eye outline, or nil when the outline is too small to judge.
    /// `unitsX` and `unitsY` convert the outline into a common length unit, so the ratio matches the real eye shape.
    static func ratio(of points: [CGPoint], unitsX: CGFloat = 1, unitsY: CGFloat = 1) -> Float? {
        guard points.count >= 3 else { return nil }
        let xs = points.map { $0.x * unitsX }
        let ys = points.map { $0.y * unitsY }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = maxX - minX
        guard width > 0.0001 else { return nil }
        return Float((maxY - minY) / width)
    }

    static func isOpen(_ ratio: Float) -> Bool {
        ratio >= openThreshold
    }

    /// True when every measured eye is open. Nil when nothing could be measured, so a missing measurement
    /// never counts as open eyes.
    static func allOpen(_ ratios: [Float?]) -> Bool? {
        let measured = ratios.compactMap { $0 }
        guard !measured.isEmpty else { return nil }
        return measured.allSatisfy(isOpen)
    }
}

/// Chooses the best frame of a burst: frames with open eyes first, then the sharpest. Pure.
enum BestShotRanker {
    /// Index of the frame to keep, or nil for an empty burst. Ties keep the earlier frame.
    /// When every frame has closed eyes, the sharpest closed-eye frame is returned; the caller must not claim open eyes.
    static func bestIndex(of shots: [ShotMeasurement]) -> Int? {
        guard !shots.isEmpty else { return nil }
        let eyesFine = shots.indices.filter { shots[$0].eyesOpen != false }
        let candidates = eyesFine.isEmpty ? Array(shots.indices) : eyesFine

        func sharpness(_ index: Int) -> Float {
            let value = shots[index].sharpness
            return value.isFinite ? value : 0
        }
        return candidates.max { lhs, rhs in
            let a = sharpness(lhs)
            let b = sharpness(rhs)
            if a != b { return a < b }
            return lhs > rhs
        }
    }

    /// Every shot's index, best first, by the same rule as `bestIndex`. Used to fall back to the next-best shot when a save fails.
    static func ranking(of shots: [ShotMeasurement]) -> [Int] {
        func sharpness(_ index: Int) -> Float {
            let value = shots[index].sharpness
            return value.isFinite ? value : 0
        }
        return shots.indices.sorted { lhs, rhs in
            let lhsEyesFine = shots[lhs].eyesOpen != false
            let rhsEyesFine = shots[rhs].eyesOpen != false
            if lhsEyesFine != rhsEyesFine { return lhsEyesFine }
            let a = sharpness(lhs)
            let b = sharpness(rhs)
            if a != b { return a > b }
            return lhs < rhs
        }
    }
}
