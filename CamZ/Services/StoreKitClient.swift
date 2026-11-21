import Foundation
import StoreKit

/// A subscription the paywall can offer. Name, price and period are the store's own text, never values from this code.
struct StoreProduct: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let price: String
    /// "per month" and so on, from the store's billing period. Empty when the store reports none.
    let period: String
}

/// The result of asking the store to buy one product.
enum PurchaseOutcome: Equatable, Sendable {
    /// A verified purchase, already finished with the store.
    case purchased(productID: String)
    /// The customer closed the sheet. This is not an error.
    case cancelled
    /// Waiting for approval, such as Ask to Buy.
    case pending
    /// The store returned a purchase that failed verification. Pro stays off.
    case unverified
    /// Any other failure.
    case failed
}

/// What the store reports about the customer's subscriptions.
enum StoreCheck: Equatable, Sendable {
    case subscribed(productID: String)
    case notSubscribed
}

/// The store seam. The live client talks to StoreKit; tests supply a fake, so purchase, restore and entitlement rules
/// run without a store.
@MainActor
protocol StoreKitClient: AnyObject, Sendable {
    /// The products the store knows among `ids`. Throws when the store cannot be reached.
    func loadProducts(ids: [String]) async throws -> [StoreProduct]
    func purchase(productID: String) async -> PurchaseOutcome
    /// The first subscription among `ids` that is verified, current and not revoked.
    func currentSubscription(among ids: [String]) async -> StoreCheck
    /// Re-syncs purchases with the store. Throws when the sync cannot complete.
    func syncPurchases() async throws
    /// Calls `onChange` when a purchase changes outside the app, such as a renewal or a refund.
    func startObservingUpdates(_ onChange: @escaping @MainActor () -> Void)
}

/// The real StoreKit 2 client.
@MainActor
final class LiveStoreKitClient: StoreKitClient {
    private var products: [String: Product] = [:]
    private var updatesTask: Task<Void, Never>?

    func loadProducts(ids: [String]) async throws -> [StoreProduct] {
        let loaded = try await Product.products(for: ids)
        for product in loaded {
            products[product.id] = product
        }
        // Keep the configured order, so the monthly and annual options stay where the configuration puts them.
        return ids.compactMap { id in
            loaded.first { $0.id == id }.map(Self.storeProduct)
        }
    }

    func purchase(productID: String) async -> PurchaseOutcome {
        do {
            if products[productID] == nil {
                _ = try await loadProducts(ids: [productID])
            }
            guard let product = products[productID] else { return .failed }
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return .unverified }
                await transaction.finish()
                return .purchased(productID: transaction.productID)
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    func currentSubscription(among ids: [String]) async -> StoreCheck {
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            guard ids.contains(transaction.productID), transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            return .subscribed(productID: transaction.productID)
        }
        return .notSubscribed
    }

    func syncPurchases() async throws {
        try await AppStore.sync()
    }

    func startObservingUpdates(_ onChange: @escaping @MainActor () -> Void) {
        guard updatesTask == nil else { return }
        updatesTask = Task {
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                onChange()
            }
        }
    }

    static func storeProduct(_ product: Product) -> StoreProduct {
        StoreProduct(
            id: product.id,
            name: product.displayName,
            price: product.displayPrice,
            period: periodText(product)
        )
    }

    /// "per month" and so on, from the billing period StoreKit reports. Empty for products without a period.
    static func periodText(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .day: return "per day"
        case .week: return "per week"
        case .month: return "per month"
        case .year: return "per year"
        @unknown default: return ""
        }
    }
}
