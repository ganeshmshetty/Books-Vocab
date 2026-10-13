<!-- doc-meta
tier: reference
authority: derived
update_trigger: code-change
scope:
  - ios/BooksAndVocab/Views/Explore/
  - ios/BooksAndVocab/Models/SharedDeck.swift
  - ios/BooksAndVocab/Services/SharedDeckCatalogService.swift
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# Explore (Shared Decks) Feature Boundary

> Explore（探索）= 第 5 個 top-level section（`AppPrimarySection.explore`），
> 共享牌組庫的 iOS 對外 surface。後端 namespace 是 `shared_decks`、公開路由 `/api/decks`
> （endpoint / DTO / store 見 `docs/reference/tech_index.md`）。**禁用 `library` 一詞**
> —— 那是 EPUB/PDF 書庫（Bookshelf），命名碰撞會混淆。
>
> **Phase 1–2（已落地）**：guest 瀏覽 / 預覽官方策展牌組（Phase 1）＋**複製官方牌組
> 進私人 Notebook 即時可見**（Phase 2）。複製結果是一般可複習卡片：完整保留官方
> content plane、fresh SRS，並直接走 `/api/vocab` sync。`KGFeatureFlags.exploreEnabled` **自 2026-08-05
> 起恆為 `true`**（Release 亦曝光）——前置條件皆已滿足：`/api/decks` 在生產、官方目錄
> 已注入實質內容、browse/preview/copy telemetry 齊備。
> publish / rate / report 與 ShareLink deep-link 分享一律 Phase 2/3 fast-follow，見「範圍邊界」。

## 檔案清冊

### 導航接線（ContentView）

| 檔案 | 說明 |
|------|------|
| `ContentView.swift` | `enum AppPrimarySection` 加 `case explore`（`titleKey="app.section.explore"`、`systemImage="sparkles"`）。gate 走 `visibleCases(podcastEnabled:exploreEnabled:)`；iOS TabView 分支 render `ExploreView()`（`accessibilityIdentifier("tab.explore")`）+ macCatalyst `NavigationSplitView` sectionContent 分支（Catalyst parity 必驗）。 |
| `Models/KGFeatureFlags.swift` | `static let exploreEnabled`：compile-time 常數，**2026-08-05 起恆 `true`**（原為 `#if DEBUG` gate）。Explore 面在所有 configuration 曝光；gate 語意測試 `PodcastFeatureGateTests`（參數化 `visibleCases` / `resolvedSelection`，不綁 flag 實值）。 |

### Model Layer（唯讀 mirror）

| 檔案 | 說明 |
|------|------|
| `Models/SharedDeck.swift` | `@Model final class SharedDeck` —— 唯讀 mirror，**刻意不 reuse `Notebook @Model`**（否則 public/official 牌組滲進私人 Notebooks `@Query`）。欄位：`remoteId`（server 鑄造 deckId，穩定鍵）/ `title` / `authorLabel?` / `isOfficial`（source-driven badge，非 client-settable）/ `category?` / `languagePair?` / `tags` / `cardCount` / `downloadCount` / `ratingAvg?` / `ratingCount` / `color?` / `coverPattern?`（procedural fallback）/ `coverAssetID?` / `coverImagePath?` / `coverImageSHA256?` / `coverImageByteSize?` / `coverImageContentType?`（canonical installed asset provenance；`@Transient coverImageFileSystemInode` 僅 runtime snapshot）/ `updatedAt?` / `sortOrder`（server browse 次序固化）/ `isSoftDeleted`（`@Attribute(originalName:"isDeleted")` 本機 tombstone，鏡射 `PodcastSeries`）/ `syncedAt`。須 register 進 ModelContainer schema。 |
| `Models/SharedTypes.swift` | wire models（lenient decode，ignore unknown keys）：`SharedDeckSummary` / `SharedDeckCard` / `SharedDeckListResponse` / `SharedDeckDetail` / `SharedDeckCardsResponse`。 |
| `Models/Notebook.swift` | provenance 欄位（**Phase 2 copy 起 stamp**）：`sourceSharedDeckId: String?` / `sourceVersion: Int?`（跨裝置 sync 走 `KGNotebook` + `NotebookResponse`；copy 落地卡是已 synced server rows，不進 outbox——sync 語意見 `docs/reference/sync_lifecycle.md`）。 |

