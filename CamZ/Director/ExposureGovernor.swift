import Foundation

/// Decides when a suggested exposure correction is actually applied.
///
/// A correction is applied only after the same direction has been suggested on consecutive analyses, and never
/// sooner than `minInterval` after the previous change. Suggestions made during that cooldown are ignored: they were
/// measured before the last change took effect, so counting them could overshoot. Small suggestions inside the
/// deadband are ignored too. Together these stop exposure from hunting back and forth between frames.
struct ExposureGovernor: Sendable {
    /// Suggestions smaller than this (EV) are ignored.
    var deadband: Float = 0.3
    /// Consecutive analyses that must agree on a direction before a change is applied.
    var requiredAgreement = 2
    /// Minimum time between applied changes, in seconds. Also the cooldown while exposure settles.
    var minInterval: TimeInterval = 1.0

    private var pending: Float = 0
    private var agreeing = 0
    private var lastApplied: TimeInterval = -.infinity

    /// Feeds one suggestion (EV, relative to the current bias). Returns the EV step to apply now, or nil.
    mutating func propose(_ delta: Float, now: TimeInterval) -> Float? {
        guard now - lastApplied >= minInterval else {
            // Still settling from the last change: don't count this suggestion.
            pending = 0
            agreeing = 0
            return nil
        }
        guard abs(delta) >= deadband else {
            pending = 0
            agreeing = 0
            return nil
        }
        if pending != 0, delta.sign == pending.sign {
            agreeing += 1
        } else {
            pending = delta
            agreeing = 1
        }
        guard agreeing >= requiredAgreement else { return nil }
        lastApplied = now
        pending = 0
        agreeing = 0
        return delta
    }
}
