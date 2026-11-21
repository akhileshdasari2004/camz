import CoreGraphics
import Foundation

/// What the camera should do with autofocus after one analysis.
enum FocusCommand: Equatable, Sendable {
    /// Keep the current focus.
    case none
    /// Aim autofocus at this point. Normalised, Vision convention; the caller converts it for the camera.
    case focus(CGPoint)
    /// No subject for a while: let go and return to continuous centre focus.
    case release
}

/// Decides when the camera should re-aim autofocus at the subject, so focus follows the subject without looping.
///
/// - It re-aims only when the subject has moved far enough, and at most once per `minInterval`.
/// - After a user tap, the tap wins for `tapLockDuration`, so AI tracking never fights the user.
/// - When no subject has been seen for `releaseAfter` seconds, AI focus lets go and returns to the centre.
struct FocusPlanner: Sendable {
    var minInterval: TimeInterval = 1.0
    /// Distance (normalised image units) the subject must move before focus is re-aimed.
    var minMovement: CGFloat = 0.08
    var tapLockDuration: TimeInterval = 4.0
    /// Seconds without a subject before AI focus is released.
    var releaseAfter: TimeInterval = 2.0

    private(set) var lastTarget: CGPoint?
    private var lastFocusTime: TimeInterval = -.infinity
    private var lastSubjectTime: TimeInterval = -.infinity
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

    /// The full autofocus decision for this analysis: focus on the subject, release when it has been gone too long,
    /// or do nothing. Nothing happens while a user tap holds focus.
    mutating func command(for point: CGPoint?, now: TimeInterval) -> FocusCommand {
        guard now >= tapLockedUntil else { return .none }
        guard let point else {
            guard lastTarget != nil, now - lastSubjectTime >= releaseAfter else { return .none }
            lastTarget = nil
            return .release
        }
        lastSubjectTime = now
        guard let focus = target(for: point, now: now) else { return .none }
        return .focus(focus)
    }
}
