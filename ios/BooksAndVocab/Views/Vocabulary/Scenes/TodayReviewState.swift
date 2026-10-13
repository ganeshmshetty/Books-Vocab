import SwiftUI
import SwiftData

/// 鍵盤評分請求（#3127）。每次請求 `sequence` 遞增，view 以 onChange 觸發一次甩出。
struct KeyboardGradeRequest: Equatable {
    let sequence: Int
    let remember: Bool
}

/// 甩出動畫中到達的評分暫存區（#3127、#3278）。有界 FIFO：甩出中後到的評分依到達順序排隊，
/// 每次 settle 只取出最前面一筆套用，因此每筆評分恰好套用一次，後到的評分不會覆蓋先到的。
/// 容量上限 `capacity` 遠大於一次甩出間可能累積的評分數（每次 settle 消耗一筆，甩出約數百毫秒），
/// 超出時丟棄最新一筆並保留已排隊的評分。純值，供單元測試。
struct FlingGradeBuffer: Equatable {
    static let capacity = 8

    private(set) var pendingRemembers: [Bool] = []

    mutating func receive(remember: Bool) {
        guard pendingRemembers.count < Self.capacity else { return }
        pendingRemembers.append(remember)
    }

    /// settle 時取出最早到達的一筆；佇列為空回傳 nil。
    mutating func takeAtSettle() -> Bool? {
        guard !pendingRemembers.isEmpty else { return nil }
        return pendingRemembers.removeFirst()
    }

    /// 自動播放中或已無卡片時整批丟棄，與原本 settle 的丟棄語意一致。
    mutating func discardAll() {
        pendingRemembers.removeAll()
    }
}

