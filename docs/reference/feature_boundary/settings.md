<!-- doc-meta
tier: reference
authority: derived
update_trigger: code-change
scope:
  - ios/BooksAndVocab/Views/Settings/
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# Settings Feature Boundary

## 檔案清冊

### Container Layer（組裝 + 路由）

| 檔案 | 說明 |
|------|------|
| `SettingsView.swift` | 主容器 `struct SettingsView: View`：環境注入、coordinator 初始化、body 組裝、task、sheet、alert wiring；body 頂部掛 `RenderStormProbe.shared.tick` |
| `SettingsView+State.swift` | `presenterState` / `presenterActions` 組裝（融合 authManager / subscriptionManager / kgService / 各設定 store）；含 `bookSync` 投影與複習節奏摘要（progress freeze 狀態） |
| `SettingsView+Bindings.swift` | 翻譯語言雙向綁定 + DEBUG 手動登入 / 本地伺服器 URL 綁定 |

### Coordinator Layer（導航協調）

| 檔案 | 說明 |
|------|------|
| `SettingsCoordinator.swift` | `@Observable @MainActor final class SettingsCoordinator: SettingsCoordinating`。導航 / sheet 狀態（paywall、刪帳確認、翻譯語言）+ 非同步協調（loadData、resync、deleteAccount、後端切換、樂觀寫＋後端推送＋失敗回滾）+ connectionPulse / iconBreathing 動畫脈搏 + 觀測事件預覽緩衝 + 持有 `syncProgress: SyncProgressStore`（見下 §同步進度） |

### Presenter Layer（純 UI 呈現）

| 檔案 | 說明 |
|------|------|
| `SettingsPresenter.swift` | `struct SettingsPresenter: View`，主佈局；`otherSection` 委派 `SettingsOtherSection`、debug 區委派 `SettingsDebugBackendSection`。**Stack 約束**：section 一律 child View struct，不得寫成 computed property 內聯回 body（真機 Debug 1MB main stack overflow，2026-06-11 定讞；見 `SettingsOtherSection.swift` 檔頭）。持有「複習卡片」的 `navigationDestination`，目的地是 Vocabulary feature 的 `ReviewCardLayoutEditor`（同一個 View struct 也被複習畫面的 sheet 用，Settings 不自建一份） |
| `SettingsPresenter+Actions.swift` | 複合互動元件庫（最大檔案）：`SettingsNavigationRow` / `SettingsCardNavigationRow` / `SettingsActionRowLabel` / `SettingsFeaturePanel` / `SettingsPlanComparisonTable` / `SettingsSubscriptionFeatureList` / `SettingsSelectableRow` / `SettingsSelectionTile` / `SettingsCompactActionButton` |
| `SettingsPresenter+Components.swift` | 微元件庫：`SettingsSectionHeader` / SectionFooter / 分隔線 / MenuValue / TitleSubtitleStack / StatusBadge / StatusValue / StatusSummaryValue（純展示，零互動邏輯） |
| `SettingsPresenter+Controls.swift` | 控件樣式層：StepperIconButton、card / button chrome / text input 修飾符、LabeledInputField |
| `SettingsPresenter+Preview.swift` | preview 資料與場景（登出 / 訂閱啟用 / 載入中 / 刪除中 / 價格不可用 / DEBUG 後端） |

### Presentation Models（UI 資料轉換）

