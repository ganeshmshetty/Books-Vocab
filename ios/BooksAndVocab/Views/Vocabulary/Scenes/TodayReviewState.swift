import SwiftUI
import SwiftData

@Observable @MainActor
final class TodayReviewState {
    struct SubmittedAnswer {
        let feedback: ReviewFeedback
        let answeredAt: Date
        let reviewRecordID: UUID
        /// Mirrors the snapshot flag: `true` once the background DB flush
        /// confirmed success. New answers start `false`; restore re-flushes any
        /// answer left `false`.
        var flushed: Bool = false
    }

    // MARK: - Card Navigation

    private var session: TodayReviewSessionState<VocabularyEntry>
    private var persistence: TodayReviewSessionPersistenceController
    private var cardCache = TodayReviewCardCache()
    private let autoplay = TodayReviewAutoplayController()
    private var collocationState = TodayReviewCollocationState()
    /// #2041: session-memory only. Cleared on every card change by
    /// `syncCurrentEntryDerivedState`; never written to a persisted store.
    private var temporaryDetail = ReviewCardTemporaryDetail()
    var linkedCardStack: [VocabularyEntry] = []
    var tappedLink: KGCardLinkSummary?
    static let cacheLookaheadLimit = 3

    // MARK: - Delegated concerns

    let scoring = ReviewScoringState()

    // MARK: - Scoring (forwarded projections — keep external API stable)

    var submittedAnswers: [Int: SubmittedAnswer] { scoring.submittedAnswers }
    var rememberedFeedbackTrigger: Int { scoring.rememberedFeedbackTrigger }
    var forgotFeedbackTrigger: Int { scoring.forgotFeedbackTrigger }
    var forgotCount: Int { scoring.forgotCount }
    var rememberedCount: Int { scoring.rememberedCount }
    /// 已作答的槽位（queue index）。洗牌時釘住，答案才不會對到別張卡（#2482）。
    private var answeredSlots: Set<Int> { Set(scoring.submittedAnswers.keys) }

    // MARK: - Perf (fling→front render gap self-measurement)
    nonisolated(unsafe) static var flingClock: DispatchTime?

    // MARK: - Analytics

    let sessionStartTime: Date
    private var sessionEndReported = false

    // MARK: - Immutable Lookup

    let linkedEntryLookup: [String: VocabularyEntry]
    let currentUserID: String?

    // MARK: - Diagnostics (throwaway-init detection)
    // Each construction bumps the global counter. If `state.init inst=#N` climbs
    // per flip while `treview.held inst=#M` (logged in the View body) stays fixed,
    // the climbing instances are built-and-discarded by a re-running
    // `State(initialValue:)` autoclosure — the real held state never changes.
    nonisolated(unsafe) static var instanceCounter = 0
    let instanceSeq: Int

    // MARK: - Init

