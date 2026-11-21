import SwiftUI

struct BottomControls: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        VStack(spacing: 14) {
            ZoomPresetBar(model: model)
                .padding(.top, 10)

            FilterCarousel(selection: $model.filter)

            if model.filter != .original {
                HStack(spacing: 14) {
                    IntensitySlider(value: $model.intensity)
                    CompareButton(isComparing: $model.isComparing)
                }
                .padding(.leading, 40)
                .padding(.trailing, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer(minLength: 0)

            CaptureModeStrip(model: model)

            HStack {
                ThumbnailButton(
                    image: model.lastThumbnail,
                    hasPhoto: model.lastCapture != nil,
                    unsavedCount: model.unsavedPhotos.count
                ) {
                    model.isReviewPresented = true
                }

                Spacer()

                // Stays tappable during an AI merge: a press there cancels the merge and keeps the normal exposure.
                ShutterButton(
                    isBusy: model.interruption != nil || (model.isCapturing && !model.canStopProcessing),
                    label: model.canStopProcessing ? "Stop AI processing" : "Take photo"
                ) {
                    Task { await model.capture() }
                }

                Spacer()

                IconButton(systemName: "arrow.triangle.2.circlepath", label: "Switch camera") {
                    Task { await model.flipCamera() }
                }
                .frame(width: 56, height: 56)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 12)
        }
        .animation(.snappy, value: model.filter == .original)
    }
}

/// Press and hold to see the frame without the filter, like Instagram's editor.
struct CompareButton: View {
    @Binding var isComparing: Bool

    var body: some View {
        Image(systemName: "square.split.2x1")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isComparing ? Color.black : .white)
            .frame(width: 36, height: 36)
            .background(isComparing ? Color.accentColor : .white.opacity(0.08), in: Circle())
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60) {
                // Never fires: the gesture only exists to track pressing.
            } onPressingChanged: { pressing in
                isComparing = pressing
            }
            .sensoryFeedback(.selection, trigger: isComparing)
            .accessibilityLabel("Compare with original")
            .accessibilityHint("Hold to see the photo without the filter")
            .accessibilityAddTraits(.isButton)
    }
}

/// The last photo. Tapping it opens the review: original against AI-enhanced, sharing, and the save state.
struct ThumbnailButton: View {
    let image: UIImage?
    /// False until a photo has been taken.
    let hasPhoto: Bool
    /// Photos the library has not saved yet. A dot shows on the thumbnail while any are waiting.
    let unsavedCount: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.25), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if unsavedCount > 0 {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 14, height: 14)
                        .offset(x: 5, y: -5)
                }
            }
            .animation(.spring(duration: 0.35), value: image)
        }
        .disabled(!hasPhoto)
        .accessibilityLabel(unsavedCount > 0 ? "Last photo, \(unsavedCount) not saved" : "Last photo")
        .accessibilityHint("Opens the review with the original and the AI-enhanced photo")
    }
}