| 檔案 | 說明 |
|------|------|
| `SettingsPresentation.swift` | `struct SettingsPresenterState` + `enum SubscriptionBadgeTone` + `struct SettingsPresenterActions`；`AccountIdentityFingerprint` 將 reviewer email 正規化（trim + NFC + POSIX lowercase）後做單向 SHA-256，供 exact-account UI evidence 使用；`PreferencesSection.reviewModeDisplayName(for:)` 組裝首頁複習節奏顯示；`BookSyncState.from(phase:)` 投影 CloudKitMirroringMonitor.phase（localOnly→nil 隱藏；failed 帶錯誤描述） |
| `SubscriptionPresentation.swift` | `enum SubscriptionPresentation`：KGSubscriptionStatus → badge / tone / 摘要 / 詳情 / CTA / permissions UI 模型；`summary(podcastEnabled:)` 依 `KGFeatureFlags.podcastEnabled` 切換 active 摘要文案（Release 用不含 Podcast 的版本） |
| `SubscriptionPaywallFeatureCatalog.swift` | Free vs Pro 功能對照目錄（EPUB/PDF、AI 翻譯、同步、知識圖譜、複習、Podcast）；`descriptors(podcastEnabled:)` 於 gate off（Release，`KGFeatureFlags.podcastEnabled`）時移除 Podcast row（quota row 恆末位）；計算屬性支援語言即時切換 |
| `SettingsMetrics.swift` | `enum AppSettingsMetrics`，Settings 專用版面常數（帳號 / 複習區塊間距與大小） |

### Section Views（各設定區塊）

| 檔案 | 說明 |
|------|------|
| `SettingsAccountSection.swift` | `struct SettingsAccountSection: View` + `SettingsAuthSummary`，帳號卡片區塊（Google / Apple / 手動登入、Pro 標籤、驗證中遮蔽層）；summary row 的 accessibility identifier 只用 `settings.account.identity.<sha256>`（缺 identity 時為 `.unavailable`）。畫面仍可顯示可存取的 email；live evidence 不註冊完整 app tree，也不把 raw account 寫入 attachment/log |
| `SettingsSubscriptionSection.swift` | `struct SettingsSubscriptionSection: View`，訂閱方案詳情區塊（方案 / 徽章 / 來源 / 管理方式 / 恢復購買）；card 以 `settings.subscription.pro.active|inactive` 暴露實際 presenter entitlement，供 exact-device App Review probe 判讀 |
| `SettingsReviewSection.swift` | `struct SettingsReviewSection: View`，複習節奏詳情頁：progress pause/freeze toggle、複習模式、自訂 SRS 參數；樂觀寫＋後端推送＋失敗回滾 |
| `SettingsPreferencesSection.swift` | `struct SettingsPreferencesSection: View`，偏好設定區塊；含「自動連結」toggle（登入顯示，串後端 `auto_link` config group，控制 judge pipeline 自動建立連結）、UI「聲音回饋」「觸覺回饋」本機開關，以及 **「複習卡片」列**（`rectangle.split.2x1` → `ReviewCardLayoutEditor`，列尾摘要由 `ReviewCardLayoutSummary.titleKey(for:)` 給 預設／自訂）。**刻意與「複習節奏」分成兩列**：複習節奏那頁擁有 SRS 排程規則，卡片長什麼樣不屬於它 |
| `SettingsOtherSection.swift` | `struct SettingsOtherSection: View`，「其他」區塊：sync status 摘要 row + **iCloud 書庫同步狀態列**（綁 Apple ID 不掛登入 gate）+ quota row + external action row（吸收原 `SettingsPresenter+Quota.swift`）。同步中時 sync row 底下展開 `SettingsSyncProgressPanel`（見下 §同步進度）；panel 放在 Button **外面**——整段同步期間 Button 是 disabled 的，包進去等於把活的進度顯示塞進死的控制項 |
| `SettingsSyncProgressPanel.swift` | `struct SettingsSyncProgressPanel: View`（+ private `SettingsSyncProgressBar` / `SettingsSyncStepRow`）：同步中展開的總進度條 + 逐步清單。進度條形狀**刻意照抄同 section 的 `quotaRow`**（兩層 pill `AppRoundedRect`、高 3）——設定頁只該有一種進度條長相。狀態符號走共用 `SyncStepStatusIcon`（`UIComponents/`，與詞庫頁同步畫面同一組視覺語言，見 `docs/reference/ui/components.md`）。**三個 struct 各自獨立、不得內聯回 `SettingsOtherSection`**（同下方 stack 約束） |
| `SettingsDebugBackendSection.swift` | `struct SettingsDebugBackendSection: View`（DEBUG only），debug backend 切換區塊（前身 `SettingsPresenter+Debug.swift`，改 inline extension → 獨立 struct） |

