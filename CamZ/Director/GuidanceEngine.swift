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
    case lowerCamera
    case raiseCamera
    case greatFraming

    var message: String? {
        switch self {
        case .none: nil
        case .holdSteady: "Hold steady"
        case .levelPhone: "Level the horizon"
        case .moveLeft: "Move slightly left"
        case .moveRight: "Move slightly right"
        case .moveCloser: "Move closer"
        case .stepBack: "Move back a little"
        case .lowerCamera: "Lower your camera"
        case .raiseCamera: "Raise your camera"
        case .greatFraming: "Perfect framing"
        }
    }
}

/// Picks the single most useful piece of guidance from the latest analysis.
///
/// Faces are normalised image rects (Vision convention: origin bottom-left, values 0…1).
/// Direction words describe how to move the phone: moving left brings content from the left edge into view.
/// Everyone in view is judged as one group box, so nobody is left cut off at an edge.
/// "Perfect framing" means no framing rule fired. It is not a judgement of photographic quality.
enum GuidanceEngine {
    /// A subject this close to the frame edge counts as cut off.
    static let edgeMargin: CGFloat = 0.03
    /// A single portrait subject smaller than this share of the frame is too far away.
    static let smallSubjectArea: CGFloat = 0.03
    /// A single subject within this distance of centre is moved toward a third.
    static let centreBand: CGFloat = 0.06
    /// A subject whose centre is above this height sits high in the frame: raise the camera.
    static let highCentreY: CGFloat = 0.8
    /// A subject whose centre is below this height sits low in the frame: lower the camera.
    static let lowCentreY: CGFloat = 0.2

    static func advice(
        readiness: CaptureReadiness,
        horizonDegrees: Float?,
        faces: [CGRect],
        scene: SceneKind,
        blurRisk: MotionBlurRisk.Level = .low
    ) -> Guidance {
        // While the phone or focus is moving, or the exposure is too long to hand-hold, the only useful message is to wait.
        guard readiness.isSteady, blurRisk != .high else { return .holdSteady }

        if let degrees = horizonDegrees {
            let tilt = abs(degrees)
            if tilt >= CompositionAnalyzer.horizonThresholdDegrees, tilt <= CompositionAnalyzer.horizonMaxDegrees {
                return .levelPhone
            }
        }

        // Without a person in view there is no subject to judge, so say nothing.
        guard let subject = subjectBox(of: faces) else { return .none }
        let lone = faces.count == 1

        if subject.maxY > 1 - edgeMargin { return .stepBack }     // a head is cut off at the top
        if subject.minY < edgeMargin { return .lowerCamera }      // a subject is cut off at the bottom
        if subject.minX < edgeMargin { return .moveLeft }         // the left edge cuts the group
        if subject.maxX > 1 - edgeMargin { return .moveRight }    // the right edge cuts the group
        if lone, scene == .portrait, subject.width * subject.height < smallSubjectArea {
            return .moveCloser
        }
        if subject.midY > highCentreY { return .raiseCamera }     // subject sits high: tilt the camera up
        if subject.midY < lowCentreY { return .lowerCamera }      // subject sits low: tilt the camera down
        if lone, abs(subject.midX - 0.5) < centreBand {
            return .moveRight                                     // moves the subject toward the left third
        }
        return .greatFraming
    }

    /// One box around everyone in view, or nil when there are no faces.
    static func subjectBox(of faces: [CGRect]) -> CGRect? {
        faces.reduce(nil as CGRect?) { box, face in box.map { $0.union(face) } ?? face }
    }
}
