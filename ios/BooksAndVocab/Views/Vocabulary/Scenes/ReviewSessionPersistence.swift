import SwiftData
import Foundation

/// 隔離所有 session 的資料庫操作與 UserDefaults 快照持久化。
/// 無 UI 依賴、無導航狀態依賴。
enum ReviewSessionPersistence {

    // MARK: - PersistenceID helpers

    static func persistenceID(for entry: VocabularyEntry) -> String {
        if let kgCardId = entry.kgCardId, !kgCardId.isEmpty {
            return "kg:\(kgCardId)"
        }
        return "local:\(entry.id.uuidString)"
    }

    /// 同一 persistenceID 只保留代表一筆（規則見 `representative(among:)`）。
    /// 回傳保持輸入的相對順序；勝者與輸入順序無關（輸入來自無排序的 fetch）。
    static func uniqueByPersistenceID(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        let winners = Dictionary(grouping: entries) { persistenceID(for: $0) }
            .compactMapValues { group in representative(among: group) }
        return entries.filter { winners[persistenceID(for: $0)] === $0 }
    }

    /// 同一 persistenceID 的代表列規則。全 app 只有這一處定義；佇列（`uniqueByPersistenceID`）、
    /// flush 寫入（`fetchEntry`）與還原快照都經此函式，不得各自選列。
    ///
    /// 候選 = 該 persistenceID 中 `shouldAppearInReview` 的列；候選為空才退回全部列。
    /// 在候選中 `dateAdded` 最早者勝，平手以 `id` 字典序。
    ///
    /// 不變式：佇列代表 == flush 寫入目標。佇列只餵入可複習列，flush 餵入同一 persistenceID 的全部列；
    /// 只要存在可複習列，兩邊的候選集合相同，min 結果必定相同。
    /// 因此「最早的一筆不可複習」時，佇列與 flush 都落在最早的可複習列上（見 TodayReviewSnapshotRestoreTests）。
    static func representative(among entries: [VocabularyEntry]) -> VocabularyEntry? {
        let reviewable = entries.filter { $0.shouldAppearInReview }
        return (reviewable.isEmpty ? entries : reviewable).min { lhs, rhs in
            if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func makeBaseline(
        from entry: VocabularyEntry
    ) -> TodayReviewSessionSnapshotStore.ReviewBaseline {
        .init(
            reviewIntervalHours: entry.reviewIntervalHours,
            nextReviewAt: entry.nextReviewAt,
            lastReviewedAt: entry.lastReviewedAt,
            reviewCount: entry.reviewCount,
            lapseCount: entry.lapseCount,
            reviewStreak: entry.reviewStreak,
            lastReviewFeedbackRaw: entry.lastReviewFeedbackRaw
        )
    }

    // MARK: - Snapshot (UserDefaults)

    static func persistSnapshot(
        userId: String,
        sessionStartTime: Date,
        currentIndex: Int,
        queueCount: Int,
        queuePersistenceIDs: [String],
        queueBaselines: [TodayReviewSessionSnapshotStore.ReviewBaseline],
        queueEntryIDs: [UUID] = [],
        submittedAnswers: [Int: TodayReviewState.SubmittedAnswer]
    ) {
        guard !queuePersistenceIDs.isEmpty else {
            TodayReviewSessionSnapshotStore.clear(for: userId)
            return
        }

        let submissions = submittedAnswers.mapValues { answer in
            TodayReviewSessionSnapshotStore.Snapshot.SubmittedAnswer(
                feedbackRaw: answer.feedback.rawValue,
                answeredAt: answer.answeredAt,
                reviewRecordID: answer.reviewRecordID,
                flushed: answer.flushed
            )
        }
        let queueItems = zip(queuePersistenceIDs, queueBaselines).enumerated().map { index, pair in
            TodayReviewSessionSnapshotStore.Snapshot.QueueItem(
                persistenceID: pair.0,
                baseline: pair.1,
                entryID: index < queueEntryIDs.count ? queueEntryIDs[index] : nil
            )
        }

        TodayReviewSessionSnapshotStore.save(.init(
            userId: userId,
            sessionStartTime: sessionStartTime,
            currentIndex: min(currentIndex, queueCount),
            queue: queueItems,
            submissions: submissions,
            updatedAt: Date()
        ))
    }

    static func clearSnapshot(for userId: String?) {
        TodayReviewSessionSnapshotStore.clear(for: userId)
    }

    // MARK: - Snapshot restore

    struct RestoredSession {
        let queue: [VocabularyEntry]
        let persistenceIDs: [String]
        let baselines: [TodayReviewSessionSnapshotStore.ReviewBaseline]
        let currentIndex: Int
        let submittedAnswers: [Int: TodayReviewState.SubmittedAnswer]
        let rememberedCount: Int
        let forgotCount: Int
        let sessionStartTime: Date
    }

    static func restoreSnapshotIfPossible(
        orderedEntries: [VocabularyEntry],
        userId: String?
    ) -> RestoredSession? {
        guard let userId,
              let snapshot = TodayReviewSessionSnapshotStore.load(for: userId) else {
            return nil
        }

        // sync 競態可能讓兩筆 VocabularyEntry 共用同一 kgCardId：每個 persistenceID 只保留代表列（同一規則），避免 trap 與重複入列。
        let uniqueEntries = uniqueByPersistenceID(orderedEntries)
        let entryMap = Dictionary(
            uniqueEntries.map { (persistenceID(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let entryByID = Dictionary(
            uniqueEntries.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // 逐一比對快照佇列。每列先以列 UUID 找回（sync 可能在快照寫入後把該列 re-key），
        // 無 UUID 或找不到才退回 persistenceID，與 fetchQueuedEntry 同一順序。
        // 缺席的卡、以及快照內解析到同一列的第二次起都視為遺失。
        // kept 保留 (舊 index, entry)；oldToNew 把舊 index 重映射到新佇列位置。
        var seenEntryIDs = Set<UUID>()
        var kept: [(oldIndex: Int, entry: VocabularyEntry)] = []
        var oldToNew: [Int: Int] = [:]
        for (oldIndex, item) in snapshot.queue.enumerated() {
            let resolved = item.entryID.flatMap { entryByID[$0] } ?? entryMap[item.persistenceID]
            guard let entry = resolved,
                  seenEntryIDs.insert(entry.id).inserted else { continue }
            oldToNew[oldIndex] = kept.count
            kept.append((oldIndex, entry))
        }

        // 只有在有卡遺失、且遺失的卡之外仍有「未 flush」答案時才 partial restore；
        // 否則維持舊行為：任何不一致即清除快照。
        if kept.count != snapshot.queue.count {
            let atRisk = snapshot.submissions.contains { oldToNew[$0.key] != nil && !$0.value.flushed }
            guard atRisk else {
                TodayReviewSessionSnapshotStore.clear(for: userId)
                return nil
            }
        }

        let droppedAnswers = snapshot.submissions.keys.filter { oldToNew[$0] == nil }
        if !droppedAnswers.isEmpty {
            let droppedUnflushed = droppedAnswers.filter { !(snapshot.submissions[$0]?.flushed ?? true) }.count
            if droppedUnflushed > 0 {
                AppLog.data.error("restoreSnapshot: dropped \(droppedAnswers.count) answers (\(droppedUnflushed) unflushed) for cards no longer reviewable")
            } else {
                AppLog.data.info("restoreSnapshot: dropped \(droppedAnswers.count) already-flushed answers for cards no longer reviewable")
            }
        }

        // 還原列採用其「目前」persistenceID：被 re-key 的列以新卡號重新進入佇列，之後的快照寫入才不會沿用舊 key。
        let restoredQueue = kept.map { $0.entry }
        let restoredEntryIDs = Set(restoredQueue.map(\.id))
        let appendedEntries = uniqueEntries.filter { !restoredEntryIDs.contains($0.id) }
        let queue = restoredQueue + appendedEntries
        let persistenceIDs = restoredQueue.map(persistenceID(for:)) + appendedEntries.map(persistenceID(for:))
        let baselines = kept.map { snapshot.queue[$0.oldIndex].baseline } + appendedEntries.map(makeBaseline(from:))

        var submittedAnswers: [Int: TodayReviewState.SubmittedAnswer] = [:]
        var rememberedCount = 0
        var forgotCount = 0
        for (oldIndex, answer) in snapshot.submissions {
            guard let newIndex = oldToNew[oldIndex],
                  let feedback = ReviewFeedback(rawValue: answer.feedbackRaw) else { continue }
            submittedAnswers[newIndex] = TodayReviewState.SubmittedAnswer(
                feedback: feedback,
                answeredAt: answer.answeredAt,
                reviewRecordID: answer.reviewRecordID,
                flushed: answer.flushed
            )
            if feedback == .remembered { rememberedCount += 1 } else { forgotCount += 1 }
        }

        // 目前 index 指向原本的卡：計算其前方仍存活的卡數。
        let currentIndex = min(kept.filter { $0.oldIndex < snapshot.currentIndex }.count, queue.count)

        return RestoredSession(
            queue: queue,
            persistenceIDs: persistenceIDs,
            baselines: baselines,
            currentIndex: currentIndex,
            submittedAnswers: submittedAnswers,
            rememberedCount: rememberedCount,
            forgotCount: forgotCount,
            sessionStartTime: snapshot.sessionStartTime
        )
    }

    // MARK: - DB flush (deferred to session end; batched into ONE save)

    /// Persist ALL un-flushed submitted answers in a SINGLE background context with
    /// ONE `safeSave()` → ONE main-context merge.
    ///
    /// The per-flip submit path deliberately does NOT write the store: a per-card
    /// save merges back into the main `ModelContext`, refetching `NotebookListView`'s
    /// `@Query<VocabularyEntry>` (~37ms) and re-rendering the review cover — a single
    /// ~130ms main-thread block that froze the next-card render (measured: the freeze
    /// aligned exactly with the background save's completion, not the in-memory
    /// throwaway). Deferring to dismiss removes every per-flip merge; crash safety is
    /// covered by the per-flip UserDefaults snapshot + restore reflush.
    ///
    /// Idempotent: skips answers whose `ReviewRecord` already exists. Reports the
    /// settled indices on success (flushed, or dropped because the queued row no longer
    /// exists) so the caller can mark them + finalize the snapshot
    /// ONLY after the store actually has the data. The empty-pending case still calls
    /// `onFlushed([])` so callers can finalize without special-casing a no-op.
    /// `queueEntryIDs` (same index space as `queuePersistenceIDs`) lets a re-keyed row still
    /// receive its grade; see `fetchQueuedEntry`.
    static func flushPendingAnswers(
        queuePersistenceIDs: [String],
        queueBaselines: [TodayReviewSessionSnapshotStore.ReviewBaseline],
        queueEntryIDs: [UUID] = [],
        submittedAnswers: [Int: TodayReviewState.SubmittedAnswer],
        container: ModelContainer,
        notebookSettingsSnapshot: NotebookSettingsSnapshot,
        onFlushed: (@MainActor @Sendable (_ indices: [Int]) -> Void)? = nil,
        onFailure: (@MainActor @Sendable () -> Void)? = nil,
        resolveEntry: @escaping @Sendable (UUID?, String, ModelContext) throws -> VocabularyEntry? = fetchQueuedEntry
    ) {
        let pending = submittedAnswers.filter { !$0.value.flushed }
        guard !pending.isEmpty else {
            if let onFlushed { Task { @MainActor in onFlushed([]) } }
            return
        }
        Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            var settled: [Int] = []
            for (index, answer) in pending {
                guard index < queuePersistenceIDs.count, index < queueBaselines.count else { continue }
                let entry: VocabularyEntry?
                do {
                    entry = try resolveEntry(
                        index < queueEntryIDs.count ? queueEntryIDs[index] : nil,
                        queuePersistenceIDs[index],
                        ctx
                    )
                } catch {
                    // DB error: this answer can't be read back, so keep it un-flushed; the
                    // snapshot + restore reflush gets another chance instead of dropping it.
                    AppLog.data.error("flushPendingAnswers: entry fetch failed for \(queuePersistenceIDs[index]), answer kept un-flushed: \(error)")
                    continue
                }
                guard let entry else {
                    // The entry is gone from the store (deleted): there is no row left to
                    // write, so the answer is dropped and settled rather than retried forever.
                    AppLog.data.info("flushPendingAnswers: entry no longer exists for \(queuePersistenceIDs[index]), dropping its answer")
                    settled.append(index)
                    continue
                }
                guard stageAnswer(
                    answer,
                    baseline: queueBaselines[index],
                    entry: entry,
                    notebookSettingsSnapshot: notebookSettingsSnapshot,
                    in: ctx
                ) else { continue }
                settled.append(index)
            }
            let saved = PerfLog.review.measure("flush.dbSaveBatch", "n=\(settled.count)") { ctx.safeSave() }.value
            if saved {
                let confirmed = settled
                if let onFlushed { await onFlushed(confirmed) }
            } else {
                AppLog.data.error("flushPendingAnswers: batch save failed for \(settled.count) answers")
                if let onFailure { await onFailure() }
            }
        }
    }

    /// Compatibility seam for callers that only have the user-global policy.
    /// Production review sessions use the snapshot overload above so a mixed
    /// notebook queue resolves each card independently.
    static func flushPendingAnswers(
        queuePersistenceIDs: [String],
        queueBaselines: [TodayReviewSessionSnapshotStore.ReviewBaseline],
        queueEntryIDs: [UUID] = [],
        submittedAnswers: [Int: TodayReviewState.SubmittedAnswer],
        container: ModelContainer,
        reviewSettings: ReviewSettings,
        onFlushed: (@MainActor @Sendable (_ indices: [Int]) -> Void)? = nil,
        onFailure: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let snapshot = NotebookSettingsResolver(
            globalReviewSettings: reviewSettings,
            globalCardLayout: .default
        ).snapshot(for: [])
        flushPendingAnswers(
            queuePersistenceIDs: queuePersistenceIDs,
            queueBaselines: queueBaselines,
            queueEntryIDs: queueEntryIDs,
            submittedAnswers: submittedAnswers,
            container: container,
            notebookSettingsSnapshot: snapshot,
            onFlushed: onFlushed,
            onFailure: onFailure
        )
    }

    /// Apply one answer's SRS mutation to `entry` and insert its `ReviewRecord`
    /// (idempotent on record existence) into `ctx`. Caller owns the single save.
    /// Returns `false` (nothing touched) when the record lookup itself fails.
    static func stageAnswer(
        _ answer: TodayReviewState.SubmittedAnswer,
        baseline: TodayReviewSessionSnapshotStore.ReviewBaseline,
        entry: VocabularyEntry,
        notebookSettingsSnapshot: NotebookSettingsSnapshot,
        in ctx: ModelContext,
        fetchRecord: (UUID, ModelContext) throws -> ReviewRecord? = fetchReviewRecord
    ) -> Bool {
        // A lookup ERROR is not "no record yet": falling through to the insert branch would add a
        // second ReviewRecord with the same id (no unique constraint) and double the event (#2796).
        // Bail before touching `entry` so the answer stays un-staged and the restore reflush retries.
        let existing: ReviewRecord?
        do {
            existing = try fetchRecord(answer.reviewRecordID, ctx)
        } catch {
            AppLog.data.error("stageAnswer: ReviewRecord fetch failed for \(answer.reviewRecordID), answer left un-staged: \(error)")
            return false
        }

        let reviewSettings = notebookSettingsSnapshot.reviewSettings(for: entry.notebookId)
        applySubmittedAnswer(answer, baseline: baseline, to: entry, reviewSettings: reviewSettings)

        if let existing {
            // Record already exists: either an idempotent re-flush (restore) or the
            // user went back and REPLACED the answer after it had been flushed (#2025).
            // `applySubmittedAnswer` above re-derived the entry from the baseline, so
            // bring the record in line in place (same id → still ONE review event).
            // `pushedAt` resets when the answer actually changed so an already-uploaded record is owed to the server
            // again; the server de-dups by event_id, so whether it adopts the new
            // value is server policy, not something the client can force.
            let changed = existing.feedback != answer.feedback.rawValue
            existing.feedback = answer.feedback.rawValue
            existing.reviewedAt = answer.answeredAt
            existing.dayKey = ReviewRecord.makeDayKey(from: answer.answeredAt)
            existing.intervalAfter = entry.reviewIntervalHours
            existing.nextReviewAfter = entry.nextReviewAt
            existing.reviewCountAfter = entry.reviewCount
            existing.streakAfter = entry.reviewStreak
            existing.lapseAfter = entry.lapseCount
            if changed { existing.pushedAt = nil }
        } else {
            // 固化 kgCardId + SRS 前後快照(此刻 entry 還在手上,值全可得):
            // baseline=複習前,applySubmittedAnswer 後 entry=複習後。事件自包含,
            // 上報不再靠卡離場即退化的三段反查,研究也能逐筆還原學習曲線。
            let record = ReviewRecord(
                word: entry.word,
                entryID: entry.id,
                feedback: answer.feedback.rawValue,
                reviewedAt: answer.answeredAt,
                kgCardId: entry.kgCardId.flatMap { $0.isEmpty ? nil : $0 },
                intervalBefore: baseline.reviewIntervalHours,
                intervalAfter: entry.reviewIntervalHours,
                nextReviewBefore: baseline.nextReviewAt,
                nextReviewAfter: entry.nextReviewAt,
                reviewCountAfter: entry.reviewCount,
                streakAfter: entry.reviewStreak,
                lapseAfter: entry.lapseCount
            )
            record.id = answer.reviewRecordID
            record.notebookId = entry.notebookId
            ctx.insert(record)
        }
        return true
    }

    // MARK: - Private DB helpers

    /// Resolves the row a queued answer grades. The queue's own row (`VocabularyEntry.id`) is
    /// tried first: `BackgroundSyncActor` can re-key a queued row's `kgCardId` mid-session, which
    /// makes the persistence id stale while the row still holds the answered card (#3123). The
    /// persistence-id lookup is the fallback when no row id is known (`entryID` nil, i.e. an index
    /// beyond `queueEntryIDs`) and for a row recreated under the same card id. Only when neither
    /// resolves is the entry deleted.
    static func fetchQueuedEntry(
        entryID: UUID?,
        persistenceID: String,
        in context: ModelContext
    ) throws -> VocabularyEntry? {
        if let entryID {
            var descriptor = FetchDescriptor<VocabularyEntry>(
                predicate: #Predicate<VocabularyEntry> { $0.id == entryID }
            )
            descriptor.fetchLimit = 1
            if let row = try context.fetch(descriptor).first { return row }
        }
        return try fetchEntry(for: persistenceID, in: context)
    }

    static func fetchEntry(
        for persistenceID: String,
        in context: ModelContext
    ) throws -> VocabularyEntry? {
        if persistenceID.hasPrefix("kg:") {
            // 不可 fetchLimit = 1：sync 競態可能有多筆同 kgCardId，必須取與佇列代表相同的那筆。
            // 取全部同 kgCardId 的列（含不可複習者）再交給 representative(among:)，由它決定，不在此自選。
            let kgCardID = String(persistenceID.dropFirst(3))
            let descriptor = FetchDescriptor<VocabularyEntry>(
                predicate: #Predicate<VocabularyEntry> { $0.kgCardId == kgCardID }
            )
            return representative(among: try context.fetch(descriptor))
        }

        guard persistenceID.hasPrefix("local:"),
              let rawID = persistenceID.split(separator: ":", maxSplits: 1).last,
              let entryID = UUID(uuidString: String(rawID)) else {
            return nil
        }

        var descriptor = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate<VocabularyEntry> { $0.id == entryID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func fetchReviewRecord(_ id: UUID, _ context: ModelContext) throws -> ReviewRecord? {
        var descriptor = FetchDescriptor<ReviewRecord>(
            predicate: #Predicate<ReviewRecord> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func applySubmittedAnswer(
        _ answer: TodayReviewState.SubmittedAnswer,
        baseline: TodayReviewSessionSnapshotStore.ReviewBaseline,
        to entry: VocabularyEntry,
        reviewSettings: ReviewSettings
    ) {
        // #3135：與評分按鈕的下次間隔提示共用同一函式，提示永遠等於寫入值。
        let updatedInterval = ReviewIntervalProjection.nextIntervalHours(
            baseline: baseline,
            feedback: answer.feedback,
            settings: reviewSettings
        )

        entry.reviewIntervalHours = updatedInterval
        entry.nextReviewAt = answer.answeredAt.addingTimeInterval(updatedInterval * 3600)
        entry.lastReviewedAt = answer.answeredAt
        entry.reviewCount = baseline.reviewCount + 1
        entry.lastReviewFeedbackRaw = answer.feedback.rawValue
        switch answer.feedback {
        case .remembered:
            entry.reviewStreak = baseline.reviewStreak + 1
            entry.lapseCount = baseline.lapseCount
        case .forgot:
            entry.reviewStreak = 0
            entry.lapseCount = baseline.lapseCount + 1
        }
    }
}
