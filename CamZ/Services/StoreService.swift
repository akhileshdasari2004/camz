import Foundation
import Observation

/// Owns Cam Z Pro access: loads the configured subscriptions, buys, restores, and keeps the entitlement current.
///
/// Product IDs come from Info.plist through `AppConfiguration`. When they are missing, the paywall says Pro is not set up
/// and sells nothing; the camera keeps working. Prices and periods come from the store, never from this code.
/// StoreKit is reached only through `StoreKitClient`, so the rules here are tested with a fake store.
@MainActor
@Observable
final class StoreService: ProAccessing {

    enum LoadState: Equatable {
        case notConfigured
        case loading
        case ready
        case unavailable
    }

    private(set) var products: [StoreProduct] = []
    private(set) var loadState: LoadState
    private(set) var isPro: Bool
    private(set) var isWorking = false
    /// Result of the last purchase or restore, for the paywall to show. Nil when there is nothing to say.
    private(set) var message: String?
    /// DEBUG builds only: treat Pro as unlocked for development testing. Ignored in release builds.
    var developmentUnlockOn: Bool = false {
        didSet { defaults.set(developmentUnlockOn, forKey: DevelopmentAccess.unlockKey) }
    }

    /// Whether Pro features may run: the store's answer, or the development unlock in DEBUG builds.
    var hasProAccess: Bool {
        ProAccessResolver.effectivePro(
            storeIsPro: isPro,
            developmentUnlockOn: developmentUnlockOn,
            developmentAllowed: DevelopmentAccess.isAvailableInThisBuild
        )
    }

    private let productIDs: [String]
    private let defaults: UserDefaults
    private let client: StoreKitClient
    private let storeTimeout: Duration
    private var cache: CachedEntitlement?
    private var isObservingUpdates = false

    private static let cacheKey = "camz.pro.entitlement"

    /// - Parameters:
    ///   - productIDs: The subscriptions to offer. Empty means the store is not configured.
    ///   - defaults: Where the last confirmed entitlement is kept, for the offline grace period.
    ///   - client: The store. Nil uses the live StoreKit client.
    ///   - storeTimeout: How long to wait for the store before using the cached confirmation.
    init(
        productIDs: [String] = StoreService.configuredProductIDs(),
        defaults: UserDefaults = .standard,
        client: StoreKitClient? = nil,
        storeTimeout: Duration = .seconds(8)
    ) {
        self.productIDs = productIDs
        self.defaults = defaults
        self.client = client ?? LiveStoreKitClient()
        self.storeTimeout = storeTimeout
        let cached = Self.loadCache(from: defaults)
        self.cache = cached
        self.isPro = EntitlementPolicy.isPro(storeAnswer: nil, cached: cached, now: Date())
        self.developmentUnlockOn = defaults.object(forKey: DevelopmentAccess.unlockKey) as? Bool ?? DevelopmentAccess.unlockByDefault
        self.loadState = productIDs.isEmpty ? .notConfigured : .loading
    }

    /// Product IDs from Info.plist. Empty when the build has none configured.
    nonisolated static func configuredProductIDs(bundle: Bundle = .main) -> [String] {
        let config = AppConfiguration.parse(bundle.infoDictionary ?? [:])
        return EntitlementPolicy.productIDs(from: [config.monthlyProductID, config.annualProductID])
    }

    /// Call once at launch. Listens for purchases made outside the app, loads the products and checks access.
    func start() async {
        if !isObservingUpdates {
            isObservingUpdates = true
            client.startObservingUpdates { [weak self] in
                Task { await self?.refreshAccess() }
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
            let loaded = try await client.loadProducts(ids: productIDs)
            products = loaded
            loadState = loaded.isEmpty ? .unavailable : .ready
        } catch {
            products = []
            loadState = .unavailable
        }
    }

    /// Asks the store which subscription is active and updates the cached answer. If the store does not answer in time,
    /// the last confirmed answer keeps Pro working for up to `EntitlementPolicy.offlineGrace`.
    func refreshAccess() async {
        let ids = productIDs
        let client = client
        let check = await Self.withTimeout(storeTimeout) { await client.currentSubscription(among: ids) }

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

    /// Buys one product and says what happened. A cancelled purchase is not an error, so it says nothing.
    func purchase(productID: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let outcome = await client.purchase(productID: productID)
        if case .purchased = outcome {
            await refreshAccess()
        }
        message = Self.message(for: outcome, isProAfterPurchase: isPro)
    }

    /// Re-syncs purchases and says whether a subscription was found.
    func restore() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.syncPurchases()
            await refreshAccess()
            message = isPro
                ? "Purchases restored. Cam Z Pro is active."
                : "No active Cam Z Pro subscription was found for this Apple ID."
        } catch {
            message = "Restore did not complete. Check your connection and try again."
        }
    }

    /// The paywall message for a purchase outcome. Pure, so every outcome is tested.
    static func message(for outcome: PurchaseOutcome, isProAfterPurchase: Bool) -> String? {
        switch outcome {
        case .purchased:
            isProAfterPurchase ? "Cam Z Pro is active." : "The purchase is not active yet. Try Restore Purchases."
        case .cancelled:
            nil
        case .pending:
            "The purchase is waiting for approval."
        case .unverified:
            "The purchase could not be verified, so Pro was not unlocked."
        case .failed:
            "The purchase did not complete. Please try again."
        }
    }

    // MARK: Private

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

/// The Pro answer the camera uses: the store's, plus the development unlock in DEBUG builds.
@MainActor
final class EffectiveProAccess: ProAccessing {
    private let store: StoreService

    init(store: StoreService) {
        self.store = store
    }

    var isPro: Bool { store.hasProAccess }
}
