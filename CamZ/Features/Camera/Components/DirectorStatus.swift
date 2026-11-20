import SwiftUI

/// The AI indicator and composition guidance, shown over the bottom of the viewfinder in Auto mode.
struct DirectorStatus: View {
    let decision: PhotoDecision

    var body: some View {
        VStack(spacing: 8) {
            if let message = decision.composition.message {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                    .transition(.opacity)
            }

            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .symbolEffect(.pulse, isActive: !decision.readiness.isSteady)
                    Text("AI")
                }
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: Capsule())

                Text(summary)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
        }
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.2), value: decision.composition)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Brand.name) AI: \(summary)")
    }

    private var summary: String {
        switch decision.readiness {
        case .moving: "Hold steady · \(decision.scene.title)"
        case .settling: "Focusing · \(decision.scene.title)"
        case .steady:
            "\(decision.scene.title) · \(decision.exposure?.status.title ?? decision.lighting.title)"
        }
    }
}
