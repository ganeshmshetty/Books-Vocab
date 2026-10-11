//
//  BackgroundSyncActor.swift
//  Books & Vocab
//
//  Created for safe off-main-thread SwiftData operations during sync.
//

import Foundation
import SwiftData

#if DEBUG
enum SettingsResetFailureInjectionError: LocalizedError {
    case noResetVisibleCard

    var errorDescription: String? {
        switch self {
        case .noResetVisibleCard:
            return L10n.string("重設 failure injector 找不到可清理的本機單字")
        }
    }
}
#endif

@ModelActor
actor BackgroundSyncActor {

    private static func parseISO8601(_ string: String) -> Date? {
        AppDateFormatters.parseISO8601(string)
    }

    /// Outcome of a `pullCardsToLocal` merge.
    ///
    /// `orphanCleanupBlocked` is `true` only when a FULL sync's orphan cleanup
    /// was skipped by the mass-deletion safety valve — meaning the local store
    /// still holds ghost entries the server no longer has. The caller must NOT
    /// advance the incremental boundary in that case, so the next sync runs a
    /// full sync again and retries the cleanup. It is always `false` for
    /// incremental syncs and for full syncs whose cleanup ran normally.
    ///
    /// The three counters describe what the merge actually changed in the local
    /// store. They exist so the UI can tell "your vocabulary changed" apart from
    /// "the sync ran and found nothing new" — a distinction the old `Bool` return
    /// could not express, which is why every visit to a notebook announced
    /// "單字庫已更新" even when the merge was a no-op.
    struct PullResult: Sendable {
        var orphanCleanupBlocked: Bool
        /// Cards present on the server but not locally → newly inserted entries.
        var inserted: Int = 0
        /// Existing entries whose **user-visible content** actually differed from
        /// the server payload. Review state is deliberately excluded — see
        /// `contentDiffers(card:from:)`.
        var updated: Int = 0
        /// Entries removed by a remote soft-delete or by full-sync orphan cleanup.
        var deleted: Int = 0

        /// Did this merge change anything a user could notice in their vocabulary?
        var changedEntryCount: Int { inserted + updated + deleted }
        var hasChanges: Bool { changedEntryCount > 0 }
    }

    /// Does `card` carry content that differs from what `entry` already holds?
    ///
    /// Pure + static so the "did anything really change" decision is unit-testable
    /// without a ModelContainer, and so the merge loop and the tests can never
    /// drift apart on what "changed" means.
    ///
    /// **Review state is excluded on purpose.** `lastReviewedAt` / `reviewCount` /
    /// `nextReviewAt` round-trip through the server on every review: this device
    /// pushes them, the next incremental pull hands them straight back, and the
    /// card's `updated_at` moves. Counting those as a change would make the
    /// "vocabulary updated" signal fire after every single review session — the
    /// exact false positive this comparison exists to prevent. What is compared is
    /// the card's *content*: the things a user reads on the row and in the detail
    /// sheet.
    static func contentDiffers(card: KGCard, from entry: VocabularyEntry) -> Bool {
        // The merge ends with `markSynced()`, which sets `syncState = .synced`.
        // For an entry that was still `pending`/`failed`, that flip is the most
        // user-visible change of all: `shouldAppearInKnowledgeList` requires
        // `isSynced`, so the row *appears in the list* — even when every content
        // field already matched. Comparing content alone would report「已是最新」
        // while new rows materialised on screen.
        if !entry.isSynced { return true }
        if entry.word != card.content { return true }
        if entry.translation != card.meaning { return true }
        if entry.partOfSpeech != card.pos { return true }
        if entry.explanation != card.note { return true }
        if entry.difficultyTier != card.difficultyTier { return true }
        if entry.inflections != (card.inflections ?? []) { return true }
        if entry.collocations != (card.collocations ?? []) { return true }
        if entry.reviewExamples != card.examples { return true }
        if entry.reviewMode != (VocabularyCardMode(rawValue: card.mode) ?? .recognition) { return true }
        if entry.graphLinksByKind != (card.linksByKind ?? [:]) { return true }
        if entry.isArchived != (card.isArchived ?? false) { return true }
        if entry.isReaderHidden != (card.isReaderHidden ?? false) { return true }
        if entry.isReviewExcluded != (card.isReviewExcluded ?? false) { return true }
        if let cardNotebookId = card.notebookId, entry.notebookId != cardNotebookId { return true }
        // `source` only ever *backfills* a book title (applySource refuses to
        // clobber a known title with an empty server one), so compare it the same
        // way: a difference counts only when the server actually supplies one.
        if let source = card.source, source.type == "book",
           let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            if entry.bookTitle != title { return true }
            let chapter = source.chapter?.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.chapterTitle != ((chapter?.isEmpty == false) ? chapter : nil) { return true }
        }
        return false
    }

    /// Fetch all cards from KG API and merge them into local SwiftData VocabularyEntry items
    /// This makes all KG words available offline (for underlining and browsing).
    @discardableResult
    func pullCardsToLocal(
        fetchedCards: [KGCard],
        isIncremental: Bool,
        progress: @Sendable @escaping (String, Int, Int) -> Void,
        notebookId: String = "default"
    ) throws -> PullResult {
        // Fetch all current local entries
        let descriptor = FetchDescriptor<VocabularyEntry>()
        let localEntries = try modelContext.fetch(descriptor)

        // Create a fast lookup dictionary keyed by (word, notebookId) to
        // correctly handle same word in different notebooks.
        var localDict = [String: VocabularyEntry]()
        var localByCardID = [String: VocabularyEntry]()
        for entry in localEntries {
            let key = mergeKey(entry.word, notebookId: entry.notebookId)
            localDict[key] = entry
            if let cardID = entry.kgCardId, !cardID.isEmpty {
                localByCardID[cardID] = entry
            }
        }

        // Keep track of LIVE fetched card keys to detect orphans later. Tombstones
        // are excluded: a tombstone sharing a word key must not shield an unmatched
        // local ghost from full-sync orphan cleanup.
        var fetchedCardKeys = Set<String>()
        // Rows already deleted by a tombstone in this merge; orphan cleanup must
        // not delete (and count) them a second time.
        var deletedEntries = Set<ObjectIdentifier>()

        // What this merge actually changed — drives the "vocabulary updated" signal.
        var insertedCount = 0
        var updatedCount = 0
        var deletedCount = 0

        // 1. Merge into local DB
        let totalCards = fetchedCards.count
        for (index, card) in fetchedCards.enumerated() {
            if index % 50 == 0 {
                progress(L10n.string("同步最新卡片..."), index, totalCards)
            }
            let cardNotebookId = card.notebookId ?? notebookId
            let mergeKey = mergeKey(card.content, notebookId: cardNotebookId)
            if card.isDeleted != true {
                fetchedCardKeys.insert(mergeKey)
            }

            // A tombstone resolves by card id only: a word-text match could name a
            // different live card that merely shares the word and delete it (#2547).
            let matchedEntry = card.isDeleted == true
                ? localByCardID[card.id]
                : (localByCardID[card.id] ?? localDict[mergeKey])

            if let existingEntry = matchedEntry {
                // Delete if marked as soft-deleted
                if card.isDeleted == true {
                    // Read identity fields before delete: a deleted @Model must not be touched.
                    let deletedWord = existingEntry.word
                    let deletedNotebookId = existingEntry.notebookId
                    AppLog.sync.info("Remote soft-delete received: \(deletedWord)")
                    modelContext.delete(existingEntry)
                    deletedEntries.insert(ObjectIdentifier(existingEntry))
                    // Evict the deleted row so later cards in this batch cannot resolve to it.
                    localByCardID[card.id] = nil
                    let deletedKey = self.mergeKey(deletedWord, notebookId: deletedNotebookId)
                    if localDict[deletedKey] === existingEntry {
                        localDict[deletedKey] = nil
                    }
                    deletedCount += 1
                    continue
                }

                if existingEntry.syncAction == .delete ||
                    (existingEntry.syncAction == .edit && !existingEntry.isSynced) {
                    // Preserve local delete or retryable edit state; do not overwrite fields.
                } else {
                    // Snapshot the verdict *before* the assignments below overwrite the
                    // fields it compares. SwiftData marks a property dirty on assignment
                    // regardless of whether the value differs, so `hasChanges` cannot
                    // answer this question after the fact.
                    if Self.contentDiffers(card: card, from: existingEntry) {
                        updatedCount += 1
                    }

                    // Update existing record
                    existingEntry.word = card.content
                    existingEntry.translation = card.meaning
                    existingEntry.partOfSpeech = card.pos
                    existingEntry.explanation = card.note
                    existingEntry.difficultyTier = card.difficultyTier
                    // Re-key the card-id index with the entry: a tombstone for the previous
                    // id later in this batch must not resolve to a row that now holds another card (#2547).
                    if let previousCardID = existingEntry.kgCardId, !previousCardID.isEmpty,
                       localByCardID[previousCardID] === existingEntry {
                        localByCardID[previousCardID] = nil
                    }
                    existingEntry.kgCardId = card.id
                    localByCardID[card.id] = existingEntry
                    existingEntry.inflections = card.inflections ?? []
                    existingEntry.collocations = card.collocations ?? []
                    existingEntry.reviewMode = VocabularyCardMode(rawValue: card.mode) ?? .recognition
                    existingEntry.reviewExamples = card.examples
                    existingEntry.graphLinksByKind = card.linksByKind ?? [:]
                    existingEntry.isArchived = card.isArchived ?? false
                    existingEntry.isReaderHidden = card.isReaderHidden ?? false
                    existingEntry.isReviewExcluded = card.isReviewExcluded ?? false
                    if let cardNotebookId = card.notebookId {
                        existingEntry.notebookId = cardNotebookId
                    }
                    Self.applySource(from: card, into: existingEntry)
                    existingEntry.markSynced()

                    // Merge review state from server (server newer wins)
                    Self.mergeReviewState(from: card, into: existingEntry)
                }
            } else {
                // If it's softly deleted but we don't have it locally, ignore it
                if card.isDeleted == true { continue }

                // Create new record. Book title/chapter come from the
                // server `source` metadata (PR #533); fall back to a
                // placeholder only when `source` is absent or empty.
                let (bookTitle, chapterTitle) = Self.resolveSource(from: card)
                let newEntry = VocabularyEntry(
                    word: card.content,
                    translation: card.meaning,
                    context: card.examples.first ?? "",
                    explanation: card.note,
                    partOfSpeech: card.pos,
                    bookTitle: bookTitle,
                    chapterTitle: chapterTitle
                )
                newEntry.difficultyTier = card.difficultyTier
                newEntry.kgCardId = card.id
                newEntry.inflections = card.inflections ?? []
                newEntry.collocations = card.collocations ?? []
                newEntry.reviewMode = VocabularyCardMode(rawValue: card.mode) ?? .recognition
                newEntry.reviewExamples = card.examples
                newEntry.graphLinksByKind = card.linksByKind ?? [:]
                newEntry.isArchived = card.isArchived ?? false
                newEntry.isReaderHidden = card.isReaderHidden ?? false
                newEntry.isReviewExcluded = card.isReviewExcluded ?? false
                newEntry.notebookId = card.notebookId ?? notebookId
                newEntry.markSynced()

                // Apply server review state to new entry
                Self.mergeReviewState(from: card, into: newEntry)

                modelContext.insert(newEntry)
                localDict[mergeKey] = newEntry
                localByCardID[card.id] = newEntry
                insertedCount += 1
            }
        }

        // 2. Cleanup orphans (Only for FULL sync)
        // Any local entry that has `syncStatus == 1` but is MISSING from the remote fetched list
        // means it was deleted remotely before soft-deletes were implemented.
        var orphanCleanupBlocked = false
        if !isIncremental {
            let localSyncedCount = localEntries.filter {
                $0.shouldAppearInKnowledgeList
            }.count
            let serverReturnedCount = fetchedCards.count

            // Safety guard: tiered protection against accidental mass deletion
            let ratio = Double(serverReturnedCount) / Double(max(localSyncedCount, 1))
            let diff = localSyncedCount - serverReturnedCount

            if ratio < 0.3 {
                orphanCleanupBlocked = true
                AppLog.sync.warning("Orphan cleanup BLOCKED: server returned <30% (\(serverReturnedCount)/\(localSyncedCount))")
            } else if diff > 50 && ratio < 0.8 {
                orphanCleanupBlocked = true
                AppLog.sync.warning("Orphan cleanup BLOCKED: large diff (\(diff) entries, ratio=\(String(format: "%.1f%%", ratio * 100)))")
            } else {
                progress(L10n.string("清理無效卡片..."), totalCards, totalCards)
                var orphanedWords: [String] = []
                for entry in localEntries {
                    guard !deletedEntries.contains(ObjectIdentifier(entry)) else { continue }
                    guard entry.shouldAppearInKnowledgeList else { continue }
                    let orphanKey = mergeKey(entry.word, notebookId: entry.notebookId)
                    guard !fetchedCardKeys.contains(orphanKey) else { continue }
                    orphanedWords.append(entry.word)
                    modelContext.delete(entry)
                }
                deletedCount += orphanedWords.count
                if !orphanedWords.isEmpty {
                    AppLog.sync.warning("Orphan cleanup removed \(orphanedWords.count) entries: \(orphanedWords.prefix(20).joined(separator: ", "))\(orphanedWords.count > 20 ? "..." : "")")
                }
            }
        }

        try modelContext.save()
        AppLog.sync.info("pullCardsToLocal completed. Merged \(fetchedCards.count) remote cards (inserted=\(insertedCount) updated=\(updatedCount) deleted=\(deletedCount)).")
        return PullResult(
            orphanCleanupBlocked: orphanCleanupBlocked,
            inserted: insertedCount,
            updated: updatedCount,
            deleted: deletedCount
        )
    }

    /// Deletes the app-account-scoped local SwiftData state — vocabulary, review
    /// records, notebooks, podcast (series / episode / progress). This is the
    /// single local-cleanup entry point for logout and account switch, so it must
    /// cover every app-account-scoped @Model: leaving any behind leaks account A's
    /// data into account B's session (followed podcast series + playback progress
    /// survived the switch before this covered them).
    ///
    /// `Book` is DELIBERATELY EXEMPT. The library lives in the CloudKit-backed
    /// CloudStore and its files sit in the per-Apple-ID iCloud/Documents
    /// container, so it is scoped to the Apple ID, not the app account. Deleting
    /// Book rows here removed them locally (and risked propagating the delete to
    /// CloudKit across devices) while the disk files persisted and the cold-start
    /// reconciler rebuilt the rows on next launch anyway — fake isolation that
    /// only left the user staring at an empty bookshelf after re-login. The
    /// library binds to the Apple ID and is left intact across logout / switch
    /// (user decision 2026-06-10).
    ///
    /// Scope: SwiftData @Model rows only. On-disk book files (Documents/Books,
    /// iCloud Documents/Books) are likewise NOT removed.
    ///
    /// Podcast deletion notes:
    /// - `PodcastSeries.episodes` is a `.cascade` relationship, so deleting a
    ///   series removes its owned episodes. We still fetch+delete ALL
    ///   `PodcastEpisode` explicitly to also clear series-less orphan episodes
    ///   (cascade does not reach them). Cascade-owned episodes are already gone
    ///   by then, so the all-episodes fetch only returns orphans — no double
    ///   delete.
    /// - `PodcastProgress` is an independent @Model (no relationship) and must
    ///   be deleted on its own.
    func clearUserData(reason: String) throws {
        AppLog.sync.info("Clearing app-account-scoped local data (vocab + review + notebook + podcast; Book is Apple-ID-scoped and preserved)... reason=\(reason)")
        let entries = try modelContext.fetch(FetchDescriptor<VocabularyEntry>())
        for entry in entries {
            modelContext.delete(entry)
        }
        let reviews = try modelContext.fetch(FetchDescriptor<ReviewRecord>())
        for record in reviews {
            modelContext.delete(record)
        }
        let notebooks = try modelContext.fetch(FetchDescriptor<Notebook>())
        for notebook in notebooks {
            modelContext.delete(notebook)
        }
        // Delete series first; cascade removes their owned episodes.
        let series = try modelContext.fetch(FetchDescriptor<PodcastSeries>())
        for s in series {
            modelContext.delete(s)
        }
        // Remaining episodes are series-less orphans the cascade can't reach.
        let episodes = try modelContext.fetch(FetchDescriptor<PodcastEpisode>())
        for episode in episodes {
            modelContext.delete(episode)
        }
        let progress = try modelContext.fetch(FetchDescriptor<PodcastProgress>())
        for p in progress {
            modelContext.delete(p)
        }
        // `Book` is intentionally NOT deleted — see the doc comment: the library
        // is Apple-ID-scoped (CloudStore/CloudKit + per-Apple-ID files), so it
        // survives logout / account-switch.
        try modelContext.save()
        AppLog.sync.info("Local data cleared. Deleted \(entries.count) vocab + \(reviews.count) review + \(notebooks.count) notebooks + \(series.count) podcast series + \(episodes.count) orphan episodes + \(progress.count) podcast progress (Book preserved: Apple-ID-scoped). reason=\(reason)")
    }

