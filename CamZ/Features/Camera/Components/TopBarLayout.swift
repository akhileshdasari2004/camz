import CoreGraphics

/// Sizes the top bar so its controls fit the screen width. Pure, so the fit is tested for each iPhone width.
///
/// The bar holds a flash (or blank) slot on the left, the zoom readout or wordmark in the centre, and the control group on
/// the right. Every control is at least `minimumTouchTarget` points, so no size shrinks below the touch minimum. The
/// wordmark is kept whenever it fits; otherwise the zoom readout takes its place.
enum TopBarLayout {
    struct Style: Equatable, Sendable {
        var buttonSize: CGFloat
        var spacing: CGFloat
        var showsWordmark: Bool
    }

    /// The smallest a touch target may be, from Apple's human interface guidelines.
    static let minimumTouchTarget: CGFloat = 44
    /// Controls on the right of the bar: Auto, Exposure and Options. Hands-free and best of three sit in the mode strip.
    static let rightButtonCount = 3
    /// Padding on each side of the bar, matching the camera screen.
    static let edgePadding: CGFloat = 20
    /// Room kept free so neighbouring controls never touch.
    static let safetyGap: CGFloat = 16
    static let wordmarkWidth: CGFloat = 64
    static let zoomReadoutWidth: CGFloat = 40

    /// Width the bar needs: left slot, centre, and the right group of `rightButtons` controls.
    static func contentWidth(buttonSize: CGFloat, spacing: CGFloat, rightButtons: Int, centreWidth: CGFloat) -> CGFloat {
        buttonSize + centreWidth + CGFloat(rightButtons) * buttonSize + CGFloat(max(0, rightButtons - 1)) * spacing
    }

    /// The largest style that fits in `availableWidth` points, with the wordmark when it fits. The caller passes the bar's own
    /// width, after its padding. When nothing fits, the narrowest style is returned.
    static func style(availableWidth: CGFloat, rightButtons: Int) -> Style {
        let usable = availableWidth - safetyGap
        let options = [
            Style(buttonSize: minimumTouchTarget, spacing: 4, showsWordmark: true),
            Style(buttonSize: minimumTouchTarget, spacing: 4, showsWordmark: false)
        ]
        for option in options {
            let centre = option.showsWordmark ? wordmarkWidth : zoomReadoutWidth
            let needed = contentWidth(
                buttonSize: option.buttonSize,
                spacing: option.spacing,
                rightButtons: rightButtons,
                centreWidth: centre
            )
            if needed <= usable { return option }
        }
        return options[options.count - 1]
    }
}
