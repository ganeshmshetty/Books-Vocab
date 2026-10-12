import SwiftUI

struct WordEditSheet: View {
    @ObserveInjection private var inject
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appSkin) private var appSkin
    @Environment(\.toastCoordinator) private var toastCoordinator
    @Bindable var entry: VocabularyEntry
    var onSaved: (() -> Void)? = nil

    @State private var draftTranslation: String
    @State private var draftExplanation: String
    @State private var isSaving = false

    /// 草稿在 init 直接取自 entry：首幀即為真實值，不會以空白草稿渲染出「儲存」停用與驗證提示的閃爍。
    init(entry: VocabularyEntry, onSaved: (() -> Void)? = nil) {
        _entry = Bindable(wrappedValue: entry)
        self.onSaved = onSaved
        _draftTranslation = State(initialValue: entry.translation)
        _draftExplanation = State(initialValue: entry.explanation ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: appSkin.spacing.sectionGap) {
                    editSection(
                        title: "翻譯結果".localized,
                        text: $draftTranslation,
                        accessibilityIdentifier: "wordDetail.edit.translation"
                    )
                    editSection(
                        title: "教學筆記".localized,
                        text: $draftExplanation,
                        accessibilityIdentifier: "wordDetail.edit.explanation"
                    )
                    if !isDraftValid {
                        Text(L10n.string("翻譯需為 1 至 1000 字，教學筆記最多 5000 字"))
                            .font(appSkin.typography.caption)
                            .foregroundStyle(appSkin.palette.secondaryText)
                            .accessibilityIdentifier("wordDetail.edit.validation")
                    }
                }
                .padding(appSkin.spacing.cardPadding)
            }
            .vocabCanvasBackground()
            .navigationTitle(entry.word)
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消".localized) { dismiss() }
                        .accessibilityIdentifier("wordDetail.edit.cancel")
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("儲存".localized) { save() }
                            .accessibilityIdentifier("wordDetail.edit.save")
                            .fontWeight(.semibold)
                            .disabled(!isDraftValid)
                    }
                }
            }
        }
        .enableInjection()
    }

    private func editSection(
        title: String,
        text: Binding<String>,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.inlineGap) {
            Text(title)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.secondaryText)

            TextEditor(text: text)
                .font(appSkin.typography.body)
                .foregroundStyle(appSkin.palette.primaryText)
                .accessibilityIdentifier(accessibilityIdentifier)
                .scrollContentBackground(.hidden)
                .padding(appSkin.spacing.inlineGap)
                .frame(minHeight: 80)
                .background(
                    AppRoundedRect(roundness: AppShellMetrics.cardRoundness)
                        .fill(appSkin.palette.cardBackground)
                        .overlay(
                            AppRoundedRect(roundness: AppShellMetrics.cardRoundness)
                                .stroke(appSkin.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
        }
    }

    private var isDraftValid: Bool {
        (try? Self.validate(translation: draftTranslation, explanation: draftExplanation)) != nil
    }

    private func save() {
        guard isDraftValid else { return }
        isSaving = true

        do {
            try Self.commitEdit(
                entry: entry,
                translation: draftTranslation,
                explanation: draftExplanation,
                save: modelContext.save
            )
            onSaved?()
            dismiss()
        } catch {
            // 一次性失敗通知走頂端 pill；重試入口就是工具列上的「儲存」，草稿仍保留在表單裡，
            // 不需要另開面板。
            toastCoordinator.error(L10n.string("儲存失敗，請再試一次"))
            isSaving = false
        }
    }

    /// 與後端 `VocabContentUpdateRequest` 的欄位上限一致（meaning 1..1000、note ≤ 5000，
    /// 以 Unicode scalar 計，對齊 Pydantic `max_length`）。超出會被伺服器以 422 拒絕，
    /// 且同步引擎視為可重試，導致條目永久卡在 failed（#2548）。
    static let translationMaxLength = 1000
    static let noteMaxLength = 5000

    enum EditValidationError: Error, Equatable {
        case translationLength
        case noteLength
        /// 列正被同步擷取中：編輯會與送出中的內容競態（SyncLifecycle I3，#3248），拒絕儲存並保留草稿。
        case uploadInFlight
    }

    /// 與後端 Python `str.strip()` 的空白集合一致：`whitespacesAndNewlines` 再加 U+001C–U+001F
    /// （Python `isspace()` 為真、Swift 不含）。缺這四個 scalar 時，僅含分隔符的輸入會通過客端、被後端 422 拒收（#2548）。
    private static var backendStripCharacters: CharacterSet {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(CharacterSet(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}"))
        return set
    }

    /// 以 trim 後的值驗證；與 `commitEdit` 送進 entry 的值完全相同。
    static func validate(translation: String, explanation: String) throws -> (translation: String, explanation: String?) {
        let trimmedTranslation = translation.trimmingCharacters(in: backendStripCharacters)
        let trimmedExplanation = explanation.trimmingCharacters(in: backendStripCharacters)

        let translationLength = trimmedTranslation.unicodeScalars.count
        guard (1...translationMaxLength).contains(translationLength) else {
            throw EditValidationError.translationLength
        }
        guard trimmedExplanation.unicodeScalars.count <= noteMaxLength else {
            throw EditValidationError.noteLength
        }
        return (trimmedTranslation, trimmedExplanation.isEmpty ? nil : trimmedExplanation)
    }

    /// 套用編輯並呼叫 `save`；失敗時把 entry 還原成編輯前的值再 rethrow，
    /// 否則記憶體裡的未存檔變更會被後續任何 save 悄悄寫入（#2732）。
    /// 驗證失敗時在任何變更前就 throw，entry 與 `save` 都不會被碰。
    static func commitEdit(
        entry: VocabularyEntry,
        translation: String,
        explanation: String,
        save: () throws -> Void
    ) throws {
        let validated = try validate(translation: translation, explanation: explanation)
        // 同步擷取期間的列不可改寫：送出中的回應會以送出內容收斂，改寫會被靜默覆蓋（#3248）。
        guard !entry.isUploadInFlight else { throw EditValidationError.uploadInFlight }

        let original = (
            translation: entry.translation,
            explanation: entry.explanation,
            explanationClearPending: entry.explanationClearPending,
            syncAction: entry.syncAction,
            syncState: entry.syncState,
            rejectedReason: entry.rejectedReason
        )

        entry.translation = validated.translation
        if let explanation = validated.explanation {
            entry.explanation = explanation
            entry.explanationClearPending = false
        } else {
            // 清空只在伺服器可能持有 note 時升級為明確清空（送 ""，#2550）；本地從未持有 note 時仍是「未變更」，
            // 因為 nil 代表未知（可能尚未 pull），不是已知的空。
            entry.explanationClearPending = entry.hasServerCard
                && (original.explanation != nil || original.explanationClearPending)
            entry.explanation = nil
        }

        // 終態拒收的 edit 不會被 sync 重新排入，必須由這裡重新排入（T12，#3207）。
        if entry.isSynced || entry.isRejectedEdit {
            entry.queueEdit()
        }

        do {
            try save()
        } catch {
            entry.translation = original.translation
            entry.explanation = original.explanation
            entry.explanationClearPending = original.explanationClearPending
            entry.syncAction = original.syncAction
            entry.syncState = original.syncState
            entry.rejectedReason = original.rejectedReason
            throw error
        }
    }
}
