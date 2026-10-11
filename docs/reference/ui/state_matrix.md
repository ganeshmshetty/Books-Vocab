<!-- doc-meta
tier: reference
authority: derived
update_trigger: code-change
scope:
  - ios/BooksAndVocab/
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# UI State Matrix

Date: 2026-06-02
Scope: `ios/BooksAndVocab`

文檔網絡：
- 設計規範主文檔：`docs/sop/ui-design.md`
- 元件 / pattern inventory：`docs/reference/ui/components.md`
- 開發入口：`docs/sop/ios.md`
- App 架構脈絡：`docs/sop/architecture.md`

## 這份文件是幹嘛的

這份文件回答的是：

- 這個畫面有哪些狀態？
- 這些狀態現在怎麼呈現？
- 哪些狀態已經有一致 UI？
- 哪些狀態還沒被完整覆蓋？

`component / pattern inventory` 解決的是「該用什麼」。
`state matrix` 解決的是「有哪些狀態不能漏」。

---

## Reader

主要檔案：
- `ios/BooksAndVocab/Views/Reader/ReaderView.swift`
- `ios/BooksAndVocab/Views/Reader/ReaderViewPresenter.swift`
- `ios/BooksAndVocab/Views/Reader/TranslationPanelPresenter+State.swift`
- `ios/BooksAndVocab/Views/Reader/TranslationVocabPresenter.swift`

### Reader Container State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Publication loading | `isLoading == true` | reader loading overlay | 已覆蓋 |
| Publication rendering progress | `loadingPhase` 變化 | loading overlay 文案切換 | 已覆蓋 |
| Publication failed | `errorMessage != nil` | `ContentUnavailableView` | 已覆蓋 |
| Reader progress unknown | `ReaderRuntimeState.progressState == .unknown`（nil / non-finite / 越界 locator 或尚未收到有效 location） | `reader.progress.unknown` badge +「閱讀進度未知」 | 已覆蓋 |
| Reader progress zero / middle / complete | valid locator progression `0...1` 分類 | `reader.progress.zero|middle|complete` badge；numeric badge 只在有效 progression 存在時呈現 | 已覆蓋 |
| Saved locator restore warning | saved locator decode 失敗 | `reader.progress.restore-failure` warning badge；不顯示 load error | 已覆蓋 |
| Restore warning → first valid location | invalid saved locator 後首個 Readium locator progression finite 且在 `0...1` | warning 消失、badge 轉 numeric state、`Book.progression` 才更新 | 已覆蓋 |
| Publication open error | loader throw / `loadingState == .failed` | `reader.error.<failure>` card + exact `reader.retry` CTA | 已覆蓋 |
| Retry transition | retry CTA 觸發 runtime retry | error/retry 消失，loading overlay 出現，成功後 content + loaded | 已覆蓋 |
| Reader ready | `publication != nil && errorMessage == nil` | Readium navigator | 已覆蓋 |
| Reader empty | `publication == nil && errorMessage == nil && loadingState == .ready` | visible `reader.empty` card + exact `reader.retry` CTA | 已覆蓋 |
| Paywall required | `!subscriptionManager.hasProAccess` | `SubscriptionPaywallSheet` | 已覆蓋 |

### Translation Panel State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Translation loading | `contentMode == .loading` | shared state message | 已覆蓋 |
| Guest mode / local save | `contentMode == .guest` | shared state message + save status | 已覆蓋 |
| Translation result | `contentMode == .translation` | translation body | 已覆蓋 |
| Explanation only | `contentMode == .explanationOnly` | explanation body | 已覆蓋 |
| Explanation loading | `isLoadingExplanation == true` | shared state message | 已覆蓋 |
| Translation / explanation failed | `translationErrorMessage` / `explanationErrorMessage` 有值 | `VocabStateMessageCard` 錯誤卡 + 重試 CTA（`onRetryTranslation` / `onRetryExplanation`，wire 在 `ReaderView+Panels.swift` + `PDFReaderView.swift`） | 已覆蓋 |
| Empty panel | `contentMode == .empty` | `VocabStateMessageCard("尚未取得翻譯", "text.viewfinder", "請重新選取文字，或稍後再試一次。")` + footer toolbar（含 dismiss） | 已覆蓋 |

判斷：
- Reader 主容器狀態已經清楚
- Translation panel 所有 contentMode 分支皆有明確 UX；`.empty` 透過 `VocabStateMessageCard` 提示用戶重新選字
- 翻譯 / 解釋失敗已是明確 error state（`VocabStateMessageCard` 錯誤卡 + 重試 CTA）

---

## Vocabulary

主要檔案：
- `ios/BooksAndVocab/Views/Vocabulary/VocabularyListView.swift`
- `ios/BooksAndVocab/Views/Vocabulary/Scenes/KGVocabView.swift`
- `ios/BooksAndVocab/Views/Vocabulary/Scenes/KGVocabPresenter.swift`
- `ios/BooksAndVocab/Views/Vocabulary/SyncView.swift`
- `ios/BooksAndVocab/Views/Vocabulary/Scenes/SyncPresenter.swift`
- `ios/BooksAndVocab/Views/Vocabulary/KnowledgeGraphView.swift`
- `ios/BooksAndVocab/Views/Vocabulary/Scenes/KnowledgeGraphPresenter.swift`
- `ios/BooksAndVocab/Views/Vocabulary/Scenes/TodayReviewPresenter.swift`

### Vocabulary List Routing State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Pending list tab | `selectedTab == 0` | pending vocab route | 已覆蓋 |
| Knowledge base tab, signed out | `selectedTab == 1 && !isLoggedIn` | login-required empty state | 已覆蓋 |
| Knowledge base tab, no Pro | `selectedTab == 1 && !hasProAccess` | paywall empty state | 已覆蓋 |
| Graph tab, no Pro | `selectedTab == 2 && !hasProAccess` | paywall empty state | 已覆蓋 |
| Export available | local pending entries exist | export menu | 已覆蓋 |

### KG Vocabulary State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Signed out | `!authManager.isLoggedIn` | empty state card | 已覆蓋 |
| Initial loading | `coordinator.isLoading && syncedEntries.isEmpty` | shared state message card | 已覆蓋 |
| Sync error（可重試） | `bannerError = .refresh(isRetryable: true)` | 清單頂端面板 `vocab.statusPanel`（重試／關閉）；使用者主動刷新時另彈 warning pill | 已覆蓋 |
| Sync error（不可重試） / 部分失敗 | `.refresh(isRetryable: false)`、`.pendingDeletesFailure`、`.archivePartial` | warning pill（`KGVocabBanner.pill`）；清單為空時仍是全頁 error state | 已覆蓋 |
| Review status filter | 使用者切換複習狀態 | 單列 filter + 排序 | 已覆蓋 |
| Empty by search / review state | `rows.isEmpty` | empty state content | 已覆蓋 |
| Populated list | `rows.count > 0` | list card + rows | 已覆蓋 |
| Pending delete retry | pending deletes | 清單頂端面板 `vocab.statusPanel`（重試，不可關閉）；重試結果以 pill 回報 | 已覆蓋 |
| Refresh success | 有變化，或使用者主動刷新 | success pill（單字庫已更新／已是最新）；自動刷新且無變化時靜默 | 已覆蓋 |

