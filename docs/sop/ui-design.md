<!-- doc-meta
tier: sop
authority: SoT
update_trigger: sop-change
scope:
  - ios/BooksAndVocab/
verified_against: 2d9f6fdbebca9fe0f2aa9a790f1498dded80050d
-->
# Books & Vocab UI Design System

> 文檔網絡：
> - 開發入口與編譯流程：`docs/sop/ios.md`
> - App 架構與 UI 脈絡：`docs/sop/architecture.md`
> - 元件 / pattern 現況清單：`docs/reference/ui/components.md`
> - 狀態覆蓋矩陣：`docs/reference/ui/state_matrix.md`
> - UI Review Checklist：`docs/reference/ui/review_checklist.md`

## 設計系統概覽

Books & Vocab 使用 Notion-inspired 的 design token 系統（純淨表面、border 分層、俐落小角半徑）。**CTA 採極淡奶黃** `brandHero #FCDE9A`(pastel cream，兩 mode 同色) — Phase 1c 拍板由古銅蜂蜜金 `#E8C77F` 改淡至 `#FCDE9A`。**Chrome（tab bar / nav button / toolbar）走灰階 tint** (`tintLight #37352F` / `tintDark #E6E6E3`)，刻意不採奶黃以避免稀釋 CTA 訊號。藍色 Morandi grey-blue `accent #4D7396` 維持為**被動色**，留給 link / info / 裝飾：

| 層級 | Token 來源 | 適用範圍 |
|------|-----------|---------|
| App Shell | `AppTheme` / `AppColors` / `AppFonts` / `AppMetrics`（含 `AppSpacing`/`AppRoundness`/`AppElevation`/`AppMotion`/`ElevationDirection`） | 全 app chrome（toolbar、tab、banner、toast）。⚠️ 原生元件的**材質 / 圓角 / 陰影**不在此列——取材與舉證見 `component_sourcing`；app 自繪 chrome 才由這層管 tint / 字型 / token |
| Vocabulary Skin | `VocabSkin`（Palette / Typography / Spacing） | Vocabulary feature 所有 View |
| Reader | `ReaderContentStyle` | EPUB/PDF reader 內容樣式 |

### 環境注入

- `@Environment(\.appTheme)` — App Shell 層
- `@Environment(\.vocabSkin)` — Vocabulary 層
- 不可硬建 instance

### 元件取材政策（2026-08-08 定案，原生優先）

KG UI 的預設路徑是先找 iOS 26 原生元件：`List` / `Form` + `Section`、`Toggle`、`Stepper`、`Picker`（`.segmented` / `.palette`）、`LabeledContent`、`Menu`、`sheet` + `presentationDetents`，以及系統 toolbar / `navigationTitle`。原生元件已提供的材質、圓角、陰影與互動行為交給平台；**想要自繪必須先寫下原生做不到什麼**，不能只以「想要不同外觀」作為理由。

合格的舉證格式直接對照既有 `AppFloatingChrome`：它具名說明 Reader 關掉 `navigationBar` / `tabBar`、系統 toolbar 會改變 webview 高度，進而觸發 ReadiumCSS multicol 重排與 `totalProgression` 偏移。這種「具名 API + 因果鏈」才足以支持自繪例外。

<!-- ui-policy: component-sourcing -->
```json
{
  "component_sourcing": {
    "version": 2,
    "decided": "2026-08-08",
    "supersedes": "mochi-polaris-v1",
    "default": "native",
    "burden_of_proof": "custom",
    "native_default_components": [
      "List",
      "Form",
      "Toggle",
      "Stepper",
      "Picker",
      "LabeledContent",
      "Menu",
      "presentationDetents"
    ],
    "custom_precedents": [
      {
        "symbol": "AppFloatingChrome",
        "file": "ios/BooksAndVocab/UIComponents/AppFloatingChrome.swift",
        "reason": "Reader hides navigationBar and tabBar; a real toolbar resizes the webview, triggering ReadiumCSS multicol reflow and shifting totalProgression"
      }
    ],
    "token_scope": {
      "AppTheme": "app-drawn",
      "VocabSkin": "app-drawn",
      "AppRoundness": "app-drawn",
      "AppElevation": "app-drawn"
    },
    "surrendered": [
      "serif-section-titles-in-native-list-rows",
      "custom-section-spacing-rhythm"
    ],
    "retained": [
      "nav-bar-serif-title-via-AppFonts.configureGlobalAppearance"
    ]
  }
}
```

