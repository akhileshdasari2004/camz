import SwiftUI

struct PermissionView: View {
    var title = "\(Brand.name) needs the camera"
    var message = "Allow camera access in Settings to start taking AI-directed photos."
    var showsSettings = true

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                BrandWordmark(size: 15)
                Text(Brand.tagline)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Brand.descriptor)

            Image(systemName: "camera.aperture")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
                .padding(.top, 8)
            }
        }
        .padding(32)
    }
}

#Preview {
    PermissionView().preferredColorScheme(.dark)
}
