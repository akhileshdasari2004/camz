import Foundation

/// Product settings read from Info.plist. Changing a key changes what is gated, sold or linked, without touching camera
/// code. Missing or invalid values fall back to safe defaults: nothing is sold, and the camera keeps working.
struct AppConfiguration: Equatable, Sendable {
    /// Features that need Cam Z Pro. Standard capture is never in this set.
    var gatedFeatures: Set<ProFeature>
    /// Subscription product IDs. Nil when not set, so the store is not configured in this build.
    var monthlyProductID: String?
    var annualProductID: String?
    /// Legal links for the paywall. Nil until the pages exist, so the app never shows a dead link.
    var privacyPolicyURL: URL?
    var termsURL: URL?

    static let gatedFeaturesKey = "CamZProGatedFeatures"
    static let monthlyKey = "CamZProMonthlyProductID"
    static let annualKey = "CamZProAnnualProductID"
    static let privacyKey = "CamZPrivacyPolicyURL"
    static let termsKey = "CamZTermsURL"

    /// Today's Pro split. Changing it is a product decision, made here rather than in the camera code.
    static let defaultGatedFeatures: Set<ProFeature> = [.handsFree, .bestOfThree, .manualControls]

    /// Reads the configuration from a bundle's Info.plist values. Pure over the dictionary, so it is tested directly.
    static func parse(_ info: [String: Any]) -> AppConfiguration {
        AppConfiguration(
            gatedFeatures: gatedFeatures(from: info[gatedFeaturesKey] as? [String]),
            monthlyProductID: nonEmpty(info[monthlyKey] as? String),
            annualProductID: nonEmpty(info[annualKey] as? String),
            privacyPolicyURL: httpsURL(info[privacyKey] as? String),
            termsURL: httpsURL(info[termsKey] as? String)
        )
    }

    /// Feature names from configuration. Nil means "not configured" and gives the default split. An empty list gates
    /// nothing. Unknown names are ignored rather than failing.
    static func gatedFeatures(from names: [String]?) -> Set<ProFeature> {
        guard let names else { return defaultGatedFeatures }
        return Set(names.compactMap { ProFeature(rawValue: $0) })
    }

    /// Only secure web links are accepted, so a typo cannot open an unsafe or invalid address.
    static func httpsURL(_ text: String?) -> URL? {
        guard let text = nonEmpty(text), let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The configuration of the running app.
    static let current: AppConfiguration = parse(Bundle.main.infoDictionary ?? [:])
}
