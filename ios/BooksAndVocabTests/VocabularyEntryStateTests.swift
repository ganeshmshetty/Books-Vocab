import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// 覆蓋 `VocabularyEntry` 的可見性 / 上傳判準 computed properties。
///
/// 這些 computed property 是 in-memory filter（StatsPresentation、
/// VocabularyListView 等）的真相。@Query 走的是平行的
/// `knowledgeListPredicate(notebookId:)` 工廠（SwiftData #Predicate 無法
/// 直接引用 computed property，故同條件雙軌表述）—— 本測試鎖 computed
/// 軌不漂移。回歸保護：syncStatus × actionType × isArchived 以及兩個
/// per-card visibility flags 的組合不可漂移。
@Suite("VocabularyEntry state predicates")
struct VocabularyEntryStateTests {

    @Test("封存排序對相同單字使用穩定 UUID tie-breaker")
    func archivedQueryUsesStableUUIDTieBreakerAcrossPersistenceOrder() throws {
        let source = try Self.archivedSheetSource()
        #expect(
            source.contains("SortDescriptor<VocabularyEntry>(\\VocabularyEntry.word)") &&
                source.contains("SortDescriptor<VocabularyEntry>(\\VocabularyEntry.id)"),
            "ArchivedVocabSheet query must sort equal words by stable id"
        )

        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let orderAB = try Self.persistedArchivedIDs(inserting: [firstID, secondID])
        let orderBA = try Self.persistedArchivedIDs(inserting: [secondID, firstID])