### Sync State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Signed out | `!isLoggedIn` | status hero | 已覆蓋 |
| No Pro | `!hasProAccess` | status hero + CTA | 已覆蓋 |
| Ready | `phase == .ready` | status hero + counts + CTA | 已覆蓋 |
| Running | `phase == .running` | progress hero + timeline | 已覆蓋 |
| Completed | `phase == .completed` | success hero + done CTA | 已覆蓋 |
| Failed | `phase == .failed` | error hero + summary + retry | 已覆蓋 |
| Partial failure | summary text from coordinator | summary text only | 部分覆蓋 |
| Cancelled | `cancelSync()` | failed phase + cancelled summary | 已覆蓋 |

判斷：
- Sync 是 vocabulary 裡最完整的 state machine
- 但 partial failure 還只是文字，沒有和 full failure 拉開更明確層級

### Knowledge Graph State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Signed out | `!isLoggedIn` | empty state | 已覆蓋 |
| Loading | `isLoading` | empty state variant | 已覆蓋 |
| Error | `errorMessage != nil` | empty state variant | 已覆蓋 |
| No nodes | `nodes.isEmpty` | empty state variant | 已覆蓋 |
| Graph visible | nodes available | graph scene | 已覆蓋 |
| Settings drawer open | `showsSettings == true` | overlay panel | 已覆蓋 |

### Overview Graph Card State（`VocabGraphEntryCard`，#2860）

由 `StatsPresentation.graphCardState` 純函式決定；卡身只會是載入佔位、錯誤面板、empty 卡身、快取圖或逾時說明（`.unpainted`），不留空白方塊。

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Loading | `!linksLoaded`，無失敗 | `AppLoadingStateCard` 卡身（catalog 場景「Graph loading」） | unit 覆蓋；catalog 場景已備，截圖未取 |
| Error panel 5xx | `!linksLoaded` + `failureReason`（HTTP 5xx） | 錯誤面板 `overview.graph.error`＋原因＋重試（catalog 場景「Graph error 5xx」） | unit 覆蓋；catalog 場景已備，截圖未取；UI 未測 |
| Error panel offline | `!linksLoaded` + `failureReason`（離線） | 同上（catalog 場景「Graph error offline」） | unit 覆蓋；catalog 場景已備，截圖未取；UI 未測 |
| Graph painted | `linksLoaded`，nodes > 0，已 painted，無失敗 | 縮圖＋健康條，無狀態列（catalog 場景「Populated」） | unit 覆蓋；catalog 場景已備，截圖未取 |
| Empty | `linksLoaded`，nodes == 0 | 原生 empty 卡身（不走 paint watchdog）（catalog 場景「Empty」） | unit 覆蓋；catalog 場景已備，截圖未取 |
| Stale | `linksLoaded` + `failureReason` | 保留快取圖＋`overview.graph.stale` 警示列（原因＋重試）（catalog 場景「Graph stale 5xx」） | unit 覆蓋；catalog 場景已備，截圖未取；UI 未測 |
| Rendering | nodes > 0，8 秒內未 painted，無失敗 | 逾時後縮圖 web view 自卡身移除，卡身「關聯圖尚未顯示」（`.unpainted`，不留空白），狀態列「關聯圖繪製中」（`overview.graph.rendering`）＋重試（非 stale 警示）。web view 已分離，晚到的 painted 不被依賴；重試重新掛回並重新計時（裝置上未驗證） | 部分覆蓋（unit；視圖層與故障注入 reproduction 未做） |
| New payload | 縮圖收到新 payload（signature 改變） | `sendInitGraph` 重置 `hasPainted`（graph.html 會重新隱藏 canvas）；卡片依 signature 重新計時；已逾時的 `.unpainted` 隨 payload 回到 `.graph` | 已覆蓋（coordinator unit；watchdog 視圖層未測） |
| Rendering + stale | nodes > 0，逾時，且有 `failureReason` | 卡身同為「關聯圖尚未顯示」，狀態列為 stale 警示（原因＋重試） | 已覆蓋（unit） |
| Retry on unpainted | 縮圖（`.graph`／`.unpainted`）且 `!hasPainted` 的重試 | 頁面未回報 `ready`（`needsRebuildOnRetry`）才 `recover()` 重建 web view；已 ready 但仍繪製中的慢圖只重新計時，不重啟渲染；錯誤面板（無縮圖）重試只回呼 `onRetry` | 部分覆蓋（coordinator unit；視圖層未測） |
| Web content terminated | 縮圖 web content process 終止 | 自動 `recover()` 最多 3 次（連續、未 painted 前）；之後標記 `pageLost` 並清除 `hasPainted`，8 秒後由 `.rendering` 列呈現，其重試 `needsRebuildOnRetry` 重建頁面（不因已 ready 而被擋） | 已覆蓋（coordinator unit） |

