<!-- doc-meta
tier: reference
authority: SoT
update_trigger: code-change
scope:
  - ios/BooksAndVocab/Models/VocabularyEntry.swift
  - ios/BooksAndVocab/Services/VocabularySyncEngine.swift
  - ios/BooksAndVocab/Views/Vocabulary/SyncView.swift
  - ios/BooksAndVocab/Views/Vocabulary/VocabularyContextStore.swift
  - ios/BooksAndVocab/Views/Vocabulary/AutoSyncMonitor.swift
  - ios/BooksAndVocab/Views/Vocabulary/Scenes/SyncCoordinator.swift
  - ios/BooksAndVocab/Views/Vocabulary/Scenes/KGVocabCoordinator.swift
  - ios/BooksAndVocab/Views/Vocabulary/Scenes/NotebookReconciler.swift
  - ios/BooksAndVocab/Views/Reader/ReaderVocabularyContext.swift
  - ios/BooksAndVocab/Views/Podcast/PodcastVocabularyContext.swift
  - ios/BooksAndVocab/Services/AuthManager.swift
  - ios/BooksAndVocab/Services/BackgroundSyncActor.swift
  - ios/BooksAndVocab/Services/KGService+Sync.swift
  - ios/BooksAndVocab/Services/KGService+VocabCRUD.swift
  - ios/BooksAndVocab/Services/KGService+Models.swift
  - backend/src/kg/api_models/vocab.py
  - backend/src/kg/routers/vocab.py
  - backend/src/kg/vocab_intake.py
  - backend/src/kg/vocab_crud.py
  - backend/src/kg/vocab_handlers/intake.py
  - backend/src/kg/vocab_handlers/crud.py
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# Sync Lifecycle

這份文件描述 Books & Vocab 本地生詞與 KG 雲端同步時的最小規則，目的不是講實作細節，而是固定「每種狀態應該怎麼表現」。

## 核心欄位

- `syncStatus`
  - `0`: `pending`
  - `1`: `synced`
  - `2`: `failed`
- `actionType`
  - `add`
  - `delete`
  - `edit`

Swift 端應優先透過 `VocabularyEntry` 的 typed helper 使用這些狀態，而不是直接散落比較 magic number 或 magic string。

## 規則表

| 狀態 | 代表意思 | 會出現在閱讀器 | 會出現在待同步 | 會出現在知識庫 |
| --- | --- | --- | --- | --- |
| `pending + add` | 本地新增，待送上雲端 | 是 | 是 | 否 |
| `synced + add` | 已與雲端一致 | 是 | 否 | 是 |
| `pending + delete` | 本地已要求刪除，待送上雲端 | 否 | 是 | 否 |
| `failed + add` | 上次新增同步失敗，可重試 | 是 | 是 | 否 |
| `failed + add` + `rejectedReason` | 後端確定性拒收（終態，不重試；`SyncView` 列出供使用者取消，取消即硬刪；`addCount` 與上傳不含此列，`pendingCount` 含之） | 是 | 是（僅列表可見、可移除，不上傳） | 否 |
| `failed + delete` | 上次刪除同步失敗，可重試 | 否 | 是 | 否 |

## 主要轉移

### 本地新增單字

1. 建立 `VocabularyEntry`
2. 呼叫 `restorePendingEntry()`
3. 顯示在閱讀器與待同步清單

### 本地新增上傳成功（`pending + add` → `synced + add`）