### Sheet / Detail Views

| 檔案 | 說明 |
|------|------|
| `SubscriptionPaywallSheet.swift` | `struct SubscriptionPaywallSheet: View`，paywall sheet：已啟用（確認式）/ 未啟用（升級式）雙佈局、產品載入、恢復購買、StoreKit 整合 |
| `SettingsAccountDetailView.swift` | `struct SettingsAccountDetailView: View`，帳號詳情（CSV 匯出、刪除帳號入口） |
| `SettingsDeleteAccountSheet.swift` | `struct SettingsDeleteAccountSheet: View`，多步驟刪帳確認 sheet：三項勾選 + 輸入確認字串 + 5 秒倒數冷卻 |
| `TranslationLanguageSettingsView.swift` | `struct TranslationLanguageSettingsView: View`，翻譯語言設定（閱讀語言 → 翻譯語言）；樂觀寫＋後端推送＋失敗回滾 |

### Copy（純文案常數）

| 檔案 | 說明 |
|------|------|
| `SubscriptionPaywallCopy.swift` | paywall 文案解析（帳單金額 / 試用 / CTA / footer）；對齊 App Store 3.1.2(c) 合規敏感字串 |
| `SettingsDeleteAccountCopy.swift` | 刪帳工作流文案（後果列表 / 確認勾選 / 倒數 / 確認字串） |
| `SettingsAccountCopy.swift` | 帳號區塊文案常數（登入 / 驗證 / 訂閱狀態 / Pro 標籤） |
| `FeedbackSettingsCopy.swift` | UI 聲音／觸覺回饋設定列文案 |

### Feedback Dependencies

| 檔案 | 說明 |
|------|------|
| `ios/BooksAndVocab/Models/FeedbackSettings.swift` | `FeedbackSettingsStore`：裝置本機聲音／觸覺回饋偏好；不控制 TTS 或 Podcast |
| `ios/BooksAndVocab/Services/FeedbackAudioService.swift` | 短促非語音 UI 音效播放器；不取代 `SpeechService` 或 `PodcastAudioEngine`；每次 `play` 先 `AppAudioSession.prepare(for: .uiTone)` |
| `ios/BooksAndVocab/Services/AppAudioSession.swift` | 短音訊的 app-level `AVAudioSession` policy（#2110），播放前一律設明確 category，不依賴先前是否開過 podcast：TTS（`SpeechService.speak`）= `.playback` + `.default` + `[.duckOthers, .interruptSpokenAudioAndMixWithOthers]`（靜音開關下仍出聲、duck 音樂／暫停其他語音，最新一句講完或取消後 `setActive(false, .notifyOthersOnDeactivation)` 還原其他 app 音量）；UI 音效 = `.ambient`（遵守靜音開關、與其他 app 混音）。**podcast 擁有 session 時不動**：以顯式 owner（`claimPodcastSession`/`releasePodcastSession(owner:)`）判定——`PodcastAudioEngine.configureAudioSession` 先 claim、`shutdown()`（deactivate 之後）與 `deinit` release，新 engine 接手後舊 engine 的遲到 release 為 no-op；不再用 `nowPlayingInfo` 推斷（遲到的 seek 完成回呼會復活它）；`shutdown()` 後 `updateNowPlayingInfo()` 為 no-op，直到下一次 `configureNowPlaying`/`loadAudio`。避免 tap 音效把播放中／暫停待續的 podcast 降成 `.ambient`；講話中的音效亦不降級。單測 `BooksAndVocabTests/AppAudioSessionTests.swift`（fake `AudioSessionControlling` seam） |
| `ios/BooksAndVocab/UIComponents/FeedbackModifiers.swift` | `AppFeedbackEvent` 與 `appFeedback` modifier；集中 gate haptic 與 UI sound |

### Debug 工具

| 檔案 | 說明 |
|------|------|
| `RenderStormProbe.swift` | `#if DEBUG` body 重評估風暴偵測：計數每秒 body evals，>5/sec 記 STORM 警告；`SETTINGS_RENDER_DEBUG=1` 加開 `_printChanges()`；log category `RenderStorm` |

