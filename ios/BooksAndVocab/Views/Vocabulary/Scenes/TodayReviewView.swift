import SwiftUI
import SwiftData

private enum ReviewTiming {
    static let shortcutHintDismissDelay: Duration = .seconds(3)
}

/// Decides whether review hotkeys must yield to an active modal surface.
/// Covers the link/sheet surfaces that present over the review. Help (`isHelpPresented`)
/// is deliberately excluded: Esc and `?` are handled by the switch itself to close it.
/// Kept ungated (not behind macCatalyst) so the policy is unit-testable on iOS.
enum TodayReviewHotkeyPolicy {
    static func suppressesHotkeys(
        hasLinkedCardStack: Bool,
        hasAddLinkRequest: Bool,
        hasPendingLinkDetail: Bool,
        isLayoutEditorPresented: Bool,
        hasTappedLink: Bool,
        hasExplainSheet: Bool
    ) -> Bool {
        hasLinkedCardStack
            || hasAddLinkRequest
            || hasPendingLinkDetail
            || isLayoutEditorPresented
            || hasTappedLink
            || hasExplainSheet
    }

    /// #3301：`onKeyPress` 預設同時送 `.down` 與 `.repeat`，按住方向鍵會連續 `.repeat`。
    /// 鍵盤評分只認初次 `.down`，一次按壓只登記一筆評分（FIFO 不會因按住而累積至上限 8 筆）。
    static func acceptsGradeKeyPhase(_ phase: KeyPress.Phases) -> Bool {
        phase == .down
    }
}

enum ReviewIntent {
    case reveal
    case collapse
    case forgot
    case remembered
    case previous
    case next
    case shuffle
    case showDetail
    case toggleAutoplay
    case toggleAutoplayPause
    case changeAutoplaySpeed
    case toggleAutoplaySound
    case close
    case showHelp
}

struct TodayReviewSession: Identifiable, Equatable {
    static func == (lhs: TodayReviewSession, rhs: TodayReviewSession) -> Bool { lhs.id == rhs.id }
    let id = UUID()
    let entries: [VocabularyEntry]
}

enum TodayReviewRevealStage: Int {
    case front
    case back

    var showsAnswer: Bool { self == .back }

    mutating func advance() {
        switch self {
        case .front: self = .back
        case .back: break
        }
    }

    mutating func retract() {
        switch self {
        case .front: break
        case .back: self = .front
        }
    }
}

struct CollocationExplainItem: Identifiable {
    let id = UUID()
    let collocation: String
    let context: String
    let existingExplanation: String?
}

struct TodayReviewView: View {
    @ObserveInjection private var inject
    @Environment(\.modelContext) private var modelContext
    @Environment(\.reviewSettingsStore) private var reviewSettingsStore
    @Environment(\.reviewCardLayoutStore) private var reviewCardLayoutStore
    @Query private var notebookSettings: [NotebookSettingsProjection]
    @Environment(\.toastCoordinator) private var toastCoordinator

    @State private var state: TodayReviewState

    @Environment(\.kgService) private var kgService
    @Environment(\.authManager) private var authManager
    // 自主量測 probe（-reviewProbe）— 一般啟動恆為 nil，.task 直接 return。
    @Environment(\.reviewProbeDriver) private var reviewProbeDriver

    @State private var isHelpPresented = false
    // Frozen at tap time: the sheet keeps linking the card it was opened on even
    // if the queue moves underneath it.
    @State private var addLinkRequest: AddLinkSheetRequest?
    @State private var pendingLinkDetail: PendingLinkDetailRequest?
    @State private var showLayoutEditor = false
    // #3124：開啟編輯器時凍結的目標單字本（nil = 全域）。sheet 開著期間不隨卡片移動而換目標。
    @State private var layoutEditTarget: LayoutEditTarget?
    @State private var notebookLayoutSaver = NotebookSettingsSaver()

