#if os(iOS)
import SwiftUI
import SwiftData

/// 播客系列選擇目標單字本 — 為當前系列綁定 notebook。
///
/// 一個 podcast 系列只歸屬恰好一本單字本：選詞 / 底線 / cache 一律認此綁定。
/// 與 ReaderNotebookPicker 共用 `NotebookBindingList`；綁定為本機偏好，持久化只需
/// save（server 不下發 preferredNotebookId，reconcile upsert 不覆寫）。
struct PodcastNotebookPicker: View {
    @ObserveInjection private var inject
    @Bindable var series: PodcastSeries

    @Query(
        filter: #Predicate<Notebook> { !$0.isSoftDeleted },
        sort: \Notebook.sortOrder
    )
    private var notebooks: [Notebook]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTheme) private var theme
    @Environment(\.toastCoordinator) private var toastCoordinator

    var body: some View {
        NavigationStack {
            List {
                NotebookBindingList(
                    notebooks: notebooks,
                    selectedNotebookId: series.preferredNotebookId,
                    onSelect: { notebook in
                        series.preferredNotebookId = notebook.remoteId
                        guard modelContext.safeSaveWithToast(toastCoordinator) else { return }
                        dismiss()
                    }
                )
            }
            .background(theme.palette.pageBackground.ignoresSafeArea())
            .navigationTitle("選擇單字本".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成".localized) { dismiss() }
                        .font(AppFonts.subhead(weight: .semibold))
                }
            }
            .onAppear { sanitizeStaleBoundNotebook() }
        }
        .enableInjection()
    }

    /// 綁定的 notebook 已刪除 → 清除綁定（下次播放器開啟會 re-seed）。
    /// 只在清單已 settle 時清除；只有 clear 分支才寫入（keep 不寫）。
    private func sanitizeStaleBoundNotebook() {
        guard let boundId = series.preferredNotebookId else { return }
        let liveIds = Set(notebooks.map(\.remoteId))
        guard PodcastSeries.sanitizeAction(bound: boundId, liveNotebookIds: liveIds) == .clear else { return }
        series.preferredNotebookId = nil
        _ = modelContext.safeSave()
    }
}
#endif
