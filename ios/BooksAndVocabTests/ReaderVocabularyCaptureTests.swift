#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Capture-side coverage for `ReaderVocabularyContext` — the
/// `VocabularyContextProtocol` implementation backing the reader's auto-save
/// pipeline. Pre-existing notebook orphan defense already pins
/// `resolveNotebookId` / `sanitizeOutbox` / `triggerPipelinesIsolated`; these
/// tests target the gap between user tap and outbox enqueue: notebook
/// scoping, root-form matching, fresh insert wiring, restore-from-delete,
/// and the synced-vs-unsynced delete fork.
@MainActor
struct ReaderVocabularyCaptureTests {

    private func makeContext() throws -> ModelContext {
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
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeBook(in ctx: ModelContext, title: String = "Book") -> Book {
        let book = Book(title: title, author: "A", fileName: "f.epub")
        ctx.insert(book)
        return book
    }

    private func makeCapture(
        ctx: ModelContext,
        vocabulary: [VocabularyEntry] = [],
        notebookId: String = "default"
    ) -> ReaderVocabularyContext {
        ReaderVocabularyContext(
            vocabulary: vocabulary,
            modelContext: ctx,
            book: makeBook(in: ctx),
            currentLocator: nil,
            notebookId: notebookId,
            toastCoordinator: AppToastCoordinator()
        )
    }

    private func makeEntry(
        word: String,
        notebookId: String = "default",
        rootForm: String? = nil,
        inflections: [String] = [],
        syncStatus: Int = 0,
        actionType: String = "add"
    ) -> VocabularyEntry {
        let entry = VocabularyEntry(
            word: word,
            translation: "t",
            context: "ctx",
            explanation: nil,
            partOfSpeech: nil,
            bookTitle: "B",
            chapterTitle: nil
        )
        entry.notebookId = notebookId
        entry.rootForm = rootForm
        entry.inflections = inflections
        entry.syncStatus = syncStatus
        entry.actionType = actionType
        return entry
    }

    // MARK: - existingEntry scoping & matching

    @Test func existingEntry_isScopedToNotebookId() throws {
        let ctx = try makeContext()
        let inOtherNotebook = makeEntry(word: "alpha", notebookId: "other")
        let inDefault = makeEntry(word: "alpha", notebookId: "default")
        let capture = makeCapture(
            ctx: ctx,
            vocabulary: [inOtherNotebook, inDefault],
            notebookId: "default"
        )
        let result = capture.existingEntry(matching: "alpha")
        #expect(result?.notebookId == "default",
                "existingEntry must filter by notebookId — duplicate words across notebooks are independent entries")
    }

    @Test func existingEntry_matchesByRootFormAndInflectionLowercase() throws {
        let ctx = try makeContext()
        let entry = makeEntry(
            word: "lay",
            notebookId: "default",
            rootForm: "lie",
            inflections: ["lays", "laid", "laying"]
        )
        let capture = makeCapture(ctx: ctx, vocabulary: [entry])

        #expect(capture.existingEntry(matching: "Lay") != nil, "match must be case-insensitive on the surface word")
        #expect(capture.existingEntry(matching: "Lie") != nil, "tapping the lemma must hit the entry via rootForm")
        #expect(capture.existingEntry(matching: "LAID") != nil, "tapping an inflection must hit the entry case-insensitively")
        #expect(capture.existingEntry(matching: "unrelated") == nil)
    }

