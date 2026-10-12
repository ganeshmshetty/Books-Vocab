import SwiftUI

// MARK: - State

struct TodayReviewPresenterState {
    /// 兩個型別已搬進 `ReviewCardView.swift`（卡片渲染不再需要先造一個 presenter）。
    /// **走 typealias 而非 rename 是量出來的決定**：這兩個名字全 repo 有 27 處、散在
    /// 6 個檔（含不在 Scenes 目錄下、最容易漏掉的 Support/Fixtures/TodayReview/
    /// TodayReviewFixtures.swift），typealias 讓那 27 處零改動。
    typealias LinkGroup = ReviewCardLinkGroup
    typealias CurrentCard = ReviewCardContent

    let progressText: String
    let currentCard: CurrentCard?
    /// 常駐三 slot 投影（Phase 4）— 固定長度 `TodayReviewCardSlotLayout.slotCount`，
    /// 內容純推導自 currentIndex / queueCount；取代舊 `nextCard` 雙軌預覽。
    let slots: [TodayReviewCardSlotModel]
    let revealStage: TodayReviewRevealStage
    let canShuffle: Bool
    /// autoplay 還有事可做嗎(見 `TodayReviewSessionState.canAutoplay`)。false 時
    /// 播放鍵變淡並停用——沉默地拒絕會製造另一顆死按鈕,那正是本次要修掉的東西。
    let canAutoplay: Bool
    let canGoPrevious: Bool
    let canGoNext: Bool
    let remainingCount: Int
    let forgotCount: Int
    let rememberedCount: Int
    let rememberedFeedbackTrigger: Int
    let forgotFeedbackTrigger: Int
    let isAutoPlaying: Bool
    let isAutoPlayPaused: Bool
    let autoplayProgress: Double
    let autoplaySpeed: AutoplaySpeed
    let autoplaySoundEnabled: Bool
    /// #2041：目前「暫時看詳細」的那張卡（`CardPresentation.reviewCardKey`），nil ＝
    /// 全部依設定。session 記憶體，換卡即清。
    var temporaryDetailCardKey: String? = nil
    /// #3127：鍵盤評分請求（與按鈕、滑動同一條甩出路徑）。變化即由 view 觸發一次 `flingCard`。
    var keyboardGrade: KeyboardGradeRequest? = nil
}

/// reference box：可被 onGeometryChange 逐幀寫入而不觸發 SwiftUI 失效。
/// 只在主執行緒讀寫（onGeometryChange action / completeFling 皆在 main）。
final class DeckHeightProbe: @unchecked Sendable {
    var layoutHeight: CGFloat = 0
}

// MARK: - Presenter

struct TodayReviewPresenter: View {
    @ObserveInjection private var inject

    static let initialFrontSlotHeight: CGFloat = 0

