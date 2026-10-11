<!-- doc-meta
tier: reference
authority: derived
update_trigger: code-change
scope:
  - ios/BooksAndVocab/Views/Podcast/
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# Podcast Feature Boundary

## 檔案清冊

### Container Layer（主場景 View）

| 檔案 | 說明 |
|------|------|
| `PodcastHomeView.swift` | **podcast 頂層 section 入口（軸 B Phase 3）** `struct PodcastHomeView: View`，由 `ContentView` `AppPrimarySection.podcasts`（iOS TabView 第 2 / Catalyst sidebar）掛載——**DEBUG-only**：`AppPrimarySection.visibleCases(podcastEnabled:)` 依 `KGFeatureFlags.podcastEnabled`（compile-time `#if DEBUG`）過濾，Release 不出現本 section；`resolvedSelection(_:podcastEnabled:)` 防禦回退 `.bookshelf`（測試 `PodcastFeatureGateTests`）。自有 `NavigationStack(path: $navigationPath)`（鏡射 `NotebookListView` path-bound root）；root 統一註冊 `navigationDestination(for: PodcastNavRoute.self)`（`.series→PodcastEpisodeListView`、`.episode→PodcastPlayerView`），**series→episode→player push 全在本 stack 完成**，不再寄生 `BookshelfView`（解架構債）。首頁 phase 由 `PodcastHomePhase.resolve` 分成 loading / error / empty / content：首次同步中顯示同步卡，list fetch failed 且本地無 series 顯示 retry error state，有既有 catalog 時保留 content。**內容為串流 shelf 堆疊**：`continueShelf`（繼續收聽，`@Query PodcastProgress`（updatedAt desc）跨 series 在記憶體 join episode→`PodcastContinueRailCard`，空則整段隱藏）+ `seriesGridSection`（所有節目 `LazyVGrid`，followed 排前 + star badge）。series 卡 / continue 卡一律 value-based `NavigationLink(value:)`（LazyV/HStack freeze 契約 PR #366/#368/#370/#373）。`.task(id: authManager.isLoggedIn)` 觸發 `syncPodcastCatalog(showToastOnFailure:warmAudioAfterSync:)`；pull-to-refresh 走同一路徑但不 warm audio。`toggleFollow` / `refreshPodcastCatalog` 自 `BookshelfView` re-home。卡片 tap feedback 共用 `BookshelfCardButtonStyle`（已提升 internal） |
| `PodcastPlayerView.swift` | **薄 wrapper**：保留 feature 入口與測試相容的 static helper API（`fetchEpisode` / `resolveVocabularyContext` / `shouldPersist` / `isCompleted`），實際 UI 與生命周期 orchestration 下放到 `PodcastPlayerScene.swift` / `PodcastPlayerSupport.swift` |
| `PodcastPlayerScene.swift` | 主播放器場景 orchestration。持有 `PodcastPlayerViewModel` / `ReaderTranslationHandler` / progress persistence / episode-switch state，負責 `.task(id: activeEpisodeId)` 換集、`scenePhase`/`onDisappear` 存檔、字幕設定 sheet、translation panel bridge、retry subtitle、auto-advance 與高頻 `PodcastProgressTicker` 隔離。**系列綁定單字本 scope**：選詞 / cache（`resolveVocabularyContext` 的 `rawNotebookId`）/ 底線（`loadLookedUpWords(notebookId:)`）一律認 `loadedSeries?.resolvedNotebookId`（`NotebookBindable`），取代舊的全域 `ActiveNotebookStore.activeNotebookId`；`seedSeriesBindingIfNeeded`（`onChange(of: loadedSeries?.remoteId)` + `liveNotebooks` settle 時觸發）以最近使用的真實單字本 seed 固化綁定（`PodcastSeries.canSeedBinding` gate live 清單）；toolbar `books.vertical` → `$showNotebookPicker` sheet → `PodcastNotebookPicker` 切換 |
| `PodcastPlayerAccessSurface.swift` | player access chrome：`PodcastPlayerLockedGateView`（guest/login vs free/paywall 鎖定畫面）、`PodcastPlayerPreviewBanner`（3 分鐘 preview 升級條）、`PodcastPlayerSettingsButton`（toolbar glyph）。把 monetization / locked UI 從 session orchestration 抽離成明名 surface |
| `PodcastEpisodeListView.swift` | 單集列表 + series 詳情容器 `struct PodcastEpisodeListView: View`。**串流「show page」hero（軸 B Phase 1）**：`heroHeader` = `PodcastSeriesHero`（沉浸式模糊封面 backdrop + 封面卡 + 標題 + meta，見下 Hero Components 條目）+ `heroContinue`（「繼續收聽」主角卡 `PodcastContinueCard`，取代舊全寬 CTA）。**episode → player 單欄 push（2026-06 #672 收斂）** — tap episode row / 繼續收聽主角卡一律 `NavigationLink(value: PodcastNavRoute.episode(...))`，由 **PodcastHomeView root 的 `navigationDestination(for: PodcastNavRoute.self)`** 接住 `PodcastPlayerView`（軸 B Phase 3 起；podcast 獨立頂層 section 後不再經 `BookshelfView`），所有 layout 皆然。`warmConnection` 走 `.simultaneousGesture(TapGesture)`。**heroContinue 鏡射 episodeRow 的 freeze 契約**：`PodcastAccess.heroAction(...)` 解析出的 `navigatesToPlayer` 為真→value-based `NavigationLink`、gate→plain `Button{handleLockedTap()}`。舊「regular 左右雙欄（右欄 inline player + 可拖拉分隔線 + `detailRouter.show` 即時 swap + 選中 row 染 `accentSubtle`）」已移除，連帶刪 `detailRouter` state / `.podcastDetailPresentation` modifier / `layoutMode`·`sizeClass`。`PodcastEpisodeActivation.activation(...)` 恆回 `.push`（保留作 episode 路由契約測試錨點）。value-based + root 統一註冊是 freeze-fix 契約（PR #366/#368/#370/#373，見檔頭註解）。⚠️ series / episode push 全在 **`PodcastHomeView` root path-bound `NavigationStack(path:)`**（軸 B Phase 3；舊 `BookshelfView` overlay master pane 已廢，見架構債） |
| `PodcastSentenceLevelView.swift` | **薄 adapter**：保留句級字幕 feature 入口與 speaker-slot 決議，真正的 viewport/follow/selection orchestration 下放到 `PodcastTranscriptViewport.swift`，render token tree 下放到 `PodcastTranscriptColumn.swift`。主檔不再同時持有 scroll/follow state、bubble cell、underline engine 與 helper enums |
| `PodcastTranscriptViewport.swift` | 句級字幕 viewport orchestration：原生 `ScrollViewReader` follow-scroll、initial positioning、manual drag disengage、selection dismiss catcher、Catalyst follow pill、DEBUG `logBoundary`。持有 `isFollowing` / `selectionState` / `scrollAnimationTask`，把互動層從 `PodcastSentenceLevelView` 本體抽出 |
| `PodcastTranscriptColumn.swift` | transcript token tree：`PodcastTranscriptColumn` + `PodcastBubbleSkin` + `PodcastBubbleCell`，負責 speaker label、a11y、TextKit rect publish、詞庫螢光筆、逐詞底線 relay bars 與 per-cell `.equatable()` 邊界。這層是 render engine，不再和 viewport state 混檔 |