    @Test func lookedUpWords_filtersToNotebookScopeWhenProvided() throws {
        let inDefault = makeEntry(
            word: "anchor",
            notebookId: "default",
            rootForm: "anchored",
            inflections: ["anchors"]
        )
        let inOther = makeEntry(
            word: "foreign",
            notebookId: "other",
            rootForm: "foreigner",
            inflections: ["foreigns"]
        )

        let lookedUp = Set(
            ReaderVocabularyContext.lookedUpWords(
                from: [inDefault, inOther],
                notebookId: "default"
            )
        )

        #expect(lookedUp.contains("anchor"))
        #expect(lookedUp.contains("anchored"))
        #expect(lookedUp.contains("anchors"))
        #expect(!lookedUp.contains("foreign"),
                "reader underlines must only reflect the active notebook scope; otherwise tapped underlined words can still miss cache and hit the API")
        #expect(!lookedUp.contains("foreigner"))
        #expect(!lookedUp.contains("foreigns"))
    }

    @Test func lookedUpWords_excludesReaderHiddenEntries() throws {
        let visible = makeEntry(
            word: "visible",
            rootForm: "see",
            inflections: ["visibly"]
        )
        let hidden = makeEntry(
            word: "hidden",
            rootForm: "hide",
            inflections: ["hiding"]
        )
        hidden.isReaderHidden = true

        let lookedUp = Set(
            ReaderVocabularyContext.lookedUpWords(
                from: [visible, hidden],
                notebookId: "default"
            )
        )

        #expect(lookedUp.contains("visible"))
        #expect(lookedUp.contains("see"))
        #expect(lookedUp.contains("visibly"))
        #expect(!lookedUp.contains("hidden"), "reader hidden cards must not feed reader lookup/highlight state")
        #expect(!lookedUp.contains("hide"))
        #expect(!lookedUp.contains("hiding"))
    }

    @Test func selectedPunctuationOnlyNoise_isDroppedBeforeNormalizeWord() {
        #expect(
            ReaderWordCapture.sanitizeSelectedWord("!?") == nil,
            "punctuation-only PDF selection must not reach normalizeWord as an empty capture"
        )
    }

    // MARK: - saveEntry insert path

    @Test func saveEntry_insertsNewEntryWithBookIdAndResolvedNotebookId() throws {
        let ctx = try makeContext()
        // Live notebook so resolveNotebookId doesn't fall back.
        let nb = Notebook(remoteId: "nb_real", name: "Real")
        ctx.insert(nb)
        try ctx.save()

        let capture = makeCapture(ctx: ctx, vocabulary: [], notebookId: "nb_real")
        let bookIdFromCapture = capture.book.id

        let inserted = capture.saveEntry(
            selection: WordSelection(word: "fresh", context: "this is fresh context", position: .zero),
            translation: "新鮮",
            rootForm: "fresh"
        )

        #expect(inserted == true, "saveEntry must report true on fresh insert")
        let all = try ctx.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(all.count == 1)
        let saved = try #require(all.first)
        #expect(saved.word == "fresh")
        #expect(saved.translation == "新鮮")
        #expect(saved.rootForm == "fresh")
        #expect(saved.notebookId == "nb_real", "resolveNotebookId chokepoint must keep the live candidate")
        #expect(saved.bookId == bookIdFromCapture, "bookId must be wired to the capture's source book")
        #expect(saved.context == "this is fresh context")
        #expect(saved.syncAction == .add)
        #expect(saved.chapterTitle == nil,
                "currentLocator: nil must round-trip to chapterTitle: nil — proves the locator passthrough wiring")
    }

    @Test func saveEntry_returnsFalseAndDoesNotDuplicateWhenActiveEntryExists() throws {
        let ctx = try makeContext()
        let active = makeEntry(word: "dup", notebookId: "default")
        ctx.insert(active)
        try ctx.save()

        let capture = makeCapture(ctx: ctx, vocabulary: [active])
        let inserted = capture.saveEntry(
            selection: WordSelection(word: "dup", context: "ignored", position: .zero),
            translation: "重複",
            rootForm: nil
        )
        #expect(inserted == false, "active (non-delete) entry must short-circuit save")

        let all = try ctx.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(all.count == 1, "no duplicate row should be inserted on collision")
        #expect(all.first?.translation == "t", "existing translation must NOT be overwritten by a duplicate tap")
    }

    @Test func saveEntry_restoresEntryQueuedForDeleteAndUpdatesTranslation() throws {
        let ctx = try makeContext()
        let queued = makeEntry(
            word: "ghost",
            notebookId: "default",
            actionType: "delete"
        )
        queued.syncStatus = 0  // pending — see queueDelete()
        ctx.insert(queued)
        try ctx.save()
        let originalId = queued.persistentModelID

        let capture = makeCapture(ctx: ctx, vocabulary: [queued])
        let inserted = capture.saveEntry(
            selection: WordSelection(word: "ghost", context: "ctx", position: .zero),
            translation: "新譯文",
            rootForm: "ghost"
        )

        #expect(inserted == true, "restoring a queued-delete must report true so the UI marks the entry as saved")
        let all = try ctx.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(all.count == 1, "restore must mutate in place, not insert a duplicate")
        let restored = try #require(all.first)
        #expect(restored.persistentModelID == originalId,
                "restore must mutate the SAME SwiftData row — a new row would break server-side correlation")
        #expect(restored.syncAction == .add, "restorePendingEntry() must flip the action back to .add")
        #expect(restored.translation == "新譯文", "restore must accept the latest translation")
        #expect(restored.rootForm == "ghost")
    }

    /// Issue #2105: ReaderView / PDFReaderView feed `vocabulary` from a
    /// `@Query` that filters out `actionType == "delete"`, so a word queued for
    /// delete is invisible to the snapshot. Re-saving it must still find and
    /// restore that row (keeping its `kgCardId`) instead of inserting a fresh
    /// entry — otherwise the next sync deletes the server card's history.
    @Test func saveEntry_restoresQueuedDeleteMissingFromDeleteFilteredSnapshot() throws {
        let ctx = try makeContext()
        let synced = makeEntry(word: "harbor", notebookId: "default", syncStatus: 1)
        synced.kgCardId = "card_harbor"
        ctx.insert(synced)
        try ctx.save()
        let originalId = synced.persistentModelID

        let deleteFiltered = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate { $0.actionType != "delete" }
        )
        let beforeDelete = makeCapture(ctx: ctx, vocabulary: try ctx.fetch(deleteFiltered))
        beforeDelete.deleteEntry(matching: "harbor")
        #expect(synced.syncAction == .delete, "arrange: synced entry must be queued for delete")

        let snapshot = try ctx.fetch(deleteFiltered)
        #expect(snapshot.isEmpty, "arrange: the reader's delete-filtered snapshot must hide the queued delete")
        let afterDelete = makeCapture(ctx: ctx, vocabulary: snapshot)
        let saved = afterDelete.saveEntry(
            selection: WordSelection(word: "Harbor", context: "ctx", position: .zero),
            translation: "港口",
            rootForm: "harbor"
        )

        #expect(saved == true)
        let all = try ctx.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(all.count == 1, "re-capture must restore the queued-delete row, not insert a second entry")
        let restored = try #require(all.first)
        #expect(restored.persistentModelID == originalId)
        #expect(restored.syncAction == .edit, "a server-held card is restored as a pending edit, never a re-sent add (#3408)")
        #expect(restored.isPendingEdit)
        #expect(restored.kgCardId == "card_harbor", "the server card id must survive so its history is kept")
        #expect(restored.translation == "港口")
        #expect(restored.rootForm == "harbor")
        let uploadableAdds = all.filter { $0.syncAction == .add && $0.shouldUploadOnNextSync }
        #expect(uploadableAdds.isEmpty, "batchAdd must not carry the word: the server would skip it and markSynced the stale translation")
        #expect(!all.contains { $0.syncAction == .delete }, "no delete may remain queued for upload")
    }

    // MARK: - sanitizeOutbox delete+add collapse

    /// Defence in depth for #2105: a pending delete and a pending add for the
    /// same word in the same notebook collapse into a restore of the delete row.
    @Test func sanitizeOutbox_collapsesDeleteAndAddForSameWord() throws {
        let ctx = try makeContext()
        let queuedDelete = makeEntry(word: "harbor", notebookId: "default", syncStatus: 1)
        queuedDelete.kgCardId = "card_harbor"
        queuedDelete.queueDelete()
        let freshAdd = makeEntry(word: "Harbor", notebookId: "default")
        freshAdd.translation = "港口"
        freshAdd.rootForm = "harbor"
        let otherNotebookAdd = makeEntry(word: "harbor", notebookId: "other")
        ctx.insert(queuedDelete)
        ctx.insert(freshAdd)
        ctx.insert(otherNotebookAdd)
        try ctx.save()
        let freshAddId = freshAdd.id
        let otherId = otherNotebookAdd.id

        let excluded = SyncCoordinator.sanitizeOutbox(
            pendingEntries: [queuedDelete, freshAdd, otherNotebookAdd],
            modelContext: ctx
        )

        #expect(excluded.contains(freshAddId), "the collapsed add must be excluded from the upload batches")
        #expect(queuedDelete.syncAction == .edit, "a server-held card becomes a pending edit, never a re-sent add (#3408)")
        #expect(queuedDelete.isPending)
        #expect(queuedDelete.kgCardId == "card_harbor")
        #expect(queuedDelete.translation == "港口", "the latest capture's translation wins")
        let all = try ctx.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(all.count == 2)
        #expect(!all.contains { $0.id == freshAddId }, "the duplicate add row is removed locally")
        #expect(all.contains { $0.id == otherId }, "a same-word entry in another notebook is independent")
    }

    // MARK: - deleteEntry sync/unsync fork

    @Test func deleteEntry_queuesDeleteForSyncedEntry() throws {
        let ctx = try makeContext()
        let synced = makeEntry(word: "anchor", notebookId: "default")
        synced.syncStatus = 1  // .synced
        ctx.insert(synced)
        try ctx.save()

        let capture = makeCapture(ctx: ctx, vocabulary: [synced])
        capture.deleteEntry(matching: "anchor")

        let all = try ctx.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(all.count == 1, "synced entry must NOT be physically removed — server still has it")
        let surviving = try #require(all.first)
        #expect(surviving.syncAction == .delete, "queueDelete() must flip actionType to delete")
        #expect(surviving.syncState == .pending, "queue must reset state to pending so the next sync picks it up")
    }

    @Test func deleteEntry_removesUnsyncedEntryLocally() throws {
        let ctx = try makeContext()
        let pending = makeEntry(word: "draft", notebookId: "default")
        pending.syncStatus = 0  // .pending — never synced
        ctx.insert(pending)
        try ctx.save()

        let capture = makeCapture(ctx: ctx, vocabulary: [pending])
        capture.deleteEntry(matching: "draft")

        let all = try ctx.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(all.isEmpty, "unsynced entry must be physically deleted — server never knew about it")
    }
}
#endif
