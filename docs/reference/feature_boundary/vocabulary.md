<!-- doc-meta
tier: reference
authority: derived
update_trigger: code-change
scope:
  - ios/BooksAndVocab/Views/Vocabulary/
  - ios/BooksAndVocab/Services/
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# Vocabulary Feature Boundary

> Notebook 是本 feature 的子場景,獨立 boundary 見 `docs/reference/feature_boundary/notebook.md`(`Scenes/Notebook*` + `Components/Notebook*`)。

## 檔案清冊

### Container Layer（組裝 + 路由）

| 檔案 | 說明 |
|------|------|
| `VocabularyListView.swift` | 主容器 `struct VocabularyListView: View` |
| `VocabularyListView+State.swift` | 狀態持有 extension |
| `VocabularyListView+Toolbar.swift` | toolbar extension |
| `VocabularyListView+Sheets.swift` | sheet 槽 extension |
| `SyncView.swift` | `struct SyncView: View`，同步畫面容器 |
| `KnowledgeGraphView.swift` | `struct KnowledgeGraphView: View`，知識圖譜容器；graph ratio 使用 review pause reference date |

### Coordinator Layer（導航協調）

| 檔案 | 說明 |
|------|------|
| `VocabularyListCoordinator.swift` | `@Observable @MainActor final class VocabularyListCoordinator` |
| `KnowledgeGraphCoordinator.swift` | `@Observable @MainActor final class KnowledgeGraphCoordinator` |
| `Scenes/KGVocabCoordinator.swift` | `@Observable @MainActor final class KGVocabCoordinator`，batch delete / archive 收斂集中於 coordinator；archive 的本地可收斂集合為 `updated_words ∪ not_found`，`failed` 才保留重試 |
| `Scenes/SyncCoordinator.swift` | `@Observable @MainActor final class SyncCoordinator`，含 `SyncFailureKind`；`PipelineStep` / `SyncPhase` 已移至 `Services/SyncProgress.swift`（設定頁的逐步同步進度共用同一組型別）；所有 Card 經同一個 vocab projection 收斂 |
| `Scenes/AddLinkCoordinator.swift` | `@Observable @MainActor final class AddLinkCoordinator`，集中既有詞庫候選搜尋與 manual-link begin/create/commit 的流程狀態；`linkingTargetCardID` 標示進行中的列（連結中忽略再次點擊，不 cancel 重送），`AddLinkActionError` 各自有 `reason`／文案／`isRetryable`，可重試者經 `retryLastAction()` 重送 |
| `Scenes/AddLinkCreationOutcome.swift` | `AddLinkCreationFailure`（以後端 `error_code` 或 client 代碼 `timed_out`／`operation_not_found`／`offline`／`not_authenticated` 分類；`interrupted` 與舊 `cancelled` 同為 interrupted；`target_archived`／`target_is_source`／`source_unavailable`／`quota_exhausted`／未登入不可重試）與 `AddLinkCreationWarning`（`enrichment_failed`／`link_projection_pending`／本地 `local_projection_failed`） |
| `Scenes/AddLinkCreationCoordinator.swift` | `@Observable @MainActor final class AddLinkCreationCoordinator`，守衛本地 pending／failed／archived target，提交單一 idempotent missing-target operation、輪詢 durable steps，完成後交給既有 serialized vocabulary pull 做 canonical projection；A 的 context 只作 B 的義項判斷線索，不在本地建立帶有 A 內容的 B 卡片。時間與 key 來源經 `AddLinkCreationEnvironment` 注入（測試 seam：pollInterval／sleep／idempotency key／`pollTimeoutNanoseconds`（預設 90 秒，含 POST）／單調 `now`）；重試 key 策略由純值 `AddLinkCreationRetryPlan` 決定——POST 未收到回應沿用同 key、輪詢斷線續輪詢同一 operation、operation 已終態失敗（含 interrupted、client 逾時、輪詢 404）才換新 key。target 正規化 `cleanedQuery`/`canonicalWord` 對齊後端 `_clean_content` + `find_by_content`（去尾端 `.,;:!?`、NFC、小寫，重音有別；候選搜尋也用 `cleanedQuery`，`run.` 與 `run` 列出同樣的字）。有警告的成功停在 `succeededWithWarnings`，`retryWarnings()` 只重跑未完成部分（缺解釋重排 pipeline，再 pull），`acknowledge()` 回 `idle` |
| `Scenes/AddLinkCreationHub.swift` | `@Observable @MainActor final class AddLinkCreationHub`（`.shared`），missing-target 建立流程的**長壽命 owner**：sheet 關閉不取消，hub 持有 coordinator 直到完全成功／使用者移除失敗或警告項（警告 job 以 `.warning` 留在來源卡、可重試；`acknowledge` 的 `idle` 亦由 owner 移除）；把每個 job 鏡射到 durable record 與 `PendingLinkProjection`，`resume(services:)`／`resume(kgService:container:)` 於下次進入複習或詳情時補查（依 operation id 續輪詢，或以同 key 重送未回應的 POST），source 卡已不存在者丟棄。**帳號邊界**：record 帶 `userId`（讀 `AuthManager.shared.userId`，經 `userIDProvider` 注入），`resume` 先丟棄非目前帳號（含未蓋章舊 record）的 job；`clearAll()`（由 `LocalDataCleanerService.clearLocalData` 於登出／切帳號呼叫）取消 live coordinator、清 jobs／UserDefaults／projection 並通知畫面重建 |
| `Scenes/PendingLinkCreationStore.swift` | `PendingLinkCreationRecord`（持久化 operationId／idempotencyKey／terminal 旗標）、`PendingLinkCreationStoring`（UserDefaults；`-isolatedAuthSession` 走 ephemeral；record 以 `userId` 分帳號）、`PendingLinkProjection`（lock 保護的 sourceCardID → 「建立中」placeholder 值，供非 main-actor 的 `CardPresentation` 讀取）、`KGCardLinkSummary.pendingCreation`（`pending-create:<jobKey>` id、無 cardId，狀態編碼於 `reason`） |
| `Scenes/PendingLinkDetailSheet.swift` | 點「建立中」連結項目的詳情：顯示單字、狀態文字與逐步進度（觀察 hub／coordinator，隨進度補上），完成自動關閉並轉為一般連結；失敗顯示訊息、重試與移除 |
| `Scenes/ReviewLinkEntryResolver.swift` | 複習 session 的連結目標／候選池改以 live store 解析（session `linkedEntryLookup`／`allEntries` 只是開場快照，session 內新建的卡不在其中）；`AddLinkSheetRequest` 於點 + 當下凍結來源卡與候選池 |

### Presenter Layer（純 UI 呈現）