### Series → Episode → Player 導航（軸 B Phase 3 起：全在 `PodcastHomeView` stack）

> **series 全平台統一 value-based push。** podcast 抽離為獨立頂層 section 後（`PodcastHomeView`，見 Container Layer），series 卡片一律 `NavigationLink(value: PodcastNavRoute.series(...))` push 進 **`PodcastHomeView` 自己的** `NavigationStack(path:)`，episode→player 同 stack 續 push。不再有平台分支（舊 regular overlay master pane vs compact push 二分已廢）。
>
> ⚠️ **舊 `BookshelfView` overlay master pane workaround 已全刪**（軸 B Phase 3）：`@State selectedSeriesRemoteId` 疊加層、`PodcastSeriesActivation` / `.selectInline`、`PodcastDetailRouter.swift` 整檔、`BookshelfView` 的 `navigationDestination(for: PodcastNavRoute.self)` 與 toolbar 返回鍵均移除。獨立 stack 後不再需要那套「規避寄生 `BookshelfView` root」的 Catalyst overlay 防護。episode→player 單欄 push（#672 收斂）邏輯不變，只是 root 從 `BookshelfView` 換成 `PodcastHomeView`，並新增 auto-advance 換集（見 ViewModel `episodeFinishedTick` / `PodcastQueue`）。

### ViewModel Layer（播放狀態機）

| 檔案 | 說明 |
|------|------|
| `PodcastPlayerViewModel.swift` | `@Observable @MainActor final class PodcastPlayerViewModel`,播放/暫停/seek + auto-pause-on-lookup + per-user progress LWW sync + sleep timer(`sleepTimerMode` / `sleepDeadline` / `DispatchSourceTimer` wall-clock;`.endOfEpisode` 由 audio engine load 換集 callback reset) + `bufferedEnd`(YouTube-style buffer overlay) + `subtitleState: PodcastSubtitleLoadState`(idle/loading/loaded/failed + inline retry) + `PodcastPlayerBootstrapPhase`(播放器啟動期 loading / missingEpisode / ready 分類) + `onSystemPause` / `onInterruptionEnded(shouldResume:)` interruption hooks(`resumeAfterSystemPause` latch:只有 interruption began 當下正在播才在 `.shouldResume` 時經 `play()` 續播;每次 interruption ended(含無 `.shouldResume`)、使用者 pause/play/stop 與 route loss 皆清 latch,重複 began 不清;engine 的 interruption/route/remote 派發在 `PodcastAudioEngineTests` 以合成 Notification 釘住)+ `onRouteLost`(拔耳機,engine 暫停且無 resume;VM 轉 `.paused` 並清 latch,不武裝 latch)+ `onRemotePlay` / `onRemotePause`(鎖屏/控制中心指令經 engine 切回 main 後走 VM `play()`/`pause()`,`state`、進度存檔與 UI 不脫節;play 只在 `.ready`/`.paused`、pause 只在 `.playing` 生效,`.loading`/`.error` 忽略以免蓋掉載入/重試卡)+ `prefetchedDurationSec` + `audioHTTPHeaders` 透傳 + `playbackAnchor: PlaybackAnchor`(連續 playhead 外推錨點:mediaTime/wallClock/rate,handleTimeUpdate/seek/play/pause/cycleRate 刷新,驅動字幕底線連續引擎,見 `PodcastSentenceLevelView` 條目;**捲動已改原生 `scrollTo` follow,不再用此 anchor**) + `liveAnchor: PodcastLiveAnchor`(reference 型 playhead 鏡像,`playbackAnchor.didSet` 單點同步、`@ObservationIgnored`;讓字幕 view 的 EquatableView token 樹被每幀跳過時,underline 內層 TimelineView 仍能每幀讀到最新 anchor——見 `PodcastSentenceLevelView` 條目) + `episodeFinishedTick`(連續播放：`onPlaybackFinished` 自然播畢時 bump，view `.onChange` 觸發 `advanceToNextEpisode`；用 counter 而非 closure 以避 VM→view→box retain cycle，鏡射 `sleepTimerFiredTick`；`.endOfEpisode` 睡眠定時那次**不** bump → 播完本集即停) + `stop()`(session-internal teardown) vs `shutdown()`(terminal cleanup) |

