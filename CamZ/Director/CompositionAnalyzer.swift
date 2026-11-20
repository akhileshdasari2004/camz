import Foundation

/// One piece of composition guidance for the viewfinder. Guidance only; the camera never crops or rotates on its own.
enum CompositionAdvice: Equatable, Sendable {
    case none
    /// The horizon is tilted by `degrees` (signed). Shown as "level the horizon".
    case levelHorizon(degrees: Float)
    /// A single person sits dead-centre, which usually looks static.
    case offsetSubject

    var message: String? {
        switch self {
        case .none: nil
        case .levelHorizon: "Level the horizon"
        case .offsetSubject: "Move off-centre for a stronger frame"
        }
    }
}

enum CompositionAnalyzer {
    /// Smaller tilts are within normal hand movement and not worth a prompt.
    static let horizonThresholdDegrees: Float = 2
    /// Larger angles are almost always the scene itself, not a tilted phone, so no prompt.
    static let horizonMaxDegrees: Float = 25
    /// A face within this distance of the frame centre counts as dead-centre.
    static let centreTolerance: Float = 0.05

    static func advice(horizonDegrees: Float?, faceCount: Int, faceCenterX: Float?) -> CompositionAdvice {
        if let degrees = horizonDegrees {
            let tilt = abs(degrees)
            if tilt >= horizonThresholdDegrees, tilt <= horizonMaxDegrees {
                return .levelHorizon(degrees: degrees)
            }
        }
        if faceCount == 1, let x = faceCenterX, abs(x - 0.5) < centreTolerance {
            return .offsetSubject
        }
        return .none
    }
}