| 檔案 | 說明 |
|------|------|
| `Scenes/VocabularyListPresenter.swift` | `struct VocabularyListPresenter<Content>: View` + `VocabularyListPresenterState` |
| `Scenes/KGVocabPresenter.swift` | Books & Vocab 詞彙列表佈局；`KGVocabRowSelection` 控制 row detail highlight，selection mode 期間 suppress highlight，避免 detail selection 與 batch selection 混淆；row review progress 使用 review pause reference date |
| `Scenes/KnowledgeGraphPresenter.swift` | 知識圖譜佈局 |
| `Scenes/WordDetailPresenter.swift` | `struct WordDetailPresenter: View`；`WordDetailInspectorMetrics` 將右側 inspector 內容限寬 320–640pt，metadata footer 走 `CollocationFlowLayout` capsule flow，避免桌面窄欄 HStack 擠爆。**卡片生命週期動作依成本分層**：封存在標題列（`archivebox` ⇄ `archivebox.fill` 單擊切換，`canArchive` 對未同步卡收起——`archiveCard` 以 word+notebookId 定址伺服器，未同步必 404）；刪除壓在內容最底的 `cardManagementSection`，與卡片隔一條 `AppAirDivider`，並收編原本孤懸的「閱讀時不標記此單字」toggle |
| `Scenes/SyncPresenter.swift` | 同步主佈局；`statusSymbol(for:)` / `detailColor(for:)` 已改為委派共用的 `SyncStepStatusIcon`（`UIComponents/`），不再自持一份六態 switch —— 設定頁的逐步同步進度是第二個消費者，見 `docs/reference/ui/components.md` |
| `Scenes/SyncPresenter+Header.swift` | 同步 header |
| `Scenes/SyncPresenter+ActionArea.swift` | 同步 action 區域 |
| `Scenes/SyncPresenter+Preview.swift` | 同步 preview 資料 |
| `Scenes/StatsPresenter.swift` | 統計畫面佈局；forecast 與 graph thumbnail 使用 review pause reference date |
| `Scenes/ReviewCalendarPresenter.swift` | 複習日曆佈局 |
| `Scenes/TodayReviewPresenter.swift` | 今日複習主佈局；翻卡路徑含 `PerfLog` render/layout tick，autoplay 答案揭露後朗讀；由 `@Environment(\.reviewCardLayoutStore)` 讀 profile 供卡片動態排版 |
| `Scenes/ReviewCardView.swift` | `struct ReviewCardView: View` —— **一張完整的複習卡**（正面摺頁 ＋ 右上角 chrome ＋ 背面摺頁 ＋ PaperFoldModifier），輸入全是資料（`ReviewCardContent` / profile / viewport），**不吃互動狀態**（IMP-20260808-ee7ca4 把它從 `TodayReviewPresenter` 的 extension 抽出；`TodayReviewPresenterState.CurrentCard` / `.LinkGroup` 現為 `ReviewCardContent` / `ReviewCardLinkGroup` 的 typealias）。它同時是**profile-driven 動態佈局的渲染端**——依 `ReviewCardRenderPlan` 決定各欄位出現在哪一面、把三層量測（natural / intermediate / compact）餵給 `ReviewCardLayoutSolver`、按解出的 policy 畫（例句 radius、解釋行數、搭配詞列數、知識連結 presentation、section spacing）。翻卡 front/back surface 與 radius 計算含 `PerfLog` instrumentation |
| `Scenes/ReviewCardNotebookBadge.swift` | 卡上「所屬單字本」標示的純值層（`TodayReviewView` 於 session 開始時查一次 `Notebook` 放進 `@State`，**不使用 `@Query`**——複習頁對 body 重算敏感）：`ReviewCardNotebookBadgeResolver` 只在 session `queue` 涵蓋 ≥2 個 `notebookId` 時產生標示（單一單字本入口回空表）；`entry.notebookId` 對 `Notebook.remoteId`（`default` sentinel 退認 `isDefault`），名稱查不到用本地化備援、永不顯示 id。`ReviewCardView` 以 overlay 畫在正面頂部留白，不進 layout／solver 預算 |
| `Scenes/ReviewCardHitTargetButton.swift` | 卡內「＋」新增連結（連結列尾與空狀態入口）的按鈕外殼：label 隱藏當版面佔位、真按鈕疊在上方，可點範圍與 accessibility frame ≥ `TodayReviewMetrics.addLinkHitTarget`（44pt）而版面尺寸不變——直接 `.frame(minHeight: 44)` 會撐高連結區、讓 solver 量到的 section 高度跳動 |
| `Scenes/TodayReviewPresenter+Toolbar.swift` | toolbar extension；「忘記 / 記得」副標 = 目前卡的下次複習間隔（#3135，`ReviewGradeIntervalHints` ← `Models/ReviewIntervalProjection.swift`，與 flush 寫入同一函式；不再顯示 session 計數）。autoplay controls 含聲音開關。播放鍵的可按性 = `isAutoPlaying || canAutoplay`：**守衛只擋開始、不擋停止**，否則就重造 autoplay 出不去的 bug；其 identifier 固定為 `todayReview.autoplayToggle`（a11y label 會隨播放狀態翻轉，靠 label 選取會在切換瞬間選不到）。版面編輯器入口（`rectangle.split.2x1`）與 autoplay 播放/暫停的 language-independent identifier（`todayReview.autoplay.playing|paused`）皆在此，入口與其他 chrome 共用 `isCardInteractive` 鎖 |

### State Layer（狀態定義）

