import SwiftUI

struct AppStartupFailure: Equatable {
    let title: String
    let message: String
    let recoverySteps: [String]
    let technicalDetails: String

    /// #2743 — 恢復步驟必須先點名永久遺失風險，不能等使用者點了按鈕才發現。
    static let clearCacheRecoveryStepKey = "如果重試無效，可以清除本機快取；所有尚未同步到雲端的本機資料會永久刪除，無法復原。"

    static func storageInitialization(error: Error) -> AppStartupFailure {
        AppStartupFailure(
            title: L10n.string("無法安全啟動資料庫"),
            message: L10n.string("App 已停止載入主要功能，避免在資料庫異常時覆寫或刪除既有資料。"),
            recoverySteps: [
                L10n.string("先重新嘗試啟動，確認是不是一次性的 migration 或 iCloud 初始化失敗。"),
                L10n.string(clearCacheRecoveryStepKey),
                L10n.string("仍無法恢復時，請聯絡支援團隊，附上下方技術細節。")
            ],
            technicalDetails: error.localizedDescription
        )
    }
}

/// View-layer recovery callbacks. View 不需要持有 ModelContainer / Service，
/// 由 host（`BooksAndVocabApp`）注入具體行為，方便測試與 #Preview。
struct AppStartupRecoveryActions {
    /// 重新嘗試啟動（重建 ModelContainer）。回傳是否成功。
    var retry: () async -> Bool
    /// 清除本機快取（UserDefaults + 已同步資料的影子），不刪除雲端資料。
    var clearLocalCache: () async -> Bool
    /// 取得 mailto: URL（含技術細節 boilerplate）— 由 host 組合，view 只負責 openURL。
    var supportMailURL: (AppStartupFailure) -> URL?

    static let preview = AppStartupRecoveryActions(
        retry: { true },
        clearLocalCache: { true },
        supportMailURL: { _ in URL(string: "mailto:\(BrandIdentity.supportEmail)") }
    )
}

/// #2743 — 清除本機快取會刪除 LocalStore 檔案（可能含尚未同步的資料）。所有決策收在這裡：
/// 只有 `confirm()` 回傳 `.clearLocalCache`；view 只執行回傳的 Effect，
/// 因此「按鈕永不直接清除」與「只有確認路徑會清除」可以由單元測試直接守護。
/// `confirm()` 刻意不以 `isPresented` 為前提：destructive 按鈕只存在於已呈現的對話框內，
/// 且 SwiftUI 關閉 binding 與按鈕 action 的先後順序不保證，前提判斷會讓清除靜默失效。
struct AppStartupClearCacheGate: Equatable {
    static let titleKey = "要清除本機快取嗎？"
    static let messageKey = "所有尚未同步到雲端的本機資料（單字、筆記本、複習紀錄、書籍與播客等）會永久遺失，無法復原。已備份到雲端的資料不受影響。"
    static let confirmKey = "清除本機資料"

    enum Effect: Equatable {
        case none
        case presentConfirmation
        case clearLocalCache
    }

    private(set) var isPresented = false

    /// 「清除本機快取」按鈕：只呈現確認對話框，永不回傳 `.clearLocalCache`。
    mutating func tap() -> Effect {
        isPresented = true
        return .presentConfirmation
    }

    /// 對話框的 destructive 按鈕：唯一回傳清除 Effect 的路徑。
    mutating func confirm() -> Effect {
        isPresented = false
        return .clearLocalCache
    }

    /// 對話框取消或被系統關閉：不清除。
    mutating func cancel() -> Effect {
        isPresented = false
        return .none
    }
}

struct AppStartupRecoveryView: View {
    @ObserveInjection private var inject
    @Environment(\.appTheme) private var appTheme
    @Environment(\.openURL) private var openURL

    let failure: AppStartupFailure
    let actions: AppStartupRecoveryActions

    /// View-local recovery phase (UI feedback only — actual state lives in host).
    private enum Phase: Equatable {
        case idle
        case working(Step)
        case retryFailed
        case cacheCleared
        case mailUnavailable
        case exhausted

