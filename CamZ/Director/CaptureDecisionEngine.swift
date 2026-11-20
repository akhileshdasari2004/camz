import Foundation

/// Accepts a value only after it has been seen `required` times in a row, so one noisy frame cannot flip a decision.
struct Stabilizer<Value: Equatable & Sendable>: Sendable {
    private let required: Int
    private var candidate: Value?
    private var count = 0
    private(set) var stable: Value?

    init(required: Int) {
        self.required = max(1, required)
    }

    /// Feeds one observation and returns the currently accepted value, if any.
    @discardableResult
    mutating func ingest(_ value: Value) -> Value? {
        if value == candidate {
            count += 1
        } else {
            candidate = value
            count = 1
        }
        if count >= required {
            stable = value
        }
        return stable
    }
}

/// Frame-to-frame change measured on a tiny grayscale signature of each analysed frame.
enum FrameMotion {
    /// Side length of the square grayscale signature.
    static let gridSize = 16

    /// Mean absolute brightness change between two signatures, from 0 (identical) to 1 (opposite).
    /// Returns 1 when the signatures can't be compared.
    static func difference(_ previous: [UInt8], _ current: [UInt8]) -> Float {
        guard previous.count == current.count, !previous.isEmpty else { return 1 }
        var total = 0
        for index in previous.indices {
            total += abs(Int(previous[index]) - Int(current[index]))
        }
        return Float(total) / Float(previous.count * 255)
    }
}

enum CaptureReadiness: Equatable, Sendable {
    /// Steady enough to shoot now.
    case steady
    /// The phone or the scene is moving.
    case moving
    /// The camera is still changing focus or exposure.
    case settling

    var isSteady: Bool { self == .steady }
}

/// Decides when the preview has been still long enough that a shot will be sharp and correctly exposed.
/// Pure: it only counts calm frames. The capture code decides what to do while it waits, and the wait is bounded.
struct CaptureDecisionEngine: Sendable {
    /// Mean brightness change (see `FrameMotion`) above which the scene counts as moving.
    var motionThreshold: Float = 0.02
    /// Consecutive calm frames required before a shot counts as steady, in good light.
    var requiredCalmFrames = 3
    /// Extra calm frames required in low light, where exposure times are longer and blur risk is higher.
    var lowLightExtraFrames = 2

    private(set) var calmFrames = 0

    mutating func ingest(motion: Float, settling: Bool, lowLight: Bool = false) -> CaptureReadiness {
        if settling {
            calmFrames = 0
            return .settling
        }
        if motion > motionThreshold {
            calmFrames = 0
            return .moving
        }
        calmFrames += 1
        let required = lowLight ? requiredCalmFrames + lowLightExtraFrames : requiredCalmFrames
        return calmFrames >= required ? .steady : .moving
    }
}

/// Decides whether a shot should still wait for a steady frame. Waiting is always bounded: capture never waits on a
/// stalled AI, and it never waits longer than `maxWait`.
enum CaptureWaitPolicy {
    /// Longest a shot waits for a steady frame.
    static let maxWait: TimeInterval = 1.5
    /// A decision older than this means the AI has stalled, so the shot is not held for it.
    static let maxDecisionAge: TimeInterval = 1.0

    /// True while the shot should keep waiting.
    /// - Parameters:
    ///   - readiness: The latest readiness from the director.
    ///   - decisionAge: Seconds since the latest decision, or nil when no decision has arrived.
    ///   - elapsed: Seconds this shot has already waited.
    static func shouldKeepWaiting(readiness: CaptureReadiness, decisionAge: TimeInterval?, elapsed: TimeInterval) -> Bool {
        guard elapsed < maxWait else { return false }
        guard let decisionAge, decisionAge <= maxDecisionAge else { return false }
        return !readiness.isSteady
    }
}