1. `SyncCoordinator` 批次上傳 → `POST /api/vocab` 回 `VocabAddResponse{ cardIds, duplicates, rejected, ... }`（逐筆驗證：無效項進 `rejected[{index, word, reason}]`，其餘照常建立，不再整批 422；非 list body 或超過 500 筆仍 422；iOS `KGAddResponse.rejected` 解碼（缺欄位視為空），依 `index` 指向原提交 entry 並 `markRejected(reason:)`：進 `failed + add` 且寫入 `rejectedReason` 終態，**不再納入 `shouldUploadOnNextSync`**（確定性拒收不自動重送，否則每次 sync 重報同一錯誤）；`markSynced`／`queueDelete` 清除該欄位，`restorePendingEntry` 亦清除但僅 queued delete 列會呼叫（`VocabularyContextStore` 與 `SyncCoordinator` 收斂皆以 `syncAction == .delete` 守門），failed add 列不會經此路徑復活；**例外**：add 於 in-flight 期間已被 `deleteLocally` 排成 delete 者，`markRejected` 不改寫為終態，保留 pending delete，下一輪 batchDelete 以 `not_found` 本地移除（#2733）；該步驟本次回報 error 並使 sync 為 partial）
2. **`cardIds` 以 client 送出的『原始』word 為 key**（非後端清洗後的 word），`created` 與 `duplicate`（已存在）兩種情況都回填對應 card id
3. 對每筆 entry：`response.cardIds[entry.word]` 命中即回填 `kgCardId` 並 `markSynced()` 直接出列
4. **不變式**：收斂依據是回傳的 cardId（= 卡片確實存在 server，權威確認），**不**靠 pull-merge 用 content 字面比對——後端 `_clean_content` 會 strip 尾標點 / 首字小寫（如 `"chateau,"`→`"chateau"`），content 比對跨此邊界必然 miss，曾導致該類 entry 永久卡在 `pending + add` 重送（修復見 vocab_intake：response key 改回原始 word）
5. 無 cardId 回傳（異常）的 entry 保持 `pending + add`，下次重試
6. **不變式（contract）**：`cardIds` 的 key 必須是 client submitted word 的 **byte-exact echo**，後端**不得**對 key 做任何 normalization（NFC/大小寫/trim）——iOS 以 `entry.word` 逐字節查找，任何後端側轉換都會讓配對 silent miss。清洗只作用於**儲存的 content**，不作用於 response key

### 上傳中的新增被刪除

1. 單字是 `pending + add` 且已被本輪 sync 擷取（`isUploadInFlight`：自擷取起至該 sync 返回為止，涵蓋 batch delete 往返、前一組 `batchAdd` 等待等 suspension）時，使用者刪除**不得硬刪**：`deleteLocally(in:)` 改呼叫 `queueDelete()`（`requiresServerDelete = isSynced || isUploadInFlight || hasServerCard`）
2. row 保留為 `pending + delete`：已送出者待上傳回填 `kgCardId` 後，下一輪 sync 送出 batch delete；尚未送出者（擷取後、送出前即被刪）送出前 revalidate 跳過、不上傳，下一輪 batch delete 以 `not_found` 本地移除（#2733）
3. 理由：硬刪會讓 server 已建立的卡片在下次 pull 被重新插入（resurrection）
4. 唯一入口：所有使用者刪除（閱讀器 `VocabularyContextStore.deleteEntry`、`SyncView` 待同步確認刪除、`WordDetailSheet`）都經 `VocabularyEntry.deleteLocally(in:)`，不得直接 `modelContext.delete(entry)`
5. **I3（不變式）**：列被擷取（`isUploadInFlight`）期間，使用者的撤銷與閱讀器重新擷取都不得改寫其 `syncAction`。`undoQueuedDelete()` 為 no-op；`restoreExistingEntryForSave` 對 in-flight 的 delete 回 `nil`，由呼叫端新增一筆 `pending + add`；`SyncView` 忽略該列的「還原」點擊。唯一允許的使用者轉移是 → delete。因此擷取時為 delete 的列，在 batch 回應或逐卡 fallback 抵達時仍是 delete；post-await 只做防禦性重查（`syncAction == .delete` 且仍在 in-flight），不需撤銷競態分支。
6. 反例（已修，#2484 撤銷競態）：撤銷發生在 batch delete 往返期間，曾把仍有 `kgCardId` 的列標成 synced；server 刪除成功後，回應被守門忽略，接著的 full pull 把它當 orphan 刪除，撤銷等於遺失卡片。逐卡 fallback 的 `deleteCard` 期間撤銷，曾在請求返回後無條件硬刪。兩者皆因 I3 不可達。
7. **已知殘餘（無程式碼變更，另案）**：(a) `KGVocabCoordinator.retryPendingDeletes`（待刪 banner 的第二條 drain，#3059）在 engine 之外發送 batch delete、不設 `isUploadInFlight`、回應後直接 `modelContext.delete`，可能與進行中的 sync 重疊；(b) 編輯（`WordEditSheet.commitEdit`）不在 I3 守門內：對 in-flight 的 pending add 只改內容，該次 sync 不會上傳，pull 可能覆寫（不硬刪、不遺失卡片）；(c) 登出／重設的 `clearUserData` 可硬刪進行中的列，sync 的 post-await 會讀到已刪列（見下節「logout-cleanup gate」的 accepted residual）。

