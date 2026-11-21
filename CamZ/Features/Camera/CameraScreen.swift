import SwiftUI

struct CameraScreen: View {
    @State private var model = CameraViewModel()
    @State private var isPinching = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.status {
            case .denied:
                PermissionView()
            case .failed(let message):
                PermissionView(title: "Camera unavailable", message: message, showsSettings: false)
            case .idle, .running:
                camera
            }
        }
        .background {
            if model.status == .running {
                HardwareShutter { Task { await model.capture() } }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.start() }
        .task { await model.store.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.start() }
            case .background: model.stop()
            default: break
            }
        }
        .sheet(isPresented: paywallBinding) {
            PaywallView(
                store: model.store,
                privacyURL: AppConfiguration.current.privacyPolicyURL,
                termsURL: AppConfiguration.current.termsURL
            )
        }
        .sheet(isPresented: optionsBinding) {
            CaptureOptionsView(model: model)
        }
        .sheet(isPresented: reviewBinding) {
            PhotoReviewView(model: model)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.captureCount)
        .sensoryFeedback(.selection, trigger: model.filter)
        .sensoryFeedback(.selection, trigger: model.mode)
    }

    private var optionsBinding: Binding<Bool> {
        Binding(
            get: { model.isOptionsPresented },
            set: { model.isOptionsPresented = $0 }
        )
    }

    private var paywallBinding: Binding<Bool> {
        Binding(
            get: { model.isPaywallPresented },
            set: { model.isPaywallPresented = $0 }
        )
    }

    private var reviewBinding: Binding<Bool> {
        Binding(
            get: { model.isReviewPresented },
            set: { model.isReviewPresented = $0 }
        )
    }

    private var camera: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
                .padding(.horizontal, 20)
                .frame(height: 52)

            viewfinder

            BottomControls(model: model)
                .frame(maxHeight: .infinity)
        }
        .overlay(alignment: .top) { toast }
    }

    // MARK: Viewfinder (3:4 so the preview matches the captured photo exactly)

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                if let renderer = model.renderer {
                    CameraPreview(renderer: renderer)
                }

                if model.showGrid {
                    GridOverlay().allowsHitTesting(false)
                }

                if model.mode == .auto {
                    DirectorStatus(decision: model.decision)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                }

                if model.isHandsFreeOn {
                    HandsFreeOverlay(countdown: model.handsFreeCountdown, message: model.handsFreeMessage) {
                        withAnimation(.snappy) { model.toggleHandsFree() }
                    }
                    .transition(.opacity)
                }

                if model.isBestOfThreeArmed || model.bestOfThreeProgress != nil || model.isChoosingBestShot {
                    BestOfThreeBadge(progress: model.bestOfThreeProgress, choosing: model.isChoosingBestShot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let point = model.focusPoint {
                    FocusIndicator()
                        .position(point)
                        .allowsHitTesting(false)
                        .id(point.x + point.y) // restart the animation on every tap
                }

                if model.showExposure {
                    ExposureSlider(
                        value: Binding(get: { model.exposureBias }, set: { model.setExposure($0) }),
                        range: model.capabilities.minBias...max(model.capabilities.maxBias, model.capabilities.minBias + 0.1)
                    )
                    .frame(maxHeight: .infinity, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                }

                Color.white
                    .opacity(model.shutterFlash ? 0.85 : 0)
                    .animation(.easeOut(duration: 0.12), value: model.shutterFlash)
                    .allowsHitTesting(false)

                if model.isComparing {
                    Text("ORIGINAL")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .padding(.top, 12)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let progress = model.captureProgress {
                    CaptureProgressPill(text: progress, canStop: model.canStopProcessing) {
                        model.cancelProcessing()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .transition(.opacity)
                }

                if let interruption = model.interruption {
                    InterruptionOverlay(message: interruption.message)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.interruption)
            .animation(.easeOut(duration: 0.15), value: model.isComparing)
            .animation(.easeOut(duration: 0.2), value: model.captureProgress)
            .animation(.easeOut(duration: 0.2), value: model.isHandsFreeOn)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    model.focus(atTap: value.location, in: geo.size)
                }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if !isPinching {
                            isPinching = true
                            model.beginZoom()
                        }
                        model.updateZoom(magnification: value.magnification)
                    }
                    .onEnded { _ in isPinching = false }
            )
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement()
        .accessibilityLabel("Viewfinder")
        .accessibilityHint("Tap to focus, pinch to zoom")
    }

    @ViewBuilder
    private var toast: some View {
        if let message = model.toast {
            Text(message)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation { model.toast = nil }
                }
        }
    }
}

/// Hands-free status across the top of the viewfinder, with the countdown and a Stop button.
private struct HandsFreeOverlay: View {
    let countdown: Int?
    let message: String?
    let stop: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                Text(message ?? "Hands-free on")
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Stop", action: stop)
                    .fontWeight(.semibold)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 12)

            Spacer()

            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Capturing in \(countdown)")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
    }
}

/// Shows that best of three is armed, or how far it has got.
private struct BestOfThreeBadge: View {
    let progress: Int?
    let choosing: Bool

    private var text: String {
        if choosing { return "Choosing the sharpest" }
        if let progress { return "Shot \(progress) of 3" }
        return "Best of 3 armed"
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor, in: Capsule())
            .padding(12)
            .accessibilityLabel(text)
    }
}

/// Shown over the viewfinder while the system has taken the camera away.
private struct InterruptionOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text("Camera paused")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    CameraScreen()
}
