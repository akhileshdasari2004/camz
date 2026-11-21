import Foundation

/// Average colour of a frame: gamma-encoded, 0…1 per channel.
struct AverageColor: Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
}

/// The light the frame appears to be lit by. Heuristic: from the average colour cast, not a calibrated measurement.
enum LightSource: Equatable, Sendable {
    case unknown, daylight, overcast, tungsten, fluorescent

    var title: String {
        switch self {
        case .unknown: "Mixed light"
        case .daylight: "Daylight"
        case .overcast: "Overcast"
        case .tungsten: "Warm indoor light"
        case .fluorescent: "Fluorescent light"
        }
    }
}

/// White balance the camera should use.
enum WhiteBalanceMode: Equatable, Sendable {
    /// The camera keeps adjusting white balance continuously. This is the default.
    case continuousAuto
    /// White balance is fixed to keep an intended warm cast. Only proposed when locking is enabled.
    case locked
}

/// Classifies the light and decides whether white balance should stay automatic.
enum WhiteBalanceAdvisor {
    /// Locking white balance stays off until device tests show it beats continuous auto white balance.
    static let lockingEnabled = false
    /// The same source must be seen this many analyses in a row before a lock is considered.
    static let requiredStableFrames = 8

    static func classify(_ color: AverageColor, meanLuma: Float) -> LightSource {
        guard meanLuma > 0.05 else { return .unknown }
        let green = max(color.green, 0.02)
        let redOverGreen = color.red / green
        let blueOverGreen = color.blue / green

        if color.green > color.red * 1.08, color.green > color.blue * 1.08 { return .fluorescent }
        if redOverGreen > 1.15, blueOverGreen < 0.85 { return .tungsten }
        if blueOverGreen > 1.12 { return meanLuma < 0.5 ? .overcast : .daylight }
        if abs(redOverGreen - 1) < 0.12, abs(blueOverGreen - 1) < 0.12, meanLuma > 0.4 { return .daylight }
        return .unknown
    }

    /// Continuous auto white balance unless every condition for a lock holds: locking enabled, an atmospheric scene
    /// (sunset or night), a stable warm source, and enough consecutive frames.
    static func mode(source: LightSource, atmosphericScene: Bool, stableFrames: Int) -> WhiteBalanceMode {
        guard lockingEnabled, atmosphericScene, stableFrames >= requiredStableFrames else {
            return .continuousAuto
        }
        return source == .tungsten ? .locked : .continuousAuto
    }
}