### 已同步單字被刪除

1. 既有單字先是 `synced + add`
2. 使用者刪除時呼叫 `queueDelete()`
3. 單字立刻從閱讀器與知識庫隱藏
4. 等下一次同步把刪除請求送到 KG

### 撤銷尚未送出的刪除（SyncView「還原」）

1. `pending + delete` 列以 `VocabularyEntry.undoQueuedDelete()` 撤銷
2. `kgCardId` 非空（server 已確認持有卡）→ `synced + add`
3. `kgCardId` 為空（server 從未確認，例如上傳中的新增被刪）→ `pending + add`，下一輪 sync 上傳；**不得**變成 `synced`（synced 無 server 卡會在 full pull 的 orphan cleanup 被刪，#2484）
4. 進行中（in-flight）的列不可撤銷（I3）：撤銷為 no-op、列保持 `pending + delete`，由回應決定去留（deleted／not_found 硬刪、failed 保留）；sync 返回後仍存在的 delete 列才可撤銷。`applyBatchDeleteResponse` 與逐卡 fallback 的 `syncAction == .delete` 守門保留作防禦
5. 完整轉移表見 `VocabularyEntry` 的 Outbox 狀態機註解（T1–T11）

### 雲端資料拉回本地

1. 若本地是 `pending + delete`（含上節「上傳中的新增被刪除」排入的 delete），保留本地刪除意圖，不被遠端覆寫；convergence 不得把 delete-queued row 重設回 `add`
2. 若遠端卡片存在且未刪除，合併內容後呼叫 `markSynced()`
3. 若遠端回傳 soft delete，本地直接刪除

**merge 回報實際變動量**（`BackgroundSyncActor.PullResult` → `KGPullOutcome`）：pull 回傳 `inserted` / `updated` / `deleted` 三個計數，`hasChanges` 即三者之和 > 0。UI 憑此區分「同步真的改了東西」與「同步跑完、什麼都沒變」。

- `updated` 只計**使用者可見內容**真的不同的詞條，判準集中在純函式 `BackgroundSyncActor.contentDiffers(card:from:)`（translation / pos / note / difficultyTier / inflections / collocations / examples / mode / graphLinks / isArchived / notebookId / book source）。
- **複習狀態刻意不算變動**（`lastReviewedAt` / `reviewCount` / `nextReviewAt` / `streak` / `lapse`）。它每次複習都由本機推上去、下一輪 incremental pull 再原樣拉回；若計入，任何一次複習後的同步都會被判為「單字庫有變化」——這正是要避免的假陽性。
- SwiftData 對屬性是「指派即髒」，所以判準必須在覆寫欄位**之前**取樣，事後問 `hasChanges` 得不到答案。

**分頁（`X-Next-Cursor`）**：`GET /api/vocab` 每頁最多 `limit`（預設 5,000）列，依 `(updated_at, id)` 升冪；還有下一頁時回 `X-Next-Cursor`。cursor 是 opaque token，綁定請求 scope（`notebook_id` + `since`），換 scope 重用會被 400 拒絕。iOS 一律經 `KGService.fetchAllVocabPages` 讀取：每頁原樣重送同一組 `notebook_id`／`since` 再加 `cursor`，直到 header 缺席；`X-Pipeline-Pending` 取最後一頁。

