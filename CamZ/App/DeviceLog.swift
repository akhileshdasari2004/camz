#if DEBUG
import Foundation
import os

/// Debug-only diagnostics for device testing. Decisions, capture timing and best-of-three scores go to the system log,
/// which Xcode's console and Console.app show. Only labels and numbers are written: no photos, no image data, no metadata,
/// and nothing is sent off the device.
enum DeviceLog {
    private static let logger = Logger(subsystem: "com.akhilesh.camz", category: "director")

    static func decision(_ decision: PhotoDecision, bias: Float, zoom: CGFloat) {
        let exposure = decision.exposure
        let confidence = decision.sceneIsConfident ? "" : "?"
        let focus = decision.focusTarget.map { "\(format(Float($0.x))),\(format(Float($0.y)))" } ?? "-"
        let line = [
            "scene=\(decision.scene.title)\(confidence)",
            "light=\(decision.lighting.title)",
            "source=\(decision.lightSource.title)",
            "exposure=\(exposure?.status.title ?? "-")",
            "delta=\(format(exposure?.suggestedBiasDelta ?? 0))",
            "bias=\(format(bias))",
            "zoom=\(format(Float(zoom)))",
            "blur=\(decision.blurRisk)",
            "focus=\(focus)",
            "readiness=\(decision.readiness)",
            "guidance=\(decision.guidance.message ?? "-")",
            "faces=\(decision.faceCount)"
        ].joined(separator: " ")
        logger.debug("\(line, privacy: .public)")
    }

    static func capture(waited: TimeInterval, outcome: String) {
        let line = "capture waited=\(format(Float(waited)))s outcome=\(outcome)"
        logger.info("\(line, privacy: .public)")
    }

    /// A hands-free event, such as "countdown" or "capture".
    static func handsFree(_ event: String) {
        logger.info("handsfree \(event, privacy: .public)")
    }

    /// Best-of-three scores: one sharpness value per shot (or "-" when it could not be scored), and the chosen shot.
    static func bestOfThree(sharpness: [Float?], chosen: Int, eyesOpen: Bool?) {
        let scores = sharpness.map { value in value.map { format($0) } ?? "-" }.joined(separator: ",")
        let eyes = eyesOpen.map { $0 ? "yes" : "no" } ?? "-"
        let line = "bestof3 sharpness=[\(scores)] chosen=\(chosen + 1) eyesOpen=\(eyes)"
        logger.info("\(line, privacy: .public)")
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }
}
#endif
