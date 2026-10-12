<!-- doc-meta
tier: reference
authority: derived
update_trigger: code-change
scope:
  - ios/BooksAndVocab/UIComponents/
  - ios/BooksAndVocab/Views/
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# UI Component & Pattern Inventory

Date: 2026-05-13
Scope: `ios/BooksAndVocab`

文檔網絡：
- 設計規範主文檔：`docs/sop/ui-design.md`
- 開發與編譯入口：`docs/sop/ios.md`
- App 架構脈絡：`docs/sop/architecture.md`
- Vocabulary 範圍對照：`docs/reference/feature_boundary/vocabulary.md`

## 這份文件是幹嘛的

這不是設計理念文件，而是「現況清單」。

用途有三個：
- 查：專案裡已經有哪些可重用元件
- 對：新畫面應該復用哪個 pattern，不要再重做一套
- 補：哪些地方還沒被 design system 完整覆蓋

簡單講：
- `component inventory` = 有哪些 UI 零件
- `pattern inventory` = 這些零件怎麼組成可重複的互動腳本

---

## Component Inventory

### App Shell Layer

主要檔案：
- `ios/BooksAndVocab/ContentView.swift`
- `ios/BooksAndVocab/UIComponents/AppShellComponents.swift`
- `ios/BooksAndVocab/UIComponents/AppSurface.swift`

核心元件：
- `AppSectionCard`
- `AppToolbarGlyph`
- `AppSectionHeader`
- `AppSectionFooter`
- `AppEmptyStateContent`
- `AppEmptyStateCard`
- `AppEmptyStateAction` — optional `accessibilityIdentifier` lets a caller expose an exact visible CTA selector without changing the shared empty-state visual pattern; semantic IDs remain owned by the feature surface.
- `AppStateMessageContent`
- `AppStateMessageCard`
- `AppTabSelector`
- `AppFilterChipBar` — 多選 filter 版本；與 `AppTabSelector` 共用 `appChipLabel`、count 與 iOS 26 `GlassEffectContainer`/`glassEffect`，fallback style 仍保留給非 glass consumer
- `AppLoadingStateCard` / `AppLoadingProgressBar` — loading/status 的共用 surface；Reader、TOC、Explore、Vocabulary、Stats 與 Settings sync 使用同一套原生 `ProgressView`，只由 app/vocab skin 決定配色
- `AppSearchField`
- `AppKeyValueRow`
- `AppActionButtonStyle`
- `AppCard`
- `AppTag`
- `AppBanner` — **已退役（#2047）**：產品呼叫點歸零，元件與 catalog 場景已移除。暫時性提示改頂端 pill（`AppToast`），承載操作的狀態改畫面內面板（`AppStateMessageCard`／`VocabStateMessageCard`），規範見 `docs/sop/ui-design.md`「暫時性提示」。`AppBannerMetrics` 仍由 `WelcomeView` 使用。
- `AppFloatingChrome` / `AppFloatingChromeButton` — 浮在內容上的**玻璃 chrome** 原語，給「沒有系統 bar 可繼承」的畫面用（Reader 把 navigationBar/tabBar 都關掉，拿不到平台白給的玻璃）。`AppFloatingChrome { }` 包 `GlassEffectContainer`；`.appFloatingChromeItem(union:in:interactive:)` 只上材質（`glassEffect` + `glassEffectUnion`，同 union id 合成一塊共享膠囊）；`.appFloatingChromeMorph(id:in:)` 走 `glassEffectID`，讓 compact ↔ expanded 由 matchedGeometry 形變。**命中區由 `AppFloatingChromeButton` 在 Button 的 label 內自撐 44pt**（`.plain` Button 的手勢掛在 label 上，祖先 `contentShape` 無法讓後代手勢認領自己 frame 以外的點——同 `VocabChromeIconButton` 與 `PodcastControlsView` 的作法）。`accessibilityLabel` 為必填。首個消費者是 Reader top chrome；同族待收編：`PodcastPlayerScene` / `PodcastTranscriptViewport` / `PodcastShelf` / `KGVocabView` / `ReviewFoldSurface` / `ArchivedVocabSheet`。材質視覺用 `ios_ops.sh catalog open` 開真實 simulator window，再以 `catalog capture` 走系統 compositor 驗證；iOS 26 Liquid Glass 的 backdrop sampling 不可用 `layer.render(in:)` 判讀。
- `AppSheetModifier` — `.appSheet(.large/.medium/.adaptive)` 統一 sheet presentation，取代各畫面散落的 `.sheet` / `.halfSheet` 呼叫
- `AppCompactActionButtonStyle` — inline 小尺寸主行動按鈕（capsule，不撐滿寬度），透過 `.buttonStyle(.appCompactAction(.primary/.neutral/.outline/.destructive))` 套用；取代 4 處 `.borderedProminent.controlSize(.small)`；與 `AppActionButtonStyle`（全寬主按鈕）分工 — banner / card / toolbar 內 inline CTA 用此
- `AppOfflineBanner` — 全 app 持久離線指示；`.appOfflineBanner()` modifier 訂閱 `NetworkMonitor.shared.isConnected`，斷線時頂部插入 24pt 細 banner，進場用 `AnyTransition.bannerReveal` + `AppMotion.emphasizedDecelerate`；現於 `ContentView` 套用一次（**已知 issue：light mode 對比 3.21:1 未達 WCAG AA**）
- `SyncStepStatusIcon`（`UIComponents/SyncStepStatusIcon.swift`）— `PipelineStep.StepStatus` 的六態符號（waiting `circle` / running `ProgressView` / retry `arrow.triangle.2.circlepath` + repeating scale / done `checkmark.circle.fill` + bounce / skipped `minus.circle.fill` / error `xmark.circle.fill`），色彩全走 `appSkin.palette`。同檔另附 `StepStatus.detailColor(_:)`——detail 文字色與符號同一組語意，刻意放在一起免得漂移。**兩個消費者**：詞庫頁同步畫面（`SyncPresenter` 已改為委派）與設定頁的逐步同步進度（`SettingsSyncProgressPanel`）。抽出的理由是**對稱的成本**：同一狀態在兩處長得不一樣是使用者學兩次的成本，複製一份 switch 則是下次加狀態時漏改一處的成本。**要加第七個狀態就改這裡**，不要在消費者端各自 switch
- `AppSkeletonLine` / `AppSkeletonCard` — Loading 骨架 primitive；`primaryText.opacity(0.06↔0.14)` pulse（`AppMotion.subtleBreath`）；`AppSkeletonCard` 已被 `VocabSceneShell` list 場景採用（1 處）。列表/內容骨架用這組；需要明確狀態文案或進度時改用 `AppLoadingStateCard`，不要再自製裸 `ProgressView`。
- `AppSidebarRow` — Catalyst 側邊欄列（`ContentView` `NavigationSplitView` sidebar 用），取代系統 `.listStyle(.sidebar)` 預設樣式（系統半透明材質 + 系統藍選取色與 app Notion 風割裂）。整列可點（`HStack` + `Spacer` 撐滿 + `.contentShape(Rectangle())` 把整矩形納入 hit-test，水平 padding 由元件內 `appSkin` token 控不靠 List inset）；走 appSkin typography/spacing/palette，選取/未選以灰階配色（`secondaryText`→`primaryText`）+ `primaryText.opacity(0.08)` 自繪 `AppRoundness.control` 圓角背景區分（自訂字體 ElmsSans 不響應 `.fontWeight`，故以配色而非字重表達選取）；hover 走既有 `.appHoverRowTint`；a11y icon `accessibilityHidden` + row 掛 `accessibilityLabel` + selected 加 `.isSelected`；selection 由 caller 自管 `@State`，不用 `List(selection:)`