- **不變式**：整批 drain 完才 merge；orphan cleanup、`SyncKeys.incrementalBoundary` 與 `payloadVersion` 只在全部頁成功後才寫；boundary 錨定在「pull 發出前的裝置時鐘」與「首頁 `Date` header」較早者、再減 60 秒（#2426，裝置超前伺服器時不會跳過伺服器變更）。`payloadVersion` 升到 2 讓既有 v1 boundary（可能已超前）被丟棄、強制一次 full drain 重建。任一頁 HTTP 失敗、無法解碼、cursor 不前進（重複）或頁數超過 `KGService.maxVocabPages`（200，擋住持續換發新 cursor 的伺服器故障，免得 sync 卡死、記憶體無界成長）即整輪 throw，什麼都不提交——截斷的讀取與「server 已沒有這些卡」無法區分。只讀第一頁時，超過 5,000 列的庫在 full sync 會把最新的卡當 orphan 刪掉，boundary 再越過沒讀到的列，那些卡就永遠拉不回來（#2101）。

### 批次刪除 / 封存回應的三個 bucket：`*_words` / `not_found` / `failed`

batch-delete（`POST /api/vocab/batch-delete`）與 batch-archive（`PATCH /api/vocab/batch-archive`）回傳**三個互斥清單**（後端 `kg/vocab_crud.py`）：

| bucket | 語意 | server 端狀態 | client 應對 |
| --- | --- | --- | --- |
| `deleted_words` / `updated_words` | 這次操作成功 | 卡片已刪 / 封存狀態已改，graph 已同步 | 本地收斂（成功語意） |
| `not_found` | **lookup 查無此字**（前一次已刪 / race） | server 上本就不存在 | 本地收斂（成功語意，刪除意圖已達成） |
| `failed` | graph 操作失敗已**回滾** | 卡片**仍存在 server**（原狀態） | **不可收斂**；保持 `failed + delete/edit`，下次 sync 重試 |

- `failed` 鍵是**向後相容的附加欄位**（Pydantic `BatchDeleteResponse` / `BatchArchiveResponse` 預設空 list）。舊 client 忽略未知鍵即可；關鍵改動是 graph-失敗的字**不再**出現在 `not_found`，因此舊 client 也不會再把仍存在 server 的字誤收斂（#720）。
- **可本地收斂集合 = `deleted_words ∪ not_found`**（`SyncCoordinator.locallyResolvableDeletes(from:)`，`SyncCoordinator` 與 `KGVocabCoordinator.retryPendingDeletes` 共用此純函數）。
- **封存同理可本地收斂集合 = `updated_words ∪ not_found`**（`KGVocabCoordinator.locallyResolvableArchives(from:)`）。`not_found` 代表 server 已無此字，封存意圖對本地而言已可收斂；`failed` 才保持未收斂並重試。
- `failed` 內的字（或任何「三個 bucket 都不在」的字）才 `markSyncFailed()` 進重試。
- 後端 batch lookup key 為 `_normalize_word(_clean_content(word))`：尾標點 / 首字大小寫等儲存層清洗後等價的輸入會命中同一張卡。完全相同的 submitted word 只執行一次；同一清洗 key 的不同 submitted word 會沿用首次 outcome，但 response bucket 仍 echo 各自的原始 word，讓 iOS 以本地 `entry.word` 收斂。
- **不變式 1**：絕不可把 `not_found` 當刪除失敗 → 否則永久卡死的隱形重試迴圈。
- **不變式 2**：絕不可把 `failed` 當成功收斂 → 該字 server 仍存在，本地移除會造成 client/server 永久分歧（#720 根因；後端已把 graph-失敗字從 `not_found` 移到 `failed` 修正此半邊）。

### 同步失敗後重試

1. 上傳新增或刪除失敗時，單字會先標記為 `failed`
2. 同步頁仍會把它算進待處理項目
3. 下一次同步前，App 會自動把 `failed` 轉回 `pending` 再重試
4. 若失敗的是刪除，單字仍維持隱藏，避免違反使用者已經做出的刪除決定
5. **`not_found` 不是失敗**（見上節）— 已不存在於 server 的字本地直接收斂，不進此重試迴圈；反之 batch 回應的 `failed` bucket 才是 server 端 graph 操作失敗（卡片仍在），須進此重試迴圈

## 同步觸發鏈

### `pullCardsToLocal` single-flight（所有 pull 路徑共用）

