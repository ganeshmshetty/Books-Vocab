//
//  BackgroundSyncActorTests.swift
//  Books & Vocab Tests
//
//  Regression coverage for the PR #533 sync-down gap: `KGCard.source`
//  was decoded but never consumed by `BackgroundSyncActor`, so cards
//  pulled from the backend permanently lost their book title / chapter
//  and displayed the hard-coded "Knowledge Graph" placeholder.
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
struct BackgroundSyncActorTests {

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            VocabularyEntry.self,
            ReviewRecord.self,
            Notebook.self,
            Book.self,
            PodcastSeries.self,
            PodcastEpisode.self,
            PodcastProgress.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Build a `KGCard` from JSON so the test exercises the same decoding
    /// path production uses (plain `JSONDecoder`, camelCase keys, no
    /// snake-case strategy). `sourceJSON` is spliced in verbatim or omitted.
    private func makeCard(
        id: String = "c1",
        content: String,
        sourceJSON: String?,
        meaning: String? = nil,
        lastReviewedAt: String? = nil,
        readerHidden: Bool? = nil,
        reviewExcluded: Bool? = nil,
        isDeleted: Bool = false,
        reviewStreak: Int? = nil,
        reviewCount: Int? = nil
    ) throws -> KGCard {
        let sourceFragment = sourceJSON.map { ",\"source\":\($0)" } ?? ""
        let meaningValue = meaning ?? "meaning-\(content)"
        let reviewFragment = lastReviewedAt.map { ",\"lastReviewedAt\":\"\($0)\"" } ?? ""
        let readerHiddenFragment = readerHidden.map { ",\"isReaderHidden\":\($0)" } ?? ""
        let reviewExcludedFragment = reviewExcluded.map { ",\"isReviewExcluded\":\($0)" } ?? ""
        let streakFragment = reviewStreak.map { ",\"reviewStreak\":\($0)" } ?? ""
        let reviewCountFragment = reviewCount.map { ",\"reviewCount\":\($0)" } ?? ""
        let json = """
        {"id":"\(id)","content":"\(content)","meaning":"\(meaningValue)",
         "pos":null,"difficulty":null,"difficultyTier":null,"note":null,
         "collocations":[],"examples":["an example"],"mode":"recognition",
         "isDeleted":\(isDeleted),"notebookId":"default"\(sourceFragment)\(reviewFragment)\(readerHiddenFragment)\(reviewExcludedFragment)\(streakFragment)\(reviewCountFragment)}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(KGCard.self, from: json)
    }

    private func fetchEntry(_ container: ModelContainer, word: String) throws -> VocabularyEntry? {
        let context = ModelContext(container)
        let entries = try context.fetch(FetchDescriptor<VocabularyEntry>())
        return entries.first { $0.word == word }
    }

    // MARK: - resolveSource (pure-function fallback semantics)

    @Test func resolveSource_book_with_title_and_chapter() throws {
        let card = try makeCard(
            content: "ephemeral",
            sourceJSON: #"{"type":"book","title":"Moby Dick","url":null,"chapter":"Loomings"}"#
        )
        let resolved = BackgroundSyncActor.resolveSource(from: card)
        #expect(resolved.bookTitle == "Moby Dick")
        #expect(resolved.chapterTitle == "Loomings")
    }

    @Test func resolveSource_book_without_chapter_yields_nil_chapter() throws {
        let card = try makeCard(
            content: "ephemeral",
            sourceJSON: #"{"type":"book","title":"Moby Dick","url":null}"#
        )
        let resolved = BackgroundSyncActor.resolveSource(from: card)
        #expect(resolved.bookTitle == "Moby Dick")
        #expect(resolved.chapterTitle == nil)
    }

    @Test func resolveSource_nil_source_falls_back_to_placeholder() throws {
        let card = try makeCard(content: "ephemeral", sourceJSON: nil)
        let resolved = BackgroundSyncActor.resolveSource(from: card)
        #expect(resolved.bookTitle == BackgroundSyncActor.fallbackBookTitle)
        #expect(resolved.chapterTitle == nil)
    }

    @Test func resolveSource_empty_title_falls_back_to_placeholder() throws {
        let card = try makeCard(
            content: "ephemeral",
            sourceJSON: #"{"type":"book","title":"   ","url":null,"chapter":"Loomings"}"#
        )
        let resolved = BackgroundSyncActor.resolveSource(from: card)
        #expect(resolved.bookTitle == BackgroundSyncActor.fallbackBookTitle)
        // No usable book title means no chapter either.
        #expect(resolved.chapterTitle == nil)
    }

    @Test func resolveSource_non_book_type_falls_back_to_placeholder() throws {
        let card = try makeCard(
            content: "ephemeral",
            sourceJSON: #"{"type":"web","title":"Wikipedia","url":"https://x"}"#
        )
        let resolved = BackgroundSyncActor.resolveSource(from: card)
        #expect(resolved.bookTitle == BackgroundSyncActor.fallbackBookTitle)
        #expect(resolved.chapterTitle == nil)
    }

    // MARK: - pullCardsToLocal (end-to-end sync-down)

    @Test func syncDown_newEntry_reflects_book_source() async throws {
        let container = try makeContainer()
        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(
            content: "ephemeral",
            sourceJSON: #"{"type":"book","title":"Pride and Prejudice","url":null,"chapter":"Chapter 3"}"#
        )

        try await actor.pullCardsToLocal(
            fetchedCards: [card],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entry = try fetchEntry(container, word: "ephemeral")
        #expect(entry?.bookTitle == "Pride and Prejudice")
        #expect(entry?.chapterTitle == "Chapter 3")
    }

    @Test func syncDown_newEntry_without_source_falls_back_to_placeholder() async throws {
        let container = try makeContainer()
        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(content: "transient", sourceJSON: nil)

        try await actor.pullCardsToLocal(
            fetchedCards: [card],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entry = try fetchEntry(container, word: "transient")
        #expect(entry?.bookTitle == BackgroundSyncActor.fallbackBookTitle)
        #expect(entry?.chapterTitle == nil)
    }

    @Test func syncDown_existingEntry_backfills_book_source() async throws {
        let container = try makeContainer()

        // Seed a synced entry that previously lost its source (placeholder title).
        let seedContext = ModelContext(container)
        let stale = VocabularyEntry(
            word: "ephemeral",
            translation: "meaning-ephemeral",
            context: "an example",
            bookTitle: BackgroundSyncActor.fallbackBookTitle
        )
        stale.notebookId = "default"
        stale.markSynced()
        seedContext.insert(stale)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(
            content: "ephemeral",
            sourceJSON: #"{"type":"book","title":"Moby Dick","url":null,"chapter":"Loomings"}"#
        )

        try await actor.pullCardsToLocal(
            fetchedCards: [card],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entry = try fetchEntry(container, word: "ephemeral")
        #expect(entry?.bookTitle == "Moby Dick")
        #expect(entry?.chapterTitle == "Loomings")
    }

    @Test func syncDown_existingEntry_keeps_local_title_when_server_source_missing() async throws {
        let container = try makeContainer()

        // A locally-known book title must not be clobbered by a card that
        // carries no usable server source.
        let seedContext = ModelContext(container)
        let local = VocabularyEntry(
            word: "ephemeral",
            translation: "meaning-ephemeral",
            context: "an example",
            bookTitle: "Locally Known Book",
            chapterTitle: "Local Chapter"
        )
        local.notebookId = "default"
        local.markSynced()
        seedContext.insert(local)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(content: "ephemeral", sourceJSON: nil)

        try await actor.pullCardsToLocal(
            fetchedCards: [card],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entry = try fetchEntry(container, word: "ephemeral")
        #expect(entry?.bookTitle == "Locally Known Book")
        #expect(entry?.chapterTitle == "Local Chapter")
    }

    @Test func syncDown_newEntry_mergesCardVisibilityPreferences() async throws {
        let container = try makeContainer()
        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(
            content: "quiet",
            sourceJSON: nil,
            readerHidden: true,
            reviewExcluded: true
        )

        try await actor.pullCardsToLocal(
            fetchedCards: [card],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entry = try fetchEntry(container, word: "quiet")
        #expect(entry?.isReaderHidden == true)
        #expect(entry?.isReviewExcluded == true)
        #expect(entry?.shouldAppearInReader == false)
        #expect(entry?.shouldAppearInReview == false)
    }

    @Test func contentDiffers_detectsCardVisibilityPreferenceChanges() throws {
        let entry = VocabularyEntry(
            word: "quiet",
            translation: "meaning-quiet",
            context: "an example",
            bookTitle: "Book"
        )
        entry.markSynced()
        let card = try makeCard(
            content: "quiet",
            sourceJSON: nil,
            readerHidden: true,
            reviewExcluded: false
        )

        #expect(BackgroundSyncActor.contentDiffers(card: card, from: entry))
    }

    /// A stale pull may carry the server's older content while a local edit is
    /// waiting for its upload. Both retryable edit states must survive it.
    @Test func syncDown_preservesLocalEditForPendingAndFailedEntries() async throws {
        for syncStatus in [VocabularySyncState.pending.rawValue, VocabularySyncState.failed.rawValue] {
            let container = try makeContainer()
            let seedContext = ModelContext(container)
            let local = VocabularyEntry(
                word: "ephemeral",
                translation: "local translation",
                context: "local context",
                explanation: "local note",
                bookTitle: "Local Book"
            )
            local.kgCardId = "c-edit"
            local.syncStatus = syncStatus
            local.actionType = VocabularySyncAction.edit.rawValue
            seedContext.insert(local)
            try seedContext.save()

            let actor = BackgroundSyncActor(modelContainer: container)
            let staleRemote = try makeCard(id: "c-edit", content: "ephemeral", sourceJSON: nil)
            try await actor.pullCardsToLocal(
                fetchedCards: [staleRemote],
                isIncremental: true,
                progress: { _, _, _ in }
            )

            let entry = try fetchEntry(container, word: "ephemeral")
            #expect(entry?.translation == "local translation")
            #expect(entry?.explanation == "local note")
            #expect(entry?.syncStatus == syncStatus)
            #expect(entry?.actionType == VocabularySyncAction.edit.rawValue)
        }
    }

    @Test func syncDown_syncedEntry_stillAcceptsRemoteContent() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let local = VocabularyEntry(
            word: "ephemeral",
            translation: "local translation",
            context: "local context",
            explanation: "local note",
            bookTitle: "Local Book"
        )
        local.kgCardId = "c-remote-wins"
        local.markSynced()
        seedContext.insert(local)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let remote = try makeCard(id: "c-remote-wins", content: "ephemeral", sourceJSON: nil)
        try await actor.pullCardsToLocal(
            fetchedCards: [remote],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entry = try fetchEntry(container, word: "ephemeral")
        #expect(entry?.translation == "meaning-ephemeral")
        #expect(entry?.explanation == nil)
        #expect(entry?.isSynced == true)
        #expect(entry?.actionType == VocabularySyncAction.add.rawValue)
    }

    @Test func syncDown_existingEntry_appliesRemoteContentIdentityChange() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let local = VocabularyEntry(
            word: "old-word",
            translation: "meaning-old-word",
            context: "an example",
            bookTitle: BackgroundSyncActor.fallbackBookTitle
        )
        local.kgCardId = "c-word-rename"
        local.reviewExamples = ["an example"]
        local.markSynced()
        seedContext.insert(local)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let remote = try makeCard(
            id: "c-word-rename",
            content: "new-word",
            sourceJSON: nil,
            meaning: "meaning-old-word"
        )

        #expect(BackgroundSyncActor.contentDiffers(card: remote, from: local))

        let result = try await actor.pullCardsToLocal(
            fetchedCards: [remote],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entries = try ModelContext(container).fetch(FetchDescriptor<VocabularyEntry>())
        #expect(result.updated == 1)
        #expect(entries.count == 1)
        #expect(entries.first?.word == "new-word")
        #expect(entries.first?.kgCardId == "c-word-rename")
    }

    @Test func syncDown_pendingDelete_stillPreservesLocalEntry() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let local = VocabularyEntry(
            word: "ephemeral",
            translation: "local translation",
            context: "local context",
            explanation: "local note",
            bookTitle: "Local Book"
        )
        local.kgCardId = "c-delete"
        local.queueDelete()
        seedContext.insert(local)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let remote = try makeCard(id: "c-delete", content: "ephemeral", sourceJSON: nil)
        try await actor.pullCardsToLocal(
            fetchedCards: [remote],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entry = try fetchEntry(container, word: "ephemeral")
        #expect(entry?.translation == "local translation")
        #expect(entry?.explanation == "local note")
        #expect(entry?.isPendingDelete == true)
    }

    // MARK: - Tombstone resolution (#2547)

    @Test func syncDown_tombstone_doesNotDeleteLiveCardWithSameWord() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let live = VocabularyEntry(word: "ephemeral", translation: "meaning-ephemeral", context: "an example", bookTitle: "Book")
        live.notebookId = "default"
        live.kgCardId = "card-Y"
        live.markSynced()
        seedContext.insert(live)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let tombstone = try makeCard(id: "card-X", content: "ephemeral", sourceJSON: nil, isDeleted: true)

        try await actor.pullCardsToLocal(
            fetchedCards: [tombstone],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entry = try fetchEntry(container, word: "ephemeral")
        #expect(entry?.kgCardId == "card-Y")
    }

    @Test func syncDown_tombstone_doesNotDeletePendingCardWithSameWord() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let pending = VocabularyEntry(word: "ephemeral", translation: "meaning-ephemeral", context: "an example", bookTitle: "Book")
        pending.notebookId = "default"
        seedContext.insert(pending)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let tombstone = try makeCard(id: "card-X", content: "ephemeral", sourceJSON: nil, isDeleted: true)

        try await actor.pullCardsToLocal(
            fetchedCards: [tombstone],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let entry = try fetchEntry(container, word: "ephemeral")
        #expect(entry != nil)
        #expect(entry?.syncStatus == 0)
    }

    @Test func syncDown_tombstone_matchingCardId_deletesCard() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let live = VocabularyEntry(word: "ephemeral", translation: "meaning-ephemeral", context: "an example", bookTitle: "Book")
        live.notebookId = "default"
        live.kgCardId = "card-X"
        live.markSynced()
        seedContext.insert(live)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let tombstone = try makeCard(id: "card-X", content: "ephemeral", sourceJSON: nil, isDeleted: true)

        try await actor.pullCardsToLocal(
            fetchedCards: [tombstone],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        #expect(try fetchEntry(container, word: "ephemeral") == nil)
    }

    @Test func syncDown_tombstoneThenLiveCardSameWord_insertsNewEntry() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let old = VocabularyEntry(word: "ephemeral", translation: "meaning-ephemeral", context: "an example", bookTitle: "Book")
        old.notebookId = "default"
        old.kgCardId = "card-X"
        old.markSynced()
        seedContext.insert(old)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let tombstone = try makeCard(id: "card-X", content: "ephemeral", sourceJSON: nil, isDeleted: true)
        let fresh = try makeCard(id: "card-Y", content: "ephemeral", sourceJSON: nil)

        try await actor.pullCardsToLocal(
            fetchedCards: [tombstone, fresh],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let context = ModelContext(container)
        let entries = try context.fetch(FetchDescriptor<VocabularyEntry>()).filter { $0.word == "ephemeral" }
        #expect(entries.count == 1)
        #expect(entries.first?.kgCardId == "card-Y")
    }

    @Test func syncDown_liveRekeyThenTombstoneForOldId_keepsRekeyedEntry() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let existing = VocabularyEntry(word: "ephemeral", translation: "meaning-ephemeral", context: "an example", bookTitle: "Book")
        existing.notebookId = "default"
        existing.kgCardId = "card-X"
        existing.markSynced()
        seedContext.insert(existing)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        // Batch order matters: the live card re-keys the entry from card-X to card-Y,
        // then the tombstone for card-X arrives and must not delete the re-keyed row.
        let rekeyed = try makeCard(id: "card-Y", content: "ephemeral", sourceJSON: nil)
        let tombstone = try makeCard(id: "card-X", content: "ephemeral", sourceJSON: nil, isDeleted: true)

        try await actor.pullCardsToLocal(
            fetchedCards: [rekeyed, tombstone],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        let context = ModelContext(container)
        let entries = try context.fetch(FetchDescriptor<VocabularyEntry>()).filter { $0.word == "ephemeral" }
        #expect(entries.count == 1)
        #expect(entries.first?.kgCardId == "card-Y")
    }

    @Test func fullSync_tombstoneDoesNotShieldUnmatchedSyncedGhost_reapsIt() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        // Row the tombstone (card-X) deletes; orphan cleanup must not count it again.
        let deletedRow = VocabularyEntry(word: "ephemeral", translation: "meaning-ephemeral", context: "an example", bookTitle: "Book")
        deletedRow.notebookId = "default"
        deletedRow.kgCardId = "card-X"
        deletedRow.markSynced()
        // Synced ghosts sharing the tombstone's word key: no kgCardId, and a different one.
        let ghostNil = VocabularyEntry(word: "ephemeral", translation: "meaning-ephemeral", context: "an example", bookTitle: "Book")
        ghostNil.notebookId = "default"
        ghostNil.markSynced()
        let ghostOther = VocabularyEntry(word: "ephemeral", translation: "meaning-ephemeral", context: "an example", bookTitle: "Book")
        ghostOther.notebookId = "default"
        ghostOther.kgCardId = "card-OTHER"
        ghostOther.markSynced()
        // Synced row whose kgCardId matches a live card: must survive cleanup.
        let kept = VocabularyEntry(word: "lucid", translation: "meaning-lucid", context: "an example", bookTitle: "Book")
        kept.notebookId = "default"
        kept.kgCardId = "card-L"
        kept.markSynced()
        seedContext.insert(deletedRow)
        seedContext.insert(ghostNil)
        seedContext.insert(ghostOther)
        seedContext.insert(kept)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let tombstone = try makeCard(id: "card-X", content: "ephemeral", sourceJSON: nil, isDeleted: true)
        let live = try makeCard(id: "card-L", content: "lucid", sourceJSON: nil)

        // 4 local synced rows vs 2 server cards → ratio 0.5, diff 2: cleanup runs.
        let result = try await actor.pullCardsToLocal(
            fetchedCards: [tombstone, live],
            isIncremental: false,
            progress: { _, _, _ in }
        )

        #expect(result.orphanCleanupBlocked == false)
        let context = ModelContext(container)
        let remaining = try context.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(remaining.filter { $0.word == "ephemeral" }.isEmpty)
        #expect(remaining.contains { $0.word == "lucid" && $0.kgCardId == "card-L" })
        // deletedRow is counted once (tombstone) plus the two ghosts: 3, not 4.
        #expect(result.deleted == 3)
    }

    // MARK: - Orphan cleanup safety-valve signalling
    //
    // Regression coverage for the sync-boundary leak: when a FULL sync's
    // orphan cleanup is blocked by the mass-deletion safety valve, the local
    // store still holds ghost entries. `pullCardsToLocal` must report this so
    // the caller can refuse to advance the incremental boundary (forcing a
    // full-sync retry next time) instead of permanently stranding the ghosts.

    /// Seed `count` server-synced entries that will become orphans (they are
    /// absent from any fetched-card list).
    private func seedSyncedEntries(_ container: ModelContainer, count: Int) throws {
        let context = ModelContext(container)
        for i in 0..<count {
            let entry = VocabularyEntry(
                word: "orphan-\(i)",
                translation: "meaning-\(i)",
                context: "ctx",
                bookTitle: "Book"
            )
            entry.notebookId = "default"
            entry.markSynced()
            context.insert(entry)
        }
        try context.save()
    }

    @Test func fullSync_safetyValve_blocked_reports_orphanCleanupBlocked() async throws {
        let container = try makeContainer()
        // 10 local synced entries; server returns just 1 → ratio 0.1 < 0.3.
        try seedSyncedEntries(container, count: 10)

        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(content: "survivor", sourceJSON: nil)

        let result = try await actor.pullCardsToLocal(
            fetchedCards: [card],
            isIncremental: false,
            progress: { _, _, _ in }
        )

        #expect(result.orphanCleanupBlocked == true)

        // Ghost entries must still be present — cleanup was skipped.
        let context = ModelContext(container)
        let remaining = try context.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(remaining.contains { $0.word == "orphan-0" })
    }

    @Test func fullSync_normal_reports_orphanCleanupNotBlocked() async throws {
        let container = try makeContainer()
        // 2 local synced entries; server returns both → no orphans, no block.
        let context = ModelContext(container)
        for word in ["alpha", "beta"] {
            let entry = VocabularyEntry(
                word: word,
                translation: "meaning-\(word)",
                context: "ctx",
                bookTitle: "Book"
            )
            entry.notebookId = "default"
            entry.markSynced()
            context.insert(entry)
        }
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let cards = [
            try makeCard(id: "a", content: "alpha", sourceJSON: nil),
            try makeCard(id: "b", content: "beta", sourceJSON: nil),
        ]

        let result = try await actor.pullCardsToLocal(
            fetchedCards: cards,
            isIncremental: false,
            progress: { _, _, _ in }
        )

        #expect(result.orphanCleanupBlocked == false)
    }

    @Test func incrementalSync_never_reports_orphanCleanupBlocked() async throws {
        let container = try makeContainer()
        // Many local synced entries, tiny incremental batch — orphan cleanup
        // does not run at all on incremental syncs, so it can never be blocked.
        try seedSyncedEntries(container, count: 10)

        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(content: "survivor", sourceJSON: nil)

        let result = try await actor.pullCardsToLocal(
            fetchedCards: [card],
            isIncremental: true,
            progress: { _, _, _ in }
        )

        #expect(result.orphanCleanupBlocked == false)
    }

    // MARK: - clearUserData (logout / account-switch isolation)
    //
    // Regression coverage for the multi-account leak: the local clear path must
    // wipe the app-account-scoped @Model types — vocab / review / notebook /
    // PodcastSeries / PodcastEpisode / PodcastProgress — in one pass, so account
    // B can't see account A's cards, followed series, or playback progress.
    //
    // `Book` is DELIBERATELY EXEMPT: it lives in the CloudKit-backed CloudStore
    // and its files sit in the per-Apple-ID iCloud/Documents container, so the
    // library is scoped to the Apple ID, not the app account. Clearing Book rows
    // on logout deleted them locally (and risked propagating the delete to
    // CloudKit) while the disk files persisted and the cold-start reconciler
    // rebuilt the rows anyway — fake isolation that only stranded the user with
    // an empty bookshelf after re-login. So `clearUserData` must LEAVE Book rows
    // intact (user decision 2026-06-10: library binds to Apple ID).

    /// Seed N user-scoped books with reading position + progress set, so the
    /// test proves the leaked private state (locator / progression) is cleared.
    private func seedBooks(_ container: ModelContainer, count: Int) throws {
        let context = ModelContext(container)
        for i in 0..<count {
            let book = Book(
                title: "Book \(i)",
                author: "Author \(i)",
                fileName: "\(UUID().uuidString).epub"
            )
            book.lastReadLocatorJSON = "{\"loc\":\(i)}"
            book.progression = 0.42
            book.preferredNotebookId = "nb-\(i)"
            context.insert(book)
        }
        try context.save()
    }

    /// Seed N series (each with M cascade-owned episodes), K orphan episodes
    /// (no series), and P progress rows.
    private func seedPodcastData(
        _ container: ModelContainer,
        series seriesCount: Int,
        episodesPerSeries: Int,
        orphanEpisodes: Int,
        progress progressCount: Int
    ) throws {
        let context = ModelContext(container)
        for s in 0..<seriesCount {
            let series = PodcastSeries(remoteId: "series-\(s)", title: "Series \(s)", hostNames: ["Host"])
            series.isFollowed = true
            context.insert(series)
            for e in 0..<episodesPerSeries {
                let ep = PodcastEpisode(remoteId: "s\(s)-e\(e)", episodeNumber: e, title: "Ep \(e)", durationSec: 60)
                ep.series = series
                context.insert(ep)
            }
        }
        for o in 0..<orphanEpisodes {
            let ep = PodcastEpisode(remoteId: "orphan-ep-\(o)", episodeNumber: o, title: "Orphan \(o)", durationSec: 60)
            context.insert(ep)
        }
        for p in 0..<progressCount {
            let prog = PodcastProgress(episodeRemoteId: "prog-ep-\(p)", lastPlayedTime: 12.5, completed: false)
            context.insert(prog)
        }
        try context.save()
    }

    @Test func clearUserData_removes_all_podcast_models() async throws {
        let container = try makeContainer()
        try seedSyncedEntries(container, count: 3)
        try seedPodcastData(
            container,
            series: 2,
            episodesPerSeries: 3,   // 6 cascade-owned episodes
            orphanEpisodes: 2,      // 2 series-less orphans
            progress: 4
        )

        // Sanity: data is actually present before the clear.
        let preContext = ModelContext(container)
        #expect(try preContext.fetchCount(FetchDescriptor<PodcastSeries>()) == 2)
        #expect(try preContext.fetchCount(FetchDescriptor<PodcastEpisode>()) == 8) // 6 + 2 orphans
        #expect(try preContext.fetchCount(FetchDescriptor<PodcastProgress>()) == 4)

        let actor = BackgroundSyncActor(modelContainer: container)
        try await actor.clearUserData(reason: "account-switch")

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<PodcastSeries>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PodcastEpisode>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PodcastProgress>()) == 0)
    }

    @Test func clearUserData_still_removes_vocab_review_notebook() async throws {
        let container = try makeContainer()

        let context = ModelContext(container)
        // vocab
        let entry = VocabularyEntry(word: "alpha", translation: "m", context: "ctx", bookTitle: "Book")
        entry.notebookId = "default"
        entry.markSynced()
        context.insert(entry)
        // review
        context.insert(ReviewRecord(word: "alpha", entryID: nil, feedback: 1, reviewedAt: Date()))
        // notebook
        context.insert(Notebook(remoteId: "nb1", name: "NB"))
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        try await actor.clearUserData(reason: "logout")

        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<VocabularyEntry>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<ReviewRecord>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<Notebook>()) == 0)
    }

    // #2745: logout deletes every VocabularyEntry, so the logout gate must count
    // every row the server has not confirmed (pending 0 and failed 2), and must
    // report zero when everything is synced so logout proceeds without a prompt.
    @Test func unsyncedEntryCount_countsPendingAndFailedButNotSynced() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let pendingA = VocabularyEntry(word: "pendingA", translation: "m", context: "ctx", bookTitle: "Book")
        let pendingB = VocabularyEntry(word: "pendingB", translation: "m", context: "ctx", bookTitle: "Book")
        let synced = VocabularyEntry(word: "synced", translation: "m", context: "ctx", bookTitle: "Book")
        synced.markSynced()
        let failed = VocabularyEntry(word: "failed", translation: "m", context: "ctx", bookTitle: "Book")
        failed.syncStatus = 2
        [pendingA, pendingB, synced, failed].forEach { context.insert($0) }
        try context.save()

        #expect(try BackgroundSyncActor.unsyncedEntryCount(in: context) == 3)
    }

    @Test func unsyncedEntryCount_isZeroWhenEverythingSynced() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let synced = VocabularyEntry(word: "synced", translation: "m", context: "ctx", bookTitle: "Book")
        synced.markSynced()
        context.insert(synced)
        try context.save()

        #expect(try BackgroundSyncActor.unsyncedEntryCount(in: context) == 0)
    }

    // #2745: clearUserData also deletes every ReviewRecord, so unacknowledged
    // reviews (pushedAt == nil) are logout losses too and must be counted.
    @Test func unsyncedReviewCount_countsOnlyUnacknowledgedRecords() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let owed = ReviewRecord(word: "owed", entryID: nil, feedback: 1)
        let acknowledged = ReviewRecord(word: "acked", entryID: nil, feedback: 1)
        acknowledged.pushedAt = .now
        context.insert(owed)
        context.insert(acknowledged)
        try context.save()

        #expect(try BackgroundSyncActor.unsyncedReviewCount(in: context) == 1)
    }

    // #2745: the logout gate reads every row logout deletes. It proceeds with no
    // prompt only when no card and no review is unconfirmed by the server.
    @Test func logoutGate_allSyncedAndAcknowledgedProceedsDirectly() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let synced = VocabularyEntry(word: "synced", translation: "m", context: "ctx", bookTitle: "Book")
        synced.markSynced()
        let acknowledged = ReviewRecord(word: "synced", entryID: nil, feedback: 1)
        acknowledged.pushedAt = .now
        context.insert(synced)
        context.insert(acknowledged)
        try context.save()

        #expect(SettingsLogoutGate.evaluate(in: context) == .proceed)
    }

    @Test func logoutGate_unsyncedCardsRequireConfirmation() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(VocabularyEntry(word: "pending", translation: "m", context: "ctx", bookTitle: "Book"))
        try context.save()

        #expect(SettingsLogoutGate.evaluate(in: context) == .confirmUnsynced(cards: 1, reviews: 0))
    }

    // Regression for the review finding on #3159: an offline review of an already
    // synced card leaves zero unsynced VocabularyEntry rows, yet clearUserData still
    // deletes the unacknowledged ReviewRecord. The gate must ask before that loss.
    @Test func logoutGate_unacknowledgedReviewOnlyRequiresConfirmation() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let synced = VocabularyEntry(word: "synced", translation: "m", context: "ctx", bookTitle: "Book")
        synced.markSynced()
        context.insert(synced)
        context.insert(ReviewRecord(word: "synced", entryID: nil, feedback: 1))
        try context.save()

        #expect(SettingsLogoutGate.evaluate(in: context) == .confirmUnsynced(cards: 0, reviews: 1))
    }

    @Test func logoutGate_unreadableCountRequiresConfirmation() {
        #expect(SettingsLogoutGate.decide(unsyncedCards: nil, unsyncedReviews: 0) == .confirmUnreadable)
        #expect(SettingsLogoutGate.decide(unsyncedCards: 0, unsyncedReviews: nil) == .confirmUnreadable)
    }

    @Test func buildReviewEventsPushPayload_encodesLocalRecords() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let entryID = UUID()
        let entry = VocabularyEntry(word: "alpha", translation: "m", context: "ctx", bookTitle: "Book")
        entry.id = entryID
        entry.kgCardId = "card-alpha"
        entry.markSynced()
        context.insert(entry)
        let record = ReviewRecord(
            word: "alpha",
            entryID: entryID,
            feedback: 1,
            reviewedAt: reviewedAt
        )
        record.id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        record.notebookId = "nb1"
        context.insert(record)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let payload = try await actor.buildReviewEventsPushPayload()

        #expect(payload.count == 1)
        let item = try #require(payload.first)
        #expect(item.event_id == "11111111-1111-1111-1111-111111111111")
        #expect(item.card_id == "card-alpha")
        #expect(item.word_snapshot == "alpha")
        #expect(item.notebook_id == "nb1")
        #expect(item.feedback == 1)
        #expect(item.reviewed_at.contains("2027"))
        #expect(item.created_at.contains("2027"))
    }

    @Test func buildReviewEventsPushPayload_usesFixatedCardIdWhenEntryGone() async throws {
        // 根因迴歸:卡離場(store 裡查無對應 entry)時,固化在 ReviewRecord 上的 kgCardId
        // 仍須讓 card_id 不退化成 nil(舊版即時三段反查到此會回 nil → 後端 card_id NULL)。
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = ReviewRecord(
            word: "orphaned",
            entryID: UUID(),                       // 對應 entry 不存在於 store
            feedback: 1,
            reviewedAt: Date(timeIntervalSince1970: 1_800_000_000),
            kgCardId: "card-fixated",
            intervalBefore: 12.0,
            intervalAfter: 22.8,
            nextReviewBefore: Date(timeIntervalSince1970: 1_800_000_000),
            nextReviewAfter: Date(timeIntervalSince1970: 1_800_082_080),
            reviewCountAfter: 3,
            streakAfter: 2,
            lapseAfter: 1
        )
        record.id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        context.insert(record)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let item = try #require(try await actor.buildReviewEventsPushPayload().first)
        #expect(item.card_id == "card-fixated")        // 不再退化
        #expect(item.interval_before == 12.0)
        #expect(item.interval_after == 22.8)
        #expect(item.review_count_after == 3)
        #expect(item.streak_after == 2)
        #expect(item.lapse_after == 1)
        #expect(item.next_review_before != nil)
        #expect(item.next_review_after != nil)
    }

    @Test func buildReviewEventsPushPayload_legacyRecordFallsBackToLookup() async throws {
        // legacy 紀錄(kgCardId 未固化)且 entry 仍在:回退舊三段反查仍能解出 card_id。
        let container = try makeContainer()
        let context = ModelContext(container)
        let entryID = UUID()
        let entry = VocabularyEntry(word: "legacy", translation: "m", context: "ctx", bookTitle: "Book")
        entry.id = entryID
        entry.kgCardId = "card-legacy"
        entry.markSynced()
        context.insert(entry)
        let record = ReviewRecord(word: "legacy", entryID: entryID, feedback: 0)  // kgCardId nil
        record.id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        context.insert(record)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let item = try #require(try await actor.buildReviewEventsPushPayload().first)
        #expect(item.card_id == "card-legacy")          // fallback 反查解出
        #expect(item.interval_after == nil)             // legacy 無 SRS 快照
    }

    @Test func buildReviewEventsPushPayload_duplicateEntryId_doesNotTrap() async throws {
        // 兩個 entry 共用同一 id(VocabularyEntry.id 非 unique,CloudKit 重複列可造成):
        // Dictionary(uniqueKeysWithValues:) 會 trap,必須改為確定性去重並仍解出 card_id。
        let container = try makeContainer()
        let context = ModelContext(container)
        let sharedID = UUID()
        for word in ["dup-a", "dup-b"] {
            let entry = VocabularyEntry(word: word, translation: "m", context: "ctx", bookTitle: "Book")
            entry.id = sharedID
            entry.kgCardId = "card-dup"
            entry.markSynced()
            context.insert(entry)
        }
        let record = ReviewRecord(word: "dup-a", entryID: sharedID, feedback: 0)  // kgCardId nil
        record.id = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        context.insert(record)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let item = try #require(try await actor.buildReviewEventsPushPayload().first)
        #expect(item.card_id == "card-dup")
    }

    // MARK: - Review-state push watermark

    /// Every synced card's SRS state was re-sent on every sync (644 cards in
    /// production) even when nothing had been reviewed since the last push.
    /// Once acknowledged, a card stays out of the payload until it is reviewed.
    @Test func buildReviewStatePushPayload_skipsCardsAcknowledgedSinceTheirLastReview() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let settled = VocabularyEntry(word: "settled", translation: "m", context: "c", bookTitle: "B")
        settled.markSynced()
        settled.lastReviewedAt = reviewedAt
        settled.reviewStateSyncedAt = reviewedAt.addingTimeInterval(60)   // acked after the review
        context.insert(settled)

        let reviewedSince = VocabularyEntry(word: "reviewed-since", translation: "m", context: "c", bookTitle: "B")
        reviewedSince.markSynced()
        reviewedSince.lastReviewedAt = reviewedAt.addingTimeInterval(120) // reviewed after the ack
        reviewedSince.reviewStateSyncedAt = reviewedAt.addingTimeInterval(60)
        context.insert(reviewedSince)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let payload = try await actor.buildReviewStatePushPayload()

        #expect(payload.map { $0.body["word"] as? String } == ["reviewed-since"])
    }

    /// A card the server has never been told about must be sent at least once,
    /// even if it was never reviewed — the backend schedules from `next_review_at`.
    @Test func buildReviewStatePushPayload_sendsNeverAcknowledgedCardsOnce() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let never = VocabularyEntry(word: "never-acked", translation: "m", context: "c", bookTitle: "B")
        never.markSynced()                       // no lastReviewedAt, no reviewStateSyncedAt
        context.insert(never)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let sent = try await actor.buildReviewStatePushPayload()
        #expect(sent.count == 1)

        try await actor.markReviewStatesPushed(sent)
        #expect(try await actor.buildReviewStatePushPayload().isEmpty)
    }

    /// #2483: a review persisted after its card was put in the payload must
    /// stay dirty. The ack covers only the instant that was sent, so a later
    /// `lastReviewedAt` survives even when it predates the ack's wall clock.
    @Test func markReviewStatesPushed_leavesReviewsSavedAfterTheSendDirty() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let sentReview = Date().addingTimeInterval(-3600)

        let inFlight = VocabularyEntry(word: "reviewed-mid-push", translation: "m", context: "c", bookTitle: "B")
        inFlight.markSynced()
        inFlight.lastReviewedAt = sentReview
        context.insert(inFlight)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let sent = try await actor.buildReviewStatePushPayload()

        // The next answer is persisted while the request is in flight.
        let writer = ModelContext(container)
        let next = try #require(try writer.fetch(FetchDescriptor<VocabularyEntry>()).first)
        next.lastReviewedAt = sentReview.addingTimeInterval(30)
        try writer.save()

        try await actor.markReviewStatesPushed(sent)

        #expect(try await actor.buildReviewStatePushPayload().count == 1)
    }

    /// Server-authoritative state is already on the server; accepting it must
    /// not leave the card queued to push that same state straight back.
    @Test func pullCardsToLocal_serverWinsMarksReviewStateAcknowledged() async throws {
        let container = try makeContainer()
        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(id: "c-srs", content: "acked", sourceJSON: nil, lastReviewedAt: "2027-01-15T10:00:00Z")

        _ = try await actor.pullCardsToLocal(fetchedCards: [card], isIncremental: true, progress: { _, _, _ in })

        #expect(try await actor.buildReviewStatePushPayload().isEmpty)
    }

    /// #2485: a server copy newer than local that forgot the card (streak 0) is
    /// the authoritative state, so the local streak must reset. The old
    /// `max(local, server)` kept the stale streak of 5.
    @Test func pullCardsToLocal_serverNewerForgotResetsLocalStreak() async throws {
        let container = try makeContainer()
        let localReviewedAt = try #require(ISO8601DateFormatter().date(from: "2027-01-10T10:00:00Z"))
        let seedContext = ModelContext(container)
        let existing = VocabularyEntry(word: "forgot", translation: "meaning-forgot", context: "an example", bookTitle: "Book")
        existing.notebookId = "default"
        existing.kgCardId = "c-streak"
        existing.markSynced()
        existing.lastReviewedAt = localReviewedAt
        existing.reviewStreak = 5
        existing.reviewCount = 5
        seedContext.insert(existing)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(
            id: "c-streak", content: "forgot", sourceJSON: nil,
            lastReviewedAt: "2027-01-15T10:00:00Z", reviewStreak: 0, reviewCount: 6
        )

        _ = try await actor.pullCardsToLocal(fetchedCards: [card], isIncremental: true, progress: { _, _, _ in })

        let entry = try #require(try fetchEntry(container, word: "forgot"))
        #expect(entry.reviewStreak == 0)
        #expect(entry.reviewCount == 6)
    }

    /// A server card that omits `reviewStreak` carries no streak to adopt, so
    /// the local streak must survive the server-newer merge.
    @Test func pullCardsToLocal_serverNewerWithoutStreakKeepsLocalStreak() async throws {
        let container = try makeContainer()
        let localReviewedAt = try #require(ISO8601DateFormatter().date(from: "2027-01-10T10:00:00Z"))
        let seedContext = ModelContext(container)
        let existing = VocabularyEntry(word: "nostreak", translation: "meaning-nostreak", context: "an example", bookTitle: "Book")
        existing.notebookId = "default"
        existing.kgCardId = "c-nostreak"
        existing.markSynced()
        existing.lastReviewedAt = localReviewedAt
        existing.reviewStreak = 4
        seedContext.insert(existing)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(
            id: "c-nostreak", content: "nostreak", sourceJSON: nil,
            lastReviewedAt: "2027-01-15T10:00:00Z"
        )

        _ = try await actor.pullCardsToLocal(fetchedCards: [card], isIncremental: true, progress: { _, _, _ in })

        #expect(try #require(try fetchEntry(container, word: "nostreak")).reviewStreak == 4)
    }

    // MARK: - Push watermark

    /// #2042: a local mode change not yet acknowledged is the user's intent. A pull carrying the server's
    /// old mode and newer SRS state must neither overwrite the mode nor run the review merge.
    @Test func pullCardsToLocal_pendingReviewModeSurvivesServerPull() async throws {
        let container = try makeContainer()
        let localReviewedAt = try #require(ISO8601DateFormatter().date(from: "2027-01-10T10:00:00Z"))
        let seedContext = ModelContext(container)
        let existing = VocabularyEntry(word: "pending", translation: "meaning-pending", context: "an example", bookTitle: "Book")
        existing.notebookId = "default"
        existing.kgCardId = "c-pending"
        existing.markSynced()
        existing.lastReviewedAt = localReviewedAt
        existing.reviewCount = 2
        existing.requestReviewMode(.production)
        seedContext.insert(existing)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(
            id: "c-pending", content: "pending", sourceJSON: nil,
            lastReviewedAt: "2027-01-15T10:00:00Z", reviewCount: 9
        )

        _ = try await actor.pullCardsToLocal(fetchedCards: [card], isIncremental: true, progress: { _, _, _ in })

        let entry = try #require(try fetchEntry(container, word: "pending"))
        #expect(entry.reviewMode == .production)
        #expect(entry.pendingReviewModePush)
        #expect(entry.reviewCount == 2)
        #expect(entry.lastReviewedAt == localReviewedAt)
    }

    /// #2042: a progress reset not yet acknowledged must survive a newer server copy with the old counts.
    @Test func pullCardsToLocal_pendingProgressResetSurvivesServerPull() async throws {
        let container = try makeContainer()
        let resetAt = try #require(ISO8601DateFormatter().date(from: "2027-01-12T10:00:00Z"))
        let seedContext = ModelContext(container)
        let existing = VocabularyEntry(word: "reset", translation: "meaning-reset", context: "an example", bookTitle: "Book")
        existing.notebookId = "default"
        existing.kgCardId = "c-reset"
        existing.markSynced()
        existing.reviewCount = 7
        existing.resetReviewProgress(now: resetAt)
        seedContext.insert(existing)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let card = try makeCard(
            id: "c-reset", content: "reset", sourceJSON: nil,
            lastReviewedAt: "2027-01-15T10:00:00Z", reviewCount: 7
        )

        _ = try await actor.pullCardsToLocal(fetchedCards: [card], isIncremental: true, progress: { _, _, _ in })

        let entry = try #require(try fetchEntry(container, word: "reset"))
        #expect(entry.reviewCount == 0)
        #expect(entry.pendingReviewProgressReset)
        #expect(entry.lastReviewedAt == resetAt)
    }

    /// #2042: a progress reset is pushed with `override: true` even when the server watermark is ahead of
    /// the device clock (the card would otherwise look acknowledged). The flag clears once that reset is acked.
    @Test func buildReviewStatePushPayload_progressResetIsOverridePushedUntilAcknowledged() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let reset = VocabularyEntry(word: "reset", translation: "m", context: "c", bookTitle: "B")
        reset.markSynced()
        reset.reviewCount = 7
        reset.reviewStateSyncedAt = now.addingTimeInterval(3600)   // server watermark ahead of device clock
        reset.resetReviewProgress(now: now)
        context.insert(reset)

        let plain = VocabularyEntry(word: "plain", translation: "m", context: "c", bookTitle: "B")
        plain.markSynced()
        plain.lastReviewedAt = now
        plain.reviewStateSyncedAt = now.addingTimeInterval(3600)
        context.insert(plain)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let sent = try await actor.buildReviewStatePushPayload()

        #expect(sent.map { $0.body["word"] as? String } == ["reset"])
        #expect(sent.first?.body["override"] as? Bool == true)
        #expect(sent.first?.body["review_count"] as? Int == 0)

        try await actor.markReviewStatesPushed(sent)
        let stored = try #require(try fetchEntry(container, word: "reset"))
        #expect(stored.pendingReviewProgressReset == false)
        #expect(try await actor.buildReviewStatePushPayload().isEmpty)
    }

    /// The payload must carry only events the server has not acknowledged.
    ///
    /// Without a watermark the client re-uploaded its entire review history on
    /// every sync — measured in production at 9,542 events / ~3.4MB / 10
    /// sequential PATCHes, 15.4s of a 17s sync, with the server skipping 100%
    /// of them.
    @Test func buildReviewEventsPushPayload_skipsAlreadyPushedRecords() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let pushed = ReviewRecord(word: "settled", entryID: nil, feedback: 1)
        pushed.pushedAt = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(pushed)

        let pending = ReviewRecord(word: "fresh", entryID: nil, feedback: 1)
        context.insert(pending)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let payload = try await actor.buildReviewEventsPushPayload()

        #expect(payload.map(\.word_snapshot) == ["fresh"])
    }

    /// A newly created review is pending until a push acknowledges it.
    @Test func reviewRecord_startsUnpushed() throws {
        #expect(ReviewRecord(word: "brand-new", entryID: nil, feedback: 1).pushedAt == nil)
    }

    /// Marking is per-batch, so a batch that fails (e.g. the 429 the old
    /// 10-request burst provoked) must not un-acknowledge the batches that
    /// already landed — and must not acknowledge the ones that did not.
    @Test func markReviewEventsPushed_marksOnlyTheGivenIds() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let landed = ReviewRecord(word: "landed", entryID: nil, feedback: 1)
        landed.id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        context.insert(landed)
        let stranded = ReviewRecord(word: "stranded", entryID: nil, feedback: 1)
        stranded.id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
        context.insert(stranded)
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        try await actor.markReviewEventsPushed(eventIDs: [landed.id.uuidString])

        let remaining = try await actor.buildReviewEventsPushPayload()
        #expect(remaining.map(\.word_snapshot) == ["stranded"])
    }

    /// Batches drain oldest-first so a partially-pushed history advances
    /// monotonically instead of re-shuffling on every attempt.
    @Test func buildReviewEventsPushPayload_isOrderedByReviewedAt() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for (word, offset) in [("third", 300.0), ("first", 100.0), ("second", 200.0)] {
            context.insert(ReviewRecord(
                word: word,
                entryID: nil,
                feedback: 1,
                reviewedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset)
            ))
        }
        try context.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let payload = try await actor.buildReviewEventsPushPayload()

        #expect(payload.map(\.word_snapshot) == ["first", "second", "third"])
    }

    /// An event pulled *from* the server is already on the server. Leaving it
    /// unmarked would make the next sync push the whole pulled history straight
    /// back — the watermark would never drain on a device that pulls history.
    @Test func mergeReviewEvents_marksRemoteEventsAsAlreadyPushed() async throws {
        let container = try makeContainer()
        let actor = BackgroundSyncActor(modelContainer: container)
        let remote = KGReviewEventPayload(
            event_id: "BBBBBBBB-0000-0000-0000-000000000001",
            card_id: "card-remote",
            word_snapshot: "remote",
            notebook_id: "default",
            feedback: 1,
            reviewed_at: "2027-01-15T10:00:00Z",
            created_at: "2027-01-15T10:00:00Z"
        )

        try await actor.mergeReviewEvents([remote])

        // Assert the record exists *and* is marked. An empty payload alone is
        // also what "the merge inserted nothing" looks like, so that assertion
        // by itself would go green on a regression in the insert path.
        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<ReviewRecord>()).first)
        #expect(stored.word == "remote")
        #expect(stored.pushedAt != nil)
        #expect(try await actor.buildReviewEventsPushPayload().isEmpty)
    }

    @Test func mergeReviewEvents_fixatesRemoteCardIdAndSRS() async throws {
        // 拉回的遠端事件即使本機查無對應 entry,也固化 card_id + SRS,不退化。
        let container = try makeContainer()
        let actor = BackgroundSyncActor(modelContainer: container)
        let remote = [KGReviewEventPayload(
            event_id: "66666666-6666-6666-6666-666666666666",
            card_id: "card-remote",
            word_snapshot: "delta",
            notebook_id: "default",
            feedback: 1,
            reviewed_at: "2026-06-04T10:00:00+00:00",
            created_at: "2026-06-04T10:00:00+00:00",
            interval_before: 12.0,
            interval_after: 22.8,
            next_review_before: "2026-06-04T10:00:00+00:00",
            next_review_after: "2026-06-05T08:48:00+00:00",
            review_count_after: 4,
            streak_after: 3,
            lapse_after: 0
        )]
        try await actor.mergeReviewEvents(remote)

        let context = ModelContext(container)
        let record = try #require(try context.fetch(FetchDescriptor<ReviewRecord>()).first)
        #expect(record.kgCardId == "card-remote")
        #expect(record.intervalAfter == 22.8)
        #expect(record.reviewCountAfter == 4)
        #expect(record.streakAfter == 3)
    }

    @Test func mergeReviewEvents_insertsMissingAndSkipsDuplicates() async throws {
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let linkedEntry = VocabularyEntry(word: "beta", translation: "m", context: "ctx", bookTitle: "Book")
        linkedEntry.kgCardId = "card-beta"
        linkedEntry.markSynced()
        seedContext.insert(linkedEntry)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        let eventID = "22222222-2222-2222-2222-222222222222"
        let remote = [KGReviewEventPayload(
            event_id: eventID,
            card_id: "card-beta",
            word_snapshot: "beta",
            notebook_id: "nb2",
            feedback: 0,
            reviewed_at: "2026-06-02T10:00:00+00:00",
            created_at: "2026-06-02T10:00:03+00:00"
        )]

        try await actor.mergeReviewEvents(remote)
        try await actor.mergeReviewEvents(remote)

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.id.uuidString == eventID.uppercased())
        #expect(record.entryID == linkedEntry.id)
        #expect(record.word == "beta")
        #expect(record.notebookId == "nb2")
        #expect(record.feedback == 0)
    }

    @Test func mergeReviewEvents_duplicateKgCardId_doesNotTrapAndAttachesToEarliestEntry() async throws {
        // 兩個本機 entry 共用同一 kgCardId:不得 trap,且事件固定掛到 dateAdded 最早者。
        let container = try makeContainer()
        let seedContext = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let later = VocabularyEntry(word: "Chateau", translation: "m", context: "ctx", bookTitle: "Book")
        later.kgCardId = "card-chateau"
        later.dateAdded = base.addingTimeInterval(100)
        later.markSynced()
        let earlier = VocabularyEntry(word: "chateau,", translation: "m", context: "ctx", bookTitle: "Book")
        earlier.kgCardId = "card-chateau"
        earlier.dateAdded = base
        earlier.markSynced()
        seedContext.insert(later)
        seedContext.insert(earlier)
        try seedContext.save()

        let actor = BackgroundSyncActor(modelContainer: container)
        try await actor.mergeReviewEvents([KGReviewEventPayload(
            event_id: "88888888-8888-8888-8888-888888888888",
            card_id: "card-chateau",
            word_snapshot: "chateau",
            notebook_id: "default",
            feedback: 1,
            reviewed_at: "2026-06-04T10:00:00+00:00",
            created_at: "2026-06-04T10:00:00+00:00"
        )])

        let context = ModelContext(container)
        let record = try #require(try context.fetch(FetchDescriptor<ReviewRecord>()).first)
        #expect(record.entryID == earlier.id)
    }

    @Test func mergeReviewEvents_restoresAfterLocalClear() async throws {
        let container = try makeContainer()
        let actor = BackgroundSyncActor(modelContainer: container)
        let remote = [KGReviewEventPayload(
            event_id: "33333333-3333-3333-3333-333333333333",
            card_id: nil,
            word_snapshot: "gamma",
            notebook_id: "default",
            feedback: 1,
            reviewed_at: "2026-06-03T10:00:00+00:00",
            created_at: "2026-06-03T10:00:03+00:00"
        )]

        try await actor.mergeReviewEvents(remote)
        try await actor.clearUserData(reason: "test-clear")
        try await actor.mergeReviewEvents(remote)

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        #expect(records.count == 1)
        #expect(records.first?.word == "gamma")
    }

    @Test func clearUserData_preserves_books() async throws {
        let container = try makeContainer()
        try seedBooks(container, count: 3)

        // Sanity: books (with private reading state) are present pre-clear.
        let preContext = ModelContext(container)
        #expect(try preContext.fetchCount(FetchDescriptor<Book>()) == 3)

        let actor = BackgroundSyncActor(modelContainer: container)
        try await actor.clearUserData(reason: "account-switch")

        // Book is Apple-ID-scoped (CloudStore/CloudKit) — logout/account-switch
        // must NOT delete the library rows. They survive untouched.
        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<Book>()) == 3)
    }

    @Test func clearUserData_clears_account_scoped_but_keeps_books() async throws {
        let container = try makeContainer()
        try seedSyncedEntries(container, count: 2)
        try seedPodcastData(
            container,
            series: 1,
            episodesPerSeries: 2,
            orphanEpisodes: 1,
            progress: 1
        )
        try seedBooks(container, count: 2)

        let actor = BackgroundSyncActor(modelContainer: container)
        try await actor.clearUserData(reason: "account-switch")

        // App-account-scoped models gone in one pass — no model type stranded.
        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<VocabularyEntry>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<PodcastSeries>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<PodcastEpisode>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<PodcastProgress>()) == 0)
        // Book is Apple-ID-scoped — deliberately preserved across the clear.
        #expect(try after.fetchCount(FetchDescriptor<Book>()) == 2)
    }
}
