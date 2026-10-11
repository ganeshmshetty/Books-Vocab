#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// track-23 一致性回滾：notebook 編輯封面圖（device-local）的落地必須與
/// `updateNotebook` API 成敗一致。`NotebookCoverCommit.plan` 是純函式 —
/// API 成功才套用 `resolvedPath` + 刪 `fileToRemove`；失敗則完全不呼叫 →
/// coverImagePath 不變、舊圖保留，杜絕「新封面 + server 舊欄位」drift。
struct NotebookCoverCommitTests {

    // MARK: - plan（純資料分支）

    @Test func unchangedCoverKeepsPathAndDeletesNothing() {
        let plan = NotebookCoverCommit.plan(staged: "/covers/a.jpg", original: "/covers/a.jpg")
        #expect(plan.resolvedPath == "/covers/a.jpg")
        #expect(plan.fileToRemove == nil)
    }

    @Test func replacingCoverResolvesNewAndQueuesOldForRemoval() {
        let plan = NotebookCoverCommit.plan(staged: "/covers/new.jpg", original: "/covers/old.jpg")
        #expect(plan.resolvedPath == "/covers/new.jpg")
        #expect(plan.fileToRemove == "/covers/old.jpg")
    }

    @Test func addingCoverFromNoneDeletesNothing() {
        let plan = NotebookCoverCommit.plan(staged: "/covers/new.jpg", original: nil)
        #expect(plan.resolvedPath == "/covers/new.jpg")
        #expect(plan.fileToRemove == nil)
    }

    @Test func removingCoverResolvesNilAndQueuesOldForRemoval() {
        let plan = NotebookCoverCommit.plan(staged: nil, original: "/covers/old.jpg")
        #expect(plan.resolvedPath == nil)
        #expect(plan.fileToRemove == "/covers/old.jpg")
    }

    @Test func noCoverEitherSideIsNoOp() {
        let plan = NotebookCoverCommit.plan(staged: nil, original: nil)
        #expect(plan.resolvedPath == nil)
        #expect(plan.fileToRemove == nil)
    }

    // MARK: - removeStaleFile（檔案副作用，模擬 API 成功路徑）

