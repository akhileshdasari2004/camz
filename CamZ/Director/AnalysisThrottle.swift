import Foundation

/// Admits one analysis at a time, and no more often than `interval`. Frames that arrive while an analysis is busy,
/// or too soon after the last one, are dropped. Pure, so the throttle is tested without Vision.
struct AnalysisThrottle: Sendable {
    let interval: TimeInterval
    private var busy = false
    private var lastAccepted: TimeInterval = -.infinity

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Returns true when a new analysis may start at `now`, and marks it as busy.
    mutating func tryStart(now: TimeInterval) -> Bool {
        guard !busy, now - lastAccepted >= interval else { return false }
        busy = true
        lastAccepted = now
        return true
    }

    /// Call when the analysis started by `tryStart` has finished.
    mutating func finish() {
        busy = false
    }
}