### Domain / Integration（翻譯與詞彙橋接）

| 檔案 | 說明 |
|------|------|
| `PodcastPlayerSupport.swift` | player 純 helper：`fetchEpisode` / `resolveVocabularyContext` / `shouldPersist` / `isCompleted`。供 `PodcastPlayerScene` 使用，`PodcastPlayerView` 只保留薄 wrapper 轉發給測試與其他呼叫點 |
| `PodcastVocabularyContext.swift` | `struct PodcastVocabularyContext: VocabularyContextProtocol`，連通 reader-parity 翻譯 + 加入詞庫 |
| `PodcastNotebookPicker.swift` | **系列綁定單字本切換 picker**：`@Bindable series: PodcastSeries`，`@Query` 過濾 `!isSoftDeleted` 的 notebook，與 `ReaderNotebookPicker` 共用 presentational `NotebookBindingList`（位於 Vocabulary/）。選一本即 `series.preferredNotebookId = remoteId` + `safeSave` + dismiss；`onAppear` `sanitizeStaleBoundNotebook`（綁定本已刪 → 清 nil，下次開啟 re-seed）。無「跟隨全域」/「預設」選項。 |
| `PodcastVocabHighlightResolver.swift` | **字幕詞庫螢光筆比對（純函式，2026-06）**：`highlightedIndices(words:normalizedLookedUp:)` 算出字幕句中命中詞庫（含 inflections，由 `ReaderVocabularyContext.lookedUpWords` 展開）的 word index；`normalize` = 折疊彎撇號（U+2019→U+0027 直撇號）+ 小寫 + 去頭尾標點，**兩側對稱**比對（修字幕彎撇 vs 詞庫直撇的 don't/can't/I'm silent 不命中）。cell 端 `PodcastSentenceLevelView` 以命中 index + 逐詞 TextKit rect（`wordRects`）畫**常駐 background layer**（顏色/濃度/字底 32% 色帶取 `ReaderSettings.vocabHighlightPreferences`，對齊 Reader 的底線式 `.vocab-word` 而非整字高色塊；不受 `isCurrent‖isNext` gate 所有句子常駐、**選取時仍顯示**、`allowsHitTesting(false)` 不擋手勢）。播放逐字底線是另一個 overlay top layer（`PodcastTranscriptMarkLayer.playbackUnderline`），不可與詞庫 highlight 共用 overlay，避免 highlight 蓋掉跟隨底線；column 每 render 折疊一次 `normalizedLookedUp` 供各 cell 共用，cell `==` 納入命中集合、highlightPreferences、colorScheme 即加/刪詞庫或偏好變更會重繪。即時更新依賴 `PodcastPlayerView.body` 頂層 `let _ = translationHandler.lookedUpWords.count` 註冊 `@Observable` 依賴（否則讀取埋在 `playerContent(_:)` 內失效不及於 body，需重進該集才現）。單測 `BooksAndVocabTests/PodcastVocabHighlightResolverTests.swift`（11 cases） |
| `PodcastAccess.swift` | **分層授權 UX policy（純函式，鏡射後端 `podcast_access.py`）**：`PodcastTier{guest,free,pro}` + `tier(hasProAccess:hasToken:)`（pro 優先；有 token=free；無=guest，對齊後端 token 判別）、`isFreePreviewable`（`freePreviewEpisodeNumber=1`，純 ep-num policy 鏡射後端）、`canPlay(…previewAvailable:)`、`isPreviewPlayback(…previewAvailable:)`、`showsProLock(…previewAvailable:)`、`heroAction(tier:episodeNumber:previewAvailable:audioAvailable:hasProgress:allCompleted:) → PodcastHeroAction`（series hero 主 CTA 的純投影：評估序 lock→unavailable→preview→replay→resume→play；`PodcastHeroAction` enum 的 `navigatesToPlayer` 區分播放 vs gate，單測 `PodcastHeroActionTests.swift`）。後三者**額外**要求 `previewAvailable`：free 用戶僅在 ep1 真有 `preview.*` 資產時才視為可試聽，legacy/未回填 series 的 ep1（`previewAvailable=false`）顯 Pro 鎖而非導向後端 404 死路（client 比後端嚴一階以避免死巷；後端仍純依 ep_num 選 key）。**伺服器仍是安全邊界**，此為 UX 層先攔（鎖定 badge/登入/paywall/試聽標示），不靠樂觀請求解析 403。單測 `BooksAndVocabTests/PodcastAccessTests.swift` |
| `PodcastQueue.swift` | **連續播放佇列決策（純函式，軸 B Phase 3）**：`nextPlayable(in:after:tier:)` → 同 series `episodeNumber` 次大且 `audioAvailable` 者，過 `PodcastAccess.canPlay` gate；遇第一個有音訊但不可播的集即停（回 `nil`，**不**跳過鎖定集找更後面）→ free 播完 ep1 preview 不自動跨 Pro-only ep2、guest 不續播。`PodcastPlayerView.advanceToNextEpisode` 由 VM `episodeFinishedTick` 的 `.onChange` 驅動，命中即設 `overrideEpisodeId` → `.task(id: activeEpisodeId)` 接手換集。單測 `BooksAndVocabTests/PodcastQueueTests.swift`（7 cases） |
| `PodcastSelectionRouting.swift` | **字幕選取單字 vs 片語分流（純函式）**：`isSingleWord(_:)`（`split(whereSeparator:\.isWhitespace).count == 1`,前後/全空白自然落空 → 非單字）+ `route(for:) → .word/.phrase`。`PodcastSelectableSentenceTextView` edit menu「翻譯」依此把單一詞導向 word path、多詞片語導向 phrase path（reader 靠手勢本質分流,podcast 所有選取同出一個 `UITextView` edit menu 故改以 token 數判定）。單測 `BooksAndVocabTests/PodcastSelectionRoutingTests.swift`（5 cases） |
| `PodcastSelectableSentenceTextView.swift` | **統一兩態字幕渲染器（③ 3-A,2026-06）**：平常態與選取態共用**同一個** `UITextView`（只 `isSelectable` 切換 → 零 reflow,消除選取跳版）。display 態逐詞 rect 由 `PodcastSentenceUITextView.layoutSubviews`（`LayoutKey` cache 守門）publish 給底線 overlay；長按 `UILongPressGestureRecognizer`(0.35s) `characterIndex(for:)` 反查 word index 進選取；selecting 態原生選取 + edit menu 翻譯/解釋（`L10n`）。**edit menu 詞彙互動對齊 reader（2026-06）**：「翻譯」依選取字數分流（`PodcastSelectionRouting.route`）——單字→`onWordSelection`（word path：`translateQuick` + 字根還原 + 詞庫去重 + 既有條目直接載入）、片語→`onTranslateSelection`（phrase path）；「解釋」對**單字 + 片語皆出現**（移除舊 `shouldOfferExplain` 單字 gate，鏡射 reader 的 gate-free edit menu，後端 explain 單一 prompt 通吃，不改）。M1 fallback flag `displayTextIsInteractive`（翻 false → display 態 inert,gesture 退 cell 層） |

