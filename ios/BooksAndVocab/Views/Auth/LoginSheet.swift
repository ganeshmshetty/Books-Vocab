//
//  LoginSheet.swift
//  Books & Vocab
//
//  獨立登入 sheet，供空狀態 / Guest 面板呼叫。
//

import SwiftUI
import SwiftData

struct LoginSheet: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.authManager) private var authManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingLocalReset = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("登入帳號".localized)
                .inlineNavigationBarTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消".localized) { dismiss() }
                            .accessibilityIdentifier("auth.loginSheet.cancelButton")
                    }
                }
        }
        .onChange(of: authManager.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn { dismiss() }
        }
        .onAppear {
            PerfLog.auth.mark("auth.gate.login.shown")
        }
        .confirmationDialog(
            L10n.string("重設本機資料？"),
            isPresented: $isConfirmingLocalReset,
            titleVisibility: .visible
        ) {
            Button(L10n.string("重設本機資料"), role: .destructive) {
                Task { _ = await authManager.recoverFromStuckLocalWipe() }
            }
            .accessibilityIdentifier("auth.loginSheet.confirmResetLocalDataButton")
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("上一個帳號的本機資料無法清除。重設會刪除本機資料庫，尚未同步的內容將無法復原。"))
        }
        .enableInjection()
    }

    private var content: some View {
        VStack(spacing: AppSpacing.s6) {
            Spacer()

            // Hero
            VStack(spacing: AppSpacing.s2) {
                AppHeroIcon()

                Text("解鎖完整功能".localized)
                    .font(appSkin.typography.displayTitle)
                    .foregroundStyle(appSkin.palette.primaryText)

                Text("AI 翻譯・知識圖譜・雲端同步".localized)
                    .font(appSkin.typography.body)
                    .foregroundStyle(appSkin.palette.secondaryText)
            }

            Spacer()

            // Auth buttons
            VStack(spacing: appSkin.spacing.controlGap) {
                Button {
                    authManager.loginWithGoogle(modelContainer: modelContext.container)
                } label: {
                    loginButtonLabel(
                        title: "以 Google 繼續",
                        systemImage: nil,
                        isGoogle: true
                    )
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("使用 Google 帳號登入".localized)
                .accessibilityIdentifier("auth.loginSheet.googleButton")

                Button {
                    authManager.loginWithApple(modelContainer: modelContext.container)
                } label: {
                    loginButtonLabel(
                        title: "以 Apple 繼續",
                        systemImage: "apple.logo",
                        isGoogle: false
                    )
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("使用 Apple 帳號登入".localized)
                .accessibilityIdentifier("auth.loginSheet.appleButton")
            }
            .padding(.horizontal, AppSpacing.s4)
            .padding(.bottom, AppSpacing.s6)

            // Error
            if let error = authManager.authError {
                VocabStateMessageCard(
                    title: "登入暫時失敗".localized,
                    systemImage: "exclamationmark.triangle.fill",
                    description: error
                )
                .padding(.horizontal, AppSpacing.s4)
            }

            // Escape for a wipe stuck past the retry cap (#3229): the only in-app path that clears the store.
            if authManager.canRecoverStuckLocalWipe {
                Button(L10n.string("重設本機資料"), role: .destructive) {
                    isConfirmingLocalReset = true
                }
                .buttonStyle(.appAction(.destructive))
                .padding(.horizontal, AppSpacing.s4)
                .accessibilityIdentifier("auth.loginSheet.resetLocalDataButton")
            }
        }
        .overlay {
            if authManager.isAuthenticating {
                ZStack {
                    appSkin.palette.pageBackground.opacity(0.85)
                    VStack(spacing: appSkin.spacing.controlGap) {
                        ProgressView().controlSize(.regular)
                        Text("正在驗證帳號…".localized)
                            .font(appSkin.typography.caption)
                            .foregroundStyle(appSkin.palette.secondaryText)
                    }
                }
                .transition(.contentSwap)
            }
        }
        .animatePhaseChange(authManager.isAuthenticating)
        // `.contain` keeps this identifier on the container element itself;
        // without it SwiftUI propagates the identifier onto every child and
        // shadows the buttons' own identifiers (breaks identifier queries).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("auth.loginSheet")
    }

    private func loginButtonLabel(title: String, systemImage: String?, isGoogle: Bool) -> some View {
        HStack(spacing: AppSpacing.s2) {
            if isGoogle {
                Text("G")
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.primaryText)
                    .frame(width: AppSettingsMetrics.socialBadgeSize, height: AppSettingsMetrics.socialBadgeSize)
                    .background(Circle().fill(appSkin.palette.cardBackground))
                    .overlay(Circle().stroke(appSkin.palette.cardBorder, lineWidth: 1))
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(appSkin.typography.iconTiny)
                    .foregroundStyle(appSkin.palette.pageBackground)
                    .frame(width: AppSettingsMetrics.socialBadgeSize, height: AppSettingsMetrics.socialBadgeSize)
                    .background(Circle().fill(AppBrandColors.appleBlack))
            }

            Text(title.localized)
                .font(appSkin.typography.body.weight(.medium))

            Spacer()

            Image(systemName: "chevron.right")
                .font(appSkin.typography.iconTiny)
                .foregroundStyle(appSkin.palette.tertiaryText)
        }
        .padding(.horizontal, AppSpacing.s4)
        .padding(.vertical, AppSpacing.s2)
        .background(
            AppRoundedRect(roundness: appSkin.roundness.control)
                .fill(appSkin.palette.cardBackground)
                .overlay(
                    AppRoundedRect(roundness: appSkin.roundness.control)
                        .stroke(appSkin.palette.cardBorder, lineWidth: 1)
                )
        )
    }
}

#Preview {
    AppThemeContainer {
        LoginSheet()
    }
    .environmentObject(AppAppearanceStore.preview)
}