---

## 改動規則

- **新增設定項目** → 對應 Section View（`SettingsAccountSection` / `SettingsReviewSection` / `SettingsPreferencesSection`）
- **新增設定區塊** → 新增 `Settings*Section.swift`（child View struct，stack 約束）+ 在 `SettingsPresenter.swift` 加入
- **新增可復用 UI 元件** → 依性質三選一：純展示微元件 → `+Components`；複合互動元件（row / panel / table）→ `+Actions`；控件樣式 / 修飾符 → `+Controls`
- **section body 一律拆獨立 `View` struct，不要 inline 回 `SettingsPresenter.body`** → 真機 main thread stack 僅 1MB，Debug `-Onone` 下 inline section 會把 body 型別尺寸撐爆觸 `EXC_BAD_ACCESS`；`SettingsStackBudgetTests`（`MemoryLayout<Body>.size` 門檻 20KB/16KB）為 re-inline 回歸防線
- **新增 sheet** → 新增 `*Sheet.swift` + 在 `SettingsCoordinator` 加 navigation state + 在 `SettingsView` 加 `.sheet` modifier
- **新增 Presentation model** → `SettingsPresentation.swift` 擴充，或新增專屬 Presentation 檔案
- **新增訂閱相關 UI** → `SubscriptionPresentation.swift` + `SettingsSubscriptionSection.swift`；paywall 文案改 `SubscriptionPaywallCopy.swift`（注意 App Store 合規字串）、對照表內容改 `SubscriptionPaywallFeatureCatalog.swift`
- **新增 user-facing 文案常數** → 對應 `*Copy.swift`，不要内聯進 View

## State 邊界

- `SettingsCoordinator`：Settings 的導航與 side-effect state（optional integration sheet、subscription paywall、delete confirm、translation config、debug backend）；由 `SettingsView` 持有，不外洩
- `SettingsPresenterState`：Presenter 接收的 UI 狀態快照，純值類型，可跨 layer 傳遞
- `SettingsPresenterState.AuthSection.identityFingerprint`：只由 `authManager.userEmail` 派生；原始帳號不進 accessibility identifier 或 evidence attachment/log，UITest 以同一正規化規則的 SHA-256 驗證裝置登入者是否等於 ASC reviewer account（畫面可見 email 仍保有一般 accessibility）
- `SettingsPresenterState.PreferencesSection.reviewModeDisplayName(for:)`：偏好首頁「複習節奏」摘要的單一組裝入口；未凍結顯示模式名，凍結時顯示 `已凍結 · <模式>`
- **複習卡片版面 profile 不進 `SettingsPresenterState`**：`SettingsPreferencesSection` 直接讀 `@Environment(\.reviewCardLayoutStore)`（owner 為 Vocabulary feature 的 `ReviewCardLayoutStore`，見 `feature_boundary/vocabulary.md`）。理由是複習畫面會即時改它——把它快照進 presenter state 只會多一份會過期的副本。摘要文案唯一入口 `ReviewCardLayoutSummary.titleKey(for:)`，判定為兩模式四面全深比較
- `SettingsPresenterActions`：callback closure 集合，由 Container 注入，不持有 mutable state
- 帳號刪除確認與 paywall 開關目前由 `SettingsCoordinator` / `SettingsView` 一起驅動；不直接散落到 section view

### 同步進度（`SyncProgressStore`）

`SettingsCoordinator.syncProgress` 持有，`SettingsView` 以 `.environment(\.syncProgressStore, …)` 注入，`SettingsOtherSection` 以 `@Environment` 讀。型別本身（含 `SyncStepID` / `SyncProgressEvent` 與單調、加權等不變式）owner 是 `ios/BooksAndVocab/Services/SyncProgress.swift`，此處只記 Settings 側的邊界：

