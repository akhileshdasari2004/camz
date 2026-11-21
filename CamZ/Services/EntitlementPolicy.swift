import Foundation

/// Features that need Cam Z Pro. One subscription unlocks all of them.
enum ProFeature: String, CaseIterable, Sendable {
    /// AI-triggered capture after a visible countdown. The manual shutter always stays available.
    case handsFree
    /// Three quick shots, keeping the sharpest one with open eyes.
    case bestOfThree
    /// Pro mode: exposure and focus are left to the user.
    case manualControls
    /// RAW and ProRAW capture. Free by default; configurable in Info.plist.
    case rawCapture
    /// Bracketed HDR merge. Free by default; configurable in Info.plist.
    case hdrBracketing
    /// Multi-frame night captures. Free by default; configurable in Info.plist.
    case nightBurst

    var title: String {
        switch self {
        case .handsFree: "Hands-free AI capture"
        case .bestOfThree: "Best of three"
        case .manualControls: "Pro mode controls"
        case .rawCapture: "RAW capture"
        case .hdrBracketing: "HDR merge"
        case .nightBurst: "Night burst"
        }
    }
}

/// What the store confirmed the last time it could be asked, kept on the device so Pro can work offline for a while.
struct CachedEntitlement: Codable, Equatable, Sendable {
    var productID: String
    var verifiedAt: Date
}

/// Pure rules for who has Pro. Tested without StoreKit.
enum EntitlementPolicy {
    /// How long a confirmed Pro entitlement keeps working when the store cannot be asked.
    static let offlineGrace: TimeInterval = 14 * 24 * 60 * 60

    /// Whether Pro is active.
    /// - Parameters:
    ///   - storeAnswer: The latest store check. `true` when an active subscription was found, `false` when none was,
    ///     and `nil` when the store did not answer in time.
    ///   - cached: The last confirmed entitlement. Used only when the store did not answer.
    static func isPro(storeAnswer: Bool?, cached: CachedEntitlement?, now: Date) -> Bool {
        if let storeAnswer { return storeAnswer }
        guard let cached else { return false }
        let age = now.timeIntervalSince(cached.verifiedAt)
        // A confirmation dated in the future means the clock was changed, so it is not trusted.
        return age >= 0 && age <= offlineGrace
    }

    /// The cache after a store check. A confirmed answer replaces it, a confirmed "no" clears it, and no answer keeps it.
    static func updatedCache(
        storeAnswer: Bool?,
        activeProductID: String?,
        previous: CachedEntitlement?,
        now: Date
    ) -> CachedEntitlement? {
        switch storeAnswer {
        case true?:
            return CachedEntitlement(productID: activeProductID ?? previous?.productID ?? "", verifiedAt: now)
        case false?:
            return nil
        case nil:
            return previous
        }
    }

    /// Product IDs from configuration: trimmed, with empty and missing entries dropped.
    static func productIDs(from configured: [String?]) -> [String] {
        configured.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Whether a feature may run. Gated features need Pro; the rest are free. `gated` comes from `AppConfiguration`, so the
    /// split can change without touching camera code.
    static func allows(
        _ feature: ProFeature,
        isPro: Bool,
        gated: Set<ProFeature> = AppConfiguration.defaultGatedFeatures
    ) -> Bool {
        !gated.contains(feature) || isPro
    }
}

/// Anything that can say whether Pro is active. View models depend on this protocol, so tests can supply a fixed answer.
@MainActor
protocol ProAccessing: AnyObject {
    var isPro: Bool { get }
}

/// Development access, so every feature can be tested in DEBUG builds without a purchase. It is compiled out of release
/// builds: the store's answer is the only way to Pro in a shipped app.
enum DevelopmentAccess {
    /// True only in DEBUG builds.
    static var isAvailableInThisBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Default for the development switch: on in DEBUG builds, so features can be tested straight away.
    static var unlockByDefault: Bool { isAvailableInThisBuild }

    static let unlockKey = "camz.dev.unlockPro"
}

/// Decides whether Pro applies. The store answer is the production rule. The development unlock adds a path only in DEBUG
/// builds, and only while its switch is on.
enum ProAccessResolver {
    static func effectivePro(storeIsPro: Bool, developmentUnlockOn: Bool, developmentAllowed: Bool) -> Bool {
        storeIsPro || (developmentAllowed && developmentUnlockOn)
    }
}

/// Used when no store is wired in. Pro is off, and free features keep working.
@MainActor
final class NoProAccess: ProAccessing {
    var isPro: Bool { false }
}