### Today Review State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Front | `revealStage == .front` | front fold card | 已覆蓋 |
| Back | `revealStage == .back` | answer fold | 已覆蓋 |
| Details | `revealStage == .details` | detail fold | 已覆蓋 |
| Completion | `currentCard == nil` | completion empty state | 已覆蓋 |
| Remembered / forgot feedback | submit action | sound feedback（可關閉）+ haptic（可關閉）+ card swap | 已覆蓋 |
| Save failure / persistence failure | `modelContext.save()` 失敗 | `onSaveFailure` → `toast.error(L10n.string("todayReview.saveFailure"))` | 已覆蓋 |
| 卡片版面：自然放得下 | `totalHeight <= available`（natural 層） | 各欄位全長呈現＝出貨既有卡片視覺 | 已覆蓋 |
| 卡片版面：逐級精簡 | `totalHeight > available` | 依固定順序退讓（例句 radius → 解釋 2/1 行 → 搭配詞 2/1 列 +N → 連結 2/1 項 + 單列摘要 +N → 最後才收 spacing/padding） | 已覆蓋 |
| 卡片版面：minimal 仍溢出 | `requiresScrollFallback`（多見於 Accessibility Dynamic Type） | 該面改垂直捲動；**不隱藏使用者勾選的欄位** | 已覆蓋 |
| 卡片版面：欄位資料缺席 | `ReviewCardContentAvailability` 該欄為 false | 本次不畫，**profile 不變**（下張卡有資料就回來）；`graphLinks` 恆可用——無連結時畫加連結入口 | 已覆蓋 |
| 卡片版面：正面／反面預算 | 正面階段常駐 reveal zone | 正面預算＝contentHeight − revealZoneReserve 且不隨 reveal 階段變動；反面拿正面實佔後的餘額 | 已覆蓋 |
| 精簡卡暫時看詳細（#2041） | 該卡方向 preset 為 `.compact`，tap chrome `todayReview.card.temporaryDetail`（value=`showDetail`／`restoreCompact`） | 只有這張卡改以 `.standard` 版面畫（例句／詳解／搭配詞，production 正面例句一併還原），以 `reviewRevealSpring` 過渡；同一顆按鈕恢復精簡。顯示詳細時**暫停 autoplay**（同 layout editor，不自動恢復；否則下一次推進就把詳細忘掉）。狀態只在 `TodayReviewState` 記憶體，任何換卡（next / previous / shuffle / submit / autoplay）即清，回到該卡仍為精簡；不寫 `ReviewCardLayoutStore`／`NotebookSettings`／iCloud。evidence value 的 `preset` 仍是設定值，另帶 `temporaryDetail=0/1`；已是正常版面的卡不顯示按鈕 | 已覆蓋（`ReviewCardTemporaryDetailTests`、`ReviewCardLayoutEditorUITests`） |
| 版面編輯器入口不可用 | `!isCardInteractive`（fling / 推進中） | toolbar 鈕點擊 no-op（與 shuffle / prev / next 同一把鎖） | 已覆蓋 |
| 開編輯器時 autoplay 正在播 | tap 入口 | `pauseForInterruption()` 暫停；**關閉後不自動恢復**（`todayReview.autoplay.paused` identifier 可判讀） | 已覆蓋 |
| autoplay 播放中評分 / 洗牌 / 水平滑動卡片（#2046） | 頂欄洗牌、Catalyst 快捷鍵、卡片水平拖動（iOS 播放中不渲染記得／忘記按鈕） | 操作被擋（卡片不位移、不計分），頂端 warning pill「自動播放中，請先關閉」；事件鍵 `todayReview.autoplayBlocked` 取代式（連點不堆疊）、滑動每次手勢只提示一次；哪些操作被擋由 `TodayReviewState.autoplayBlocks` 單一真相決定（暫停不解除；唯一解法是關閉自動播放，文案據此） | 單元覆蓋（`TodayReviewAutoplayGatingTests`）；UITest 待補 |
| 開新增連結時 autoplay 正在播 | tap `todayReview.card.addLink` | 先 `pauseAutoPlayForModalInterruption()`；`AddLinkSheetRequest` 於點擊當下凍結來源卡與候選池，sheet 全程綁定該卡（`addLink.sourceWord` 顯示來源字）；關閉後維持暫停 | 已覆蓋 |
| 多單字本入口 | session `queue` 涵蓋 ≥2 個 `notebookId`（`ReviewCardNotebookBadgeResolver`；於 session 開始時一次查 `Notebook` 進 `@State`，複習頁不掛 `@Query`，Notebook 寫入不觸發 body 重算） | 每張卡正面頂部留白以 overlay 畫 `todayReview.card.notebook`（色點＋名稱，value=notebookId）；不進 layout，卡高與 solver 預算不變；背面展開時仍可見。名稱查不到→「未命名單字本」，`default` sentinel 無 row→「預設單字本」，永不顯示 id；AddLink sheet 加 `addLink.notebookScope`（「只會搜尋「X」內的單字」） | 已覆蓋 |
| 單一單字本入口 | `queue` 只含一個 `notebookId` | 不畫標示；AddLink sheet 不顯示範圍提示 | 已覆蓋 |
| 連結目標在 session 開始後才建立 | 點連結 →「查看詳情」，`linkedEntryLookup` 查無 | 改查 live store；仍查無才 `toast.error`（`找不到符合的單字`），不再靜默無反應 | 已覆蓋 |
| 連結建立中（關閉 sheet 後） | `AddLinkCreationHub` 有該 source 卡的 running job | 來源卡連結區立即出現 `todayReview.card.link.pending.<word>`（單字 + 迷你進度 +「正在建立…」，accessibilityValue=`creating`）；**不論 presentation（含 `.summary`）或有幾個建立中項目，建立中項目都留在組名旁，只有一般連結落入「+N」**；狀態更新（creating→failed／warning、移除）走 `TodayReviewCardCache.refreshLinks`，沿用該卡 `measurementCache`，翻開中的卡不重解版面、不跳高；點入開 `todayReview.card.link.pending.detail`（單字、狀態文字、逐步進度；`...pending.status` value=`creating`）；完成後 pending 項消失、sheet 自動關閉、該處出現一般連結 | 已覆蓋（UITest 僅覆蓋失敗路徑；creating→完成見 `AddLinkCreationHubTests`） |
| 連結建立失敗（關閉 sheet 後） | job `failed`（terminal 失敗或輪詢斷線） | 項目改顯示警示圖示（value=`failed`），**不會自行消失**；詳情顯示失敗文案＋`...pending.retry`（terminal 失敗換新 idempotency key；輪詢斷線續輪詢同一 operation；POST 未回應沿用同 key）＋`...pending.dismiss`（唯一移除途徑） | 已覆蓋 |
| 新增連結：完全成功 | operation `succeeded` 且本地 pull 成功 | sheet 自動關閉（`onLinked`）；來源卡出現一般連結 | 已覆蓋（單元 `AddLinkCreationFailureTests`） |
| 新增連結：部分完成（sheet 開著） | `succeeded_with_warnings`（`enrichment_failed`／`link_projection_pending`）或本地 pull 失敗 | **不自動關閉**：`addLink.creation.warning` 顯示「已建立，但有一部分沒完成」，逐項 `addLink.creation.warning.item.<code>`；`addLink.creation.retry` 只重跑未完成部分（缺解釋→重排 pipeline，再 pull，不再 POST）；`addLink.creation.warning.done` 才關閉 | 已覆蓋（單元；UITest 為原始碼契約，live warning 情境未覆蓋） |
| 新增連結：部分完成（sheet 已關） | 同上，但 sheet 先被關閉 | 來源卡項目顯示警示（value=`warning`），不會自行消失；詳情列出未完成部分＋`...pending.retry`＋`...pending.dismiss`（完成）；重試進行中按完成＝取消該重試並移除項目（`AddLinkCreationHub.dismiss` 先 `cancel()`，重試結束不會把項目帶回來） | 已覆蓋（單元） |
| 新增連結：失敗分類 | operation `failed`／`interrupted`、client 逾時、輪詢 404、斷線 | `addLink.error.reason` value＝原因碼；文案依 `AddLinkCreationFailure`（額度、來源不可用、目標已封存、不能連到自己、服務不可用、伺服器中斷、逾時、請求已不存在、網路、登入）；不可重試者（封存／自己／來源不可用／額度／登入）不顯示重試；`addLink.creation.backToSearch` 回搜尋並移除該失敗 job | 已覆蓋（單元＋UITest 斷線路徑） |
| 新增連結：輪詢逾時 | 一次嘗試（含 POST）超過 90 秒仍非終態 | 停止輪詢，失敗 `timed_out`（可重試，重試換新 key） | 已覆蓋（單元，fake clock） |
| 新增連結：既有字連結中 | 點候選列 | 該列 `addLink.row.linking.<cardId>` 進度、所有列與建立鈕鎖定；再次點擊不重送 | 已覆蓋（單元） |
| 新增連結：既有字連結失敗 | `AddLinkActionError` | banner `addLink.error.reason`（value＝原因碼）依錯誤顯示不同文案；可重試者 banner 帶重試 | 已覆蓋（單元） |
| 新增連結：建立入口 | 有輸入且本地無此字（含 `apple.` 等尾端標點正規化） | 部分符合候選之下仍有 `addLink.create`；精確符合已連結顯示「已連結」 | 已覆蓋（單元） |
| 新增連結：建立入口文案（#2037） | 建立入口出現 | 主行為完整動作句「建立「新字」並連結到「來源字」」（`addLink.create.title`，超過 20 字元以「…」截斷、動詞與來源字完整，字內引號改為 `'`，最多兩行）；副行「加入：單字本名稱」（`addLink.create.notebook`，名稱取來源卡所在單字本，查不到→備援字串、永不顯示 id；單一單字本入口也顯示）；兩行各以隱藏元素鏡射 id（value＝文字），`addLink.create` 的 label 含新字與來源字；文字隨輸入淡入淡出、不跳變。舊 key `建立` 不改義（仍是 create_card 步驟標籤） | 已覆蓋（單元＋UITest） |
| 新增連結：離線（#2039） | `NetworkMonitor.isConnected == false`（裝置網路，非 server health） | 開 sheet 時頂端 toast 提示「目前離線，無法建立新單字或連結」；`addLink.create` 仍列出但停用，副行改為原因（`addLink.create.disabledReason`）；點既有候選、重試建立都在**樂觀寫入之前**被擋下並再提示；斷線／恢復連線各彈一次 toast（恢復時入口自動可用） | 已覆蓋（單元；UITest 無法在不改 app 啟動旗標下模擬離線，未覆蓋） |
| 新增連結：搜尋框 Return（#2038） | 搜尋框按 Return | 純函數 `AddLinkReturnBehavior.resolve`：輸入與某個可連結既有單字**完全相同**（正規化同後端）→ 直接連結該字，該列右緣 `addLink.row.returnHint`（↵）、鍵盤鍵 `.join`；完全相同且已連結 → 不動作，toast「已連結過「X」」；只有部分符合（含只剩一個）→ 只收鍵盤；本地完全沒有 → 只收鍵盤並讓 `addLink.create` 短暫高亮（`addLink.create.highlight` value＝`on`／`off`），**絕不建立**；封存／未同步／來源自己亦只收鍵盤。其餘狀態鍵 `.done`；隱藏元素 `addLink.return.action` 的 value＝決策名（`linkExact`／`alreadyLinked`／`dismissKeyboard`／`revealCreate`） | 已覆蓋（單元＋UITest） |
| 連結區「+N」展開（#2043） | 某組連結多於 solver 的 presentation 能顯示（2／1／0 個） | 「+N」是按鈕（`todayReview.card.link.overflow.<groupId>`，value=`collapsed`／`expanded`）；點開就地在組名下方折行列出其餘連結（至多 20 個，其餘仍計入「+K」；`AppMotion.reviewRevealSpring`），再點收合（文案「收合」）。展開狀態只存記憶體、綁單張卡（換卡即還原）；展開高度寫在獨立的量測 key，不污染收合時 natural／intermediate／compact 的量測。裝置上沒有的連結只計數、不可展開 | 已覆蓋（單元＋UITest） |
| 「＋」新增連結點擊範圍（#2044） | 連結列尾的「＋」或空狀態「新增連結」 | 圖示放大一級；可點範圍與 accessibility frame ≥ 44×44，版面佔位仍等於 label（連結區高度、solver 預算不變）；`todayReview.card.addLink` id 不變 | 已覆蓋（單元＋UITest） |
| 建立中／失敗／警告連結出現在詳情頁（Word Detail） | 同一張卡的 `WordDetailSheet`（開著或之後打開） | creating＝單字＋shimmer；failed／warning＝單字＋狀態文案＋圖示（`wordDetail.link.pending.<state>`，**不是無限 shimmer**），點入開 `PendingLinkDetailSheet`（重試／移除）；sheet 觀察 `AddLinkCreationHub.revision` 即時重建，完成後該列轉為一般連結；詳情頁的 AddLink 也傳 `onLinked` | 已覆蓋（原始碼契約；無 UITest） |
| 登出／切換帳號 | `LocalDataCleanerService.clearLocalData` | `AddLinkCreationHub.clearAll()`：取消 live coordinator，清 jobs、UserDefaults record、`PendingLinkProjection`，不留上個帳號輸入的單字；record 帶 `userId`，`resume` 丟棄非目前帳號的 job | 已覆蓋（單元） |
| 候選超過 20 個時的精確符合 | 輸入字與某既有字完全相同（正規化同後端），但該字在 store 順序中落在前 20 個部分符合之後 | `localCandidates` 精確符合排第一再取前 20，Return 仍可連結並顯示 `addLink.row.returnHint` | 已覆蓋（單元） |
| 建立中 app 被殺 | 下次進入複習，`resume` 發現 durable record | hub init 即還原 pending 項（projection 載入）；`resume` 依 operationId 續輪詢並完成本地 pull，或以同 key 重送未回應的 POST；source 卡已不存在則丟棄 | 已覆蓋（單元） |
| 開啟新增連結 sheet | sheet 出現 | `addLink.searchField` 立即取得鍵盤 focus，可直接打字 | 已覆蓋（`AddLinkSheetUXUITests`） |
| 建立進度步驟標籤 | `AddLinkCreationCoordinator` running | 六步依序為 `addLink.step.resolveTarget／translate／createCard／enrich／createLink／localProjection`，描述該步實際動作 | 已覆蓋（`AddLinkStepCopyTests`） |

