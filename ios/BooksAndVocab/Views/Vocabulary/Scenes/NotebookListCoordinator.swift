//
//  NotebookListCoordinator.swift
//  Books & Vocab
//
//  單字本列表的 DB + API 操作封裝

import Foundation
import SwiftData

@MainActor protocol NotebookListCoordinating: AnyObject, Observable {
    func reconcileNotebooks(
        authManager: any AuthManaging,
        currentNotebooks: [Notebook],
        allEntries: [VocabularyEntry],
        modelContext: ModelContext,
        kgService: any KGServing
    ) async
    func createNotebook(
        name: String,
        color: String?,
        coverPattern: String?,
        coverImagePath: String?,
        modelContext: ModelContext,
        kgService: any NotebookServing,
        toastCoordinator: AppToastCoordinator
    ) async
    func updateNotebook(
        _ notebook: Notebook,
        name: String,
        color: String?,
        coverPattern: String?,
        stagedCoverImagePath: String?,
        originalCoverImagePath: String?,
        modelContext: ModelContext,
        kgService: any NotebookServing,
        toastCoordinator: AppToastCoordinator
    ) async
    func deleteNotebook(
        _ notebook: Notebook,
        isActive: Bool,
        availableNotebooks: [Notebook],
        allEntries: [VocabularyEntry],
        modelContext: ModelContext,
        kgService: any KGServing,
        toastCoordinator: AppToastCoordinator,
        setActiveNotebook: (String) -> Void
    ) async
}

@Observable @MainActor
final class NotebookListCoordinator: NotebookListCoordinating {
    var exportURL: URL?

    /// reconcile 失敗訊息；nil = 未失敗或已恢復。
    /// View 透過此值顯示 inline error banner + retry CTA。fetch 成功一律清空，
    /// 避免殘留 stale error。
    var reconcileError: String?

    /// 首次 reconcile 是否已完成（成功 / 失敗 / 未登入 early-return 都算）。
    /// 用於區分「載入中」vs「真的沒有單字本」— 鏡像 PR #603 Podcast 修法。
    /// 首次完成後永不重設，後續 refresh 不會再回退顯示 loading placeholder。
    var hasLoadedOnce: Bool = false

    /// 從 server 拉 notebook 清單並與本地 reconcile：
    /// - remote 新增 → 本地 insert
    /// - remote 同名 remoteId → 更新欄位（含 isSoftDeleted，對應遠端刪除）
    /// - 本地存在但 remote 不回報 → 本地標記 isSoftDeleted（對應被其他裝置刪除）
    /// - 任何轉為 isSoftDeleted 的 notebook 都 cascade 其 entries
    ///
    /// 與舊版 `ensureDefaultNotebook` 不同：**每次呼叫都 reconcile**，不再只在 `currentNotebooks.isEmpty` 時跑。
    func reconcileNotebooks(
        authManager: any AuthManaging,
        currentNotebooks: [Notebook],
        allEntries: [VocabularyEntry],
        modelContext: ModelContext,
        kgService: any KGServing
    ) async {
        // Clear any prior error up front so a stale banner never survives a new
        // reconcile attempt regardless of which branch returns below (mirrors
        // BookshelfCoordinator.clearError at the start of an import batch). The
        // failure branches below re-set it when this attempt also fails.
        reconcileError = nil
        guard authManager.isLoggedIn else {
            // 未登入也算「首次載入流程已完成」— 否則 logged-out users 會永久卡 loading placeholder。
            hasLoadedOnce = true
            return
        }
        defer { hasLoadedOnce = true }

        let remoteNotebooks: [KGNotebook]
        do {
            remoteNotebooks = try await kgService.fetchNotebooks()
        } catch {
            AppLog.kg.error("fetchNotebooks failed: \(error.localizedDescription)")
            // 離線占位：用 canonical "default" sentinel（非隨機 local-UUID），真本同步進來
            // 時 reconcile upsert 就地合併，不再分裂出永遠回收不掉的幽靈「我的單字本」。
            let allLocal = (try? modelContext.fetch(FetchDescriptor<Notebook>())) ?? []
            NotebookReconciler.ensureOfflineDefault(local: allLocal, modelContext: modelContext)
            modelContext.safeSave()
            // 本地已有 notebook 時 fetch 失敗仍要 inline error 提示，讓使用者
            // 知道清單可能不是最新且可手動重試。空清單情境上面已 fallback 本地預設。
            if !currentNotebooks.isEmpty {
                reconcileError = error.localizedDescription
            }
            return
        }

        // 查全量（含 isSoftDeleted）避免已刪除 notebook 無法被 reconcile 修正
        let allLocal: [Notebook]
        do {
            allLocal = try modelContext.fetch(FetchDescriptor<Notebook>())
        } catch {
            AppLog.kg.error("fetch all notebooks failed: \(error.localizedDescription)")
            reconcileError = error.localizedDescription
            return
        }

        let removed = NotebookReconciler.reconcile(
            remote: remoteNotebooks,
            local: allLocal,
            allEntries: allEntries,
            modelContext: modelContext
        )

        // 若全域 active notebook 指向剛轉不可見的本子（跨裝置刪除 / 孤兒回收），清掉
        // UserDefaults，否則 `Book.resolvedNotebookId` 還會 fall through 到死 id，
        // 造成新建 entry 變孤兒。
        if let active = ActiveNotebookStore.shared.activeNotebookIdIfSet,
           removed.contains(active) {
            ActiveNotebookStore.shared.clearStale()
            AppLog.kg.warning("cleared stale activeNotebookId after reconcile remove: \(active)")
        }

        modelContext.safeSave()
        reconcileError = nil

        // Remote merge keeps locally-newer settings dirty; push them now.
        await NotebookSettingsDrain.drain(modelContext: modelContext, service: kgService)
    }

