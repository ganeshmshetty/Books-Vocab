import SwiftUI
import SwiftData

struct WordDetailSheet: View {
    @ObserveInjection private var inject
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.kgService) private var kgService
    @Environment(\.detailRouter) private var detailRouter
    @Environment(\.toastCoordinator) private var toastCoordinator
    @State private var state = WordDetailSceneState()
    @State private var localLinkedCardStack: [VocabularyEntry] = []
    @State private var isEditing = false
    @State private var showAddLink = false
    @State private var pendingLinkDetail: PendingLinkDetailRequest?
    @State private var isConfirmingDelete = false

    // Long-lived owner of link creations: read so the pending rows follow the jobs
    // (appear, fail, turn into real links) even while this sheet stays open.
    private let creationHub = AddLinkCreationHub.shared

    @Bindable var entry: VocabularyEntry
    let allEntries: [VocabularyEntry]
    private let wrapInNavigation: Bool
    private let showsInlineChrome: Bool
    /// `nil` = 沿用 `showsInlineChrome`（app 內所有宿主）。只有截圖／行銷這種
    /// 需要「有 chrome 但不入鏡生命週期動作」的呈現路徑才顯式指定。
    private let explicitLifecycleActions: Bool?
    private let onInlineClose: (() -> Void)?
    private let externalLinkedCardStack: Binding<[VocabularyEntry]>?

    init(
        entry: VocabularyEntry,
        allEntries: [VocabularyEntry] = [],
        wrapInNavigation: Bool = true,
        showsInlineChrome: Bool? = nil,
        showsLifecycleActions: Bool? = nil,
        onClose: (() -> Void)? = nil,
        linkedCardStack: Binding<[VocabularyEntry]>? = nil,
        presentsEagerly: Bool = false
    ) {
        self.entry = entry
        self.allEntries = allEntries
        self.wrapInNavigation = wrapInNavigation
        self.showsInlineChrome = showsInlineChrome ?? wrapInNavigation
        self.explicitLifecycleActions = showsLifecycleActions
        self.onInlineClose = onClose
        self.externalLinkedCardStack = linkedCardStack
        // Catalog / snapshot seam: seed the presentation synchronously so a
        // `layer.render(in:)` snapshot captures the card, not the loading
        // placeholder the deferred `.task` would still be showing. The live app
        // keeps `presentsEagerly == false` and its brief loading→card fade.
        if presentsEagerly {
            let seeded = WordDetailSceneState()
            seeded.refreshPresentation(for: entry, in: allEntries)
            _state = State(initialValue: seeded)
        }
    }

    var body: some View {
        Group {
            if let presenterState = state.presenterState {
                WordDetailPresenter(
                    state: presenterState,
                    isArchived: entry.isArchived,
                    canArchive: entry.isSynced,
                    isReaderHidden: entry.isReaderHidden,
                    isReviewExcluded: entry.isReviewExcluded,
                    canEditCardPreferences: entry.isSynced && cardPreferenceService != nil,
                    showsCardManagement: offersLifecycleActions,
                    showsChrome: showsInlineChrome,
                    onClose: showsInlineChrome ? { handleClose() } : nil,
                    onEdit: { isEditing = true },
                    onLinkTapped: handleLinkTap,
                    onToggleArchive: offersLifecycleActions ? { handleToggleArchive() } : nil,
                    onDelete: offersLifecycleActions ? { isConfirmingDelete = true } : nil,
                    onToggleReaderHidden: offersLifecycleActions ? { handleToggleReaderHidden() } : nil,
                    onToggleReviewExcluded: offersLifecycleActions ? { handleToggleReviewExcluded() } : nil,
                    onAddLink: { showAddLink = true },
                    onDeleteLink: { link in
                        state.deleteLink(link, from: entry, allEntries: allEntries, kgService: kgService)
                    },
                    onHideLink: { link in
                        state.hideLink(link, from: entry, allEntries: allEntries, kgService: kgService)
                    },
                    onUnhideLink: { link in
                        state.unhideLink(link, from: entry, allEntries: allEntries, kgService: kgService)
                    },
                    onPendingLinkTapped: { pendingLinkDetail = PendingLinkDetailRequest(link: $0) }
                )
            } else {
                VocabStateMessageCard(
                    title: "載入中".localized,
                    systemImage: "doc.text"
                ) {
                    ProgressView()
                        .controlSize(.small)
                }
                .padding()
            }
        }
        .animation(AppMotion.contentFade, value: state.presenterState != nil)
        // 卡片動作失敗（封存／偏好／連結回捲）是一次性通知：轉成頂端 pill 後即消化，
        // 下一次同類失敗才會再觸發。重做動作的入口本來就在卡片上，不需要面板。
        .onChange(of: state.actionError) { _, message in
            guard let message else { return }
            toastCoordinator.error(message)
            state.dismissActionError()
        }
        .task(id: "\(entry.id)|\(entry.graphLinksJSON.hashValue)") {
            // Yield once so SwiftUI can render the loading placeholder before
            // we run the (lightweight but synchronous) presentation computation.
            await Task.yield()
            state.refreshPresentation(for: entry, in: allEntries)
        }
        .task {
            // Same re-attach as the review screen: a pending link restored from disk
            // gets its context back here too, so its retry works from this sheet.
            creationHub.resume(kgService: kgService, container: modelContext.container)
        }
        .onChange(of: creationHub.revision) { _, _ in
            // A pending link appeared, failed, or became a real one: rebuild the
            // presentation (the id-keyed task above only watches the graph JSON).
            guard state.presenterState != nil else { return }
            state.refreshPresentation(for: entry, in: allEntries)
        }
        .overlay {
            if shouldUseLinkedOverlayStack {
                LinkedCardOverlayStack(stack: linkedCardStack, allEntries: allEntries)
            }
        }
        .toastSheet(isPresented: $isEditing) {
            WordEditSheet(
                entry: entry,
                onSaved: { state.refreshPresentation(for: entry, in: allEntries) }
            )
        }
        .confirmationDialog(
            WordDetailCopy.deleteTitle(word: entry.word),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(WordDetailCopy.delete, role: .destructive) { handleDelete() }
            Button(WordDetailCopy.cancel, role: .cancel) {}
        } message: {
            Text(WordDetailCopy.deleteMessage(linkCount: state.presenterState?.card.totalLinkCount ?? 0))
        }
        .toastSheet(isPresented: $showAddLink) {
            AddLinkSheet(
                sourceEntry: entry,
                allEntries: allEntries,
                onLinked: { state.refreshPresentation(for: entry, in: allEntries) }
            )
        }
        .toastSheet(item: $pendingLinkDetail) { request in
            PendingLinkDetailSheet(link: request.link)
                .appSheet(.medium)
        }
        .enableInjection()
    }

    private var linkedCardStack: Binding<[VocabularyEntry]> {
        externalLinkedCardStack ?? $localLinkedCardStack
    }

    /// 四項卡片控制只在「本 sheet 自己擁有 chrome」的宿主出現，避免 linked overlay
    /// 重複提供會改變卡片生命週期的入口。
    ///
    /// 唯一 `showsInlineChrome == false` 的宿主是 `LinkedCardOverlayStack`——它自繪
    /// header，不應在「點連結進來看一眼」的疊層中混入四個管理控制。要管理卡片，正常
    /// 開啟它即可。
    ///
    /// `showsLifecycleActions` 是唯一的例外閥門，給截圖／行銷這種「要 chrome、不要
    /// 管理控制列入鏡」的呈現路徑用；不傳就是上面那條推導，app 內行為不變。
    private var offersLifecycleActions: Bool { explicitLifecycleActions ?? showsInlineChrome }

    private var cardPreferenceService: (any CardPreferenceUpdating)? {
        kgService as? any CardPreferenceUpdating
    }

    private var shouldUseLinkedOverlayStack: Bool {
        // 有外部 stack binding 時，overlay 由外部 LinkedCardOverlayStack 管理，不重複渲染
        guard externalLinkedCardStack == nil else { return false }
        return wrapInNavigation || detailRouter == nil
    }

    /// 封存後**刻意不關 sheet**：圖示翻成 `archivebox.fill`，再按一次就是解除封存。
    /// toggle 自己就是 undo，所以不需要帶動作按鈕的 undo toast（pill 依規範不放按鈕）。
    /// 失敗訊息由 `actionError` 轉成頂端 error pill（見 body 的 `onChange`）。
    private func handleToggleArchive() {
        // 重入防護在 `WordDetailSceneState.isSettingArchived`，不在這裡：放狀態物件才
        // 涵蓋所有呼叫端，view 端再複製一份只會變成兩個要一起推理的旗標。
        Task { @MainActor in
            await state.setArchived(
                !entry.isArchived,
                for: entry,
                kgService: kgService,
                modelContext: modelContext
            )
        }
    }

    private func handleToggleReaderHidden() {
        guard let cardPreferenceService else { return }
        Task { @MainActor in
            await state.setCardPreferences(
                readerHidden: !entry.isReaderHidden,
                reviewExcluded: nil,
                for: entry,
                kgService: cardPreferenceService,
                modelContext: modelContext
            )
        }
    }

    private func handleToggleReviewExcluded() {
        guard let cardPreferenceService else { return }
        Task { @MainActor in
            await state.setCardPreferences(
                readerHidden: nil,
                reviewExcluded: !entry.isReviewExcluded,
                for: entry,
                kgService: cardPreferenceService,
                modelContext: modelContext
            )
        }
    }

    /// 刪除是 local-first 軟刪（`queueDelete` 排進 outbox，離線可用），與封存的
    /// server-authoritative 語意相反 —— 所以這裡不需要回捲，但需要關掉 sheet：
    /// 讓使用者盯著一張已經不存在的卡是最糟的收尾。
    ///
    /// **未同步的卡要硬刪、不能排 outbox**（形狀照 `VocabularyContextStore.deleteEntry`）：
    /// `queueDelete` 只是把 syncAction 標成 delete 等下次同步推上去，但伺服器上根本沒有
    /// 這張卡，那次呼叫必然打空。雖然 `SyncCoordinator` 的 `not_found` 分支最後會收斂，
    /// 中間卻留著一筆假的「待刪除」掛在 outbox（SyncView 看得見），離線時無限期滯留。
    /// 本檔的封存路徑已經對 `isSynced` 做過同一個判斷（`canArchive`），不可逆的這一半
    /// 沒有理由不做。
    private func handleDelete() {
        entry.deleteLocally(in: modelContext)
        guard modelContext.safeSaveWithToast(toastCoordinator) else { return }
        toastCoordinator.success(WordDetailCopy.deleted)
        handleClose()
    }

    private func handleClose() {
        if let onInlineClose {
            onInlineClose()
        } else {
            dismiss()
        }
    }

    private func handleLinkTap(_ link: KGCardLinkSummary) {
        guard let target = state.linkedEntry(for: link, from: entry, in: allEntries) else { return }
        if !wrapInNavigation, let detailRouter {
            detailRouter.showWordDetail(target, allEntries: allEntries)
            return
        }
        linkedCardStack.wrappedValue.append(target)
    }
}