#if DEBUG
    /// Remove one reset-visible card and commit it before the UI-test failure is
    /// raised. This proves the Settings UI observes a real residual store and
    /// that retry runs against that residual rather than a pre-cleanup throw.
    func clearFirstUserDataForInjectedFailure() throws {
        let descriptor = FetchDescriptor<VocabularyEntry>(predicate: #Predicate {
            $0.syncStatus == 1 &&
            $0.actionType != "delete" &&
            $0.isArchived == false
        })
        guard let entry = try modelContext.fetch(descriptor).first else {
            AppLog.sync.warning("Settings reset failure injection found no reset-visible vocabulary entry")
            throw SettingsResetFailureInjectionError.noResetVisibleCard
        }
        modelContext.delete(entry)
        try modelContext.save()
        AppLog.sync.warning("Settings reset failure injection committed one-card partial cleanup")
    }
#endif

    /// Returns the number of synced entries in the local store.
    func syncedEntryCount() throws -> Int {
        let descriptor = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate<VocabularyEntry> { $0.syncStatus == 1 }
        )
        return try modelContext.fetchCount(descriptor)
    }

    /// Counts vocabulary rows the server has not confirmed: pending (0) or
    /// failed (2). `clearUserData` deletes every row, so these are what a logout
    /// would discard. Static and synchronous so the MainActor logout gate can
    /// read it on the caller's context without an actor hop.
    static func unsyncedEntryCount(in context: ModelContext) throws -> Int {
        try context.fetchCount(
            FetchDescriptor<VocabularyEntry>(predicate: #Predicate { $0.syncStatus != 1 })
        )
    }

    /// Deletes only server-synced entries (syncStatus == 1).
    /// Used on startup when not logged in to remove stale KG data
    /// while preserving locally-created pending words (syncStatus == 0).
    func clearSyncedData() throws {
        let descriptor = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate<VocabularyEntry> { $0.syncStatus == 1 }
        )
        let entries = try modelContext.fetch(descriptor)
        guard !entries.isEmpty else { return }
        entries.forEach { modelContext.delete($0) }
        try modelContext.save()
        AppLog.sync.info("Cleared \(entries.count) stale synced entries on startup.")
    }

    /// Build the payload for pushing review states to the backend — only the
    /// cards whose SRS state the backend does not already have.
    ///
    /// `needsReviewStatePush` is evaluated in Swift rather than in the fetch
    /// predicate because it compares two of the entry's own optional dates,
    /// which `#Predicate` does not express. The fetch is local and bounded by
    /// the library size; the payload and the round trip were the expensive part.
    func buildReviewStatePushPayload() throws -> [[String: Any]] {
        let descriptor = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate<VocabularyEntry> { $0.syncStatus == 1 }
        )
        let entries = try modelContext.fetch(descriptor).filter(\.needsReviewStatePush)

        var payload: [[String: Any]] = []
        for entry in entries {
            let lastReviewed = entry.lastReviewedAt ?? entry.dateAdded
            var item: [String: Any] = [
                "word": entry.word,
                "review_interval_hours": entry.reviewIntervalHours,
                "next_review_at": AppDateFormatters.iso8601.string(from: entry.nextReviewAt),
                "last_reviewed_at": AppDateFormatters.iso8601.string(from: lastReviewed),
                "review_count": entry.reviewCount,
                "lapse_count": entry.lapseCount,
                "review_streak": entry.reviewStreak,
                "last_review_feedback": entry.lastReviewFeedbackRaw,
            ]
            if let cardId = entry.kgCardId, !cardId.isEmpty {
                item["card_id"] = cardId
            }
            payload.append(item)
        }
        return payload
    }

    /// Record that the backend accepted the review states we sent.
    ///
    /// `boundary` is captured *before* the payload is built, so a review that
    /// lands while the request is in flight stays dirty and goes out next sync
    /// instead of being silently acknowledged as already-sent.
    func markReviewStatesPushed(upTo boundary: Date) throws {
        let descriptor = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate<VocabularyEntry> { $0.syncStatus == 1 }
        )
        var marked = 0
        for entry in try modelContext.fetch(descriptor) where entry.needsReviewStatePush {
            guard (entry.lastReviewedAt ?? entry.dateAdded) <= boundary else { continue }
            entry.reviewStateSyncedAt = boundary
            marked += 1
        }
        guard marked > 0 else { return }
        try modelContext.save()
        AppLog.sync.info("markReviewStatesPushed: acknowledged \(marked) card review states")
    }

    private static let dayFormatter = AppDateFormatters.dayKey

    // MARK: - Merge Key Helper

    private func mergeKey(_ word: String, notebookId: String) -> String {
        "\(word.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces).lowercased())|\(notebookId)"
    }

    // MARK: - Book Source Merge Helper

    /// Placeholder shown when a synced card carries no usable book source.
    static let fallbackBookTitle = "Knowledge Graph"

    /// Resolve the book title / chapter for a card from its server `source`
    /// metadata. iOS captures always originate from the reader so a card's
    /// `source.type` is `"book"`; non-book / missing / empty sources fall
    /// back to `fallbackBookTitle` with no chapter.
    ///
    /// This closes the sync-down gap from PR #533: the `source` field was
    /// decoded but never consumed, so synced cards permanently lost their
    /// book name and chapter.
    static func resolveSource(from card: KGCard) -> (bookTitle: String, chapterTitle: String?) {
        guard let source = card.source, source.type == "book" else {
            return (fallbackBookTitle, nil)
        }
        let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else {
            return (fallbackBookTitle, nil)
        }
        let chapter = source.chapter?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedChapter = (chapter?.isEmpty == false) ? chapter : nil
        return (title, resolvedChapter)
    }

    /// Backfill an existing entry's book title / chapter from server `source`.
    /// Only overwrites when the server actually supplies a usable book title —
    /// a missing/empty server source must not clobber a locally-known title.
    private static func applySource(from card: KGCard, into entry: VocabularyEntry) {
        guard let source = card.source, source.type == "book",
              let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        entry.bookTitle = title
        let chapter = source.chapter?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.chapterTitle = (chapter?.isEmpty == false) ? chapter : nil
    }


    // MARK: - Review State Merge Helper

    /// Observability counter for the equal-instant (serverLast == localLast)
    /// branch where server-wins silently overwrites equally-fresh local
    /// feedback. Pure telemetry — does NOT change the >= merge decision.
    /// Merge runs single-threaded on the sync path; `nonisolated(unsafe)` is
    /// safe (statics are not actor-isolated, observation only).
    nonisolated(unsafe) static var reviewMergeEqualInstantConflicts = 0

    private static func mergeReviewState(from card: KGCard, into entry: VocabularyEntry) {
        guard let serverLastStr = card.lastReviewedAt,
              let serverLast = parseISO8601(serverLastStr) else { return }

        let localLast = entry.lastReviewedAt ?? .distantPast
        if serverLast >= localLast {
            if localLast != .distantPast {
                if serverLast == localLast {
                    reviewMergeEqualInstantConflicts += 1
                    AppLog.sync.info("Review merge conflict (equal-instant): server overwrites equally-fresh local feedback for '\(entry.word)' at \(serverLastStr); total=\(reviewMergeEqualInstantConflicts)")
                }
                AppLog.sync.info("Review merge: server wins for '\(entry.word)' (server=\(serverLastStr), local=\(AppDateFormatters.iso8601.string(from: localLast)))")
            }
            entry.reviewIntervalHours = card.reviewIntervalHours ?? entry.reviewIntervalHours
            if let nextStr = card.nextReviewAt, let nextDate = parseISO8601(nextStr) {
                entry.nextReviewAt = nextDate
            }
            entry.lastReviewedAt = serverLast
            entry.reviewCount = max(entry.reviewCount, card.reviewCount ?? 0)
            entry.lapseCount = max(entry.lapseCount, card.lapseCount ?? 0)
            // Streak is state, not a counter: a newer server that forgot the card
            // (streak 0) must reset it. Only an absent field keeps the local value (#2485).
            entry.reviewStreak = card.reviewStreak ?? entry.reviewStreak
            entry.lastReviewFeedbackRaw = card.lastReviewFeedback ?? entry.lastReviewFeedbackRaw
            // Server won, so the server already has this state — queuing it for
            // push would send its own data back to it on the next sync.
            //
            // Acknowledge at `serverLast`, not `.now`: `needsReviewStatePush`
            // compares against `lastReviewedAt`, which was just set to
            // `serverLast`, so this settles the card regardless of how the
            // device clock compares to the server's. Using `.now` left any card
            // whose server timestamp ran ahead of the device clock permanently
            // dirty — re-pushed on every sync, which is the bug this whole
            // change exists to kill.
            entry.reviewStateSyncedAt = serverLast
        } else if localLast > serverLast {
            AppLog.sync.info("Review merge: local wins for '\(entry.word)' (local=\(AppDateFormatters.iso8601.string(from: localLast)), server=\(serverLastStr)), local review preserved")
        }
    }
}