### Review Card Layout Editor State（`ReviewCardLayoutEditor`）

兩個入口共用同一頁：複習 toolbar sheet（`ReviewCardLayoutEditorSheet`）與 設定 ▸ 偏好 ▸ 複習卡片（`navigationDestination`）。

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Mode = 辨識 / 產出 | `modePicker` 分段選擇 | 兩模式各自獨立的欄位配置；由複習畫面進入時預選**畫面上那張卡的模式** | 已覆蓋 |
| Face = 正面 / 背面 | `facePicker` 分段選擇 | 切換編輯中的那一面；預覽區同步 | 已覆蓋 |
| Locked core row | 恆常 | `lock.fill` 鎖定列（正面＝題目、背面＝答案），**無 toggle 可關**；模式語意非 profile 欄位 | 已覆蓋 |
| 欄位開 / 關 | `toggle.<field>` | 開啟時重排回 `canonicalOrder`（不是附加到尾端）；直寫 store，背後卡片即時重排 | 已覆蓋 |
| 該面零可選欄位 | `activeFields.isEmpty` | 預覽區顯示空狀態說明（`reviewCardLayout.preview.empty`）＋鎖定列仍在——卡片不會變成空白 | 已覆蓋 |
| Settings 摘要：預設 | `profile == .default`（兩模式四面全深比較） | 偏好列尾顯示「預設」 | 已覆蓋 |
| Settings 摘要：自訂 | 任一模式任一面與預設不同 | 偏好列尾顯示「自訂」 | 已覆蓋 |
| Reset 目前模式 | `reset.currentMode` | 只還原當前模式兩面，另一模式不動 | 已覆蓋 |
| Reset 全部 | `reset.all`（destructive） | 兩模式四面全還原成預設 | 已覆蓋 |
| 跨裝置衝突 | iCloud KV 外部變更通知 | updatedAt LWW 整組原子取代；時戳不可信（非有限 / 超界 / 版本不明）時整包忽略，不半套 | 已覆蓋 |

---

## Explore（Shared Deck Catalog）