    private struct LayoutEditTarget: Equatable {
        let notebookId: String
        let notebookName: String
    }
    // 卡上單字本標示（#2040）。刻意不用 @Query：複習頁對 body 重算敏感（翻卡手感戰役），
    // Notebook 任何寫入（同步、改色、換封面）都不該讓它重算。session 開始時查一次，
    // 之後只在明確事件才重算（目前僅 session 開始，見 `refreshNotebookBadges`）。
    @State private var notebookBadges: [String: ReviewCardNotebookBadge] = [:]
    @State private var explainSheetItem: CollocationExplainItem? = nil
    #if targetEnvironment(macCatalyst)
    @State private var hasConsumedShortcutHint = false
    @AppStorage("kg_mac_review_shortcut_hint_shown") private var hasShownShortcutHint = false
    @State private var shortcutHintTask: Task<Void, Never>?
    #endif

    private let allEntries: [VocabularyEntry]
    // Long-lived owner of link creations; read here so pending items re-render
    // and cached cards rebuild when a job changes state.
    private let creationHub: AddLinkCreationHub
    let onClose: () -> Void

    init(
        entries: [VocabularyEntry],
        allEntries: [VocabularyEntry],
        currentUserID: String?,
        onClose: @escaping () -> Void
    ) {
        // Touch the hub before the state prewarms cards so restored pending
        // creations are already in the projection when the first card is built.
        creationHub = AddLinkCreationHub.shared
        _state = State(initialValue: TodayReviewState(
            entries: entries,
            allEntries: allEntries,
            currentUserID: currentUserID
        ))
        self.allEntries = allEntries
        self.onClose = onClose
    }

    /// 複習頁的設定解析器（body 與切換面板確認共用，確保有效初始間隔來源一致）。
    private var reviewNotebookSettingsResolver: NotebookSettingsResolver {
        NotebookSettingsResolver(
            globalReviewStore: reviewSettingsStore,
            globalCardLayoutStore: reviewCardLayoutStore,
            projections: notebookSettings
        )
    }

    private var reviewModeSheetBinding: Binding<Bool> {
        Binding(
            get: { state.isReviewModeSheetPresented },
            set: { state.isReviewModeSheetPresented = $0 }
        )
    }

    /// 面板確認（#2042 Stage 3）：寫入方向與進度覆寫，失敗才回報。
    private func confirmReviewModeSwitch(level: Double) {
        state.isReviewModeSheetPresented = false
        let notebookId = state.currentEntry?.notebookId ?? "default"
        let initialIntervalHours = reviewNotebookSettingsResolver
            .snapshot(for: allEntries.map(\.notebookId))
            .reviewSettings(for: notebookId)
            .effectiveInitialIntervalHours
        guard state.applyReviewModeSwitch(
            level: level,
            initialIntervalHours: initialIntervalHours,
            now: Date()
        ) else { return }
        do {
            try modelContext.save()
        } catch {
            toastCoordinator.error(L10n.string("todayReview.saveFailure"))
        }
    }