    /// Reconcile the server vocab-ui projection with the local active notebook
    /// cursor. The store owns timestamp comparison, so stale responses are no-op.
    func syncActiveNotebookFromServer(authManager: any AuthManaging, kgService: any KGServing) async {
        await syncActiveNotebookFromServer(
            authManager: authManager,
            kgService: kgService,
            store: ActiveNotebookStore.shared
        )
    }

    /// Injectable user-config seam for account-switch regression tests and
    /// non-singleton local projections. Capture the account before the await so
    /// a response fetched for account A cannot apply after switching to B.
    func syncActiveNotebookFromServer(
        authManager: any AuthManaging,
        kgService: any UserConfigFetching,
        store: ActiveNotebookStore
    ) async {
        guard authManager.isLoggedIn,
              !authManager.isDemoMode,
              let requestedUserId = authManager.userId,
              let requestedToken = authManager.token
        else { return }
        do {
            let config = try await kgService.fetchUserConfig()
            guard Self.acceptsServerResponse(
                authManager: authManager,
                requestedUserId: requestedUserId,
                requestedToken: requestedToken
            ) else { return }
            guard let vu = config.vocab_ui,
                  let ts = vu.updated_at,
                  !vu.active_notebook_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            _ = store.syncActiveNotebookFromServer(
                ActiveNotebookState(activeNotebookId: vu.active_notebook_id, updatedAt: ts)
            )
        } catch {
            AppLog.kg.warning("syncActiveNotebookFromServer failed: \(error.localizedDescription)")
        }
    }

    /// A response or push belongs to the credential snapshot that started it,
    /// not merely to a mutable "logged in" bit that may now describe account B.
    static func acceptsServerResponse(
        authManager: any AuthManaging,
        requestedUserId: String,
        requestedToken: String
    ) -> Bool {
        !Task.isCancelled &&
            authManager.isLoggedIn &&
            !authManager.isDemoMode &&
            authManager.userId == requestedUserId &&
            authManager.token == requestedToken
    }

    /// best-effort push active notebook 到後端（讓 chrome / web 能讀）。失敗不 rollback：
    /// iCloud KVS 已是 Apple 裝置跨裝置權威，backend 為補充橋樑，後續 server sync 收斂。
    /// `id` 與 `updatedAt` 由 caller 在 setActive 後**同步**一起捕捉傳入（非在此讀
    /// snapshot），避免快速連續切換 A→B 時 task-A 讀到 B 的時戳、push 出 (idA, tsB) 不一致對。
    func pushActiveNotebook(
        _ id: String,
        updatedAt: Double?,
        requestedUserId: String,
        requestedToken: String,
        authManager: any AuthManaging,
        kgService: any UserConfigServing
    ) async {
        guard Self.acceptsServerResponse(
            authManager: authManager,
            requestedUserId: requestedUserId,
            requestedToken: requestedToken
        ) else { return }
        let payload = KGVocabUIConfig(active_notebook_id: id, updated_at: updatedAt)
        do {
            if let concreteService = kgService as? KGService {
                _ = try await concreteService.updateVocabUIConfig(payload, using: requestedToken)
            } else {
                _ = try await kgService.updateVocabUIConfig(payload)
            }
        } catch {
            AppLog.kg.warning("pushActiveNotebook failed: \(error.localizedDescription)")
        }
    }