vocab pull 有五個呼叫點：`KGVocabView.task`（進頁自動）、pull-to-refresh、錯誤 banner 的重試、`SyncCoordinator` 的 pipeline 輪詢、以及 `backgroundSync`。過去只有 `backgroundSync` 有 claim 鎖，其餘各跑各的——生產日誌可見同一個 `?since=` cursor 被兩個請求同時帶出去（兩輪在對方寫回 boundary 前各自讀了同一個值）。現在 `KGService.pullCardsToLocal` 是一層 single-flight wrapper：

- **序列化、不合流**：後到的呼叫排在前一輪之後（`KGService.enqueuePull`），各自發自己的 `GET /api/vocab`，所以不會有兩個請求帶同一個 `?since=`。不共用前一輪的回應：pipeline 輪詢要的是「自己上傳之後」的 `X-Pipeline-Pending`。
- **`notebookId` 決定是哪一種 pull**：`nil` 是全域 sync，擁有 `SyncKeys.incrementalBoundary` 與 payload-version 升級，full sync 才做 orphan cleanup。非 `nil`（AddLink 的 local projection）是 notebook-scoped projection：對該 notebook 做 drain 完的全量讀取，經 `KGService.mergeNotebookScopedCards` 以 `isIncremental: true` 合併——**不做 orphan cleanup、不讀也不寫 boundary 與 `payloadVersion`**。舊行為拿全域 boundary 當 `since` 又寫回去，其他 notebook 在舊 boundary 之後的伺服器變更從此拉不到；boundary 清空時更會以單一 notebook 的卡跑 full-sync cleanup，把其他 notebook 的卡當 orphan 刪掉（#2102）。Explore 複製後的 `pullCopiedDeck` 走同一條 merge。
- 實際工作跑在 **unstructured `Task`** 裡，因此**不繼承呼叫端的取消**。從 `.task` / `.refreshable` 發起的 pull 不會因為 view 重繪或離場而被砍掉——那正是舊行為把 `URLError.cancelled`(-999) 一路包成 `KGError.networkError`、在使用者面前顯示「網路錯誤：已取消」的成因。
- 取消不是失敗：`authenticatedRequest` 把 -999 轉成 `CancellationError`，`backgroundSync` 的 phase 回報略過它，單字本 banner 也不因它改變畫面。

`KGService.backgroundSync` 是共用 resync 入口，由以下觸發：post-login / scenePhase→active / ⌘R menu / Settings 手動同步。其執行序：

0. **logout-cleanup gate**（claim 鎖成功後、任何 sync 工作前）— `await sessionInvalidator.waitForPendingLocalDataCleanup()`。詳見下節「logout-cleanup gate 不變式」。
1. vocab push → vocab pull（本文上述狀態流轉）。**push → pull 必須序列**（pull 會把伺服器的 `lastReviewedAt` 寫回本地，先拉再送會覆蓋掉「還沒送出」的基準）。
2. **podcast catalog** — 自整輪最前面就與第 1 條**併行**（2026-08-06 起；原為序執行於 vocab pull 之後）。共用 backgroundSync 的所有觸發；自我防禦、不 throw。詳見 `docs/reference/feature_boundary/podcast.md §同步觸發`（含空 server list 非權威的 tombstone 不變式、以及它併行後必須自帶的 session 前置檢查）。

**併行邊界（不變式，違反會靜默損毀資料）**：可併行的只有「零欄位重疊」的腿——podcast catalog（`PodcastSeries`/`Episode`/`Progress`）與 vocab 管線（`VocabularyEntry`/`ReviewRecord`）互不相交，故安全。Card 只有一個 `/api/vocab` pull writer；不得再增加會同時 fetch/write 全部 `VocabularyEntry` 或共用 `SyncKeys.incrementalBoundary` 的第二 projection。即使 `BackgroundSyncActor` 是 `@ModelActor`，多個 call site 各自 `init` 仍只會序列化同一實例；平行 writer 會造成 lost update、mergeKey 重複插入或 mass-deletion 分母漂移。

### Settings 顯式同步與帳號邊界