extension BackgroundSyncActor {
    /// Build append-only review event payloads for the events the server has not
    /// acknowledged yet (`pushedAt == nil`), oldest first.
    ///
    /// The ordering makes a partially-drained history advance monotonically:
    /// batches are cut from this array, so a failed batch leaves a stable
    /// oldest-first remainder instead of re-shuffling on the next attempt.
    func buildReviewEventsPushPayload() throws -> [KGReviewEventPayload] {
        let descriptor = FetchDescriptor<ReviewRecord>(
            predicate: #Predicate<ReviewRecord> { $0.pushedAt == nil },
            sortBy: [SortDescriptor(\.reviewedAt, order: .forward)]
        )
        let records = try modelContext.fetch(descriptor)
        guard !records.isEmpty else { return [] }
        let entries = try modelContext.fetch(FetchDescriptor<VocabularyEntry>())
        // VocabularyEntry.id 非 unique(CloudKit 重複列可造成):重複 key 取第一個,不可 trap。
        let entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return records.compactMap { record in
            // 優先用複習當下固化在事件上的 kgCardId(自包含,不退化)。只有 legacy 紀錄
            // (固化前)才回退舊的 entryID→entry→kgCardId 三段反查 —— 卡若已離場仍會是
            // nil,但那是固化上線前的歷史殘留,新事件不再受此影響。
            let cardId: String?
            if let fixated = record.kgCardId, !fixated.isEmpty {
                cardId = fixated
            } else if let entryID = record.entryID,
                      let resolvedCardId = entriesByID[entryID]?.kgCardId,
                      !resolvedCardId.isEmpty {
                cardId = resolvedCardId
            } else {
                cardId = nil
            }
            return KGReviewEventPayload(
                event_id: record.id.uuidString,
                card_id: cardId,
                word_snapshot: record.word,
                notebook_id: record.notebookId,
                feedback: record.feedback,
                reviewed_at: AppDateFormatters.iso8601.string(from: record.reviewedAt),
                created_at: AppDateFormatters.iso8601.string(from: record.reviewedAt),
                interval_before: record.intervalBefore,
                interval_after: record.intervalAfter,
                next_review_before: record.nextReviewBefore.map { AppDateFormatters.iso8601.string(from: $0) },
                next_review_after: record.nextReviewAfter.map { AppDateFormatters.iso8601.string(from: $0) },
                review_count_after: record.reviewCountAfter,
                streak_after: record.streakAfter,
                lapse_after: record.lapseAfter
            )
        }
    }