    init(
        entries: [VocabularyEntry],
        allEntries: [VocabularyEntry],
        currentUserID: String?
    ) {
        let _initStart = DispatchTime.now()
        Self.instanceCounter += 1
        self.instanceSeq = Self.instanceCounter
        self.currentUserID = currentUserID
        // Per-phase sub-timing folded into the single `state.init` line so a throwaway
        // init's cost is attributable (load vs restore vs 636-entry lookup vs prewarm) —
        // decides whether killing the throwaway needs full ownership injection or just a
        // lazy `start()`. DispatchTime captures match the existing `_initStart` precedent.
        let _tLoad = DispatchTime.now()
        // 去重先於 loadOrder：之後的佇列、id、baseline 都保證 persistenceID 唯一。
        // 先以 shouldAppearInReview 決定佇列成員，再由 representative(among:) 選代表（與 flush 同一規則）。
        let reviewEntries = ReviewSessionPersistence.uniqueByPersistenceID(entries.filter(\.shouldAppearInReview))
        let ordered = ReviewSessionStore.loadOrder(
            availableEntries: reviewEntries,
            userID: currentUserID,
            // Today Review restores an unfinished queue even if sync added or removed cards
            // since the shuffle was saved; new cards are appended and missing cards filtered.
            allowPartialQueue: true
        ) ?? reviewEntries
        let _msLoad = PerfChannel.ms(since: _tLoad)
        let _tRestore = DispatchTime.now()
        let restored = ReviewSessionPersistence.restoreSnapshotIfPossible(
            orderedEntries: ordered,
            userId: currentUserID
        )
        let _msRestore = PerfChannel.ms(since: _tRestore)
        session = TodayReviewSessionState(queue: ordered)
        persistence = TodayReviewSessionPersistenceController(
            queue: ordered,
            currentUserID: currentUserID
        )
        sessionStartTime = restored?.sessionStartTime ?? Date()
        let _tLookup = DispatchTime.now()
        linkedEntryLookup = Self.buildLinkedEntryLookup(from: allEntries)
        let _msLookup = PerfChannel.ms(since: _tLookup)
        if let restored {
            session = TodayReviewSessionState(
                queue: restored.queue,
                currentIndex: restored.currentIndex
            )
            persistence = TodayReviewSessionPersistenceController(
                queuePersistenceIDs: restored.persistenceIDs,
                queueBaselines: restored.baselines,
                currentUserID: currentUserID
            )
            scoring.restore(
                submittedAnswers: restored.submittedAnswers,
                rememberedCount: restored.rememberedCount,
                forgotCount: restored.forgotCount
            )
        }
        let _tPrewarm = DispatchTime.now()
        syncCurrentEntryDerivedState()
        prewarmCardWindow()
        let _msPrewarm = PerfChannel.ms(since: _tPrewarm)
        AppAnalytics.track(.reviewSessionStarted(cardCount: ordered.count))
        PerfLog.review.mark("state.init", "inst=#\(instanceSeq) entries=\(reviewEntries.count) all=\(allEntries.count) queue=\(ordered.count) load=\(String(format: "%.1f", _msLoad)) restore=\(String(format: "%.1f", _msRestore)) lookup=\(String(format: "%.1f", _msLookup)) prewarm=\(String(format: "%.1f", _msPrewarm)) total=\(PerfChannel.ms(since: _initStart))ms")
    }

    // MARK: - Computed (State Projection)

    var queue: [VocabularyEntry] { session.queue }
    var currentIndex: Int { session.currentIndex }
    var revealStage: TodayReviewRevealStage { session.revealStage }
    var preparedCardCache: [UUID: TodayReviewPresenterState.CurrentCard] { cardCache.storage }
    var currentCollocationExplanations: [String: String] { collocationState.explanations }
    var canAutoplay: Bool { session.canAutoplay }
    var isAutoPlaying: Bool { autoplay.isPlaying }
    var isAutoPlayPaused: Bool { autoplay.isPaused }
    var autoplaySpeed: AutoplaySpeed { autoplay.speed }
    var autoplaySoundEnabled: Bool { autoplay.soundEnabled }

    var currentEntry: VocabularyEntry? {
        session.currentEntry
    }

    var progressText: String {
        session.progressText
    }

    var presenterState: TodayReviewPresenterState {
        TodayReviewPresenterState(
            progressText: progressText,
            currentCard: currentCardState,
            slots: slotModels,
            revealStage: revealStage,
            canShuffle: session.canShuffle(pinned: answeredSlots),
            canAutoplay: canAutoplay,
            canGoPrevious: session.canGoPrevious,
            canGoNext: session.canGoNext,
            remainingCount: session.remainingCount,
            forgotCount: forgotCount,
            rememberedCount: rememberedCount,
            rememberedFeedbackTrigger: rememberedFeedbackTrigger,
            forgotFeedbackTrigger: forgotFeedbackTrigger,
            isAutoPlaying: isAutoPlaying,
            isAutoPlayPaused: isAutoPlayPaused,
            autoplayProgress: queue.isEmpty ? 0 : Double(currentIndex) / Double(queue.count),
            autoplaySpeed: autoplaySpeed,
            autoplaySoundEnabled: autoplaySoundEnabled,
            temporaryDetailCardKey: temporaryDetail.detailedCardKey
        )
    }

    private var currentCardState: TodayReviewPresenterState.CurrentCard? {
        guard let current = currentEntry else { return nil }
        return cachedOrBuildCard(for: current)
    }

    var currentCardForTesting: TodayReviewPresenterState.CurrentCard? {
        currentCardState
    }

    private var nextCardState: TodayReviewPresenterState.CurrentCard? {
        let nextIndex = currentIndex + 1
        guard nextIndex < queue.count else { return nil }
        return cachedOrBuildCard(for: queue[nextIndex])
    }