| 檔案 | 說明 |
|------|------|
| `Scenes/TodayReviewState.swift` | `@Observable @MainActor final class TodayReviewState`，複習場景 owner；持有 scoring / persistence / analytics / cache orchestration、review intent gating（自動播放中被擋的操作集合是 `autoplayBlocks` 單一真相，`performReviewIntent` 守衛與 view 層提示 pill 共用，#2046）與 collocation substate，同時把 queue+reveal 導航委派 `TodayReviewSessionState`；`refreshPeerDependentCards()`（linked-card overlay 堆疊數變化、或 `peerChipFingerprint`（queue 連結 peer 的 isArchived／syncAction 指紋）變化時由 view 呼叫；對已備卡 `refreshLinks(forPreparedEntries:)` 原地重算連結並沿用量測，再 prewarm，#2535／#2133）；`finalizeSnapshotAfterFlush(completed:)` 只在 `completed && !hasUnflushedAnswers` 時清 snapshot，否則重寫，使 restore 能補 flush（#3123） |
| `Scenes/TodayReviewSessionState.swift` | `struct TodayReviewSessionState<Entry>`，純 session/navigation domain state；封裝 queue / currentIndex / revealStage / shuffle（只重排未作答的槽，已作答者釘住，#2482）/ next / previous / completion 判定，以及 `canAutoplay`（loop 每圈只有翻面與推進兩種動作，兩者皆不可能＝死路，播放鍵須停用而非沉默 no-op） |
| `Scenes/TodayReviewSessionPersistenceController.swift` | `struct TodayReviewSessionPersistenceController`，封裝 queue persistence metadata / snapshot / deferred flush；讓 `TodayReviewState` 不直接操作 `ReviewSessionPersistence`。同時保存佇列各列的 `queueEntryIDs`（列自身 UUID）：deferred flush 先以列 UUID 解析，sync 把 kgCardId re-key 後答案仍寫入同一列；persistence id 只作 fallback，兩者皆無才視為已刪除並 info log 丟棄（#3123）；snapshot 每列同寫 `entryID`，restore 同序解析（列 UUID 優先、persistence id 為 fallback，還原列採目前 persistence id，#3169） |
| `Scenes/TodayReviewCardCache.swift` | `struct TodayReviewCardCache`，封裝 current/next card cache、prewarm window 與 rebuild。**fling 每幀不得重建 `CardDocument` 或重走 paragraphs**——欄位資料在此預先整理好，只在 profile / 寬度 / Dynamic Type / 卡片 identity 改變時才重算（原 `PostExampleMetrics` 已隨動態佈局移除）。**`refreshLinks(for:)`**（建立中連結的狀態更新）只換卡的連結內容並**沿用 `measurementCache`**，僅在連結 item 集合改變時丟棄 graph-links 一節的量測（`invalidateGraphLinksMeasurements`）；`rebuild` 會重置整張卡的量測，只留給真正的 succeeded→連結 轉換（`onLinked`）；`build`／`buildOne`／`prewarm`／`rebuild`／`refreshLinks` 皆帶 `peers`（review 路徑的 peer lookup，省略即殘留 archived／delete-queued 的 chip，#2535）；`refreshLinks(forPreparedEntries:)` 對已備卡原地重算連結並沿用量測（#2133）；不再有全量丟棄的 `invalidateAll` |
| `Scenes/TodayReviewAutoplayController.swift` | `@Observable @MainActor final class TodayReviewAutoplayController`，封裝 autoplay playback state / settings persistence / loop task。**`@Observable` 是契約不是風格**：4 個 playback 狀態由 `TodayReviewState` 的 computed property 投影給 `TodayReviewView.body` 讀，型別若無 registrar 則切 autoplay 不會 invalidate view（開啟方向被 loop 的 `session` mutation 延遲自癒、關閉方向永不自癒 → 播放列永久卡住）。把持有它的 `let` 改成 `var` 不能代替。`task` 必須 `@ObservationIgnored`（每卡 restart loop = 每卡兩次假通知）。`pauseForInterruption()` 只暫停不啟動且**刻意不自動恢復**。由 `TodayReviewAutoplayObservationTests` 釘住 |
| `Scenes/TodayReviewCollocationState.swift` | `struct TodayReviewCollocationState`，封裝 collocation explanation 的 scene-local mirror 與 entry mutation；讓 `TodayReviewView` 不再直接持有 explanation mirror / save 流程 |
| `Scenes/WordDetailSceneState.swift` | `@Observable @MainActor final class WordDetailSceneState`，封裝 presenterState、`actionError`（原 `linkError`，現為所有卡片層級動作共用的單一失敗事件來源；#2047 起 `WordDetailSheet` 把它轉成頂端 error pill 後即 `dismissActionError()` 消化，不再渲染 banner）與 link / archive mutation orchestration；讓 `WordDetailSheet` 退回 scene 組裝與 routing。**錯誤生命週期規則**：成功只清同類動作留下的錯誤，否則失敗訊息會活過後續的成功動作。`setArchived` 是 async（對齊 `KGVocabCoordinator.handleBatchArchive`），失敗回捲採 compare-and-swap + `!entry.isDeleted` 守衛——await 期間背景 pull 可能帶回權威值並 `markSynced()`，無條件寫回會用舊值蓋掉新鮮值且不再推送 |
| `Presentation/ReviewSessionStore.swift` | `struct ReviewSessionStore`，複習 session order 持久化；使用 `kg:<cardId>` / `local:<uuid>` persistence id、user scope 與 queue fingerprint |

### Domain Layer（純規則 / mutation helper）

| 檔案 | 說明 |
|------|------|
| `Domain/VocabularyGraphLinkMutation.swift` | `struct VocabularyGraphLinkMutation`，集中 manual-link optimistic insert / commit / rollback、hide/unhide 與 delete rollback；`TodayReviewView` / `WordDetailSheet` 共用同一套 graph-link mutation 規則 |

### Presentation Models（UI 資料轉換）

| 檔案 | 說明 |
|------|------|
| `Presentation/VocabularyEntryPresentation.swift` | `enum VocabularyEntryPresentation`，詞條 UI 模型 |
| `Presentation/WordRowPresentation.swift` | 詞列行 UI 模型；review state/relative label/progress 支援注入 `now` |
| `Presentation/WordDetailPresentation.swift` | `enum WordDetailPresentation`，詞條詳情 UI 模型 |
| `Presentation/CardPresentation.swift` | `struct CardPresentation` + `CardLinkGroupPresentation` |
| `Presentation/KnowledgeGraphPresentation.swift` | `KnowledgeGraphNode` / `KnowledgeGraphEdge` / `KnowledgeGraphTheme` / `enum KnowledgeGraphPresentation` |
| `Presentation/StatsPresentation.swift` | `enum StatsPresentation`；`buildSummary(..., now:)` 支援 frozen review clock |
| `Presentation/KGVocabSortOption.swift` | `enum KGVocabSortOption` |

### Scenes（獨立場景 View）

> Notebook 場景(`Scenes/NotebookListView.swift` / `NotebookListCoordinator.swift` / `NotebookEditSheet.swift`)獨立 boundary 見 `docs/reference/feature_boundary/notebook.md`,本表不重列。