主要檔案：
- `ios/BooksAndVocab/Views/Explore/ExploreView.swift`
- `ios/BooksAndVocab/Views/Explore/SharedDeckDetailView.swift`
- `ios/BooksAndVocab/Services/SharedDeckCatalogService.swift`

### Explore Catalog State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|---------|------|
| Loading | sync 中且本機 live deck 數為 0 | loading state message + progress | 已覆蓋 |
| Empty | sync 成功且 catalog 為空 | empty state | 已覆蓋 |
| Error | list 或 SwiftData fetch/reconcile/save failure 且沒有 cache | error state + retry | 已覆蓋 |
| Partial | list 或 SwiftData failure 但保有 cache | cached content + 頂端失敗面板 `explore.partialState`（`AppStateMessageCard` + 具名「重試」）；手動重新整理失敗另彈 warning pill | 已覆蓋 |
| No results | 有 catalog 但搜尋/篩選結果為 0 | no-results state + clear filters | 已覆蓋 |
| Content | 有 live deck 且篩選結果非空 | deck grid/list | 已覆蓋 |

### Explore Detail Storage State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|---------|------|
| Loading | detail 讀取本機 SharedDeck 尚未完成 | detail loading state | 已覆蓋 |
| Loaded | 唯一 deck row 成功讀取 | cover/header/copy/sample cards | 已覆蓋 |
| Missing | fetch 成功但沒有該 remoteId | missing deck state | 已覆蓋 |
| Storage failure | SwiftData fetch 失敗或資料列不合法 | 明確 storage-error state + retry；不得顯示 missing | 已覆蓋 |

Explore fixture evidence 另受 `sharedDecks` contract 約束：每個 fixture 恰有一個 `assetIDs`，snapshot/驗證/decode 失敗直接 fail-loud，不以 optional evidence node 形成假成功。

## Settings

主要檔案：
- `ios/BooksAndVocab/Views/Settings/SettingsView.swift`
- `ios/BooksAndVocab/Views/Settings/SettingsPresenter.swift`
- `ios/BooksAndVocab/Views/Settings/SettingsCoordinator.swift`

### UI Feedback Preferences

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Sound feedback on/off | `FeedbackSettingsStore.soundFeedbackEnabled` | Settings 偏好列；`appFeedback` 播放短促非語音 UI 音效 | 已覆蓋 |
| Haptic feedback on/off | `FeedbackSettingsStore.hapticFeedbackEnabled` | Settings 偏好列；`appFeedback` gate `.sensoryFeedback` | 已覆蓋 |
| Content audio isolation | TTS / Podcast event | 維持各自既有服務與設定，不受 UI feedback switches 影響 | 已覆蓋 |

### Auth / Account State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Logged out | `!auth.isLoggedIn` | login section | 已覆蓋 |
| Logged in | `auth.isLoggedIn` | account summary + logout | 已覆蓋 |
| Auth error | `auth.authError != nil` | auth summary error text | 已覆蓋 |
| Delete confirm | `showDeleteAccountConfirm == true` | destructive alert | 已覆蓋 |
| Delete in progress | `isDeletingAccount == true` | danger button text switch | 已覆蓋 |
| Delete failed | `deleteAccountError != nil` | alert | 已覆蓋 |

### KG / Backend State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Signed out | `kg == nil` | section hidden | 已覆蓋 |
| Connected | `kg.isConnected == true` | connected badge / server count | 已覆蓋 |
| Offline | `kg.isConnected == false` | offline label | 已覆蓋 |
| Last sync available | `lastSyncDescription != nil` | row reveal | 已覆蓋 |
| Sync idle（收合） | `!syncSummary.isSyncing` | sync row 摘要 + `lastSyncedText` | 已覆蓋 |
| Sync in progress（展開） | `syncSummary.isSyncing && !syncProgress.steps.isEmpty` | sync row 底下展開 `SettingsSyncProgressPanel`（總進度條 + 逐步清單），以 `AppMotion.phaseChange` 收合、`lastSyncedText` 同步淡回 | `#Preview`（catalog 凍結期不新增 surface，見 `docs/reference/catalog_scope.md` §FROZEN 紅線 1）|
| 單步：waiting / running / retry / done / skipped / error | `PipelineStep.status` | `SyncStepStatusIcon` 六態符號 + detail 文字（running 且 `total > 0` 時顯示 `current/total` 計數器）| 已覆蓋 |
| Sync round did-not-run | `SyncRoundOutcome.didNotRun`（離線 / 被另一輪佔著 claim / 中途取消）| `store.reset()` → 面板直接收合，**不宣稱完成也不宣稱失敗** | 已覆蓋 |
| Debug backend mode | debug section | local / prod switch | 已覆蓋 |

### Subscription State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| No subscription section | signed out | section hidden | 已覆蓋 |
| Free / inactive | `!pro.is_active` | status card | 已覆蓋 |
| Trial | `status.is_trial` | status card | 已覆蓋 |
| Active | `status.is_active` | status card | 已覆蓋 |
| Purchase / refresh loading | `subscriptionManager.isLoading` | CTA loading spinner | 已覆蓋 |
| Purchase status message | `purchaseStatusMessage != nil` | shared state message card | 已覆蓋 |
| App Store error | `lastError != nil` | shared state message card | 已覆蓋 |
| Product pricing unavailable | `state.pricingUnavailableMessage != nil` | `pricingUnavailableCard`（`VocabStateMessageCard`） | 已覆蓋 |

判斷：
- Settings 的 section-level state 已經不差
- pricing unavailable 已收斂到 `VocabStateMessageCard`；殘留的 detail-text fallback（auth error、offline label）仍非明確 state 分層

---

## Cross-Surface Findings

### 已經相對一致的

- Empty state：
  已大量收斂到 `AppEmptyState*` / `VocabEmptyState*`
- State message：
  Reader / Vocabulary / Settings 已開始收斂到 `AppStateMessage*` / `VocabStateMessageCard`
- Big status hero：
  Vocabulary sync / graph 已有清楚的大狀態模式
- Offline state：
  `AppOfflineBanner` modifier 已掛在 `ContentView` 根層，連線中斷時自動覆蓋 destructive tint capsule（已知 light mode 對比未達 WCAG AA，待 polish）

### 仍然不一致的

- Error severity：
  有些是 banner，有些是 card，有些只是文案
- Partial failure：
  Sync 有，但其餘路徑還沒有明確語法
- Silent success：
  某些成功狀態沒有顯示，只有資料靜默刷新
- Empty state policy：
  部分畫面是顯式 empty state，部分畫面是 `EmptyView()`
- Skeleton 載入：
  `AppSkeletonLine` / `AppSkeletonCard` primitive 已備齊；目前唯一 callsite 在 `VocabSceneShell.swift:52`（`.loadingSkeleton` phase 用 `AppSkeletonCard(lineCount: 2)`），透過 `VocabSceneShell` 間接覆蓋 KGVocab / Sync / TodayReview / KnowledgeGraph / PodcastEpisodeList 等場景；其餘獨立 loading（Bookshelf import overlay、PodcastPlayer `.loading`、ReaderView publication load）仍用 ProgressView 或 state message card

---

## Next UX Priorities

### Priority 1（已完成）