/// 寫入與本地鏡像的原子化提交（#3320）：save 失敗時 entry 與 state 都回到寫入前的快照。
@MainActor
enum TodayReviewCollocationCommit {
    @discardableResult
    static func commit(
        _ explanation: String?,
        for collocation: String,
        entry: VocabularyEntry?,
        state: inout TodayReviewCollocationState,
        save: () -> Bool
    ) -> Bool {
        let previousStored = entry?.collocationExplanations
        state.update(explanation, for: collocation, entry: entry)
        guard save() else {
            if let entry {
                entry.collocationExplanations = previousStored ?? [:]
                state.sync(from: entry)
            }
            return false
        }
        return true
    }
}

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

        /// 同一筆作答？replace 會保留 `reviewRecordID` 但換掉 feedback 與 `answeredAt`，
        /// 所以只比 record ID 不夠（#3409）。
        func isSameSubmission(as other: SubmittedAnswer) -> Bool {
            feedback == other.feedback
                && answeredAt == other.answeredAt
                && reviewRecordID == other.reviewRecordID
        }
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
    /// #3130：「+N」連結展開。與 temporary detail 同一生命週期，換卡即由 `syncCurrentEntryDerivedState` 清空。
    private var linkExpansion = ReviewCardLinkExpansion()
    var linkedCardStack: [VocabularyEntry] = []
    var tappedLink: KGCardLinkSummary?
    /// #3127：最近一次鍵盤評分請求（見 `requestKeyboardGrade`）。session 記憶體，不持久化。
    private(set) var keyboardGrade: KeyboardGradeRequest?
    private var keyboardGradeSequence = 0
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
    /// #2535: card ids that a queued card links to. `peerChipFingerprint` watches only these
    /// peers, so an unrelated card's archive does not re-derive the review chips.
    private var queuePeerCardIDs: Set<String> = []
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
        queuePeerCardIDs = Self.peerCardIDs(of: ordered)
        let _msLookup = PerfChannel.ms(since: _tLookup)
        if let restored {
            session = TodayReviewSessionState(
                queue: restored.queue,
                currentIndex: restored.currentIndex
            )
            persistence = TodayReviewSessionPersistenceController(
                queuePersistenceIDs: restored.persistenceIDs,
                queueBaselines: restored.baselines,
                queueEntryIDs: restored.queue.map(\.id),
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

    /// header 與 toolbar 的進度：已評數 / 總數（#3371、#3390）。瀏覽（‹ ›、autoplay）不改變它。
    var progressText: String {
        ReviewGradeProgress(graded: scoring.gradedCount, total: session.queue.count).text
    }

    /// 瀏覽位置（不顯示）：autoplay 換卡時重置旁白狀態的訊號（見 TodayReviewPresenter）。
    var positionText: String {
        session.positionText
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
            temporaryDetailCardKey: temporaryDetail.detailedCardKey,
            linkExpansion: linkExpansion,
            keyboardGrade: keyboardGrade,
            positionText: positionText
        )
    }

    private var currentCardState: TodayReviewPresenterState.CurrentCard? {
        cardContent(at: currentIndex)
    }

    var currentCardForTesting: TodayReviewPresenterState.CurrentCard? {
        currentCardState
    }

    private var nextCardState: TodayReviewPresenterState.CurrentCard? {
        cardContent(at: currentIndex + 1)
    }

    /// 常駐三 slot 投影（Phase 4）— 指派純推導自 (currentIndex, queue.count)，
    /// 內容走與 current/next 相同的 render-safe cache 路徑（非 mutating）。
    private var slotModels: [TodayReviewCardSlotModel] {
        TodayReviewCardSlotModel.make(currentIndex: currentIndex, queueCount: queue.count) { index in
            cardContent(at: index)
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

    /// 指定 queue index 的卡片內容，附上此位置的已評標示（#3371）。標示逐 index 讀評分 state，
    /// 不寫進 `cardCache`（cache 以 entry 為鍵，同一張卡在不同位置的評分各自不同）。
    private func cardContent(at index: Int) -> TodayReviewPresenterState.CurrentCard? {
        guard index >= 0, index < queue.count,
              var content = cachedOrBuildCard(for: queue[index]) else { return nil }
        content.gradedBadge = ReviewGradedBadge.resolve(scoring.gradedFeedback(at: index))
        return content
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
        trackPeers(of: entry)
        cardCache.rebuild(for: entry, peers: linkedEntryLookup)
    }

    /// A peer was archived, restored or queued for delete while the session is open
    /// (e.g. in the linked-card overlay). Chips are dropped at build time, so the link
    /// content of the prepared cards is re-derived from the peers' current state (#2535).
    /// Measurements are kept, so the card on screen does not jump (#2133).
    func refreshPeerDependentCards() {
        cardCache.refreshLinks(forPreparedEntries: queue, peers: linkedEntryLookup)
        prewarmCardWindow()
    }

    /// Archive and delete-queue state of the peers the queue links to (#2535). The view
    /// reads it in `body` and re-derives the chips when it changes, so a peer flip that
    /// lands after the overlay closed (a failed archive rolled back) still restores its chip.
    var peerChipFingerprint: Int {
        var hasher = Hasher()
        for cardID in queuePeerCardIDs.sorted() {
            guard let peer = linkedEntryLookup[cardID] else { continue }
            hasher.combine(cardID)
            hasher.combine(peer.isArchived)
            hasher.combine(peer.syncAction.rawValue)
        }
        return hasher.finalize()
    }

    private func trackPeers(of entry: VocabularyEntry) {
        queuePeerCardIDs.formUnion(Self.peerCardIDs(of: [entry]))
    }

    /// The card's link set changed (pending link created/failed/resolved, or AddLink
    /// succeeded): update its links in place and keep its measurements (see
    /// `TodayReviewCardCache.refreshLinks`). Use `rebuildCacheForEntry` only when the
    /// card content itself changed.
    func refreshLinksForEntry(_ entry: VocabularyEntry, pendingLinks: [KGCardLinkSummary]? = nil) {
        trackPeers(of: entry)
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
        withAnimation(AppMotionResolver.systemAnimation(.reveal)) {
            temporaryDetail.toggle(cardKey: key)
        }
        if temporaryDetail.isDetailed(cardKey: key) {
            pauseAutoPlayForModalInterruption()
        }
    }

    /// #3135：目前卡兩顆評分按鈕的下次間隔提示。baseline 取 session 快照（與 flush 寫入同源）。
    func gradeIntervalHints(settings: NotebookSettingsSnapshot) -> ReviewGradeIntervalHints? {
        guard let entry = currentEntry, session.currentIndex < persistence.queueBaselines.count else { return nil }
        return ReviewGradeIntervalHints(
            baseline: persistence.queueBaselines[session.currentIndex],
            settings: settings.reviewSettings(for: entry.notebookId)
        )
    }

    /// #3130：「+N」展開由 session 持有；動畫經 `AppMotionResolver`（Reduce Motion 下為 cross-fade）。
    func toggleLinkGroup(_ groupID: String) {
        guard let key = currentCardState?.card.reviewCardKey else { return }
        withAnimation(AppMotionResolver.systemAnimation(.reveal)) {
            linkExpansion.toggle(groupID, cardKey: key)
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
        withAnimation(AppMotionResolver.systemAnimation(.navigation)) {
            _ = session.shuffleRemaining(pinned: answeredSlots)
        }
        syncCurrentEntryDerivedState()
        syncQueueMetadata(keepingBaselinesAt: answeredSlots)
        prewarmCardWindow()
        ReviewSessionStore.saveOrder(queue, userID: currentUserID)
        persistSnapshot()
    }

    func goPrevious() {
        guard session.canGoPrevious else { return }
        withAnimation(AppMotionResolver.systemAnimation(.navigation)) {
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
        withAnimation(AppMotionResolver.systemAnimation(.navigation)) {
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

    /// 回傳 false 代表儲存失敗，entry 與本地鏡像已回滾到呼叫前（#3320）；呼叫端必須回報使用者。
    @discardableResult
    func updateCollocationExplanation(
        _ explanation: String?,
        for collocation: String,
        modelContext: ModelContext
    ) -> Bool {
        TodayReviewCollocationCommit.commit(
            explanation, for: collocation, entry: currentEntry, state: &collocationState,
            save: { modelContext.safeSave() }
        )
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

    /// 鍵盤評分（#3127）：只登記請求，不在此同步 submit。實際甩出與 settle 由 view 的
    /// `gradeFromControl` 完成，與按鈕、滑動走同一條路徑。守衛與 `performReviewIntent` 的 forgot／remembered 一致。
    func requestKeyboardGrade(remember: Bool) -> Bool {
        guard !autoplayBlocks(remember ? .remembered : .forgot), currentEntry != nil else { return false }
        keyboardGradeSequence += 1
        keyboardGrade = KeyboardGradeRequest(sequence: keyboardGradeSequence, remember: remember)
        return true
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
            withAnimation(AppMotionResolver.systemAnimation(.reveal)) {
                advanceReveal()
            }
            return true

        case .collapse:
            guard revealStage == .back, currentEntry != nil else { return false }
            withAnimation(AppMotionResolver.systemAnimation(.reveal)) {
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
                withAnimation(AppMotionResolver.systemAnimation(.navigation)) {
                    _ = self.session.advanceAfterSubmission()
                }
                self.syncCurrentEntryDerivedState()
                self.prewarmCardWindow()
                // #3410：與 goNext() 一致，autoplay 推進後也要寫回快照，否則 kill 後還原停在播放前的卡。
                self.persistSnapshot()
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
        // Snapshot what this flush writes: a confirmation may only mark that exact submission
        // flushed, not whatever the index holds once the flush returns (#3409).
        let sent = scoring.submittedAnswers
        persistence.flushPendingAnswers(
            submittedAnswers: sent,
            container: container,
            notebookSettingsSnapshot: notebookSettingsSnapshot,
            onFinalize: onFinalize,
            onFailure: onFailure,
            onFlushed: { [weak self] indices in
                if let self {
                    for i in indices {
                        guard let answer = sent[i] else { continue }
                        self.scoring.markFlushed(at: i, confirming: answer)
                    }
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
            onFinalize: { [weak self] in
                self?.finalizeSnapshotAfterFlush(completed: self?.session.isComplete ?? false)
            },
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

    // MARK: - #2042 Stage 3：切換辨識⇄產出與忘記程度

    /// 面板是否開啟（由 `TodayReviewView` 的 toastSheet 綁定）。狀態放在這裡，讓 Environment 動作只捕捉 state、不捕捉 view。
    var isReviewModeSheetPresented = false

    /// 目前卡的 session 基準（切換後重拍是否生效的觀測點）。
    var currentReviewBaseline: TodayReviewSessionSnapshotStore.ReviewBaseline? {
        guard session.currentIndex < persistence.queueBaselines.count else { return nil }
        return persistence.queueBaselines[session.currentIndex]
    }

    /// 切換後的方向（目前卡的反向）；沒有目前卡時退回 `.production`，面板不會顯示。
    var reviewModeSwitchTarget: VocabularyCardMode {
        (currentEntry?.reviewMode ?? .recognition).toggledReviewMode
    }

    /// 未評分的目前卡才能切換：已評分的卡其 session 基準在 flush 時以舊值重算，調整會被覆寫。
    var canSwitchReviewMode: Bool {
        currentEntry != nil && !answeredSlots.contains(session.currentIndex)
    }

    /// 開面板：暫停自動播放，關閉後不自動恢復（與 layout editor 同一契約）。
    func beginReviewModeSwitch() {
        pauseAutoPlayForModalInterruption()
        isReviewModeSheetPresented = true
    }

    /// 面板確認：目前卡改方向（pending mode）並依拉桿套用進度覆寫（pending override），
    /// 再重拍未評分卡的 session 基準，之後評分與持久化快照都以新值為準。
    @discardableResult
    func applyReviewModeSwitch(level: Double, initialIntervalHours: Double, now: Date) -> Bool {
        guard canSwitchReviewMode, let entry = currentEntry else { return false }
        entry.requestReviewMode(reviewModeSwitchTarget)
        let adjustment = ReviewProgressAdjustment.forgetting(
            level: level,
            currentIntervalHours: entry.reviewIntervalHours,
            initialIntervalHours: initialIntervalHours
        )
        entry.applyReviewProgressAdjustment(adjustment, now: now, initialIntervalHours: initialIntervalHours)
        syncQueueMetadata(keepingBaselinesAt: answeredSlots)
        rebuildCacheForEntry(entry)
        persistSnapshot()
        return true
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

    private static func peerCardIDs(of entries: [VocabularyEntry]) -> Set<String> {
        Set(entries.flatMap { $0.graphLinksByKind.values.joined() }.map(\.cardId))
    }

    private func syncQueueMetadata(keepingBaselinesAt answeredSlots: Set<Int>) {
        persistence.syncQueueMetadata(for: queue, keepingBaselinesAt: answeredSlots)
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
        var expansion = linkExpansion
        if expansion.reset() { linkExpansion = expansion }
    }
}
