<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - ios/BooksAndVocab/
  - backend/src/kg/
verified_against: ccf74f4a1dc18760d9ede238dfece39cde0c61d7
-->
# Books & Vocab Architecture (Offline-First & Multi-User)

Books & Vocab app 採用**後端權威、離線優先**的資料架構。已後端化的跨裝置 domain state 以 Knowledge Graph (KG) 伺服器為權威來源；尚未後端化的共享 state 依本文資料權威邊界分階段遷移。iOS 的 `SwiftData` 應收斂為本機投影、離線 cache 與 outbox 執行基礎，不再作為跨裝置 Single Source of Truth 的長期架構。完整的帳戶隔離機制確保多用戶與多設備場景下的資料安全。

本機仍必須保存資料，因為核心場景包含離線閱讀、離線查詞、離線複習與低延遲 UI。但本機保存的語意分三類：

- **Authoritative remote state**：後端 DB / object storage 是權威，client 只持有鏡像與 pending intent。
- **Device cache**：可刪可重建的媒體、封面、subtitle、下載音訊、書籍檔案副本。
- **Local-only ephemeral state**：單次 session、debug、尚未決定是否同步的 UI 暫態。

**平台**：iOS 26+ / iPadOS 26+ / Mac Catalyst（macOS 26.0+，`SUPPORTS_MACCATALYST`，非原生 macOS — 核心依賴 Readium 僅 iOS）

**Client 端**：iOS / Mac Catalyst app；官網由 backend static pages 服務

---

## 資料權威邊界

| 資料類型 | 權威來源 | iOS 保存語意 | 備註 |
|---|---|---|---|
| 帳號 / session | Backend auth + Keychain token | Keychain session cache | 登出 / token invalidation 必須清本機 user-scoped projection |
| Vocabulary card / graph links / notebook assignment | Backend card / graph / notebook stores | `VocabularyEntry` projection + outbox | 本地新增、刪除、hide/unhide 先 optimistic，再同步收斂 |
| Review state | Backend card review fields | `VocabularyEntry` review fields projection | LWW 以 `last_reviewed_at` 判定 |
| Dictionary lookup / cache / provider budget | Backend GET integration + `lexical_cache.db`（跨用戶全域） | 不投影；iOS 無字典 surface | 查詢不建立 Card 或 graph state；provider、授權、TTL、限流與每小時上游預算全歸 backend。跨用戶共用快取避免重複消耗上游額度；觀測入口 `ops_cli.py dictionary-health` |
| Review event log | Backend `review_events` append-only log | `ReviewRecord` projection | client `event_id` 必須非空白；API 以 422 拒絕空白值後才進入 store，非空 legacy ID 維持冪等；日曆與每日明細讀事件鏡像 |
| Notebook metadata | Backend `/api/notebooks/*` | `Notebook` projection + pending mutation | cover photo 本機 path 只是 device cache；遠端 cover 需另設 asset 權威 |
| Podcast catalog | Backend podcast catalog / object storage | `PodcastSeries` / `PodcastEpisode` cache | 空 server list 不視為權威刪除，避免短暫 index 故障 mass tombstone |
| Podcast progress | Backend `podcast_progress` LWW store | `PodcastProgress` projection | CloudKit 只能視為 legacy/過渡，不應再當跨裝置權威 |
| Podcast follow | 目標為 backend user preference | 目前 `PodcastSeries.isFollowed` local preference | 若未來新增非 Apple client，需先後端化 |
| Book metadata / reading progress | 目標為 backend library store | 目前 `Book` 由 SwiftData CloudKit 保存 | 後端化時保存 metadata、locator、progress、preferred notebook；原始檔走 asset/object storage |
| Book / podcast media files | Object storage 或本機匯入來源 | FileManager cache / download | 不塞 SQLite；可刪後重抓或要求重新下載 |
| Reader / review / translation / appearance settings | 目標為 backend user config | 目前混用 UserDefaults + iCloud KVS | 多平台前需 typed server config；UserDefaults 只作啟動快取 |
| UI filter / sort / session snapshot / debug URL | Local-only unless explicitly promoted | UserDefaults / memory | 不影響跨裝置資料完整性，可維持本機 |

### Current storage audit（2026-06）

本表是目前 codebase 的實際持久化盤點，不是目標狀態。掃描來源：`AppBootstrap.fullModelTypes` / `ModelConfiguration`、iOS `UserDefaults` / `CloudPreferencesSync` / `FileManager` 使用點、後端 routers / API models / stores。