原列項皆已補成明確 presentation：
- Reader translation `empty` → `VocabStateMessageCard`
- Reader translation / explanation error → 錯誤卡 + 重試 CTA
- Today Review persistence failure → `todayReview.saveFailure` toast
- Settings subscription unavailable pricing → `pricingUnavailableCard`

### Priority 2

把 partial failure 做成正式 pattern，而不是只留 summary text：
- Sync partial failure
- KGVocab delete retry result

### Priority 3（已完成）

Preview matrix 已補齊：
- Reader chrome: loading / compact / expanded / translation
- Translation panel: loading / guest / translation / explanation only / empty
- Reader settings: default
- Sync: signed out / no Pro / ready / running / failed / completed
- Settings: logged out / logged in active / sub loading / delete in progress
- Today Review: front / back / details / completed

新增或修改 UI 時，參考 `docs/reference/ui/review_checklist.md`。

---

## Notebook Card (HStack book-row, `NotebookCard`)

主要檔案：
- `ios/BooksAndVocab/Views/Vocabulary/Components/NotebookCard.swift`
- `ios/BooksAndVocab/Views/Vocabulary/Components/NotebookPalette.swift`
- `ios/BooksAndVocab/Views/Vocabulary/Components/NotebookCoverPatterns.swift`

> Book-row redesign 後 `NotebookCard` 不再用 `NotebookStackedCoverView`(該 view 改由 Bookshelf / Podcast / EditSheet preview 維持);stack depth / rotation / deck press 行為僅在那些 surface 生效。

### Variants

| State | 觸發條件 | 視覺 |
|------|---------|------|
| 使用中 | `isActive == true` | cover 左欄 name 旁 5pt 圓點(`NotebookPalette.darken(cover, by: 0.5)`),取代舊 3pt spine / 「使用中」pill |
| 有待複習 | `dueCount > 0` | metadata 右欄 `N 詞` row 後接 5pt warning 圓點 + count;`dueCount == 0` 時不顯示 |
| 空 notebook | `cardCount == 0` | metadata 改顯示「尚未加入單字」placeholder,**不**渲染 `N 詞` / ProgressCapsule |
| 一般狀態 | `cardCount > 0` | metadata 顯示 `N 詞` monoLabel + ProgressCapsule(4pt, fillColor=coverColor) |
| Pending sync | `pendingCount > 0` | 頂部 TipView(`SyncPendingTip`),卡片內不顯示 chip |
| 自訂照片封面 | `coverImagePath != nil` | cover 左欄底層改用 image fill,仍套 noise pattern + name overlay |
| Editorial rule | always | cover 內 1pt rule(寬 cover×0.3,色 darken 0.5);cover/metadata 間 0.5pt 垂直 cardBorder rule |

### Theme / Press / a11y

| State | 觸發條件 | 行為 |
|------|---------|------|
| Light mode | `colorScheme == .light` | cover 套 Morandi palette 12 色;`primaryText #37352F` 對全 12 色 ≥ AA 7:1(`NotebookCoverContrastTests` 鎖) |
| Dark mode | `colorScheme == .dark` | `NotebookCard.coverColor` 自動套 `NotebookPalette.darken(_, by: 0.2)` 使 `primaryText #E6E6E3` 對 cover ≥ AA 4.5:1(test 鎖) |
| Press | `NavigationLink` + `.buttonStyle(.plain)` | 無 deck press 動畫(`NotebookDeckButtonStyle` 不適用於 row)、無 offset/scale;按壓由 SwiftUI default highlight + nav push 提供 |
| Dynamic Type `.accessibility3` | a11y size | metadata truncate,row 高度固定 72pt 不縮放 |

整 row 為單一 a11y element(`children: .ignore` + label = `name + cardCount + 狀態`)。

### Legacy stack(`NotebookStackedCoverView`,Bookshelf / Podcast / EditSheet preview 仍用)

| State | 觸發條件 | 視覺 |
|------|---------|------|
| 空本 | `cardCount == 0` | 單張平面卡(`layerCount=1`),無下層 ghost |
| 薄堆 | `1...50` | 2 層(1 ghost + 1 頂層) |
| 中堆 | `51...200` | 3 層 |
| 厚堆 | `200+` | 4 層(上限) |
| Editorial rotation | layerCount ≥ 2 | 每層 ±1.5° per-notebook deterministic(`stableSeed(for: data.name)` djb2 → `seedJitter`),anchor `.bottom`;跨 launch 同角度 |
| Press(此 surface) | `NotebookDeckButtonStyle` `isPressed == true` | 頂層 offset −14pt + scale 0.97;ghost 每深一層額外下沉 1pt;haptic `.selection`。Rotation 不參與 press 動畫 |
| Reduce Motion | `accessibilityReduceMotion == true` | 關閉 offset/scale;保留 opacity dip + haptic + push transition;rotation 保留 |

---

## Bookshelf

主要檔案：
- `ios/BooksAndVocab/Views/Bookshelf/BookshelfView.swift`
- `ios/BooksAndVocab/Views/Bookshelf/BookshelfCoordinator.swift`
- `ios/BooksAndVocab/Views/Bookshelf/BookshelfMetrics.swift`

> Bookshelf 是 EPUB/PDF/TXT/MD 書籍 + Podcast Series 的統一書庫入口。同一 `NavigationStack` 同時承載 `Book` 與 `PodcastNavRoute` push。`BookshelfImportError.classify` 把底層錯誤分類成 `unsupportedExtension` / `iCloudUnavailable` / `unknown` 等 diagnosed 形式。

### Bookshelf Container State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Idle empty（無書 + 無 podcast） | `books.isEmpty && podcastSeries.isEmpty` + `CloudKitMirroringMonitor.phase ∈ {settled, localOnly}` | `emptyState` ScrollView：`AppEmptyStateContent`（真「尚無書籍」）+ EPUB 指南 TipView + 匯入 CTA + 登入 / Demo 雙 CTA | 已覆蓋 |
| CloudKit 還原確認中 | `books.isEmpty` + `phase == .waitingFirstEvent` | emptyState 內 `cloudRestoreStatus`：`ProgressView` + `正在確認 iCloud 書庫…`（`bookshelf.emptyState.cloudStatus`） | 已覆蓋 |
| CloudKit 還原中 | `books.isEmpty` + `phase == .restoring` | emptyState 內 `cloudRestoreStatus`：`ProgressView` + `正在從 iCloud 取回書庫…`（`bookshelf.emptyState.cloudStatus`） | 已覆蓋 |
| CloudKit 同步失敗 | `books.isEmpty` + `phase == .failed(msg)` | emptyState 內 `cloudRestoreStatus`：`Label` + `exclamationmark.icloud` + `iCloud 書庫同步異常・<msg>` | 已覆蓋 |
| Books + podcast 並存 | 任一非空 | `bookGrid` LazyVGrid（書先、podcast series 後）+ pull-to-refresh | 已覆蓋 |
| Import loading overlay | `coordinator.isLoading == true` | scrim + linear `ProgressView`（`loadingProgress` 有值）或 indeterminate spinner + `loadingMessage` | 已覆蓋 |
| Import error alert | `coordinator.showError == true` | system alert，title `匯入錯誤・<diagnosis>` | 已覆蓋 |
| Import error persistent banner | `errorMessage != nil && !showError` | `safeAreaInset(.top)` `AppStateMessageCard`，含「再試匯入 / 關閉」雙 CTA | 已覆蓋 |
| 部分成功匯入 | `succeeded > 0 && failures.count > 0` | toast warning + alert（保留 inline banner） | 已覆蓋 |
| 批次全失敗 | `succeeded == 0 && failures.count > 1` | alert message 為 per-file diagnosis 條列 | 已覆蓋 |
| Background podcast sync 進行中 | `.task` 內 `PodcastSyncService.syncAll` 跑著 | 無顯式 UI（靜默） | 缺口（Priority 3） |
| Background podcast sync 失敗 | sync 拋例外 | 無 UI，僅 log | 缺口（Priority 2） |