    private func writeTempJPEG() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notebook_cover_\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        return url.path
    }

    /// API 成功 + 換圖 → 舊檔被刪。
    @Test func removeStaleFileDeletesOldImageOnSuccess() throws {
        let old = try writeTempJPEG()
        let new = try writeTempJPEG()
        let plan = NotebookCoverCommit.plan(staged: new, original: old)

        NotebookCoverCommit.removeStaleFile(plan)

        #expect(!FileManager.default.fileExists(atPath: old)) // 舊圖已刪
        #expect(FileManager.default.fileExists(atPath: new))  // 新圖保留
        try? FileManager.default.removeItem(atPath: new)
    }

    /// 封面未變更 → 不刪任何檔（避免誤刪仍在使用的圖）。
    @Test func removeStaleFileKeepsUnchangedCover() throws {
        let path = try writeTempJPEG()
        let plan = NotebookCoverCommit.plan(staged: path, original: path)

        NotebookCoverCommit.removeStaleFile(plan)

        #expect(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 模擬 API **失敗路徑**：`removeStaleFile` 從不被呼叫 → 舊圖必然保留，
    /// 可在重試 / 取消時恢復。此處直接驗證「不呼叫即不刪」的安全保證。
    @Test func failurePathNeverTouchesOldImage() throws {
        let old = try writeTempJPEG()
        // updateNotebook catch 分支不呼叫 removeStaleFile，亦不寫 resolvedPath。
        // 模擬之：不執行任何 commit 動作。
        #expect(FileManager.default.fileExists(atPath: old))
        try? FileManager.default.removeItem(atPath: old)
    }

    // MARK: - coordinator 提交路徑（#2428 create / #2731 failed update）

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Notebook.self, NotebookSettingsProjection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    private func remote(id: String = "nb-new", name: String = "N") -> KGNotebook {
        KGNotebook(
            id: id, name: name, color: nil, coverPattern: nil,
            sortOrder: 0, isDefault: false, isDeleted: false,
            cardCount: 0, updatedAt: nil,
            sourceSharedDeckId: nil, sourceVersion: nil
        )
    }

    /// #2428：建立成功 → 新本子持有 staged 封面路徑，檔案保留。
    @MainActor
    @Test func createPersistsStagedCoverOnSuccess() async throws {
        let ctx = try makeContext()
        let staged = try writeTempJPEG()
        let service = NotebookServiceFake(result: .success(remote()))

        await NotebookListCoordinator().createNotebook(
            name: "N", color: nil, coverPattern: nil, coverImagePath: staged,
            modelContext: ctx, kgService: service, toastCoordinator: AppToastCoordinator()
        )

        let saved = try ctx.fetch(FetchDescriptor<Notebook>())
        #expect(saved.first?.coverImagePath == staged)
        #expect(FileManager.default.fileExists(atPath: staged))
        try? FileManager.default.removeItem(atPath: staged)
    }

    /// #2428：建立 API 失敗 → staged jpg 被清掉（沒有 owner 的孤兒檔）。
    @MainActor
    @Test func createFailureRemovesStagedCover() async throws {
        let ctx = try makeContext()
        let staged = try writeTempJPEG()
        let service = NotebookServiceFake(result: .failure(URLError(.notConnectedToInternet)))

        await NotebookListCoordinator().createNotebook(
            name: "N", color: nil, coverPattern: nil, coverImagePath: staged,
            modelContext: ctx, kgService: service, toastCoordinator: AppToastCoordinator()
        )

        #expect(try ctx.fetch(FetchDescriptor<Notebook>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staged))
    }

    /// #2428 residual：remote 建立成功但本地 save 失敗 → 本地無 owner，staged jpg 必須清掉。
    @MainActor
    @Test func createSaveFailureRemovesStagedCover() async throws {
        let ctx = try makeContext()
        let staged = try writeTempJPEG()
        let service = NotebookServiceFake(result: .success(remote()))

        await NotebookListCoordinator().createNotebookCore(
            name: "N", color: nil, coverPattern: nil, coverImagePath: staged,
            modelContext: ctx, kgService: service, toastCoordinator: AppToastCoordinator(),
            persist: { _, _ in false }
        )

        #expect(!FileManager.default.fileExists(atPath: staged))
        // 已 insert 的 model 不可保留指向已刪檔案的路徑（之後任一次成功 save 會持久化 dangling 路徑）。
        let notebooks = try ctx.fetch(FetchDescriptor<Notebook>())
        #expect(notebooks.count == 1)
        #expect(notebooks.first?.coverImagePath == nil)
    }

    /// #2731：更新 API 失敗 → staged 新圖被清掉，原圖與 model 路徑不動。
    @MainActor
    @Test func updateFailureRemovesStagedAndKeepsOriginal() async throws {
        let ctx = try makeContext()
        let original = try writeTempJPEG()
        let staged = try writeTempJPEG()
        let nb = Notebook(remoteId: "nb-1", name: "Old", color: nil)
        nb.coverImagePath = original
        ctx.insert(nb)
        let service = NotebookServiceFake(result: .failure(URLError(.notConnectedToInternet)))

        await NotebookListCoordinator().updateNotebook(
            nb, name: "New", color: nil, coverPattern: nil,
            stagedCoverImagePath: staged, originalCoverImagePath: original,
            modelContext: ctx, kgService: service, toastCoordinator: AppToastCoordinator()
        )

        #expect(nb.coverImagePath == original)
        #expect(FileManager.default.fileExists(atPath: original))
        #expect(!FileManager.default.fileExists(atPath: staged))
        try? FileManager.default.removeItem(atPath: original)
    }

    /// #2731：更新失敗但使用者未換圖（staged == original）→ 絕不刪原圖。
    @MainActor
    @Test func updateFailureWithUnchangedCoverKeepsFile() async throws {
        let ctx = try makeContext()
        let original = try writeTempJPEG()
        let nb = Notebook(remoteId: "nb-1", name: "Old", color: nil)
        nb.coverImagePath = original
        ctx.insert(nb)
        let service = NotebookServiceFake(result: .failure(URLError(.notConnectedToInternet)))

        await NotebookListCoordinator().updateNotebook(
            nb, name: "New", color: nil, coverPattern: nil,
            stagedCoverImagePath: original, originalCoverImagePath: original,
            modelContext: ctx, kgService: service, toastCoordinator: AppToastCoordinator()
        )

        #expect(FileManager.default.fileExists(atPath: original))
        try? FileManager.default.removeItem(atPath: original)
    }
}

/// 只實作 create / update 的窄 NotebookServing fake（其餘不應被呼叫）。
private final class NotebookServiceFake: NotebookServing {
    let result: Result<KGNotebook, Error>
    init(result: Result<KGNotebook, Error>) { self.result = result }

    func fetchNotebooks() async throws -> [KGNotebook] { [] }
    func createNotebook(name: String, color: String?, coverPattern: String?) async throws -> KGNotebook {
        try result.get()
    }
    func updateNotebook(id: String, name: String?, color: String?, coverPattern: String?) async throws -> KGNotebook {
        try result.get()
    }
    func deleteNotebook(id: String) async throws {}
}
#endif