### Service Layer（PodcastSyncService analog）

| 檔案 | 說明 |
|------|------|
| `Services/SharedDeckCatalogService.swift` | `final class SharedDeckCatalogService` = `PodcastSyncService` 1:1 analog。`optionallyAuthedData(from:kgService:session:)` guest browse——**無 token 或 token 已過期皆放行，且不觸發 session invalidation**（取 token 走 `KGServing.authTokenWithoutInvalidation()` 這個零副作用入口，**不是** `currentAuthToken()`：後者對過期 token 會先 `sessionInvalidator.logout` 再 throw，`try?` 吞得掉錯誤卻吞不掉副作用，於是逛公開牌組會把人登出 —— APP-20260805-0049ac）。`session:` 帶預設值，僅供測試注入 URLProtocol 探針；`fetchDeckList(query:)` / `fetchDeckDetail(deckId:)` / `fetchDeckCards(deckId:cursor:limit:)`；`syncAll(context:)` **全目錄 cursor 分頁**（跟 `nextCursor` 抓完整個 catalog 再 reconcile；**截斷對稱化**——分頁被截斷時 skip reconcile，partial set 絕不驅動 mass-delete）→ upsert + `reconcileLocalState(serverSummaries:context:)` **empty-response mass-delete guard**（空 server list 視為非權威、不下 tombstone）。SwiftData fetch/reconcile/save 失敗回傳 typed `SyncFailure.storage(...)`、rollback 並不發成功同步通知；caller 必須呈現 error/partial，不得轉成 empty/new row。nested `BrowseQuery`（filter → `URLQueryItem`）。測試 `SharedDeckCatalogServiceTests` / `SharedDeckModelIsolationTests` / `SharedDeckWireDecodeTests`。 |
| `Services/KGService+Decks.swift` | copy 傳輸擴充。`copyDeck(deckId:idempotencyKey:notebookName:)` 打 `POST /api/decks/{id}/copy`（`DeckCopyResponse`）；`pullCopiedDeck(...)` post-copy **notebook-first targeted pull**——複製後只針對新 notebook + 其一般卡做 incremental `/api/vocab` pull，卡片即時可見且直接具複習資格；既有 synced server rows 不進 outbox。測試 `SharedDeckCopyPullTests`。 |

UI World materialization 另以 `SharedDeckCatalogService.upsertDeck(summary:installedAsset:)` 寫入 canonical asset provenance；Release remote summary 沒有 canonical asset path 時仍以 `coverPattern` 作 procedural fallback。若已有 canonical projection 但 path/SHA/bytes 不完整、bytes/SHA 驗證失敗或 image decode 失敗，Explore cover fail-closed，不回 procedural pattern。

### View Layer（`Views/Explore/`）