    /// 常駐三 slot 投影（Phase 4）— 指派純推導自 (currentIndex, queue.count)，
    /// 內容走與 current/next 相同的 render-safe cache 路徑（非 mutating）。
    private var slotModels: [TodayReviewCardSlotModel] {
        TodayReviewCardSlotModel.make(currentIndex: currentIndex, queueCount: queue.count) { index in
            cachedOrBuildCard(for: queue[index])
        }
    }

    var nextCardForTesting: TodayReviewPresenterState.CurrentCard? {
        nextCardState
    }

    /// Fallback: build on-demand if async cache hasn't completed yet.
    private func cachedOrBuildCard(for entry: VocabularyEntry) -> TodayReviewPresenterState.CurrentCard? {
        // Render-path read MUST be non-mutating: this runs inside SwiftUI body
        // evaluation (presenterState → currentCardState/nextCardState) and cardCache
        // is @Observable; a mutating lookup fires a per-render mutation (even on a
        // hit) → infinite re-eval loop. Hits are served read-only; the
        // prewarm-covered, near-impossible miss builds an ephemeral card without
        // writing the observed cache (self-heals on the next prewarmCardWindow()).
        cardCache.cached(for: entry) ?? TodayReviewCardCache.buildOne(entry, peers: linkedEntryLookup)
    }

    // MARK: - Actions

    func handleLinkTap(_ link: KGCardLinkSummary) {
        tappedLink = link
    }

    func navigateToLinkedCard(link: KGCardLinkSummary) {
        guard let target = linkedEntryLookup[link.cardId],
              !target.isArchived, target.syncAction != .delete else { return }
        tappedLink = nil
        linkedCardStack.pushLinkedCard(target)
    }

    /// `peer` is the link's other end resolved live by the caller (it also
    /// finds cards created after the start-of-session snapshot, e.g. via Add
    /// Link); the snapshot is only the fallback. Hide and restore must act on the
    /// same peer or the reciprocal link stays visible on it.
    func hideLink(_ link: KGCardLinkSummary, peer: VocabularyEntry? = nil) {
        tappedLink = nil
        guard let entry = currentEntry else { return }
        setLinkHidden(
            true,
            for: link,
            sourceEntry: entry,
            targetEntry: peer ?? linkedEntryLookup[link.cardId]
        )
    }

    func restoreHiddenLink(
        _ link: KGCardLinkSummary,
        sourceEntry: VocabularyEntry,
        targetEntry: VocabularyEntry?
    ) {
        setLinkHidden(false, for: link, sourceEntry: sourceEntry, targetEntry: targetEntry)
    }

    private func setLinkHidden(
        _ hidden: Bool,
        for link: KGCardLinkSummary,
        sourceEntry: VocabularyEntry,
        targetEntry: VocabularyEntry?
    ) {
        VocabularyGraphLinkMutation.setHidden(
            hidden,
            for: link,
            source: sourceEntry,
            peer: targetEntry
        )
        rebuildCacheForEntry(sourceEntry)
        // Bidirectional link target: if it lives in the review queue its
        // prepared-card cache is now stale too. VocabularyEntry is a class, so
        // match by identity. currentEntry (always in queue) is rebuilt above.
        if let targetEntry {
            if targetEntry !== sourceEntry, queue.contains(where: { $0 === targetEntry }) {
                rebuildCacheForEntry(targetEntry)
            }
        }
    }

    func rebuildCacheForEntry(_ entry: VocabularyEntry) {
        cardCache.rebuild(for: entry, peers: linkedEntryLookup)
    }

    /// A peer was archived, restored or queued for delete while the session is open
    /// (e.g. in the linked-card overlay). Chips are dropped at build time, so every
    /// prepared card is rebuilt from the peers' current state (#2535). Called when the
    /// overlay stack changes; the peer objects are live, only their cached chips are stale.
    func refreshPeerDependentCards() {
        cardCache.invalidateAll()
        prewarmCardWindow()
    }

    /// The card's link set changed (pending link created/failed/resolved, or AddLink
    /// succeeded): update its links in place and keep its measurements (see
    /// `TodayReviewCardCache.refreshLinks`). Use `rebuildCacheForEntry` only when the
    /// card content itself changed.
    func refreshLinksForEntry(_ entry: VocabularyEntry, pendingLinks: [KGCardLinkSummary]? = nil) {
        cardCache.refreshLinks(for: entry, pendingLinks: pendingLinks, peers: linkedEntryLookup)
    }

