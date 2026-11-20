#if DEBUG
import Foundation
import os

/// Debug-only diagnostics for device testing. Decisions and capture timing go to the system log, which Xcode's console
/// and Console.app show. Only labels and numbers are written: no photos, no image data, no metadata, and nothing is
/// sent off the device.
enum DeviceLog {
    private static let logger = Logger(subsystem: "com.akhilesh.camz", category: "director")

    static func decision(_ decision: PhotoDecision, bias: Float, zoom: CGFloat) {
        let exposure = decision.exposure
        let confidence = decision.sceneIsConfident ? "" : "?"
        let focus = decision.focusTarget.map { "\(format(Float($0.x))),\(format(Float($0.y)))" } ?? "-"
        let line = [
            "scene=\(decision.scene.title)\(confidence)",
            "light=\(decision.lighting.title)",
            "exposure=\(exposure?.status.title ?? "-")",
            "delta=\(format(exposure?.suggestedBiasDelta ?? 0))",
            "bias=\(format(bias))",
            "zoom=\(format(Float(zoom)))",
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

    private static func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }
}
#endif