| Surface | 目前存放 | 後端整合狀態 | 缺口 |
|---|---|---|---|
| `VocabularyEntry` 詞卡、review state、graph links | iOS `LocalStore` projection；backend `cards.db` / per-notebook graph stores | **已後端權威化**，仍保留 iOS outbox/cache | `edit` 狀態仍需完整 contract；iOS 本機 projection 不可誤當 SoT |
| `ReviewRecord` 複習事件 | iOS `LocalStore` projection；backend `review_events` append-only log | **已後端權威化** | 需持續保證非空白 client `event_id` 冪等與刪卡後事件保留 |
| `Notebook` metadata | iOS `LocalStore` projection；backend `/api/notebooks/*` + `notebooks.db` | **大致後端權威化** | 自訂 cover photo 仍是本機 file path；遠端 cover asset 尚未成為權威 |
| `PodcastSeries` / `PodcastEpisode` catalog | iOS `LocalStore` cache；backend `/api/podcasts*` + object storage metadata | **catalog 已後端權威化** | `PodcastSeries.isFollowed` 仍是本機欄位 |
| `PodcastProgress` | iOS `CloudStore` CloudKit；backend `podcast_progress.db` LWW | **後端已有權威面，但 iOS 仍未退 CloudKit** | 需要補推/觀測/再 local-only 退場，不能一步刪 CloudKit |
| `Book` metadata / reading progress | iOS `CloudStore` CloudKit `Book` | **未後端化；綁 Apple ID 非 app 帳號** | 無 backend library API、無 `remoteBookId`、無 position outbox；登出 / account-switch **不清** Book 行（`clearUserData` 刻意排除，2026-06-10），與 per-Apple-ID 檔案範疇對齊 |
| Book 原始檔 / converted EPUB / originals | iCloud container `Documents/Books` 或 local `Documents/Books` / `Originals` | **未後端化** | 無 object storage asset manifest、upload/download/quota/privacy policy |
| Reader settings | `ReaderSettings` UserDefaults + iCloud KVS | **未後端化** | font/size/line-height/scroll/underline 尚無 server config domain |
| Translation language | UserDefaults + iCloud KVS；backend `/api/user/config.translation`（含 `updated_at`） | **三層後端化**（Feature C；source/target 共用單一 group `updated_at` 整組 LWW + server cold-start wins、只寫本地不回寫 KVS） | 對標其他 group：backend 真 LWW 待 `serverTranslationLwwEnabled`，現以 iCloud KVS 為 Apple 裝置權威 |
| Review settings / pause clock + mode/SRS | `ReviewSettingsStore` UserDefaults + iCloud KVS；backend `/api/user/config.review_clock` + `.review_mode` | pause clock、mode/自訂 SRS 參數皆三層後端化（各自 updatedAt LWW 整組原子 + server cold-start wins；autoplay 純本地） | 對標 translation：backend 真 LWW 待 `serverReviewClockLwwEnabled` / `serverReviewModeLwwEnabled`，現以 iCloud KVS 為跨裝置權威 |
| App language / appearance | UserDefaults + iCloud KVS | **未後端化** | 若未來新增非 Apple client，不會共享；`.system` selection 需 server contract |
| Active notebook / notebook filter / sort | `activeNotebookId` 三層（`ActiveNotebookStore` UserDefaults + iCloud KVS + backend `/api/user/config.vocab_ui`）；`NotebookFilter` / `NotebookSortOption` 仍 `@AppStorage` local-only | **activeNotebookId 已三層後端化**（Feature B；updatedAt LWW 整組原子 + server cold-start wins；filter/sort 純觀感 local-only） | 對標 review settings：backend 真 LWW 待 `serverVocabUiLwwEnabled`，現以 iCloud KVS 為 Apple 裝置權威、backend 為 cold-start 橋樑 |
| Review session snapshots | UserDefaults | **local-only** | 可保留本機；不應納入後端權威，除非要跨裝置續答 |
| Podcast downloads / covers | `Documents/podcast-downloads`、`Documents/podcast-covers` | **device cache** | 登出清理已存在；不應後端化為 DB state |
| Notebook cover photo files | `Documents/notebook-covers` path | **未後端化 asset** | 需要 cover asset contract，否則多裝置看不到自訂圖 |
| Auth session | Keychain token + UserDefaults profile；backend auth/user store | **正確分層** | token 不應進一般 user config；Keychain 為 device credential cache |
| Debug server URL / welcome seen / auto-sync threshold | UserDefaults | **local-only** | 可維持本機，不需要後端化 |

結論：目前不是「全面整合到後端」。已整合的核心是詞卡 / graph / notebook / review events / podcast catalog / podcast progress backend 面；尚未整合的是書庫、書檔 asset、多數偏好設定、podcast follow、部分 UI state 與 cover assets。後續 rollout 應優先處理會影響跨裝置語意的資料；純 device cache / debug / session snapshot 不需要後端化。

### 遷移原則

