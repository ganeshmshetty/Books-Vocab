//
//  NotebookEditSheet.swift
//  Books & Vocab
//
//  新建 / 編輯單字本的 sheet

import SwiftUI
import PhotosUI

struct NotebookAppearance {
    let name: String
    let color: String?
    let coverPattern: String?
    /// 使用者在 sheet 內選定的封面路徑（staged，nil = 移除封面）。
    let coverImagePath: String?
    /// 進入編輯前的原始封面路徑。封面落地 + 舊檔刪除延到 API 成功後，由
    /// coordinator 用此值算出該刪哪個舊檔（全有或全無，避免 drift）。
    let originalCoverImagePath: String?
}

/// 封面選擇器（色票／圖樣）的觸控與無障礙契約。視覺尺寸由各選項自己決定，
/// 這裡只保證可點區域達 HIG 下限，並集中「選中」語意讓測試可釘。
enum NotebookEditPickerMetrics {
    /// HIG 觸控下限；沿用 chrome 既有常數，不另開第二個 44。
    static let hitTarget = AppFloatingChromeMetrics.hitTarget
    /// 色票圓點的視覺直徑（命中區由 `hitTarget` 另外撐開）。
    static let swatchDiameter: CGFloat = 32

    /// 選項在 a11y 樹的附加 trait。`Button` 已自帶 isButton，這裡只補選中狀態。
    static func accessibilityTraits(isSelected: Bool) -> AccessibilityTraits {
        isSelected ? .isSelected : []
    }
}