        #expect(orderAB == orderBA)
        #expect(orderAB == [firstID, secondID])
    }

    @Test("封存單字詳情必須以 activeEntries 作為候選池（#2727）")
    func archivedSheetPassesActiveEntriesToWordDetailSheet() throws {
        let source = try Self.archivedSheetSource()
        #expect(
            source.contains("WordDetailSheet(entry: entry, allEntries: activeEntries)"),
            "ArchivedVocabSheet must pass allEntries: activeEntries to WordDetailSheet, otherwise the candidate pool is empty"
        )
    }

    private static func archivedSheetSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let iosRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = iosRootURL
            .appendingPathComponent("BooksAndVocab/Views/Vocabulary/Scenes/ArchivedVocabSheet.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func persistedArchivedIDs(inserting ids: [UUID]) throws -> [UUID] {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: configuration
        )
        let context = ModelContext(container)

        for (index, id) in ids.enumerated() {
            let entry = VocabularyEntry(
                word: "duplicate",
                translation: "翻譯",
                context: "ctx",
                bookTitle: "book"
            )
            entry.id = id
            entry.notebookId = index == 0 ? "notebook-a" : "notebook-b"
            entry.syncStatus = VocabularySyncState.synced.rawValue
            entry.actionType = VocabularySyncAction.add.rawValue
            entry.isArchived = true
            context.insert(entry)
        }
        try context.save()

        let descriptor = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate<VocabularyEntry> { $0.isArchived == true },
            sortBy: [
                SortDescriptor(\VocabularyEntry.word),
                SortDescriptor(\VocabularyEntry.id)
            ]
        )
        return try context.fetch(descriptor).map(\.id)
    }

    /// 建一筆 entry 並覆寫 sync 狀態欄位（init 預設 syncStatus=0/add/未封存）。
    private func entry(
        status: Int,
        action: String,
        archived: Bool = false,
        readerHidden: Bool = false,
        reviewExcluded: Bool = false
    ) -> VocabularyEntry {
        let e = VocabularyEntry(
            word: "w", translation: "翻譯", context: "ctx", bookTitle: "book"
        )
        e.syncStatus = status
        e.actionType = action
        e.isArchived = archived
        e.isReaderHidden = readerHidden
        e.isReviewExcluded = reviewExcluded
        return e
    }

    // MARK: - shouldAppearInKnowledgeList = synced && !delete && !archived

    @Test("synced + add + 未封存 → 入知識列表")
    func knowledgeList_syncedAdd() {
        #expect(entry(status: 1, action: "add").shouldAppearInKnowledgeList)
    }

    @Test("synced 但已封存 → 不入知識列表")
    func knowledgeList_excludesArchived() {
        #expect(!entry(status: 1, action: "add", archived: true).shouldAppearInKnowledgeList)
    }

    @Test("synced 但待刪除 → 不入知識列表")
    func knowledgeList_excludesDelete() {
        #expect(!entry(status: 1, action: "delete").shouldAppearInKnowledgeList)
    }

    @Test("未同步(pending) → 不入知識列表")
    func knowledgeList_excludesPending() {
        #expect(!entry(status: 0, action: "add").shouldAppearInKnowledgeList)
    }

    // MARK: - shouldAppearInArchiveList = synced && !delete && archived

    @Test("synced + 已封存 → 入封存列表")
    func archiveList_syncedArchived() {
        #expect(entry(status: 1, action: "add", archived: true).shouldAppearInArchiveList)
    }

    @Test("synced + 未封存 → 不入封存列表（與知識列表互斥）")
    func archiveList_excludesUnarchived() {
        #expect(!entry(status: 1, action: "add").shouldAppearInArchiveList)
    }

    @Test("已封存但待刪除 → 不入封存列表")
    func archiveList_excludesDelete() {
        #expect(!entry(status: 1, action: "delete", archived: true).shouldAppearInArchiveList)
    }

    @Test("知識列表與封存列表恆互斥")
    func knowledgeAndArchiveAreMutuallyExclusive() {
        for archived in [true, false] {
            let e = entry(status: 1, action: "add", archived: archived)
            #expect(e.shouldAppearInKnowledgeList != e.shouldAppearInArchiveList)
        }
    }

    // MARK: - shouldAppearInReader = !delete && !archived

    @Test("未刪除 + 未封存 → 入 Reader（含未同步）")
    func reader_pendingStillShows() {
        #expect(entry(status: 0, action: "add").shouldAppearInReader)
    }

    @Test("已封存 → 不入 Reader")
    func reader_excludesArchived() {
        #expect(!entry(status: 1, action: "add", archived: true).shouldAppearInReader)
    }

    @Test("待刪除 → 不入 Reader")
    func reader_excludesDelete() {
        #expect(!entry(status: 1, action: "delete").shouldAppearInReader)
    }

    @Test("閱讀時不顯示只影響 Reader，不影響單字本與複習")
    func readerHidden_excludesReaderOnly() {
        let e = entry(status: 1, action: "add", readerHidden: true)
        #expect(!e.shouldAppearInReader)
        #expect(e.shouldAppearInKnowledgeList)
        #expect(e.shouldAppearInReview)
    }

    @Test("不複習只影響複習，不影響單字本與 Reader")
    func reviewExcluded_excludesReviewOnly() {
        let e = entry(status: 1, action: "add", reviewExcluded: true)
        #expect(e.shouldAppearInReader)
        #expect(e.shouldAppearInKnowledgeList)
        #expect(!e.shouldAppearInReview)
    }

    @Test("封存仍優先排除 Reader 與複習")
    func archived_preferencesRemainDormant() {
        let e = entry(status: 1, action: "add", archived: true)
        #expect(!e.shouldAppearInReader)
        #expect(!e.shouldAppearInReview)
        #expect(e.shouldAppearInArchiveList)
    }

    // MARK: - shouldUploadOnNextSync = pendingAdd || pendingDelete || failedAdd || failedDelete

    @Test("pending + add → 待上傳")
    func upload_pendingAdd() {
        #expect(entry(status: 0, action: "add").shouldUploadOnNextSync)
    }

    @Test("failed + delete → 待上傳（重試）")
    func upload_failedDelete() {
        #expect(entry(status: 2, action: "delete").shouldUploadOnNextSync)
    }

    @Test("synced + add → 不再上傳")
    func upload_syncedAddSkips() {
        #expect(!entry(status: 1, action: "add").shouldUploadOnNextSync)
    }

    // MARK: - #3673: editing a synced card keeps it visible while the server still holds it

    private func syncedWithServerCard() -> VocabularyEntry {
        let e = VocabularyEntry(word: "edit", translation: "翻譯", context: "ctx", bookTitle: "book")
        e.notebookId = "notebook-a"
        e.kgCardId = "c-edit"
        e.markSynced()
        return e
    }

    @Test("#3673 synced 卡編輯排入 pending edit 後仍入知識列表與複習")
    func editQueued_syncedCardStaysVisible() {
        let e = syncedWithServerCard()
        e.queueEdit()
        #expect(e.shouldAppearInKnowledgeList)
        #expect(e.shouldAppearInReview)
    }

    @Test("#3673 編輯被拒收（failed + edit + rejectedReason）後仍入知識列表與複習")
    func editRejected_syncedCardStaysVisible() {
        let e = syncedWithServerCard()
        e.queueEdit()
        e.markEditRejected(reason: "rejected")
        #expect(e.shouldAppearInKnowledgeList)
        #expect(e.shouldAppearInReview)
    }

    @Test("#3673 待刪除的 synced 卡仍不入知識列表（negative control）")
    func pendingDeleteWithServerCard_stillHidden() {
        let e = syncedWithServerCard()
        e.syncAction = .delete
        e.syncState = .pending
        #expect(!e.shouldAppearInKnowledgeList)
    }

    @Test("#3673 pending add 且無 kgCardId 仍不入知識列表（negative control）")
    func pendingAddWithoutServerCard_stillHidden() {
        let e = VocabularyEntry(word: "new", translation: "翻譯", context: "ctx", bookTitle: "book")
        e.syncAction = .add
        e.syncState = .pending
        #expect(!e.shouldAppearInKnowledgeList)
    }

    @Test("#3673 queueEdit 後 knowledgeListPredicate 仍取回該卡，negative controls 仍排除（SwiftData）")
    func editQueued_stillFetchedByKnowledgeListPredicate() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: VocabularyEntry.self, configurations: configuration)
        let context = ModelContext(container)

        let edited = syncedWithServerCard()
        context.insert(edited)

        let pendingAdd = VocabularyEntry(word: "new", translation: "翻譯", context: "ctx", bookTitle: "book")
        pendingAdd.notebookId = "notebook-a"
        pendingAdd.syncAction = .add
        pendingAdd.syncState = .pending
        context.insert(pendingAdd)

        let pendingDelete = syncedWithServerCard()
        pendingDelete.word = "gone"
        pendingDelete.syncAction = .delete
        pendingDelete.syncState = .pending
        context.insert(pendingDelete)
        try context.save()

        edited.queueEdit()
        try context.save()

        let rows = try context.fetch(
            FetchDescriptor<VocabularyEntry>(predicate: VocabularyEntry.knowledgeListPredicate(notebookId: "notebook-a"))
        )
        #expect(rows.map(\.id) == [edited.id])
    }
}
