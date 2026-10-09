#if os(iOS)
import SwiftUI

// MARK: - Native Settings Form

/// 閱讀設定 — 與「複習節奏」「複習卡版面」共用**同一套原生心智模型**
/// （APP-20260808-f0770b 收斂 + APP-20260808-240a94 原生化）：
///
///   容器  `NavigationStack` + `Form`（呈現層由 `ReaderView` 的 `.sheet` 提供
///          detents 與 drag indicator，不再自繪 panel 卡片與 handle）
///   分組  `Section` + `SettingsSectionHeader` / `SettingsSectionFooter`
///   選擇  `Picker` —— 行內單值用 `.menu`，選項本身值得一列（帶 icon / 色票）用 `.inline`
///   數值  離散值共用的 +/- adjustment row；連續值才使用原生 `Slider`
///   開關  `Toggle`
///
/// 具名承認的代價：自繪的 selection tile、label chip、control surface、群組
/// air divider 全部退場，換來系統列樣式；襯線標題與自訂間距節奏隨之消失，
/// 主題選項的色票縮成一列內的小色塊。這是「一致性優先」的直接後果，
/// **不要**在 Section 內重新自繪把 editorial 個性救回來。
extension ReaderSettingsPresenter {

    // MARK: Layout

    /// **一頁，不含 chrome** —— 沒有自己的 `NavigationStack`、沒有「完成」。
    ///
    /// 這是為了讓同一頁能掛在兩個入口下，與 `ReviewCardLayoutEditor` 完全同構：
    /// 從閱讀器進來時由 `ReaderSettingsPanelSheet` 補上 stack 與完成鍵；從
    /// 設定▸偏好 進來時直接被 `navigationDestination` push，用既有的返回鍵。
    /// 頁面自己帶 `NavigationStack` 的話，push 進設定會變成雙層導覽列。
    var vocabLayout: some View {
        Form {
            vocabPreviewSection
            vocabTypographySection
            vocabAppearanceSection
            vocabHighlightSection
            #if DEBUG
            vocabDebugSection
            #endif
        }
        .navigationTitle(L10n.string("reader.settings.title"))
        .inlineNavigationBarTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { resetMenu }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.settingsPanel")
    }

    // MARK: Reset

