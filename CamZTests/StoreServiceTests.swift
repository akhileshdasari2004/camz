import Foundation
import XCTest
@testable import CamZ

/// A store that answers from fields the test sets, so purchase, restore and entitlement rules run without StoreKit.
@MainActor
final class FakeStoreKitClient: StoreKitClient {
    var products: [StoreProduct] = []
    var loadError: Error?
    var purchaseOutcome: PurchaseOutcome = .failed
    /// What the store reports as the active subscription. Nil means none.
    var subscription: StoreCheck?
    /// Simulates a store that answers slowly.
    var checkDelay: Duration?
    var syncError: Error?
    private(set) var purchaseRequests: [String] = []
    private(set) var syncCount = 0

    func loadProducts(ids: [String]) async throws -> [StoreProduct] {
        if let loadError { throw loadError }
        return ids.compactMap { id in products.first { $0.id == id } }
    }

    func purchase(productID: String) async -> PurchaseOutcome {
        purchaseRequests.append(productID)
        return purchaseOutcome
    }

    func currentSubscription(among ids: [String]) async -> StoreCheck {
        if let checkDelay {
            try? await Task.sleep(for: checkDelay)
        }
        return subscription ?? .notSubscribed
    }

    func syncPurchases() async throws {
        syncCount += 1
        if let syncError { throw syncError }
    }

    func startObservingUpdates(_ onChange: @escaping @MainActor () -> Void) {}
}

@MainActor
final class StoreServiceTests: XCTestCase {

    private let monthly = "com.example.camz.pro.monthly"
    private let annual = "com.example.camz.pro.annual"
    private var client: FakeStoreKitClient!

    override func setUp() async throws {
        client = FakeStoreKitClient()
        client.products = [
            StoreProduct(id: monthly, name: "Cam Z Pro Monthly", price: "$4.99", period: "per month"),
            StoreProduct(id: annual, name: "Cam Z Pro Annual", price: "$39.99", period: "per year")
        ]
    }

    private func makeStore(ids: [String]? = nil, timeout: Duration = .seconds(8)) throws -> StoreService {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CamZTests.store.\(UUID().uuidString)"))
        return StoreService(productIDs: ids ?? [monthly, annual], defaults: defaults, client: client, storeTimeout: timeout)
    }

    // MARK: Products

    func testMissingProductIDsLeaveTheStoreNotConfigured() throws {
        let store = try makeStore(ids: [])
        XCTAssertEqual(store.loadState, .notConfigured)
        XCTAssertTrue(store.products.isEmpty)
    }

    func testProductsLoadInTheConfiguredOrderWithTheStoresText() async throws {
        let store = try makeStore()
        await store.loadProducts()
        XCTAssertEqual(store.loadState, .ready)
        XCTAssertEqual(store.products.map(\.id), [monthly, annual])
        XCTAssertEqual(store.products.first?.price, "$4.99", "prices come from the store, not from this code")
    }

    func testAnEmptyStoreResponseIsUnavailable() async throws {
        client.products = []
        let store = try makeStore()
        await store.loadProducts()
        XCTAssertEqual(store.loadState, .unavailable)
    }

    func testAStoreErrorIsUnavailableAndCanRecover() async throws {
        client.loadError = TestError()
        let store = try makeStore()
        await store.loadProducts()
        XCTAssertEqual(store.loadState, .unavailable)
        client.loadError = nil
        await store.loadProducts()
        XCTAssertEqual(store.loadState, .ready)
    }

    // MARK: Purchases