    /// Record that the backend accepted these events, so later syncs stop
    /// re-sending them. Called per batch: a batch that fails must not
    /// acknowledge itself, and must not un-acknowledge earlier batches.
    func markReviewEventsPushed(eventIDs: [String], at instant: Date = .now) throws {
        guard !eventIDs.isEmpty else { return }
        let ids = eventIDs.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty else { return }

        // Fetch the batch's own rows, not every pending row: this runs once per
        // batch, so re-scanning the whole pending set each time would make the
        // one-time drain of a large legacy history quadratic — on the very sync
        // this change exists to speed up.
        let descriptor = FetchDescriptor<ReviewRecord>(
            predicate: #Predicate<ReviewRecord> { ids.contains($0.id) }
        )
        var marked = 0
        for record in try modelContext.fetch(descriptor) where record.pushedAt == nil {
            record.pushedAt = instant
            marked += 1
        }
        if marked > 0 {
            try modelContext.save()
        }
        // The watermark's two failure directions are both silent: mark nothing
        // and the client re-sends forever (no fix); mark everything and events
        // never reach the server (data loss). This count mismatch is the only
        // signal that the fetch above stopped matching what was actually sent,
        // so it must not pass quietly. A re-sent already-acked event is the one
        // benign case — the server dedupes it and it is already marked.
        if marked != ids.count {
            AppLog.sync.error(
                "markReviewEventsPushed: acknowledged \(marked) of \(ids.count) sent events — the rest were already marked, or the watermark query stopped matching"
            )
        } else {
            AppLog.sync.info("markReviewEventsPushed: acknowledged \(marked) review events")
        }
    }

