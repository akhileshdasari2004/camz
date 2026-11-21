import Foundation

/// Reduces AI work and optional features as the device heats up. Only uses public thermal state.
enum ThermalPolicy {
    /// Seconds between analysed frames for a thermal state.
    static func analysisInterval(for state: ProcessInfo.ThermalState) -> TimeInterval {
        switch state {
        case .nominal, .fair: 0.2
        case .serious: 0.5
        case .critical: 1.0
        @unknown default: 0.5
        }
    }

    /// Hands-free capture is allowed only while the device is not under serious thermal pressure.
    static func allowsHandsFree(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .nominal || state == .fair
    }

    /// Best-of-three capture is allowed only while the device is not under serious thermal pressure.
    static func allowsBestOfThree(_ state: ProcessInfo.ThermalState) -> Bool {
        allowsHandsFree(state)
    }

    /// Multi-frame captures (HDR merges and night bursts) are allowed only while the phone is not under thermal pressure.
    static func allowsComputedCapture(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .nominal || state == .fair
    }
}