    func handleDetailTap() {
        guard let current = currentEntry else { return }
        linkedCardStack.pushLinkedCard(current)
    }

    /// #2041: the compact card's "show detailed for now" button (same button
    /// restores compact). Action path only — never called from a body.
    /// Animated with the reveal spring so the card's height change is continuous.
    /// Showing the detail pauses autoplay (no auto-resume, like the layout editor):
    /// the next autoplay advance would otherwise forget the override within one
    /// interval, defeating "let me read this card in full".
    func toggleTemporaryDetail() {
        guard let key = currentCardState?.card.reviewCardKey else { return }
        withAnimation(AppMotion.reviewRevealSpring) {
            temporaryDetail.toggle(cardKey: key)
        }
        if temporaryDetail.isDetailed(cardKey: key) {
            pauseAutoPlayForModalInterruption()
        }
    }

    func advanceReveal() {
        _ = session.advanceReveal()
    }

    func retractReveal() {
        _ = session.retractReveal()
    }

    func shuffleQueue() {
        guard session.canShuffle(pinned: answeredSlots) else { return }
        withAnimation(AppMotion.reviewNavigationSpring) {
            _ = session.shuffleRemaining(pinned: answeredSlots)
        }
        syncCurrentEntryDerivedState()
        syncQueueMetadata()
        prewarmCardWindow()
        ReviewSessionStore.saveOrder(queue, userID: currentUserID)
        persistSnapshot()
    }

    func goPrevious() {
        guard session.canGoPrevious else { return }
        withAnimation(AppMotion.reviewNavigationSpring) {
            _ = session.goPrevious()
        }
        syncCurrentEntryDerivedState()
        if autoplay.isLoopActive {
            startAutoPlayLoop()
        }
        prewarmCardWindow()
        persistSnapshot()
    }

    func goNext() {
        guard session.canGoNext else { return }
        withAnimation(AppMotion.reviewNavigationSpring) {
            _ = session.goNext()
        }
        syncCurrentEntryDerivedState()
        if autoplay.isLoopActive {
            startAutoPlayLoop()
        }
        prewarmCardWindow()
        persistSnapshot()
    }

    // MARK: - Autoplay

    func toggleAutoPlay() {
        // 守衛只擋「開始」:已在播放時必須永遠能停,否則就是重造 autoplay 出不去的 bug。
        guard isAutoPlaying || canAutoplay else { return }
        autoplay.togglePlayback(restartLoop: { [weak self] in self?.startAutoPlayLoop() })
    }

    func toggleAutoPlayPause() {
        autoplay.togglePause(restartLoop: { [weak self] in self?.startAutoPlayLoop() })
    }

    func stopAutoPlay() {
        autoplay.stop()
    }

    /// Pause because a modal took over the card (the layout editor). Deliberately
    /// does NOT auto-resume on dismiss — the user came to change the card, so they
    /// decide when it starts moving again.
    func pauseAutoPlayForModalInterruption() {
        autoplay.pauseForInterruption()
    }

    func changeAutoplaySpeed(to speed: AutoplaySpeed) {
        autoplay.changeSpeed(to: speed, restartLoop: { [weak self] in self?.startAutoPlayLoop() })
    }

    func toggleAutoplaySound() {
        autoplay.toggleSound()
    }

    func updateCollocationExplanation(
        _ explanation: String?,
        for collocation: String,
        modelContext: ModelContext
    ) {
        collocationState.update(explanation, for: collocation, entry: currentEntry)
        modelContext.safeSave()
    }

    /// 自動播放中會被擋掉的操作（#2046）：評分與洗牌要等使用者先關閉自動播放（暫停不算：`isAutoPlaying` 在暫停時仍為 true，
    /// 擋的範圍與提示文案都以「關閉」為準，否則提示會叫人做一件解不開的事）。單一真相 ——
    /// `performReviewIntent` 的守衛與 view 層「為何沒反應」的 pill 提示都問它，
    /// 兩邊不會對「哪些操作被擋」各說各話。
    static func autoplayBlocks(_ intent: ReviewIntent, isAutoPlaying: Bool) -> Bool {
        guard isAutoPlaying else { return false }
        switch intent {
        case .forgot, .remembered, .shuffle: return true
        default: return false
        }
    }