### Streaming UI Components（軸 B：hero / shelf / 卡片）

| 檔案 | 說明 |
|------|------|
| `PodcastSeriesHero.swift` | 兩個串流 hero 元件（皆純展示、不持有 navigation）：<br>**`PodcastSeriesHero`** — 沉浸式 series 標頭：ambient 模糊封面 backdrop（`coverColor` 漸層基底 + `coverImagePath` 存在時低透明模糊封面疊加，底部以 `LinearGradient → pageBackground` 融入無硬邊，`allowsHitTesting(false)` + `accessibilityHidden`）+ 浮起封面卡（`.appElevation(.z3)`）+ hero 標題 + 主持人/集數/總時長 meta（`metaText`/`formatTotalDuration` 自 PodcastEpisodeListView re-home）。<br>**`PodcastContinueCard`** — 「繼續收聽」主角卡（取代舊全寬 CTA）：play/lock disc（actionable=`brandHero`+`onBrandHero`、否則灰）+ 行動動詞 eyebrow（依 `PodcastHeroAction` 映射既有 L10n key）+ 目標單集 `displayTitle` + 進度條（`ProgressCapsule`，僅 `.resume`）+ 還剩 `podcast.continue.remaining`（`monospacedDigit`）。**navigation 由 owner（PodcastEpisodeListView.heroContinue）包**，鏡射 episodeRow 的 value-based-push / plain-Button freeze 契約，自身絕不建 NavigationLink。clock 用共用 `PodcastClock.format`。附 `#Preview` 涵蓋 hero + 6 種 action 狀態 |
| `PodcastShelf.swift` | **串流首頁元件（軸 B Phase 2）**：`PodcastShelf<Content>`（泛用水平 carousel：section 標題 + `ScrollView(.horizontal)` + `LazyHStack`，codebase 首個泛用橫排容器）+ `PodcastContinueRailCard`（繼續收聽卡：直式封面縮圖 + 右下 play disc + series/episode 標題 + `ProgressCapsule` + 還剩 `monospacedDigit`，固定寬 150）。皆純展示、owner 以 value-based `NavigationLink` 包（freeze 契約）。clock 用 `PodcastClock.format`。Scenario baseline×5（resume/no-progress/long/large-numbers/a11y3，見 `PodcastShelfCardsScenarios`） |
| `PodcastSeriesCard.swift` | `struct PodcastSeriesCard: View` — series grid 卡（2:3 封面 + waveform/追蹤 badge + 標題 + `主持人 · N 集` 串流 meta 單行 tail 截斷，無主持人退純集數）。軸 B Phase 3 自 `Bookshelf/Components/` 遷入本 feature 目錄（現由 `PodcastHomeView` grid 使用） |

### Streaming / Offline Services（ios/BooksAndVocab/Services/）

| 檔案 | 說明 |
|------|------|
| `PodcastAssetPreloader.swift` | @MainActor singleton；warm AVFoundation HTTP/2 連線（tap-on-row + bookshelf-appear）；LRU-5, 60s TTL；失敗即 evict |
| `PodcastDownloadManager.swift` | @MainActor @Observable singleton；URLSession.background 跑離線下載；落地 `episode.localAudioPath`（Documents/podcast-downloads/<seriesId>/<remoteId>.mp3）；`didFinishDownloadingTo` 先經 `downloadRejection(for:)` 驗 response：non-2xx 或 text/JSON/XML content-type 一律 `markFailed`（刪暫存、不落地、`localAudioPath` 不動、row 提供「重試下載」）；progress / failed 由 `@Query` 觀察。`configure(podcastEnabled:)` 於 gate off（Release）時拒收 ModelContainer，manager 保持 inert（測試 `PodcastDownloadManagerGateTests`）|
| `PodcastSyncService.swift` / `PodcastSyncServiceCore.swift` | `PodcastSyncService` 保留薄 facade/相容入口，核心同步流程位於 `PodcastSyncServiceCore.swift`；`syncAll(context:)` 拉取後端 podcast catalog 並 upsert series/episode。可注入的 `PodcastCatalogTransport`、`PodcastCoverCaching`、`PodcastCatalogReconciler` 分別隔離網路請求、PNG 封面驗證與非權威空目錄守衛，讓同步、封面與 reconcile failure 可獨立測試。**自我防禦**：list fetch 失敗即 skip、空 server list（`/api/podcasts` 回 `[]`，S3 index.json 短暫讀不到時）視為非權威 → reconcile 跳過 series tombstone（不 soft-delete），對稱 episode 層 empty-episodes 守衛、不 throw。**封面快取**：upsert 後以 bounded concurrency 跑 `cacheCoverIfNeeded`，把 `coverImageURL`（有值才）認證下載成 `Documents/podcast-covers/<sid>_<v>.png`（legacy 無 `?v=` 時退 `<sid>.png`）→ 寫 `PodcastSeries.coverImagePath`（HTTP 2xx + `image/png` + PNG magic 守門、best-effort、失敗退程序化封面、不 abort sync）；**server 撤回封面**（`coverImageURL` 轉 nil/空）時 `upsertSeries` 清掉 `coverImagePath` + best-effort 刪當前 path/legacy `<sid>.png`，避免 stale 快取永久渲染且不以 prefix 誤刪其他 `_` series；`LocalDataCleanerService.purgePodcastCovers` 於 logout/account-switch 清除 disk + memory cover cache。**觸發來源**：`PodcastHomeView` `.task`/`.refreshable` + `KGService.backgroundSync`（與 vocab 管線併行的 podcast leg，見 §同步觸發）。**請求形狀見下方 §catalog 請求形狀** |

