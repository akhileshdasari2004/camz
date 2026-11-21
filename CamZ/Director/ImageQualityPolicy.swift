import Foundation

/// Processing strength for photos this app computes (HDR merges, night averages). A plain one-tap photo is never
/// processed: the camera's own file is kept as it is.
///
/// Every value here is conservative on purpose. Sharpening is always zero, because it adds halos along high-contrast
/// edges, and noise reduction stays low so fine detail survives. Until device tests prove more, nothing here claims to
/// beat Apple's Camera.
enum ImageQualityPolicy {
    /// Sharpening is never applied to computed photos.
    static let sharpness: Float = 0

    /// Luminance noise reduction strength (Core Image `inputNoiseLevel`) for an ISO. Clean images get none.
    static func noiseLevel(iso: Float) -> Float {
        guard iso.isFinite, iso > 400 else { return 0 }
        // Linear from 0 at ISO 400 to 0.02 at ISO 3200, then flat. Stronger smoothing would erase detail.
        let fraction = min(1, (iso - 400) / 2800)
        return 0.02 * fraction
    }

    /// Highlight amount for Core Image `CIHighlightShadowAdjust`: 1 leaves highlights alone, lower values recover them.
    /// Recovery is limited to 40 % so highlights never go grey.
    static func highlightAmount(highlightClipping: Float) -> Float {
        guard highlightClipping.isFinite, highlightClipping > 0 else { return 1 }
        let recovery = 0.4 * min(1, highlightClipping * 10)
        return 1 - recovery
    }

    /// Shadow amount for `CIHighlightShadowAdjust`: 0 leaves shadows alone. Lift is limited to 30 %, so blacks stay black.
    static func shadowAmount(shadowClipping: Float) -> Float {
        guard shadowClipping.isFinite, shadowClipping > 0 else { return 0 }
        return 0.3 * min(1, shadowClipping * 4)
    }
}