    /// 「自動播放中請先關閉」pill 的事件鍵：按鈕 / 鍵盤 / 滑動三個入口共用同一個 key，
    /// 連點取代而非堆疊（pill 規範見 docs/sop/ui-design.md「暫時性提示」）。
    static let autoplayBlockedNoticeKey = "todayReview.autoplayBlocked"

    func autoplayBlocks(_ intent: ReviewIntent) -> Bool {
        Self.autoplayBlocks(intent, isAutoPlaying: isAutoPlaying)
    }

    @discardableResult
    func performReviewIntent(
        _ intent: ReviewIntent,
        container: ModelContainer,
        reviewSettings: ReviewSettings
    ) -> Bool {
        switch intent {
        case .reveal:
            guard revealStage == .front, currentEntry != nil else { return false }
            withAnimation(AppMotion.reviewRevealSpring) {
                advanceReveal()
            }
            return true

        case .collapse:
            guard revealStage == .back, currentEntry != nil else { return false }
            withAnimation(AppMotion.reviewRevealSpring) {
                retractReveal()
            }
            return true

        case .forgot:
            guard !autoplayBlocks(.forgot), currentEntry != nil else { return false }
            submit(.forgot, container: container, reviewSettings: reviewSettings)
            return true

        case .remembered:
            guard !autoplayBlocks(.remembered), currentEntry != nil else { return false }
            submit(.remembered, container: container, reviewSettings: reviewSettings)
            return true

        case .previous:
            guard currentIndex > 0 else { return false }
            goPrevious()
            return true

        case .next:
            guard currentIndex < queue.count - 1 else { return false }
            goNext()
            return true

        case .shuffle:
            guard !autoplayBlocks(.shuffle), session.canShuffle(pinned: answeredSlots) else { return false }
            shuffleQueue()
            return true

        case .showDetail:
            guard currentEntry != nil else { return false }
            handleDetailTap()
            return true

        case .toggleAutoplay:
            guard isAutoPlaying || canAutoplay else { return false }
            toggleAutoPlay()
            return true

        case .toggleAutoplayPause:
            guard isAutoPlaying else { return false }
            toggleAutoPlayPause()
            return true

        case .changeAutoplaySpeed:
            changeAutoplaySpeed(to: autoplaySpeed.next)
            return true

        case .toggleAutoplaySound:
            toggleAutoplaySound()
            return true

        case .close, .showHelp:
            return false
        }
    }

    func startAutoPlayLoop() {
        autoplay.startOrRestartLoop(
            isComplete: { [weak self] in self?.session.isComplete ?? true },
            shouldReveal: { [weak self] in self?.revealStage == .front },
            reveal: { [weak self] in self?.advanceReveal() },
            advance: { [weak self] in
                guard let self, !self.session.isComplete, self.session.canGoNext else { return false }
                withAnimation(AppMotion.reviewNavigationSpring) {
                    _ = self.session.advanceAfterSubmission()
                }
                self.syncCurrentEntryDerivedState()
                self.prewarmCardWindow()
                return true
            }
        )
    }

    // MARK: - Submit (Scoring only — persistence deferred to session end)

    /// Score the current card and advance. Persistence to SwiftData is DEFERRED to
    /// session end / dismiss (`flushPendingAnswers`): a per-flip store write merges
    /// into the main `ModelContext` and freezes the next-card render ~130ms. The
    /// per-flip cost here is only the UserDefaults snapshot, which is store-free and
    /// is the crash-recovery source of truth until the deferred flush confirms.
    func submit(
        _ feedback: ReviewFeedback,
        container: ModelContainer,
        reviewSettings: ReviewSettings
    ) {
        guard currentEntry != nil else { return }
        PerfLog.review.mark("submit.enter", "idx=\(currentIndex) fb=\(feedback == .remembered ? "R" : "F")")
        // Replace semantics (#2025): a different feedback on an already-scored card
        // (user went back) replaces the old answer; the same feedback is an
        // idempotent advance (also what lets a repeated tap on the last card finish).
        switch scoring.score(feedback, at: currentIndex) {
        case .unchanged:
            advancePastAlreadyScoredCard()
            return
        case .recorded:
            AppAnalytics.track(.reviewCardSubmitted(
                feedback: feedback == .remembered ? "remembered" : "forgot",
                cardIndex: currentIndex,
                totalCards: queue.count
            ))
        case .replaced(let previous):
            // Not a new submission: keep `reviewCardSubmitted` 1:1 with cards and
            // report the change as its own event so aggregates move, not inflate.
            AppAnalytics.track(.reviewAnswerCorrected(
                from: previous == .remembered ? "remembered" : "forgot",
                to: feedback == .remembered ? "remembered" : "forgot",
                cardIndex: currentIndex,
                totalCards: queue.count
            ))
        }

        let didComplete = session.advanceAfterSubmission()
        syncCurrentEntryDerivedState()
        PerfLog.review.mark("submit.advance", "idx=\(currentIndex - 1)->\(currentIndex)")
        // Persist AFTER advancing so the crash-recovery snapshot reflects the next
        // card. (Previously this ran pre-increment and only became correct via the
        // async flush callback's second persist — fragile; a crash in that window
        // restored to the already-answered card. Now correct synchronously, which
        // matters more since the DB flush itself is deferred to dismiss.)
        PerfLog.review.measure("submit.snapshot") { persistSnapshot() }
        // prewarm 移出 settle transaction：promoted 卡已被上一輪 lookahead
        // 覆蓋，此呼叫只延伸視窗；同步做會在 settle 幀內 mutate @Observable
        // cardCache → 再一次 body 失效。miss 由 cachedOrBuildCard fallback 兜底。
        Task { @MainActor [weak self] in
            guard let self else { return }
            PerfLog.review.measure("submit.prewarm") { self.prewarmCardWindow() }
        }

        finishSessionIfComplete(completed: didComplete)
    }

