import SwiftUI
import StoreKit

struct SubscriptionPaywallSheet: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.dismiss) private var dismiss
    @Environment(\.subscriptionManager) private var subscriptionManager
    @Environment(\.authManager) private var authManager
    @Environment(\.kgService) private var kgService
    /// StoreKit 對此使用者有資格的免費試用天數；nil＝無 offer／不符資格／尚未解析。
    @State private var introTrialDays: Int?

    private var activeFeatures: [SettingsSubscriptionFeatureItem] {
        SubscriptionPaywallFeatureCatalog.activeItems(successTone: appSkin.palette.success)
    }

    private var paywallFeatures: [SettingsSubscriptionFeatureItem] {
        SubscriptionPaywallFeatureCatalog.paywallItems(accentTone: appSkin.palette.accent)
    }

    /// Free vs Pro 對照表 — 強化升級決策資訊密度
    private var comparisonRows: [SettingsPlanComparisonRow] {
        SubscriptionPaywallFeatureCatalog.comparisonRows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if subscriptionManager.hasProAccess {
                    activeLayout
                } else {
                    inactiveLayout
                }
            }
            .background(appSkin.palette.pageBackground.ignoresSafeArea())
            .navigationTitle(L10n.string("訂閱"))
            .inlineNavigationBarTitle()
            .task {
                await subscriptionManager.loadProducts()
            }
            .task(id: subscriptionManager.proProduct?.id) {
                introTrialDays = await PaywallIntroOffer.eligibleFreeTrialDays(for: subscriptionManager.proProduct)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("完成")) { dismiss() }
                }
            }
            .animatePhaseChange(subscriptionManager.hasProAccess)
            .animatePhaseChange(subscriptionManager.entitlements.pro.will_renew)
        }
        .enableInjection()
    }

    // MARK: - 已啟用 Layout（確認式）

    private var activeLayout: some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.sheetSectionSpacing) {
            // Hero 確認
            VStack(spacing: appSkin.spacing.controlGap) {
                Image(systemName: isCancelledButActive ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(appSkin.typography.symbolHero)
                    .foregroundStyle(isCancelledButActive ? appSkin.palette.accent : appSkin.palette.success)

                Text(isCancelledButActive ? L10n.string("Pro 即將到期") : L10n.string("Pro 已啟用"))
                    .font(appSkin.typography.displayTitle)
                    .foregroundStyle(appSkin.palette.primaryText)

                Text(activeSummaryText)
                    .font(appSkin.typography.body)
                    .foregroundStyle(appSkin.palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, appSkin.spacing.inlineGap)

            // 功能已解鎖列表
            SettingsSubscriptionFeatureList(
                borderTone: appSkin.palette.success.opacity(0.2),
                items: activeFeatures
            )

            // 來源資訊
            SettingsSubscriptionInfoBlock(
                title: priceLine,
                detail: L10n.format("權限來源：%@", entitlementSourceLine),
                titleFont: appSkin.typography.caption
            )

            // 管理按鈕
            VStack(spacing: appSkin.spacing.controlGap) {
                if !isAdminGranted {
                    Button {
                        Task {
                            await PlatformStore.manageSubscriptions()
                            await subscriptionManager.resyncAfterManagement(using: kgService, authManager: authManager)
                        }
                    } label: {
                        paywallActionLabel(
                            title: L10n.string("管理訂閱"),
                            trailingSystemImage: "arrow.up.forward"
                        )
                    }
                    .buttonStyle(.vocabAction(.primary))
                    .disabled(subscriptionManager.isLoading)
                }

                Button {
                    Task {
                        await subscriptionManager.refresh(using: kgService, authManager: authManager, force: true)
                    }
                } label: {
                    paywallActionLabel(
                        title: primaryActionTitle,
                        isLoading: subscriptionManager.isLoading
                    )
                }
                .buttonStyle(.vocabAction(.neutral))
                .disabled(subscriptionManager.isLoading)
            }

            purchaseStatusCard

            Text(footerNote)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)

            legalLinksFooter
        }
        .padding(appSkin.spacing.sheetPaddingCompact)
    }

    // MARK: - 未啟用 Layout（行銷式）

    private var inactiveLayout: some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.sheetSectionSpacing) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(appSkin.typography.symbolHero)
                .foregroundStyle(appSkin.palette.accent)

            Text("Books & Vocab Pro")
                .font(appSkin.typography.displayTitle)
                .foregroundStyle(appSkin.palette.primaryText)

            Text(paywallSummaryText)
                .font(appSkin.typography.body)
                .foregroundStyle(appSkin.palette.secondaryText)
                .lineSpacing(6)

            // 價格區塊（金額最突出，試用為次要 — 3.1.2(c) 合規）
            SettingsSubscriptionInfoBlock(
                title: billedAmountLine,
                subtitle: trialInfoLine,
                detail: L10n.format("權限來源：%@", entitlementSourceLine),
                titleFont: appSkin.typography.sectionTitle
            )

            // 功能列（行銷式 — 強調你「缺少」什麼）
            SettingsSubscriptionFeatureList(
                borderTone: appSkin.palette.cardBorder,
                items: paywallFeatures
            )

            // Free vs Pro 對照表
            SettingsPlanComparisonTable(rows: comparisonRows)

            // CTA 按鈕（強烈）
            VStack(spacing: appSkin.spacing.controlGap) {
                Button {
                    Task {
                        await subscriptionManager.purchasePro(using: kgService, authManager: authManager)
                    }
                } label: {
                    paywallActionLabel(
                        title: ctaButtonTitle,
                        isLoading: subscriptionManager.isLoading || productLoadState == .loading
                    )
                }
                .buttonStyle(.vocabAction(.primary))
                .disabled(subscriptionManager.isLoading || productLoadState != .ready)

                Button {
                    Task {
                        await subscriptionManager.restorePurchases(using: kgService, authManager: authManager)
                    }
                } label: {
                    paywallActionLabel(title: L10n.string("恢復購買"))
                }
                .buttonStyle(.vocabAction(.neutral))
                .disabled(subscriptionManager.isLoading)
            }

            purchaseStatusCard

            if productLoadState != .ready {
                loadProductsRetryCard
            }

            Text(footerNote)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)

            Text(L10n.string("訂閱將透過 Apple ID 自動續訂。可隨時在 App Store 設定中取消，取消後當期仍可使用至到期日。"))
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)
                .multilineTextAlignment(.leading)

            legalLinksFooter
        }
        .padding(appSkin.spacing.sheetPaddingCompact)
    }

    @ViewBuilder
    private var purchaseStatusCard: some View {
        if let purchaseStatusMessage = subscriptionManager.purchaseStatusMessage {
            VocabStateMessageCard(
                title: purchaseStatusMessage,
                systemImage: "checkmark.circle"
            )
        }
    }

    private var loadProductsRetryCard: some View {
        let isLoading = productLoadState == .loading
        return VocabStateMessageCard(
            title: isLoading ? L10n.string("正在載入訂閱方案") : L10n.string("訂閱方案載入失敗"),
            systemImage: isLoading ? "hourglass" : "arrow.clockwise.circle",
            description: isLoading
                ? L10n.string("正在從 App Store 取得訂閱資訊。")
                : L10n.string("App Store 尚未回傳訂閱資訊，請稍候或點下方重試。")
        ) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.string("正在載入訂閱方案"))
            } else {
                Button {
                    Task { await subscriptionManager.loadProducts() }
                } label: {
                    paywallActionLabel(title: L10n.string("重新載入"), font: appSkin.typography.caption)
                }
                .buttonStyle(.vocabAction(.neutral))
                .disabled(subscriptionManager.isLoading)
            }
        }
    }

    private func paywallActionLabel(
        title: String,
        isLoading: Bool = false,
        trailingSystemImage: String? = nil,
        font: Font? = nil
    ) -> some View {
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
            }

            Text(title)
                .font(font)

            Spacer()

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(appSkin.typography.iconSmall)
                    .foregroundStyle(appSkin.palette.quaternaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Legal Links Footer

    private var legalLinksFooter: some View {
        HStack(spacing: appSkin.spacing.controlGap) {
            Link(L10n.string("隱私政策"), destination: AppURLs.privacy)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)
            Text("·")
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)
            Link(L10n.string("服務條款"), destination: AppURLs.terms)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)
            Spacer()
        }
    }

    // MARK: - Computed Properties

    /// 目前 Pro entitlement 快照 + App Store 價格 — 餵給純 `SubscriptionPaywallCopy`。
    /// 所有文案邏輯收斂到該 enum（可單元測試），此處僅為 view-binding 薄轉發。
    private var pro: KGSubscriptionStatus { subscriptionManager.entitlements.pro }
    private var productPrice: String? { subscriptionManager.proProduct?.displayPrice }
    private var productLoadState: SubscriptionProductLoadState {
        SubscriptionManager.productLoadState(
            isLoading: subscriptionManager.isLoading,
            hasProduct: subscriptionManager.proProduct != nil,
            hasError: subscriptionManager.productLoadFailed
        )
    }

    private var isCancelledButActive: Bool { pro.isCancelledButActive }
    private var isAdminGranted: Bool { SubscriptionPaywallCopy.isAdminGranted(pro) }

    private var activeSummaryText: String { SubscriptionPaywallCopy.activeSummary(pro) }
    private var paywallSummaryText: String { SubscriptionPaywallCopy.marketingSummary }
    private var billedAmountLine: String { SubscriptionPaywallCopy.billedAmount(pro, productDisplayPrice: productPrice) }
    private var trialInfoLine: String? { SubscriptionPaywallCopy.trialInfo(pro, introTrialDays: introTrialDays) }
    private var priceLine: String { SubscriptionPaywallCopy.priceLine(pro, productDisplayPrice: productPrice, introTrialDays: introTrialDays) }
    private var ctaButtonTitle: String { SubscriptionPaywallCopy.ctaButtonTitle(pro, productDisplayPrice: productPrice, introTrialDays: introTrialDays) }
    private var entitlementSourceLine: String { SubscriptionPaywallCopy.entitlementSource(pro) }
    private var primaryActionTitle: String { SubscriptionPaywallCopy.primaryActionTitle(pro) }
    private var footerNote: String { SubscriptionPaywallCopy.footerNote(pro) }
}