- **走 environment 而不是塞進 `SettingsPresenterState`**：一輪同步會寫這個 store 幾十次。放進 presenter state 會讓整個設定頁跟著重算；走 environment 才能只驅動 sync row 底下那個葉節點（`PodcastProgressTicker` 的同一個模式，見 `feature_boundary/podcast.md`）。
- **`isSyncing` 與 store 並存、不互相取代**：`isSyncing` 回答「在不在跑」（同時守著重入 guard 與按鈕 disabled），store 回答「跑到哪」。
- **步驟清單由服務宣告，UI 不猜**：`KGService.syncStepIDs()` + coordinator 自己收尾的 `.status` 一列。UI 必須先知道完整清單才畫得出「還沒輪到」的灰列與正確的進度條分母。
- **reporter 走 `AsyncStream` 而不是每事件一個 `Task { @MainActor in }`**：後者不保證順序，計數器會肉眼可見地彈回。store 內部的單調守衛是防線不是設計。
- **終態取自 `backgroundSync` 回傳的 `SyncRoundOutcome`，不讀 `lastBackgroundSyncError`**：`.didNotRun` 直接 `reset()` 收合、不宣稱任何事（理由見 `docs/reference/tech_index.md` 的 `BackgroundSyncing` 條目）。
- **顯式同步等待 shared lane**：Settings 使用 `backgroundSyncWhenAvailable`；普通 background trigger 忙碌時仍可 `.didNotRun`，但 Settings 不可把上一帳號的進行中 round 當成新帳號結果。
- **帳號邊界先取消再重置**：`resetForAccountBoundary()` 取消 active resync task、旋轉 generation/request owner、清除暫態 lifecycle/progress；舊 round 的晚到事件、save 與終態更新均 fail-closed。DEBUG fixture evidence 另以 session token 隔離。
- **`AppMotion`**：展開/收合共用一條 `phaseChange`（`lastSyncedText` 同時淡回來 = 一次過渡而非兩段接力），進場 transition 用 `statusRowReveal`——`docs/sop/ui-design.md` 把這兩個 token 指名給 Settings / Sync 且規定不混用。

## 現況判讀

- `SettingsView` 已從單檔主容器拆成 `View + State + Bindings` 三檔；主檔 143 行，保留組裝、task、sheet、alert 與 RenderStormProbe wiring
- 登出按鈕先過 `SettingsLogoutGate`（定義在 `SettingsAccountSection.swift`）：未同步卡或複習紀錄非零即 confirmationDialog，文案 `SettingsAccountCopy.unsyncedLogoutMessage(cards:reviews:)`；登出流程與 sync 不變式見 `sync_lifecycle.md` 的 logout-cleanup gate 段
- 原 645 行 `+Components` 已拆三檔：微元件留 `+Components`（192）、複合互動元件進 `+Actions`（438，現為最大檔案）、控件樣式進 `+Controls`（116）
- `SettingsCoordinator` 已從純導航狀態機（190 行）長成「狀態 + 非同步協調」混合職責（413 行）；再長大時優先考慮把樂觀寫＋回滾協調抽 service，而不是繼續堆 coordinator
- 後續若再新增設定區塊，優先擴充 `SettingsView+State.swift` 或對應 section view，而不是把狀態組裝塞回主檔

## 共用依賴

| Token | 用途 |
|-------|------|
| `AppTheme` | 色彩，`@Environment(\.appTheme)` |
| `AppMetrics` / `AppShellMetrics` | 間距、尺寸 |
| `AppMotion` | 動畫 token |
| `AppFonts` | 字型 |
| `SubscriptionPresentation` | 訂閱狀態 UI 模型，Settings 內部共用 |

## 未來路標

- `AppSkin.Spacing` 內 `sheet*`（`sheetSectionSpacing` / `sheetPadding` / `sheetPaddingCompact`）目前 3 欄位、Settings / Subscription / Podcast 三 feature 共用 → 留 AppSkin。**若 Settings sheet 演化出 ≥5 個 feature-local 欄位**，套同模式建 `SettingsSheetMetrics`（參考 boundary rectify 2026-05 的 `ReaderMetrics` / `TodayReviewMetrics` 範式）。