| 檔案 | 說明 |
|------|------|
| `Scenes/KGVocabView.swift` | `struct KGVocabView: View`，Books & Vocab 詞彙列表場景；持有 `selectedRowID` 以在 desktop 三欄工作流中保留「目前右側 detail 對應哪一列」的中欄視覺狀態，filtered rows 移除該 id 時自動清空。整頁 error state 用固定重試文案，避免把低階 error message 直接暴露到 UI；清單頂端提示依 #2047 拆成兩個出口（`KGVocabBanner.panel`／`.pill`）：待刪除與可重試的同步錯誤是畫面內面板（`vocab.statusPanel`，具名重試／關閉），其餘結果（成功、不可重試、部分失敗）以 `KGVocabCoordinator.noticeRevision` 觸發頂端 pill；分類/sort 使用 review pause reference date |
| `Scenes/ReviewModeSheet.swift` | `struct ReviewModeSheet: View` 辨識⇄產出切換面板（#2042 Stage 3）＋ `ReviewForgettingSlider`：`DragGesture` 拉桿，底圖重用 `ReviewGradientBar`，預設右端＝歸零；觸點→level 換算為純函式，確認才回傳 level |
| `Scenes/ReviewModeEnvironment.swift` | `ReviewModeSwitchAction` 與 `EnvironmentValues.reviewModeSwitchAction`（ReviewCardView ⋯ 選單的切換動作，nil ＝不顯示）；`VocabularyCardMode.toggledReviewMode` / `switchTargetLabelKey` 為方向與文案單一定義 |
| `Models/ReviewProgressAdjustment.swift` | `enum ReviewProgressAdjustment`：拉桿 level → `keep`／`reschedule`／`reset` 的純函式映射（0 保留、≥0.92 吸附歸零、中間值間隔 × (1−level) 不低於有效初始間隔） |
| `Models/VocabularyEntry+ReviewAdjustment.swift` | `VocabularyEntry.applyReviewProgressAdjustment(_:now:initialIntervalHours:)`：套用映射結果並排入 `pendingReviewProgressReset`（override push） |
| `Scenes/TodayReviewView.swift` | `struct TodayReviewView: View` + `TodayReviewSession` + `TodayReviewRevealStage`；scene 組裝、sheet/shortcut chrome、外部 env wiring。版面編輯器掛在此的 `.toastSheet`：開啟時**先擷取當下卡片的 mode**（不是 sheet build 時的 current）、暫停 autoplay，關閉只翻 presentation flag，**不碰 reveal stage / currentIndex / session 持久化** |
| `Scenes/TodayReviewPhaseView.swift` | `struct TodayReviewPhaseView: View`，複習階段切換場景 |
| `Scenes/TodayReviewSwipeDeck.swift` | swipe deck：常駐三 card slot 組裝（`cardSlotView`/`deckDepthShell` 恆駐 depth-2）+ swipe gesture + fling settle 機械（`completeFling` 的 no-anim 內容抽成 `settleDeckAfterFling`：釋放姿態 / 背面放閘 / 釘高 / 推進；settle 只重隨機被回收 slot 的 rotation）+ 方向標記 `swipeMarkers`（#2045：三個 slot 常駐 overlay、置於姿態 modifier 前跟著卡片位移旋轉，只有 active 吃 swipeOffset；「記得 / 忘記」不透明度 = `TodayReviewFling.markerOpacity`，由 swipeOffset 連續推導、無結構切換、不改 layout 高度、不吃命中；正式進程不進 a11y，僅 UITest 進程以 `todayReview.swipeMarker.{remembered,forgot}` + 強度值暴露，另有 `todayReview.swipeMarkerPeak.*` 峰值探針——presenter `swipeMarkerPeak` 在手勢入口 `recordSwipeMarkerPeak` 累計、放開後保留，供 press-drag 阻塞下斷言「標記曾出現」）。fling 期間置 `dismissPhase == .animatingOut`，卡片離場後才清——`isCardInteractive` 因此涵蓋整個 fling/推進窗口 |
| `Scenes/TodayReviewCardSlot.swift` | Phase 4 常駐三 slot 純邏輯（slot = index % 3，active/preview/underPreview/hidden）：`TodayReviewCardSlotLayout`（role 指派 + 統一線性 depth transform/borderOpacity 純函數）+ `TodayReviewCardSlotModel`；settle = transaction 內三向 role 輪替、存活 slot 零內容 diff |
| `Scenes/TodayReviewDeckHeight.swift` | 卡片區高度過渡的純規則（#2026）：`plan`（hold / snap / animate，同高恆等、終點 = 新高度、啟動與答案展開時 snap）、`slotHeight`（非 active cap 到 min(過渡值, 目標)；展開中已 settle 的 active 由 `settledBack` 讓非 active cap = 背面總高，使翻面前後卡片區高度連續；展開中背面總高變動（縮短／增長）由 `RevealLatch.tracking` 無動畫追蹤、cap 不留快照縫；active 只在過渡中釘高，穩態 `nil`）、`slotHeightUpdate`（對 **slot 自己上次的值** 去重，不對卡片量測快取）。高度由單一 `deckShellHeight` 以 `reviewNavigationSpring` 過渡，**不走 dismissProgress**；起點由 `settleDeckAfterFling` 的 `pinDeckHeight` 釘在畫面當下的 layout 高度；previous / shuffle / next / autoplay 不經 fling，改由 `RevealLatch`（reveal settle 後記下背面總高、以 cardKey 識別）在翻面當幀接手（`effectiveShell`），retarget 後丟棄；`clipBleed` 在 active 被釘高的過渡期只裁底邊（變高時內容不得溢進展開區）。刻意不做 `interpolated(from:to:progress:)`：動畫中途 retarget 時 @State 只有 model 值、讀不到畫面值，會跳回舊目標 |
| `Scenes/TodayReviewFling.swift` | fling 過渡的純規則（#2027）：swipe 放手 / 按鈕 / ReviewProbe 全經 `plan`（終點、凍結 intensity = 方向符號、`AppMotion.swipeFling(duration:)`（bounce 0）時長只依「升頂還剩多少」連續放大，飽和的 swipe 放手 = 原 SwipeFling 0.18、按鈕最長 ×1.6），`flingCard` 只有一條 withAnimation；`dismissProgress` 200pt 映射拖動與 fling 同源、刻意不改（fling 中 body 只以終值求值、preview 沿同一 spring 插值）；`toolbarIntensity` 在凍結值歸零前讀凍結值 —— settle no-anim 不歸零凍結值，由 `completeFling` 下一個 runloop 以 spring 放鬆；`markerOpacity`（#2045）= 沿方向位移 / 閾值、0 起線性漸入、閾值飽和、反向恆 0 |
| `Scenes/TodayReviewSwipeMarker.swift` | 方向標記的 UITest 契約（#2045，純值）：`TodayReviewSwipeMarkerKind` 的 a11y id 與強度值格式（`%.2f`，夾在 0…1）、`TodayReviewSwipeMarkerPeak` 手勢峰值純值；page object 鏡射同一份 id，單元測試鎖定 |
| `Scenes/TodayReviewPreviewData.swift` | preview 資料 |
| `Scenes/TodayReviewMetrics.swift` | TodayReview feature-local 版面 metrics(`static let`,~44 個)。動態佈局新增三顆共用 token：`foldSectionSpacingCompact`（精簡最後一階的 section 間距）、`foldMeaningLineSpacing`（等同卡片一直在畫的 5pt，預設佈局要重現現況就必須同號）、`revealZoneMinHeight`（「點一下展開」區的高度下限，solver 從正面預算扣的與畫面讓出的是同一顆） |
| `Scenes/ReviewCardLayout.swift` | **動態佈局的純值層**（無 SwiftUI import）：`ReviewCardFace` / `ReviewCardContentAvailability`（可用性與 profile 分離——缺資料只是本次不畫，不從使用者的偏好裡刪掉；`graphLinks` 恆可用，因為空連結時畫的是加連結入口，濾掉等於拿走唯一入口）/ `ReviewCardViewport`（容器高度 → contentHeight / revealZoneReserve / frontHeight / backHeight 的**單一來源**，正面預算刻意不隨 reveal 階段變動）/ `ReviewCardRenderPlan`（profile × mode × availability → 兩面欄位）/ `ReviewCardChrome`（padding 與 solver 扣的 inset 同一份）/ `ReviewCardLayoutSolver`（**O(fields) 純函式，每個 section 最多走訪一次、不留狀態**，固定精簡順序見下方「動態佈局契約」） |
| `Scenes/ReviewCardTemporaryDetail.swift` | `struct ReviewCardTemporaryDetail`（#2041）：精簡卡「暫時看詳細」的純值層——一次只記一張卡的 `reviewCardKey`、`toggleState`（只有 `.compact` preset 才有按鈕）、`renderProfile`（只把那張卡的方向升成 `.standard`，不另做版面）、`prospectiveBlockFields`（精簡時先以隱藏 probe 量好詳細會多出的欄位，展開才動畫到真高度）。僅 `TodayReviewState` 持有，換卡即清，**不得寫入 `ReviewCardLayoutStore`／`NotebookSettings`** |
| `Scenes/ReviewCardLayoutEditor.swift` | `struct ReviewCardLayoutEditor: View` + `ReviewCardLayoutEditorSheet`。**一個 View struct 供兩個入口共用**（複習 toolbar sheet + Settings navigation destination），只有外殼 chrome 不同；**不得 inline 回 presenter body**（真機 Debug 1MB main stack，同 `SettingsPresenter` 約束）。直寫 `ReviewCardLayoutStore`（工具列遇到有 override 的單字本時改寫該本 override，見 `ReviewCardLayoutStore` 條目的 scope 說明）、不持 draft，所以卡片與編輯器不可能各說各話；勾選走 `ReviewCardField.toggling` 重排回 `canonicalOrder`（開關是可見性決定，永遠不是排序決定） |
| `Scenes/TodayReviewSessionSnapshotStore.swift` | `TodayReviewState` session snapshot 持久化；佇列列的 `entryID` 為 optional，舊快照缺欄位時退回 persistence id 還原（#3169） |
| `Scenes/ReviewFoldSurface.swift` | `struct ReviewFoldSurface` + `ReviewFoldChevronPill` |
| `Scenes/ReviewScoringState.swift` | 複習評分子狀態 |
| `Scenes/ReviewSessionPersistence.swift` | 複習 session 落地/恢復邏輯 |
| `Scenes/SelectionModeState.swift` | 列表多選模式狀態 |
| `Scenes/OverviewTab.swift` | `struct OverviewTab: View`，Vocab 入口 overview tab |
| `Scenes/AddLinkSheet.swift` | `struct AddLinkSheet: View`，KG 手動加連線 sheet；搜尋同 Notebook 的既有詞條並把流程狀態委派 `AddLinkCoordinator`，本地無此字時（即使有部分符合候選）提供建立並連結入口，已連結的精確符合顯示「已連結」；既有詞條（候選「新增連結」與 Return 精確符合，皆經 `selectEntry`）與新詞共用同一個 `AddLinkCreationCoordinator` operation pipeline（#3115：進度面板顯示 `existing_card` 跳過的步驟、關閉 sheet 不回滾）；無 operation 服務時才 fallback 到同步 `AddLinkCoordinator.startLinkExisting`；候選列（#3111，取代 #2407「點列即連結」）：收合時一行（word · 詞性 · 中譯；AX 字級可折成兩行）加兩顆 44pt 按鈕「新增連結」（`addLink.local.result.<id>.link`）與「打開卡片」（`.openCard`）；點列本體只展開／收合，一次一列（`AddLinkRowDisclosure` 純 reducer），不連結、不開卡；展開內容為全部 sense、例句（`CardExampleView`，`showsFooter: false`）、變化形與來源（與例句重複的 context 不重印）；「打開卡片」以 nested `WordDetailSheet` 呈現，返回時 query 保留；搜尋字變更即收合。連結中的列顯示 `addLink.row.linking.<cardId>` 並鎖定所有列的連結按鈕；只有完全成功自動關閉，警告需按完成；送出的 context 是 A 的 sense clue，不是 B 的例句。開啟即 focus 搜尋框；每次 render 只算一次候選（`AddLinkSearchSnapshot`），lookup marker／列表／選列共用 |
| `Scenes/AddLinkRowDisclosure.swift` | `struct AddLinkRowDisclosure`（#3111）：候選列展開狀態的純 reducer。`send(.toggleRow)` 只切換展開（一次一列，不回傳連結效果）；`.link`／`.openCard` 回傳對應 `Effect` 交 sheet 執行且不改展開；`.queryChanged` 收合 |
| `Scenes/AddLinkSearchIndex.swift` | `AddLinkSearchIndex`，sheet 持有的逐詞條搜尋鍵快取（locale-folded word／translation、正規化 word）；以原始字串比對失效，locale 變更即清空；`localCandidates` 預設用拋棄式 index，行為等同未快取（#2406） |
| `Scenes/AddLinkSearchSnapshot.swift` | 一次 query 的衍生值：trimmed query、`localCandidates`、`exactTargetState`（有輸入即算，部分符合候選旁也要能判「建立」）；純值，與逐處重算結果相同 |
| `Scenes/AddLinkStepCopy.swift` | `enum AddLinkStep`：後端六個 step id（順序即後端回報順序）→ 描述該步實際動作的 `addLink.step.*` 文案；`AddLinkCreationCoordinator.initialSteps()` 只從這裡取標籤 |
| `Scenes/AddLinkCreateCopy.swift` | `enum AddLinkCreateCopy`（#2037）：建立入口的純文案——完整動作句 `addLink.create.title`（新字＋來源字，超過 20 字元截斷、折疊空白、字內引號換成 `'`）與副行 `addLink.create.notebook`（單字本名稱由 `ReviewCardNotebookBadgeResolver` 解析，永不顯示 id）。舊 key `建立` 不改義 |
| `Scenes/AddLinkConnectivity.swift` | `enum AddLinkConnectivity`（#2039）：以 `NetworkMonitor.isConnected` 判定 sheet 能否做 server 工作；離線時提供提示文案、建立入口的停用原因與狀態轉換 toast，純值 |
| `Scenes/AddLinkReturnKey.swift` | `enum AddLinkReturnBehavior`（#2038）：搜尋框 Return 的純函數（`resolve(snapshot)`）——完全相同的可連結字→`linkExact`、完全相同已連結→`alreadyLinked`、部分符合／不可連結→`dismissKeyboard`、本地無此字→`revealCreate`；永不建立、永不在部分符合間猜選；`submitLabel` 隨狀態變（`.join`／`.done`），`accessibilityValue` 供 UITest 讀決策名（隱藏元素 `addLink.return.action`） |
| `Scenes/AddLinkCreateRow.swift` | 建立入口視圖：兩行文字的 `addLink.create` 按鈕，另以隱藏元素鏡射 `addLink.create.title`／`addLink.create.notebook`（Button 會合併子元素） |
| `Scenes/ReviewCardLinkStrip.swift` | `ReviewCardLinkStripLayout`（每組顯示哪幾個、「+N」是多少、展開後至多 `expandedLimit`=20 個、能否展開）與 `ReviewCardLinkExpansion`（綁單張卡的記憶體展開狀態＋展開期間 graph-links 量測 key 的 variant）；純值，畫面與測試共用 |
| `Scenes/AddLinkCoordinator.swift` | `@Observable` 加連線流程狀態機；本地候選搜尋與 manual link 的 begin/create/commit 在此收斂 |
| `Scenes/AddLinkCreationProgressView.swift` | missing-target operation 的進度外殼；直接使用 Settings 的 `SettingsSyncProgressPanel` 與 `PipelineStep`，保持同一套進度視覺語言；失敗顯示 `addLink.error.reason`（value＝原因碼）、可重試才給 `addLink.creation.retry`、`addLink.creation.backToSearch`；警告逐項列出未完成部分（`addLink.creation.warning.item.<code>`）並給重試與 `addLink.creation.warning.done` |
| `Scenes/WordDetailSheet.swift` | `struct WordDetailSheet: View`，負責 scene 組裝、routing 與 sheet chrome；link / archive orchestration 委派 `WordDetailSceneState`。封存後**刻意不 dismiss**（圖示翻轉即回饋兼 undo）；刪除走 `.alert`（與批次刪除同一 presentation，#2963）並**指名損失**（連結數取自 presenterState），確認後 `queueDelete` + dismiss。`offersLifecycleActions` 由 `showsInlineChrome` 推導：唯一為 false 的宿主 `LinkedCardOverlayStack` 自繪 header，封存鈕本就不渲染，若不一併關掉刪除，該疊層會變成「只能刪不能封存」 |
| `Scenes/WordDetailCopy.swift` | `enum WordDetailCopy`，詳情頁文案（慣例對齊 `NotebookListCopy`）。`deleteMessage(linkCount:)` 依連結數分流，無連結時不印「0 條」 |
| `Scenes/WordEditSheet.swift` | `struct WordEditSheet: View` |
| `Scenes/ArchivedVocabSheet.swift` | `struct ArchivedVocabSheet: View` |
| `GraphWebView.swift` | `struct GraphWebView: UIViewRepresentable` + `GraphForces` |
| `GraphThumbnailWebView.swift` | `GraphThumbnailHolder` + `GraphThumbnailCoordinator` + `GraphThumbnailWebView`，跨 tab 切換存活的圖譜縮圖 WKWebView（不可互動、載入同 `graph.html`） |
| `AutoSyncMonitor.swift` | `struct AutoSyncMonitor: ViewModifier`，監看 `pendingEntries`、auto-sync toggle、網路離線→連線恢復事件並 debounce 觸發 auto-sync（`minTriggerInterval` 防 hot loop） |

