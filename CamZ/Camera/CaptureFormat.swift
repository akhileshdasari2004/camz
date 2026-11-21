import Foundation

/// What the user asked the shutter to save.
enum CaptureFormat: String, CaseIterable, Identifiable, Sendable {
    /// One processed photo (HEIC, or JPEG where HEIC is unavailable). The default.
    case processed
    /// Bayer RAW (DNG) straight from the sensor, with no processing by the camera.
    case raw
    /// Apple ProRAW (DNG), where the device and the photo output support it.
    case proRAW

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processed: "Photo"
        case .raw: "RAW"
        case .proRAW: "ProRAW"
        }
    }
}

/// A RAW pixel format the photo output offers. `CameraService` classifies each one with AVFoundation.
struct RawFormatCandidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case appleProRAW
        case bayer
    }

    let code: UInt32
    let kind: Kind
}

/// The capture chosen for this device and camera, with the reason when the request could not be met exactly.
struct CaptureFormatChoice: Equatable, Sendable {
    /// The RAW format to request, or nil for a processed-only capture.
    var raw: RawFormatCandidate?
    /// Whether a processed photo is captured too. With RAW alone this is false.
    var savesProcessed: Bool
    /// Why the request could not be met exactly. Nil when it was met.
    var fallbackReason: String?
}

/// Chooses the capture format from what the hardware actually offers. Pure, so every fallback is tested without a camera.
enum CaptureFormatSelector {
    static let noRawReason = "RAW is not available on this camera, so a processed photo was taken."
    static let noProRAWReason = "ProRAW is not available on this device, so Bayer RAW was taken."

    /// - Parameters:
    ///   - format: What the user asked for.
    ///   - alongsideProcessed: Keep a processed photo as well, saved as a Photos pair with the RAW file.
    ///   - candidates: The RAW formats the photo output offers right now (empty when there are none).
    ///   - proRAWAllowed: True only when ProRAW is enabled on the photo output for this device and session.
    static func choose(
        format: CaptureFormat,
        alongsideProcessed: Bool,
        candidates: [RawFormatCandidate],
        proRAWAllowed: Bool
    ) -> CaptureFormatChoice {
        let bayer = candidates.first { $0.kind == .bayer }
        let proRAW = candidates.first { $0.kind == .appleProRAW }

        switch format {
        case .processed:
            return CaptureFormatChoice(raw: nil, savesProcessed: true, fallbackReason: nil)

        case .raw:
            guard let bayer else {
                return CaptureFormatChoice(raw: nil, savesProcessed: true, fallbackReason: noRawReason)
            }
            return CaptureFormatChoice(raw: bayer, savesProcessed: alongsideProcessed, fallbackReason: nil)

        case .proRAW:
            if proRAWAllowed, let proRAW {
                return CaptureFormatChoice(raw: proRAW, savesProcessed: alongsideProcessed, fallbackReason: nil)
            }
            if let bayer {
                return CaptureFormatChoice(raw: bayer, savesProcessed: alongsideProcessed, fallbackReason: noProRAWReason)
            }
            return CaptureFormatChoice(raw: nil, savesProcessed: true, fallbackReason: noRawReason)
        }
    }
}
