import Foundation

/// How one shutter press is taken. `.single` is the normal one-tap capture and the default.
enum CaptureStrategy: Equatable, Sendable {
    case single
    /// Exposure brackets at these EV offsets, aligned and merged.
    case hdrBracket(evOffsets: [Float])
    /// Several frames at the same exposure, aligned and averaged to reduce noise.
    case nightBurst(frames: Int)
}

/// The strategy with the reason it was chosen or refused, so the screen and the log can say why.
struct CapturePlan: Equatable, Sendable {
    var strategy: CaptureStrategy
    var reason: String
}

/// What the scene and the camera look like right now. Every value comes from the analysis or the camera.
struct CaptureScene: Equatable, Sendable {
    /// Mean brightness of the frame, 0…1.
    var meanLuma: Float
    var highlightClipping: Float
    var shadowClipping: Float
    var subjectMoving: Bool
    /// Zoom in display units (1× = main lens).
    var displayZoom: CGFloat
    /// Exposure time of one frame at the current settings, in seconds. Nil when the camera has not reported it.
    var exposureSeconds: Double?
    /// 35 mm-equivalent focal length of the lens in use. Nil when unknown.
    var focalLength35mm: Float?
}

/// What the camera can do for bracketed captures.
struct BracketCapability: Equatable, Sendable {
    var supported: Bool
    var maxFrames: Int

    static let none = BracketCapability(supported: false, maxFrames: 0)
}

/// Decides how a shutter press is taken. Pure, so every refusal is tested without a camera.
///
/// Night is considered first, because a dark scene is the case where multi-frame capture helps most. HDR is used only
/// for real contrast: strong clipping at both ends. Anything that would not help falls back to one photo.
enum CapturePlanner {
    /// Frames darker than this (mean luma) are low light.
    static let lowLightMean: Float = 0.25
    /// Highlight clipping above this share, together with shadow clipping, means the scene has more range than one frame holds.
    static let hdrHighlightClipping: Float = 0.01
    static let hdrShadowClipping: Float = 0.05
    /// Most night frames averaged. More frames gain little after about four.
    static let maxNightFrames = 4
    static let hdrOffsets: [Float] = [-2, 0, 2]
    /// Longest zoom for night captures. Telephoto lenses are dimmer and noisier in the dark.
    static let nightMaxZoom: CGFloat = 1.5

    static func plan(
        scene: CaptureScene,
        wantsHDR: Bool,
        wantsNight: Bool,
        capability: BracketCapability
    ) -> CapturePlan {
        guard wantsHDR || wantsNight else {
            return CapturePlan(strategy: .single, reason: "Standard one-tap capture.")
        }

        if wantsNight, scene.meanLuma < lowLightMean {
            if let refusal = nightRefusal(scene: scene, capability: capability) {
                return CapturePlan(strategy: .single, reason: refusal)
            }
            let frames = min(maxNightFrames, capability.maxFrames)
            return CapturePlan(
                strategy: .nightBurst(frames: frames),
                reason: "Dark scene: \(frames) aligned frames will be averaged to reduce noise."
            )
        }

        if wantsHDR, scene.highlightClipping >= hdrHighlightClipping, scene.shadowClipping >= hdrShadowClipping {
            guard capability.supported, capability.maxFrames >= hdrOffsets.count else {
                return CapturePlan(strategy: .single, reason: "Bracketed capture is not available on this camera, so one photo was taken.")
            }
            return CapturePlan(
                strategy: .hdrBracket(evOffsets: hdrOffsets),
                reason: "Strong contrast: exposures at -2, 0 and +2 EV will be aligned and merged."
            )
        }

        if wantsNight, !(scene.meanLuma < lowLightMean) {
            return CapturePlan(strategy: .single, reason: "The scene is bright enough for one photo.")
        }
        return CapturePlan(strategy: .single, reason: "No strong contrast or low light, so one photo is enough.")
    }

    /// Why a night burst cannot run, or nil when it can.
    private static func nightRefusal(scene: CaptureScene, capability: BracketCapability) -> String? {
        guard capability.supported, capability.maxFrames >= 2 else {
            return "Night bursts need bracketed capture, which this camera does not offer, so one photo was taken."
        }
        guard !scene.subjectMoving else {
            return "The subject is moving, so a night burst would ghost. One photo was taken."
        }
        guard scene.displayZoom <= nightMaxZoom else {
            return "Night photos use the main lens. Zoom back to 1× for a night burst."
        }
        guard let exposure = scene.exposureSeconds, exposure > 0 else {
            return "The exposure time is not known yet, so one photo was taken."
        }
        if let focal = scene.focalLength35mm, exposure > 2 / Double(focal) {
            return "Each frame would blur at this exposure time. One photo was taken."
        }
        return nil
    }
}