### Book Card State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Cover decoded | `decodedCoverImage != nil` | 平台 image fill | 已覆蓋 |
| Cover placeholder | 無 cover data 或解碼中 | mutedFill + `book` SF symbol + title + format 標 | 已覆蓋 |
| 閱讀進度 | `book.progression > 0` | accent capsule + 百分比 mono 文字 | 已覆蓋 |
| iCloud 待下載 | `book.needsICloudDownload` 或 `state == .notDownloaded` | `icloud.and.arrow.down` 徽章 | 已覆蓋 |
| iCloud 下載中 | `state == .downloading(progress)` | `ICloudProgressBadge`（圓環 + 數字） | 已覆蓋 |
| iCloud 下載失敗 | `state == .failed` | `retryBadge`（`exclamationmark.icloud` warning tint，tap 觸發 `triggerDownload` 重試；`BookCard.swift:134,154`） | 已覆蓋 |
| 長按 context | context menu | 刪除（destructive） | 已覆蓋 |

### Podcast Series Card State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| 一般 series | always | `NotebookCoverView`（pattern + name）+ `waveform` 角標 + episode count | 已覆蓋 |
| 已追蹤 | `series.isFollowed == true` | 左上 `star.fill` 角標 + a11y label `已追蹤` | 已覆蓋 |
| 自訂封面 | `series.coverImagePath != nil` | cover image fill 取代 pattern | 已覆蓋 |

### Bookshelf Auth / Paywall

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Demo mode | `authManager.isDemoMode` | empty state 不再顯示登入 / Demo CTA | 已覆蓋 |
| 未登入 + 非 Demo | `!isDemoMode && !isLoggedIn` | empty state 多出「登入帳號 / 體驗複習與圖譜」雙 CTA | 已覆蓋 |
| 已登入 ready | `isLoggedIn` | `.task` 觸發 `PodcastSyncService.syncAll` + audio prefetch | 已覆蓋 |
| Paywall | 無 — Bookshelf 本身不擋 paywall | n/a | n/a（paywall 落在 Reader / Vocabulary） |

判斷：
- Import 流程的 alert + persistent banner 雙層配置是目前 cross-surface 最成熟的 error pattern
- 殘留缺口集中在「背景同步沒有可見訊號」：podcast sync running / failed、warmFollowedSeriesAudio 失敗皆靜默
- iCloud 下載六態齊全（current / downloading / notDownloaded / failed），`.failed` 已有專屬可重試徽章，與「沒下過」明確區分
- **空書架 CloudKit 還原三分化已補齊**（`CloudKitMirroringMonitor.phase`）：本地 0 列不再一律講「尚無書籍」——還原確認中 / 還原中顯示 ProgressView 提示、同步失敗顯示 `exclamationmark.icloud` 警示，只有 `settled`（首次 import 成功收尾）/ `localOnly` 才渲染真空 emptyState

---

## Podcast

主要檔案：
- `ios/BooksAndVocab/Views/Podcast/PodcastEpisodeListView.swift`
- `ios/BooksAndVocab/Views/Podcast/PodcastPlayerView.swift`
- `ios/BooksAndVocab/Views/Podcast/PodcastPlayerViewModel.swift`（`PodcastPlayerState`、`PodcastSubtitleLoadState`、`SleepTimerMode`）
- `ios/BooksAndVocab/Views/Podcast/PodcastSubtitleView.swift`
- `ios/BooksAndVocab/Views/Podcast/PodcastControlsView.swift`
- `ios/BooksAndVocab/Views/Podcast/PodcastSettingsPopover.swift`

> 音訊與字幕狀態**獨立**：`state` 走 audio lifecycle，`subtitleState` 走 SRT 載入；字幕失敗不阻斷播放。

### Episode List State（`PodcastEpisodeListView`）

由 `VocabScenePhase` 驅動，透過 `VocabSceneShell` 統一渲染。

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Initial loading | `isLoading && !hasLoadedOnce` | `.loadingSkeleton` → `AppSkeletonCard` | 已覆蓋 |
| Load error | `loadError != nil && rawEpisodes.isEmpty` | `.error` phase，title `無法載入集數`，retry 重跑 `reloadFromStore` | 已覆蓋 |
| Empty episodes（首載後） | `rawEpisodes.isEmpty && hasLoadedOnce` | `.empty` phase，title `尚無集數` + `waveform.slash` | 已覆蓋 |
| Populated | episodes 非空 | hero + episode rows（accent divider 區隔） | 已覆蓋 |
| Continue / Resume CTA | `progressMap[ep].lastPlayedTime > 0 && !completed` | hero primary CTA 文字「繼續播放」 | 已覆蓋 |
| All completed | `rawEpisodes.allSatisfy(completed)` | hero CTA 文字「重新播放」 | 已覆蓋 |
| Audio 暫不可用 | `!target.audioAvailable` | CTA 文字「音訊暫不可用」+ `icloud.slash` + disabled | 已覆蓋 |
| Navigation lock | `navigationLocked == true`（tap 後 1s） | 所有 push CTA disabled，避免雙 push freeze | 已覆蓋 |
| Follow toggle 儲存失敗 | `PodcastFollowToggle.perform` 回 `.rolledBack` | toast error `追蹤狀態儲存失敗` + 自動回滾 star | 已覆蓋 |
| Sort 切換 | `sort` 變更 | menu pick + 動畫排序 | 已覆蓋 |
| Refresh after load error | `loadError != nil` 但 `rawEpisodes` 非空（殘留） | content 仍顯示 + 上方插入畫面內面板 `VocabStateMessageCard`（`載入失敗，顯示快取資料` + 具名「重試」→ `reloadFromStore()`；`podcast.episodeList.staleBanner`） | 已覆蓋 |