**認證邊界（silent-failure regression）**：catalog browse 與背景預熱不得以 `currentAuthToken()` 作可選 token 前置檢查（#2806 前 `currentAuthToken()` 以本地時鐘判過期即登出；現已移除該判斷，但可選路徑仍一律走零副作用入口）。`optionallyAuthedResponseData`、`PodcastHomeView.warmFollowedSeriesAudio` 與 `PodcastEpisodeListView.warmConnection` 一律使用 `authTokenWithoutInvalidation()`；過期/缺 token 時 browse 走 guest 或 audio prewarm 直接 skip，絕不寫 `sessionExpiredReason` 或呼叫 logout。使用者主動的 required-auth 下載、播放、字幕仍取 `currentAuthToken()`（不以本地時鐘判過期）。登出只由真實 401 經 `handleUnauthorized` 觸發，入口為 `authenticatedRequest`、`authedResponseData`、`PodcastProgressSync.pushProgress` 與 user-config seam；**背景下載與 AVPlayer 播放不呼叫 logout**：下載的 401 經 `downloadRejection(for:)` 走 `markFailed`（row 顯示伺服器拒絕錯誤、可重試），AVPlayer 的 401 只表現為載入失敗（目前不檢查 HTTP 狀態，AVPlayerItem 不直接暴露 401）。已過期的下載或播放由同一使用者的下一次 authenticated 呼叫決定：若 catalog leg、字幕或進度同步也回 401，才登出。刻意不在下載回呼內直接登出，因為背景 URLSession 的回呼可晚於重新登入完成，而 `handleUnauthorized` 沒有 token 身分比對，會把新 session 誤登出。回歸錨點為 `PodcastSilentFailureTests` 的 optional browse 與兩個 audio-preload header seam 測試。 |

### catalog 請求形狀（2026-08-06 起：穩態 1 趟）

`syncAll` 以前對每個 series 各發一次 detail 請求且序列等待（1 + N 趟）。現在改成 **1 趟清單 + 只抓「內容指紋變了」的 detail**，且那些 detail 併發抓（滑動視窗上限 3，形狀沿用同檔 `cacheCovers`，避免目錄長大時對後端 stampede）。**穩態成本 = 1 趟**；有變更時 1 + 併發抓變動者；首裝 1 + 併發 N。**後端零改動**。

- **指紋不是只有 `updatedAt`**：`PodcastSyncService.fingerprint` 涵蓋 `updatedAt` + `coverImageURL` + `title` + `totalDurationSec` + `episodeCount`，欄位間以 U+001F 分隔避免互相冒充；落地在 `PodcastSeries.remoteFingerprint`（nil = 舊列或伺服器沒給 → 一律重抓）。判準是「`index.json` 會投影、而我們又會 render 的每個欄位」，因為發布工具**會在不 bump `updatedAt` 的前提下改內容**（見下方 §metadata.json contract 的封面條目）。
- **`PodcastSeriesSummary.updatedAt` 一直都在清單裡**，只是這個型別以前沒解它。`index.json` 是 `metadata.json` 的機械式投影（見 `ops/podcast_upload.sh`），所以清單天生帶著與 detail 相同的時戳。
- **刻意不走「把 detail 內嵌進 list」**：`episodes[].subtitleContent` 是整份 inline SRT（實測 165–212 KB/集），內嵌會把 7 KB 的回應變成數 MB，在行動網路上是用頻寬換往返。
- **重抓判準**（`needsDetailFetch`，逐條有測試 `PodcastCatalogSkipTests`）：沒見過 / 被 tombstone 過 / 伺服器沒給 `updatedAt` / 指紋不同 → 抓。**指紋相同但本機 episode 數與 `episodeCount` 對不上也抓**——這是完整性檢查不是快取檢查，上一輪可能只寫了一半，只看指紋會讓該 series 永遠卡在半套資料。
- **封面改由清單驅動**（不再只看這輪抓到的 detail），讓跳過的 series 也有機會補上它上次沒下載成功的封面；已快取者 `cacheCoverIfNeeded` 直接早退、零網路。
- **已知盲點**：若發布工具改了 episode *內部*欄位卻既不 bump `updatedAt` 也不動 `index.json`，清單上沒有任何差異，客戶端無從察覺。這只能由工具側解——`ops/podcast_preview_backfill.py` 原本正是這個形狀，已於同一批改成會 bump（契約見 `docs/reference/tech_index.md`）。