- 後端化不是移除本機資料，而是把本機資料降級成 projection / cache / outbox。
- 新增跨裝置 user-facing state 時，預設先設計後端權威 contract；只有明確 local-only 的 UI 暫態才可只放 `UserDefaults`。
- CloudKit / iCloud KVS 不再作為新功能的跨裝置權威。既有使用處可分階段退場，退場前必須有後端 contract、資料 migration 與 rollback gate。
- 書籍與音訊等大型資產走 object storage 或本機 cache；SQLite / SwiftData 只保存 metadata、進度與檔案索引。
- 衝突解決必須寫成 contract：append-only event 用非空白 client `event_id` 冪等，偏好設定與 progress 用 timestamp LWW，刪除/封存用 tombstone 或明確 bucket 收斂。

### User config contract（目標狀態）

目前後端 `/api/user/config` 只持久化 translation language；iOS 仍把多個跨裝置偏好放在 `UserDefaults` / iCloud KVS。多平台化前，user config 應收斂成 typed server contract，並讓本機 store 只作啟動快取與離線 pending patch。

| Config domain | 目標欄位 | 目前 iOS 來源 | 衝突規則 |
|---|---|---|---|
| `translation` | `source_lang`、`target_lang`、`updated_at` | `TranslationLanguage` + iCloud KVS；後端已保存語言但缺 timestamp LWW | `updated_at` LWW；遠端失敗 rollback 本機 |
| `reader` | `font`、`font_size`、`line_height`、`scroll_mode`、`underline_opacity`、`updated_at` | `ReaderSettings` UserDefaults + iCloud KVS | 整個 reader object LWW；debug hit-testing 不同步 |
| `review` | `mode`、custom intervals、`progress_paused`、`progress_paused_at`、`updated_at` | `ReviewSettingsStore` UserDefaults；pause(`review_clock`)與 mode/custom intervals(`review_mode`)皆已上 iCloud KVS + backend `/api/user/config`（各自 updatedAt LWW），autoplay 仍純本地 | LWW；pause/resume 與 mode/SRS 須跨裝置一致，避免 due/reviewed 與 SRS 間隔漂移 |
| `appearance` | `mode`、`updated_at` | `AppAppearanceStore` UserDefaults + iCloud KVS | LWW；`.system` 只保存 mode，不保存 resolved value |
| `language` | `app_language`、`updated_at` | `AppLanguageStore` UserDefaults + iCloud KVS | LWW；`.system` 只保存 selection，不保存系統解析結果 |
| `podcast` | `followed_series_ids`、`updated_at` | `PodcastSeries.isFollowed` local SwiftData | LWW 或 per-series timestamp；server list 用於排序與 cross-platform follow |
| `vocab_ui` | `active_notebook_id`、`updated_at` | `activeNotebookId` UserDefaults | LWW；server 必須拒絕已刪 notebook，client 保留本機 fallback |
| `auto_link` | `enabled`、`updated_at` | `AutoLinkSettingsStore` UserDefaults（無 iCloud KVS 層）| **真 LWW（已落地）**：新 group 無 cold-start-only 歷史包袱，server `updated_at` 較新即套；push 失敗 rollback 含原時戳 |

分階段實作時，先擴充後端 response 以向後相容方式回傳 optional domains，再讓 iOS 依 domain-level `updated_at` merge。每個 domain 的 PATCH 必須是 partial update，不能用缺欄位覆蓋既有 server config；client 也不能在 fetch 失敗時把本機舊值重新 PUT 成權威。

### Podcast state migration（目標狀態）

Podcast catalog 與 media 已由後端 / object storage 提供，iOS 的 series / episode rows 是 cache。剩餘要收斂的是 per-user state：progress 已有後端 LWW store，follow 仍是本機偏好。

| State | 現況 | 目標 | 退場條件 |
|---|---|---|---|
| Catalog | `/api/podcasts*` + object storage 權威；iOS `PodcastSeries` / `PodcastEpisode` cache | 維持現況 | 不使用空 catalog 進行 mass tombstone；短暫 S3 index 故障只降級 |
| Progress | 後端 `podcast_progress.db` LWW；iOS `PodcastProgress` 仍在 SwiftData CloudKit store | 後端為唯一跨裝置權威；iOS row 只作 cache + pending push | iOS 啟動 / catalog sync 先 pull remote，播放中節流 push；確認 migration 後把 `PodcastProgress` 移出 CloudKit config |
| Follow | `PodcastSeries.isFollowed` local SwiftData | 後端 user config 或 dedicated follow endpoint 權威；iOS optimistic toggle + rollback | API 回傳 followed set + `updated_at`；iOS 首次 migration 上傳本機 followed series；server 拒絕不存在 / deleted series |
| Downloaded audio | `PodcastDownloadManager` 本機檔案 | 純 device cache | 登出 / account switch 清本機下載；不可當作跨裝置權威 |
| Cover cache | `podcast-covers/` 本機檔案 | 純 device cache | server cover retracted 時刪 cache；登出清 cache |

