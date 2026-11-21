import Foundation

/// Hands-free AI capture: waits for conditions to hold, counts down, then asks for one capture. Pure, so the safety
/// rules are tested without a camera. A manual shutter press never goes through this controller.
///
/// Callers must call `didCapture` after every `.capture` action, including when the capture failed, so the controller
/// never stays stuck in `.capturing`.
struct HandsFreeController: Sendable {
    enum State: Equatable, Sendable {
        case off
        case watching
        case ready(since: TimeInterval)
        case countdown(endsAt: TimeInterval)
        case capturing
        case cooldown(until: TimeInterval)
        case finished
    }

    enum Action: Equatable, Sendable {
        case none
        case capture
    }

    /// Conditions must hold this long before the countdown starts.
    var holdDuration: TimeInterval = 1.0
    /// Visible countdown before the automatic capture.
    var countdownDuration: TimeInterval = 3.0
    /// Pause after each automatic capture.
    var cooldownDuration: TimeInterval = 5.0
    /// Most automatic captures allowed per enabling. Prevents runaway shooting.
    var maxCaptures: Int = 5
    /// Longest time one enabling may last, so hands-free cannot run unattended for long. Ten minutes by default.
    var maxSessionDuration: TimeInterval = 600

    private(set) var state: State = .off
    private(set) var captures = 0
    /// When this enabling ends by itself.
    private(set) var sessionEnds: TimeInterval = .infinity

    var isEnabled: Bool {
        switch state {
        case .off, .finished: false
        default: true
        }
    }

    mutating func enable(now: TimeInterval = 0) {
        captures = 0
        sessionEnds = now + maxSessionDuration
        state = .watching
    }

    /// Turns hands-free capture off, including any countdown in progress. Used for cancel, backgrounding and heat.
    mutating func disable() {
        state = .off
    }

    /// Feeds one analysis. Returns `.capture` once, when a countdown finishes with conditions still good.
    mutating func update(conditionsGood: Bool, now: TimeInterval) -> Action {
        if isEnabled, now >= sessionEnds {
            state = .finished
            return .none
        }
        switch state {
        case .off, .finished, .capturing:
            return .none
        case .cooldown(let until):
            if now >= until { state = .watching }
            return .none
        case .watching:
            if conditionsGood { state = .ready(since: now) }
            return .none
        case .ready(let since):
            guard conditionsGood else {
                state = .watching
                return .none
            }
            if now - since >= holdDuration { state = .countdown(endsAt: now + countdownDuration) }
            return .none
        case .countdown(let endsAt):
            guard conditionsGood else {
                state = .watching
                return .none
            }
            guard now >= endsAt else { return .none }
            state = .capturing
            return .capture
        }
    }

    /// Call after every `.capture` action, whether or not the photo was taken.
    mutating func didCapture(now: TimeInterval) {
        captures += 1
        state = captures >= maxCaptures ? .finished : .cooldown(until: now + cooldownDuration)
    }

    /// Call when a `.capture` could not take a photo (the camera was busy or stopped). Watching resumes at once and
    /// nothing is counted, so a refused attempt never uses up one of the automatic shots.
    mutating func skipCapture() {
        state = .watching
    }

    /// Whole seconds left in the countdown, rounded up, for display.
    func secondsRemaining(now: TimeInterval) -> Int? {
        guard case .countdown(let endsAt) = state else { return nil }
        return max(1, Int((endsAt - now).rounded(.up)))
    }
}

/// The conditions a hands-free shot needs before its countdown may start. Pure.
/// An unknown blur risk does not block the shot: only a measured high risk does.
enum HandsFreeGate {
    static func conditionsGood(
        readiness: CaptureReadiness,
        guidance: Guidance,
        exposure: ExposureStatus?,
        blurRisk: MotionBlurRisk.Level,
        thermalAllows: Bool
    ) -> Bool {
        guard thermalAllows, readiness.isSteady, blurRisk != .high else { return false }
        guard exposure == .balanced else { return false }
        return guidance == .none || guidance == .greatFraming
    }
}