- 一般 `backgroundSync` 遇到已有同步時回傳 `.didNotRun`；Settings 的顯式同步走 `backgroundSyncWhenAvailable`，等待 process-wide shared lane，避免帳號切換後把上一帳號的 busy 狀態誤當成新帳號「已同步」。
- Settings coordinator 在 account boundary 取消持有中的 resync task、遞增 generation/request token 並重置暫態進度；已進入底層同步的舊 round 即使完成，也不得更新新帳號的 UI、SwiftData save 或 terminal state。
- DEBUG UI World 的同步 transport evidence 以 session token 隔離；帳號切換後舊 transport 的晚到事件不得寫入新 session 的證據。

## 複習進度覆寫（review-state push `override`）

- `ReviewStateEntry.override = true`（`PATCH /api/vocab/review`）是進度重設指令：`review_count` / `lapse_count` 原樣寫入、`next_review_at` 取 client 值（now），**不受** `last_reviewed_at` 新舊影響，server 較新時仍套用（#2042）。兩分支（server 較新／client 較新）寫入的 override 欄位一致：`review_count`、`lapse_count`、`review_interval_hours`、`review_streak`、`last_review_feedback`、`next_review_at`，排程結果與時鐘先後無關。`last_reviewed_at` 不在此一致集合內，見本節末條。
- 非 override 仍走 LWW：server 較新只取 counts 的 max；覆寫不取 max，否則 reset 無法落地。
- 同批次同卡多筆合併時，較新的 override 保留其 counts，不與較舊的一般 entry 取 max。
- server 較新分支不改 `last_reviewed_at`（歷史不改寫）；client 較新分支依 LWW 接受 client 的 `last_reviewed_at`。`override` 不會被持久化或由 pull 回傳。

## 複習事件上傳水位（review-event push watermark）

複習事件（`ReviewRecord` → `PATCH /api/vocab/review-events`）是 **append-only 帳本**，不進上述 `syncStatus × actionType` 狀態機；它自己的收斂條件是**水位**而非狀態轉移。

- **水位欄位（不變式）**：`ReviewRecord.pushedAt: Date?`。`nil` = 尚欠伺服器。`buildReviewEventsPushPayload` 只取 `pushedAt == nil`，並依 `reviewedAt` 遞增排序。
- **為何需要**：後端以 `event_id` 去重，client 端若無水位就無法區分「已上傳」與「新事件」，只能整份重送。2026-08-05 生產實測（帳號 000287）：9,542 筆事件、約 3.4MB、10 次序列 PATCH，佔一次同步 17s 中的 15.4s，伺服器每次皆回 `inserted=0, skipped=9542`。
- **逐批確認（不變式）**：`pushReviewEvents` 在**每個 batch 回應後**立即 `markReviewEventsPushed`，不是整輪結束才記。batch 才是伺服器實際接受的單位；後續 batch 失敗（離線 / 401 / 此突發自身觸發的 429）不可回退已落地的批次——這正是大量歷史事件能**跨多次同步分批排空**而非每次從頭的原因。
- **拉回即已確認（不變式）**：`mergeReviewEvents` 對插入的遠端事件直接寫 `pushedAt`。它來自伺服器就已在伺服器上；不標記會讓下一次推送把整份拉回的歷史原樣送回，水位永遠排不空。
- **遷移策略（刻意不 backfill）**：欄位為 optional，既有列一律以 `nil` 進場、在升級後第一次同步完整排空一次——成本恰等於舊行為，且不可能把「其實從未上傳成功」的事件誤標為已上傳。之後穩態為 ~0。
- **輸入契約（不變式）**：`event_id` 必須是非空白字串。空字串或全空白值在 API model boundary 以 HTTP `422` 拒絕，store 不會被呼叫，也不會寫入事件；非空 legacy ID 原樣保留，既有 `event_id` duplicate 行為（`inserted=0, skipped=1`）不變。

伺服器端對應：`ReviewEventStore.insert_many` 以分塊 `IN` 查詢一次取回已存在的 `event_id`（chunk 500，低於 SQLite 3.32 前 999 個繫結變數上限），取代逐筆 `session.get`。同一批 payload 內重複的 `event_id` 由迴圈內累加的 id 集合擋下（舊版靠 autoflush，改批次取回後必須顯式維持）。

