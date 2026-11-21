import Foundation

/// Exposure facts read from the active camera, used to judge how likely a shot is to blur.
struct ExposureSnapshot: Equatable, Sendable {
    /// Exposure duration in seconds.
    var exposureSeconds: Double
    /// ISO sensitivity of the active camera.
    var iso: Float
    /// Horizontal field of view of the active format in degrees, when AVFoundation reports it.
    var fieldOfViewDegrees: Float?
}

/// Estimates blur risk from exposure duration against the handheld limit for the lens in use.
enum MotionBlurRisk {
    enum Level: Equatable, Sendable {
        case unknown, low, medium, high
    }

    /// Width of a 35 mm full-frame sensor, used for 35 mm-equivalent focal lengths.
    static let fullFrameWidthMM: Float = 36

    /// 35 mm-equivalent focal length, derived from the horizontal field of view. Nil when the field of view is unusable.
    static func focalLength35mm(fieldOfViewDegrees: Float) -> Float? {
        guard fieldOfViewDegrees > 1, fieldOfViewDegrees < 179 else { return nil }
        let halfAngle = fieldOfViewDegrees * Float.pi / 360
        return (fullFrameWidthMM / 2) / tan(halfAngle)
    }

    /// Safe handheld exposure time for a 35 mm-equivalent focal length: the common 1/focal rule.
    static func safeExposureSeconds(focal35mm: Float) -> Double {
        1 / Double(focal35mm)
    }

    /// Horizontal field of view at a zoom factor, from the field of view of the lens at 1×. Approximate: it assumes a
    /// simple crop of the same sensor area.
    static func fieldOfView(baseDegrees: Float, zoom: CGFloat) -> Float {
        let magnification = Float(max(zoom, 1))
        let halfAngle = baseDegrees * Float.pi / 360
        return 2 * atan(tan(halfAngle) / magnification) * 180 / Float.pi
    }

    /// Blur risk for the current exposure. Unknown when the camera has not reported the needed values.
    static func level(snapshot: ExposureSnapshot?, subjectMoving: Bool) -> Level {
        guard
            let snapshot,
            snapshot.exposureSeconds.isFinite,
            snapshot.exposureSeconds > 0,
            let fov = snapshot.fieldOfViewDegrees,
            let focal = focalLength35mm(fieldOfViewDegrees: fov)
        else { return .unknown }

        let ratio = snapshot.exposureSeconds / safeExposureSeconds(focal35mm: focal)
        if ratio > 2 || (subjectMoving && ratio > 1) { return .high }
        if ratio > 1 { return .medium }
        return .low
    }
}
