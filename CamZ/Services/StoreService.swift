import Foundation
import Observation
import StoreKit

/// Owns Cam Z Pro: loads the configured subscriptions, buys, restores, and keeps Pro access current.
///
/// Product IDs come from Info.plist (`CamZProMonthlyProductID`, `CamZProAnnualProductID`). When they are empty, the
/// paywall says Pro is not set up in this build and sells nothing. Prices and periods come from StoreKit, never from code.
@MainActor
@Observable
final class StoreService: ProAccessing {

    enum LoadState: Equatable {
        case notConfigured
        case loading
        case ready
        case unavailable
    }

    /// The outcome of asking StoreKit which subscription is active.
    enum StoreCheck: Sendable, Equatable {
        case subscribed(productID: String)
        case notSubscribed
    }

    private(set) var products: [Product] = []
    private(set) var loadState: LoadState
    private(set) var isPro: Bool
    private(set) var isWorking = false
    /// Result of the last purchase or restore, for the paywall to show. Nil when there is nothing to say.
    private(set) var message: String?

    private let productIDs: [String]
    private let defaults: UserDefaults
    private var cache: CachedEntitlement?
    private var updatesTask: Task<Void, Never>?

    private static let cacheKey = "camz.pro.entitlement"
    /// Longest wait for StoreKit's entitlement list before the cached answer is used instead.
    private static let storeTimeout: Duration = .seconds(8)

    init(productIDs: [String] = StoreService.configuredProductIDs(), defaults: UserDefaults = .standard) {
        self.productIDs = productIDs
        self.defaults = defaults
        let cached = Self.loadCache(from: defaults)
        self.cache = cached
        self.isPro = EntitlementPolicy.isPro(storeAnswer: nil, cached: cached, now: Date())
        self.loadState = productIDs.isEmpty ? .notConfigured : .loading
    }

    /// Product IDs from Info.plist. Empty when the build has none configured.
    nonisolated static func configuredProductIDs(bundle: Bundle = .main) -> [String] {
        EntitlementPolicy.productIDs(from: [
            bundle.object(forInfoDictionaryKey: "CamZProMonthlyProductID") as? String,
            bundle.object(forInfoDictionaryKey: "CamZProAnnualProductID") as? String
        ])
    }

    /// Call once at launch. Listens for purchases made outside the app, loads the products and checks access.
    func start() async {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    guard let self else { return }
                    if case .verified(let transaction) = update {
                        await transaction.finish()
                    }
                    await self.refreshAccess()
                }
            }
        }
        await loadProducts()
        await refreshAccess()
    }

    func loadProducts() async {
        guard !productIDs.isEmpty else {
            products = []
            loadState = .notConfigured
            return
        }
        loadState = .loading
        do {
            let loaded = try await Product.products(for: productIDs)
            // Keep the configured order, so the monthly and annual options stay where the configuration puts them.
            products = productIDs.compactMap { id in loaded.first { $0.id == id } }
            loadState = products.isEmpty ? .unavailable : .ready
        } catch {
            products = []
            loadState = .unavailable
        }
    }

    /// Asks StoreKit which subscription is active and updates the cached answer. If StoreKit does not answer in time,
    /// the last confirmed answer keeps Pro working for up to `EntitlementPolicy.offlineGrace`.
    func refreshAccess() async {
        let ids = productIDs
        let check = await Self.withTimeout(Self.storeTimeout) { await Self.check(productIDs: ids) }

        let storeAnswer: Bool?
        let activeProductID: String?
        switch check {
        case .subscribed(let productID)?:
            storeAnswer = true
            activeProductID = productID
        case .notSubscribed?:
            storeAnswer = false
            activeProductID = nil
        case nil:
            storeAnswer = nil
            activeProductID = nil
        }

        let now = Date()
        cache = EntitlementPolicy.updatedCache(
            storeAnswer: storeAnswer,
            activeProductID: activeProductID,
            previous: cache,
            now: now
        )
        saveCache()
        isPro = EntitlementPolicy.isPro(storeAnswer: storeAnswer, cached: cache, now: now)
    }

    func purchase(_ product: Product) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = "The purchase could not be verified, so Pro was not unlocked."
                    return
                }
                await transaction.finish()
                await refreshAccess()
                message = isPro ? "Cam Z Pro is active." : "The purchase is not active yet. Try Restore Purchases."
            case .userCancelled:
                message = nil
            case .pending:
                message = "The purchase is waiting for approval."
            @unknown default:
                message = "The purchase did not complete."
            }
        } catch {
            message = "The purchase did not complete. Please try again."
        }
    }

    func restore() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppStore.sync()
            await refreshAccess()
            message = isPro ? "Purchases restored. Cam Z Pro is active." : "No active Cam Z Pro subscription was found for this Apple ID."
        } catch {
            message = "Restore did not complete. Check your connection and try again."
        }
    }

    /// "per month" and so on, from the billing period StoreKit reports. Empty for products without a period.
    static func periodText(for product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .day: return "per day"
        case .week: return "per week"
        case .month: return "per month"
        case .year: return "per year"
        @unknown default: return ""
        }
    }

    // MARK: Private

    /// The first configured subscription StoreKit reports as verified, current and not revoked.
    nonisolated static func check(productIDs: [String]) async -> StoreCheck {
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            guard productIDs.contains(transaction.productID), transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            return .subscribed(productID: transaction.productID)
        }
        return .notSubscribed
    }

    /// Runs `operation`, or returns nil when it takes longer than `limit`.
    nonisolated static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func loadCache(from defaults: UserDefaults) -> CachedEntitlement? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedEntitlement.self, from: data)
    }

    private func saveCache() {
        if let cache, let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Self.cacheKey)
        } else {
            defaults.removeObject(forKey: Self.cacheKey)
        }
    }
}