`ReviewEventStore` 啟動時把 legacy `ingested_at` 文字（含 offset、`T`/`Z` 形式、缺小數位）一次性改寫為 canonical naive-UTC（`YYYY-MM-DD HH:MM:SS.ffffff`，冪等），使 `get_since` 的過濾與 `(ingested_at, event_id)` 排序、以及 `insert_many` 的 `SELECT max(ingested_at)` 都在 SQL 內走 `ix_reviewevent_ingested_at` 索引，不再全表載入後在 Python 排序。

## logout-cleanup gate 不變式（重登↔sync 競態防線）

`AuthManager.logout` 排程的本地清理（`clearLocalData`）會跳 `BackgroundSyncActor`、是真實 suspension。快速「登出→重登」時，若 sync 在 cleanup 收尾前動工，會搶用尚未清乾淨的 sync boundary 跑 incremental（後端全部 skip → 本地空庫卻自認最新），且拉回的資料又被 resume 的 cleanup 再清一遍 —— 2026-06-09 帳號 000287 單字本事故根因。防線：

- **單點 gate（不變式）**：sync 動任何工作前必先等 logout cleanup 鏈收尾。gate 只在 `backgroundSync` claim 鎖成功後的**唯一入口**生效（`await sessionInvalidator.waitForPendingLocalDataCleanup()`），因此**四個觸發點（post-login / scenePhase→active / ⌘R menu / Settings 手動）全部**自動經過同一道 gate；call site 不再各自重複 gate。無 pending cleanup 時 gate 立即返回（正常冷啟登入不被拖慢）。
- **cleanup 鏈化（不變式）**：連續 logout 時 `pendingLocalDataCleanup` 保留前一個 handle 並 chain（新 cleanup `await previousCleanup?.value` 才動工），故同一時間至多一個 cleanup 跑、零互踩。gate 只 await 最新 handle 即隱含前序全部收尾。
- **generation re-check（防 TOCTOU）**：`waitForPendingLocalDataCleanup` 進場記 `localDataCleanupGeneration`，await 完若 generation 已被新 logout 遞增則重 loop，直到鏈上最後一個 cleanup 完成 —— 單次 await 只跟得到進場當下 handle，re-check 補住懸掛期間又 logout 的窗口。
- **gate 期間被擋的是同一次 sync（不變式）**：sync 被 gate 擋下等待，等待結束後**是同一次 sync 繼續往下跑**（非取消後補跑），因此「等 cleanup」與「跳過這次 sync 待下次補跑」語意等價，**不會漏 sync**。
- **Accepted residual**：gate 通過後、sync 真正動工前，caller（非 MainActor 的 `backgroundSync`）resume 有一次 executor hop；logout 恰落在此窗口仍會與新 cleanup 並行。徹底閉合需 sync 內部 generation re-check/abort（另案），現靠空庫安全網 + 帳號切換清 boundary 緩解。

## 帳號偏好 purge 與 delete_account 邊界（#2434 / #2556）

- **登出 purge（不變式）**：`clearLocalData` 只清 pre-account raw review-card layout 的本機領養副本（`ReviewCardLayoutStore.purgeAdoptedLegacyRawLayout`）。iCloud KVS 的 raw layout 刻意保留：移除共享 KVS raw key 會把刪除傳播到同一 Apple ID 的其他未領養裝置。
- **領養 marker 回填（不變式）**：領養紀錄同時寫入 UserDefaults 與 iCloud KVS。舊版只寫本機的已領養裝置，於每次啟動時把本機 marker 回填到 KVS（`AccountPreferenceNamespace.publishLocalAdoptionToCloud`），否則未領養裝置仍會把保留的 KVS raw layout 領養進後續帳號。
- **delete_account purge（不變式）**：只清被刪帳號的 `kg.account.<digest>.*`，UserDefaults 與 KVS 兩層都清；其他帳號的命名空間不動。被刪帳號 ID 必須由 `SettingsCoordinator` 於 `await DELETE` 前擷取，經 `AuthManaging.logoutAfterAccountDeletion(modelContainer:deletedAccountID:)` 傳入。不得於 await 後才讀 `userId`：併發的 401 teardown 會先把它清成 nil，purge 會被靜默跳過（#2556）。
- **刪除範圍（不變式）**：刪除文案宣稱的「雲端閱讀進度與書架」由後端 `DELETE /api/user/account` 移除 `users/<uid>/library.db`（`_remove_user_dir`，同一請求內完成）。本機 Book rows 與檔案刻意保留（`BackgroundSyncActor`，#758），文案不宣稱本機刪除。