Progress CloudKit 退場不可直接刪 schema。安全順序：

1. 後端 progress endpoint 與 iOS pull/push 已雙向上線，且 tie-break 規則一致（同 instant 取較大 position）。
2. 新版本 iOS 啟動時先把現有 CloudKit/local `PodcastProgress` 補推到後端，再 pull remote merge。
3. 觀測一個發版週期後，`PodcastProgress` 改到 local-only store；CloudKit 舊資料只讀一次 migration，不再作權威。
4. 最後移除 CloudKit dependency 前，確認 `Book` 也已有後端 library contract；否則 `CloudStore` 還會因 `Book` 存在而保留。

Follow 後端化應優先走 user config domain（`podcast.followed_series_ids`），除非需要 per-series audit / notification 才拆 dedicated table。client 的 toggle contract 必須是 optimistic local update，server 失敗 rollback；若 server 回傳某 series 已不存在，client 應清除該 follow 並顯示一般同步收斂，不視為 fatal error。

### Reading library migration（目標狀態）

`Book` 目前由 SwiftData CloudKit 保存 metadata、cover blob、`lastReadLocatorJSON`、`progression`、`preferredNotebookId` 與檔名；實體檔案在 iCloud container / Documents。這讓 iOS 裝置間可同步，但 web / Android / backend 無法讀取，且 CloudKit schema 仍綁住 app 資料架構。後端化後應拆成兩層：

| Layer | 後端權威 | iOS cache | 備註 |
|---|---|---|---|
| Library metadata | `book_id`、title、author、format、source hash、cover asset id、created/updated/deleted timestamps | `Book` projection | `book_id` 應為 server id；本機 UUID 可作 migration client id |
| Reading position | `last_locator_json`、`progression`、`date_last_read`、`updated_at` | `Book.lastReadLocatorJSON` / `progression` cache | LWW；EPUB/PDF 都走同一 contract，避免 PDF 顯式 save、EPUB debounce save 行為漂移 |
| Notebook binding | `preferred_notebook_id` | `Book.preferredNotebookId` cache | server 拒絕 deleted / nonexistent notebook；client 失敗 fallback 到 active/default |
| Asset manifest | object key、size、sha256、format、upload status | `epubFileName` / local path cache | 原始 EPUB/PDF/TXT/MD 不進 SQLite；TXT/MD 轉 EPUB 後可同時保留 original asset |
| Cover | cover asset key 或 derived thumbnail | local cover cache / optional SwiftData blob during migration | 大圖不長期塞 SwiftData blob；可由 backend 產生或 client upload |

建議 API contract（後續實作，非現況）：

- `GET /api/library/books?since=`：增量列出 metadata + tombstone。
- `POST /api/library/books`：建立 book metadata，帶 `client_book_id` 冪等鍵與 optional asset manifest。
- `PATCH /api/library/books/{book_id}`：partial update metadata / notebook binding。
- `PUT /api/library/books/{book_id}/position`：LWW 更新 locator / progression。
- `POST /api/library/books/{book_id}/asset-upload`：取得 object storage upload target 或宣告本機-only asset。
- `GET /api/library/books/{book_id}/asset`：下載 / redirect 至可授權的 object storage URL。

Migration 順序：

1. 先只同步 metadata + reading position，不要求原始檔上傳；跨裝置可看到書目與進度，但沒有 asset 時顯示「需下載 / 重新匯入」狀態。
2. 加入 asset upload entitlement / quota policy：免費層可只同步 metadata；Pro 或明確容量限制才同步原始檔。
3. iOS 首次啟動 migration 掃描現有 `Book`，以 `client_book_id` 冪等 upsert 到後端；成功後保存 `remoteBookId`（後續實作需新增欄位）。
4. Reader 每次 debounce save 後排 position outbox，不讓翻頁直接阻塞網路；進背景 / 關閉 reader 時 flush 本機與 best-effort remote。
5. 後端 metadata / position 穩定後，`Book` 可移出 CloudKit store；但移除 CloudKit entitlement 前要確認沒有其他 model 仍依賴 CloudKit。

刪除語意必須是 tombstone，而不是只刪本機 row。使用者刪書時：