        enum Step { case retrying, clearing }
    }

    @State private var phase: Phase = .idle
    @State private var clearCacheGate = AppStartupClearCacheGate()

    init(failure: AppStartupFailure, actions: AppStartupRecoveryActions) {
        self.failure = failure
        self.actions = actions
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.s6) {
                    headerSection
                    recoveryStepsSection
                    actionLayersSection
                    statusBanner
                    technicalDetailsSection
                }
                .padding(AppSpacing.s6)
                .animation(AppMotion.contentFade, value: phase)
            }
            .background(appTheme.palette.pageBackground.ignoresSafeArea())
            .navigationTitle(L10n.string("啟動保護模式"))
            .inlineNavigationBarTitle()
        }
        .enableInjection()
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s3) {
            Label(failure.title, systemImage: "externaldrive.badge.exclamationmark")
                .font(AppFonts.h2(weight: .semibold))
                .foregroundStyle(appTheme.palette.primaryText)

            Text(failure.message)
                .font(AppFonts.body())
                .foregroundStyle(appTheme.palette.secondaryText)
        }
    }

    private var recoveryStepsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s3) {
            Text(L10n.string("建議處理方式"))
                .font(AppFonts.subhead(weight: .semibold))
                .foregroundStyle(appTheme.palette.primaryText)

            ForEach(Array(failure.recoverySteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: AppSpacing.s3) {
                    Text("\(index + 1).")
                        .font(AppFonts.monoNumbers(size: 17))
                        .foregroundStyle(appTheme.palette.accent)
                    Text(step)
                        .font(AppFonts.body())
                        .foregroundStyle(appTheme.palette.secondaryText)
                }
            }
        }
    }

    private var actionLayersSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s3) {
            Text(L10n.string("恢復操作"))
                .font(AppFonts.subhead(weight: .semibold))
                .foregroundStyle(appTheme.palette.primaryText)

            // Layer 1 — Retry
            Button {
                Task { await runRetry() }
            } label: {
                Label(L10n.string("重新嘗試啟動"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.appCompactAction(.primary))
            .disabled(isWorking || phase == .exhausted)

            // Layer 2 — Clear local cache
            Button {
                perform(clearCacheGate.tap())
            } label: {
                Label(L10n.string("清除本機快取"), systemImage: "trash.slash")
            }
            .buttonStyle(.appCompactAction(.neutral))
            .disabled(isWorking)
            .confirmationDialog(
                L10n.string(AppStartupClearCacheGate.titleKey),
                isPresented: Binding(
                    get: { clearCacheGate.isPresented },
                    set: { if !$0 { _ = clearCacheGate.cancel() } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.string(AppStartupClearCacheGate.confirmKey), role: .destructive) {
                    perform(clearCacheGate.confirm())
                }
                Button(L10n.string("取消"), role: .cancel) { perform(clearCacheGate.cancel()) }
            } message: {
                Text(L10n.string(AppStartupClearCacheGate.messageKey))
            }

            // Layer 3 — Contact support
            Button {
                openSupportMail()
            } label: {
                Label(L10n.string("聯絡支援團隊"), systemImage: "envelope")
            }
            .buttonStyle(.appCompactAction(.outline))
            .disabled(isWorking)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch phase {
        case .idle:
            EmptyView()

        case .working(let step):
            HStack(spacing: AppSpacing.s3) {
                ProgressView()
                    .controlSize(.small)
                Text(step == .retrying
                     ? L10n.string("正在重新嘗試啟動…")
                     : L10n.string("正在清除本機快取…"))
                    .font(AppFonts.caption())
                    .foregroundStyle(appTheme.palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.s4)
            .background(
                appTheme.palette.cardBackground,
                in: AppRoundedRect(roundness: AppRoundness.control)
            )
            .transition(.overlayFade)

        case .retryFailed:
            recoveryNoticeBanner(
                icon: "exclamationmark.triangle",
                text: L10n.string("重試仍失敗。請試試清除本機快取或聯絡支援。"),
                tone: .warning
            )

        case .cacheCleared:
            recoveryNoticeBanner(
                icon: "checkmark.circle",
                text: L10n.string("本機快取已清除。建議再次重試啟動。"),
                tone: .success
            )

        case .mailUnavailable:
            recoveryNoticeBanner(
                icon: "envelope.badge",
                text: L10n.format("無法開啟郵件 App。請手動寄信至 %@，並附上技術細節。", BrandIdentity.supportEmail),
                tone: .warning
            )

        case .exhausted:
            recoveryNoticeBanner(
                icon: "lifepreserver",
                text: L10n.string("已嘗試過所有自動恢復步驟。請聯絡支援團隊。"),
                tone: .warning
            )
        }
    }

    private var technicalDetailsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s2) {
            Text(L10n.string("技術細節"))
                .font(AppFonts.subhead(weight: .semibold))
                .foregroundStyle(appTheme.palette.primaryText)

            Text(failure.technicalDetails)
                .font(AppFonts.monoNumbers(size: 12))
                .foregroundStyle(appTheme.palette.tertiaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.s4)
                .background(
                    appTheme.palette.cardBackground,
                    in: AppRoundedRect(roundness: AppRoundness.card)
                )
                .overlay {
                    AppRoundedRect(roundness: AppRoundness.card)
                        .stroke(appTheme.palette.cardBorder, lineWidth: 1)
                }
        }
    }

    // MARK: - Helpers

    private enum BannerTone { case warning, success }

    @ViewBuilder
    private func recoveryNoticeBanner(icon: String, text: String, tone: BannerTone) -> some View {
        let fg: Color = {
            switch tone {
            case .warning: return appTheme.palette.warning
            case .success: return appTheme.palette.success
            }
        }()
        HStack(alignment: .top, spacing: AppSpacing.s3) {
            Image(systemName: icon)
                .foregroundStyle(fg)
            Text(text)
                .font(AppFonts.caption())
                .foregroundStyle(appTheme.palette.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.s4)
        .background(
            appTheme.palette.cardBackground,
            in: AppRoundedRect(roundness: AppRoundness.control)
        )
        .overlay {
            AppRoundedRect(roundness: AppRoundness.control)
                .stroke(fg.opacity(0.32), lineWidth: 1)
        }
        .transition(.overlayFade)
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    private func runRetry() async {
        phase = .working(.retrying)
        let success = await actions.retry()
        // 成功時 host 會切換出 recovery view；view 不需手動清 state。
        if !success {
            phase = .retryFailed
        }
    }

    /// 只執行 gate 回傳的 Effect；view 不自行判斷是否清除。
    private func perform(_ effect: AppStartupClearCacheGate.Effect) {
        switch effect {
        case .none, .presentConfirmation:
            break
        case .clearLocalCache:
            Task { await runClearCache() }
        }
    }

    private func runClearCache() async {
        phase = .working(.clearing)
        let success = await actions.clearLocalCache()
        phase = success ? .cacheCleared : .exhausted
    }

    private func openSupportMail() {
        guard let url = actions.supportMailURL(failure) else {
            phase = .mailUnavailable
            return
        }
        openURL(url) { accepted in
            if !accepted {
                Task { @MainActor in phase = .mailUnavailable }
            }
        }
    }
}

#Preview("AppStartupRecoveryView — idle") {
    AppThemeContainer {
        AppStartupRecoveryView(
            failure: .storageInitialization(error: NSError(
                domain: "SwiftDataError",
                code: 134_060,
                userInfo: [NSLocalizedDescriptionKey: "CloudKit schema validation failed: Notebook.coverPalette missing remote field."]
            )),
            actions: .preview
        )
    }
    .environmentObject(AppAppearanceStore.preview)
}

#Preview("AppStartupRecoveryView — exhausted") {
    AppThemeContainer {
        AppStartupRecoveryView(
            failure: .storageInitialization(error: NSError(domain: "SwiftDataError", code: 1)),
            actions: AppStartupRecoveryActions(
                retry: { false },
                clearLocalCache: { false },
                supportMailURL: { _ in nil }
            )
        )
    }
    .environmentObject(AppAppearanceStore.preview)
}