### 同步觸發

podcast catalog 同步現有兩條觸發鏈：

1. **PodcastHomeView 局部觸發** — `.task(id: authManager.isLoggedIn)`（登入狀態翻轉時同步）+ `.refreshable`（下拉重試）。首頁以 `PodcastHomePhase` 區分 loading / error / empty / content。
2. **`KGService.backgroundSync` 的併行 podcast leg**（`KGService+Sync.swift:runPodcastLeg`）— 共用所有既有 resync 觸發：post-login / scenePhase→active / ⌘R menu / Settings 手動同步。補上局部 task/refresh 沒跑到時 podcast catalog 仍可由全域同步復原的路徑（書為本地 `@Query` 故恆在）。**Release gate**：整條 catalog leg（list fetch + 封面下載）經 `KGService.runPodcastCatalogSyncIfEnabled` seam——`KGFeatureFlags.podcastEnabled == false`（Release）時在建構 `PodcastSyncService` 前 early-return，零 podcast 網路/磁碟活動（測試 `PodcastDataLayerGateTests`；logout cleanup 刻意不 gate，清舊 build 殘檔）。

   **2026-08-06 起改為與整條 vocab 管線併行**（`async let`，起跑於整輪最前面；原為序執行於 vocab pull 之後）。動機是量測：生產一輪 7.55s 裡 6.08s 在這條腿，而資料量僅約 7 KB——貴的是往返次數，且那些往返不需要等 vocab。用 `async let` 而非 `Task`：401 / cancelled 早退離開 scope 時，結構化併發自動取消並等待，不留孤兒（catalog 同步冪等，取消無後果）。**這筆成本 Release 從來不付**（leg 受 `podcastEnabled` gate），修它是為了不污染我們自己的量測與 debug 體感。
   - **併行後它必須自帶 session 前置檢查。** 以前它排在 vocab pull 的 401 早退之後、被那個 return 順手擋掉；跑在最前面就沒有那道保護。判定只讀 `authSession.token` 是否為 nil（keychain 未載入即跳過），**不以本地時鐘判斷 expiry**（#2806）；過期由伺服器真實 401 決定。前置檢查不走 `currentAuthToken()`：後者離線拋 `KGError.offline`、無 token 拋 `KGSessionPendingError`，目錄腿只需要「有無 token」這個狀態位。登出後的本地清理等待已在 `performBackgroundSync` 入口單點完成（`waitForPendingLocalDataCleanup()`，000287 防線），本腿排在它之後，不另行重複。
   - **失敗只染紅設定頁的那一列，不進 `failures`。** 進去會讓整輪判定為部分失敗、`lastSyncDate` 不前進、彈出「背景同步部分失敗」——讓 catalog 的一次 hiccup 凍住「上次同步時間」是明確的退步。逐步清單已提供該有的可見性。

### metadata.json contract

- `episodes[].subtitleContent: String?` 由 `ops/podcast_upload.sh` 嵌入；iOS `PodcastEpisode.inlineSubtitle` 直接消費，跳過 `/api/podcasts/{sid}/{ep}/subtitle` fetch
- `episodes[].localAudioPath: String?` (SwiftData only, 不在後端 JSON) — 由 DownloadManager 填寫；PlayerView 認到即用 file:// URL 跳過認證
- `coverImageURL: String?` 由 `ops/podcast_upload.sh`（full publish）**或** `ops/podcast_cover_publish.py`（封面重發布,audio-decoupled）寫入（`cover` stage 有產 `cover.png` → `/api/podcasts/{sid}/cover?v=<sha16>`，否則 `null`）；也在 `index.json` series entry（series list 即可顯示封面）。backend 忽略 query 仍 proxy 同一張 `<sid>/cover.png`；iOS 用 `v` token 命名本地快取，否則退 `color`/`coverPattern` 程序化封面。
  **替換既有封面仍可於下次 catalog sync 自動刷新** —— 這條在 detail-fetch 改成指紋跳過之後**依然成立，但成立的理由換了**，值得寫死免得下次有人「優化」指紋欄位時弄壞它：`podcast_cover_publish.py` 換 `coverImageURL`（新 `?v=`）並重建 `index.json`，卻**刻意不 bump `updatedAt`**，所以只比時戳的話新封面永遠到不了已安裝的裝置。現在能刷新，是因為 `coverImageURL` 本身就在指紋裡（見上方 §catalog 請求形狀）→ 指紋不同 → 重抓 detail → `upsertSeries` 寫新 URL → `cacheCoverIfNeeded` 見到新 `v` token 才下載。**「封面清單改由 summary 驅動」救不了它**：`cacheCoverIfNeeded` 讀的是**本機**那一列的 `coverImageURL`，沒有 detail 重抓就永遠是舊值。**把 `coverImageURL` 移出指紋 = 封面永久凍結。**
- `episodes[ep1].previewAvailable: Bool` + `previewDurationSec: Int`（free-tier 試聽，**僅 ep_01**）：`ops/podcast_upload.sh` 對 ep_01 以 `ffmpeg -t 180 -c copy` stream-copy 出 `ep_01/preview.<fmt>`（同 container/codec、無損）並寫此二欄；既有 series 由 `ops/podcast_preview_backfill.py`（bucket-driven、audio-decoupled、dry-run 預設 / `--execute` / `--check` drift）回填。backend `audio` 端點對 free tier 服務此 `preview.<fmt>` 物件（見 `tech_index.md` podcast_access），**不**對完整檔做 byte 截斷（progressive MP4 單 moov 宣告全長，截 byte 會讓 AVPlayer 報錯而非乾淨停止）。preview 欄位本身在 `episodes` 內、`index.json` 會 strip，故不出現在 series-list view；但**回填工具現在會另外 bump `updatedAt` 並 patch 這一筆的 index entry**，否則指紋不變、客戶端跳過 detail、回填的 preview 永遠到不了已安裝的裝置（工具契約見 `docs/reference/tech_index.md`）