    /// 與 `ReviewCardLayoutEditor.resetMenu` 同形：`.primaryAction` 上一個
    /// 逆時針箭頭選單，唯一一個 destructive 項目，identifier 走同一個
    /// `<scope>.resetMenu` 後綴慣例。兩頁的重置手感因此一致。
    private var resetMenu: some View {
        Menu {
            Button(L10n.string("reader.settings.reset.all"), role: .destructive) {
                onResetToDefaults()
            }
            .accessibilityIdentifier("reader.settings.reset.all")
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .accessibilityLabel(L10n.string("reader.settings.reset"))
        .accessibilityIdentifier("reader.settings.resetMenu")
    }

    // MARK: Preview

    /// 即時預覽擺在控制項**之前**：先讓人看到現在長什麼樣，再讓人動旋鈕。
    ///
    /// **與複習卡版面編輯器順序相反，這是刻意的不是不一致**（別「對齊」回去）。
    /// 共用的規則是「預覽緊貼它所控制的東西」：這一頁的控制項全頁共用同一份
    /// `ReaderSettings`，所以預覽只需要一張、擺頁首涵蓋全部；`ReviewCardLayoutEditor`
    /// 的預覽是**該複習方向專屬**的（辨識 / 產出各一張，`VocabularyCardMode`；每張
    /// 本身都已兩面都畫），所以它擺在各自 Picker 的
    /// 正下方（見 `ReviewCardLayoutEditor.swift:directionSection`）。
    ///
    /// 每一格都直接讀 binding 的當前值，沒有 draft、沒有 snapshot ——
    /// 所以它必然與正下方那些控制項一致，不需要靠誰記得同步。
    var vocabPreviewSection: some View {
        Section {
            ReaderSettingsPreviewCard(
                font: bindings.font.wrappedValue,
                fontScale: state.fontScale,
                lineHeight: bindings.lineHeight.wrappedValue,
                letterSpacing: bindings.letterSpacing.wrappedValue,
                theme: state.previewTheme,
                vocabHighlightPreferences: VocabHighlightPreferences(
                    colorPreset: bindings.vocabHighlightColorPreset.wrappedValue,
                    opacity: bindings.underlineOpacity.wrappedValue,
                    customSRGB: bindings.vocabHighlightCustomSRGB.wrappedValue
                )
            )
        } header: {
            SettingsSectionHeader(
                title: L10n.string("reader.settings.section.preview"),
                icon: "text.alignleft"
            )
        }
    }

    // MARK: Typography

    var vocabTypographySection: some View {
        Section {
            ReaderTypographyAdjustmentRow(
                title: L10n.string("reader.settings.fontSize"),
                value: state.fontSizeText,
                rowIdentifier: "reader.settings.fontSize",
                decrementIdentifier: "reader.settings.fontSize.decrement",
                incrementIdentifier: "reader.settings.fontSize.increment",
                canDecrement: state.canDecreaseFontSize,
                canIncrement: state.canIncreaseFontSize,
                onDecrement: onDecreaseFontSize,
                onIncrement: onIncreaseFontSize
            )

            ReaderTypographyAdjustmentRow(
                title: L10n.string("reader.settings.lineHeight"),
                value: String(
                    format: "%.1f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    bindings.lineHeight.wrappedValue
                ),
                rowIdentifier: "reader.settings.lineHeight",
                decrementIdentifier: "reader.settings.lineHeight.decrement",
                incrementIdentifier: "reader.settings.lineHeight.increment",
                canDecrement: bindings.lineHeight.wrappedValue > ReaderTypographyMetrics.lineHeightRange.lowerBound,
                canIncrement: bindings.lineHeight.wrappedValue < ReaderTypographyMetrics.lineHeightRange.upperBound,
                onDecrement: { changeLineHeight(by: -1) },
                onIncrement: { changeLineHeight(by: 1) }
            )

            ReaderTypographyAdjustmentRow(
                title: L10n.string("reader.settings.letterSpacing"),
                value: state.letterSpacingText,
                rowIdentifier: "reader.settings.letterSpacing",
                decrementIdentifier: "reader.settings.letterSpacing.decrement",
                incrementIdentifier: "reader.settings.letterSpacing.increment",
                canDecrement: state.canDecreaseLetterSpacing,
                canIncrement: state.canIncreaseLetterSpacing,
                onDecrement: { changeLetterSpacing(by: -1) },
                onIncrement: { changeLetterSpacing(by: 1) }
            )

            Picker(selection: bindings.scrollMode) {
                Text(L10n.string("reader.settings.readingMode.paged")).tag(false)
                Text(L10n.string("reader.settings.readingMode.scroll")).tag(true)
            } label: {
                Text(L10n.string("reader.settings.readingMode"))
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("reader.settings.readingMode")
        } header: {
            SettingsSectionHeader(title: L10n.string("reader.settings.section.typography"), icon: "textformat.size")
        }
    }

    private func changeLineHeight(by tickDelta: Int) {
        bindings.lineHeight.wrappedValue = ReaderTypographyMetrics.steppedValue(
            from: bindings.lineHeight.wrappedValue,
            by: tickDelta,
            in: ReaderTypographyMetrics.lineHeightRange,
            step: ReaderTypographyMetrics.lineHeightStep
        )
    }

    private func changeLetterSpacing(by tickDelta: Int) {
        bindings.letterSpacing.wrappedValue = ReaderTypographyMetrics.steppedValue(
            from: bindings.letterSpacing.wrappedValue,
            by: tickDelta,
            in: ReaderTypographyMetrics.letterSpacingRange,
            step: ReaderTypographyMetrics.letterSpacingStep
        )
    }

    // MARK: Appearance

    var vocabAppearanceSection: some View {
        Section {
            Picker(selection: bindings.font) {
                ForEach(ReaderFont.allCases) { font in
                    Text(font.displayName).tag(font)
                }
            } label: {
                Text(L10n.string("reader.settings.font"))
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("reader.settings.font")

            themeOptions
        } header: {
            SettingsSectionHeader(title: L10n.string("reader.settings.section.appearance"), icon: "paintpalette")
        }
    }

    /// An explicit glass tile grid keeps each theme choice addressable in UI
    /// tests. SwiftUI's inline Picker does not preserve child accessibility
    /// identifiers in the XCTest hierarchy, making theme counterexamples flaky
    /// by construction.
    private var themeOptions: some View {
        ReaderThemeGlassPicker(selection: bindings.theme, onSelect: onSelectTheme)
    }

    private var underlineOpacitySelection: Binding<Double> {
        Binding(
            get: { bindings.underlineOpacity.wrappedValue },
            set: { onSelectUnderlineOpacity(VocabHighlightPreferences.quantizedOpacity($0)) }
        )
    }

    // MARK: Highlight

    var vocabHighlightSection: some View {
        Section {
            VocabHighlightColorPresetPicker(
                selection: bindings.vocabHighlightColorPreset,
                customSRGB: bindings.vocabHighlightCustomSRGB,
                title: L10n.string("vocab.highlight.color.label"),
                accessibilityIdentifier: "reader.settings.highlightColor"
            )

            VStack(alignment: .leading, spacing: AppSpacing.microGap) {
                HStack {
                    Text(L10n.string("vocab.highlight.opacity.label"))
                    Spacer(minLength: AppSpacing.s2)
                    Text(
                        String(
                            format: "%.0f%%",
                            locale: Locale(identifier: "en_US_POSIX"),
                            underlineOpacitySelection.wrappedValue * 100
                        )
                    )
                    .monospacedDigit()
                }
                Slider(
                    value: underlineOpacitySelection,
                    in: VocabHighlightPreferences.opacityRange,
                    step: VocabHighlightPreferences.opacityStep
                )
                .accessibilityLabel(L10n.string("vocab.highlight.opacity.label"))
                .accessibilityIdentifier("reader.settings.highlightOpacity")
            }
        } header: {
            SettingsSectionHeader(title: L10n.string("reader.settings.section.highlight"), icon: "highlighter")
        }
    }

    // MARK: Debug

    #if DEBUG
    var vocabDebugSection: some View {
        Section {
            Toggle(isOn: bindings.showHitTestingDebug) {
                Text(L10n.string("reader.settings.debug.hitTesting"))
            }
            .accessibilityIdentifier("reader.settings.debug.hitTesting")
        } header: {
            SettingsSectionHeader(title: L10n.string("reader.settings.section.debug"), icon: "ladybug")
        } footer: {
            SettingsSectionFooter(L10n.string("reader.settings.debug.footer"))
        }
    }
    #endif
}

private struct ReaderTypographyAdjustmentRow: View {
    let title: String
    let value: String
    let rowIdentifier: String
    let decrementIdentifier: String
    let incrementIdentifier: String
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.s2) {
            LabeledContent(title) {
                Text(value).monospacedDigit()
            }
            Spacer(minLength: AppSpacing.s2)
            adjustmentButton(
                systemName: "minus",
                label: L10n.format("reader.settings.adjust.decrease", title),
                identifier: decrementIdentifier,
                disabled: !canDecrement,
                action: onDecrement
            )
            adjustmentButton(
                systemName: "plus",
                label: L10n.format("reader.settings.adjust.increase", title),
                identifier: incrementIdentifier,
                disabled: !canIncrement,
                action: onIncrement
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(rowIdentifier)
    }

    private func adjustmentButton(
        systemName: String,
        label: String,
        identifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(
                    width: AppFloatingChromeMetrics.hitTarget,
                    height: AppFloatingChromeMetrics.hitTarget
                )
        }
        .buttonStyle(.appCompactAction(.neutral))
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

#endif