## 知識圖譜變更的傳播（server 端 touch barrier）

知識圖譜連結（建立 / hide / unhide / delete）本身不在上述 `syncStatus` 流轉中。client 透過 `get_modified_since(updated_at)` 抓 card 增量，看到 card 變更後**重拉該 card 的 links**。因此每個 graph op 必須在改完 graph 後 **bump 兩端 card 的 `updated_at`**（`cards_store.touch`），否則 graph 變了但 client 永遠抓不到 → 靜默不一致。

- **不變式**：graph 變更後 touch 失敗**不可被吞掉**。`backend/src/kg/vocab_graph_ops.py:_touch_both` 保證：兩端皆嘗試 touch（一端失敗不跳過另一端，只要任一端 `updated_at` 前進 client 仍能收斂）、失敗 `logger.error`（可觀測）並 re-raise（不假裝成功）。
- **可逆 op（hide / unhide、create 的 unhide 分支）**：touch 失敗時回滾 graph 變更，使 graph 與 card 狀態一致。
- **不可逆 op（hard delete、create 新連結）**：不乾淨回滾，僅靠 barrier 的「可觀測 + re-raise」。
- **notebook 隔離硬化（manual link）**：card store 為 per-user、graph 為 per-notebook，故 `create_manual_link` 必填 `notebook_id`，兩端卡片的 `notebook_id` 須等於之，否則以 `NotFoundError(404)` 拒絕（語意：該卡不存在於此 notebook），杜絕跨 notebook 連結。後端為權威；iOS `AddLinkSheet` 候選 filter 額外加 `notebookId == sourceEntry.notebookId` 做 defense-in-depth（#776，`backend/src/kg/vocab_graph_ops.py`）。

## 共享牌組（Explore）與 sync 邊界

共享牌組庫（Explore）**不進**上述 `syncStatus × actionType` 狀態機：

- **browse = guest-tolerant public GET**：`SharedDeckCatalogService`（`PodcastSyncService` analog）走 `/api/decks*` 唯讀 mirror，router 無 auth dependency、容忍過期 bearer→guest；upsert 進獨立 `SharedDeck @Model`（**非** `VocabularyEntry`/`Card`），**永不進 client outbox**，故不觸發 vocab 上傳/刪除轉移。reconcile 保 empty-response mass-delete guard（空 server list 視為非權威、不下 tombstone），與 podcast catalog 同範式。
- **copy provenance（`source_shared_deck_id`/`source_version`/`source_shared_card_guid`）**：browse（Phase 1）不 stamp、pull-only；Phase 2 server-side copy 把完整 content plane 寫成 ordinary Card，重設 SRS 與 id、蓋 fresh `updated_at`，再經既有 incremental `/api/vocab` pull（`?since` / post-copy notebook-first targeted pull）作為已 synced rows 落地並立即參與一般複習。copy 不進 outbox；graph link 由 server 端 remap，故 `syncStatus × actionType` 狀態機結構性不變。

## Card 單一 projection 與字典 lookup 邊界

所有 Card 與 graph link 只走既有 `/api/vocab` 增量面與同一套 outbox/SRS 規則。後端字典 integration 的 search/detail GET 只回 lookup payload，不建立 Card、graph link 或同步狀態，因此不屬於本狀態機；lookup endpoint、flag、cache 與限流見 `docs/reference/tech_index.md`。

## Phase 2 之後的建議

- 若未來真的用到 `failed`，要補明確 retry 規則
- 若未來支援編輯詞卡內容，`edit` 需要獨立轉移表
- 若同步流程再變複雜，優先擴充這份文件與測試，而不是把邏輯散回各個 View