    var body: some View {
        let _ = PerfLog.review.mark("treview.held", "inst=#\(state.instanceSeq) viewBody")
        let notebookSettingsResolver = reviewNotebookSettingsResolver
        let notebookSettingsSnapshot = notebookSettingsResolver.snapshot(
            for: allEntries.map(\.notebookId)
        )
        let reviewState = state
        let reviewModeSwitch = ReviewModeSwitchAction(isAvailable: state.canSwitchReviewMode) {
            reviewState.beginReviewModeSwitch()
        }
        return TodayReviewPresenter(
            state: state.presenterState,
            notebookSettingsResolver: notebookSettingsResolver,
            isHelpPresented: isHelpPresented,
            showFirstRunHint: shouldShowFirstRunHint,
            onClose: { perform(.close) },
            onAdvanceReveal: {
                perform(.reveal)
            },
            onCollapseReveal: {
                perform(.collapse)
            },
            onShuffle: { perform(.shuffle) },
            onPrevious: { perform(.previous) },
            onNext: { perform(.next) },
            onForgot: {
                perform(.forgot)
            },
            onRemembered: {
                perform(.remembered)
            },
            onLinkTap: { link in
                if link.isPendingCreation {
                    pendingLinkDetail = PendingLinkDetailRequest(link: link)
                } else {
                    state.handleLinkTap(link)
                }
            },
            onAddLink: {
                guard let entry = state.currentEntry else { return }
                // Autoplay would advance the card under the sheet; pause first
                // and leave it paused afterwards (same contract as the layout editor).
                state.pauseAutoPlayForModalInterruption()
                addLinkRequest = ReviewLinkEntryResolver.addLinkRequest(
                    sourceEntry: entry,
                    sessionEntries: allEntries,
                    context: modelContext
                )
            },
            onToggleAutoPlay: { perform(.toggleAutoplay) },
            onToggleAutoPlayPause: { perform(.toggleAutoplayPause) },
            onChangeAutoPlaySpeed: { perform(.changeAutoplaySpeed) },
            onToggleAutoPlaySound: { perform(.toggleAutoplaySound) },
            onAdjustLayout: {
                // Autoplay would keep flipping cards under the sheet; pause first
                // and leave it paused afterwards.
                state.pauseAutoPlayForModalInterruption()
                layoutEditTarget = makeLayoutEditTarget(for: state.presenterState.currentCard)
                showLayoutEditor = true
            },
            onDetailTap: { perform(.showDetail) },
            onToggleHelp: { perform(.showHelp) },
            onExplainCollocation: { collocation in
                guard let entry = state.currentEntry else { return }
                explainSheetItem = CollocationExplainItem(
                    collocation: collocation,
                    context: entry.context,
                    existingExplanation: nil
                )
            },
            onViewCollocationExplanation: { collocation in
                guard let entry = state.currentEntry else { return }
                explainSheetItem = CollocationExplainItem(
                    collocation: collocation,
                    context: entry.context,
                    existingExplanation: state.currentCollocationExplanations[collocation]
                )
            },
            onDeleteCollocationExplanation: { collocation in
                if !state.updateCollocationExplanation(nil, for: collocation, modelContext: modelContext) {
                    toastCoordinator.error(L10n.string("todayReview.saveFailure"))
                }
            },
            collocationExplanations: state.currentCollocationExplanations,
            notebookBadges: notebookBadges,
            onToggleTemporaryDetail: { state.toggleTemporaryDetail() },
            onToggleLinkGroup: { state.toggleLinkGroup($0) },
            gradeHints: state.gradeIntervalHints(settings: notebookSettingsSnapshot)
        )
        .environment(\.reviewModeSwitchAction, reviewModeSwitch)
        .toastOverlay()
        .task {
            refreshNotebookBadges()
        }
        .task {
            // A restored session may hold answers whose background DB flush
            // failed last run (flushed=false). Re-flush them so the card
            // schedule catches up; idempotent, so a clean restore is a no-op.
            let toast = toastCoordinator
            state.reflushUnflushedRestoredAnswers(
                container: modelContext.container,
                notebookSettingsSnapshot: notebookSettingsSnapshot,
                onSaveFailure: { toast.error(L10n.string("todayReview.saveFailure")) }
            )
        }
        .task {
            // Links being created when the app last died are re-attached here:
            // polled by operation id (or re-sent with the same key), then
            // projected locally. Idempotent for jobs that already have a coordinator.
            creationHub.resume(kgService: kgService, container: modelContext.container)
        }
        .onChange(of: creationHub.revision) { _, _ in
            // A pending link appeared, failed, or turned into a real one (sheet
            // open or not): rebuild only the affected source cards.
            let dirty = creationHub.takeDirtySourceCardIDs()
            guard !dirty.isEmpty else { return }
            // Light update, not a rebuild: a full rebuild resets the card's measured
            // heights and the open card would jump for a frame (#2133).
            for entry in state.queue where entry.kgCardId.map(dirty.contains) == true {
                state.refreshLinksForEntry(entry)
            }
        }
        .task {
            // probe 迴圈讀 reference 型 state（永遠新鮮）；fling 由 presenter
            // 註冊的 handler 走真實評分路徑。driver.run 對重複觸發 idempotent。
            guard let reviewProbeDriver else { return }
            await reviewProbeDriver.run(session: state)
        }
        .overlay {
            LinkedCardOverlayStack(stack: $state.linkedCardStack, allEntries: allEntries)
        }
        // Peers may be archived or restored inside the overlay; rebuild chips when it closes (#2535).
        .onChange(of: state.linkedCardStack.count) { _, _ in
            state.refreshPeerDependentCards()
        }
        // A peer flip after the overlay closed (a failed archive rolled back) re-derives the
        // chips too. The fingerprint is read in body, so SwiftUI tracks the peers it covers.
        .onChange(of: state.peerChipFingerprint) { _, _ in
            state.refreshPeerDependentCards()
        }
        .toastSheet(item: $state.tappedLink) { link in
            LinkReasonSheet(
                link: link,
                onNavigate: { navigateToLinkedCard(link) },
                onHide: {
                    guard let entry = state.currentEntry else { return }
                    let notebookId = entry.notebookId
                    let peer = ReviewLinkEntryResolver.entry(
                        forCardID: link.cardId,
                        snapshot: state.linkedEntryLookup,
                        context: modelContext
                    )
                    state.hideLink(link, peer: peer)
                    let toast = toastCoordinator
                    Task {
                        do {
                            try await kgService.hideLink(linkId: link.id, notebookId: notebookId)
                        } catch {
                            state.restoreHiddenLink(
                                link,
                                sourceEntry: entry,
                                targetEntry: peer
                            )
                            // #3130：樂觀隱藏失敗時連結已還原，必須告知使用者，不能無聲復活。
                            toast.error(L10n.string("todayReview.linkHideFailed"))
                        }
                    }
                }
            )
            .appSheet(.medium)
        }
        .toastSheet(item: $addLinkRequest) { request in
            AddLinkSheet(
                sourceEntry: request.sourceEntry,
                allEntries: request.allEntries,
                // 連結目標只能在來源同一本（`AddLinkCoordinator.isEligibleTarget`）；
                // 多單字本入口要明講，免得使用者以為能搜所有單字本。
                notebookScopeName: notebookBadges[request.sourceEntry.notebookId]?.name,
                // #2408: 成功只新增一列連結、不是新卡；保留 measurementCache。
                // link 集合改變時僅 graph-links 段重新量測（見 TodayReviewCardCache.refreshLinks）。
                onLinked: { state.refreshLinksForEntry(request.sourceEntry) }
            )
        }
        .toastSheet(item: $pendingLinkDetail) { request in
            PendingLinkDetailSheet(link: request.link)
                .appSheet(.medium)
        }
        .toastSheet(isPresented: reviewModeSheetBinding) {
            ReviewModeSheet(
                targetMode: state.reviewModeSwitchTarget,
                onConfirm: { level in confirmReviewModeSwitch(level: level) }
            )
            .appSheet(.medium)
        }
        .toastSheet(isPresented: $showLayoutEditor) {
            // Writes straight through to the layout the card actually draws (the
            // notebook override when it has one, else the shared store), so the card
            // behind the sheet re-lays out live. Nothing here touches reveal stage,
            // current index or session persistence.
            ReviewCardLayoutEditorSheet(
                previewCard: state.presenterState.currentCard,
                profile: layoutEditProfileBinding,
                notebookName: layoutEditTarget?.notebookName,
                onReset: layoutEditResetAction,
                onDone: { showLayoutEditor = false }
            )
        }
        .toastSheet(item: $explainSheetItem) { item in
            CollocationExplainSheet(
                collocation: item.collocation,
                context: item.context,
                existingExplanation: item.existingExplanation,
                onSave: { explanation in
                    if !state.updateCollocationExplanation(explanation, for: item.collocation, modelContext: modelContext) {
                        toastCoordinator.error(L10n.string("todayReview.saveFailure"))
                    }
                },
                onDelete: {
                    if !state.updateCollocationExplanation(nil, for: item.collocation, modelContext: modelContext) {
                        toastCoordinator.error(L10n.string("todayReview.saveFailure"))
                    }
                }
            )
            .appSheet(.medium)
        }
        .onDisappear {
            // Stop autoplay on dismiss — this onDisappear runs on every target
            // (it sits outside the macCatalyst #if below), so it is the single
            // teardown point for the 4s autoplay loop. Without this the loop
            // keeps mutating currentIndex/revealStage in the background and
            // retains the state object. stopAutoPlay() is idempotent.
            state.stopAutoPlay()

            let completed = state.currentIndex >= state.queue.count
            if !completed {
                let durationMs = Int(Date().timeIntervalSince(state.sessionStartTime) * 1000)
                AppAnalytics.track(.reviewSessionEnded(
                    remembered: state.rememberedCount,
                    forgot: state.forgotCount,
                    completed: false,
                    durationMs: durationMs
                ))
            }

            // Single persistence point. The per-flip submit path is store-free (a
            // per-card SwiftData save merged into the main context and froze the
            // next-card render); all deferred answers flush here in ONE batched save.
            // Finalize the crash-recovery snapshot and push to backend ONLY after the
            // store confirms — a failed flush keeps the snapshot so restore retries.
            // The flush is a detached background-context save, so this is NOT the
            // synchronous main-context onDisappear save that trips the teardown trap.
            let loggedIn = authManager.isLoggedIn && !authManager.isDemoMode
            let container = modelContext.container
            let toast = toastCoordinator
            state.flushPendingAnswers(
                container: container,
                notebookSettingsSnapshot: notebookSettingsSnapshot,
                onFinalize: {
                    // Clears only when every answer reached the store (#3123).
                    state.finalizeSnapshotAfterFlush(completed: completed)
                    guard loggedIn else { return }
                    Task { await kgService.pushReviewQuietly(container: container) }
                },
                onFailure: { toast.error(L10n.string("todayReview.saveFailure")) }
            )
        }
        #if targetEnvironment(macCatalyst)
        .focusable()
        .onKeyPress { press in
            handleCatalystKey(press) ? .handled : .ignored
        }
        .onAppear {
            guard !hasShownShortcutHint else { return }
            shortcutHintTask?.cancel()
            shortcutHintTask = Task { @MainActor in
                try? await Task.sleep(for: ReviewTiming.shortcutHintDismissDelay)
                guard !Task.isCancelled else { return }
                hasConsumedShortcutHint = true
                hasShownShortcutHint = true
            }
        }
        .onDisappear {
            shortcutHintTask?.cancel()
            shortcutHintTask = nil
        }
        // 複習快捷鍵說明(View menu)— review session active 時才 publish → menu 自動 disable。
        .focusedSceneValue(\.showReviewHelp, ShowReviewHelpAction { isHelpPresented = true })
        #endif
        .enableInjection()
    }