    func createNotebook(
        name: String,
        color: String?,
        coverPattern: String?,
        coverImagePath: String?,
        modelContext: ModelContext,
        kgService: any NotebookServing,
        toastCoordinator: AppToastCoordinator
    ) async {
        await createNotebookCore(
            name: name, color: color, coverPattern: coverPattern, coverImagePath: coverImagePath,
            modelContext: modelContext, kgService: kgService, toastCoordinator: toastCoordinator,
            persist: { $0.safeSaveWithToast($1) }
        )
    }

    /// `createNotebook` 的實作 seam：`persist` 可注入，讓測試模擬本地存檔失敗（不在 protocol 上）。
    func createNotebookCore(
        name: String,
        color: String?,
        coverPattern: String?,
        coverImagePath: String?,
        modelContext: ModelContext,
        kgService: any NotebookServing,
        toastCoordinator: AppToastCoordinator,
        persist: (ModelContext, AppToastCoordinator) -> Bool
    ) async {
        do {
            let remote = try await kgService.createNotebook(name: name, color: color, coverPattern: coverPattern)
            let nb = Notebook(remoteId: remote.id, name: remote.name, color: remote.color)
            nb.coverPattern = remote.coverPattern
            nb.coverImagePath = coverImagePath
            nb.syncStatus = 1
            modelContext.insert(nb)
            if let settings = remote.settings {
                let projection = NotebookSettingsProjection(notebookId: remote.id)
                projection.applyRemote(settings)
                modelContext.insert(projection)
            }
            if persist(modelContext, toastCoordinator) {
                toastCoordinator.success("已建立".localized)
            } else {
                // remote 已建立但本地存檔失敗：model 已 insert，先退回無封面再清 staged 檔，
                // 避免之後任一次成功 save 持久化指向已刪檔的 dangling 路徑（#2428）。
                nb.coverImagePath = nil
                NotebookCoverCommit.discardStagedFile(staged: coverImagePath, original: nil)
            }
        } catch {
            // API 失敗：staged 封面沒有任何 owner，立即清掉避免孤兒檔（#2428）。
            NotebookCoverCommit.discardStagedFile(staged: coverImagePath, original: nil)
            toastCoordinator.error("建立失敗".localized)
            AppLog.kg.error("createNotebook failed: \(error.localizedDescription)")
        }
    }

    func updateNotebook(
        _ notebook: Notebook,
        name: String,
        color: String?,
        coverPattern: String?,
        stagedCoverImagePath: String?,
        originalCoverImagePath: String?,
        modelContext: ModelContext,
        kgService: any NotebookServing,
        toastCoordinator: AppToastCoordinator
    ) async {
        do {
            let remote = try await kgService.updateNotebook(id: notebook.remoteId, name: name, color: color, coverPattern: coverPattern)
            notebook.name = remote.name
            notebook.color = remote.color
            notebook.coverPattern = remote.coverPattern
            // 封面圖是 device-local（不上 server / 不參與 reconcile）。只有 API 成功後
            // 才落地新封面 + 刪舊圖 → 與 server 欄位的成敗一致（track-23，全有或全無）。
            let coverPlan = NotebookCoverCommit.plan(staged: stagedCoverImagePath, original: originalCoverImagePath)
            notebook.coverImagePath = coverPlan.resolvedPath
            notebook.updatedAt = Date()
            if modelContext.safeSaveWithToast(toastCoordinator) {
                NotebookCoverCommit.removeStaleFile(coverPlan)
                toastCoordinator.success("已更新".localized)
            } else {
                // 存檔失敗：model 退回原封面，staged 新圖無 owner → 清掉（#2731）。
                notebook.coverImagePath = originalCoverImagePath
                NotebookCoverCommit.discardStagedFile(staged: stagedCoverImagePath, original: originalCoverImagePath)
            }
        } catch {
            // API 失敗：不動 coverImagePath、不刪舊圖；sheet 在非同步存檔前已 dismiss，
            // Cancel 清理不會執行 → staged 新圖在此清掉（#2731）。server 欄位與本地封面
            // 同時維持舊值，無 drift。
            NotebookCoverCommit.discardStagedFile(staged: stagedCoverImagePath, original: originalCoverImagePath)
            toastCoordinator.error("更新失敗".localized)
            AppLog.kg.error("updateNotebook failed: \(error.localizedDescription)")
        }
    }