主導航 pattern：
- `ContentView` 以 `AppPrimarySection` 定義全 app 一級資訊架構（DEBUG：書庫 → 播客 → 單字本 → 總覽；Release：無播客——`AppPrimarySection.visibleCases(podcastEnabled:)` 依 `KGFeatureFlags.podcastEnabled` 過濾，見 `tech_index.md`）。iPhone / iPad 保留 `TabView`；Mac Catalyst 走 `NavigationSplitView` + `.sidebar` list，將主區切換移到左側側欄，避免桌面版沿用手機底部分頁。Catalyst 不用 `List(selection:)`（iOS SDK availability unavailable），改以 sidebar `AppSidebarRow`（見上）+ `selectedSection` 狀態維持選取背景。

#### Toast 子系統

主要檔案：
- `ios/BooksAndVocab/UIComponents/AppToast.swift`
- `ios/BooksAndVocab/UIComponents/AppToastCoordinator.swift`
- `ios/BooksAndVocab/UIComponents/View+ToastSheet.swift`
- `ios/BooksAndVocab/Services/ModelContext+SafeSave.swift`

核心元件（行為契約見 `docs/sop/ui-design.md`「暫時性提示」）：
- `AppToast` — 頂端 glass pill，預設單行（縮小後尾端截斷、不換行）；截斷時可輕點展開成多行（#2862，`isExpanded`／`onToggleExpanded` 由 coordinator 提供），支援上滑關閉，**無動作按鈕**；選取器 `app.toast`
- `AppToastCoordinator` — toast 計時／動畫／VoiceOver 外殼；`AppToastQueue` 是純狀態機（同 key 就地取代、不同 key 排隊、最多 2 則、滿了留較嚴重者、退場後才換下一則）；`AppToastItem`（style: success/info/warning/error，`key` 為事件身分）
- `toastSheet` — 自動在 sheet 內注入 `toastOverlay()` 的 view modifier
- `toastFullScreenCover` — 同上，用於 fullScreenCover
- `safeSaveWithToast()` — `ModelContext` 安全存檔 + toast 回饋

責任：
- app-wide card / empty state / message / tab / search / row / action chrome / banner / sheet presentation / toast notification

不該做的事：
- feature-specific 視覺語言不應直接塞回這層

### Vocabulary Skin Layer

主要檔案：
- `ios/BooksAndVocab/Models/AppSkin.swift`（前身 `Skin/VocabSkin.swift`，已升格為全 app 共用）
- `ios/BooksAndVocab/Views/Vocabulary/Components/VocabComponents.swift`（前身 `VocabSkinComponents.swift`）
- `ios/BooksAndVocab/Views/Vocabulary/Components/VocabShellComponents.swift`