    // internal — extension files 需要存取
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.appSkin) var appSkin
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(\.speechService) var speechService
    /// 自動播放中滑動被擋時的 pill 提示（#2046）。只在手勢 closure 內呼叫，不在 body 讀取。
    @Environment(\.toastCoordinator) var toastCoordinator
    @Environment(\.reviewCardLayoutStore) var reviewCardLayoutStore
    // 自主量測 probe（-reviewProbe）— 一般啟動恆為 nil，.task 直接 return。
    @Environment(\.reviewProbeDriver) private var reviewProbeDriver

    // 動畫狀態 — dismissPhase 是唯一的互動鎖
    @State var frozenSwipeIntensity: Double = 0
    @State var swipeOffset: CGFloat = 0
    /// 本次手勢的標記峰值（#2045）。僅 UITest 進程累計與暴露，正式進程恆 `.zero`。
    @State var swipeMarkerPeak = TodayReviewSwipeMarkerPeak.zero
    @State var containerWidth: CGFloat = 393
    @State var dismissPhase: DismissPhase = .idle
    /// 這一次被擋下的滑動手勢是否已提示過（每次手勢只提示一次，手勢結束重置；#2046）。
    @State var autoplayBlockedHintShown = false
    // 首插入升起動畫（取代舊 `.reviewCardPromote` insertion transition）：
    // 0 = promote 起始姿態（scale 0.96 / yOff 22），1 = identity。只屬於
    // active role；onAppear 以 spring 推到 1，之後恆 1（slot 常駐不再插入）。
    @State var introProgress: CGFloat = 0
    // 甩出回饋的觸發計數（#3127）：記得／忘記 各自一個，haptic 類別與聲音由 AppFeedbackEvent.reviewGrade 決定。
    @State var flingRememberedTrigger = 0
    @State var flingForgotTrigger = 0
    /// 甩出中到達的評分暫存（只留一筆，settle 後套用一次；#3127）。
    @State var bufferedGrade = FlingGradeBuffer()
    @State private var celebrationTriggered = false
    @State private var lastAutoplaySpokenCardKey: String?
    // Per-slot 隨機微旋轉（index 對齊 slot）。slot 存活期間持久 —— 角色輪替
    // （underPreview→preview→active）時 rotation 連續不跳動；只有 settle 回收
    // 舊 active slot（換內容、沉到最深層）時重隨機該一格（completeFling）。
    @State var stackRotations: [Double] = [
        .random(in: -1.0...1.0),
        .random(in: -1.0...1.0),
        .random(in: -1.0...1.0)
    ]
    // depth-2 殼層（第四層暗示）自己的持久旋轉 —— 殼層恆駐，不參與輪替。
    @State var deckShellRotation: Double = .random(in: -1.0...1.0)
    // FIX(review-flip-gap)：卡片區是 `ZStack(alignment:.top)` 疊三個常駐 slot
    // （Phase 4），ZStack 的 layout 高度 = 最高 slot。較高的背景卡（preview /
    // underPreview，例如正面帶長例句的 production 卡或多行單字）會把 ZStack 撐高，
    // 把其下方 sibling 的 expand zone 往下推 → 卡片與底部「點一下展開」出現大縫隙
    // （洗牌換矮卡進 preview 窗即塌回，故洗牌能修）。修法：非 active slot 的 layout
    // 高度一律 cap 到 active 卡的 front 高度，讓 ZStack 只由 active 卡決定高度。
    // 逐 slot 記實測 front 高度（高度綁內容，非綁 role）；`activeCardHeight` 讀
    // 目前 active slot 的值。active slot 恆 uncap → 量到自然高度；背景卡升 active 時
    // 去除 cap 會觸發重量 → 自我校正，無 role 輪替 stale 問題、無 layout 回授迴圈。
    @State var slotFrontHeights: [CGFloat] = Array(
        repeating: TodayReviewPresenter.initialFrontSlotHeight,
        count: TodayReviewCardSlotLayout.slotCount
    )
    // 三階量測快取已隨卡片渲染搬進 `ReviewCardView` 自己的 @State（IMP-20260808-ee7ca4）。

    // #2026 卡片區高度過渡 —— 規則見 TodayReviewDeckHeight.swift。
    // `deckShellHeight`：獨立的單一 CGFloat，role 翻面時以 reviewNavigationSpring
    // 過渡一次（nil ↔ 固定值無法插值，所以不再讓 active slot 的 nil 直接定義高度）。
    // 0 = 尚未建立（啟動量測前），此時改用量測目標。
    @State var deckShellHeight: CGFloat = 0
    /// 過渡動畫進行中：model 值立刻等於目標，但畫面還在飛 —— active 需持續釘高，
    /// 否則 layout 會立刻跳到自然高度。完成回呼放下。
    @State var deckHeightInFlight = false
    /// 重新指向時作廢舊動畫的完成回呼。
    @State var deckHeightGeneration = 0
    /// 卡片區 ZStack 的最新 layout 高度（含背面展開後的總高）。reference box：
    /// 逐幀寫入不觸發 body；只在 completeFling 的 settle 縫讀一次當過渡起點。
    @State var deckHeightProbe = DeckHeightProbe()
    /// 背面展開 settle 後記下的卡片區總高（previous / shuffle / autoplay 離場的接手起點；
    /// 規則見 `TodayReviewDeckHeight.RevealLatch`）。展開中同時是非 active cap 的依據
    /// （`deckSettledBackHeight`），背面高度變動時由 `trackRevealedBackHeight` 追蹤（#2026 r7）。
    /// 離場被 retarget 消化、或同卡收合即丟棄。
    @State var deckRevealLatch: TodayReviewDeckHeight.RevealLatch?

    /// 目前 active slot 的實測 front 高度 = 過渡目標（非 active slot cap 到此值）。
    var activeCardHeight: CGFloat {
        guard let activeSlot = state.slots.firstIndex(where: { $0.assignment.role == .active }),
              slotFrontHeights.indices.contains(activeSlot) else {
            return Self.initialFrontSlotHeight
        }
        return ReviewCardLayoutSolver.activeShellHeight(
            heights: slotFrontHeights,
            activeIndex: activeSlot
        )
    }

    // Back-content mount gate. Decoupled from `showsAnswer` so the heavy back
    // tree (CardDocumentView / CardRichTextRenderer / VocabTierLabel /
    // reviewLinkStrip) is NOT built while the FRONT card is shown (subtraction
    // probe — see answerFoldSurface), yet STAYS mounted through the whole collapse
    // fold. `showsAnswer` flips instantly but `PaperFoldModifier.progress`
    // interpolates 1→0 over the spring; unmounting on the instant flip would tear
    // the real content out at progress≈1 and fold an empty box. So: mount on the
    // rising edge (content appears under the opacity-0 cover of the opening fold),
    // and defer unmount to AFTER the spring settles on the falling edge.
    @State var backContentMounted = false
    // Generation token: cancels a pending deferred-unmount when the user
    // re-reveals before the collapse settles, or when the card advances.
    @State var backMountGeneration = 0
    // With the per-card `.id` gone the answer subtree is reused across cards, so
    // the advance frame would otherwise feed the showsAnswer:true→false falling
    // edge into the reveal-collapse spring — the new front card would visually
    // "un-fold" the previous card's back. Suppress the reveal spring for exactly
    // the advance frame (set true in onChange(currentCardKey), cleared next
    // runloop) so PaperFoldModifier.progress snaps to 0 without rewinding. Same
    // single-frame main-thread gate pattern the fling settle uses.
    @State var suppressFoldAnimation = false
    // Spring settle budget for reviewRevealSpring (response 0.42, damping 0.88).
    // Mirrors the 0.8s safety window the swipe deck uses for settle.frames.
    private static let revealSettleSeconds: Double = 0.85

    /// 角色翻面 / 目標高度改變的觸發鍵。active slot 換了、但新舊卡高度相同時
    /// `target` 不變，仍須重新規劃（否則 settle 時釘住的起點永不放開）。
    struct DeckHeightKey: Equatable {
        let activeSlot: Int?
        let target: CGFloat
        let revealed: Bool
    }

    var deckHeightKey: DeckHeightKey {
        DeckHeightKey(
            activeSlot: state.slots.firstIndex(where: { $0.assignment.role == .active }),
            target: activeCardHeight,
            revealed: state.revealStage.showsAnswer
        )
    }

    /// 離開「已展開且 settle 的卡」時的接手高度（翻面當幀有值，retarget 後 latch 清掉）。
    var deckHandoffHeight: CGFloat? {
        deckRevealLatch?.handoffHeight(currentCardKey: currentCardKey)
    }

    /// 過渡值的有效起點 —— 有接手高度就用它（螢幕上當下是背面總高）。
    var deckEffectiveShell: CGFloat {
        TodayReviewDeckHeight.effectiveShell(shell: deckShellHeight, handoff: deckHandoffHeight)
    }

    /// 卡片區過渡中（與 `deckSlotHeight` 的 active 釘高同一判定）。#3110：點一下展開 hint 在此期間隱藏。
    var deckIsTransitioning: Bool {
        TodayReviewDeckHeight.isTransitioning(
            shell: deckEffectiveShell,
            target: activeCardHeight,
            inFlight: deckHeightInFlight
        )
    }

    /// 點一下展開 hint 的 `.animation` 值（#3110）；種類判定見 `TodayReviewDeckHeight.expandZoneMotion`。
    func expandZoneAnimation(zoneActive: Bool) -> Animation? {
        switch TodayReviewDeckHeight.expandZoneMotion(
            zoneActive: zoneActive, deckIsTransitioning: deckIsTransitioning
        ) {
        case .snap: return nil
        case .contentFade: return AppMotion.contentFade
        case .revealSpring: return AppMotion.reviewRevealSpring
        }
    }

    /// 已 settle 的展開背面高度（同一張卡仍展開才有效；見 `RevealLatch`）。非 nil 時非 active
    /// slot 的 cap 取它（見 `TodayReviewDeckHeight.slotHeight` 的 `settledBack`）。
    var deckSettledBackHeight: CGFloat? {
        guard let latch = deckRevealLatch,
              latch.survives(currentCardKey: currentCardKey, revealed: state.revealStage.showsAnswer)
        else { return nil }
        return latch.height
    }

    /// slot 的 layout 高度（nil = 自然高度）。cardSlotView 與 deckDepthShell 共用。
    /// `settled: false` 只給裝飾殼層：殼層維持正面基準，不隨展開背面下移外露。
    func deckSlotHeight(isActive: Bool, settled: Bool = true) -> CGFloat? {
        TodayReviewDeckHeight.slotHeight(
            isActive: isActive,
            shell: deckEffectiveShell,
            target: activeCardHeight,
            inFlight: deckHeightInFlight,
            revealed: state.revealStage.showsAnswer,
            settledBack: (settled && !isActive) ? deckSettledBackHeight : nil
        )
    }

    /// 依規劃把 `deckShellHeight` 帶向目標。由 `.onChange(of: deckHeightKey)` 觸發 ——
    /// 涵蓋 fling / 按鈕 / autoplay / previous / shuffle 全部 role 翻面路徑，
    /// 不依賴 dismissProgress（它只在 fling 時變動且 200pt 飽和）。
    func retargetDeckHeight() {
        let revealed = state.revealStage.showsAnswer
        // 起點取接手高度（背面離場）或過渡值；latch 一經消化 / 收合就丟。
        let displayed = deckEffectiveShell
        let handedOff = deckHandoffHeight != nil
        if let latch = deckRevealLatch,
           !latch.survives(currentCardKey: currentCardKey, revealed: revealed) {
            deckRevealLatch = nil
        }
        switch TodayReviewDeckHeight.plan(
            displayed: displayed,
            target: activeCardHeight,
            revealed: revealed
        ) {
        case .hold:
            // 接手值與目標同高：model 值仍是正面舊值，必須對齊，否則 active 永遠釘在舊值。
            if handedOff {
                var noAnim = Transaction(animation: nil)
                noAnim.disablesAnimations = true
                withTransaction(noAnim) {
                    deckShellHeight = displayed
                    deckHeightInFlight = false
                }
            }
            return
        case .snap(let height):
            deckHeightGeneration += 1
            var noAnim = Transaction(animation: nil)
            noAnim.disablesAnimations = true
            withTransaction(noAnim) {
                deckShellHeight = height
                deckHeightInFlight = false
            }
        case .animate(let height):
            deckHeightGeneration += 1
            let generation = deckHeightGeneration
            deckHeightInFlight = true
            withAnimation(AppMotion.reviewNavigationSpring, completionCriteria: .logicallyComplete) {
                deckShellHeight = height
            } completion: {
                if generation == deckHeightGeneration { deckHeightInFlight = false }
            }
        }
    }

    enum DismissPhase {
        case idle
        case animatingOut
    }

    let state: TodayReviewPresenterState
    var notebookSettingsResolver = NotebookSettingsResolver(
        globalReviewSettings: .default,
        globalCardLayout: .default
    )
    let isHelpPresented: Bool
    let showFirstRunHint: Bool
    let onClose: () -> Void
    let onAdvanceReveal: () -> Void
    let onCollapseReveal: () -> Void
    let onShuffle: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onForgot: () -> Void
    let onRemembered: () -> Void
    let onLinkTap: (KGCardLinkSummary) -> Void
    let onAddLink: () -> Void
    let onToggleAutoPlay: () -> Void
    let onToggleAutoPlayPause: () -> Void
    let onChangeAutoPlaySpeed: () -> Void
    let onToggleAutoPlaySound: () -> Void
    /// Opens the shared review-card layout editor. The owner pauses autoplay and
    /// presents; the presenter only reports the intent.
    let onAdjustLayout: () -> Void
    let onDetailTap: () -> Void
    let onToggleHelp: () -> Void
    let onExplainCollocation: (String) -> Void
    let onViewCollocationExplanation: (String) -> Void
    let onDeleteCollocationExplanation: (String) -> Void
    var collocationExplanations: [String: String] = [:]
    /// notebookId → 卡上標示。只有多單字本 session 才有內容；空表 ＝ 不畫（#2040）。
    var notebookBadges: [String: ReviewCardNotebookBadge] = [:]
    /// #2041：精簡卡 chrome 的「暫時看詳細／恢復精簡」。預設 no-op（fixture / catalog）。
    var onToggleTemporaryDetail: () -> Void = {}

    /// 給 extension 判斷能否互動
    var isCardInteractive: Bool {
        dismissPhase == .idle
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let currentCard = state.currentCard {
                    topBar

                    GeometryReader { geo in
                        // One viewport value owns the card region's arithmetic: the
                        // insets drawn below, the reveal zone's floor, and every
                        // budget the solver is handed all come from here.
                        let viewport = ReviewCardViewport(containerHeight: geo.size.height)
                        VStack(spacing: 0) {
                            reviewCard(currentCard, viewport: viewport)
                                .padding(.horizontal, TodayReviewMetrics.cardHorizontalInset)
                                .padding(.top, TodayReviewMetrics.cardTopInset)
                                .padding(.bottom, TodayReviewMetrics.cardBottomInset)

                            // expandZone 常駐（settle 白工 1c）：條件 `if` 在每次
                            // 推進的 settle 幀做結構 insert（含 transition machinery
                            // 的 _makeView）；改為常駐節點，front/answer 切換只是
                            // 高度/透明度/命中/a11y 的值 diff。
                            let zoneActive = state.revealStage == .front
                            // #3110：卡片區飛行中隱藏（不沿彈簧上飄），settle 後 fade in。
                            let zoneVisible = zoneActive && !deckIsTransitioning
                            revealExpandZone(
                                title: L10n.string("點一下展開"),
                                minHeight: viewport.revealZoneReserve,
                                action: onAdvanceReveal
                            )
                            .frame(height: zoneActive ? nil : 0, alignment: .top)
                            .opacity(zoneVisible ? 1 : 0)
                            .animation(expandZoneAnimation(zoneActive: zoneActive), value: zoneVisible)
                            .allowsHitTesting(zoneVisible && isCardInteractive)
                            .accessibilityHidden(!zoneActive)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }

                    bottomToolbar
                } else {
                    completionState
                }
            }
            // The review cover is a full-screen surface. Keep the root column
            // tied to that proposal across reveal/card transitions; otherwise
            // SwiftUI may remeasure this VStack at intrinsic content height,
            // moving the card and grading toolbar upward while the background
            // still fills the screen and leaves a large empty area below it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            #if targetEnvironment(macCatalyst)
            .overlay {
                if isHelpPresented {
                    appSkin.palette.shadow.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { onToggleHelp() }
                        // Catalyst-only scrim; dismissal is the keyboard shortcut / help toggle.
                        .accessibilityHidden(true)
                        .transition(.overlayFade)

                    shortcutHelpOverlay
                        .transition(.overlayFade)
                }
            }
            .animation(AppMotion.panelState, value: isHelpPresented)
            #endif
            .platformContentMaxWidth(for: LayoutMode(horizontalSizeClass: sizeClass))
            .vocabCanvasBackground()
            .platformHideNavigationBar()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                // 動畫進行中不更新，避免 truncateRadius 變化導致 view rebuild 中斷 transition
                guard dismissPhase == .idle, !state.revealStage.showsAnswer else { return }
                containerWidth = newWidth
            }
            .onChange(of: state.revealStage) { _, stage in
                guard stage.showsAnswer else { return }
                speakCurrentAutoplayCardIfNeeded()
            }
            .onChange(of: state.revealStage.showsAnswer, initial: true) { _, shows in
                updateBackContentMount(showsAnswer: shows)
            }
            .onChange(of: currentCardKey) { _, _ in
                // Card advanced (next / previous / shuffle / submit / autoplay-advance):
                // the answer subtree is now reused in place after removing `.id`.
                // Drop the gate immediately (generation bump + unmount) so the NEW
                // front card doesn't inherit a mounted heavy back tree (would defeat
                // the front-render subtraction probe). Suppress the reveal-collapse
                // spring for this single advance frame so the reused fold subtree
                // snaps progress→0 instead of rewinding the previous card's reveal.
                // fling 路徑已在 completeFling 的 transaction 內「推進前」放閘
                // （幽靈背面樹修復），此處冪等補收其他推進路徑；guard 避免對
                // 已放下的閘重複寫 @State（多餘 invalidation）。
                backMountGeneration += 1
                if backContentMounted { backContentMounted = false }
                if !suppressFoldAnimation {
                    suppressFoldAnimation = true
                    DispatchQueue.main.async { suppressFoldAnimation = false }
                }
            }
            .onChange(of: state.progressText) { _, _ in
                if lastAutoplaySpokenCardKey != nil { lastAutoplaySpokenCardKey = nil }
            }
            .onChange(of: state.keyboardGrade) { _, request in
                // 鍵盤評分（#3127）：與按鈕同一入口，甩出中則暫存、settle 後套用。
                guard let request else { return }
                gradeFromControl(remember: request.remember, source: "keyboard")
            }
            .appFeedback(.gradeRemembered, trigger: flingRememberedTrigger)
            .appFeedback(.gradeForgot, trigger: flingForgotTrigger)
            .animation(AppMotion.panelState, value: isHelpPresented)
        }
        .task {
            // probe 的 fling 入口 = 評分按鈕的同一條路徑（flingCard → suppress /
            // settle 全套機械）。閉包只讀寫 @State（live storage）與穩定的
            // callback let，無 stale-struct 問題 — 與 swipeDragGesture 同模式。
            guard let reviewProbeDriver else { return }
            reviewProbeDriver.flingHandler = { direction, remember in
                guard dismissPhase == .idle else { return false }
                flingCard(
                    direction: direction,
                    source: "probe",
                    callback: remember ? onRemembered : onForgot
                )
                return true
            }
        }
        .enableInjection()
    }

    /// Presenter-level identity for the active card (dateAdded + word). Drives the
    /// back-mount gate reset and reveal-spring suppression on every card advance;
    /// independent of any view `.id`, so the reused subtree still resets per card.
    private var currentCardKey: String {
        state.currentCard?.card.reviewCardKey ?? ""
    }

    /// Drive `backContentMounted` with a lagged falling edge so the collapse fold
    /// always folds the real back content (blocker: collapse regression), while
    /// keeping it unmounted on the front card (subtraction probe).
    ///
    /// - rising (front→back): mount synchronously — the content must exist as the
    ///   `PaperFoldModifier` opens (progress 0→1, opacity 0→1), so it builds under
    ///   the opacity-0 cover and reveals in-place. Also opens a `reveal.frames`
    ///   sampler so the operator can confirm the now-reveal-time back-tree build
    ///   doesn't drop frames (didn't move the hitch from front render to reveal).
    /// - falling (back→front, same card): KEEP mounted; defer unmount to after the
    ///   spring settles so progress 1→0 folds the real content. Generation-guarded
    ///   so a re-reveal mid-collapse cancels the unmount.
    private func updateBackContentMount(showsAnswer: Bool) {
        backMountGeneration += 1
        let generation = backMountGeneration
        if showsAnswer {
            backContentMounted = true
            latchRevealedDeckHeight(generation: generation)
            #if DEBUG
            PerfLog.review.startFrameSampler("reveal.frames")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.revealSettleSeconds * 1_000_000_000))
                PerfLog.review.stopFrameSampler("reveal.frames")
            }
            #endif
        } else {
            // Defer unmount until the collapse fold finishes; re-reveal or card
            // advance bumps the generation and cancels this.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.revealSettleSeconds * 1_000_000_000))
                guard generation == backMountGeneration,
                      !state.revealStage.showsAnswer else { return }
                backContentMounted = false
            }
        }
    }

    /// reveal 的摺疊 spring settle 後，把當下卡片區總高記成離場接手起點。
    /// generation 同 back-mount 閘：再次 reveal / 收合 / 換卡都會 bump → 作廢。
    /// 注意 Task 捕獲的是 presenter 的舊 snapshot（state 是 let），所以卡片 key 在排程當下
    /// 取、不在 Task 內讀；settle 前離場者（<0.85s）落回舊行為（已記為 deviation）。
    private func latchRevealedDeckHeight(generation: Int) {
        let cardKey = currentCardKey
        let probe = deckHeightProbe
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.revealSettleSeconds * 1_000_000_000))
            guard generation == backMountGeneration else { return }
            // 展開中非 active cap 會由正面高度改到背面高度：以 reveal spring 寫入，預覽下緣連續過渡、不瞬跳。
            withAnimation(AppMotion.reviewRevealSpring) {
                deckRevealLatch = TodayReviewDeckHeight.RevealLatch(cardKey: cardKey, measured: probe.layoutHeight)
            }
        }
    }

    /// 展開中 active 的自然高度（＝背面總高）變動時，追蹤進 latch（#2026 r7；規則見 `RevealLatch.tracking`）。
    /// 不加動畫：active 的自然高度本身是瞬間變的，cap 若跟著 spring 會讓卡片區落後於卡片，露出縫。
    func trackRevealedBackHeight(_ height: CGFloat) {
        guard let next = deckRevealLatch?.tracking(
            measured: height,
            currentCardKey: currentCardKey,
            revealed: state.revealStage.showsAnswer
        ) else { return }
        var noAnim = Transaction(animation: nil)
        noAnim.disablesAnimations = true
        withTransaction(noAnim) {
            deckRevealLatch = next
        }
    }

    private func speakCurrentAutoplayCardIfNeeded() {
        guard state.isAutoPlaying,
              state.autoplaySoundEnabled,
              let card = state.currentCard?.card
        else { return }
        let key = "\(card.dateAdded.timeIntervalSinceReferenceDate)-\(card.word)"
        guard key != lastAutoplaySpokenCardKey else { return }
        lastAutoplaySpokenCardKey = key
        speechService.speak(card.word)
    }

    // MARK: - Card

    func reviewCard(_ currentCard: TodayReviewPresenterState.CurrentCard, viewport: ReviewCardViewport) -> some View {
        let card = currentCard.card
        let _ = PerfLog.render.tick(
            "todayReview.card.body",
            "chars=\(card.word.count) reveal=\(state.revealStage.rawValue) blocks=\(currentCard.backDocument.blocks.count)"
        )
        // 轉場合成追蹤：僅在轉場期間(fling 中或有 swipe offset)逐幀 mark 作用中
        // 互動卡片的單字 + 狀態機,對照 stack.preview / front.chrome 看 fling 期間
        // 究竟合成了哪一層、chrome 何時補上。idle 不觸發,避免 reveal 動畫洪流。
        if dismissPhase != .idle || swipeOffset != 0 {
            PerfLog.review.mark(
                "compose.active",
                "w=\(card.word) dismiss=\(dismissPhase == .idle ? "idle" : "out") supp=\(suppressFoldAnimation) off=\(Int(swipeOffset))"
            )
        }

        // Phase 4 常駐三 slot：結構永不變 —— depth-2 殼層 + slot0/1/2 恆在
        // view tree。推進（fling settle / previous / shuffle / autoplay）只翻 role
        // 與 transform 值，settle 幀零 _makeView、深度堆疊零空窗。
        // promote / 連續堆疊機制見 TodayReviewCardSlot.swift。
        return ZStack(alignment: .top) {
            // depth-2 殼層 — 純裝飾常駐節點（卡不足以 opacity 隱藏，不結構移除）。
            deckDepthShell(height: deckSlotHeight(isActive: false, settled: false) ?? 0)

            cardSlotView(slot: 0, viewport: viewport)
            cardSlotView(slot: 1, viewport: viewport)
            cardSlotView(slot: 2, viewport: viewport)
        }
        .onAppear {
            guard introProgress < 1 else { return }
            withAnimation(AppMotion.reviewRevealSpring) { introProgress = 1 }
        }
        .onChange(of: deckHeightKey) { _, _ in retargetDeckHeight() }
        // 卡片區 ZStack 的 layout 高度：使用者看到的「卡片區高度」本身。
        // box 寫入不觸發 body（見 deckHeightProbe）；DEBUG 另發 gap.geom（#2026 量測，
        // onGeometryChange 對動畫中的 layout 逐幀觸發，相鄰事件 |Δh| = 單幀跳變量）。
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            deckHeightProbe.layoutHeight = h
            #if DEBUG
            PerfLog.review.mark(
                "gap.geom",
                "slot=-1 role=deck kind=deck w=\(card.word) h=\(String(format: "%.1f", h)) reveal=\(state.revealStage.rawValue) dismiss=\(dismissPhase == .idle ? 0 : 1) off=\(Int(swipeOffset)) idx=\(state.progressText)"
            )
            #endif
        }
    }

    // MARK: - Completion / Expand Zone

    var completionState: some View {
        VStack(spacing: appSkin.metrics.cardBlockPadding) {
            Spacer()
            VocabEmptyStateContent(
                title: L10n.string("今天複習完成"),
                systemImage: "checkmark.circle",
                description: L10n.string("這一輪 session 的卡片都處理完了。"),
                guidanceText: L10n.string("todayReview.completion.nextDue"),
                symbolBounce: celebrationTriggered
            )
            .scaleEffect(celebrationTriggered ? 1 : 0.8)
            .opacity(celebrationTriggered ? 1 : 0)
            .onAppear {
                withAnimation(AppMotion.celebrationBounce) {
                    celebrationTriggered = true
                }
            }
            Button(L10n.string("返回單字本"), action: onClose)
                .buttonStyle(.ghost(appSkin.palette.primaryText))
            Spacer()
        }
        .padding(.horizontal, appSkin.metrics.cardBlockPadding)
        .appFeedback(.success, trigger: celebrationTriggered) { _, newValue in newValue }
    }

    func revealExpandZone(
        title: String,
        minHeight: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                AppRoundedRect(roundness: AppRoundness.pill)
                    .fill(appSkin.palette.quaternaryTextFaint)
                    .frame(width: 56, height: 3)
                Text(title)
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.quaternaryText.opacity(TodayReviewMetrics.dimTextOpacity))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // gap 調查：UITest 讀此元件 frame.minY = expand zone 頂 = 卡片區底界，
        // 與 todayReview.card.front.maxY 的差即使用者看到的「卡片↔底部縫隙」。
        .accessibilityIdentifier("todayReview.expandZone")
    }
}