| 檔案 | 說明 |
|------|------|
| `ExploreView.swift` | 主場景：search field + filter chips（category / language-pair / official segment / sort）+ loading/empty/error/partial/no-results/content states（見 `docs/reference/ui/state_matrix.md`）；list/storage failure 都進 error/partial，不把 SwiftData failure 當空目錄；DEBUG fixture evidence 由單一 manifest asset node fail-loud 呈現；counts/dates 走 `LocaleAwareFormatter`。 |
| `SharedDeckDetailView.swift` | 預覽（card count / sample cards / author + official badge / rating / download count）**＋ 複製 CTA**（Phase 2）：tap → destination picker（可建新本、預填名）→ 觸發 `SharedDeckCopyController`；header cover 將 `SharedDeck` 的 canonical path/SHA/bytes provenance 傳入 `NotebookCoverView`，無 canonical asset projection 的 Release remote summary 才 fallback 到 `coverPattern`；canonical metadata/load failure 不 fallback。SwiftData detail fetch failure 是獨立 storage-error state，不能落到 missing deck。DEBUG evidence selector `explore.detail.cover.<remoteId>` 只掛在實際 rendered `Image` node，value 帶 `sha256` + `bytes` + installed path。4-state（idle / copying / done / error）+ offline / logged-out gate（離線或未登入時 CTA 停用並提示）。 |
| `SharedDeckCopyIntentStore.swift` | 複製待完成意圖的落盤（#3423）。`PendingDeckCopyIntent`（owner + deckId + idempotencyKey + notebook 名稱）、`SharedDeckCopyIntentStoring`（UserDefaults；`-isolatedAuthSession` 走 ephemeral）。inflight 寫入、success 清除；`SharedDeckCopyRegistry` 行程啟動時以此接回 key，重啟後 retry 不重複複製。 |
| `SharedDeckCopyController.swift` | 複製編排（Phase 2）。持有 **stable `idempotencyKey`**（同一次複製意圖重試不產生重複 notebook；經 `SharedDeckCopyIntentStore` 跨行程重啟保留，#3423）；驅動 `KGService+Decks.copyDeck` → `pullCopiedDeck`，管理 4-state 與 offline / logged-out gate。`SharedDeckCopyRegistry` 以 deckId + 帳號 owner 隔離；inflight／failure 於 reopen 原樣接回，success 僅在目標 notebook 已不在本機時退場（重拉**完整成功**且仍無才視為已刪、可重新複製；重拉失敗維持成功態）（#2748）。測試 `SharedDeckCopyControllerTests`。 |
| `ExploreDeckCard.swift` | Explore grid/list 的 deck 卡片元件。 |
| `ExploreFilterChip.swift` | filter chip 元件。 |
| `SharedDeckPresentation.swift` | Explore 呈現層純函式（view data 組裝）；測試 `SharedDeckPresentationTests`。 |

### Debug / Test 錨點

| 檔案 | 說明 |
|------|------|
| `Debug/Scenarios/ExploreViewScenarios.swift` / `SharedDeckDetailViewScenarios.swift` | Catalog surface scenarios（`CatalogScene` 註冊）。 |
| `Debug/Scenarios/SharedDeckCatalogFixtures.swift` | Catalog / UI-World 的 SharedDeck seed 資料。 |
| `BooksAndVocabUITests/ExploreNavigationUITests.swift` | Explore tab 導航 + a11y UITest（`AppPage` 加 Explore 入口），另驗 loaded fixture 的 detail cover 由 production `SharedDeck` asset path 投影並留下獨立 evidence step。 |

## 改動規則