### Sub-views（UI 元件）

| 檔案 | 說明 |
|------|------|
| `PodcastControlsView.swift` | 播放/暫停/快轉/速度控制列（brandHero CTA + appCompactAction；15s ghost 按鈕含 44pt 最小 tap target；seek bar 整條 20pt hit area 可點/拖，並有 adjustable trait(VoiceOver 上下滑/Switch Control ±15s 經 `PodcastSeekBarAccessibility` → `viewModel.skip` 夾限;UITest `PodcastPage.seekBar` 用 type-agnostic 查詢),幾何換算由 `PodcastSeekBarGeometry` 測試鎖住） |
| `PodcastEpisodeRow.swift` | 單集 list row（標題、長度、追蹤 chevron），row 節奏 token 對齊 `WordRow` |
| `PodcastSubtitleView.swift` | 字幕單行渲染 |
| `PodcastSettingsPopover.swift` | 字幕大小 S/M/L/XL/XXL + highlight 顏色 swatch（寫回 shared `ReaderSettings.vocabHighlightColorPreset`）+ auto-pause toggle + 逐字跟隨 toggle(`@AppStorage("podcast.wordFollowEnabled")`) + 睡眠定時 Picker(off / 5 / 15 / 30 / 60min / endOfEpisode)含 `TimelineView` MM:SS 倒數。**呈現方式**:`PodcastPlayerView` 以 `.sheet`(`NavigationStack` + 完成鈕)叫出，**非** `.popover`——toolbar-anchored `.popover` 在 Mac Catalyst present 過場 trap(`ops/catalyst_lint.sh` 守門)。觸發鈕依 layout 自判:compact 走 `ToolbarItem(.topBarTrailing)`,regular inline 走 `inlineSettingsButton` content overlay(player 不再自帶內層 NavigationStack,見 `PodcastPlayerView` 條目) |
| `PodcastFollowToggle.swift` | series 追蹤 toggle（已追蹤浮上書庫頂端） |
| `PodcastBadge.swift` | 「已追蹤」「新集數」狀態 badge |
| `SpeakerAccentBar.swift` | 多角色播客的口音/語者識別條 |
| `SubtitleRenderState.swift` | 字幕高亮狀態（current sentence index + 啟動瞬間 layout） |
| `PodcastTextKitWordRects.swift` | TextKit 逐詞 rect 純函式（③ 3-A）：`wordRanges`（位置式 word→`NSRange`,依 `sentence.text == words.joined(" ")`）+ `resolve`（`NSLayoutManager.boundingRect`,越界/zero 回 nil）+ `LayoutKey`（text+font+width cache 守門）。統一 `UITextView` 的底線 rect 來源,取代舊 `CachedFlowLayout`+`WordFrameKey` anchorPreference |

### Token Layer

| 檔案 | 說明 |
|------|------|
| `PodcastPlayerMetrics.swift` | 播放器 feature-local 尺寸常數 + `PodcastSeekBarGeometry` 純幾何 helper（track position → time / progress width / buffered width）+ `PodcastClock.format`（`m:ss` / `h:mm:ss` 時鐘格式，locale 無關；`PodcastContinueCard` / `PodcastContinueRailCard` 共用，消除先前兩處重複的 `formatClock`） |

---

## 改動規則

- **新增播放器控制 UI** → 抽到 `PodcastControlsView` 或新元件,不要繼續長 `PodcastPlayerView`
- **新增字幕呈現邏輯** → `PodcastSentenceLevelView` 或 `PodcastSubtitleView`,逐詞底線幾何抽到 `PodcastTextKitWordRects`（rect 解析）+ `PodcastUnderlineGeometry`（bar）,字幕高亮狀態抽到 `SubtitleRenderState`
- **新增播放狀態（speed / region / queue）** → `PodcastPlayerViewModel`,View 不放 mutable state
- **新增 series / episode 列表 UI** → `PodcastEpisodeListView` + `PodcastEpisodeRow`；列表卡片骨架走共用 `ListSectionCard`（UIComponents，與單字列表共用，見 `docs/reference/ui/components.md` §List Shell），divider 由 caller 在 `ForEach` 內插
- **改 podcast 頂層 section / series 導航** → `PodcastHomeView`（自有 `NavigationStack(path:)` + shelf 堆疊）+ `ContentView.AppPrimarySection`。series / episode / player 全 value-based push 在 `PodcastHomeView` stack，`navigationDestination(for: PodcastNavRoute.self)` 統一掛 root。**不要**重建 overlay master pane / `selectedSeriesRemoteId` / `PodcastDetailRouter`（軸 B Phase 3 已廢）。新增首頁 shelf → `PodcastShelf`（泛用橫排）+ 對應 rail card
- **改連續播放 / auto-advance** → 決策走 `PodcastQueue.nextPlayable`（純函式 + `PodcastAccess.canPlay` gate），觸發走 VM `episodeFinishedTick` → `PodcastPlayerView.advanceToNextEpisode`（設 `overrideEpisodeId`，**勿**改用 nav push 以免堆疊 nav stack）。entitlement 邊界改動同步 `PodcastQueueTests`
- **新增 user-tunable 播放參數(字幕 / 跟隨 / 計時器 等)** → `PodcastSettingsPopover`(集中所有 user-tunable 播放參數;非字幕專屬)
- **新增詞彙互動** → `PodcastVocabularyContext`(reader-parity:任何 reader 詞彙流程都要在此鏡像)
- **動分層授權（誰能播哪集 / 鎖定呈現）** → policy 一律走 `PodcastAccess`(勿在各 view 散寫 tier 條件)；改 free 可播範圍同步後端 `podcast_access.FREE_PREVIEW_EP_NUM` + `PodcastAccess.freePreviewEpisodeNumber` + `PodcastAccessTests`。鎖定 row 用 `Button{paywall/login}`（**不可**用 closure-based `NavigationLink`，會重現 LazyVStack freeze）；可播 row 維持 value-based `NavigationLink(value:)`。player 須保留防禦式 gate（`canPlay` false → `lockedGateView` 且 `loadEpisode` early-return，涵蓋 deep-link 直達）
- **新增 metric token** → 跨 feature 用升 `AppMetrics`;單 feature 用留 `PodcastPlayerMetrics`
- **訂閱進度持久化等高頻(15Hz)`@Observable` 狀態** → **絕不**把 `.onChange(of: vm.currentTime)`／類似高頻讀取掛在 `PodcastPlayerScene.body`／`playerCore`／`playerContent` 等父層,必須隔離進只渲染 `Color.clear` 的葉子(`PodcastProgressTicker` 模式)。否則 `@Observable` 的 per-view-body 失效會讓父 body 每 tick 重求值、連鎖重建字幕子樹,字幕的 `EquatableView` 優化(`PodcastTranscriptColumn.equatable()`)會被父層 invalidation 架空 → 捲動卡頓 + follow 捲動失效

