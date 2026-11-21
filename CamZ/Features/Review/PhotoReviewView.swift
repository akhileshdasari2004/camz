import SwiftUI
import UIKit

/// The review of the last photo: original versus AI-enhanced, zoom, share, and the save state. Opened from the thumbnail.
/// A photo that has not reached Photos stays here with a retry, so it is never dropped.
struct PhotoReviewView: View {
    @Bindable var model: CameraViewModel
    @State private var split = 0.5
    @State private var images = ReviewImages.empty
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let progress = model.captureProgress {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(progress)
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Processing: \(progress)")
                }

                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let note = model.lastCapture?.fallbackReason {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text(saveStatus)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(model.unsavedPhotos.isEmpty ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Save status: \(saveStatus)")

                actions
            }
            .padding(16)
            .background(Color.black.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { model.isReviewPresented = false }
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .task(id: model.lastCapture?.id) {
                await load()
            }
        }
    }

    private var title: String {
        let photo = model.lastCapture
        return PhotoReviewLogic.title(
            hasOriginal: photo?.original != nil,
            isRawOnly: PhotoReviewLogic.lead(processed: photo?.processed, raw: photo?.raw) == .rawOnly
        )
    }

    private var saveStatus: String {
        PhotoReviewLogic.saveStatusText(
            saved: model.lastCaptureSaved,
            unsavedCount: model.unsavedPhotos.count,
            accessDenied: model.photosAccessDenied
        )
    }

    @ViewBuilder
    private var preview: some View {
        let photo = model.lastCapture
        switch PhotoReviewLogic.lead(processed: photo?.processed, raw: photo?.raw) {
        case .processed:
            if PhotoReviewLogic.canCompare(enhanced: photo?.processed, original: photo?.original),
               let primary = images.primary, let original = images.original {
                ComparisonView(original: original, enhanced: primary, split: $split)
            } else if let primary = images.primary {
                ZoomableImage(image: primary)
            } else {
                ProgressView()
                    .accessibilityLabel("Loading photo")
            }
        case .rawOnly:
            VStack(spacing: 12) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 44, weight: .light))
                Text("The RAW file is saved to Photos. Open it there to edit it.")
                    .font(.body)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .nothing:
            Text("No photo yet. Take one with the shutter.")
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if model.photosAccessDenied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens Cam Z's settings so you can allow adding photos")
            }
            if !model.unsavedPhotos.isEmpty {
                Button {
                    Task { await model.retryUnsavedPhotos() }
                } label: {
                    Label("Retry saving to Photos", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Tries again to save the photos that Photos refused")
            }
            HStack(spacing: 12) {
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityLabel("Share photo")
                }
                Button {
                    if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                } label: {
                    Label("Open in Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityHint("Opens the Photos app")
            }
        }
        .buttonStyle(.bordered)
        .tint(Color.accentColor)
    }

    /// Decodes the pictures off the main thread, and writes a share file with the photo's real type.
    private func load() async {
        guard let photo = model.lastCapture else {
            images = .empty
            shareURL = nil
            return
        }
        let primaryData = photo.processed ?? photo.raw
        let originalData = photo.original
        let decoded = await Task.detached(priority: .userInitiated) { () -> ReviewImages in
            ReviewImages(
                primary: photo.processed.flatMap { UIImage(data: $0) },
                original: originalData.flatMap { UIImage(data: $0) }
            )
        }.value
        images = decoded

        guard let primaryData else {
            shareURL = nil
            return
        }
        let name = PhotoReviewLogic.shareFileName(for: primaryData, capturedAt: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        shareURL = (try? primaryData.write(to: url)) != nil ? url : nil
    }
}

/// The decoded pictures for the review. Empty until they load.
struct ReviewImages {
    var primary: UIImage?
    var original: UIImage?

    static let empty = ReviewImages(primary: nil, original: nil)
}

/// Original on the left, AI-enhanced on the right, divided by a line the user drags. Also adjustable with VoiceOver.
struct ComparisonView: View {
    let original: UIImage
    let enhanced: UIImage
    @Binding var split: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Image(uiImage: enhanced)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                Image(uiImage: original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * split)
                    }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: geo.size.height)
                    .position(x: geo.size.width * split, y: geo.size.height / 2)

                Circle()
                    .fill(Color.white)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                    }
                    .position(x: geo.size.width * split, y: geo.size.height / 2)

                HStack {
                    Text("Original")
                    Spacer()
                    Text("AI-enhanced")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .frame(width: geo.size.width, alignment: .leading)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    split = PhotoReviewLogic.clampedSplit(value.location.x / geo.size.width)
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Comparison: original on the left, AI-enhanced on the right")
        .accessibilityValue("\(Int((split * 100).rounded())) percent enhanced")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = PhotoReviewLogic.clampedSplit(split + 0.1)
            case .decrement: split = PhotoReviewLogic.clampedSplit(split - 0.1)
            @unknown default: break
            }
        }
    }
}

/// A photo at full resolution that zooms with a pinch, pans once zoomed, and resets on a double tap.
struct ZoomableImage: View {
    let image: UIImage
    @State private var zoom: Double = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        let scale = PhotoReviewLogic.clampedZoom(zoom * Double(pinch))
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(
                x: offset.width + (zoom > 1 ? drag.width : 0),
                y: offset.height + (zoom > 1 ? drag.height : 0)
            )
            .gesture(
                MagnificationGesture()
                    .updating($pinch) { value, state, _ in
                        state = value
                    }
                    .onEnded { value in
                        zoom = PhotoReviewLogic.clampedZoom(zoom * Double(value))
                        if zoom == PhotoReviewLogic.minimumZoom { offset = .zero }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .updating($drag) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        guard zoom > 1 else { return }
                        offset = CGSize(
                            width: offset.width + value.translation.width,
                            height: offset.height + value.translation.height
                        )
                    }
            )
            .onTapGesture(count: 2) {
                zoom = PhotoReviewLogic.minimumZoom
                offset = .zero
            }
            .clipped()
            .accessibilityLabel("Photo. Pinch to zoom, drag to pan when zoomed, double tap to reset.")
    }
}