### Components（可復用 UI 元件）

| 檔案 | 說明 |
|------|------|
| `Components/VocabShellComponents.swift` | shell 級元件庫：`VocabTabSelector` / `VocabChromePill` / `VocabSearchField` 等 |
| `Components/VocabShellComponents+Lists.swift` | shell 級 list cards / status hero / timeline / button styles(`VocabListCard` 等) |
| `Components/VocabShellComponents+Actions.swift` | `VocabSortPill` + `VocabReviewCTAPill`(brandHero 填色 capsule，與 sort pill 同列尾端，由 `KGVocabPresenter.State.ReviewCTA` 驅動) |
| `Components/VocabComponents.swift` | skin 級元件:`VocabCard` / `VocabToneChip` / `VocabEmptyStateCard` / `VocabReviewProgressBar` 等(前身 `VocabSkinComponents.swift`,隨 AppSkin 正名整併) |
| `Components/VocabSceneShell.swift` | `VocabSceneShell<Content>` + `VocabScenePhase`,統一 vocabulary 四態容器(loading / loadingSkeleton / empty / error / content)；error phase 可帶 description，retry action 維持 owner 注入 |
| `Components/WordRow.swift` | `struct WordRow: View`；維持 word、pos、translation、book、trailing、status 的截斷與等寬數字布局契約 |
| `Components/VocabReviewBanner.swift` | `struct VocabReviewBanner<FilterContent>: View`。完整 hero CTA(cardBackground + title + stats + button)，**僅** NotebookListView 使用作為 primary entry point。VocabularyListView 詳情頁不再渲染此 banner — CTA 改走 `VocabReviewCTAPill` 內嵌於 chip+sort 列。 |
| `Components/CardExampleView.swift` | 書摘卡（#3113）：例句的唯一呈現，Linked Card／Word Detail 與複習卡背面共用。inset 填色 `mutedFill`、襯線 `typography.cardExample`、高亮引號字、footer（`CardExampleSource` 書名 · 章節；朗讀句子／複製為 44pt borderless）。複習卡正面（cloze）`showsFooter: false`，不朗讀答案。`CardExampleSource.make` 對 `Knowledge Graph` fallback 與空書名回 nil |
| `Components/CardDocumentView.swift` | card document 主 View；`.example` 區塊委派 `CardExampleView`，`.divider` 不繪製（區塊間分隔只靠 padding，無 hairline）；render path 含 `PerfLog` tick。Add Link 例句改由 `CardExampleView`（`showsFooter: false`）呈現；`CardInlineText` 的 `.example` 樣式已移除（#3113-r2） |
| `Components/CardRichTextRenderer.swift` | 例句 inline renderer（`**` 與反引號皆高亮；`plainText` 去標記供朗讀／複製）；render path 含 `PerfLog` tick |
| `Components/CardSections.swift` | card 各 section 元件 |
| `Components/CardDocumentBuilder.swift` | `CardDocument` builder |
| `Components/CardDocumentModels.swift` | `CardDocument` / `CardDocumentBlock` 等 data model |
| `Components/CardMarkdownInlineParser.swift` | Markdown inline 解析器 |
| `Components/WordDetailComponents.swift` | 詞條詳情子元件；`WordDetailGraphLinkRow` 對建立中連結分流：creating＝shimmer、failed／warning＝狀態圖示＋文案，點入開 `PendingLinkDetailSheet`（重試／移除） |
| `Components/CollocationExplainSheet.swift` | `struct CollocationExplainSheet: View`，搭配詞翻譯 sheet（借用 `ReaderMetrics` 對齊 Reader panel，見共用依賴） |
| `Components/VocabCalendarGrid.swift` | 日曆格元件 |
| `Components/VocabActivityHeatmap.swift` | 活躍熱圖元件 |
| `Components/VocabForecastChart.swift` | 預測圖表元件 |
| `Components/VocabGraphEntryCard.swift` | Overview 關聯圖入口卡（#2860）：header、狀態列（導覽部分）、縮圖三個 `NavigationLink`（`.liftable`），重試按鈕在所有 link 之外；狀態由 `StatsPresentation.graphCardState` 決定，錯誤面板與 stale／rendering 列都附原因與重試；繪製逾時時縮圖改為「關聯圖尚未顯示」卡身，見 `docs/reference/ui/state_matrix.md`「Overview Graph Card State」 |
| `Components/BookshelfItem.swift` | `enum BookshelfItem` / `BookshelfDestination`，書架統一條目（notebook / podcastSeries 二態 + 排序 key） |
| `Components/ProgressCapsule.swift` | `struct ProgressCapsule: View`，通用進度 capsule（fill / track / label） |
| `Components/SelectionToolbar.swift` | `struct SelectionToolbar: View`，多選模式底部封存／刪除工具列 |
| `Components/PressableInteraction.swift` | `PressableStyle` / `LiftableButtonStyle` ButtonStyle（按壓縮放/抬升回饋 + `.pressable` / `.liftable` 便捷取用） |
| `NotebookBindingList.swift` | `struct NotebookBindingList: View`（presentational，置於 Vocabulary/ 根）。單字本選擇清單，Reader（`ReaderNotebookPicker`，書綁定）與 Podcast（`PodcastNotebookPicker`，系列綁定）共用。`notebooks`/`selectedNotebookId`/`onSelect` 純資料注入；**刻意不標示「預設」** —— 所有單字本平權，每個容器（book/series）綁定即真相、無 magic 預設本。見 `NotebookBindable` |