`AppTheme` / `VocabSkin` / `AppRoundness` / `AppElevation` 從此只在 app 自繪的形狀上有效；改用原生 `List` / `Form` / `Toggle` / `Stepper` 後，圓角、陰影與材質歸系統，不得再以 `.appElevation(.zN)` / `AppRoundedRect` 覆蓋原生元件。`ops/ui_token_lint.py` 對 raw padding / shadow / radius / color literal 的禁令方向不變，只是適用面明確收斂到自繪區。

原生化在 List row 內具名放棄襯線 section title 與自訂間距節奏；仍保留 nav bar 襯線標題，因 `AppFonts.configureGlobalAppearance()` 的 appearance proxy 已由實測證明是目前仍有效的作用。

<!-- ui-policy: mochi-polaris-v1 status=superseded -->
### Mochi 化北極星五條（2026-05 拍板）

本段的 #1 已由上方 `component_sourcing` 取材政策吸收並擴大（從 bar 擴至所有元件）；#2–#5 對 app 自繪的形狀仍有效，對原生元件不適用。

KG UI 對齊 [mochi.cards](https://mochi.cards/docs/api/) editorial 質感。以下五條為 hard rule，新 view / refactor PR 違反 → review block。

1. **內容層單色、系統 chrome 的材質不歸 app 管**　`pageBackground` 是**內容層**的唯一底色；禁止用自繪背景在內容區做分區。**系統 bar（nav bar / tab bar / toolbar item）的材質由平台決定**，目視在 Xcode 26 build 上是浮動膠囊 tab bar、玻璃 toolbar 膠囊與 bar 後的 scroll-edge 模糊——那是平台外觀，不是違反本條。
   - **禁止**對系統 bar 疊自訂 `.background` 或第二層 `glassEffect`。要調整走 `.toolbarBackground` 這類系統 API —— **但它的正當用途是可見度 / scheme（`.hidden` / `.visible` / `.toolbarColorScheme`），不是拿自己的顏色去換掉平台材質**。`.toolbarBackground(<某個色>, for: .navigationBar)` 正好是「用系統 API 做出舊規則要擋的東西」，本條**照樣擋**。（現行 `ios/` 對它有 **0 個 callsite**，沒有前例可援引。）
   - **本條約束的是系統 bar；自繪 in-content bar 另有一道門檻。** 已認可的既有案例如 `TodayReviewMetrics` 的 `topBar*Inset`（見 `docs/reference/feature_boundary/vocabulary.md`）照常用 token。但**新開一個自繪 bar 之前必須先說明「系統 bar 為什麼做不到」**——「想要不同外觀」不算理由。這個 carve-out 不是自我標記就能進的：把自繪的東西叫做 in-content 並不讓它離開本條。
   - ⚠️ **不要再把 transparent appearance proxy 當成「遵守本條」的手段，它沒有在做事**；也**不要**為了拿玻璃而刪它，刪掉會同時失去襯線標題**與 tab bar item 的 10pt 字級**（`AppFonts.configureGlobalAppearance()`）。依據與其邊界見下方實測註。

> **實測註（2026-08-06）** — 量到的範圍要跟結論一起讀，別外推。
> **量測環境**：Xcode 26.4（iOS 26 SDK —— Liquid Glass 採用是 **SDK-gated**，所以這欄是
> 關鍵變因，不是背景資訊）、iOS 26.4 simulator、iPhone 17 Pro Max、light mode、
> 兩個畫面（A = Settings sheet inline title 已捲動，zh-Hant；B = Notebooks large title
> 捲到頂，en）。
> **三個變體**：v1 = 掛 `configureWithTransparentBackground()`（現行生產碼）、
> v2 = 掛不呼叫任何 `configureWith*` 的裸 appearance、v3 = 完全不掛 proxy。
> **量到什麼**
> - **背景（null result）**：v1 / v2 / v3 三者 nav bar 背景**逐像素相同**（含 bar 後有內容
>   模糊的區域）；`UITabBarAppearance` 有無 `configureWithDefaultBackground()`，
>   tab bar 膠囊背景亦**逐像素相同**。
> - **字型（positive result）**：v1 vs v3 標題字形 **2,312 px**（畫面 A）、**18,394 px**（畫面 B）；
>   v1 vs v2 僅 **16 px**、max channel delta 3 —— 即 antialias 噪訊，視為相同（只在畫面 A 量過）。
>   換句話說：**掛 proxy 就有襯線、不掛就沒有；而掛哪一種 proxy 不影響背景。**
> - 這個 null result **只證明 proxy 的背景設定不改 bar 背景**，不證明 bar 渲染成什麼——
>   「是玻璃」來自**目視**，不是這個 diff。
> **未測**：dark mode、Mac Catalyst、iPad / regular size class、
> `compactAppearance` / `compactScrollEdgeAppearance`（生產碼在 `AppFonts.swift:302-305`
> 四個 slot 都掛，但上述兩畫面只走到 `standardAppearance` 與 `scrollEdgeAppearance`；
> 橫置 iPhone / compact height 未測）、
> `UINavigationBarAppearance.configureWithDefaultBackground()`（現行碼從未執行到它——
> `makeNavBarAppearances()` 造的 `opaque` 變體在 `AppFonts.swift:301` 被 `_` 丟棄）、
> 以及 `buttonAppearance` / `shadowColor` / `backIndicatorImage` 等其餘 `UIBarAppearance` 屬性。
> 要據此做更大的決定，先把缺的格子補測。
2. **border 退場、divider 進場**　list cards 預設無 border。分區走 `hr-style divider`（hairline + `AppMetrics.dividerAirMargin = 16` 上下 margin）+ 留白。例外：modal / popover / sticky group 必須有邊界，可保留 border。**玻璃自帶邊緣高光，不要再對玻璃元件描邊**——這是本條的延伸，不是例外。
3. **shadow 收到 z0 / z1 兩階**　list / resting cards 用 z0（無 shadow，純背景區分）或 z1（極輕）。z2 以上保留給 sheet / drawer / modal / overlay。禁止 raw `.shadow(...)`，一律走 `.appElevation(.zN)`。**玻璃元件不加 elevation**——系統的玻璃已含分層陰影，疊上去會髒。
4. **單一強調色策略**　全 app 強調色只有以下軸線，禁止為了好看引入新色：
   - `brandHero` 奶黃 — 日常 CTA（既有）
   - `accent` Morandi grey-blue — 連結 / info / 被動裝飾（既有）
   - `inlineCode` 深藍綠 — 技術 token（API 端點 / 短語引用 / ID）— **Phase 3 Notebook 套皮時隨需引入**
   - `ctaCritical` 深炭 — 不可錯過 CTA — **暫不上線**，產品決策觸發場景後再引入
5. **互動 motion 收斂**　按鈕按壓統一走 `TapFeedback` triplet；非按鈕互動禁 transform，只動 `bg-color` / `opacity`，曲線預設 `quickEaseOut`（0.15s）或 `controlEaseOut`（0.14s），對齊 Mochi `transition: bg .1s` 路線。

> 落地原則：北極星規則先於 token。新 token 於 Phase N 真正需要時才加入 `AppColors` / `AppTheme.Palette` / `AppMetrics`，避免提前累積 dormant token。Phase 路線：1 = AppSurface flat / 2 = Bookshelf / 3 = Notebook / 4 = Reader / 5 = Today Review motion / 6 = Settings / 7 = Auth / 8 = 全域 motion / 9 = docs + review。

### Mac Catalyst 平台適配

KG 的 Mac 支援走 **Mac Catalyst**（`SUPPORTS_MACCATALYST = YES`），**非原生 macOS**（核心依賴 Readium 僅宣告 `platforms: [.iOS]`）。Catalyst 下 `os(iOS)` 為 true、`os(macOS)` 為 false。

- **分流一律 `#if targetEnvironment(macCatalyst)`，禁 `#if os(macOS)`**（死碼，永不編譯）。Mac 專屬 UX 用 Catalyst 可用的 iOS API（`.onKeyPress` / `UIPointerInteraction` / `UIWindowScene`），不用 AppKit；`.pointerStyle`(iOS 18+) 在 Catalyst 不可用。
- `Platform/PlatformRepresentable.swift`：UIKit typealias（PlatformView / Color / Image / Font）。
- `Platform/PlatformCompatibility.swift`：iOS / Catalyst SwiftUI modifier wrapper；含取 `UIWindowScene` 的先例（`connectedScenes.compactMap { $0 as? UIWindowScene }.first`）。
- `Platform/MacWindowChrome.swift`：Catalyst 視窗 chrome 單一來源。`.defaultSize` / `.windowResizability` 在 Catalyst **靜默無效**，視窗尺寸改走 UIKit `sizeRestrictions.minimumSize` + `requestGeometryUpdate(.Mac(...))`，尺寸常數集中此處。Reader 沉浸 title bar 走 `setTitlebarHidden` **scoped 可逆**（進 Reader 隱藏、離開復原，不可在 App 啟動時全域設死，否則其他頁失去標題列）。
- Reader 系列以 `#if os(iOS)` 整檔隔離 —— Catalyst 下 `os(iOS)` true **仍編譯仍啟用**（非死碼）。
- 其餘 View 共用，平台差異以條件編譯處理。

**指標 / hover 回饋**（`UIComponents/HoverHighlight.swift`）：

- `.appHoverLift()`：卡片 hover 時輕微 scale 浮起（1.02）。卡片屬按鈕互動，scale 合 Motion Contract；已 gate `accessibilityReduceMotion`（Reduce Motion 退回無 transform）。
- `.appHoverRowTint()`：扁平可點 list-row hover 時 bg tint（`primaryText.opacity(0.05)`，只動 background，合「非按鈕互動禁 transform」）。卡片型可點走 `.appHoverLift` / 既有 `.liftable`，不重複套 tint。
- `.appPointerHover(_:)`：chrome 控制項（chip / segment / pill / plain icon button）的桌面指標層，包 UIKit `.hoverEffect`（預設 `.highlight`）。Catalyst / iPad 觸控板下指標 morph 貼合元件 + 系統 highlight。`.pointerStyle`(iOS 18+) 在 Catalyst 不可用，故用 `.hoverEffect` 而非自訂 cursor 形狀（Catalyst 慣用指標層，非 pointing-hand）。套用：`AppFilterChipBar` / `AppTabSelector` / `VocabSortPill` / `VocabReviewCTAPill` / `VocabChromeIconButton` / `AppFloatingChromeButton`。
- **不分流**：`.onHover` / `.hoverEffect` 在純觸控 iPhone 無指標事件自動 no-op，iPad 觸控板 + Mac Catalyst 共益，故 hover / pointer modifier **不**包 `#if`。

---

## Motion Contract

Books & Vocab 的 motion system 不接受各頁自由書寫 `.spring(...)` / `.easeOut(...)`。
動畫必須優先走 `BooksAndVocab/Models/AppMetrics.swift` 中的 `AppMotion` 與共享 `AnyTransition` 語意 token。

### 核心原則

1. 先選語意，再選數值。
2. 同一類互動跨 feature 必須共用同一 token。
3. feedback 要成對出現：
   視覺 feedback 與 haptic feedback 應一起設計。
4. 不為了「有在動」而加動畫。
   animation 只服務於 state change、hierarchy、feedback、continuity。

### AppMotion 語意層

| Token | 用途 | 目前主要路徑 |
|------|------|-------------|
| `panelState` | panel / drawer / settings 開合 | Reader、Translation、Graph Settings |
| `panelSnapBack` | drag release 回位 | TranslationPanel |
| `headerState` | compact / expanded header 切換 | Reader header |
| `phaseChange` | 流程狀態切換 | Sync、Settings 狀態卡 |
| `feedbackPulse` | 成功保存、數字跳動、局部確認 | Translation save、Sync step、Review feedback、Toast |
| `contentFade` | 短暫內容淡出 | Reader progress / transient overlay |
| `loadingState` | loading 文案、loading overlay 的 state swap | Reader loading |
| `reviewRevealSpring` | review front/back/details 展開 | Today Review |
| `reviewNavigationSpring` | review 上一張 / 下一張 / 洗牌 | Today Review |
| `reviewCardSwapSpring` | review 回答後換卡 | Today Review |
| `panelState` + `AnyTransition.bannerReveal` | toast pill 進出（Reduce Motion 改 `overlayFade`） | AppToast（全 app，見「暫時性提示」） |
| `emphasizedDecelerate` | 非對稱進場曲線（Material 3） | AppOfflineBanner、未來 sheet/panel 進場 |
| `emphasizedAccelerate` | 非對稱退場曲線（Material 3） | 未來 sheet/panel 退場 |
| `subtleBreath` | 2.4s easeInOut autoreverse | `AppSkeleton` pulse、empty state 呼吸 |
| `shimmer` | 1.4s linear repeatForever | skeleton mask（dormant，待 callsite） |
| `TapFeedback` triplet | `scaleDown 0.97` / `opacityDip 0.92` / `animation` | PressableInteraction / ButtonStyle 統一按壓物理感 |
| `cardDeckRelease` | `spring response=0.28, dampingFraction=0.85` | `NotebookDeckButtonStyle` release/cancel 回彈（press-in 走 `TapFeedback.animation`） |

### Transition 語意層

| Token | 用途 |
|------|------|
| `overlayFade` | scrim、暫時性 overlay、toolbar 進出 |
| `readerPanelReveal` | 底部 panel / drawer 進出 |
| `feedbackBadge` | saved / success 類 badge |
| `linkedOverlayCard` | linked card 疊層卡片 |
| `modalSwap` | 同區塊登入/登出、模式切換 |
| `statusRowReveal` | Settings / status row 延伸顯示 |

### 禁止事項

- 不要在 feature 檔案裡直接寫新的 `.spring(response:...)`，除非先把它提升為 `AppMotion` 語意 token。
- 不要為相似 overlay 各自定義不同 transition。
- 不要把 loading、success、error 都混用同一個動畫。
- 不要用 `.default` 當正式產品互動動畫。

### Feature Mapping

- Reader：
  `panelState`、`panelSnapBack`、`headerState`、`loadingState`、`feedbackBadge`
- Review：
  `reviewRevealSpring`、`reviewNavigationSpring`、`reviewCardSwapSpring`、`overlayFade`
- Sync：
  `phaseChange`、`feedbackPulse`、`blurReplace`
- Settings：
  `modalSwap`、`statusRowReveal`
- Toast：
  `panelState` + `bannerReveal`（Reduce Motion：`overlayFade`）；畫面內面板：`phaseChange` + `statusRowReveal`
- Graph：
  `panelState`（settings panel）、`linkedOverlayCard`

### 文件責任

- 若是要改 token 定義：
  先更新 `BooksAndVocab/Models/AppMetrics.swift`
- 若是要改互動規則：
  先更新本頁，再改程式
- 若是要排查編譯或 SwiftUI 實作錯誤：
  回到 `docs/sop/ios.md`
- 若是要理解 UI 為何出現在某個資料流程中：
  回到 `docs/sop/architecture.md`
- 若是要新增 spacing/elevation 數值：
  先在 `AppSpacing` / `AppElevation` 加 token，不可在 view 寫 magic number
- 若是要決定某個元件的圓角：
  **不要新增 token** —— 圓角只有五階（見下方 `AppRoundness`）。照**尺度規則**挑：
  短邊 ≲30pt → `pill`；30–70pt → `control`；>70pt → `card`；方形圖示 → `icon`。
  尺度規則優先於角色名稱：比例制下同一個 token 在 44pt 與 227pt 上分別是 3.3pt 與 17pt，
  所以「它是一張卡片」不足以決定用 `card`，得先看它多大

---

## 暫時性提示：頂端 pill 與畫面內面板（#2047）

所有暫時性提示（通知、已完成、輕度警告、輕度錯誤）統一用頂端滑出的小 pill；需要使用者決定或操作的狀態留在該畫面內的面板。實作：`UIComponents/AppToast.swift`（外觀）、`UIComponents/AppToastCoordinator.swift`（`AppToastQueue` 純狀態機＋計時），契約測試 `BooksAndVocabTests/ToastNotificationTests.swift`。

### 選哪一種

| 情境 | 用 | 例 |
|------|----|----|
| 一次性通知：已完成、背景結果、輕度警告／錯誤 | 頂端 pill：`toastCoordinator.success/info/warning/error` | 已複製、已刪除、同步完成、儲存失敗 |
| 需要使用者決定或操作的**持續狀態**（重試、完成、關閉） | 畫面內面板：`AppStateMessageCard`（App Shell）／`VocabStateMessageCard`（Vocabulary 層）＋ `.appCompactAction` 具名按鈕 | 快取資料過期＋重試、刪除待同步＋重試、新增連結警告的重試／完成 |
| 破壞性操作確認、需明確知悉的阻斷結果 | 系統 `.alert` / `.confirmationDialog` | 移除未同步單字、登入已過期、帳號刪除失敗 |
| 持續性環境狀態（不是事件、也不需操作） | 既有專屬 strip：`AppOfflineBanner`、`DemoBanner` | 離線、Demo 模式 |

1. **pill 只負責通知，不放按鈕**（沒有 undo／retry／action）。需要操作就用面板；兩者互斥，不擴充 pill 的 action API。
2. 面板因**使用者操作的結果**而新出現時，另外彈一則 pill（面板可能不在視線內）。進畫面時自動載入失敗只顯示面板：面板就是進頁第一眼，pill 只會每次進頁重複出現（對齊 `ExplicitSync`「自動同步靜默、顯式同步回饋」）。
3. `AppBanner`（內容流橫幅）已退役（#2047）：產品呼叫點歸零、元件已移除。暫時性用途改 pill，承載操作的改面板。

### pill

- **位置**：頂端 overlay；root 與每個 `toastSheet`／`toastFullScreenCover` 內容層都掛 `toastOverlay()`，所以 sheet 裡也看得到。Liquid Glass 小膠囊，`style` 決定語氣色與預設 icon；外緣留 `AppShellMetrics.pageHorizontalPadding`，長字截斷在膠囊內而不是貼齊螢幕邊。
- **時長**：success／info 2.5 秒，warning／error 4 秒；可上滑提前關閉。VoiceOver 開啟時同時朗讀，計時照常。
- **進出場**：`AppMotion.panelState` 驅動 `AnyTransition.bannerReveal`（自頂端滑入＋淡入）；Reduce Motion 改 `overlayFade`。同一事件就地取代只換字（`contentTransition(.opacity)`），不重播進出場。
- **佇列**（`AppToastQueue`）：
  - 事件身分＝`AppToastItem.key`，預設 `style|message`，重複的同一則自然合併；文案會變的同一事件（進度數字、同一來源的新結果）由呼叫端傳穩定的 `key:`。
  - 同 key → 就地取代並重設計時（顯示中或等待中皆然）。
  - 不同 key → 排隊；同時最多 `AppToastQueue.capacity` = 2 則（顯示中 1＋等待 1）。
  - 滿了 → 等待中較不嚴重的那則讓位（error > warning > success／info，同級留最新）；新來的比等待中的都不重要就丟棄。顯示中那則不會被擠掉。
  - 下一則在前一則退場後再等 `AppToastCoordinator.handoffDelay`（0.35 秒，對齊 `panelState` 退場）才進場：兩則 pill 不交疊、不原地換字。
- **文案**：預設單行。`lineLimit(1)` → 先縮小到 0.8 → 尾端截斷，**不換行**。上限 `AppToastItem.copyBudgetColumns` = 40 欄（中日韓全形字 2 欄、其餘 1 欄 ⇒ 約 20 個全形字或 40 個英文字元；DEBUG 超限記 log）。失敗清單、原因、下一步這類較長說明放面板。文案一律走 `L10n.string`／`L10n.format` 並過 `ops/i18n_lint.sh`。
- **展開（#2862，唯一的多行狀態，由使用者觸發）**：縮小後仍放不下（自然寬 × 0.8 > 可見寬）的 pill 顯示 `chevron.down` 並可輕點；點擊就地展開成完整多行（`lineLimit(nil)`、icon 頂對齊、圓角由 pill 過渡到 card、寬度上限 560pt），再點收合（回到單行、尾端截斷，**收合不關閉通知**）。未截斷的 pill 不可點、外觀不變；展開外觀與可點性都以「當前文案是否截斷」為閘，同 key 取代成短文案時殘留的展開狀態不生效。上滑關閉在兩種狀態都有效。`isExpanded` 在 `AppToastCoordinator`，root 與 sheet overlay 共用同一份狀態、同步展開，不各自計時。Reduce Motion 下展開／收合只淡入淡出。展開時自動消失計時重排為 `max(時長, 8 秒)`；收合時恢復該則的正常時長。展開狀態在該則退場時重設，同 key 取代時保留。佇列中的下一則等展開的那則退場後才進場，不會餓死。VoiceOver 仍朗讀完整文案；可展開時以 `accessibilityAction(.default)` 提供與輕點同一路徑的展開／收合，並只在可展開且未展開時附 `accessibilityHint`（`toast.expand.hint`）。點擊區以負 inset 外擴到 44pt，不改變視覺尺寸。
- **事件 vs 狀態**：pill 是事件。狀態值不變但又發生一次（例如連續兩次下拉都「已是最新」）也要再通知，呼叫端以事件序號（例：`KGVocabCoordinator.noticeRevision`）觸發，不要拿狀態值的變化當觸發。
- **選取器**：`app.toast`，label 為文案，`accessibilityValue` = `success`／`info`／`warning`／`error`。

### 畫面內面板

- `AppStateMessageCard`／`VocabStateMessageCard`：title 寫狀態，description 放補充說明（可多行），accessory 放具名 `.appCompactAction` 按鈕（主要動作 `.primary`，關閉 `.outline`），不用裸 glyph。
- **位置**：該畫面內容流頂端（受影響內容上方），隨內容捲動；不是 overlay。
- **進出場**：插入點掛 `.transition(.statusRowReveal)`，容器以 `.animation(AppMotion.phaseChange, value: <狀態>)` 驅動，不得跳變。
- **生命週期**：狀態解除（重試成功、使用者關閉）才消失；不自動計時消失。

---

## Layout / Spacing / Elevation token（Models/AppMetrics.swift）

PR #402 七階段升級補完語意分層。新元件優先使用以下 token，舊 `AppMetrics.spacing*` 保留為相容別名。

| Token tier | 內容 | 採用率 |
|-----------|------|--------|
| `AppSpacing` | 8pt grid：`s0=0/s1=4/s2=8/.../s7=64`、`hairline=1`；語意 alias `cardOuterPadding/innerGap/sectionGap` | 部分 — 新元件已切，舊 view 仍多 raw 數字 |
| `AppRoundness` | **無因次圓度 t**：`none=0 / card=.15 / control=.30 / icon=.45 / pill=1`。實際半徑由 `AppRoundedRect` 在 render 當下算出：`r = t · min(W,H) / 2`。圓角一律走 `AppRoundedRect(roundness:)` / `AppUnevenRoundedRect(top:bottom:)`，**不得**直接用 `RoundedRectangle` / `Capsule()`（`ops/ui_token_lint.py` 會擋，例外需行內 `// token-allow:`） | **live — 全 app 圓角唯一入口** |
| ~~`AppRadius`~~ | **已刪除**（連 `DesignTokens.Radius` 也不再輸出到 Swift）。舊值 `xs=4/sm=6/md=8/lg=12/xl=16/pill=999`；本表過去寫的 `sm=8/md=12/lg=16/xl=24` 從來就是錯的，比實際碼大一階。`radius.*` 現為純 web token，只餵 `backend/static/kg-*.css` | 不存在 |
| `AppElevation` | `z0...z4` 替代 `paperFloat`/`cover`/`panel` 命名；`.appElevation(.zN)` modifier；dark mode 透過 `AppElevationModifier` 自動加強 opacity | **live — 全 app shadow 唯一入口，~24 callsites**（AppSurface / AppToast / Card / cover / overlay / 各 presenter）。raw `.shadow(...)` 一律改走此 token。 |
| `AppFonts.hero` / `TypeScale.hero` | 40pt serif hero typography（`TypeScale`：caption2/caption/subhead/body/h2/h1/hero，無 display1/2）；`AppFonts.hero(weight:)` 取用 | 視場景使用 |
| `AppFonts.Tracking` / `LineSpacing` | letter-spacing / 行高 token | 部分 |

舊 `AppShadows.panelOpacity` 在本 PR 由 0.70 → 0.18（paper-tone shadows）；後續逐步以 `AppElevation` 取代分散的 paperFloat/cover/panel 命名。

### Editorial imperfection / static rotation

某些 editorial 元件（如 `NotebookStackedCoverView` 的 cream paper ghost）需要 deterministic 微旋轉帶入「桌上隨手疊」手感。**Rotation 屬 layout 非 motion** 時 — i.e. 角度在 mount 後不再改變、不隨 state 動畫 — `accessibilityReduceMotion` **不關閉** rotation。Apple HIG 的 RM 規範針對動態 motion；靜態 visual rotation 與 Wallet/Books 既有圖示同性質、不適用 RM gate。

落地規則：
- Rotation 角度由 deterministic seed 推得（如 `NotebookStackMetrics.stableSeed(for:)` djb2 over utf8），**禁用 `String.hashValue`**（per-process random seed 會導致跨 launch 角度跳動）
- Rotation 不參與 press / 任何 state transition
- Reduce Motion 仍關 offset/scale 動畫；只保留 rotation 與 opacity dip

Precedent callsite：`NotebookStackedCoverView` editorial stack。

---

## Color token：Brand Hero + 狀態 bg

`AppColors.brandHeroLight` `#FCDE9A` (HSB ~41°/0.39/0.99) / `brandHeroDark` `#FCDE9A` (兩 mode 同色) + `AppColors.brandHero(_:)` scheme-aware accessor。色相為極淡奶黃 pastel cream(Phase 1c)，與 `accent`(Morandi blue) 分家 — `brandHero` 主 CTA，`accent` 退為被動點綴。`onBrandHero` 採 `#1C1A17` 深炭灰(白字 fail AA)，配新奶黃對比 ~13.5:1 ✓ AAA。**`tint` 走灰階 chrome** (`tintLight #37352F` / `tintDark #E6E6E3`)，不再跟 brandHero — chrome ≠ CTA。

`AppTheme.Palette` 新欄位：
- `accentHero` — 品牌 hero 主色（scheme-aware）
- `accentSubtle` — 弱化 accent
- `successBg` / `warningBg` / `infoBg` / `destructiveBg` — 10% tint 狀態背景，配狀態前景文字
- `borderStrong` — 加強邊框（給 outline button 等）

`VocabSkin.Palette` 已整合 brand hero 三色階。

---

## 新 primitives（UIComponents/）

PR #402 引入：

- `AppCompactActionButtonStyle` — 取代 `.borderedProminent.controlSize(.small)`，inline 主 CTA；`.appCompactAction(.primary/.neutral/.outline/.destructive)`
- `AppOfflineBanner` — `.appOfflineBanner()` modifier，root 層套用；訂閱 `NetworkMonitor.shared.isConnected`
- `AppSkeletonLine` / `AppSkeletonCard` — Loading 骨架 primitive；列表/內容骨架使用此元件
- `AppLoadingStateCard` / `AppLoadingProgressBar` — 明確 loading/status/進度 primitive；需要狀態文案或進度時使用這組，不自製裸 `ProgressView`

---

## Dark Mode 故事

- **Paper-tone 統一**：`AppShadows.panelOpacity` 0.70 → 0.18，整 app shadow 改走低對比浮紙語意。Reader/large panel 視覺層次降低，refactor 後續以 `AppElevation` 取代。
- **Dark mode brand tint**：`accentHero` 在 dark mode 走 `brandHeroDark`；`AppElevationModifier` 在 dark mode 自動加強 shadow opacity，避免黑底黑影失語意。

---

## Known Polish Debt

下列 issue 已知，列入後續 polish pass PR：

1. ~~**`AppOfflineBanner` light mode 對比 ≈ 3.21:1**~~ — 已解除。banner 前景已是 `primaryText`（灰階高對比）非 destructive 紅字；primaryText 疊於 destructiveBg（destructive 10~14% tint over pageBackground）實測 light ~9.85:1 / dark ~11.6:1 ✓ WCAG AAA。原 3.21:1 為「紅字當前景」的舊設計數據，已不適用。
2. ~~**`accentHero` dark mode footgun**~~ — 已解除。Phase 1b 起 brandHero 改奶黃，前景採 `AppColors.onBrandHero` deep charcoal `#1C1A17`，light/dark 變體配 onBrandHero 對比 5.11/7.05:1 ✓ AA/AAA。
3. ~~**`AppCompactActionButtonStyle` primary foreground raw `.white`**~~ — 已解除。改走 `AppColors.onBrandHero` token；奶黃 + 白字 fail AA → onBrandHero 強制 deep charcoal 是 token-level 保證。
4. **低採用率 tokens**：`AppSkeletonLine` 目前無外部直接 callsite（僅 def + `AppSkeletonCard` 內部 + preview）；`AppSkeletonCard` 已用於 `VocabSceneShell`、`AppElevation` 已是全 app shadow 唯一入口（~24 callsites）。注意 PR #402 曾規劃的 `display1/2` / `appReadableFrame` / `AppLayout` token **從未進入 codebase**，勿引用。

---

## Component Hard Rules（防破圖）

以下規則適用所有 list row / inline metric / 中英混排場景。新元件 PR 違反 → review block。

1. **List row 內所有 user-content text 必須有 `.lineLimit(n)` + `.truncationMode(.tail)`**  
   不限定 row 高度時，至少要 truncate 而非 wrap 撐高（破壞 list 節奏）。Word/title 一般 `lineLimit(1)`；中譯/說明可 `lineLimit(2)` 但仍要 truncate。
2. **數字 metric 一律 `.monospacedDigit()`**  
   `42d / 2d`、百分比、進度、剩餘秒數等任何會動態變動的數字。避免比例字寬抖動。例：`VocabReviewProgressBar.detailLabel`、`WordRow.trailingLabel`。
3. **同 row 含 text + spacer + button 時 spacer 必須有 `minLength: 8`**  
   防止內容擠壓到 trailing element 黏 leading text。
4. **partOfSpeech / unit / 短 label 用 `.fixedSize(horizontal: true, vertical: false)`**  
   保留視覺重量，防止被中間 text 撐到換行。
5. **新增高密度 list 元件時，必加對應 `Debug/Scenarios/*Scenarios.swift`**  
   涵蓋 happy / long-content / large-numbers / narrow-width / dynamicTypeSize(.accessibility3) 五種 stress case，作為 visual baseline。範例：`NotebookListScenarios.swift`、`BookCardScenarios.swift`。

6. **可點擊元素用 `Button`，不用 `.onTapGesture`；觸控區 ≥ 44pt**
   `.onTapGesture` 沒有 button trait、沒有選中狀態、也不保證命中區（#2053：色票 32×32、圖樣選項、row tap 都曾如此）。選擇器／row 一律 `Button { … } label: { … }.buttonStyle(.plain)`，label 內 `.frame(minWidth/minHeight: AppFloatingChromeMetrics.hitTarget)` + `.contentShape(Rectangle())`，選中狀態用 `.accessibilityAddTraits(.isSelected)`（先例：`NotebookEditPickerMetrics`、`ReaderThemeGlassPickerMetrics`）。確實需要手勢（與 `onLongPressGesture` 並存、全頁背景收鍵盤等）時，在 modifier chain **之後**宣告 `.accessibilityAddTraits(.isButton)` / `.accessibilityAction(…)` / `.accessibilityHidden(true)`，或行內標 `// a11y-allow: <語意在哪裡／為何不需要>`。`ops/tap_a11y_lint.sh` 守門（`--baseline-check`，baseline 為空、零容忍；`// a11y-allow:` 才是例外通道，不要往 baseline 加 key）。

> Phase 2(2026-05) 起 `WordRow` / `VocabReviewProgressBar` 已套用上述規則。新元件 PR Reviewer 看到缺漏直接退件。
