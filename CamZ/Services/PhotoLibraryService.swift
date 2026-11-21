import Photos

enum PhotoLibraryError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        "Allow \(Brand.name) to add photos in Settings to save your shots."
    }
}

/// Saves encoded image data to the user's photo library (add-only access).
struct PhotoLibraryService: PhotoSaving {

    func save(_ data: Data) async throws {
        try await save(CapturedPhoto(processed: data))
    }

    /// One Photos asset per capture. The primary photo is the processed image when there is one, otherwise the RAW file.
    /// A RAW file beside a processed photo, or the original beside a computed photo, is added as the alternate resource.
    /// That is how the Camera app stores RAW pairs, and it lets the original be recovered in Photos.
    func save(_ photo: CapturedPhoto) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.notAuthorized }
        guard photo.primaryData != nil else { throw CameraError.captureFailed }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            if let processed = photo.processed {
                request.addResource(with: .photo, data: processed, options: nil)
                if let raw = photo.raw {
                    request.addResource(with: .alternatePhoto, data: raw, options: Self.rawOptions())
                } else if let original = photo.original {
                    request.addResource(with: .alternatePhoto, data: original, options: nil)
                }
            } else if let raw = photo.raw {
                request.addResource(with: .photo, data: raw, options: Self.rawOptions())
            }
        }
    }

    /// Declares the DNG type, which Photos needs to recognise RAW data. ProRAW is DNG too.
    private static func rawOptions() -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.uniformTypeIdentifier = "com.adobe.raw-image"
        return options
    }
}
