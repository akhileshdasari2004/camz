import Foundation

/// Correlated colour temperature from a frame's average colour. Pure, so the estimate is tested without a camera.
enum ColorTemperature {
    /// Approximate colour temperature in kelvin (McCamy's formula on CIE 1931 chromaticity). Nil when the colour is too dark
    /// or has no chromaticity. The estimate assumes the frame's average colour is the light, which is only roughly true.
    static func kelvin(_ color: AverageColor) -> Double? {
        // Gamma-encoded sRGB to linear light.
        func linear(_ value: Float) -> Double {
            let v = Double(min(max(value, 0), 1))
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.red)
        let g = linear(color.green)
        let b = linear(color.blue)
        let x = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = 0.0193 * r + 0.1192 * g + 0.9505 * b
        let sum = x + y + z
        guard y > 0.002, sum > 0 else { return nil }
        let cx = x / sum
        let cy = y / sum
        let n = (cx - 0.3320) / (0.1858 - cy)
        guard n.isFinite else { return nil }
        return 449 * pow(n, 3) + 3525 * pow(n, 2) + 6823.3 * n + 5520.33
    }
}

/// What white balance should do for the next frames.
enum WhiteBalanceDecision: Equatable, Sendable {
    /// The camera keeps adjusting white balance continuously. The default, and the fallback.
    case continuousAuto(reason: String)
    /// Hold white balance at this colour temperature, because the light is stable and warm by design.
    case lock(kelvin: Double, reason: String)
}

/// Decides when a white-balance lock is justified, and holds it steadily once it is set. Pure, so the rules are tested.
///
/// A lock is set only when all of these hold: the light has been measured steadily for a while, the scene is atmospheric
/// (sunset or night, where warm light is part of the picture), and no people are in frame, because skin tones are safer
/// under continuous auto. The locked target keeps half of the warmth, so a sunset stays warm.
///
/// Once set, the lock is hysteretic. Ordinary variation in the light does not release it. It is released only after the
/// light has failed the hold rules for `releaseAfterFrames` frames in a row. That is what stops the lock from oscillating.
struct WhiteBalanceController: Sendable {
    /// Estimates this close to neutral (about 6500 K) do not justify a lock: continuous auto already handles them.
    static let neutralKelvin: Double = 6500
    static let neutralBand: Double = 900
    /// While locked, a lock is held through estimates this close to neutral. Narrower than `neutralBand`, so it is sticky.
    static let holdBand: Double = 450
    /// Frames that must agree before a lock is considered.
    static let requiredStableFrames = 8
    /// Largest spread, in kelvin, across the stable window before a lock is set. A wider spread means the light is changing.
    static let maxStableSpread: Double = 200
    /// Wider spread a held lock tolerates. Ordinary variation keeps it; a real change of light releases it.
    static let maxHeldSpread: Double = 400
    /// Share of the warmth kept in a lock. 0.5 keeps half, so a warm scene stays warm without a strong cast.
    static let warmthKept: Double = 0.5
    /// Frames that must fail the hold rules in a row before a held lock is released.
    static let releaseAfterFrames = 30

    /// Set false while the feature is unproven on a device. The decision then never locks.
    var lockingEnabled: Bool = true

    private(set) var window: [Double] = []
    private(set) var isLocked = false
    private(set) var lockedKelvin: Double?
    private var framesOutsideHold = 0

    /// Feeds one analysed frame. Pass nil for the colour temperature when a frame cannot be measured.
    mutating func ingest(kelvin: Double?, atmosphericScene: Bool, faceCount: Int) -> WhiteBalanceDecision {
        guard lockingEnabled else {
            release()
            return .continuousAuto(reason: "White-balance locking is off.")
        }
        guard let kelvin, kelvin.isFinite else {
            window.removeAll()
            return stepHeld(holds: false, reason: "Light not measured yet.")
        }
        window.append(kelvin)
        if window.count > Self.requiredStableFrames {
            window.removeFirst(window.count - Self.requiredStableFrames)
        }
        let spread = (window.max() ?? 0) - (window.min() ?? 0)
        let median = window.sorted()[window.count / 2]
        let warm = abs(median - Self.neutralKelvin) > Self.neutralBand

        if isLocked {
            // Skin tones take priority over stability: a person in frame releases the lock at once.
            if faceCount > 0 {
                release()
                return .continuousAuto(reason: "People are in frame, so skin tones return to auto.")
            }
            let holds = spread <= Self.maxHeldSpread
                && abs(median - Self.neutralKelvin) > Self.holdBand
                && atmosphericScene
                && faceCount == 0
            return stepHeld(holds: holds, reason: holdReason(spread: spread, atmospheric: atmosphericScene, faces: faceCount))
        }

        guard window.count == Self.requiredStableFrames else {
            return .continuousAuto(reason: "Measuring the light.")
        }
        guard spread <= Self.maxStableSpread else {
            return .continuousAuto(reason: "The light is changing.")
        }
        guard warm else {
            return .continuousAuto(reason: "Auto white balance already handles this light.")
        }
        guard atmosphericScene else {
            return .continuousAuto(reason: "Warm or cool light here is not part of the picture, so auto is kept.")
        }
        guard faceCount == 0 else {
            return .continuousAuto(reason: "People are in frame, so skin tones stay on auto.")
        }
        isLocked = true
        lockedKelvin = Self.neutralKelvin + Self.warmthKept * (median - Self.neutralKelvin)
        framesOutsideHold = 0
        return .lock(kelvin: lockedKelvin ?? median, reason: "Stable warm light at sunset or night: locked to keep its mood.")
    }

    /// Moves a held lock on by one frame. Keeps it while the hold rules hold, and releases it only after a run of failures.
    private mutating func stepHeld(holds: Bool, reason: String) -> WhiteBalanceDecision {
        guard isLocked, let kelvin = lockedKelvin else {
            return .continuousAuto(reason: reason)
        }
        if holds {
            framesOutsideHold = 0
            return .lock(kelvin: kelvin, reason: "Stable warm light: lock held.")
        }
        framesOutsideHold += 1
        if framesOutsideHold >= Self.releaseAfterFrames {
            release()
            return .continuousAuto(reason: reason)
        }
        return .lock(kelvin: kelvin, reason: "A brief change in the light: lock held for now.")
    }

    private mutating func release() {
        isLocked = false
        lockedKelvin = nil
        framesOutsideHold = 0
    }

    private func holdReason(spread: Double, atmospheric: Bool, faces: Int) -> String {
        if faces > 0 { return "People are in frame, so skin tones return to auto." }
        if !atmospheric { return "The scene is no longer atmospheric, so auto returns." }
        if spread > Self.maxHeldSpread { return "The light is changing." }
        return "Stable warm light: lock held."
    }
}
