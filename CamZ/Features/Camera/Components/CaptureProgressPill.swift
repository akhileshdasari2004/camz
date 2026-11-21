import SwiftUI

/// What a capture is doing, shown over the viewfinder, such as "Merging exposures". While an AI merge runs, Stop AI cancels
/// it, and the photo is saved with the normal exposure, so the press is never lost.
struct CaptureProgressPill: View {
    let text: String
    let canStop: Bool
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.black)
            Text(text)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if canStop {
                Button("Stop AI", action: stop)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.black)
                    .tint(.black)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Stops the AI merge and saves the normal exposure")
            }
        }
        .foregroundStyle(.black)
        .padding(.leading, 14)
        .padding(.trailing, canStop ? 4 : 14)
        .padding(.vertical, canStop ? 0 : 8)
        .background(Color.accentColor, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture in progress: \(text)")
    }
}