    /// Batched, deferred persistence — the SINGLE point where review results reach
    /// SwiftData. Called from the view's `onDisappear` (and on restore for answers
    /// whose previous flush never confirmed). Marks each confirmed answer flushed,
    /// then runs `onFinalize` so the caller finalizes the crash-recovery snapshot
    /// ONLY after the store actually holds the data.
    func flushPendingAnswers(
        container: ModelContainer,
        notebookSettingsSnapshot: NotebookSettingsSnapshot,
        onFinalize: @escaping @MainActor () -> Void = {},
        onFailure: (@MainActor @Sendable () -> Void)? = nil
    ) {
        persistence.flushPendingAnswers(
            submittedAnswers: scoring.submittedAnswers,
            container: container,
            notebookSettingsSnapshot: notebookSettingsSnapshot,
            onFinalize: onFinalize,
            onFailure: onFailure,
            onFlushed: { [weak self] indices in
                if let self {
                    for i in indices { self.scoring.markFlushed(at: i) }
                }
            }
        )
    }

    /// Compatibility overload for legacy callers and single-notebook tests.
    /// The production review route captures a mixed-notebook snapshot.
    func flushPendingAnswers(
        container: ModelContainer,
        reviewSettings: ReviewSettings,
        onFinalize: @escaping @MainActor () -> Void = {},
        onFailure: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let snapshot = NotebookSettingsResolver(
            globalReviewSettings: reviewSettings,
            globalCardLayout: .default
        ).snapshot(for: [])
        flushPendingAnswers(
            container: container,
            notebookSettingsSnapshot: snapshot,
            onFinalize: onFinalize,
            onFailure: onFailure
        )
    }

    /// Session-completion teardown. Runs once `currentIndex` has advanced past
    /// the last card (`currentIndex >= queue.count`), at which point
    /// `currentEntry` is nil and the presenter shows `completionState`. Idempotent
    /// on the index check, but the side effects (clear / analytics) are NOT — only
    /// call this on the *transition* into completion (i.e. right after the index
    /// that advanced past the end). All paths that can reach the end-of-queue
    /// (normal final submit + repeated submit on the already-scored last card)
    /// funnel through here so the completion contract stays single-sourced.
    private func finishSessionIfComplete(completed: Bool? = nil) {
        guard completed ?? session.isComplete else { return }
        // Always clear: going back and shuffling re-saves the order, so every
        // transition into completion must drop it again.
        ReviewSessionStore.clear(userID: currentUserID)
        // Re-completing after back + replace must not re-report the session
        // (the correction already travelled as `reviewAnswerCorrected`).
        guard !sessionEndReported else { return }
        sessionEndReported = true
        // NOTE: the crash-recovery snapshot is deliberately NOT cleared here. With
        // persistence deferred to dismiss, the snapshot is the only record of the
        // session's answers until `flushPendingAnswers` confirms the store write —
        // clearing it now would lose data on a crash between completion and dismiss.
        // The view's onDisappear clears it only after the deferred flush succeeds.
        let durationMs = Int(Date().timeIntervalSince(sessionStartTime) * 1000)
        AppAnalytics.track(.reviewSessionEnded(
            remembered: rememberedCount,
            forgot: forgotCount,
            completed: true,
            durationMs: durationMs
        ))
    }