### Overlay Layer

| 檔案 | 說明 |
|------|------|
| `Overlay/LinkedCardOverlayStack.swift` | `struct LinkedCardOverlayStack: View`，關聯卡片 overlay |
| `Overlay/LinkReasonSheet.swift` | `struct LinkReasonSheet: View`，KG 連結理由 sheet（顯示 `KGCardLinkSummary`，提供導航/隱藏 link 動作） |

> Design token 已從 feature 本地 `Skin/VocabSkin.swift` 升格為全 app 共用 `AppSkin`(見 `ios/BooksAndVocab/Models/AppSkin.swift`),不再屬於 Vocabulary feature scope。

---

## 改動規則

- **新增列表 UI** → `Scenes/VocabularyListPresenter.swift` 或新增 Presenter extension
- **新增業務流程** → Coordinator（`VocabularyListCoordinator` / `SyncCoordinator` / `KGVocabCoordinator`）
- **新增 pure domain rule / optimistic mutation** → `Domain/`（不得直接塞回 scene / presenter）
- **新增 UI 資料模型** → `Presentation/` 下新增或擴充現有 Presentation enum/struct
- **新增可復用元件** → `Components/VocabShellComponents*.swift`（shell 級）或 `Components/VocabComponents.swift`（skin 級）
- **新增場景** → `Scenes/` 新增 View + Presenter + Coordinator，並在對應 container 的 Sheets extension 掛載
- **新增 design token** → `ios/BooksAndVocab/Models/AppSkin.swift`（全 app 共用；禁止在 feature 檔案裡硬編碼顏色/間距）
- **改複習卡片版面** → 先讀下方「動態佈局契約」。新增可選欄位＝改 `ReviewCardField`（含 `canonicalOrder`、`titleKey`/`captionKey` 與五個 lproj）+ `ReviewCardContentAvailability` + solver 的精簡階梯 + renderer；**版面幾何一律新增 `TodayReviewMetrics` token，不得在 solver 或 renderer 任一側寫死數字**——兩邊算的必須是同一顆

