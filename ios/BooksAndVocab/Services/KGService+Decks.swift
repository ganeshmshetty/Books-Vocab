//
//  KGService+Decks.swift
//  Books & Vocab
//
//  Explore 共享牌組寫入路徑（copy）。browse（唯讀 mirror）走
//  `SharedDeckCatalogService`；此檔只放需登入 CurrentUser 的寫入端點。
//

import Foundation
import SwiftData

extension KGService {

    /// `POST /api/decks/{deckId}/copy` —— 把官方牌組複製進呼叫者的私人 Notebook。
    /// 需登入（走 `authenticatedDecode` 帶 bearer；guest / 過期 token → 401 → unauthorized）。
    /// server 端已有 per-user 鎖 + copy_log 冪等：同 `idempotencyKey` retry 回同一 notebook。
    func copyDeck(
        deckId: String,
        idempotencyKey: String,
        notebookName: String? = nil
    ) async throws -> DeckCopyResponse {
        var body: [String: String] = ["idempotencyKey": idempotencyKey]
        if let notebookName {
            let trimmed = notebookName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { body["notebookName"] = trimmed }
        }
        return try await authenticatedDecode(
            DeckCopyResponse.self,
            path: "api/decks/\(deckId)/copy",
            method: "POST",
            body: try JSONEncoder().encode(body),
            // Copy is server-side idempotent by idempotencyKey, so a transport
            // retry is safe — but the endpoint mutates (creates a notebook), so
            // keep the request's own retry policy off and let the CALLER retry
            // with the SAME key (SharedDeckCopyController holds a stable key).
            retryPolicy: .none
        )
    }

    // MARK: - Post-copy targeted pull (2c-2)

    /// After a successful copy, bring the new notebook + its cards local NOW so the
    /// user can review immediately (rather than waiting for the next backgroundSync).
    /// Self-defending — never throws: any failure just logs, and the copied cards
    /// still arrive on the next full sync (their fresh `updated_at` clears the
    /// server-side incremental boundary). Reuses the existing sync infrastructure:
    /// `fetchNotebooks` + `NotebookReconciler` for the notebook row, and
    /// `BackgroundSyncActor.pullCardsToLocal` for the cards.
    ///
    /// Returns `true` iff the authoritative notebook reconcile completed. That is the only
    /// evidence that a notebook absent locally is really gone on the server (#2748). The
    /// card pull is excluded on purpose: a deleted notebook has no cards to fetch, so a
    /// card-pull failure must not block retiring a genuinely deleted copy.
    @discardableResult
    func pullCopiedDeck(container: ModelContainer, notebookId: String) async -> Bool {
        let reconciled = await landCopiedNotebook(container: container)
        do {
            let cards = try await fetchNotebookCards(notebookId: notebookId)
            try await Self.mergeNotebookScopedCards(cards, notebookId: notebookId, container: container)
            AppLog.kg.info("[Explore] post-copy pull merged \(cards.count) cards into notebook \(notebookId)")
        } catch {
            AppLog.kg.warning("[Explore] post-copy card pull failed for \(notebookId): \(error.localizedDescription)")
        }
        return reconciled
    }

    /// Land the freshly-copied notebook as a local `Notebook` row via an
    /// AUTHORITATIVE full notebook reconcile (the same path `NotebookListView` runs
    /// on appear — `fetchNotebooks` is the complete list, so reconcile's tombstone
    /// pass is safe). This reuses `NotebookReconciler.reconcile`'s field mapping +
    /// provenance stamping rather than duplicating a bespoke upsert.
    /// Returns whether the reconcile completed (false on fetch or store failure).
    @MainActor
    private func landCopiedNotebook(container: ModelContainer) async -> Bool {
        do {
            let remote = try await fetchNotebooks()
            let context = container.mainContext
            let localNotebooks = try context.fetch(FetchDescriptor<Notebook>())
            let allEntries = try context.fetch(FetchDescriptor<VocabularyEntry>())
            let removed = NotebookReconciler.reconcile(
                remote: remote, local: localNotebooks, allEntries: allEntries, modelContext: context
            )
            if let active = ActiveNotebookStore.shared.activeNotebookIdIfSet, removed.contains(active) {
                ActiveNotebookStore.shared.clearStale()
            }
            context.safeSave()
            return true
        } catch {
            AppLog.kg.warning("[Explore] post-copy notebook reconcile failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Notebook-scoped FULL fetch (no `since`), drained across every page so a
    /// copied deck larger than one server page lands whole. Deliberately
    /// notebook-scoped and boundary-free — see `mergeNotebookScopedCards`.
    private func fetchNotebookCards(notebookId: String) async throws -> [KGCard] {
        try await fetchAllVocabPages(query: [URLQueryItem(name: "notebook_id", value: notebookId)]).cards
    }

    /// Merge notebook-scoped copied cards into local SwiftData as SYNCED rows.
    ///
    /// Two load-bearing choices, both deliberate:
    /// - **`isIncremental: true`** → SKIP orphan cleanup. A notebook-scoped fetch is
    ///   NOT authoritative for the whole store, so the orphan reap (which would
    ///   delete every local synced card absent from this one notebook's page) must
    ///   never run here.
    /// - **Never touches `SyncKeys.incrementalBoundary`.** A notebook-scoped pull
    ///   must never advance the GLOBAL boundary, or the next full incremental sync
    ///   would skip other notebooks' server-side changes made since the old
    ///   boundary. `KGService.pullCardsToLocal(notebookId:)` routes every
    ///   notebook-scoped pull (AddLink's projection) here for the same reason (#2102).
    ///
    /// Static + card-injected so the merge is unit-testable without a network stack.
    @discardableResult
    static func mergeNotebookScopedCards(
        _ fetchedCards: [KGCard],
        notebookId: String,
        container: ModelContainer,
        progress: @Sendable @escaping (String, Int, Int) -> Void = { _, _, _ in }
    ) async throws -> BackgroundSyncActor.PullResult {
        let actor = BackgroundSyncActor(modelContainer: container)
        return try await actor.pullCardsToLocal(
            fetchedCards: fetchedCards,
            isIncremental: true,
            progress: progress,
            notebookId: notebookId
        )
    }
}