核心元件：
- `VocabCard`
- `HangingIndentFlowLayout`（`Components/HangingIndentFlowLayout.swift`，複習卡連結列）：首格為標籤、其後項目接在標籤右側並換行到同一值欄；超過值欄寬的項目在值欄內換行、不溢出卡片（#3227）。連結列「+N」命中帶上限見 `TodayReviewMetrics.linkOverflowHitTarget`（膠囊高 + 2×s1，不蓋到上一列；放棄 44pt 下限，#3226/#3253）
- `VocabToneChip`
- `VocabTierLabel`
- `VocabEmptyStateContent`
- `VocabEmptyStateCard`
- `VocabStateMessageCard`
- `VocabTabSelector`
- `VocabSearchField`
- `VocabToolbarGlyph`
- `VocabChromeIconButton`
- `VocabOverlayHeader`
- `VocabInlineActionButton`
- `VocabSectionHeader`
- `VocabSliderRow`
- `VocabListCard`
- `VocabStatusHero`
- `VocabTimelineRow`
- `VocabActionButtonStyle`
- `VocabSceneShell` — 四態容器（loading/empty/error/content），統一 Vocabulary 場景的狀態管理殼層；各 VocabPresenter 優先透過此殼層組合狀態而非各自手拼
- `GraphThumbnailWebView` — `UIViewRepresentable` 小型圖譜預覽（iOS / Catalyst 共用，無原生 macOS `NSViewRepresentable` 分支），用於 StatsPresenter
- `NotebookStackedCoverView` — Editorial 立體堆卡（**目前由 Bookshelf / Podcast / EditSheet preview 使用,NotebookCard book-row 不再用**）：彩色封面 + cream 紙頁三階 ghost（`paperLight/paperSepia/paperSepiaDeep`）；幾何走 `NotebookStackMetrics`（dy/dx=4pt / rotation ±1.5° / jitter ±1pt / rotationOverhang 8pt / `patternOpacity` 0.12）；每層 0.5pt `cardBorder` hairline；rotation 由 `stableSeed(for:)` djb2 hash 保證跨 launch 同字串同角度；下層 ghost `.appElevation(.z1)`、頂層 `.z2`；按壓走 `NotebookDeckButtonStyle`（press-in `TapFeedback.animation` + release `AppMotion.cardDeckRelease` + haptic `.selection`），Reduce Motion 關 offset/scale 但 **保留 rotation**（靜態 layout 非 motion）；`showsName: Bool = true` opt-in 開關
- `EditorialCoverComposition`(private in `NotebookCard.swift`) — **live**：D1 editorial cover overlay，由 `coverArea` 以 `.overlay` 套在 cover view 之上（grid + hero 兩 style 皆套），跟外層 `rotationEffect` 一起旋轉。內容:serif name 左上(grid 22pt / hero 32pt)+ hairline rule(cover 寬 ×0.25)+ `N 詞` 右下(cardCount > 0)+ 3pt spine(grid && isActive)。cover view 以 `showsName: false` 把 name 渲染交給此 overlay。
- `VocabReviewCTAPill` — 用於 detail 頁(KGVocabPresenter)與 **NotebookListView 頂部 section header**(D4 editorial),brandHero 奶黃 capsule + onBrandHero 前景。Both 同視覺族群,page-level 標題不需卡片框包裹。
- `VocabReviewBanner` — **(已從 NotebookListView 解除引用)** 元件保留於 codebase 作 future use / preview;NotebookListView 現走 page section header `今日複習` + `VocabReviewCTAPill` 取代。
- `ReviewCardLayoutEditor`（`Views/Vocabulary/Scenes/ReviewCardLayoutEditor.swift`）— **跨 feature 共用的設定頁 View struct**：複習畫面 toolbar 以 `ReviewCardLayoutEditorSheet` 包成 sheet，Settings ▸ 偏好 以 `navigationDestination` 直接 push 同一個 struct，**兩邊只有外殼 chrome 不同、頁面本體零複製**。用的是原生 `Form` / `Section` 加 Settings 層的 `SettingsSectionHeader` / `SettingsSectionFooter`（`6c8a99a37` 起不再用 `SettingsDivider` / `.settingsCard()` / `AppKeyValueRow`），所以在 Settings 裡看起來就是原生一頁。**不得 inline 回任何 presenter body**（真機 Debug 1MB main stack，同 `SettingsPresenter` 的 stack 約束）。**新增跨 feature 共用設定頁時照此抄**：頁面本體是獨立 top-level struct，入口各自包 chrome。
- `ReviewCardLayoutPreviewCard`（`Views/Vocabulary/Scenes/ReviewCardLayoutPreviewCard.swift`）— 版面設定頁的即時預覽（見 Pattern 9）。**它不是「長得像卡片的東西」，它就是卡片**：內部唯一畫東西的是 `ReviewCardView`（出貨複習卡的同一個 view，由 IMP-20260808-ee7ca4 從 `TodayReviewPresenter` 抽成純輸入版本）。像素級不飄移靠的是這個結構事實不是紀律 —— **此處不得出現第二份手刻的卡片版面**，出現了這個型別就沒有存在理由。姿態固定「翻開的樣子」（`showsAnswer: true` + `mountsBack: true`）因為要看的正是兩面各有什麼；`interactive: false` 不吃手勢也不搶 `todayReview.card.front` 的 a11y 契約；`measuresSections: true` 才跑與真卡同一組隱藏量測 probe。**「不飄移」的範圍要講清楚**：它保證的是**程式碼**不飄移（同一個 view、同一組 probe），不是「你等下在複習畫面會看到的就是這一張」—— 預覽的高度預算是寫死的 `viewportHeight = 420`，真卡吃的是 `geo.size.height`（`TodayReviewPresenter.swift:174`），而 `revealZoneReserve` 隨 containerHeight 變（見 `ReviewCardBudgetParityTests`），所以 solver 一般會落在**不同的精簡級**。準確的說法是「同一份 profile ∧ 同一個高度預算下逐像素一致」；預覽示範的是「這個 preset 長什麼樣」

責任：
- vocabulary feature 的 card rhythm、toolbar chrome、status hero、overlay shell、timeline row、四態場景殼層、graph thumbnail

### Reader Layer

