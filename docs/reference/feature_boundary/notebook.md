<!-- doc-meta
tier: reference
authority: derived
update_trigger: code-change
scope:
  - ios/BooksAndVocab/Views/Vocabulary/Scenes/NotebookListView.swift
  - ios/BooksAndVocab/Views/Vocabulary/Scenes/NotebookListCoordinator.swift
  - ios/BooksAndVocab/Views/Vocabulary/Scenes/NotebookReconciler.swift
  - ios/BooksAndVocab/Views/Vocabulary/Scenes/NotebookEditSheet.swift
  - ios/BooksAndVocab/Views/Vocabulary/Components/Notebook*.swift
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# Notebook Feature Boundary

> Notebook 是 Vocabulary feature 的子場景(不獨立成 `Views/Notebook/` 目錄,
> 檔案分散於 `Views/Vocabulary/Scenes/` 與 `Views/Vocabulary/Components/`)。
> 與 `Views/Vocabulary/` 的整體 scope 邊界一起讀:`docs/reference/feature_boundary/vocabulary.md`。

## 檔案清冊

### Scenes Layer（容器 / 主場景）

| 檔案 | 說明 |
|------|------|
| `Scenes/NotebookListView.swift` | 主場景 `struct NotebookListView: View`。**Unified LazyVStack book-row layout** — 所有 notebook 一律 full-width row(取消 hero/grid 分支)。**單欄 drill-down 導航(2026-06 #671 收斂)** — notebook row 一律 `NavigationLink(value: notebook.remoteId)` → `navigationDestination(for: String.self)` push `VocabularyListView(notebookId:)`,所有 layout(含 regular / Catalyst)皆然;舊「regular row button selection + 右側 `safeAreaInset` inline 第二欄 + 可拖拉分隔線」雙欄已移除,連帶刪 `NotebookActivationMode` / `NotebookSelectionPolicy` / `NotebookMasterDetailMetrics`(收斂後零引用)及 `selectedNotebookId` / `containerWidth` / `reconcileSelectedNotebook` 等 inline 專屬 state。**Inline pill cluster**(取代舊 banner + toolbar buttons):`今日複習` page section header + `VocabReviewCTAPill` + filter pill(`notebooks.count >= 2` 才顯示,觸發 `NotebookFilterPickerSheet`) + 新增 pill,全部在 ScrollView 內。Pill cluster 與 notebook list 間用 `AppAirDivider`(hairline + 32pt margin)分區,不再用整盒 border 切割(Mochi 北極星二)。**Toolbar 只剩** `[sort] [archive]`。Notebook stats/CTA due 計算使用 review pause reference date。 |
| `Scenes/NotebookListCoordinator.swift` | `@Observable @MainActor final class NotebookListCoordinator`，導航 + sheet 狀態 + cover photo 編輯流程（含 `photoError` + `originalCoverImagePath` 延遲刪 + 取消還原）。`reconcileNotebooks` 只負責 fetch + 失敗時 `NotebookReconciler.ensureOfflineDefault` 占位；reconcile 純邏輯已抽至 `NotebookReconciler`。`deleteNotebook` 對 local-only 本子（`remoteId` 前綴 `local-` 或 `syncStatus==0`）跳過 server 呼叫，只做本地刪除（避免 404 throw 鎖死孤兒）。**active notebook 後端化**：`coldStartActiveNotebook`（登入且本機 `snapshot.updatedAt==nil` 時 `getUserConfig` → `ActiveNotebookStore.applyServerState`，僅寫本地不回寫 iCloud）+ `pushActiveNotebook(id,updatedAt:)`（切換後 best-effort PUT `vocab_ui`，不 rollback）；全域 active notebook 游標讀寫一律收斂於 `Models/ActiveNotebookStore`（三層 LWW，見 `docs/sop/architecture.md` storage audit + `serverVocabUiLwwEnabled` flag）。 |
| `Scenes/NotebookReconciler.swift` | `enum NotebookReconciler`（純邏輯、無 IO、不 save，對齊 `PodcastSyncService.reconcileLocalState` 範式）。`reconcile(remote:local:allEntries:modelContext:)`：upsert + tombstone（`syncStatus==1` 缺席→刪）+ **reap 孤兒**（`local-*` 且 `syncStatus==0` 的離線占位本，在有真本時硬刪、殘留 entry 改派 `default`）+ cascade（僅 tombstone 真本下 entries `queueDelete`）；回傳轉不可見 remoteId 集合供清 `activeNotebookId`。`ensureOfflineDefault`：離線無可見本時建 `remoteId=="default"` sentinel 占位（非隨機 `local-UUID`），真本同步進來 upsert 就地合併、不分裂幽靈本。修「多個『我的單字本』」client↔server 不一致根因。 |
| `Scenes/NotebookEditSheet.swift` | `struct NotebookEditSheet: View`，建立/編輯 notebook sheet（含 cover system 選色/選 pattern/匯入照片） |

### Components Layer（可復用元件）

| 檔案 | 說明 |
|------|------|
| `Components/NotebookCard.swift` | `struct NotebookCard: View` — **HStack book-row,固定 72pt 高**(取代舊 VStack `EditorialCoverComposition` overlay 設計)。**Mochi Phase 3:整卡外框 stroke 已移除**(北極星二 border 退場),靠 `cardBackground` vs `pageBackground` 色差 + 卡片間留白分區。Cover 40% 寬左欄:`coverColor` 底 + 統一 noise pattern (opacity 0.04) + 可選 `NotebookCoverPattern` 疊層 + serif italic name `AppFonts.serif(size: 17, bold: true).italic()` 左上 + active 5pt 圓點(`NotebookPalette.darken(cover, by: 0.5)`,取代舊 3pt spine / 「使用中」pill)+ 1pt editorial rule(寬 cover×0.3,同 darken 0.5)。0.5pt 垂直 `cardBorder` rule 切隔(書背隱喻內部結構,保留)。Metadata 右欄:`N 詞` monoLabel + (`actionableCount = dueCount + unlearnedCount` > 0) 5pt warning 圓點 + count(與「今日複習」入口徽章同口徑:到期複習 + 未學新卡,#863) + `ProgressCapsule`(4pt, fillColor=coverColor);`cardCount == 0` 顯示「尚未加入單字」placeholder。**Dark mode**: `coverColor` 自動套 `NotebookPalette.darken(_, by: 0.55)`(contrast test 鎖)。內含 `struct NotebookCardActions`(line 8,context menu callbacks)與 `struct NotebookCardData`(line 29,view data)為同檔 inline struct,非獨立檔。 |
| `Components/NotebookStackedCoverView.swift` | Editorial 立體堆卡。**新增 `showsName: Bool = true` 透傳至內層 `NotebookCoverView`** — NotebookCard 套 editorial overlay 時傳 false 避免雙層 name。其餘維持:彩色封面 + cream 紙頁三階 ghost,deterministic rotation + dx jitter,`NotebookDeckButtonStyle` press env。 |
| `Components/NotebookStackMetrics.swift` | 立體堆卡 token 集中地。**新增 `patternOpacity: Double = 0.12`** — `NotebookCoverPatterns` 6 種 pattern 統一引此 token(noise 例外,保動態公式)。其餘維持 `layerCount` / offsets / rotations / `stableSeed` / `ghostPaperColor`。 |
| `Components/NotebookCoverPatterns.swift` | 6 種 SwiftUI Canvas pattern 渲染(dots / lines / grid / waves / circles / noise)+ `NotebookCoverView`(頂層封面實體 view)。**新增 `showsName: Bool = true`** — gate 中央白字 name 渲染。5 處非 NotebookCard callsite(Bookshelf / Podcast / EditSheet / StackedCoverView / #Preview)default true zero-touch。pattern stroke/fill opacity 統一引 `NotebookStackMetrics.patternOpacity`。 |
| `Components/NotebookPalette.swift` | 12 色 Morandi 色票 + `color(for:)` + **新增 `darken(_:by:)` HSB helper**(brightness ×(1-amount),hue/sat 保留;cover hairline rule / D3 spine / dark mode cover 用)。 |
| `Components/NotebookFilterChip.swift` | filter chip：全部 / 有待複習 / 已學完 / 自訂排序 |
| `Components/NotebookStatsCalculator.swift` | `struct NotebookStats` + `enum NotebookStatsCalculator { static compute, static filtered }`。Pure 聚合與篩選邏輯，從 NotebookListView 抽出後可獨立 unit test（覆蓋 due/unlearned/reviewed/pending/lastActivity 分支）。`NotebookSortOption.sort(stats:)` 唯一外部 caller。 |
| `Components/NotebookDetailPresentation.swift` | `struct NotebookDetailPresentation: ViewModifier`，NotebookListView 唯一的 word-detail/today-review 呈現分支。**2026-06 #671 收斂後一律 modal**(不再分 layout):word-detail → `toastSheet(WordDetailSheet.appSheet(.large))`、today-review → `platformFullScreenCover(TodayReviewPhaseView)`。舊 iPad/Mac inline 可拖拉 panel(`safeAreaInset(.trailing)` + `DraggableDivider` + `@AppStorage("kg_detail_panel_width")` + `layoutMode` 分支)已移除。today-review 唯一 inline 入口仍經 shared `DetailRouter`(`.environment(\.detailRouter)`)觸發。 |
| `Components/NotebookHeaderPillLabel.swift` | `struct NotebookHeaderPillLabel<Content>: View`，Today Review action bar 三 pill（CTA/filter/plus）共用的視覺規格（Capsule，~27pt 高）。 |

---

## 改動規則

- **新增 notebook list UI** → `NotebookListView`，狀態組裝抽到 `NotebookListCoordinator`
- **新增 notebook card 樣式** → `NotebookCard` HStack book-row(cover 40% 左 + metadata 右);新增 cover pattern 走 `NotebookCoverPatterns` + 在 enum 加 case + opacity 引 `NotebookStackMetrics.patternOpacity`
- **新增 cover 配色** → `NotebookPalette` 加 case；保持 12 色限制（UI 一致性）
- **新增建立/編輯欄位** → `NotebookEditSheet` 表單；驗證邏輯走 coordinator
- **新增 notebook 操作（archive / share / export）** → `NotebookCardActions`（`Components/NotebookCard.swift:8` inline struct）context menu + `NotebookListCoordinator` 加 action handler
- **新增 filter / sort** → `NotebookFilterChip` 擴 enum；資料層走 SwiftData `@Query` predicate
- **改動 notebook 統計／篩選邏輯** → `NotebookStatsCalculator`（pure，加 unit test 於 `NotebookStatsCalculatorTests.swift`）；改 sort comparator 走 `NotebookSortOption.sort(stats:)`
- **改動 notebook 與卡片的綁定關係** → 涉及 `resolveNotebookId` chokepoint / `sanitizeOutbox` / `triggerPipelinesIsolated`，動之前讀 `docs/sop/architecture.md` §Notebook 同步 + `docs/reference/sync_lifecycle.md`
- **改動 notebook reconcile / 孤兒回收 / 離線占位** → 純邏輯走 `NotebookReconciler`（加 unit test 於 `NotebookReconcilerTests.swift`，鏡像 `PodcastReconcileTests`）；`reconcileNotebooks` 只做 fetch + 委派。離線占位本一律用 canonical `"default"` sentinel，**禁**隨機 `local-UUID`（會製造永遠回收不掉的重複「我的單字本」，client↔server 不一致根因）

## State 邊界

- `NotebookListCoordinator`：notebook 列表的導航、sheet、cover photo 編輯狀態（含取消還原機制），由 `NotebookListView` 持有
- Notebook 資料模型來自 SwiftData，**不**放 coordinator
- `NotebookEditSheet` 的編輯草稿狀態為 sheet-local，submit 才走 coordinator 持久化
- Notebook ID 解析必經 `resolveNotebookId` 單一入口（防 orphan）
- 帳號偏好與 active notebook 游標仍沿用既有 `UserDefaults` / iCloud KVS / server projection API；登入帳號存在時，`ReviewSettingsStore`、`TranslationLanguage` 與 `ActiveNotebookStore` 的 durable keys 以 account namespace 隔離（account identifier 不直接進 key）。`AuthManager` 在登入、冷啟動與恢復 session 邊界啟用 namespace；切換或無帳號時先暫停舊 projection，再由 `SettingsCoordinator` 以 account generation 與 user identity 驗證非同步 response。延遲的舊帳號 response 不得套用到新帳號。第一次啟用 authenticated account 時，各 preference family 只將既有 legacy keys 明確遷移一次；後續帳號不重複繼承 legacy state。直接使用 guest/preview API 的 caller 仍可明確選擇 legacy namespace，但 app 的 logged-out/demo 邊界維持 suspended projection。delete_account 只清除「被刪除帳號」的 `kg.account.<digest>.*` 偏好（本機 `UserDefaults` 與 iCloud KVS），其他帳號不受影響；legacy-migration marker 保留，防止之後的帳號重新領養 raw 值。review-card-layout 的領養紀錄同時寫入 iCloud KVS，同一 Apple ID 的其他裝置不會再把保留的 KVS raw layout 領養給後續帳號。sign-out 僅移除本裝置已領養的 pre-account raw layout。
- Active notebook 的 raw key 僅作當前帳號的 UI compatibility projection；notebook/card ownership、backend schema/API 與既有產品資料模型邊界不因 account namespace 改變。

## 共用依賴

| Token | 用途 |
|-------|------|
| `VocabSkin` | 共用詞彙 feature design token（cover / banner 顏色） |
| `AppTheme` | 色彩，`@Environment(\.appTheme)` |
| `AppMetrics` / `AppShellMetrics` | 間距、尺寸 |
| `AppMotion` | 動畫 token |
| `NotebookPalette` | 12 色封面色票 |

## 相關 doc

- `docs/reference/feature_boundary/vocabulary.md` — 母 feature 的整體 scope（含 KGVocab / TodayReview / Sync）
- `docs/reference/sync_lifecycle.md` **(SoT)** — notebook ↔ 卡片 sync 狀態流轉
- `docs/sop/architecture.md` §Notebook robustness — `resolveNotebookId` / `sanitizeOutbox` / `triggerPipelinesIsolated` 防禦設計
- `docs/reference/product_surface.md` §Notebook bookshelf — 已實作功能清冊