/// Save 按鈕的可用條件。處理照片中禁止 Save：否則 staged 封面會在 processPhoto 仍在寫檔時
/// 交給 onSave，之後 processPhoto 會刪掉已交出的檔並留下孤兒新檔（#3498）。
enum NotebookEditSaveGate {
    static func isSaveEnabled(name: String, isProcessingPhoto: Bool) -> Bool {
        !isProcessingPhoto && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct NotebookEditSheet: View {
    @ObserveInjection private var inject
    enum Mode {
        case create
        case edit(name: String, color: String?, coverPattern: String?, coverImagePath: String?)
    }

    let mode: Mode
    let onSave: (NotebookAppearance) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appSkin) private var skin

    @State private var name: String = ""
    @State private var selectedColor: String?
    @State private var selectedPattern: String?
    @State private var coverImagePath: String?
    private let originalCoverImagePath: String?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isProcessingPhoto = false
    @State private var photoError: String?
    /// staged 封面已交給 onSave（所有權轉給 coordinator）；未設為 true 時關閉即須清掉 staged 檔（#3414）。
    @State private var isCommitted = false
    /// sheet 已關閉；processPhoto 若在關閉後才寫出檔案，必須立即清掉（#3414）。
    @State private var isDismissed = false

    init(mode: Mode, onSave: @escaping (NotebookAppearance) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _selectedColor = State(initialValue: nil)
            _selectedPattern = State(initialValue: nil)
            _coverImagePath = State(initialValue: nil)
            self.originalCoverImagePath = nil
        case .edit(let n, let c, let p, let img):
            _name = State(initialValue: n)
            _selectedColor = State(initialValue: c)
            _selectedPattern = State(initialValue: p)
            _coverImagePath = State(initialValue: img)
            self.originalCoverImagePath = img
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NotebookCoverView(
                        color: NotebookPalette.color(for: selectedColor),
                        pattern: selectedPattern.flatMap { NotebookCoverPattern(rawValue: $0) },
                        coverImagePath: coverImagePath,
                        name: name.isEmpty ? NotebookEditCopy.previewTitle : name
                    )
                    .frame(height: 100)
                    .clipShape(AppRoundedRect(roundness: skin.roundness.card))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section {
                    TextField(NotebookEditCopy.namePlaceholder, text: $name)
                        .onChange(of: name) { _, new in
                            let clamped = NotebookEditCopy.clampedName(new)
                            if clamped != new { name = clamped }
                        }
                }

                Section(NotebookEditCopy.colorSectionTitle) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: NotebookEditPickerMetrics.hitTarget), spacing: 0)],
                        spacing: 0
                    ) {
                        ForEach(NotebookPalette.colors, id: \.hex) { item in
                            let isSelected = selectedColor == item.hex
                            Button {
                                selectedColor = item.hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: item.hex) ?? skin.palette.accent) // token-allow: notebook palette data color
                                    .frame(
                                        width: NotebookEditPickerMetrics.swatchDiameter,
                                        height: NotebookEditPickerMetrics.swatchDiameter
                                    )
                                    .overlay {
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(skin.typography.caption)
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .frame(
                                        minWidth: NotebookEditPickerMetrics.hitTarget,
                                        minHeight: NotebookEditPickerMetrics.hitTarget
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(NotebookPalette.localizedName(item.name))
                            .accessibilityAddTraits(NotebookEditPickerMetrics.accessibilityTraits(isSelected: isSelected))
                        }
                    }
                }

                Section(NotebookEditCopy.patternSectionTitle) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSpacing.s2) {
                            patternOption(nil, label: NotebookEditCopy.noPatternTitle)
                            ForEach(NotebookCoverPattern.allCases) { pattern in
                                patternOption(pattern.rawValue, label: pattern.label)
                            }
                        }
                        .padding(.vertical, AppSpacing.s1)
                    }
                }

                Section(NotebookEditCopy.customImageSectionTitle) {
                    HStack {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label(NotebookEditCopy.imagePickerTitle(hasImage: coverImagePath != nil), systemImage: "photo")
                        }

                        if coverImagePath != nil {
                            Spacer()
                            Button(role: .destructive) {
                                removeCoverImage()
                            } label: {
                                Label(NotebookEditCopy.removeImageTitle, systemImage: "trash")
                            }
                        }
                    }
                    .disabled(isProcessingPhoto)

                    if isProcessingPhoto {
                        ProgressView(NotebookEditCopy.processingImageTitle)
                    }

                    if let photoError {
                        Text(photoError)
                            .font(skin.typography.caption)
                            .foregroundStyle(skin.palette.destructive)
                    }
                }
            }
            .navigationTitle(NotebookEditCopy.navigationTitle(isCreating: isCreating))
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 未保存的 staged 新檔由 onDisappear 統一清理（取消與下滑關閉共用同一路徑）
                    Button(NotebookEditCopy.cancelTitle) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NotebookEditCopy.saveTitle(isCreating: isCreating)) {
                        // 舊原檔的刪除延到 updateNotebook API 成功後才做（見
                        // NotebookCoverCommit），失敗則原檔保留 + coverImagePath 不變，
                        // 避免「新封面 + server 舊欄位」drift（track-23）。
                        isCommitted = true
                        onSave(NotebookAppearance(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            color: selectedColor,
                            coverPattern: selectedPattern,
                            coverImagePath: coverImagePath,
                            originalCoverImagePath: originalCoverImagePath
                        ))
                        dismiss()
                    }
                    .disabled(!NotebookEditSaveGate.isSaveEnabled(name: name, isProcessingPhoto: isProcessingPhoto))
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await processPhoto(item) }
            }
            // 處理中禁止下滑關閉，避免關閉與寫檔交錯（#3414）
            .interactiveDismissDisabled(isProcessingPhoto)
        }
        .appSheet(.large)
        .onDisappear {
            isDismissed = true
            NotebookCoverCommit.discardUncommittedStaged(
                staged: coverImagePath,
                original: originalCoverImagePath,
                committed: isCommitted
            )
        }
        .enableInjection()
    }

    @ViewBuilder
    private func patternOption(_ patternId: String?, label: String) -> some View {
        let isSelected = selectedPattern == patternId
        let color = NotebookPalette.color(for: selectedColor)
        Button {
            selectedPattern = patternId
        } label: {
            VStack(spacing: AppSpacing.s1) {
                ZStack {
                    AppRoundedRect(roundness: AppRoundness.control)
                        .fill(patternId == nil ? skin.palette.mutedFill : color)
                        .frame(width: 48, height: 36)
                    if let pid = patternId, let p = NotebookCoverPattern(rawValue: pid) {
                        p.patternOverlay(size: CGSize(width: 48, height: 36))
                            .clipShape(AppRoundedRect(roundness: AppRoundness.control))
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white)
                            .font(skin.typography.iconSmall)
                    }
                }
                Text(label)
                    .font(skin.typography.monoLabel)
                    .foregroundStyle(skin.palette.secondaryText)
            }
            .frame(minWidth: NotebookEditPickerMetrics.hitTarget, minHeight: NotebookEditPickerMetrics.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(NotebookEditPickerMetrics.accessibilityTraits(isSelected: isSelected))
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    @MainActor
    private func processPhoto(_ item: PhotosPickerItem) async {
        isProcessingPhoto = true
        photoError = nil
        defer { isProcessingPhoto = false }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            photoError = NotebookEditCopy.photoErrorMessage(.loadFailed)
            return
        }

        guard let uiImage = UIImage(data: data) else {
            photoError = NotebookEditCopy.photoErrorMessage(.unsupportedFormat)
            return
        }
        let maxDim: CGFloat = 600
        let scale = min(maxDim / uiImage.size.width, maxDim / uiImage.size.height, 1.0)
        let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resizedImage = renderer.image { _ in uiImage.draw(in: CGRect(origin: .zero, size: newSize)) }
        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.7) else {
            photoError = NotebookEditCopy.photoErrorMessage(.processingFailed)
            return
        }

        guard jpegData.count <= 500_000 else {
            photoError = NotebookEditCopy.photoErrorMessage(.fileTooLarge)
            return
        }

        let filename = "notebook_cover_\(UUID().uuidString).jpg"
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            photoError = NotebookEditCopy.photoErrorMessage(.saveFailed)
            return
        }
        let dir = documentsURL.appendingPathComponent("NotebookCovers", isDirectory: true)
        let fileURL = dir.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try jpegData.write(to: fileURL)
        } catch {
            photoError = NotebookEditCopy.photoErrorMessage(.saveFailed)
            return
        }
        // sheet 已 commit 或關閉（取消 / 存檔後才完成）：沒有 owner 會接手這個新檔，立即清掉（#3414、#3498）。
        // 必須在刪除前一個 staged / 指派 coverImagePath 之前判斷，已交給 onSave 的檔不可再被動到。
        if NotebookCoverCommit.shouldDiscardLateWrite(committed: isCommitted, dismissed: isDismissed) {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        // 清掉本次編輯中已 staged 的舊新檔（非 original），避免 orphan
        if let prev = coverImagePath, prev != originalCoverImagePath {
            try? FileManager.default.removeItem(atPath: prev)
        }
        coverImagePath = fileURL.path
        selectedPattern = nil
    }

    private func removeCoverImage() {
        // 只清掉 staged 新檔；originalCoverImagePath 延遲到 save 再刪
        if let path = coverImagePath, path != originalCoverImagePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        coverImagePath = nil
    }
}