主要檔案：
- `ios/BooksAndVocab/Views/Reader/ReaderContentStyle.swift`
- `ios/BooksAndVocab/Views/Reader/TranslationPanel.swift`
- `ios/BooksAndVocab/Views/Reader/TranslationPanelPresenter+State.swift`
- `ios/BooksAndVocab/Views/Reader/TranslationVocabPresenter.swift`
- `ios/BooksAndVocab/Views/Reader/ReaderSettingsPanel.swift`
- `ios/BooksAndVocab/Views/Reader/ReaderSettingsPreviewCard.swift`
- `ios/BooksAndVocab/Views/Reader/VocabHighlightColorPresetPicker.swift`
- `ios/BooksAndVocab/Views/Reader/ReaderSettingsPresenter.swift`
- `ios/BooksAndVocab/Views/Reader/ReaderSettingsPresenter+Vocab.swift`
- `ios/BooksAndVocab/Views/Reader/ReaderViewPresenter.swift`

核心元件 / 容器：
- `TranslationPanel`
- `TranslationPanelPresenterState`
- `TranslationVocabPresenter`
- `ReaderSettingsPanel`
- `ReaderSettingsPresenter`
- `ReaderViewPresenter`
- `ReaderSettingsPresenter` — 閱讀器設定的頂層 presenter（vocab 單一模式，glass 分支已移除）
- `VocabHighlightColorPresetPicker` — Reader / Podcast 共用詞庫 highlight 顏色入口，採原生 iOS 26 `Picker(.palette)` 與 `VocabHighlightColorPreset` 色票；accessibility identifier 由 caller 注入，避免 Podcast 誤掛 Reader surface id
- `ReaderSettingsPreviewCard` — 閱讀設定頁的即時預覽（見 Pattern 9）。**與 `ReviewCardLayoutPreviewCard` 不同族**：它做不到「就是那個 view」，因為閱讀器正文是 Readium 跑在 WKWebView 裡排的、樣式以 CSS 注入。所以它承諾的是**同一批值**而非同一個 view —— 字體走 `ReaderFont.previewFontName`、字級/行距是送進 `EPUBPreferences` 的同兩個值、紙墨色取自 `ReaderTheme`、生字色帶取自產 CSS 的同一個 `ReaderContentStyle`。`ReaderPreviewStyleSourceTests` 現在另外釘住 line-height range/tick source、164pt fixed viewport 與 8% edge fade 的 layout contract；仍未宣稱跨 WebView 逐像素一致：`baseFontSize` 是參考基準、換行位置受 SwiftUI/Blink 差異影響、色帶高度仍是示意而非 CSS 等量。
- `PDFReaderView` — PDF 格式閱讀器（iOS only）

責任：
- reader loading / overlay / header / translation / settings panel
- reader / podcast 共用 highlight 顏色入口
- PDF reader 獨立路徑
- 整層以 `#if os(iOS)` 隔離 —— Catalyst 下 `os(iOS)` 為 true 仍編譯仍啟用

目前狀態：
- motion 已大幅收斂
- state presentation 已透過 shared state message 語法統一
- glass 分支已完全移除，僅保留 vocab 模式

### Settings Layer

主要檔案：
- `ios/BooksAndVocab/Views/Settings/SettingsPresenter.swift`
- `ios/BooksAndVocab/Views/Settings/SettingsPresentation.swift`

核心元件：
- `SettingsSectionHeader`
- `SettingsSectionFooter`
- `SettingsDivider`
- `SettingsSocialBadge`
- `SettingsAuthButton`
- `SettingsAuthSummary`
- `SettingsRow`
- `SettingsCardModifier`
- `SettingsButtonChromeModifier`

責任：
- settings-only row layout 與 auth/subscription/info section composition

目前狀態：
- 已接入 shared motion
- 狀態訊息開始接入 shared state card 語法

### Models / Tokens Layer

主要檔案：
- `ios/BooksAndVocab/Services/RetryPolicy.swift`
- `ios/BooksAndVocab/Models/AppMetrics.swift` — AppMetrics / AppSpacing / AppRoundness / AppElevation / AppMotion / ElevationDirection（無 AppLayout — readable-width 由 `WordDetailPresenter` local `maxContentWidth=640` 控）
- `ios/BooksAndVocab/Models/AppFonts.swift` — AppFonts.serif/sans/mono + TypeScale(caption2/caption/subhead/body/h2/h1/hero) + Tracking + LineSpacing
- `ios/BooksAndVocab/Models/AppColors.swift` — semantic palette tokens（含 brandHero light/dark）
- `ios/BooksAndVocab/Models/AppTheme.swift` — `@Environment(\.appTheme)` 注入點，Palette/Typography 三組（light/dark/highContrast）