    // MARK: - Layout editor target (#3124)

    /// 開編輯器時決定目標：卡片所屬單字本有 override → 編輯它；否則 nil（全域 store）。
    private func makeLayoutEditTarget(for card: TodayReviewPresenterState.CurrentCard?) -> LayoutEditTarget? {
        guard let notebookId = card?.card.notebookId else { return nil }
        let resolver = NotebookSettingsResolver(
            globalReviewStore: reviewSettingsStore,
            globalCardLayoutStore: reviewCardLayoutStore,
            projections: notebookSettings
        )
        guard resolver.cardLayoutEditScope(notebookId: notebookId) == .notebook else { return nil }
        return LayoutEditTarget(notebookId: notebookId, notebookName: notebookDisplayName(notebookId))
    }

    /// 讀取即 @Query 的即時 override；寫入走設定頁同一條路（樂觀寫入投影 → NotebookSettingsSaver）。
    /// nil 代表編輯全域，由 `ReviewCardLayoutEditor` 退回 `reviewCardLayoutStore`。
    private var layoutEditProfileBinding: Binding<ReviewCardLayoutProfile>? {
        guard let notebookId = layoutEditTarget?.notebookId else { return nil }
        return Binding(
            get: {
                notebookSettings.first(where: { $0.notebookId == notebookId })?.cardLayoutOverride
                    ?? reviewCardLayoutStore.profile
            },
            set: { saveNotebookCardLayout($0, notebookId: notebookId) }
        )
    }