### Player Container State（`PodcastPlayerView` × `PodcastPlayerState`）

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| VM 尚未建立 | `viewModel == nil` | `ProgressView("載入中…")` | 已覆蓋（過渡態） |
| `.idle` / `.loading` | audio 未 ready | 置中 `ProgressView` + `載入音訊…` 文案 | 已覆蓋 |
| `.error(msg)` | audio 載入或中斷失敗 | `xmark.octagon` hero + `音訊載入失敗` + msg + 重試 CTA（`reloadEpisode`） | 已覆蓋 |
| `.ready` / `.playing` / `.paused` | audio ready 之後 | subtitle view + `PodcastControlsView` + 底部 `TranslationPanel` overlay | 已覆蓋 |
| Episode 切換中 | `.task(id: episodeId)` re-run | 先存舊 progress → 重建 VM；中間透過 `viewModel == nil` 顯示 `ProgressView` | 已覆蓋 |
| Scene phase 退出 | `scenePhase != .active` | 自動 saveProgress（無 UI） | 已覆蓋 |
| 未取得 audio URL | `loadEpisode` 找不到 local 或 remote URL | `vm.reportError("無音訊 URL")` → `.error` | 已覆蓋 |
| 認證 token 失敗 | `kgService.currentAuthToken()` throw | `.error` 帶錯誤訊息 | 已覆蓋 |
| Local file 播放 | `episode.localAudioPath` 存在 | 無 auth header，直接 file:// | 已覆蓋（無顯式 indicator） |
| 系統中斷 / route change | engine `onSystemPause`(中斷)/ `onRouteLost`(拔耳機,不武裝續播 latch) | VM 從 `.loading` / `.playing` 拉回 `.paused` | 已覆蓋 |
| Mid-stream 失敗後 didEnd | engine `onPlaybackFinished` 與 `.error` 競爭 | 守 `if case .error` 不 clobber error UI | 已覆蓋 |

### Subtitle State（`PodcastSubtitleLoadState`）

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| `.idle` | 未啟動（初始 / pre-load 過渡） | 無 overlay，純句子層渲染 | 已覆蓋 |
| `.loading` | `setSubtitleLoading()`（無 inline、有 URL） | Capsule hint overlay：spinner + `字幕載入中…`（`podcast.subtitleLoading`） | 已覆蓋 |
| `.loaded` | fetch 成功 / inline subtitle | 句子層 + 高亮字 + cue tracking | 已覆蓋 |
| `.failed` | fetch / decode 失敗，或 non-2xx response（`authedData` 拋 `URLError(.badServerResponse)`） | `AppStateMessageCard` overlay：`字幕載入失敗` + `音訊仍可正常播放` + 重試 CTA（`onRetrySubtitle`） | 已覆蓋 |
| `.unavailable` | `markSubtitleUnavailable()`（episode 無 subtitle URL） | `AppStateMessageCard` overlay：`此集無逐句字幕` + `音訊仍可正常播放`（無重試 CTA；`podcast.subtitleUnavailable`） | 已覆蓋 |

### Translation Panel State（podcast surface）

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| 無查詢 | `translationHandler.wordSelection == nil` | 不顯示 panel | 已覆蓋 |
| 查詢中 | `translationHandler.isTranslating == true` | `TranslationPanel` shared state message + spinner | 已覆蓋（共用 Reader pattern） |
| 翻譯結果 | `translationResult` 有值 | translation body | 已覆蓋 |
| Explain only | `isExplanationOnly == true` | explanation body | 已覆蓋 |
| 翻譯 / 解釋失敗 | `translationErrorMessage` / `explanationErrorMessage` | 共用 `TranslationPanel` 渲染 `VocabStateMessageCard` 錯誤卡 + 重試 CTA（`onRetryTranslation` / `onRetryExplanation` → `retryLastLookup`，與 Reader 對齊；`PodcastPlayerView.swift:345-352`） | 已覆蓋 |
| 自動暫停 | `autoPauseOnLookup` + panel 出現 | VM `pause()` + `autoPausedByTranslation = true`，dismiss 後自動 resume | 已覆蓋 |

### Controls / Seek Bar State

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Duration 未知 | `viewModel.duration == 0` | 拖曳 disabled（防 seek(0)）；文字顯示 `--:--` | 已覆蓋 |
| Buffered 區段 | `viewModel.bufferedEnd > 0` | accent.opacity(0.25) overlay capsule + easeOut 0.2s | 已覆蓋 |
| Dragging | `isDragging == true` | seek bar swipe spring + thumb 跟手 + 時間文字 follow dragTime | 已覆蓋 |
| 倍速切換 | tap rate chip | mono label capsule，VM `cycleRate()` | 已覆蓋 |
| Skip ±15s | tap forward/back | engine skip + 同步 currentTime | 已覆蓋 |

### Sleep Timer State（`SleepTimerMode`）

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| `.off` | 預設 | popover Picker 顯示「關閉」 | 已覆蓋 |
| `.minutes(N)` | 5 / 15 / 30 / 60 | Picker 選中 + `TimelineView` 每秒 tick 顯示「剩餘 mm:ss」 | 已覆蓋 |
| `.endOfEpisode` | 「結束本集」 | Picker 選中，無 deadline 倒數（依靠 `onPlaybackFinished` 結束時自動 reset） | 已覆蓋 |
| 倒數結束 | timer fire（`sleepTimerFiredTick`） | engine pause + mode 回 `.off` + `.sensoryFeedback(.success)` + `toastCoordinator.info(L10n.string("podcast.sleepTimer.fired.toast"))` | 已覆蓋 |

### Settings Popover

| State | 觸發條件 | 目前 UI | 狀態 |
|------|----------|--------|------|
| Open | `showSettingsPopover == true` | popover：字幕大小 segmented / 逐字跟隨 / 查詞時自動暫停 / 睡眠定時 + 倒數 | 已覆蓋 |
| 字幕大小變更 | `subtitleSize` 變更 | `@AppStorage` 持久化，subtitle view 立即套用 | 已覆蓋 |
| 逐字跟隨關閉 | `wordFollowEnabled == false` | 句子層不顯示 word underline | 已覆蓋 |

判斷：
- Player error / subtitle failure 是目前 podcast 最成熟的 state machine（hero error + inline retry）
- subtitle `.loading` hint、`.unavailable` 與 `.idle` 區分、sleep timer fire toast、episode list stale banner 皆已補齊
- 殘留缺口：Bookshelf 背景 podcast sync running / failed 仍靜默（podcast translation 錯誤卡重試 CTA 已與 Reader 對齊）

### Next UX Priorities（Bookshelf + Podcast 補充）

#### Priority 1（已完成）
- Podcast subtitle `.loading` inline hint（spinner + `字幕載入中…`，`PodcastSubtitleView.subtitleLoadingHint`）
- Sleep timer 倒數結束 toast + haptic（`.sensoryFeedback(.success)` + `podcast.sleepTimer.fired.toast`）
- Podcast subtitle `.unavailable` 與 `.idle` 區分（`subtitleUnavailableHint` + `此集無逐句字幕`）

#### Priority 2
- ~~Podcast translation 錯誤卡 wire 重試 CTA（`onRetryTranslation` / `onRetryExplanation`）~~ — 已完成（`PodcastPlayerView.swift:345-352`，與 Reader 對齊）
- Bookshelf background podcast sync 失敗 toast / status row
- ~~iCloud 書籍下載失敗 vs notDownloaded 的徽章區分~~ — 已完成（`BookCard.swift:134` `case .failed: retryBadge`）

> Episode list 「load error 但有殘留資料」的 stale 面板已完成（`VocabStateMessageCard` + `podcast.episodeList.staleBanner`；#2047 由 `AppBanner` 遷入面板）。

#### Priority 3
- Bookshelf podcast sync running 的微 indicator（pull-to-refresh 期間 OK，自動 sync 期間缺）
- `warmFollowedSeriesAudio` 失敗的 telemetry（純 silent，不需 UI）