核心元件 / token：
- `RetryPolicy` — 網路重試策略，實作指數退避（exponential backoff）+ Retry-After header 解析；所有 authenticated request 統一使用，不各自硬編 retry 邏輯
- `AppSpacing` — 8pt grid 語意 token（s0–s7 + `cardOuterPadding/innerGap/sectionGap`），取代 raw padding magic number
- `AppRoundness` — 無因次圓度 t（`none=0 / card=.15 / control=.30 / icon=.45 / pill=1`）。半徑不是常數，由 `AppRoundedRect` 於 render 當下從元件自身 box 導出：`r = t · min(W,H) / 2`
- `AppRoundedRect` / `AppUnevenRoundedRect`（`ios/BooksAndVocab/UIComponents/AppRoundedRect.swift`）— 全 app 圓角矩形的唯一入口。`Shape` + `InsettableShape`，`.inset(by:)` 給出真正的 concentric 巢狀（`r_inner = r_outer − d`），所以 `.strokeBorder` 與容器內嵌不需再手算 `±2`。t=1 端點是 `.continuous` 方圓，**不是**正圓或圓弧膠囊
- `AppElevation` — z0–z4 shadow token + `.appElevation(.zN)` modifier；dark mode 自動加強 opacity（**live：~24 callsites**，全 app shadow 唯一入口 — AppSurface / AppToast / Card / cover / overlay 等）
- `AppMotion` — 動畫語意層 token（`emphasizedDecelerate/Accelerate`、`subtleBreath`、`panelState`、`feedbackPulse`、`phaseChange`、`shimmer`、`TapFeedback` triplet）
- Animation convenience methods — `View.animatePhaseChange()`、`View.animateFeedback()` 等擴充，將常用 `withAnimation` 組合收斂為語意化呼叫
- `AppFonts.hero(weight:)` / `TypeScale.hero` — 40pt serif hero typography（`TypeScale` 階梯：`caption2/caption/subhead/body/h2/h1/hero`，無 display1/2）
- `AppColors.brandHero(_:scheme)` + `AppTheme.palette.accentHero/accentSubtle/successBg/warningBg/infoBg/destructiveBg/borderStrong` — 品牌 hero + 狀態 bg 色彩 token
- `@Environment(\.appResolvedColorScheme)` + `.appAppearanceScheme()`（`Models/AppAppearanceMode.swift`，由 `AppThemeContainer` 餵值）— **presentation 邊界的外觀重播**。sheet / fullScreenCover 是獨立的 presentation host，SwiftUI **只在呈現當下播種一次** interface style 且之後不再重播；所以環境驅動的顏色（`.tint`、`appSkin`）會即時更新，而系統自繪的東西（原生 `Form`、nav bar）凍在原地 —— 症狀就是「整頁只有一半跟著換配色」（APP-20260809-f1b8cb）。`.appAppearanceScheme()` 掛在 presentation 的**內容根**上重新宣告一次，冪等。**環境鍵存的必須是具體 light/dark 而非 `AppAppearanceStore.resolvedColorScheme`**：後者在 `.system` 時是 `nil`，而 `preferredColorScheme(nil)` 的語意是「我不表態」，不表態拉不回一個已經播種成淺色的 sheet。走 `toastSheet` / `platformFullScreenCover` / `loginSheet` 的呼叫端不必自己寫（seam 已寫），**自己開原生 presentation 的地方要自己寫**，由 `SheetAppearanceBoundaryTests` 釘住（**檔級加總，擋「忘記」不擋「寫錯」**——同檔內一個 sheet 掛兩次、另一個沒掛，總數仍然對得起來；像素本身也不在它守備範圍）

責任：
- 跨層共用的網路策略 model
- 動畫呼叫語法糖，確保 motion token 使用一致

不該做的事：
- 不應在此層持有任何 SwiftUI View 或 `@State`

---

### Interaction — Hover / Pointer Layer

主要檔案：
- `ios/BooksAndVocab/UIComponents/HoverHighlight.swift` — 指標 hover / pointer 回饋 modifier（`.appHoverLift` / `.appHoverRowTint` / `.appPointerHover`）

核心元件：
- `.appHoverLift(scale:)` — 卡片 hover 輕微 scale 浮起（預設 1.02）；卡片屬按鈕互動故 scale 合 Motion Contract，已 gate `accessibilityReduceMotion`。套用：`BookCard` / `PodcastSeriesCard` / `NotebookCard`。
- `.appHoverRowTint(roundness:)` — 扁平可點 list-row hover bg tint（`primaryText.opacity(0.05)`，只動 background）。套用：`SettingsNavigationRow` / `SettingsCardNavigationRow` / `syncSummaryRow`。卡片型可點走 lift / `.liftable`，不重複 tint。
- `.appPointerHover(_:)` — chrome 控制項的桌面指標層：包 UIKit `.hoverEffect`（預設 `.highlight`），Catalyst / iPad 觸控板下指標 morph 貼合元件 + 系統 highlight，提示可互動。套用：`AppFilterChipBar` / `AppTabSelector` / `VocabSortPill` / `VocabReviewCTAPill` / `VocabChromeIconButton` / `AppFloatingChromeButton`。

責任 / 邊界：
- `.onHover` / `.hoverEffect` 在純觸控 iPhone 無指標事件自動 no-op，iPad 觸控板 + Mac 共益 → hover / pointer modifier **不**包 `#if`。`.pointerStyle`(iOS 18+) 在 Catalyst 不可用，故指標層走 `.hoverEffect`（UIKit pointer effect）而非自訂 cursor 形狀。

---

## Pattern Inventory

### 1. Empty State Pattern

用途：
- 尚未登入
- 沒有資料
- 搜尋無結果
- 任務完成後無下一步

優先元件：
- `AppEmptyStateContent`
- `AppEmptyStateCard`
- `VocabEmptyStateContent`
- `VocabEmptyStateCard`

代表畫面：
- `BookshelfView`
- `KGVocabView`
- `KnowledgeGraphPresenter`
- `TodayReviewPresenter`

規則：
- title + icon + description 為最小組
- feature 版面優先用 feature wrapper，不直接手拼 icon/text

### 2. State Message Pattern

用途：
- loading
- transient success
- inline warning
- recoverable error
- status + timer

優先元件：
- `AppLoadingStateCard` / `AppLoadingProgressBar`（loading / progress）
- `AppStateMessageContent`
- `AppStateMessageCard`
- `VocabStateMessageCard`

代表畫面：
- `TranslationPanelPresenterState`
- `TranslationVocabPresenter`
- `KGVocabView`
- `SettingsPresenter` paywall 狀態區

規則：
- 若狀態在 panel 內，優先用 `Content`
- 若狀態本身就是一個獨立區塊，優先用 `Card`
- UI World asset evidence 不是 loading/empty placeholder：選定 fixture 後，asset snapshot 或 decode 失敗必須 fail-loud；不可用 optional lookup 或 `EmptyView` 把 evidence node 靜默省略。