- metadata tombstone 同步到後端，其他裝置隱藏該書。
- 本機檔案可立即刪除；object storage asset 在 tombstone commit 後 best-effort 立即 `delete_object`（`DELETE /api/library/books/{id}`），asset 格式 / local-only 變更時同樣刪除被取代的舊 key；刪除失敗只記 log、不使請求失敗，舊 key 留在 `library.db` 的 `librarypendingobjectdelete` ledger，於下一次 library 寫入重試，並由帳號刪除（erasure）兜底回收。目前沒有「刪書後 recovery window」：tombstone 不可還原 asset。
- 帳號刪除（erasure）的 late PUT 上界：tombstone 後仍有效的 presigned PUT（`_ASSET_URL_TTL` = 3600 秒 = 1 小時）可能落地為 `library/<uid>/` 下的孤兒物件。erasure 於本地目錄移除之後執行前綴 sweep（`sweep_account_prefixes`）清除；已接受的保留上界是「erasure 之後至多 1 小時內的上傳」，reconciler 不在範圍內。
- 帳號持有人需套用的 IAM policy（agent 不執行 aws；`<bucket>` 換成實際 bucket 名）：

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "ListLibraryPrefix",
        "Effect": "Allow",
        "Action": "s3:ListBucket",
        "Resource": "arn:aws:s3:::<bucket>",
        "Condition": {"StringLike": {"s3:prefix": ["library/*"]}}
      },
      {
        "Sid": "DeleteLibraryObjects",
        "Effect": "Allow",
        "Action": "s3:DeleteObject",
        "Resource": "arn:aws:s3:::<bucket>/library/*"
      }
    ]
  }
  ```

  唯讀驗證：`aws s3api list-objects-v2 --bucket <bucket> --prefix library/ --max-keys 1`（只列不刪）。
- 詞卡的 `bookId` 關聯不應硬刪詞卡；只解除來源書關聯或保留書名 snapshot。

### Rollout PR sequence（目標順序）

後端權威化應拆成多個可回滾 PR，不做單次大爆破。每個 PR 都要保持舊版 iOS 可用，且後端 response 新欄位必須 optional / backward-compatible。

| PR | Scope | 主要產出 | Gate |
|---|---|---|---|
| 1 | User config timestamps | 後端 `TranslationLanguageConfig.updated_at` + domain-level partial merge；iOS 開啟 translation server LWW | backend tests + iOS settings tests；遠端失敗 rollback |
| 2 | User config domains | reader / review / appearance / language / vocab_ui optional domains；iOS 啟動 fetch + local cache fallback | 每個 domain partial PATCH 測試；fetch 失敗不可 PUT 舊值 |
| 3 | Podcast follow backend | `podcast.followed_series_ids` 或 dedicated follow endpoint；iOS optimistic toggle + migration | 不存在 series 收斂；登出 / account switch 清 projection |
| 4 | Podcast progress backend hardening | 啟動一次性補推 CloudKit/local rows 到後端，維持 CloudKit 讀取作過渡；加 migration/drift counters | LWW tie-break 一致；重複 migration 冪等；至少一個發版週期觀測 |
| 5 | Podcast progress CloudKit退場 | `PodcastProgress` 改 local-only projection，不再把 CloudKit 當權威 | PR4 觀測完成；feature flag 可回 legacy；無嚴重 drift |
| 6 | Library metadata + position backend | `/api/library/books*` metadata / tombstone / position；iOS `Book.remoteBookId` + position outbox | 不上傳 asset 也可用；EPUB/PDF position contract 一致 |
| 7 | Library asset sync | object storage upload/download、quota、privacy copy、download state UI | 大檔不上 DB；quota / entitlement / retry / cancellation tests |
| 8 | CloudKit / iCloud KVS cleanup | 移除不再需要的 cross-device Apple-only authority；保留 UserDefaults 啟動快取 | 發版週期觀測完成；舊資料 migration 完成；rollback path 明確 |

每個實作 PR 的 docs gate：

- 改 backend endpoint / DB / env / schema 時，同步 `docs/reference/tech_index.md`。
- 新增已上線 user-facing 功能時，同步 `docs/reference/product_surface.md`。
- 改 iOS feature 分層或檔名時，同步對應 `docs/reference/feature_boundary/*.md`。
- 改 sync 狀態流轉時，同步 `docs/reference/sync_lifecycle.md`。
- 只寫目標規劃而未實作 endpoint/schema 時，不更新 reference SoT，以免把 roadmap 誤標成產品現況。

### Verification and rollback gates

每個資料權威遷移 PR 必須能獨立回滾。後端新增欄位與 endpoint 先上線、舊 client 可忽略；iOS 再逐步讀寫；最後才移除 Apple-only authority。

必備驗證：

- **Backend contract tests**：partial PATCH 不覆蓋缺欄位、`updated_at` LWW、stale write 被拒或回傳現有值、tombstone 不復活。
- **iOS unit tests**：fetch 失敗 fallback、本機 optimistic update rollback、logout/account-switch 清 projection、migration 重跑冪等。
- **Cross-device scenario**：A 離線改、本機 outbox；B 線上改；A 回線後依 contract 收斂，不可雙方互相覆寫成舊值。
- **Backward compatibility**：舊 iOS 對新增 response domain 忽略不 crash；新 iOS 對舊 backend 缺 domain 使用本機 fallback。
- **Docs gate**：實作 PR 必須更新 reference SoT；規劃 PR 只能更新 SOP，避免產品現況污染。

Rollback 規則：

- 後端 schema 加欄位 / table 時先 additive，不在同 PR 刪舊資料。
- iOS feature flag 預設可關閉 server-authoritative domain，關閉後回到本機 cache / legacy sync。
- Migration 必須冪等：同一 `client_id` / `event_id` / `client_book_id` 重送不產生 duplicate。
- 刪除 / tombstone rollout 前不得 hard-delete remote asset；先保留 recovery window。
- CloudKit / iCloud KVS 退場只能在至少一個發版週期觀測無嚴重 drift 後進行。

Operational observability：

- Backend 對 migration write path 記錄 accepted / stale / rejected / duplicate counters。
- Admin 或 log 查詢需能按 user id 檢查 config、podcast progress、library metadata 的 remote 狀態。
- iOS sync log 需能區分 fetch failed、merge skipped、rollback、migration already done。
- 若 drift 偵測發現 server 缺少本機已存在的 migrated entity，client 應補推而非靜默刪本機。

---

## 核心資料模型: `VocabularyEntry` & `AuthManager`

### 多帳戶認證架構

**AuthManager** (`AuthManager.swift`) 負責全應用的認證與帳號管理：
- **isLoggedIn**: 用戶是否已登入（Apple / Google Sign-In）
- **userId**: 當前活躍帳戶的 ID，儲存於 Keychain
- **token**: JWT 認證令牌，用於 KG API 呼叫的 `Authorization: Bearer` 標頭
- **Apple Sign-In**：原生 `ASAuthorization` 流程
- **Google Sign-In**：整合 GoogleSignIn SDK，支援多設備無縫切換
- **Web Auth**：後端提供 `/login` → Google/Apple OAuth callback 的瀏覽器登入骨架(官網未來擴展成帳號/訂閱管理的入口)。`/login` 會為 Apple form-post flow 預先 mint `oauth_state` HttpOnly Secure cookie，Google flow 的 nonce 由 `/auth/web/google/login` 簽發並記錄於 server 端（單次使用、600s TTL、process-local，見 `deploy.md` 單 worker 不變式），callback 必須同時通過 cookie compare 與該 nonce 的消耗，重放或偽造的 cookie/state 配對在任何對外 token 交換前即被拒；成功後**僅**簽發 session JWT(中間頁呈現),**不設** admin/session cookie。未來 same-origin 帳號流程會改設 session cookie + redirect
- **Guest Mode**：未登入時仍允許查詞與本地儲存，帳號切換時自動清除舊帳號資料

### 生詞條目狀態管理

閱讀器中所有的生詞、以及知識庫中所有的卡片，在手機端都統一對應到同一個 SwiftData Model: `VocabularyEntry`。`VocabularyEntry` 是後端 card state 的本機 projection，同時承載離線新增 / 刪除 outbox，不是跨裝置權威。
我們透過 `syncStatus` 與 `actionType` 這兩個欄位來控制單字的狀態與流向。

- `syncStatus` 已由 `VocabularySyncState` 封裝：`pending` / `synced` / `failed`
- `actionType` 已由 `VocabularySyncAction` 封裝：`add` / `delete` / `edit`
- 實際持久化仍保留原始欄位，避免 SwiftData migration 成本，但業務邏輯應優先走 typed helper，如 `queueDelete()`、`markSynced()`
- 更完整的規則表見 [reference/sync_lifecycle.md](../reference/sync_lifecycle.md)

| `syncStatus` | `actionType` | 含義 | 在哪裡顯示？ |
|-------------|--------------|------|-------------|
| 0 | `"add"` (預設) | **待收錄**：在手機新增，但尚未上傳至 KG 伺服器 | `VocabularyListView` 頁籤「待收錄」清單、`SyncView` 的上傳階段 |
| 1 | `"add"` | **知識庫**：已經與 KG 伺服器同步過，存在於雲端的單字 | `KGVocabView` 頁籤「知識庫」清單 |
| 0 / 1 | `"delete"` | **待刪除**：使用者在手機點擊刪除，等待上傳告訴 KG 伺服器也要刪除 | 隱藏不顯示，僅在 `SyncView` 執行刪除 Request |

> **注意：執行緒安全 & 帳號隔離**
> - 所有與後端同步並寫入 SwiftData 的操作，都會使用獨立的背景 `ModelContext` 來執行，避免 UI 卡頓
> - 帳號切換時，`AuthManager.logout()` 會自動呼叫 `clearLocalData()` 清除**app-account-scoped** 的 SwiftData（vocab / review / notebook / podcast series·episode·progress），確保隔離
> - Settings 顯式同步在帳號邊界會取消 active resync task、拒收舊 generation 的晚到事件與 save；若既有底層 round 尚未結束，新的 Settings round 等待 process-wide sync lane，不與舊 service instance 併發寫入
> - **例外：`Book` 刻意不清**。書庫綁 Apple ID（`CloudStore` CloudKit + per-Apple-ID 檔案）而非 app 帳號；清 Book 行只會讓重登後書架空白（檔案仍在、冷啟動 reconciler 又補回），故 `clearUserData` 排除 Book。登入轉換另呼叫 `AppOrphanBookRecovery.run` 即時補建被清空的列（2026-06-10）

---

## 閱讀器 (ReaderView) 的離線運作

支援格式：EPUB、TXT、MD、PDF（`BookshelfImportService` 統一入口，TXT/MD 經 `EPUBConverter` 轉 EPUB 後閱讀，PDF 走 `PDFReaderView` 獨立路徑）。`EPUBConverter` 拆三檔：核心 `EPUBConverter.swift`、Markdown 解析 `EPUBConverter+Markdown.swift`、純 Swift ZIP 寫入 `EPUBConverter+MinimalZIP.swift`（避免 ZipFoundation 依賴）。Reader 以 `#if os(iOS)` 隔離 —— Catalyst 下 `os(iOS)` 為 true 故仍編譯仍啟用（非原生 macOS，無 AppKit 路徑）。

1. **底線渲染 (Underline Rendering)**:
   打開書籍時，撈出所有非刪除的 `VocabularyEntry`，注入 JS 顯示底線。離線亦可。

2. **點擊單字 (Word Selection)**:
   - **已存在於本地**: 從 `VocabularyEntry` 取出翻譯/詞性/解釋瞬間顯示，`O(1)` 無網路。
   - **全新單字**: 觸發 LLM 翻譯（provider 由 backend registry 路由，預設 Gemini），自動擷取 context sentence（書籍原文上下文）；儲存時寫入 `syncStatus = 0` 的 `VocabularyEntry`。

---

## 雙向同步機制 (BackgroundSyncActor & KGService)

App 實作了雙向同步流程，由 `BackgroundSyncActor`（`@ModelActor` 背景執行緒）驅動。同步的目標是讓本機 projection 收斂到後端權威狀態，並把離線期間產生的 pending intent 送上後端：

1. **Push Review State** — 推送本地複習狀態（`review_count`、`next_review_date` 等），LWW 策略以 `last_reviewed_at` 判定
2. **Push Review Events** — 推送完整複習事件（`event_id`、`card_id`、`word_snapshot`、`notebook_id`、`feedback`、`reviewed_at`、`created_at`）；`event_id` 必須非空白，空白值在 API boundary 以 422 拒絕且不落盤，非空 legacy ID 維持 client UUID 冪等去重
3. **Upload Deletes** — 找出 `actionType == "delete"` 項目，呼叫 API 刪除
4. **Upload Adds** — 找出 `syncStatus == 0` 新詞，POST 到 KG
5. **Fire-and-Forget Pipeline** — 呼叫 `/api/pipeline` 觸發背景 AI 處理（Enrich → Embed → Judge → Difficulty），每次執行寫入 `pipeline_log.db` 記錄 per-run/step timing + status + items
6. **Pull & Merge** — `pullCardsToLocal`：
   - 增量同步（`since` 時間戳），只拉異動過的 KGCard
   - 背景執行緒合併翻譯、詞性、難度、graph links
   - 全量同步時做 Orphan Cleanup（安全閾值 50 筆 / ratio < 0.8 保護）
7. **Pull Review Events** — 從 `/api/vocab/review-events` 增量拉回跨裝置複習事件，寫入本地 `ReviewRecord` 鏡像；月曆與每日明細只讀真實事件，不再用 daily aggregate placeholder 補洞

### Bilateral Optimistic Sync（hide/unhide/delete links）

Graph link 操作採用 bilateral optimistic 策略：
- 使用者操作 → **立即本地修改** → 排入 `bilateralOps` queue
- 下次 sync 時 `flushPendingOperations` 批量 POST 到 server
- Server 端 hide/unhide 是 idempotent，重複推送安全
- Blocked pairs：hard delete link 時寫入 blocked pair，防止 pipeline 重新生成

### One-Shot Judge 子系統

Pipeline 的 Link 階段現由 one-shot judge 取代舊的 candidate queue：
- **pending_judge**：待 embed 的卡在 embed 前即寫入 `pending_judge_<nb>.json`（而非直接建 link）；judge 以 `pop_pending_judge` *claim*（不刪檔），links 落盤後才 `ack_pending_judge` 移出。任何例外／取消都把未結清的 id 交回佇列；行程被 SIGKILL 時 claim 仍在檔內，下一個行程的新 `GraphStore` 直接視為待判（#2084）。ack 只移除「自己 claim 到的那一代」：每次 enqueue 在檔尾 `{"gen": {id: token}}` 列記 generation（id 列仍是純字串，舊程式碼忽略該列；無 gen 的舊檔視為 claim 之前的最舊一代），別的 store 在 claim 後重新 enqueue 同一 id（cache 淘汰＋intake 重試）會換新 token，A 的 ack 因 token 不符而保留該列
- **Selective Prompt**：LLM 一次性判斷 pending pairs 是否值得連結，batch 模式節省 86% input tokens
- **Degree Cap**：`MAX_DEGREE` 限制每個 node 的 to-side 連結數，hidden links 不計入
- **judge_log**：完整記錄每次判斷的 accept/reject 決策，供 admin dashboard 顯示 acceptance rate
- **Blocked pairs**：hard delete 時寫入 blocked pair，judge 不會重新提議

### Translate Log

翻譯/解釋路徑新增結構化 LLM 呼叫日誌：
- 每次 LLM 呼叫記錄 prompt、response、token 消耗、latency
- **Cross-user cache**：相同 word+context 命中快取時跳過 LLM 呼叫
- Admin user detail page 可瀏覽 translate_log 記錄

### LLM Failure Log

LLM provider/SDK 的 terminal failure（429/5xx/timeout 等）另寫入 `llm_errors.db`，供 admin cost/error 趨勢補齊「有燒請求但無 usage」的觀測缺口；error message 入庫前必須遮罩 bearer/API key/token/password/secret-like 值。

## Notion-inspired UI 視覺系統

系統透過 CSS 與 JS 注入到 Readium，實行極簡的 Notion-inspired 視覺：

- **字體 (Typography)**: 英文 `Crimson Pro`（bundled, SIL OFL）+ `Biotif`，中文 `STSongti-SC`。
- **透明度控制**: `ReaderSettings` 面板調節 `--vocab-opacity` CSS Variable。
- **介面隱形化**: 底線用柔和 `linear-gradient`，高亮用低對比度邊框 + 4% Alpha 底色。

### Toast Notification System

全 app 暫時性提示走 `AppToastCoordinator`（EnvironmentKey 注入）；pill vs 畫面內面板、時長、佇列與文案上限的規範在 `docs/sop/ui-design.md`「暫時性提示」：
- `AppToast`：頂端 pill，預設單行、無動作按鈕，支援 swipe dismiss；截斷時可輕點展開成多行（#2862），4 種 style（success/info/warning/error）
- `AppToastQueue`：同一事件（`key`）就地取代、不同事件排隊（最多 2 則）
- `toastSheet` / `toastFullScreenCover`：自動注入 `toastOverlay()` 的 sheet wrapper
- `safeSaveWithToast()`：`ModelContext` 安全存檔 + toast 回饋
- 22 個 View 已接入

### Motion Layer

除了色彩、字體與材質，Books & Vocab 現在也把 motion 視為設計系統的一部分。

- 動畫語意層集中在 `BooksAndVocab/Models/AppMetrics.swift` 的 `AppMotion`
- 共享 transition 也集中在同一檔案，避免 feature 各自發明不同進出方式
- Reader、Review、Sync 是目前優先完成收斂的三條主路徑

目前映射原則：
- Reader panel / header → `panelState`、`headerState`
- Review reveal / navigation → `reviewRevealSpring`、`reviewNavigationSpring`
- Modal / sheet 交換 → `modalSwapSpring`
- Sync phase / step update → `phaseChange`、`feedbackPulse`

這層規範的主文檔在 `docs/sop/ui-design.md` 的 `Motion Contract`。
若要改動畫規則，先更新該文檔，再修改程式；若是查編譯或 SwiftUI 實作錯誤，回 `docs/sop/ios.md`。
若要確認現有有哪些可重用 UI 零件與互動模式，查 `docs/reference/ui/components.md`。
若要確認各主畫面有哪些狀態已覆蓋、哪些還沒補齊，查 `docs/reference/ui/state_matrix.md`。
若要查 backend 部署、debug、測試與格式規範入口，查 `docs/sop/backend.md`。

---

## Crash Reporting Layer（Sentry）

Backend + iOS 同時整合 Sentry，opt-in 啟動且預設關閉（`SENTRY_DSN` / `Info.plist SentryDSN` 為空時整層 no-op）。本段只談架構分層 — 細節不在此重複。

- **Backend 實作**：`backend/src/kg/sentry_init.py`；FastAPI / Starlette / Logging integrations + auth header / OAuth query scrub；狀態暴露於 `/api/system/info`。
- **iOS 實作**：`ios/BooksAndVocab/Services/AppCrashReporting.swift`；SPM 守門 + `BooksAndVocabApp.init()` 第一步 bootstrap + `setUser` 連動 `authManager.isLoggedIn`。
- **Env / 取樣 / 隱私規範（SoT）**：`docs/sop/deploy.md §Sentry 錯誤追蹤`。
- **iOS bootstrap 順序 / `beforeSend` 過濾規則**：`docs/sop/ios.md §Crash Reporting`。
