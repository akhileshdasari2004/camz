import SwiftUI

/// Hands-free and best of three, shown above the shutter rather than in the top bar. Each pill is at least 44 points
/// tall, shows its state, and carries a lock when the mode needs Cam Z Pro.
struct CaptureModeStrip: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        HStack(spacing: 10) {
            ModePill(
                title: "Hands-free",
                systemName: "timer",
                isOn: model.isHandsFreeOn,
                needsPro: !model.isAllowed(.handsFree)
            ) {
                withAnimation(.snappy) { model.toggleHandsFree() }
            }
            ModePill(
                title: "Best of 3",
                systemName: "square.stack.3d.up",
                isOn: model.isBestOfThreeArmed,
                needsPro: !model.isAllowed(.bestOfThree)
            ) {
                withAnimation(.snappy) { model.toggleBestOfThree() }
            }
        }
    }
}

private struct ModePill: View {
    let title: String
    let systemName: String
    let isOn: Bool
    let needsPro: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.footnote.weight(.semibold))
                if needsPro {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(isOn ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 44)
            .background(isOn ? Color.accentColor : Color.white.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("\(title), \(isOn ? "on" : "off")\(needsPro ? ", needs Cam Z Pro" : "")")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