### 3. Hero Status Pattern

用途：
- sync ready / running / failed / completed
- login required
- pro required
- graph empty / loading / failed

優先元件：
- `VocabStatusHero`

代表畫面：
- `SyncPresenter`
- `KnowledgeGraphPresenter`

規則：
- 用於大狀態切換
- 不要拿來做小型 inline message

### 4. List Shell Pattern

用途：
- filter / tab / count / row list / divider

優先元件：
- `ListSectionCard`（`ios/BooksAndVocab/UIComponents/ListSectionCard.swift`）— 扁平列表共用卡片容器（`VStack(spacing:0)` + `cardBackground` fill + `cardBorder` stroke + `clipShape` 圓角讓 per-row 選中底色不溢出）。podcast 集數列表與單字列表共同骨架；divider 由 caller 在 `ForEach` 內插（不塞進容器，保語意）
- `VocabListCard`
- `VocabTabSelector`
- `VocabSearchField`
- `WordRow`

代表畫面：
- `KGVocabPresenter`
- `VocabularyListPresenter`
- `PodcastEpisodeListView`

規則：
- tab + header + list content 優先收斂到同一殼層
- 扁平 row list 的卡片容器收斂到 `ListSectionCard`

### 5. Overlay / Panel Pattern

用途：
- translation panel
- reader settings
- graph settings
- linked card overlay

優先元件 / token：
- `TranslationPanel`
- `ReaderSettingsPanel`
- `VocabOverlayHeader`
- `AppMotion.panelState`
- `AnyTransition.readerPanelReveal`
- `AnyTransition.overlayFade`

代表畫面：
- `ReaderView`
- `KnowledgeGraphPresenter`
- `LinkedCardOverlayStack`

規則：
- panel 開合用 `panelState`
- 底部浮層進出用 `readerPanelReveal`
- scrim / 暫時遮罩用 `overlayFade`

### 6. Feedback Pattern

用途：
- save success
- review remembered / forgot
- sync numeric progress
- badge confirmation

優先 token：
- `AppMotion.feedbackPulse`
- `AnyTransition.feedbackBadge`

代表畫面：
- `TranslationPanelPresenterState`
- `TranslationVocabPresenter`
- `SyncPresenter`
- `TodayReviewPresenter`

規則：
- feedback 必須有語意，不只是一個 bounce
- 成功 feedback 應優先搭配 haptic

### 7. Phase Transition Pattern

用途：
- sync lifecycle
- auth logged in/out swap
- settings status swap

優先 token：
- `AppMotion.phaseChange`
- `AnyTransition.modalSwap`
- `AnyTransition.statusRowReveal`

代表畫面：
- `SyncPresenter`
- `SettingsPresenter`

規則：
- phase 與 row reveal 要分開，不能混用同一動畫

### 8. Adaptive Field Pattern（使用者選欄位 → 版面自己讓路）

用途：
- 讓使用者勾選要顯示哪些資訊欄位，而版面在空間不足時**逐級退讓**而非硬截或爆版
- 目前唯一實作：複習卡片（`ReviewCardLayoutProfile` × `ReviewCardLayoutSolver` × `ReviewCardView`）

三個角色，職責不可混：
- **profile（持久偏好）** — 使用者勾了什麼。與「這張卡有沒有這筆資料」正交：缺資料只是本次不畫（`ReviewCardContentAvailability`），**永遠不從偏好裡刪掉**
- **solver（純值）** — 拿三層量測（natural / intermediate / compact）與一個高度預算，解出每欄的 policy。O(fields)、無狀態、不 import SwiftUI
- **renderer（畫）** — 只照 policy 畫，**不自己再從 token 推一次幾何**；solver 扣的 chrome/spacing 與 renderer 畫的必須是同一顆 token

規則：
- **固定精簡順序，寫死在 solver 裡**，不是「哪個最大就砍哪個」——順序可預期，使用者才學得會版面會怎麼變（順序與豁免欄位見 `feature_boundary/vocabulary.md` §動態佈局契約）
- **natural = 目前出貨的樣子**。若把既有的截斷當成「已經壓過一層」，未動過的預設會比它要重現的畫面更鬆
- 核心欄位（題目 / 答案）是**模式語意不是可選欄位**：不進可勾選陣列，在編輯器畫成鎖定列
- 編輯器**直寫 store、不持 draft**，背後的畫面即時重排；退無可退才捲動，不靜默隱藏使用者親手勾的東西

代表畫面：
- `ReviewCardLayoutEditor`（編輯端）＋ TodayReview 卡片正反面（渲染端）

---

### 9. Live Preview Pattern（設定頁當場看得到，不必關掉才知道）

用途：
- 凡是「改一個值、效果在別的畫面才看得到」的設定頁，都在同頁掛一張即時預覽
- 現有兩個實作：`ReviewCardLayoutPreviewCard`（複習卡版面）、`ReaderSettingsPreviewCard`（閱讀設定）

**不飄移要靠結構，不能靠紀律**。兩種強度，選能拿到的那個、並在型別的檔頭具名寫出是哪一種：
- **同一個 view**（強）— 預覽內部直接掛出貨用的那個 view，**不得出現第二份手刻的版面**。`ReviewCardLayoutPreviewCard` 走這條（實測：該檔零個 `Text` / `VStack` / `Rectangle`）。代價是那個 view 必須先被抽成純輸入版本（IMP-20260808-ee7ca4）
- **同一批值**（弱，但仍可承諾）— 出貨路徑不在 SwiftUI 裡（例如 Readium 在 WKWebView 排版），塞一個等價 WebView 換來的是「更慢且一樣近似」而非「更真」。此時預覽讀**送進出貨路徑的同一批值**（同一個 enum、同一個 style 物件、同一組倍率）。`ReaderSettingsPreviewCard` 走這條

