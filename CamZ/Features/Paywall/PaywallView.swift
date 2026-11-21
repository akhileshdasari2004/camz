import SwiftUI

/// The Cam Z Pro offer. Prices, periods and status come from StoreKit. The free camera stays free.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    let store: StoreService

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
                    }
                    restore
                    fineprint
                }
                .padding(24)
            }
            .background(Color.black.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cam Z Pro")
                .font(.largeTitle.bold())
            Text("The AI director stays free. Pro adds the features below.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ProFeature.allCases, id: \.self) { feature in
                Label(feature.title, systemImage: "checkmark.circle.fill")
                    .font(.body)
            }
            Text("Free: AI exposure, focus, framing guidance, lens choice and the manual shutter.")
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
                Text("Pro is not set up in this build yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .unavailable:
                VStack(alignment: .leading, spacing: 12) {
                    Text("The Pro options could not be loaded. Check your connection and try again.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await store.loadProducts() }
                    }
                }
            case .ready:
                VStack(spacing: 12) {
                    ForEach(store.products) { product in
                        Button {
                            Task { await store.purchase(product) }
                        } label: {
                            VStack(spacing: 4) {
                                Text(product.displayName)
                                    .font(.headline)
                                Text([product.displayPrice, StoreService.periodText(for: product)]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " "))
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentColor)
                        .foregroundStyle(.black)
                        .disabled(store.isWorking)
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
        .frame(maxWidth: .infinity)
    }

    private var fineprint: some View {
        Text("Payment is charged to your Apple ID. A subscription renews automatically unless it is cancelled at least 24 hours before the end of the current period. Manage it in Settings > Apple ID > Subscriptions.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
