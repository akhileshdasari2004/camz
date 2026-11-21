import AVFoundation
import CoreImage
import ImageIO

/// Handles one capture. AVFoundation calls back once per photo (a RAW file and a processed photo come as two calls),
/// so this collects them and reports the pair only after the whole capture has finished. The processed photo gets the
/// same look as the preview; the RAW file is kept exactly as the camera wrote it.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {

    private let engine: FilterEngine
    private let context: CIContext
    private let fallbackReason: String?
    /// True when the request asked for ProRAW, so the RAW file it returns is recorded as ProRAW.
    private let expectsProRAW: Bool
    private let willCapture: @Sendable () -> Void
    private let completion: (Result<CapturedPhoto, Error>) -> Void
    private var processed: Data?
    private var raw: Data?
    private var rawIsProRAW = false
    private var failure: Error?
    private var didComplete = false

    init(
        engine: FilterEngine,
        context: CIContext,
        fallbackReason: String? = nil,
        expectsProRAW: Bool = false,
        willCapture: @escaping @Sendable () -> Void,
        completion: @escaping (Result<CapturedPhoto, Error>) -> Void
    ) {
        self.engine = engine
        self.context = context
        self.fallbackReason = fallbackReason
        self.expectsProRAW = expectsProRAW
        self.willCapture = willCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            failure = failure ?? error
            return
        }
        if photo.isRawPhoto {
            guard let data = photo.fileDataRepresentation() else {
                failure = failure ?? CameraError.captureFailed
                return
            }
            raw = data
            rawIsProRAW = expectsProRAW
            return
        }
        do {
            processed = try Self.processedData(for: photo, engine: engine, context: context)
        } catch {
            failure = failure ?? error
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { failure = failure ?? error }
        if let failure {
            finish(.failure(failure))
            return
        }
        guard processed != nil || raw != nil else {
            finish(.failure(CameraError.captureFailed))
            return
        }
        finish(.success(CapturedPhoto(processed: processed, raw: raw, rawIsProRAW: rawIsProRAW, fallbackReason: fallbackReason)))
    }

    /// The processed photo with the current look applied. With the original look, the camera's own file is returned untouched.
    private static func processedData(for photo: AVCapturePhoto, engine: FilterEngine, context: CIContext) throws -> Data {
        guard
            let data = photo.fileDataRepresentation(),
            let source = CIImage(data: data, options: [.applyOrientationProperty: true])
        else { throw CameraError.captureFailed }

        // Nothing to do for the untouched look: keep the original file and its metadata.
        guard engine.filter != .original, engine.intensity > 0 else { return data }

        let output = engine.apply(to: source)
            .settingProperties(metadata(from: photo.metadata))
        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!

        if let heif = context.heifRepresentation(of: output, format: .RGBA8, colorSpace: colorSpace, options: [:]) {
            return heif
        }
        if let jpeg = context.jpegRepresentation(of: output, colorSpace: colorSpace, options: [:]) {
            return jpeg
        }
        throw CameraError.captureFailed
    }

    /// Keeps the original EXIF/TIFF metadata (date, lens, exposure…) on the
    /// re-encoded photo. The pixels are already upright, so orientation is reset.
    static func metadata(from original: [String: Any]) -> [String: Any] {
        var metadata = original
        metadata[kCGImagePropertyOrientation as String] = 1

        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        // Dimensions are rewritten by the encoder; stale values would be wrong after rotation.
        if var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = nil
            exif[kCGImagePropertyExifPixelYDimension as String] = nil
            metadata[kCGImagePropertyExifDictionary as String] = exif
        }
        metadata[kCGImagePropertyPixelWidth as String] = nil
        metadata[kCGImagePropertyPixelHeight as String] = nil
        return metadata
    }

    private func finish(_ result: Result<CapturedPhoto, Error>) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
    }
}

/// Collects the frames of one bracketed capture, in the order the camera delivers them. The look is applied after the
/// merge, so every frame is kept unprocessed here.
final class BracketCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {

    private let willCapture: @Sendable () -> Void
    private let completion: (Result<[Data], Error>) -> Void
    private var frames: [Data] = []
    private var failure: Error?
    private var didFlash = false
    private var didComplete = false

    init(willCapture: @escaping @Sendable () -> Void, completion: @escaping (Result<[Data], Error>) -> Void) {
        self.willCapture = willCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // One shutter flash for the whole bracket, not one per frame.
        guard !didFlash else { return }
        didFlash = true
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            failure = failure ?? error
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            failure = failure ?? CameraError.captureFailed
            return
        }
        frames.append(data)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { failure = failure ?? error }
        if let failure {
            finish(.failure(failure))
        } else if frames.isEmpty {
            finish(.failure(CameraError.captureFailed))
        } else {
            finish(.success(frames))
        }
    }

    private func finish(_ result: Result<[Data], Error>) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
    }
}
