#if DEBUG && canImport(Playbook)
import Playbook
import SwiftUI

/// Temporary, repeatable visual review surface for the iOS 26 Glass pass.
/// It composes the real shared primitives; it is not a production screen.
enum AppGlassScenarios {
    static func register(in playbook: Playbook) {
        playbook.addScenarios(of: "UI Foundation · iOS 26 Glass") {
            Scenario("Controls and toast", layout: .fillH) {
                GlassControlsScene()
            }
            Scenario("Surfaces and states", layout: .fillH) {
                GlassSurfacesScene()
            }
        }
    }
}

private struct GlassControlsScene: View {
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.s4) {
                Text(L10n.string("iOS 26 Glass controls")) // i18n-allow: debug-only visual review fixture
                    .font(AppFonts.h2(weight: .semibold))
                    .foregroundStyle(appTheme.palette.primaryText)

                Text(L10n.string("主要 CTA 保持實心；次要、外框與危險操作使用語意化 glass。")) // i18n-allow: debug-only visual review fixture
                    .font(AppFonts.caption())
                    .foregroundStyle(appTheme.palette.secondaryText)

                VStack(spacing: AppSpacing.s3) {
                    Button(L10n.string("開始複習")) {} // i18n-allow: debug-only visual review fixture
                        .buttonStyle(.appCompactAction(.primary))
                    Button(L10n.string("次要操作")) {} // i18n-allow: debug-only visual review fixture
                        .buttonStyle(.appCompactAction(.neutral))
                    Button(L10n.string("外框操作")) {} // i18n-allow: debug-only visual review fixture
                        .buttonStyle(.appCompactAction(.outline))
                    Button(L10n.string("刪除")) {}
                        .buttonStyle(.appCompactAction(.destructive))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AppToast(
                    item: .init(message: L10n.string("背景同步完成"), style: .success), // i18n-allow: debug-only visual review fixture
                    onDismiss: {}
                )
                AppToast(
                    item: .init(message: L10n.string("部分同步失敗，請稍後重試"), style: .warning), // i18n-allow: debug-only visual review fixture
                    onDismiss: {}
                )
                AppToast(
                    item: .init(message: L10n.string("刪除失敗"), style: .error),
                    onDismiss: {}
                )
                // #2862 truncated pill: tap-to-expand fixtures (collapsed shows chevron.down).
                AppToast(
                    item: .init(message: L10n.string("背景同步部分失敗：複習進度上傳失敗：伺服器暫時不可用, 複習紀錄上傳失敗：伺服器暫時不可用"), style: .warning), // i18n-allow: debug-only visual review fixture
                    onToggleExpanded: {},
                    onDismiss: {}
                )
                AppToast(
                    item: .init(message: "Background sync partly failed: review progress upload failed, review log upload failed: server temporarily unavailable"), // i18n-allow: debug-only visual review fixture
                    isExpanded: true,
                    onToggleExpanded: {},
                    onDismiss: {}
                )
            }
            .padding(AppSpacing.s5)
        }
        .background(appTheme.palette.pageBackground.ignoresSafeArea())
    }
}

private struct GlassSurfacesScene: View {
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.s4) {
                Text(L10n.string("Surface and state hierarchy")) // i18n-allow: debug-only visual review fixture
                    .font(AppFonts.h2(weight: .semibold))
                    .foregroundStyle(appTheme.palette.primaryText)

                AppSectionCard(padding: 0, style: .settings(.previewNeutral)) {
                    VStack(alignment: .leading, spacing: AppSpacing.s2) {
                        Text(L10n.string("Settings flat grouping")) // i18n-allow: debug-only visual review fixture
                            .font(AppFonts.body(weight: .semibold))
                        Text(L10n.string("分區依靠留白與 divider，不再依靠外框。")) // i18n-allow: debug-only visual review fixture
                            .font(AppFonts.caption())
                            .foregroundStyle(appTheme.palette.secondaryText)
                    }
                    .padding(AppSpacing.s4)
                }

                AppStateMessageCard(
                    title: L10n.string("內容載入失敗"), // i18n-allow: debug-only visual review fixture
                    systemImage: "exclamationmark.triangle",
                    description: L10n.string("可重試的錯誤使用單一狀態 surface。") // i18n-allow: debug-only visual review fixture
                ) {
                    Button(L10n.string("重試")) {}
                        .buttonStyle(.appCompactAction(.outline))
                }

                AppLoadingStateCard(
                    title: L10n.string("載入中"),
                    systemImage: "arrow.triangle.2.circlepath",
                    description: L10n.string("使用 shared loading card。"), // i18n-allow: debug-only visual review fixture
                    visualStyle: .app
                )

                AppSkeletonCard(lineCount: 3, showAvatar: true)
            }
            .padding(AppSpacing.s5)
        }
        .background(appTheme.palette.pageBackground.ignoresSafeArea())
    }
}

#Preview("iOS 26 Glass controls") {
    AppThemeContainer {
        GlassControlsScene()
    }
    .environmentObject(AppAppearanceStore.preview)
}
#endif
