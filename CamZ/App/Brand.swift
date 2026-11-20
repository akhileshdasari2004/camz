import SwiftUI

/// The product identity people see. Keep in step with `CFBundleDisplayName` and the usage strings
/// in `project.yml` and `CamZ/Info.plist`.
enum Brand {
    static let name = "Cam Z"
    static let descriptor = "Cam Z — AI Smart Photography"
    static let tagline = "POINT. SNAP. PERFECT."
}

/// The CAM Z wordmark: heavy, rounded and tracked out.
struct BrandWordmark: View {
    var size: CGFloat = 13

    var body: some View {
        Text(Brand.name.uppercased())
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .tracking(size * 0.22)
            .foregroundStyle(.white)
            .accessibilityLabel(Brand.name)
    }
}