規則：
- **禁的是第二份「值的來源」，不是第二份 renderer。** 這兩件事只在強分支重合，弱分支必然要自己排版（`ReaderSettingsPreviewCard` 用 `ReaderProseFlowLayout` 自己排、自己算字級行距，這是對的）。真正的禁令是：不得自立 HSL 表、不得自訂 clamp 上下界、不得複寫 CSS 倍率。正面判準看 `ReaderSettingsPreviewCard.highlightBand`——它照抄 CSS 的 `clamp(0, …, 1)`，而不是自己決定夾在哪
- **弱分支必須附一組釘住那些值的測試，否則「同一批值」只是自述。** 現行憑證是 `ios/BooksAndVocabTests/ReaderPreviewStyleSourceTests.swift`：CSS 色相與原生共讀同一張 HSL 表、`vocabOpacityMultiplier` 與 CSS 字串內嵌的是同一個 Double、每個 `ReaderFont.previewFontName` 都解析得到已註冊字體（**`Font.custom` 找不到字體不報錯，只靜靜退回系統字體——這條測試是唯一擋得住它的東西**）、送進 WebView 的背景就是該主題的 `paperColor`
- **值與幾何要分開講。** 上面那組測試把**值**（顏色 / 濃度 / 字體 / 紙墨）結構化釘住了；**幾何**（`baseFontSize` / `intrinsicLineHeightRatio` / `wordSpacingRatio` / 色帶高度）沒有任何測試，那部分仍然是紀律，而且已被檔頭具名為近似。混在一起講會讓「結構」這個詞蓋掉一半其實沒有保障的東西
- **近似之處要逐條具名**，不要假裝沒有（`ReaderSettingsPreviewCard` 檔頭列了四條，見上方 Reader Layer）。特別是使用者**看得到卻不會理解**的那種（滑桿死區、色帶粗細），漏掉它們等於讓文件的規則與示範互相否證
- 預覽綁 binding 即時更新，**不做 snapshot**
- 頂層 struct，**不 inline 進 presenter / editor 的 body** —— Debug `-Onone` 下主執行緒 1MB stack 會被 inline 的 section tree 撐爆（同 `SettingsPresenter.swift` 檔頭的約束）
- Catalog / `#Preview` 的 harness 也走真的加減與真的預覽；harness 另存一份寫死的顯示字串會與預覽互相矛盾（實測：標著 2.0x 卻畫出 1.0x 的字）

**心智模型對齊**（這是本 pattern 的另一半，不是附註）：同一族的設定頁要長得一樣、操作起來一樣。「這一族」目前指的是**帶即時預覽的偏好頁**——複習卡版面與閱讀設定兩頁，共用四項：原生 `Form` / `Section` + `SettingsSectionHeader/Footer`、toolbar `.primaryAction` 上同形的 `resetMenu`（a11y id 後綴慣例 `<scope>.resetMenu`）、**一個頁面 struct 兩個入口**（情境入口包 sheet chrome、設定 ▸ 偏好 `navigationDestination` 直接 push，頁面本體零複製）、以及下面這條擺放規則。再加一頁時照這四項抄。

（`SettingsReviewSection` 也是原生 `Form` + 同一組 header/footer，但無預覽、無 resetMenu、單一入口，所以只符合第一項——別把它當這一族的樣板。）

**Section 順序沒有共用答案，共用的是「預覽緊貼它所控制的東西」。** 兩頁刻意相反，別去「對齊」：閱讀設定的控制項全頁共用同一份 `ReaderSettings`，所以預覽只需一張、擺頁首涵蓋全部；`ReviewCardLayoutEditor` 的預覽是**該複習方向專屬**的（辨識 / 產出各一張，`VocabularyCardMode.allCases`；每一張本身都已經是翻開的樣子、兩面都畫），所以擺在各自 Picker 的**正下方**（`ReviewCardLayoutEditor.directionSection`）。

代表畫面：
- `ReviewCardLayoutEditor` / `ReviewCardLayoutEditorSheet`（編輯端）＋ `ReviewCardLayoutPreviewCard`（預覽端）
- `ReaderSettingsPanel` / `ReaderSettingsPanelSheet`（編輯端）＋ `ReaderSettingsPreviewCard`（預覽端）

---

## Current Gaps

### Gap 1: Settings 還是偏 feature-local

現況（2026-08-09 量測，`.settingsCard()` **12 個呼叫點**——第 13 個 grep 命中是 `SettingsPresenter+Controls.swift:20` 的宣告本身，不是使用）：

| 在哪 | 幾個 | 檔 |
|---|---|---|
| 主頁 section | 5 | Account / Subscription / Other / Preferences / DebugBackend 各 1 |
| 子頁 | 7 | `SettingsAccountDetailView` 3、`TranslationLanguageSettingsView` 2、`SettingsDeleteAccountSheet` 2 |

另有三頁已改用原生 `Form` / `Section`：`SettingsReviewSection`（`b64a6869c`）、`ReviewCardLayoutEditor`（`6c8a99a37`）、`ReaderSettingsPanel`（`5a87c8189`），票號 APP-20260808-240a94 / f0770b。**三者皆為同一段尚未合併的工作，還沒有在 main 上存活過任何一輪迭代**——讀下面那條方向時要知道它的地基有多薄。