## State 邊界

- `TodayReviewState`：複習 scene owner，負責 orchestration；僅 `TodayReviewView` 持有，不外洩
- `TodayReviewSessionState`：純 session/navigation state，僅 `TodayReviewState` 持有
- `TodayReviewSessionPersistenceController`：session persistence helper，僅 `TodayReviewState` 持有
- `TodayReviewCardCache`：TodayReview rich-card cache helper，僅 `TodayReviewState` 持有
- `TodayReviewAutoplayController`：autoplay helper，僅 `TodayReviewState` 持有；狀態被投影給 view，故必須維持 `@Observable`
- `ReviewCardLayoutStore`（`ios/BooksAndVocab/Models/ReviewCardLayoutProfile.swift`，**Model 層、非本 feature 私有**）：複習卡片版面 profile 的唯一 owner。**只有一個 `EnvironmentKey`（`\.reviewCardLayoutStore`，`defaultValue = .shared`）**，app code 從不注入第二個 store——覆寫只出現在 `#Preview` 與測試。所以複習畫面改的與 Settings 顯示的必然是同一個物件（**前提：卡片所屬單字本沒有 notebook override**）。有 override 的單字本，複習工具列的編輯器改寫入該本的 `NotebookSettingsProjection` override（`ReviewCardLayoutEditScope.notebook`，`TodayReviewView.layoutEditProfileBinding`），與該本設定頁寫的是同一份投影，並在頂部標示範圍、提供「改用全域版面」（#3124）；卡片畫什麼，編輯器就改什麼。`ReviewCardLayoutSummary.titleKey` 的 預設／自訂 判定是**兩模式四面全深比較**（synthesized `Equatable`），不是只看目前這面
- `ReviewCardLayoutSolver` / `ReviewCardViewport` / `ReviewCardRenderPlan`：純值型，**不得持有狀態、不得引入 SwiftUI**；solver 必須維持 O(fields)（最多六欄）且每個 section 只走訪一次——它跑在翻卡/fling 路徑上
- `TodayReviewCollocationState`：collocation explanation substate，僅 `TodayReviewState` 持有
- `WordDetailSceneState`：Word Detail scene owner，持有 presenterState / link error 與 link mutation orchestration
- `VocabularyGraphLinkMutation`：Vocabulary feature-local pure domain helper，供多個 scene 共用 graph-link optimistic mutation / rollback 規則
- `SyncCoordinator`：同步流程狀態，僅 `SyncView` 持有
- `AddLinkCreationCoordinator`：missing-target Add Link 的 server operation／polling／canonical pull projection 狀態；由 `AddLinkCreationHub.makeCoordinator()` 產生，`AddLinkSheet` 只是顯示者。**sheet 關閉不取消建立**：hub 持有執行中的 coordinator 並完成本地 pull，來源卡以 `PendingLinkProjection` 顯示「建立中」項目
- `AddLinkCreationHub`：建立中／失敗／警告 job 的唯一 owner 與持久化邊界（record 存 UserDefaults，app 被殺後由 `resume` 補查）；`PendingLinkProjection` 只有 hub 寫入
- `KGVocabCoordinator`：Books & Vocab 詞彙列表狀態，僅 `KGVocabView` 持有
- `VocabularyListCoordinator`：詞彙列表主導航狀態，由 `VocabularyListView` 持有
- Presentation models（`Presentation/`）：純值類型，可跨 layer 傳遞，但不持有 mutable state
- **容器↔單字本綁定 scope**（`NotebookBindable`，`ios/BooksAndVocab/Models/NotebookBindable.swift`）：每本書（`Book`）/ 每個 podcast 系列（`PodcastSeries`）綁定**恰好一本真實單字本**，開啟時以最近使用的真實本 seed 固化（`ensureBoundNotebook` + `canSeedBinding` gate：seed 須在 live 清單內已 settle，擋未同步 `"default"` sentinel）。固化後選詞 / highlight / cache scope 一律認 `resolvedNotebookId` 綁定本，**不再隨全域 active 漂移、無 magic 預設本**。`preferredNotebookId` 為純本機偏好；`resolvedNotebookId` 的 `?? activeNotebookId` 僅防禦性 last-resort（未經開啟流程就讀取），非主路徑。綁定本被刪除時由各 picker 的 `sanitizeStaleBoundNotebook` 清 nil、下次開啟 re-seed

## Card 與列表篩選邊界

Vocabulary 只呈現一般 Card；所有詞條共用同一套 detail、edit、archive/delete、graph 與 SRS 路徑。列表篩選只保留「複習狀態」單列，不再依卡片種類分面。Card 與同步語意分別以 `docs/reference/card_format.md`、`docs/reference/sync_lifecycle.md` 為 SoT。