    func deleteNotebook(
        _ notebook: Notebook,
        isActive: Bool,
        availableNotebooks: [Notebook],
        allEntries: [VocabularyEntry],
        modelContext: ModelContext,
        kgService: any KGServing,
        toastCoordinator: AppToastCoordinator,
        setActiveNotebook: (String) -> Void
    ) async {
        let deletedId = notebook.remoteId
        do {
            // local-only / 未同步本子在 server 上沒有對應紀錄，呼叫 server delete 會 404
            // 並讓整個刪除 throw → 本地永遠刪不掉（孤兒 local-* 預設本即此類）。
            // 直接跳過 server、只做本地刪除。
            let isLocalOnly = deletedId.hasPrefix("local-") || notebook.syncStatus == 0
            if !isLocalOnly {
                try await kgService.deleteNotebook(id: deletedId)
            }

            NotebookReconciler.cascadeDeleteEntries(
                matching: [deletedId],
                allEntries: allEntries,
                modelContext: modelContext
            )

            if isActive, let fallback = Self.resolveFallbackNotebookId(
                excluding: deletedId,
                from: availableNotebooks
            ) {
                setActiveNotebook(fallback)
            }
            notebook.isSoftDeleted = true
            notebook.updatedAt = Date()
            if let settings = (try? modelContext.fetch(
                FetchDescriptor<NotebookSettingsProjection>()
            ))?.first(where: { $0.notebookId == deletedId }) {
                modelContext.delete(settings)
            }

            // Hard guarantee mirror of the reconcile-path UserDefaults cleanup:
            // even if `setActiveNotebook` was a no-op (caller injection 不保證寫入)
            // 或 `resolveFallbackNotebookId` 回傳 nil（only-notebook edge case），
            // 直接清掉指向 deletedId 的 stale activeNotebookId，避免 Book.resolvedNotebookId
            // 之後 fall through 到死 id。
            if ActiveNotebookStore.shared.activeNotebookIdIfSet == deletedId {
                ActiveNotebookStore.shared.clearStale()
            }

            if modelContext.safeSaveWithToast(toastCoordinator) {
                toastCoordinator.success("已刪除".localized)
            }
        } catch {
            toastCoordinator.error("刪除失敗".localized)
            AppLog.kg.error("deleteNotebook failed: \(error.localizedDescription)")
        }
    }

    /// 選擇 active notebook 的 fallback：isDefault 優先 → 第一個非刪除非自己 → nil（caller 應保留舊值）。
    static func resolveFallbackNotebookId(
        excluding deletedId: String,
        from notebooks: [Notebook]
    ) -> String? {
        let candidates = notebooks.filter { !$0.isSoftDeleted && $0.remoteId != deletedId }
        if let def = candidates.first(where: { $0.isDefault }) {
            return def.remoteId
        }
        return candidates.first?.remoteId
    }
}

private extension KGService {
    /// Use the credential captured by the selection task. The ordinary
    /// UserConfigServing method intentionally resolves the mutable current
    /// session, which is unsafe after an account switch.
    func updateVocabUIConfig(_ vocabUI: KGVocabUIConfig, using token: String) async throws -> KGUserConfig {
        guard connectivityGate.isConnected else { throw KGError.offline }
        let config = try await userConfigClient.updateVocabUIConfig(
            baseURL: baseURL,
            token: token,
            vocabUI: vocabUI
        )
        AppLog.kg.info("Updated vocab_ui (active notebook) config successfully")
        return config
    }
}