影響：
- 可用，但長期容易維持兩套語言
- **這個 gap 原本寫的解法（往 shared shell 回收）已不是現行方向，但新方向的適用範圍比它看起來窄。** 那三頁清一色是**偏好 / 旋鈕頁**（Picker / Stepper / Slider / Toggle），而且是同一段工作裡的三次同一個決定、零獨立確認；剩下 7 個子頁呼叫點在帳號詳情、訂閱、刪除帳號、翻譯語言——editorial、danger 與商業 surface，原生化在那裡**零證據**。所以：**偏好 / 旋鈕類的新頁往原生 `Form` 走，其餘四處與主頁 5 處維持現狀待評估**，別把它讀成全域禁令
- **原生化不是免費的，代價已被具名接受**：自繪的 selection tile / label chip / control surface / 群組 air divider 全部退場，襯線標題與自訂間距節奏消失，主題色票縮成一列內的小色塊，頁面背景交還系統 grouped background。理由是**一致性優先**（三頁共用同一套心智模型），不是維護成本。兩處檔頭都寫了同一句話：**不要在 `Section` 內重新自繪把 editorial 個性救回來**（`ReaderSettingsPresenter+Vocab.swift` / `SettingsReviewSection.swift` 檔頭）

### Gap 2: Raw spacing magic numbers 大量存在

現況：
- Color / Font / Animation token 覆蓋率良好
- `AppSpacing` 8pt grid 已建立，但採用率低 — ReaderSettings、TranslationVocab、StatsPresenter 仍大量 raw 數字
- 新增 UI 須優先採用 `AppSpacing.sN`

影響：
- spacing 不一致，難以全局調整

### Gap 3: 28 個 View 缺少 #Preview

現況：
- 核心場景（KGVocab、Bookshelf、TodayReview、Settings）有 Preview
- 但 AddLinkSheet、WordDetailPresenter、StatsPresenter、NotebookListView 等 28 個 View 缺少

影響：
- 開發時無法快速預覽，UI 變更驗證效率低

### Gap 4: 低採用率 design system surface

現況：
- `AppSkeletonLine` 目前無外部直接 callsite（僅 def + `AppSkeletonCard` 內部 + preview）；`AppSkeletonCard` 已被 `VocabSceneShell` 採用（1 處）
- `AppLoadingStateCard` / `AppLoadingProgressBar` 已收斂 Reader、TOC、Explore、Vocab、Stats 與 Settings sync 的明確 loading/status surface；底層 indicator 統一原生 `ProgressView`
- `AppElevation` 已是全 app shadow 唯一入口（~24 callsites）；`AppCompactActionButtonStyle`（4 處）、`AppOfflineBanner`（ContentView 1 處）、`AppMotion.emphasizedDecelerate`（AppOfflineBanner 內部）皆已落地
- PR #402 曾規劃的 `AppLayout` / `AppFonts.display1/2` token **從未進入 codebase**（doc 舊版誤記為已定義）；readable-width 實際由 `WordDetailPresenter` local `maxContentWidth=640` 控

影響：
- 仍有 primitive（如 `AppSkeletonLine`）採用率低，token 漂移風險 — 安排 callsite migration 鎖定語意

### Gap 5: 已知對比缺陷

現況：
- `AppOfflineBanner` light mode 對比 ≈ 3.21:1（destructiveLight 12pt semibold on 10% destructiveLight bg），**fail WCAG AA 4.5:1**
- ~~`accentHero` dark mode 4.02:1~~ — 已解除：Phase 1b 起 brandHero 從 Morandi 藍改奶黃 `#B5894B/#C9A968`，前景採 `onBrandHero` deep charcoal `#1C1A17`，light/dark 對比 5.11/7.05:1 ✓ AA/AAA（BooksAndVocabTests/WCAGContrastTests.swift 鎖住）
- ~~`AppCompactActionButtonStyle` primary foreground raw `.white`~~ — 已解除：改走 `AppColors.onBrandHero`；奶黃 + 白字 fail AA → onBrandHero 強制 deep charcoal 是 token-level 保證

影響：
- 視覺品牌一致性 + a11y 合規邊界；polish pass PR 處理

---

## Reuse Order

新增 UI 時，優先順序如下：

1. 先看有沒有現成 pattern
2. 再選對應 component
3. 最後才補 token
4. 真的沒有才新增新元件

簡單決策：
- 是空狀態？先看 `AppEmptyState*` / `VocabEmptyState*`
- 是 loading / 進度訊息？先看 `AppLoadingStateCard` / `AppLoadingProgressBar`
- 是 success / error 訊息？先看 `AppStateMessage*` / `VocabStateMessageCard`
- 是大狀態切換？先看 `VocabStatusHero`
- 是 list + tabs + search？先看 `VocabListCard` + `VocabTabSelector` + `VocabSearchField`
- 是 panel / drawer / overlay？先看 `TranslationPanel` / `ReaderSettingsPanel` / `VocabOverlayHeader` + motion tokens
- 是 inline 小型主 CTA？先看 `.buttonStyle(.appCompactAction(...))`，不直接 `.borderedProminent`
- 是 loading list / card？先看 `AppSkeletonLine` / `AppSkeletonCard`（`AppSkeletonCard` 已用於 `VocabSceneShell`）
- 是離線 / 網路狀態提示？root 層套 `.appOfflineBanner()`；transient 通知走頂端 pill（`AppToast`，見 `docs/sop/ui-design.md`「暫時性提示」）；承載操作的狀態用 `AppStateMessage*`
- raw `.shadow(...)`？改用 `.appElevation(.zN)`
- raw spacing 數字？改用 `AppSpacing.sN`

---

## Next Recommended Step

State matrix 與 preview matrix 已建立（見 `ui_state_matrix.md`）。
新增或修改 UI 前，先跑一遍 `ui_review_checklist.md`。