    func testASuccessfulPurchaseUnlocksPro() async throws {
        let store = try makeStore()
        client.purchaseOutcome = .purchased(productID: monthly)
        client.subscription = .subscribed(productID: monthly)
        await store.purchase(productID: monthly)
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.message, "Cam Z Pro is active.")
        XCTAssertEqual(client.purchaseRequests, [monthly])
    }

    func testAPurchaseThatIsNotYetActiveSaysSo() async throws {
        let store = try makeStore()
        client.purchaseOutcome = .purchased(productID: monthly)
        client.subscription = .notSubscribed
        await store.purchase(productID: monthly)
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.message, "The purchase is not active yet. Try Restore Purchases.")
    }

    func testACancelledPurchaseIsQuietAndLeavesProOff() async throws {
        let store = try makeStore()
        client.purchaseOutcome = .cancelled
        await store.purchase(productID: monthly)
        XCTAssertFalse(store.isPro)
        XCTAssertNil(store.message, "cancelling is not an error")
    }

    func testAPendingPurchaseDoesNotUnlockPro() async throws {
        let store = try makeStore()
        client.purchaseOutcome = .pending
        await store.purchase(productID: monthly)
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.message, "The purchase is waiting for approval.")
    }

    func testAnUnverifiedPurchaseNeverUnlocksPro() async throws {
        let store = try makeStore()
        client.purchaseOutcome = .unverified
        client.subscription = .subscribed(productID: monthly)
        await store.purchase(productID: monthly)
        XCTAssertFalse(store.isPro, "an unverified transaction is not an entitlement")
        XCTAssertEqual(store.message, "The purchase could not be verified, so Pro was not unlocked.")
    }

    func testAFailedPurchaseSaysSo() async throws {
        let store = try makeStore()
        client.purchaseOutcome = .failed
        await store.purchase(productID: monthly)
        XCTAssertEqual(store.message, "The purchase did not complete. Please try again.")
    }

    func testPurchasesRunOneAfterAnotherInOrder() async throws {
        let store = try makeStore()
        client.purchaseOutcome = .cancelled
        await store.purchase(productID: monthly)
        await store.purchase(productID: annual)
        XCTAssertEqual(client.purchaseRequests, [monthly, annual], "each request runs once, in order")
    }

    // MARK: Restore

    func testRestoreFindsAnExistingSubscription() async throws {
        let store = try makeStore()
        client.subscription = .subscribed(productID: annual)
        await store.restore()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.message, "Purchases restored. Cam Z Pro is active.")
        XCTAssertEqual(client.syncCount, 1)
    }

    func testRestoreWithoutASubscriptionSaysSo() async throws {
        let store = try makeStore()
        await store.restore()
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.message, "No active Cam Z Pro subscription was found for this Apple ID.")
    }

    func testARestoreThatCannotSyncSaysSo() async throws {
        let store = try makeStore()
        client.syncError = TestError()
        await store.restore()
        XCTAssertEqual(store.message, "Restore did not complete. Check your connection and try again.")
    }

    // MARK: Entitlement rules

    func testAStoreThatSaysNoClearsAConfirmation() async throws {
        let store = try makeStore()
        client.subscription = .subscribed(productID: monthly)
        await store.refreshAccess()
        XCTAssertTrue(store.isPro)
        client.subscription = .notSubscribed
        await store.refreshAccess()
        XCTAssertFalse(store.isPro, "a confirmed 'no' is final, even if a confirmation was cached")
    }

    func testASlowStoreFallsBackToTheCachedConfirmation() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CamZTests.store.\(UUID().uuidString)"))
        client.subscription = .subscribed(productID: monthly)
        let first = StoreService(productIDs: [monthly], defaults: defaults, client: client, storeTimeout: .seconds(8))
        await first.refreshAccess()
        XCTAssertTrue(first.isPro)

        // A new launch, with a store that does not answer in time: the confirmation keeps Pro working offline.
        client.checkDelay = .seconds(5)
        let second = StoreService(productIDs: [monthly], defaults: defaults, client: client, storeTimeout: .milliseconds(100))
        XCTAssertTrue(second.isPro, "the cache applies at launch")
        await second.refreshAccess()
        XCTAssertTrue(second.isPro, "the store did not answer, so the recent confirmation is used")
    }

    func testMessagesCoverEveryPurchaseOutcome() {
        XCTAssertEqual(StoreService.message(for: .purchased(productID: "x"), isProAfterPurchase: true), "Cam Z Pro is active.")
        XCTAssertNil(StoreService.message(for: .cancelled, isProAfterPurchase: false))
        XCTAssertNotNil(StoreService.message(for: .pending, isProAfterPurchase: false))
        XCTAssertNotNil(StoreService.message(for: .unverified, isProAfterPurchase: false))
        XCTAssertNotNil(StoreService.message(for: .failed, isProAfterPurchase: false))
    }

    // MARK: Development unlock

    func testTheDevelopmentUnlockIsOnByDefaultOnlyInDebugBuilds() throws {
        let store = try makeStore()
        XCTAssertEqual(store.developmentUnlockOn, DevelopmentAccess.unlockByDefault)
        XCTAssertTrue(DevelopmentAccess.isAvailableInThisBuild, "these tests run in a DEBUG build")
        XCTAssertTrue(store.hasProAccess, "DEBUG builds can test every feature without a purchase")
    }

    func testTheDevelopmentUnlockCanBeSwitchedOff() throws {
        let store = try makeStore()
        store.developmentUnlockOn = false
        XCTAssertFalse(store.hasProAccess)
        XCTAssertFalse(store.isPro, "the store answer itself is unchanged")
    }

    func testProductionAccessNeverComesFromTheDevelopmentUnlock() {
        XCTAssertFalse(ProAccessResolver.effectivePro(storeIsPro: false, developmentUnlockOn: true, developmentAllowed: false))
        XCTAssertTrue(ProAccessResolver.effectivePro(storeIsPro: true, developmentUnlockOn: false, developmentAllowed: false))
        XCTAssertTrue(ProAccessResolver.effectivePro(storeIsPro: false, developmentUnlockOn: true, developmentAllowed: true))
        XCTAssertFalse(ProAccessResolver.effectivePro(storeIsPro: false, developmentUnlockOn: false, developmentAllowed: true))
    }
}
