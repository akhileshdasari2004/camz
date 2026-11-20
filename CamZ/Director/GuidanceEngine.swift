import CoreGraphics

/// One piece of on-screen guidance. The viewfinder shows at most one at a time.
enum Guidance: Equatable, Sendable {
    case none
    case holdSteady
    case levelPhone
    case moveLeft
    case moveRight
    case moveCloser
    case stepBack
    case greatFraming

    var message: String? {
        switch self {
        case .none: nil
        case .holdSteady: "Hold steady"
        case .levelPhone: "Level your phone"
        case .moveLeft: "Move slightly left"
        case .moveRight: "Move slightly right"
        case .moveCloser: "Move closer"
        case .stepBack: "Move back a little"
        case .greatFraming: "Great framing"
        }
    }
}

/// Picks the single most useful piece of guidance from the latest analysis.
///
/// Faces are normalised image rects (Vision convention: origin bottom-left, values 0…1).
/// Direction words describe how to move the phone: moving left brings content from the left edge into view.
enum GuidanceEngine {
    /// A subject this close to the frame edge counts as cut off.
    static let edgeMargin: CGFloat = 0.03
    /// A portrait subject smaller than this share of the frame is too far away.
    static let smallSubjectArea: CGFloat = 0.03
    /// A single subject within this distance of centre is moved toward a third.
    static let centreBand: CGFloat = 0.06

    static func advice(
        readiness: CaptureReadiness,
        horizonDegrees: Float?,
        faces: [CGRect],
        scene: SceneKind
    ) -> Guidance {
        // While the phone or focus is moving, the only useful message is to wait.
        guard readiness.isSteady else { return .holdSteady }

        if let degrees = horizonDegrees {
            let tilt = abs(degrees)
            if tilt >= CompositionAnalyzer.horizonThresholdDegrees, tilt <= CompositionAnalyzer.horizonMaxDegrees {
                return .levelPhone
            }
        }

        // Without a person in view there is no subject to judge, so say nothing.
        guard let main = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return .none
        }
        if main.maxY > 1 - edgeMargin { return .stepBack }      // top of the head is cut off
        if main.minX < edgeMargin { return .moveLeft }          // left edge cuts the subject
        if main.maxX > 1 - edgeMargin { return .moveRight }     // right edge cuts the subject
        if faces.count == 1, scene == .portrait, main.width * main.height < smallSubjectArea {
            return .moveCloser
        }
        if faces.count == 1, abs(main.midX - 0.5) < centreBand {
            return .moveRight                                   // moves the subject toward the left third
        }
        return .greatFraming
    }
}
