#if DEBUG && canImport(Playbook)
import Playbook
import StoreKit
import SwiftUI

/// Catalog scenarios for `SubscriptionPaywallSheet`.
///
/// The sheet derives every piece of copy from `subscriptionManager.entitlements.pro`
/// via the pure `SubscriptionPaywallCopy` enum, and branches its whole layout on
/// `subscriptionManager.hasProAccess`. So we drive the surface through UI World
/// entitlement fixtures plus a synthetic `PreviewSubscriptionManager` mock — no
/// network, no StoreKit, no local subscription data factory.
///
/// `SubscriptionManaging` is `@MainActor`-isolated, so the mock is constructed
/// inside a `View` body (`PaywallScene`), never synchronously inside a `Scenario`
/// closure.
enum PaywallScenarios {
    static func register(in playbook: Playbook) {
        playbook.addScenarios(of: "Paywall") {
            Scenario("Paywall (inactive)", layout: .fill) {
                PaywallScene(fixtureID: .free)
            }
            Scenario("Pro active (renewing)", layout: .fill) {
                PaywallScene(fixtureID: .pro)
            }
            Scenario("Pro cancelled but active", layout: .fill) {
                PaywallScene(fixtureID: .cancelledButActive)
            }
            Scenario("Admin granted", layout: .fill) {
                PaywallScene(fixtureID: .adminGranted)
            }
        }
    }
}

// MARK: - Scene harness

/// Builds the `@MainActor` mock inside a main-actor-isolated `body`, then injects
/// it into the sheet's environment.
private struct PaywallScene: View {
    let fixtureID: UIWorldEntitlementsFixtureID

    var body: some View {
        let seed = FixtureDatasetStore.requireEntitlementsSeed(for: fixtureID)
        AppThemeContainer {
            SubscriptionPaywallSheet()
                .environment(\.subscriptionManager, PreviewSubscriptionManager(seed: seed))
        }
        .environmentObject(AppAppearanceStore.preview)
    }
}

// MARK: - Mock

/// Inert `SubscriptionManaging` for catalog rendering. All async actions are no-ops.
@MainActor
private final class PreviewSubscriptionManager: SubscriptionManaging {
    var entitlements: KGEntitlements
    var isLoading: Bool = false
    var lastError: String?
    var productLoadFailed = false
    var activePaywallSource: PaywallSource?
    var proProduct: Product?
    var proProductIdentifier: String = BrandIdentity.proProductID
    var purchaseStatusMessage: String?

    var hasProAccess: Bool { entitlements.pro.is_active }

    init(seed: UIWorldEntitlementsSeed) {
        self.entitlements = KGEntitlements(pro: seed.pro)
    }

    func refresh(using kgService: any KGServing, authManager: any AuthManaging, force: Bool) async {}
    func resyncAfterManagement(using kgService: any KGServing, authManager: any AuthManaging) async {}
    func loadProducts() async {}
    func purchasePro(using kgService: any KGServing, authManager: any AuthManaging) async {}
    func restorePurchases(using kgService: any KGServing, authManager: any AuthManaging) async {}
    func listenForTransactionUpdates(using kgService: any KGServing, authManager: any AuthManaging) {}
}
#endif