    private var layoutEditResetAction: (() -> Void)? {
        guard layoutEditTarget != nil else { return nil }
        return { resetLayoutEditTargetToGlobal() }
    }

    /// 「改用全域版面」：拿掉這本的 override。卡片隨即畫全域，編輯器也跟著切到全域。
    private func resetLayoutEditTargetToGlobal() {
        guard let notebookId = layoutEditTarget?.notebookId else { return }
        saveNotebookCardLayout(nil, notebookId: notebookId)
        layoutEditTarget = nil
    }

    private func saveNotebookCardLayout(_ profile: ReviewCardLayoutProfile?, notebookId: String) {
        let projection = notebookProjection(for: notebookId)
        let now = Date().timeIntervalSince1970
        let timestamp = projection.cardLayoutUpdatedAt.map { now > $0 ? now : $0.nextUp } ?? now
        projection.applyLocalCardLayout(profile, updatedAt: timestamp)
        guard modelContext.safeSave() else { return }

        Task { @MainActor in
            let outcome = await notebookLayoutSaver.saveCardLayout(
                projection: projection, profile: profile, updatedAt: timestamp, service: kgService
            )
            switch outcome {
            case .superseded:
                return
            case .applied:
                modelContext.safeSave()
            case let .failed(error):
                AppLog.kg.error("review layout notebook sync failed: \(error.localizedDescription)")
                toastCoordinator.error(L10n.string("notebookSettings.syncFailed"))
            }
        }
    }

