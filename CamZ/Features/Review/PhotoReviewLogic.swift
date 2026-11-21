import Foundation

/// The rules behind the photo review: what can be compared, how far the divider and zoom may move, what a shared file is
/// called, and what the save status says. Pure, so every rule is tested without a screen.
enum PhotoReviewLogic {
    static let minimumZoom: Double = 1
    static let maximumZoom: Double = 4

    /// A comparison needs both pictures, and they must differ. A failed enhancement leaves only one picture.
    static func canCompare(enhanced: Data?, original: Data?) -> Bool {
        guard let enhanced, let original, !enhanced.isEmpty, !original.isEmpty else { return false }
        return enhanced != original
    }

    /// The divider position: 0 is all original, 1 is all enhanced. Anything outside that range is pulled back into it.
    static func clampedSplit(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    static func clampedZoom(_ value: Double) -> Double {
        guard value.isFinite else { return minimumZoom }
        return min(max(value, minimumZoom), maximumZoom)
    }

    /// Which picture the review leads with. Always the photo that was taken, so the review never hides a valid photo.
    enum Lead: Equatable {
        case processed
        case rawOnly
        case nothing
    }

    static func lead(processed: Data?, raw: Data?) -> Lead {
        if let processed, !processed.isEmpty { return .processed }
        if let raw, !raw.isEmpty { return .rawOnly }
        return .nothing
    }

    /// The file extension for a photo, read from its first bytes. Used for the share file, so the receiver gets a real type.
    static func fileExtension(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "dng" }
        if data.count > 12, data[4..<8].elementsEqual("ftyp".utf8) { return "heic" }
        return "img"
    }

    /// The name of the file a share sends. Based on the time of the capture, so names do not repeat.
    static func shareFileName(for data: Data, capturedAt: Date) -> String {
        let stamp = Int(capturedAt.timeIntervalSince1970)
        return "CamZ-\(stamp).\(fileExtension(for: data))"
    }

    /// The save status shown on the review screen.
    static func saveStatusText(saved: Bool, unsavedCount: Int, accessDenied: Bool = false) -> String {
        if unsavedCount > 0 {
            if accessDenied {
                return "Photos access is off. Allow Cam Z to add photos in Settings, then retry."
            }
            return unsavedCount == 1
                ? "1 photo is not saved yet. Retry to save it to Photos."
                : "\(unsavedCount) photos are not saved yet. Retry to save them to Photos."
        }
        return saved ? "Saved to Photos." : "Saving to Photos…"
    }

    /// What the photo is called on the review screen: a computed photo that kept its original is an enhancement.
    static func title(hasOriginal: Bool, isRawOnly: Bool) -> String {
        if isRawOnly { return "RAW file" }
        return hasOriginal ? "AI-enhanced photo" : "Photo"
    }
}
