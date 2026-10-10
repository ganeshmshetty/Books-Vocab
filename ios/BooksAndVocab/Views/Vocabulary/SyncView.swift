//
//  SyncView.swift
//  Books & Vocab
//
//  Thin sync scene container — environment/query wiring only.
//

import SwiftUI
import SwiftData

struct SyncView: View {
    @ObserveInjection private var inject
    @Environment(\.modelContext) private var modelContext
    @Environment(\.kgService) private var kgService
    @Environment(\.authManager) private var authManager
    @Environment(\.toastCoordinator) private var toastCoordinator
    @Query(filter: #Predicate<VocabularyEntry> { $0.syncStatus != 1 })
    private var pendingEntries: [VocabularyEntry]

    @Environment(\.syncCoordinator) private var coordinator
    @State private var showSettings = false
    @State private var pendingDeleteID: UUID?

    var body: some View {
        NavigationStack {
            SyncPresenter(
                state: presenterState,
                onPrimaryAction: handlePrimaryAction,
                onCancel: coordinator.cancelSync,
                onShowSettings: { showSettings = true },
                onPendingRowTapped: handlePendingRowTap,
                onPendingActionTapped: handlePendingActionTap
            )
            .settingsSheet(isPresented: $showSettings)
            .task {
                refreshStepLayoutIfIdle()
            }
            .onChange(of: pendingEntries.count) { _, _ in
                refreshStepLayoutIfIdle()
            }
            .alert(
                "移除此待收錄單字？".localized,
                isPresented: Binding(
                    get: { pendingDeleteID != nil },
                    set: { if !$0 { pendingDeleteID = nil } }
                )
            ) {
                Button("取消".localized, role: .cancel) { pendingDeleteID = nil }
                Button("移除".localized, role: .destructive) { confirmPendingDelete() }
            } message: {
                Text("尚未同步到雲端，移除後無法復原。".localized)
            }
        }
        .enableInjection()
    }

    private var presenterState: SyncPresenterState {
        let filtered = pendingEntries.filter { $0.syncAction != .delete || $0.shouldUploadOnNextSync }
        return SyncPresenterState(
            isLoggedIn: authManager.isLoggedIn,
            isConnected: kgService.isConnected,
            phase: coordinator.phase,
            failureKind: coordinator.failureKind,
            pendingCount: pendingEntries.count,
            addCount: addActions.count,
            deleteCount: deleteActions.count,
            steps: coordinator.steps,
            summaryText: coordinator.summaryText,
            pendingRows: filtered.map { entry in
                SyncPresenterState.RowItem(
                    id: entry.id,
                    row: entry.wordRowViewData(),
                    actionSystemImage: entry.syncAction == .delete ? "arrow.uturn.backward.circle" : "trash",
                    actionTone: entry.syncAction == .delete ? .secondary : .tertiary,
                    actionAccessibilityLabel: entry.syncAction == .delete
                        ? L10n.string("sync.pending.undoDelete")
                        : L10n.string("sync.pending.cancelAdd")
                )
            }
        )
    }

    private var deleteActions: [VocabularyEntry] {
        pendingEntries.filter { $0.syncAction == .delete && $0.shouldUploadOnNextSync }
    }

    private var addActions: [VocabularyEntry] {
        pendingEntries.filter { $0.syncAction == .add && $0.shouldUploadOnNextSync }
    }

    private func handlePrimaryAction() {
        switch coordinator.phase {
        case .ready:
            coordinator.startSync(
                pendingEntries: pendingEntries,
                modelContext: modelContext,
                kgService: kgService
            )
        case .failed:
            refreshStepLayout()
        case .completed, .running:
            break
        }
    }

    private func handlePendingRowTap(_ entryID: UUID) {
        // In SyncView we don't navigate to detail — just a visual acknowledgement
    }

    private func handlePendingActionTap(_ entryID: UUID) {
        guard let entry = pendingEntries.first(where: { $0.id == entryID }) else { return }
        if entry.syncAction == .delete {
            entry.markSynced()
            modelContext.safeSaveWithToast(toastCoordinator)
        } else {
            // .add pending 是尚未上雲的 local-only 資料，硬刪後無法復原 → 先確認
            pendingDeleteID = entryID
        }
    }

    private func confirmPendingDelete() {
        defer { pendingDeleteID = nil }
        guard let id = pendingDeleteID,
              let entry = pendingEntries.first(where: { $0.id == id }) else { return }
        modelContext.delete(entry)
        modelContext.safeSaveWithToast(toastCoordinator)
    }

    private func refreshStepLayout() {
        coordinator.resetForRetry(
            deleteCount: deleteActions.count,
            addCount: addActions.count
        )
    }

    private func refreshStepLayoutIfIdle() {
        guard coordinator.phase != .running else { return }
        refreshStepLayout()
    }
}

#Preview("SyncView / Ready") {
    AppThemeContainer {
        SyncView()
            .modelContainer(for: [VocabularyEntry.self, Notebook.self], inMemory: true)
    }
    .environmentObject(AppAppearanceStore.preview)
}