    /// Merge remote append-only review events into local ReviewRecord rows.
    func mergeReviewEvents(_ remoteEvents: [KGReviewEventPayload]) throws {
        guard !remoteEvents.isEmpty else { return }

        let descriptor = FetchDescriptor<ReviewRecord>()
        let existing = try modelContext.fetch(descriptor)
        var existingIDs = Set(existing.map(\.id))
        let entries = try modelContext.fetch(FetchDescriptor<VocabularyEntry>())
        // 同一 kgCardId 可能對應多個本機 entry(重複列):依 (dateAdded, id.uuidString) 排序後
        // 取第一個,使掛載對象與 fetch 順序無關、確定性可重現,且不可 trap。
        let entryIDsByCardID = Dictionary(
            entries
                .sorted { lhs, rhs in
                    lhs.dateAdded != rhs.dateAdded
                        ? lhs.dateAdded < rhs.dateAdded
                        : lhs.id.uuidString < rhs.id.uuidString
                }
                .compactMap { entry -> (String, UUID)? in
                    guard let cardID = entry.kgCardId, !cardID.isEmpty else { return nil }
                    return (cardID, entry.id)
                },
            uniquingKeysWith: { first, _ in first }
        )
        var inserted = 0

        for event in remoteEvents {
            guard
                let eventID = UUID(uuidString: event.event_id),
                !existingIDs.contains(eventID),
                let reviewedAt = Self.parseISO8601(event.reviewed_at)
            else { continue }

            let record = ReviewRecord(
                word: event.word_snapshot,
                entryID: event.card_id.flatMap { entryIDsByCardID[$0] },
                feedback: event.feedback,
                reviewedAt: reviewedAt,
                // 固化遠端事件帶的 kgCardId + SRS 快照,本機即使查無對應 entry(卡未同步到)
                // 也保住 card 身分與學習曲線,下次上報不會因本機反查不到而退化。
                kgCardId: event.card_id.flatMap { $0.isEmpty ? nil : $0 },
                intervalBefore: event.interval_before,
                intervalAfter: event.interval_after,
                nextReviewBefore: event.next_review_before.flatMap { Self.parseISO8601($0) },
                nextReviewAfter: event.next_review_after.flatMap { Self.parseISO8601($0) },
                reviewCountAfter: event.review_count_after,
                streakAfter: event.streak_after,
                lapseAfter: event.lapse_after
            )
            record.id = eventID
            record.notebookId = event.notebook_id
            // It came from the server, so it is already on the server. Leaving it
            // unmarked would make the next push send the entire pulled history
            // straight back and the watermark would never drain.
            record.pushedAt = .now
            modelContext.insert(record)
            existingIDs.insert(eventID)
            inserted += 1
        }

        if inserted > 0 {
            try modelContext.save()
            AppLog.sync.info("mergeReviewEvents: inserted \(inserted) remote review events")
        }
    }
}
