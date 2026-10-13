#if os(iOS)
//
//  ReaderNotebookPicker.swift
//  Books & Vocab
//
//  閱讀器內選擇目標單字本 — 為當前書綁定或解除綁定 notebook

import SwiftUI
import SwiftData

struct ReaderNotebookPicker: View {
    @ObserveInjection private var inject
    @Bindable var book: Book

    @Query(
        filter: #Predicate<Notebook> { !$0.isSoftDeleted },
        sort: \Notebook.sortOrder
    )
    private var notebooks: [Notebook]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.toastCoordinator) private var toastCoordinator

    var body: some View {
        let presentation = ReaderNotebookPickerPresentation(layoutMode: LayoutMode(horizontalSizeClass: sizeClass))

        return NavigationStack {
            List {
                // Notebook 列表（每本書必綁定恰好一本真實單字本，不提供「跟隨全域」）
                NotebookBindingList(
                    notebooks: notebooks,
                    selectedNotebookId: book.preferredNotebookId,
                    onSelect: { notebook in
                        book.preferredNotebookId = notebook.remoteId
                        guard persistBookBinding(userInitiated: true) else { return }
                        dismiss()
                    }
                )
            }
            .frame(maxWidth: presentation.contentMaxWidth)
            .padding(.horizontal, presentation.horizontalPadding)
            .frame(maxWidth: .infinity)
            .background(theme.palette.pageBackground.ignoresSafeArea())
            .navigationTitle("選擇單字本".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成".localized) { dismiss() }
                        .font(AppFonts.subhead(weight: .semibold))
                }
            }
            .onAppear {
                sanitizeStaleBoundNotebook()
            }
        }
        .enableInjection()
    }

    /// 已刪除 notebook 防護：列表已 settle 且不含綁定 id 時才清除綁定（決策與 ReaderView 共用）。
    private func sanitizeStaleBoundNotebook() {
        let action = Book.sanitizeAction(
            bound: book.preferredNotebookId,
            liveNotebookIds: Set(notebooks.map(\.remoteId))
        )
        guard action == .clear else { return }
        book.preferredNotebookId = nil
        persistBookBinding()
    }

    /// 使用者主動選擇時失敗要 toast 並讓 sheet 保持開啟；onAppear 的清理維持靜默。
    @discardableResult
    private func persistBookBinding(userInitiated: Bool = false) -> Bool {
        let saved = userInitiated
            ? modelContext.safeSaveWithToast(toastCoordinator)
            : modelContext.safeSave()
        if saved {
            BookManifestStore().writeBestEffort(book: book)
        }
        return saved
    }
}
#endif
