import SwiftUI

/// The Cam Z Pro offer. Names, prices, periods and status come from the store. The free camera stays free.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    let store: StoreService
    /// Legal pages, shown only once they are configured. Nil hides the link rather than showing a dead one.
    var privacyURL: URL?
    var termsURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    features
                    offers
                    if let message = store.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Purchase status: \(message)")
                    }
                    restore
                    disclosures
                    legalLinks
                }
                .padding(24)
            }
            .background(Color.black.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cam Z Pro")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("The AI director stays free. Pro adds the features below.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([ProFeature.handsFree, .bestOfThree, .manualControls], id: \.self) { feature in
                Label(feature.title, systemImage: "checkmark.circle.fill")
                    .font(.body)
            }
            Text("Free: AI exposure, focus, framing guidance, lens choice, the manual shutter, saving photos, and RAW, HDR and night capture.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var offers: some View {
        if store.isPro {
            Label("Cam Z Pro is active on this Apple ID.", systemImage: "checkmark.seal.fill")
                .font(.headline)
        } else {
            switch store.loadState {
            case .notConfigured:
                Text("Pro is not set up in this build yet. The camera works without it.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Loading Pro options")
            case .unavailable:
                VStack(alignment: .leading, spacing: 12) {
                    Text("The Pro options could not be loaded. Check your connection and try again. The camera works without them.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await store.loadProducts() }
                    }
                    .frame(minHeight: 44)
                }
            case .ready:
                VStack(spacing: 12) {
                    ForEach(store.products) { product in
                        Button {
                            Task { await store.purchase(productID: product.id) }
                        } label: {
                            VStack(spacing: 4) {
                                Text(product.name)
                                    .font(.headline)
                                Text([product.price, product.period].filter { !$0.isEmpty }.joined(separator: " "))
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentColor)
                        .foregroundStyle(.black)
                        .disabled(store.isWorking)
                        .accessibilityLabel("\(product.name), \([product.price, product.period].filter { !$0.isEmpty }.joined(separator: " "))")
                    }
                }
            }
        }
    }

    private var restore: some View {
        Button("Restore purchases") {
            Task { await store.restore() }
        }
        .disabled(store.isWorking)
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    /// Subscription terms required before a subscription can be sold.
    private var disclosures: some View {
        Text("Cam Z Pro is an auto-renewing subscription. Payment is charged to your Apple ID when you confirm. The subscription renews at the price shown unless it is cancelled at least 24 hours before the end of the current period. Manage or cancel it in Settings > Apple ID > Subscriptions. Free features stay free without a subscription.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var legalLinks: some View {
        if privacyURL != nil || termsURL != nil {
            HStack(spacing: 16) {
                if let privacyURL {
                    Link("Privacy Policy", destination: privacyURL)
                }
                if let termsURL {
                    Link("Terms of Use", destination: termsURL)
                }
            }
            .font(.footnote)
            .frame(minHeight: 44)
        }
    }
}