- **新增 Explore 畫面 / 元件** → `Views/Explore/`；動工前讀 `docs/sop/ui-design.md` + `docs/reference/ui/{components,review_checklist,state_matrix}.md`；deck cover 復用 `NotebookCoverView`，優先使用 `SharedDeck` canonical installed asset，`coverPattern` 僅是沒有 canonical projection 的 procedural fallback；canonical metadata/load failure 必須 fail-closed。Catalog 是按需使用的 agent UI 工作台：只有反覆 debug／展示有價值時才自願新增 UI World scenario，不設覆蓋義務。正本：`docs/reference/catalog_scope.md`。
- **改共享牌組 wire / model** → `Models/SharedTypes.swift`（lenient decode）+ `Models/SharedDeck.swift`（@Model，改欄位須 verify SwiftData lightweight migration）。**絕不** reuse `Notebook @Model`。
- **改 browse / sync 邏輯** → `Services/SharedDeckCatalogService.swift`（reconcile 純邏輯保 empty-response guard；`syncAll` 全目錄分頁保截斷對稱化）。
- **改 Explore fixture evidence / storage failure contract** → `Support/Fixtures/Core/FixtureDatasetSeeds+Explore.swift` 維持每 fixture 單一 `assetIDs`；`ExploreView` evidence lookup、`SharedDeckCatalogService` SwiftData transaction 與 `SharedDeckDetailView` storage state 必須一起更新並補 failure-path tests，禁止 optional/empty fallback。
- **改複製流程（copy）** → client 走 `Views/Explore/SharedDeckCopyController.swift` + `Services/KGService+Decks.swift`（stable idempotencyKey、post-copy notebook-first targeted pull）；server-side clone 不變量與 `POST /api/decks/{deckId}/copy` 見 `docs/reference/tech_index.md`。**官方牌組可複製性**由 emitter curation guard `_assert_copyable` 在 emit 前把關（擋同 deck 內 NOCASE 同形字碰撞，否則 copy 端撞私人 `Card` `UNIQUE(content COLLATE NOCASE, notebook_id)` 致 count mismatch）——見 `docs/reference/tech_index.md` `build_official.py` 條目。
- **改後端 endpoint / DTO / store / env** → 見 `docs/reference/tech_index.md`（`/api/decks` router、`shared_decks.db` 6 表、DTO、cursor、caps env、`Notebook.is_staged` copy barrier）。
- **改 telemetry** → 事件定義在 `Services/AppAnalytics.swift`（`AnalyticsEvent` 的 Explore 段 + `SessionMetrics` 四個 deck counter + `SessionSnapshot.logSummary`），掛點只有三處：`ExploreView.syncCatalog`（browse）、`SharedDeckDetailView.load`（preview，**僅成功呈現才計**）、`SharedDeckCopyController.copy`（copy 成功/失敗 + Sentry breadcrumb）。**隱私線**：`deckId` 是 server 鑄造的公開識別碼可 `.public`；使用者搜尋字串**只上報 `hasQuery` 布林、絕不上報內容**。失敗分類走 `SharedDeckCopyController.failureReason`（ASCII 穩定值，與 i18n 的 `message(for:)` 刻意分開）。測試 `ExploreTelemetryTests`（聚合斷言用獨立 `SessionMetrics()` 實例，不碰 `.shared`，避免與並行 suite 互相污染）。
- **i18n 鐵律 8**：新 View 零 raw 中文；`app.section.explore` + 所有 Explore/preview keys 進全 5 lproj。使用者供給的 deck title / authorLabel 是 runtime 資料（i18n 覆蓋外）。

## 範圍邊界（Phase 分期）

| 能力 | Phase | 狀態 |
|------|-------|------|
| guest 瀏覽 / 預覽官方牌組（唯讀）| 1 | ✅ 已落地 |
| Explore section Release 曝光 | 2 | ✅ 2026-08-05 flip（`exploreEnabled` 不再 `#if DEBUG`）|
| 複製官方牌組進私人 Notebook（copy）+ destination picker + ordinary Card + fresh SRS + 即時可見 | 2 | ✅ 已落地 |
| ShareLink deep-link 分享 | 2 | ⏳ fast-follow（deferred、out-of-scope）——需 Apple portal Associated Domains + AASA 部署，屬獨立基建決策 |
| `deckBrowsed` / `deckPreviewed` / `deckCopyCompleted` / `deckCopyFailed` telemetry 事件 | 2 | ✅ 已落地（`AppAnalytics` + `SessionMetrics` 聚合 + copy 路徑 Sentry breadcrumb）|
| Card / Notebook provenance stamp（`sourceSharedDeckId/Version` + `source_shared_card_guid`）| 2 | ✅ 本切片（copy 落地即 stamp）|
| PublishSheet / 「我發布的牌組」/ rating / report UI | 3 | 🔒 UGC，需使用者 go |

## 相關 doc

- `docs/reference/tech_index.md` **(SoT)** — `/api/decks` router、`shared_decks.db` 表、DTO、cursor、env、`build_official.py` CLI
- `docs/reference/product_surface.md` **(SoT)** — 已實作能力清冊（Explore bullet）
- `docs/reference/feature_boundary/notebook.md` — 牌組容器（copy 目標，Phase 2）
- `docs/reference/sync_lifecycle.md` **(SoT)** — copy 語意（provenance inert / guest-tolerant browse 不進 outbox）
- `docs/reference/ops_state_plane.md` **(SoT)** — 官方注入 emitter（`build_official.py`）§4 入口偏差
