import SwiftUI

// 背景工作膠囊（#3116）：Add Link 建立中、sheet 已關閉時，app 根層的一顆小玻璃膠囊，
// 顯示進行中的工作數與整體進度；點擊開啟該工作的進度明細。它是第三種暫時性提示：
// 持續、非模態、可點、只報告狀態（規範見 docs/sop/ui-design.md「背景工作膠囊」）。

/// 膠囊要呈現的內容，純資料：由 hub 進行中的工作投影而來。
struct AppJobCapsuleModel: Equatable {
    struct Entry: Equatable {
        let jobKey: String
        let word: String
        let fraction: Double
    }

    /// 進行中的工作，由舊到新（與 `AddLinkCreationHub.runningJobs` 同序）。
    let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    var isVisible: Bool { !entries.isEmpty }
    var count: Int { entries.count }
    var isAggregate: Bool { entries.count > 1 }

    /// 只有一個工作時膠囊點名它；多個時改報數量。
    var word: String? { isAggregate ? nil : entries.first?.word }

    /// 所有進行中工作的平均進度，夾在 0...1。
    var fraction: Double {
        guard !entries.isEmpty else { return 0 }
        let sum = entries.reduce(0) { $0 + Self.clamped($1.fraction) }
        return Self.clamped(sum / Double(entries.count))
    }

    /// 點擊要開啟的工作：最舊的那一個。
    var openJobKey: String? { entries.first?.jobKey }

    /// VoiceOver value：整數百分比。
    var percentText: String { "\(Int((fraction * 100).rounded()))%" }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// 哪些畫面需要把膠囊移開（例如閱讀器的頁面文字不能被遮住）。以持有者為單位：
/// 任一持有者仍在，膠囊就不出現。
@Observable @MainActor
final class AppJobCapsuleSuppression {
    static let shared = AppJobCapsuleSuppression()

    private(set) var holders: Set<String> = []

    var isSuppressed: Bool { !holders.isEmpty }

    func setHeld(_ held: Bool, by holder: String) {
        if held {
            holders.insert(holder)
        } else {
            holders.remove(holder)
        }
    }
}

enum AppJobCapsuleMetrics {
    /// HIG 觸控下限；系統玻璃不會替膠囊撐命中區，所以自己補。
    static let hitTarget: CGFloat = 44
    /// 讓膠囊停在根層底部的浮動 tab bar 之上。尚未以 Catalog 截圖驗證（見 ui-design.md）。
    static let bottomClearance: CGFloat = 96
}

/// 膠囊本體：一顆玻璃膠囊，左側細進度環，右側文案。無描邊、無 elevation。
struct AppJobCapsule: View {
    @Environment(\.appTheme) private var appTheme
    let model: AppJobCapsuleModel
    let onOpen: (String) -> Void

    private var title: String {
        if let word = model.word {
            return L10n.format("addLink.job.capsule.single", word)
        }
        return L10n.format("addLink.job.capsule.multi", String(model.count))
    }

    var body: some View {
        if let jobKey = model.openJobKey {
            Button {
                onOpen(jobKey)
            } label: {
                HStack(spacing: AppSpacing.s2) {
                    AppJobCapsuleRing(fraction: model.fraction)
                    Text(title)
                        .font(AppFonts.caption(weight: .semibold))
                        .foregroundStyle(appTheme.palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, AppSpacing.s4)
                .frame(minHeight: AppJobCapsuleMetrics.hitTarget)
                .glassEffect(.regular, in: AppRoundedRect(roundness: AppRoundness.pill))
                .contentShape(AppRoundedRect(roundness: AppRoundness.pill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(model.percentText)
            .accessibilityHint(L10n.string("addLink.job.capsule.hint"))
            .accessibilityIdentifier("addLink.job.capsule")
        }
    }
}

private struct AppJobCapsuleRing: View {
    @Environment(\.appTheme) private var appTheme
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(appTheme.palette.tertiaryText.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(appTheme.palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .animation(AppMotion.feedbackPulse, value: fraction)
        .accessibilityHidden(true)
    }
}

/// 根層底部的膠囊宿主：讀 hub 的進行中工作，決定顯示與點擊要開的明細 sheet。
private struct AppJobCapsuleHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hub: AddLinkCreationHub
    let suppression: AppJobCapsuleSuppression
    @State private var openedLink: KGCardLinkSummary?

    var body: some View {
        let entries = hub.runningJobs.map { job in
            AppJobCapsuleModel.Entry(
                jobKey: job.record.jobKey,
                word: job.record.word,
                fraction: job.coordinator?.fraction ?? 0
            )
        }
        let model = AppJobCapsuleModel(entries: entries)
        let isShown = model.isVisible && !suppression.isSuppressed

        VStack {
            if isShown {
                AppJobCapsule(model: model) { jobKey in
                    open(jobKey: jobKey, entries: entries)
                }
                .padding(.bottom, AppJobCapsuleMetrics.bottomClearance)
                .transition(reduceMotion ? AnyTransition.overlayFade : AnyTransition.readerPanelReveal)
            }
        }
        .animation(AppMotion.panelState, value: isShown)
        .toastSheet(item: $openedLink) { link in
            PendingLinkDetailSheet(link: link, hub: hub)
        }
    }

    private func open(jobKey: String, entries: [AppJobCapsuleModel.Entry]) {
        guard let entry = entries.first(where: { $0.jobKey == jobKey }) else { return }
        openedLink = .pendingCreation(jobKey: entry.jobKey, word: entry.word, state: .creating)
    }
}

private struct AppJobCapsuleOverlayModifier: ViewModifier {
    let hub: AddLinkCreationHub
    let suppression: AppJobCapsuleSuppression

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            AppJobCapsuleHost(hub: hub, suppression: suppression)
        }
    }
}

extension View {
    /// 把背景工作膠囊掛在 app 根層，與 `toastOverlay()` 同一層（#3116）。
    func appJobCapsuleOverlay(
        hub: AddLinkCreationHub = .shared,
        suppression: AppJobCapsuleSuppression = .shared
    ) -> some View {
        modifier(AppJobCapsuleOverlayModifier(hub: hub, suppression: suppression))
    }
}