    private func notebookProjection(for notebookId: String) -> NotebookSettingsProjection {
        if let existing = notebookSettings.first(where: { $0.notebookId == notebookId }) { return existing }
        let created = NotebookSettingsProjection(notebookId: notebookId)
        modelContext.insert(created)
        return created
    }

    private func notebookDisplayName(_ notebookId: String) -> String {
        let name = try? modelContext.fetch(
            FetchDescriptor<Notebook>(predicate: #Predicate { $0.remoteId == notebookId })
        ).first?.name
        return name ?? L10n.string("notebookSettings.notebookFallback")
    }

    /// 判斷看的是 session 自己的卡（queue），不是 allEntries：後者是連結查詢用的
    /// 候選池，單一單字本入口也可能混進其他本，拿它判會在單本入口誤畫標示。
    /// 單一單字本入口根本不查庫。
    private func refreshNotebookBadges() {
        let sessionNotebookIDs = state.queue.map(\.notebookId)
        guard ReviewCardNotebookBadgeResolver.spansMultipleNotebooks(sessionNotebookIDs) else {
            notebookBadges = [:]
            return
        }
        let notebooks: [Notebook]
        do {
            notebooks = try modelContext.fetch(
                FetchDescriptor<Notebook>(predicate: #Predicate { !$0.isSoftDeleted })
            )
        } catch {
            // 標示退回本地化備援名稱（永遠不是 id 字串），複習本身不受影響。
            AppLog.kg.error("review notebook badges fetch failed: \(error.localizedDescription)")
            notebooks = []
        }
        notebookBadges = ReviewCardNotebookBadgeResolver.badges(
            sessionNotebookIDs: sessionNotebookIDs,
            notebooks: notebooks
        )
    }

    /// Resolves the target against the live store (the session's lookup is a
    /// start-of-session snapshot) and tells the user when it cannot be found
    /// instead of silently doing nothing.
    private func navigateToLinkedCard(_ link: KGCardLinkSummary) {
        state.tappedLink = nil
        guard let target = ReviewLinkEntryResolver.entry(
            forCardID: link.cardId,
            snapshot: state.linkedEntryLookup,
            context: modelContext
        ) else {
            toastCoordinator.error(L10n.string("找不到符合的單字"))
            return
        }
        state.linkedCardStack.pushLinkedCard(target)
    }

    private var shouldShowFirstRunHint: Bool {
        #if targetEnvironment(macCatalyst)
        return !hasShownShortcutHint && !hasConsumedShortcutHint && !state.isAutoPlaying && state.currentIndex < min(state.queue.count, 3)
        #else
        return false
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Hardware-keyboard shortcuts on Mac Catalyst (replaces the old AppKit
    /// macKeyResponder path). Requires the view to hold keyboard focus.
    private func handleCatalystKey(_ press: KeyPress) -> Bool {
        guard !TodayReviewHotkeyPolicy.suppressesHotkeys(
            hasLinkedCardStack: !state.linkedCardStack.isEmpty,
            hasAddLinkRequest: addLinkRequest != nil,
            hasPendingLinkDetail: pendingLinkDetail != nil,
            isLayoutEditorPresented: showLayoutEditor,
            hasTappedLink: state.tappedLink != nil,
            hasExplainSheet: explainSheetItem != nil
        ) else { return false }
        switch press.key {
        case .space:
            return perform(state.revealStage == .front ? .reveal : .collapse)
        // 鍵盤評分走甩出路徑（#3127）：與按鈕、滑動同一條 fling，不直接 submit。
        case .leftArrow:
            return state.isAutoPlaying ? perform(.previous) : gradeFromKeyPress(press, remember: false)
        case .rightArrow:
            return state.isAutoPlaying ? perform(.next) : gradeFromKeyPress(press, remember: true)
        case .upArrow:
            return perform(.previous)
        case .downArrow:
            return perform(.next)
        case .escape:
            if isHelpPresented {
                isHelpPresented = false
                return true
            }
            return perform(.close)
        default:
            switch press.characters.lowercased() {
            case "d": return perform(.showDetail)
            case "s": return perform(.shuffle)
            case "p": return perform(state.isAutoPlaying ? .toggleAutoplayPause : .toggleAutoplay)
            case "?", "/": return perform(.showHelp)
            default: return false
            }
        }
    }
    /// #3301：`.repeat` 也回傳 handled（方向鍵不交給 focus 系統移動），但不登記評分請求。
    private func gradeFromKeyPress(_ press: KeyPress, remember: Bool) -> Bool {
        guard TodayReviewHotkeyPolicy.acceptsGradeKeyPhase(press.phase) else { return true }
        return state.requestKeyboardGrade(remember: remember)
    }
    #endif

    @discardableResult
    private func perform(_ intent: ReviewIntent) -> Bool {
        switch intent {
        case .close:
            onClose()
            return true

        case .showHelp:
            isHelpPresented.toggle()
            return true

        default:
            let handled = state.performReviewIntent(
                intent,
                container: modelContext.container,
                reviewSettings: reviewSettingsStore.settings
            )
            // 自動播放中評分 / 洗牌不是壞掉，是被擋（#2046）：說出原因，不要靜默無反應。
            if !handled, state.autoplayBlocks(intent) {
                toastCoordinator.warning(
                    L10n.string("todayReview.autoplay.blockedHint"),
                    key: TodayReviewState.autoplayBlockedNoticeKey
                )
            }
            return handled
        }
    }

}

// MARK: - Preview

#Preview("TodayReview / Session") {
    AppThemeContainer {
        TodayReviewView(
            entries: TodayReviewViewPreviewData.sampleEntries,
            allEntries: TodayReviewViewPreviewData.sampleEntries,
            currentUserID: "preview-user",
            onClose: {}
        )
        .modelContainer(for: [
            VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            NotebookSettingsProjection.self
        ], inMemory: true)
    }
    .environmentObject(AppAppearanceStore.preview)
}

private enum TodayReviewViewPreviewData {
    static let sampleEntries: [VocabularyEntry] = {
        let e1 = VocabularyEntry(
            word: "meticulous",
            translation: "一絲不苟的",
            context: "The editor was meticulous about every detail.",
            explanation: "做事非常細心、注意細節。",
            partOfSpeech: "adj.",
            bookTitle: "Designing Interfaces",
            chapterTitle: "Writing Tone"
        )
        e1.syncState = .synced
        e1.reviewMode = .recognition

        let e2 = VocabularyEntry(
            word: "ephemeral",
            translation: "短暫的",
            context: "Social media posts are ephemeral by nature.",
            explanation: "形容事物存在時間極短。",
            partOfSpeech: "adj.",
            bookTitle: "Designing Interfaces",
            chapterTitle: "Writing Tone"
        )
        e2.syncState = .synced
        e2.reviewMode = .recognition

        return [e1, e2]
    }()
}
