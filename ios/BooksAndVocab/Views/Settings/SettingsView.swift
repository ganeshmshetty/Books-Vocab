//
//  SettingsView.swift
//  Books & Vocab
//

import SwiftUI
import SwiftData
import StoreKit

struct SettingsView: View {
    @ObserveInjection private var inject
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    @Environment(\.kgService) var kgService
    @Environment(\.authManager) var authManager
    @Environment(\.subscriptionManager) var subscriptionManager
    @Environment(\.openURL) var openURL
    @Environment(\.requestReview) var requestReview
    @Environment(\.toastCoordinator) var toastCoordinator
    @EnvironmentObject var appLanguage: AppLanguageStore
    @EnvironmentObject var appearanceStore: AppAppearanceStore
    @Environment(\.reviewSettingsStore) var reviewSettingsStore
    @Environment(\.autoSyncSettingsStore) var autoSyncSettingsStore
    @Environment(\.autoLinkSettingsStore) var autoLinkSettingsStore
    @Environment(\.feedbackSettingsStore) var feedbackSettingsStore
    @State var coordinator = SettingsCoordinator()
    @State var exportURL: URL?
    /// Predicate 對應 shouldAppearInKnowledgeList — 僅用於 displayCardCount
    @Query(filter: #Predicate<VocabularyEntry> {
        $0.syncStatus == 1 &&
        $0.actionType != "delete" &&
        $0.isArchived == false
    }) var allEntries: [VocabularyEntry]

    /// The boolean login flag is not enough here: a manual login can replace
    /// account A with account B while both states remain `true`. The task must
    /// restart for either logout or an account switch so transient sync UI is
    /// never carried across an identity boundary.
    private var settingsAccountTaskID: String {
        "\(authManager.isLoggedIn ? "logged-in" : "logged-out"):\(authManager.userId ?? "none"):\(authManager.isDemoMode)"
    }

    /// The clean Settings UI fixture is applied after the process-wide store can
    /// be initialized by AuthManager. Re-activating the guest namespace here
    /// makes the fixture's real LWW write observable before the coordinator
    /// performs its normal account-boundary load. This is simulator-only test
    /// plumbing; production launches never rewrite a user's preferences.
    private var shouldNormalizeCleanSettingsFixture: Bool {
#if DEBUG && targetEnvironment(simulator)
        AppRuntimeOptions.isUITesting()
            && ProcessInfo.processInfo.arguments.contains("-seedFixture:settings:cleanPreferences")
#else
        false
#endif
    }

    private func normalizeCleanSettingsFixtureIfNeeded() {
        guard shouldNormalizeCleanSettingsFixture else { return }
#if DEBUG && targetEnvironment(simulator)
        reviewSettingsStore.activateAccount(nil)
        reviewSettingsStore.update(.default)
#endif
    }

    var body: some View {
#if DEBUG
        let _ = RenderStormProbe.shared.tick("SettingsView")
        let _ = RenderStormProbe.printChangesEnabled ? Self._printChanges() : ()
#endif
        SettingsPresenter(
            state: presenterState,
            translationSourceLang: translationSourceLangBinding,
            translationTargetLang: translationTargetLangBinding,
            onTranslationLanguageChanged: { source, target in
                await coordinator.updateTranslationLanguage(
                    source: source,
                    target: target,
                    authManager: authManager,
                    kgService: kgService,
                    toastCoordinator: toastCoordinator
                )
            },
            onPauseReviewClockChanged: { isPaused, previousSnapshot in
                await coordinator.updateReviewClock(
                    isPaused: isPaused,
                    previousSnapshot: previousSnapshot,
                    reviewSettingsStore: reviewSettingsStore,
                    authManager: authManager,
                    kgService: kgService,
                    toastCoordinator: toastCoordinator
                )
            },
            onReviewModeChanged: { newSettings, previousSnapshot in
                await coordinator.updateReviewMode(
                    newSettings,
                    previousSnapshot: previousSnapshot,
                    reviewSettingsStore: reviewSettingsStore,
                    authManager: authManager,
                    kgService: kgService,
                    toastCoordinator: toastCoordinator
                )
            },
            manualLoginUserId: manualLoginBinding,
            debugLocalServerURL: debugLocalServerURLBinding,
            actions: presenterActions
        )
        // 逐步同步進度。走 environment 而不是往 presenter state 塞欄位：這個 store
        // 在一輪同步裡會被寫幾十次，讓它只驅動「同步狀態」那一列底下的葉節點，
        // 不讓整個設定頁跟著重算（`PodcastProgressTicker` 的同一個模式）。
        .environment(\.syncProgressStore, coordinator.syncProgress)
        .task(id: settingsAccountTaskID) {
            coordinator.resetForAccountBoundary(authManager: authManager)
            normalizeCleanSettingsFixtureIfNeeded()
            await coordinator.loadData(authManager: authManager, kgService: kgService)
            if authManager.isLoggedIn {
                await subscriptionManager.loadProducts()
                await subscriptionManager.refresh(using: kgService, authManager: authManager, force: false)
            } else {
                // 登出時立即清除訂閱狀態
                await subscriptionManager.refresh(using: kgService, authManager: authManager, force: true)
            }
        }
        .onChange(of: coordinator.showSubscriptionPaywall) { _, isPresented in
            if !isPresented, authManager.isLoggedIn {
                Task {
                    await subscriptionManager.refresh(using: kgService, authManager: authManager, force: true)
                }
            }
        }
        .onAppear {
            coordinator.handleAppear()
            AppLanguageStore.shared.setSettingsPresentationActive(true)
        }
        .onDisappear {
            AppLanguageStore.shared.setSettingsPresentationActive(false)
        }
        .subscriptionPaywallSheet(isPresented: $coordinator.showSubscriptionPaywall)
        .toastSheet(item: $exportURL) { url in
            PlatformShareView(url: url)
                .onDisappear { VocabularyExporter.cleanup(url) }
        }
        .toastSheet(isPresented: $coordinator.showDeleteAccountConfirm) {
            SettingsDeleteAccountSheet(
                onConfirm: {
                    Task {
                        await coordinator.deleteAccount(
                            authManager: authManager,
                            kgService: kgService,
                            modelContext: modelContext
                        )
                    }
                },
                isDeleting: coordinator.isDeletingAccount
            )
        }
        .alert("刪除失敗".localized, isPresented: Binding(
            get: { coordinator.deleteAccountError != nil },
            set: { if !$0 { coordinator.clearDeleteAccountError() } }
        )) {
            Button("好".localized, action: coordinator.clearDeleteAccountError)
        } message: {
            Text(coordinator.deleteAccountError ?? "請稍後再試".localized)
        }
        .enableInjection()
    }
}

extension View {
    /// 呈現 SettingsView，並在 sheet 邊界 re-inject 它依賴的兩個 app 級
    /// ObservableObject。SwiftUI `.sheet` 會傳遞 value-based `.environment(\.key)`，
    /// 但【不】跨 sheet 邊界傳遞 `@EnvironmentObject` —— 少了這層，SettingsView
    /// 讀 appLanguage 時即 fatal "No ObservableObject of type AppLanguageStore found"。
    /// 兩者皆為 .shared singleton，重複注入冪等無害。所有設定入口統一走此。
    func settingsSheet(isPresented: Binding<Bool>) -> some View {
        toastSheet(isPresented: isPresented) {
            SettingsView()
                .environmentObject(AppLanguageStore.shared)
                .environmentObject(AppAppearanceStore.shared)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppLanguageStore.shared)
        .environmentObject(AppAppearanceStore.shared)
}