    /// Re-run the DB flush for any restored answer whose previous flush never
    /// confirmed success (`flushed == false`). Fixes the consistency bug where a
    /// failed background flush left the card's spaced-repetition schedule stale
    /// while the snapshot still marked it answered — restore alone never
    /// re-flushed, so the schedule stayed broken forever.
    ///
    /// Idempotent: `flushPendingAnswers` skips records that already exist and only
    /// touches answers still marked `flushed == false`, so a second call is a no-op.
    /// Safe to call on every appear.
    func reflushUnflushedRestoredAnswers(
        container: ModelContainer,
        notebookSettingsSnapshot: NotebookSettingsSnapshot,
        onSaveFailure: (@MainActor @Sendable () -> Void)? = nil
    ) {
        flushPendingAnswers(
            container: container,
            notebookSettingsSnapshot: notebookSettingsSnapshot,
            onFinalize: { [weak self] in self?.persistSnapshot() },
            onFailure: onSaveFailure
        )
    }

    func reflushUnflushedRestoredAnswers(
        container: ModelContainer,
        reviewSettings: ReviewSettings,
        onSaveFailure: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let snapshot = NotebookSettingsResolver(
            globalReviewSettings: reviewSettings,
            globalCardLayout: .default
        ).snapshot(for: [])
        reflushUnflushedRestoredAnswers(
            container: container,
            notebookSettingsSnapshot: snapshot,
            onSaveFailure: onSaveFailure
        )
    }

    func persistSnapshot() {
        persistence.persistSnapshot(
            sessionStartTime: sessionStartTime,
            currentIndex: currentIndex,
            queueCount: queue.count,
            submittedAnswers: scoring.submittedAnswers
        )
    }

    func clearSnapshot() {
        persistence.clearSnapshot()
    }

    /// True while some answer is not confirmed in the store (skipped by a deferred
    /// flush, or never flushed). Such an answer exists only in the snapshot.
    var hasUnflushedAnswers: Bool {
        scoring.submittedAnswers.values.contains { !$0.flushed }
    }

    /// Crash-recovery finalize after a deferred flush (#3123). The snapshot is dropped
    /// only when the session is complete AND every answer is confirmed in the store.
    /// Otherwise it is rewritten, so restore re-flushes whatever was skipped.
    func finalizeSnapshotAfterFlush(completed: Bool) {
        if completed && !hasUnflushedAnswers {
            clearSnapshot()
        } else {
            persistSnapshot()
        }
    }

    // MARK: - Cache Builders

    private func prewarmCardWindow() {
        cardCache.prewarm(
            queue: queue,
            currentIndex: currentIndex,
            lookaheadLimit: Self.cacheLookaheadLimit,
            peers: linkedEntryLookup
        )
    }

    private static func buildLinkedEntryLookup(
        from entries: [VocabularyEntry]
    ) -> [String: VocabularyEntry] {
        entries.reduce(into: [String: VocabularyEntry]()) { lookup, entry in
            guard let cardID = entry.kgCardId else { return }
            lookup[cardID] = entry
        }
    }

    private func syncQueueMetadata() {
        persistence.syncQueueMetadata(for: queue)
    }

    private func advancePastAlreadyScoredCard() {
        // Always advance, including past the last card: when the user
        // re-submits on an already-scored final card we must push currentIndex
        // to queue.count so currentEntry becomes nil and the session reaches its
        // completion state. Previously this guarded `< queue.count - 1`, which
        // pinned the last card forever and the completion teardown never ran.
        let didComplete = session.advanceAfterSubmission()
        syncCurrentEntryDerivedState()
        prewarmCardWindow()
        persistSnapshot()
        finishSessionIfComplete(completed: didComplete)
    }

    private func syncCurrentEntryDerivedState() {
        collocationState.sync(from: currentEntry)
        // Every card change (next / previous / shuffle / submit / autoplay) funnels
        // here: leaving the card forgets its temporary detail, and coming back to
        // it later starts compact again. Idle resets write nothing.
        var detail = temporaryDetail
        if detail.reset() { temporaryDetail = detail }
    }
}