## State 邊界

- `PodcastPlayerViewModel`：播放器狀態機(playing / current ep / progress / sentence highlight),由 `PodcastPlayerScene`（掛在 `PodcastPlayerView` 下）持有,**不**外洩至 series 列表
- `SubtitleRenderState`：字幕 layout 快取,由字幕 view 持有
- per-user progress(`/api/podcasts/.../progress`)走 backend LWW,iOS 端只 cache;不放 ViewModel mutable state
- `PodcastVocabularyContext` 為 protocol 橋接,持有者是上層 view;具體儲存交由共用 `VocabularyService`
- `PodcastSeries.preferredNotebookId`（`NotebookBindable` conformance）：系列綁定的單字本 remoteId，**純本機偏好**（與 `isFollowed` 同屬本機欄位，server 不下發、`PodcastSyncService` reconcile upsert 不覆寫）。每個系列綁定恰好一本，選詞/底線/cache scope 認此本，無 magic 預設本

## 共用依賴

| Token | 用途 |
|-------|------|
| `AppTheme` | 色彩,`@Environment(\.appTheme)` |
| `AppMetrics` / `AppShellMetrics` | 間距、尺寸 |
| `AppMotion` | 動畫 token(字幕跳動、按鈕回饋) |
| `AppTransition` | 過渡動畫 |
| `PodcastPlayerMetrics` | Podcast 專屬尺寸常數 |
| `VocabularyContextProtocol` | reader-parity 翻譯/查詞橋接 |
| `VocabHighlightPreferences` | Reader-shared 詞庫 highlight 偏好；PodcastSubtitleView 由 `ReaderSettings` 注入至句級字幕 |

## Storage backend(2026-06 Track B)

- **音頻格式**: AAC/M4A(128k,`+faststart`)。`.mp3` 仍可播,backend `audio.m4a` → `audio.mp3` fallback 涵蓋過渡期 series。
- **位置**: Lightsail Object Storage `s3://kg-podcasts-prod/{series_id}/{metadata.json, cover.png(選), ep_NN/{audio.m4a,subtitle.srt,script.md}}`(`cover.png` 為 series 層封面,`cover` stage 有產才有;舊 disk-mode 路徑 `data/podcasts/...` 仍由 backend 處理,當 `PODCAST_BUCKET` env 未設時)。
- **iOS 變更**: 零。`AVURLAssetHTTPHeaderFields` 帶 `Authorization: Bearer`,backend 走 proxy 模式(不 302 redirect 到 presigned URL,避免 AWS sig + Bearer header 衝突 → 403)。
- **Range 支援**: backend 把 `Range` header 原樣轉給 S3 `get_object(Range=...)`,S3 回 206 + `Content-Range`,backend 透傳。
- **過渡期回退**: `PODCAST_BUCKET` env unset → backend 改走 disk fallback,舊 series 仍可播。
- 詳見 `docs/sop/podcast_pipeline.md §Storage`。

## 架構債

- ~~**podcast 無頂層 section、被迫經 `BookshelfView` 進入**~~ **（軸 B Phase 3 已解）**：podcast 現為獨立頂層 section `PodcastHomeView`（`ContentView.AppPrimarySection.podcasts`，iOS TabView 第 2 + Catalyst sidebar），自有 `NavigationStack(path:)`；series→episode→player push 全在 podcast 自己的 stack，不再寄生 `BookshelfView` root，連帶刪除整套 overlay master pane workaround（`selectedSeriesRemoteId` / `PodcastSeriesActivation` / `PodcastDetailRouter.swift`）。series 啟動全平台統一 value-based push。
- **series 詳情仍是 `PodcastEpisodeListView` 全頁 push，非平台原生 `NavigationSplitView`。** 未來可評估以原生 split 呈現 series master-detail，但需先驗證 Catalyst 巢狀 split（`ContentView` 已用 `NavigationSplitView`）穩定性，本輪不做。

## 相關 doc

- `docs/reference/feature_boundary/reader.md` — reader 翻譯流程,podcast `VocabularyContext` 必須 mirror
- `docs/reference/sync_lifecycle.md` — 詞彙加入後的 sync 規則(**SoT**)
- `docs/sop/backend.md` — `/api/podcasts*` endpoint 與 progress LWW 後端細節
- `docs/sop/podcast_pipeline.md` — pipeline(synthesize → upload → S3)
- `docs/reference/product_surface.md` §Podcast player — 已實作功能清冊(避免重做)
