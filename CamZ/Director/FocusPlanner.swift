import CoreGraphics
import Foundation

/// Decides when the camera should re-aim autofocus at the subject, so focus follows the subject without looping.
///
/// - It re-aims only when the subject has moved far enough, and at most once per `minInterval`.
/// - After a user tap, the tap wins for `tapLockDuration`, so AI tracking never fights the user.
struct FocusPlanner: Sendable {
    var minInterval: TimeInterval = 1.0
    /// Distance (normalised image units) the subject must move before focus is re-aimed.
    var minMovement: CGFloat = 0.08
    var tapLockDuration: TimeInterval = 4.0

    private(set) var lastTarget: CGPoint?
    private var lastFocusTime: TimeInterval = -.infinity
    private var tapLockedUntil: TimeInterval = -.infinity

    /// Call when the user taps to focus. AI tracking pauses until the lock expires.
    mutating func noteUserTap(now: TimeInterval) {
        tapLockedUntil = now + tapLockDuration
        lastTarget = nil
    }

    /// Returns the point to focus on now, or nil to keep the current focus.
    mutating func target(for point: CGPoint?, now: TimeInterval) -> CGPoint? {
        guard now >= tapLockedUntil, let point else { return nil }
        if let last = lastTarget {
            let dx = point.x - last.x
            let dy = point.y - last.y
            guard (dx * dx + dy * dy).squareRoot() >= minMovement else { return nil }
        }
        guard now - lastFocusTime >= minInterval else { return nil }
        lastTarget = point
        lastFocusTime = now
        return point
    }
}
