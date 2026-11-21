import AVFoundation
import SwiftUI

struct TopBar: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        GeometryReader { geo in
            // Sizes follow the screen width, so every control fits on compact iPhones. See `TopBarLayout`.
            let style = TopBarLayout.style(availableWidth: geo.size.width, rightButtons: TopBarLayout.rightButtonCount)
            HStack(spacing: 0) {
                if model.capabilities.hasFlash {
                    IconButton(systemName: flashIcon, isActive: model.flashMode != .off, label: flashLabel, size: style.buttonSize) {
                        model.cycleFlash()
                    }
                } else {
                    Color.clear.frame(width: style.buttonSize, height: style.buttonSize)
                }

                Spacer(minLength: 2)

                // The wordmark sits at a lens preset when there is room; the zoom readout shows otherwise.
                Group {
                    if style.showsWordmark, isAtPreset {
                        BrandWordmark(size: 12)
                            .transition(.opacity)
                    } else {
                        Text(String(format: "%.1f×", model.displayZoom))
                            .font(.system(.footnote, design: .rounded).monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityLabel("Zoom \(String(format: "%.1f", model.displayZoom)) times")
                            .transition(.opacity)
                    }
                }
                .animation(.snappy, value: isAtPreset)

                Spacer(minLength: 2)

                HStack(spacing: style.spacing) {
                    IconButton(
                        systemName: "sparkles",
                        isActive: model.mode == .auto,
                        label: model.mode == .auto ? "Auto mode on" : "Auto mode off",
                        showsLock: !model.isAllowed(.manualControls),
                        size: style.buttonSize
                    ) {
                        withAnimation(.snappy) { model.toggleMode() }
                    }
                    IconButton(systemName: "plusminus.circle", isActive: model.showExposure, label: "Exposure", size: style.buttonSize) {
                        withAnimation(.snappy) { model.showExposure.toggle() }
                    }
                    IconButton(
                        systemName: "slider.horizontal.3",
                        isActive: optionsChanged,
                        label: "Capture options",
                        size: style.buttonSize
                    ) {
                        model.isOptionsPresented = true
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var isAtPreset: Bool {
        model.zoomPresets.contains { abs($0 - model.displayZoom) < 0.05 }
    }

    /// True when any capture option differs from the default, so the button shows it.
    private var optionsChanged: Bool {
        model.captureFormat != .processed || model.isHDREnabled || model.isNightModeEnabled || model.showGrid
    }

    private var flashIcon: String {
        switch model.flashMode {
        case .on: "bolt.fill"
        case .auto: "bolt.badge.automatic.fill"
        default: "bolt.slash.fill"
        }
    }

    private var flashLabel: String {
        switch model.flashMode {
        case .on: "Flash on"
        case .auto: "Flash auto"
        default: "Flash off"
        }
    }
}

struct IconButton: View {
    let systemName: String
    var isActive = false
    let label: String
    /// Shows a small lock when the feature needs Cam Z Pro.
    var showsLock = false
    /// Side length in points. Never below the 44-point touch minimum; see `TopBarLayout`.
    var size: CGFloat = TopBarLayout.minimumTouchTarget
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.425, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : .white)
                .frame(width: size, height: size)
                .background(.white.opacity(0.08), in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    if showsLock {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(3)
                            .background(Color.accentColor, in: Circle())
                    }
                }
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Circle())
        }
        .accessibilityLabel(showsLock ? "\(label), needs Cam Z Pro" : label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