## 動態佈局契約（複習卡片）

改 `ReviewCardLayout.swift` / `ReviewCardView.swift` 前必讀。**版面規則**（前五條）由 `ReviewCardRenderPlanTests` / `ReviewCardBudgetParityTests` / `ReviewCardLayoutStoreTests` 釘住（`ReviewCardLayoutEditor` 這個 View struct 本身無 unit test；其 store／preview 邏輯由 `ios/BooksAndVocabTests/ReviewCardLayoutEditorTests.swift` 釘住）；**效能那條沒有單元測試守得住**，它的量測面是 `./ops/review_flip_probe.sh`，而該 gate 最後一次有證據的結果是**紅的**（見該條）。`parse_gap_geom`（`ops/review_flip_probe_report.py`）只有解析器本身有 unit test；**目前沒有任何路徑把 `gap.geom` 行餵進它**，`review_flip_probe.sh` 尚未 ingest。**解析邊界**：`w=` 為 greedy，右界是整行最後一段完整尾巴（` h=… reveal=… dismiss=… off=… idx=…`）；單字本身含完整尾段時由 `test_word_containing_gap_geom_tail_keeps_full_word` 釘住（修前非 greedy 會靜默截斷為首段）。`ops/tests/test_ui_world_manifest.py::test_review_height_varied_fixture_has_short_tall_and_long_word_card_classes` 只釘資料類別（總數 40 且三類計數加總＝40、三類皆非空；short 類 `reviewExamples[0]` < 40、tall 類 `reviewExamples[0]` > 200、long-word 類 `len(word)` > 40；long-word 以 `len(word) > 40` 定義，該斷言為自洽而非獨立驗證；計數加總不等於互斥驗證），**不釘渲染後的高度**；量測本身未在該 lane 重跑。

- **固定精簡順序，不可改動**：① 例句縮到目標詞前後各 3 詞 → ② 解釋降 2 行、再降 1 行 → ③ 搭配詞 2 列降 1 列（以 +N 表示）→ ④ 知識連結每組 2 項降 1 項、再降單列摘要 +N → ⑤ **最後才**降 section spacing 與 fold padding（走 `foldSectionSpacingCompact`，不是就地寫死）。
- **不會被自動隱藏的東西**：題目、答案、詞性、難度。使用者勾選的長內容至少保留 minimal 摘要；只有 Accessibility Dynamic Type 下連 minimal 都放不下，才啟用垂直捲動（`requiresScrollFallback`）。
- **natural 這一層就是「目前出貨的卡片」**：解釋 3 行、搭配詞 2 列、背面例句不截斷。若把它們當成「已經壓過的一層」，未動過的預設 profile 會比它要重現的畫面更鬆，得等階梯跑完才回到原樣。
- **正面預算不預留反面高度**，且不隨 reveal 階段變動（展開時區塊收合，但讓預算長大會在翻卡中途重解正面）。反面拿的是「同一份 contentHeight 扣掉正面實際佔用」——inset 只扣一次。
- **一份 chrome、一份 spacing**：solver 扣的 `chromeHeight` 由 `ReviewCardChrome.verticalInset(for:)` 給，renderer 畫的 padding 也由它給；solver 解出的 `sectionSpacing` 直接回傳給 renderer 畫，renderer 不得自己從 token 再推一次。
- **效能（目標，尚未達成；最後已知紅，本次未重量測）**：欄位資料在 `TodayReviewCardCache` 預先整理；fling 每幀不得重建 `CardDocument` 或重新遍歷 paragraphs。只有 profile / 寬度 / Dynamic Type / 卡片 identity 改變才重算（量測 cache key = `ReviewCardMeasurementKey`）。反面重內容維持 reveal 才 mount、collapse 動畫結束才 unmount。
  **已知缺口**：`reviewMeasurementProbes` 為了取三層高度，會在卡片內渲染**隱藏的量測副本**（每欄最多 3 份，六欄最多 18 份），而 cache key 含 `cardKey`（word + dateAdded）→ **每換一張卡就整批重量測，而且落在推進那一幀**。「只在 identity 改變時重算」在逐卡推進的情境下＝每張卡都重算。量測證據：`./ops/review_flip_probe.sh --simulator --release --dataset-file ops/fixtures/ui_worlds/marketing_demo.json --flips 30` 在 `d75ac2d74`（solver 上線前）為 p95 16.667ms / 0 stalls，在 `c2665ae51`（solver 上線）之後起 p95 33–34ms / stalls 7 之 30。修的方向是把量測移出關鍵幀（沿用 `TodayReviewState.prewarmCardWindow()` 既有的預熱窗口預熱下一張），而不是放寬門檻。上述數值未留存於 repo（無可重現 artifact）。對照世界 `ops/fixtures/ui_worlds/review_height_varied.json`（`reviewDeck.probe` 牌組 40 張，`variedshort*`／`variedtall*`／長多行 word 三類）是 H1 量測的待用 fixture，**但 probe 尚不能消費 `gap.geom`**，因此以 `./ops/review_flip_probe.sh --simulator --release --dataset-file ops/fixtures/ui_worlds/review_height_varied.json --flips 30` 目前不產生 H1 結論。來源：`reviewDeck.probe` 的 40 張為新生成（`variedshort*`／`variedtall*`／長多行 word），`reviewDeck.probe.notebookName` 為 `Review Height Varied Fixture`，頂層 `datasetID` 為 `review_height_varied`，頂層 `vocabulary` 為空物件 `{}`；**不是**由 `marketing_demo.json` 衍生。repo 內沒有 generator script，該 JSON 本身即唯一來源。該 probe 命令結果：**NOT RUN**（需 simulator 量測，未在本 lane `debug/issue-2026-r3` 內執行）。

## 共用依賴

| Token | 用途 |
|-------|------|
| `AppSkin` | 全 app 共用 feature-level UI token(前身 `VocabSkin`,已正名),`@Environment(\.appSkin)` |
| `AppTheme` | 全局色彩，`@Environment(\.appTheme)` |
| `AppMetrics` / `AppShellMetrics` | 間距、尺寸 |
| `AppMotion` | 動畫 token |
| `AppTransition` | 過渡動畫 |
| `AppFonts` / `AppSkin.Typography` | 字型 |
| `TodayReviewMetrics` | TodayReview feature-local 版面參數（card / topBar / toolbar / fold / swipe geometry 等，~44 個 static let，定義於 `Scenes/TodayReviewMetrics.swift`）。boundary rectify 2026-05 從 `AppSkin.Metrics`/`Spacing` 遷出 24 個欄位 |
| `ReaderMetrics`（**跨 feature 借用**） | `Components/CollocationExplainSheet.swift` 使用 `ReaderMetrics.panelHorizontalInset` / `.panelBottomInset`，目的是讓翻譯 sheet 視覺對齊 Reader panel。**未來 Reader 重構時 Vocabulary 是 stakeholder** |
