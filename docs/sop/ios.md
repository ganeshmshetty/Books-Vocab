<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - ios/
  - ops/
verified_against: 8210e47aa53f8a2b03aafefadb7494098fa22cb1
-->
# Books & Vocab iOS 開發技能

## 核心資訊

- **專案路徑**: `ios/BooksAndVocab.xcodeproj`
- **Scheme**: `BooksAndVocab`
- **工作目錄**: repo root（`~/kg/`）
- **Destinations**: iOS 26+ / iPadOS 26+ / Mac Catalyst（macOS 26.0+，非原生 macOS）
- **平台抽象**: `Platform/PlatformRepresentable.swift`、`Platform/PlatformCompatibility.swift`

---

## 最高指導原則

**Exit Code `0` = 編譯成功；release 前仍需看第一屏 diagnostics summary 的 warnings。**

---

## Mac Catalyst 雷區（編譯過 ≠ 不崩）

Catalyst 是正式 target（Mac 走 Catalyst，非原生 macOS）。以下寫法**編譯通過但在 Catalyst runtime crash**，CI 由 `ops/catalyst_lint.sh` 擋：

- **`.popover` 掛在 `.toolbar` / `ToolbarItem` 的 Button 上** → present 過場走 UIKit `_pinInputViewsForKeyboardSceneDelegate`，scene 未就緒時 trap（`EXC_BREAKPOINT`，backtrace 全在 UIKitCore、無 app frame）。**改用 `.sheet`**（不同 presentation controller，亦免疫 popover resize 時的 willReposition recursion crash）。豁免：同行 `// catalyst-allow: <reason>`。
- 判讀法：`brk #1` + backtrace 唯一 app frame 是 `main` = framework trap，非 app force-unwrap；務必先取 lldb `bt`。

`ops/catalyst_lint.sh [--report|--strict]`，baseline 0 命中。

---

## iOS ops 統一入口（agent 優先）

新工作流優先走 `ops/ios_ops.sh`，底層 `ios_build.sh` / `ios_test.sh` / `ios_release.sh` 仍保留為 primitives。

```bash
./ops/ios_ops.sh status                 # project version/build + Organizer latest + TestFlight latest
./ops/ios_ops.sh doctor                 # release readiness: project/Organizer/TestFlight/signing/StoreKit/Sentry
./ops/ios_ops.sh doctor --json          # 同上，輸出 kg.ios.doctor.v1 結構化 JSON
./ops/ios_ops.sh build                  # 委派 ios_build.sh，結束即列 warnings/errors diagnostics
./ops/ios_ops.sh test --file FooTests.swift
./ops/ios_ops.sh archive                # archive + export，預設不上傳
./ops/ios_ops.sh archive --json         # machine-readable archive/export/upload report:kg.ios.archive.v1
./ops/ios_ops.sh archive --upload       # 明示才上傳 TestFlight
./ops/ios_ops.sh archives latest        # 本機 Organizer latest archive
./ops/ios_ops.sh issues --log <log>     # 解析既有 xcodebuild log
./ops/ios_ops.sh logs --since 5m        # runtime log 回溯快照（log show），過濾常見 Apple framework 噪音
./ops/ios_ops.sh logs --json --limit 200 # 同上，輸出 kg.ios.logs.v1 結構化 JSON
./ops/ios_ops.sh logs --follow          # 即時串流（log stream）；--limit N 為 stop-after-N gate
./ops/ios_ops.sh logs --follow --json   # 即時串流，逐行輸出 kg.ios.log-stream.v1（一行一物件）
./ops/ios_ops.sh sentry [--json]        # iOS Sentry wiring 摘要 / schema=kg.ios.sentry.v1
./ops/ios_ops.sh workflow release       # read-only 發版工作流：下一步命令 + todo/ready/block/warn/manual
./ops/ios_ops.sh workflow release --json # 同上，輸出 kg.ios.workflow.v1 結構化 JSON
./ops/ios_ops.sh gate release --json    # release hard-stop verdict:0 pass / 3 warn / 2 block
./ops/ios_ops.sh xcode --json           # Xcode/project/destination/simulator inventory:kg.ios.xcode.v1
./ops/ios_ops.sh simulator status --json # booted simulator + app data container/process:kg.ios.simulator.v1
./ops/ios_ops.sh simulator ensure-booted --json # 若 simulator 已 booted 就重用，否則 boot 預設裝置並等待 bootstatus
./ops/ios_ops.sh simulator launch --json # launch installed app, then re-check process state
./ops/ios_ops.sh simulator terminate --json # stop installed app, then re-check process state
./ops/ios_ops.sh simulator screenshot --out build/sim/current.png --json # 本機截圖 artifact，不上傳
./ops/ios_ops.sh runs --json            # 最近 build/test verdict + log/xcresult artifact path + diagnostics
./ops/ios_ops.sh snapshot --json        # 一次拉 project/Organizer/TestFlight/readiness/workflow/gate/xcode/simulator/runs
./ops/ios_ops.sh snapshot --json --skip-xcode # 快速模式:不拉 Xcode destination/simulator inventory
./ops/ios_ops.sh snapshot --json --skip-simulator # 快速模式:不拉 booted simulator/app process
./ops/ios_ops.sh snapshot --json --include-logs --log-limit 50 # 同上,再內嵌 runtime logs
./ops/ios_ops.sh review-probe --simulator --flips 30 # review-flip 自主量測 rig（passthrough review_flip_probe.sh；--device <udid> / --release / --instruments；exit 0 pass / 1 fail / 2 invalid / 64 usage）
./ops/ios_ops.sh quality impact --files ios/BooksAndVocab/Views/Foo.swift --json # UI 品質控制面：查改動該跑哪些 static/structure/snapshot/behavior/perf/visual gate
./ops/ios_ops.sh commands --json        # 自描述 CLI catalog:side-effect / schema / delegate
```

輸出契約:第一屏固定優先看 `[ios][issues]` / `[ios][summary]` / `[ios][next]` 類摘要;需要原始資料時再開 log path。

原則:優先組合 Xcode 官方 CLI,不重造輪子。`ios_build.sh`/`ios_ops.sh build` 與 `ios_release.sh` archive 會產生 `-resultBundlePath <*.xcresult>`,再用 `xcrun xcresulttool get build-results` 抽 warnings/errors;`ios_test.sh` 會用 `xcrun xcresulttool get test-results summary/tests` 抽 executed/failures。raw xcodebuild log parser 只作 fallback。

build/test/archive 共用 `/tmp/kg-ios-build.lock`；test 的 simulator execution 另有 per-device lock。共享 lock 先以原子單調 ticket queue 排定 FIFO 順序，只有 queue head 能嘗試取得 `shlock`，所以後到 waiter 不會繞過已排隊 predecessor。timeout 或 INT/TERM/HUP 會移除自己的 ticket；後續 waiter 只會清理 PID 已死亡的 abandoned ticket。三個 caller 的 cleanup 都做 owner guard（lock 內容仍等於自己的 PID 才刪），不可手動刪 live lock 或繞過 `ios_ops.sh`。所有 lock 排隊除記錄 `lockWaitMs` 外，會以 15 秒 cadence 輸出 `phase=lock-wait` heartbeat（留在最長 20 秒可見進度上限內），包含等待者 PID/alive 與 holder PID/alive。只看到 `waiting for ... lock` 後超過 20 秒沒有 heartbeat 是工具缺陷，不可把它解讀成正常排隊。

`ios_ops.sh doctor` 是 release readiness 儀表板:read-only 彙總 project `MARKETING_VERSION(CURRENT_PROJECT_VERSION)`、Organizer latest archive、TestFlight latest build、ASC version state、manual signing export options、StoreKit scheme/file、Sentry release wiring。ASC version-state 查詢有短 deadline，逾時只會 `status=warn`，不阻塞本機 readiness。`status=block` 代表發版前必修（例如 build number 未增加），`status=warn` 代表資訊缺失或 local artifact 落後。agent/CI 要少調用工具時用 `--json`，schema 為 `kg.ios.doctor.v1`，核心陣列是 `readiness[]`，且頂層直接內嵌同一份 `sentry: kg.ios.sentry.v1`，讓 readiness 與 wiring 摘要共用單一路徑。現在另外有 `summary.verdict` 與 `summary.counts.ok|warn|block|total`，文字模式也會固定印 `[ios][doctor] summary ...`，不必每次自己掃完整列 readiness item 才知道整體狀態。

`ios_ops.sh status --json` 是更輕量的 quick summary：只回 `kg.ios.status.v1`，含 project version/build、Organizer latest archive 與 TestFlight latest build，不做 readiness/gate 判斷。適合 agent 第一輪只想知道「現在 local/Organizer/TestFlight 各是多少」時使用。

`ios_ops.sh workflow release` 是 read-only 發版操作編排:輸出 `[ios][workflow] step=N key=... status=todo|ready|block|warn|manual command="..." note="..."`。它不跑測試/編譯/archive/upload；除了 project settings、Organizer、TestFlight、ASC state，也會自動讀 `ops/app_review/` 最新 semver spec 並執行本地 App Review gate。這五個潛在慢來源都使用共用 visible runner，輸出與 timeout 契約以 `docs/reference/tech_index.md` 的 `ops/lib/streaming_command.py` 段落為 SoT。只有 gate PASS 時 submit step 才標 `manual`；gate BLOCK、spec 缺失或 gate 無法執行時，submit step 必為 `block`，唯一 next command 是 `./ops/app_review_evidence.py status --spec <latest>`。`--json` schema 另含 `appReviewGate`、`summary.verdict` 與 `summary.counts.ready|todo|block|warn|manual|total`。

`ios_ops.sh gate release --json` 是 release hard-stop verdict:schema 為 `kg.ios.gate.v1`,重用 `doctor --json` + `workflow release --json`。exit code 固定為 `0=pass`、`3=warn`、`2=block`;`todo`/`manual` 會列入 `todos[]`/`manual[]` 供 agent 排下一步。`block` 來自 readiness 或 workflow，其中包含 App Review evidence gate，所以缺 producer、缺/漂移/過期證據不能再以 GUI manual step 繞過。

`./ops/app_review_evidence.py plan|status --spec ops/app_review/<version>.json` 是送審證據控制面：`plan` 列 artifact、typed producer、authority 與 next command，`status` 執行完整 gate 並回報 block reason。最終 ASC desired bundle 是 release owner 提供的人工輸入；本工具不生成或改寫截圖 bundle，也沒有 Catalog appearance producer。其餘 `urls|journey|journey-run|demo-run|attest` 依 checked spec 產生封閉證據；`journey-run` / `demo-run` 的 dirty tree verdict 仍 fail closed。

證據控制面的長 child command 不得成為黑盒：desired shape/build/bundle、journey、physical demo 與 gate evaluation 都會把 `start` / `spawned` / 每 20 秒 `heartbeat` 寫到 stderr；child 正常 exit 時另寫 `done` + rc，stdout 仍只輸出最終 JSON。中斷會向上拋出並清除整個 child process group。若 stderr 超過 20 秒無進度，視為 runner 缺陷，不得靜默等候或把它解讀為健康。**心跳本身不是健康證明**：`heartbeat` 另帶 `stalled` 等前進判準（欄位語意正本為 `docs/reference/tech_index.md` 的 `ops/lib/streaming_command.py` 段落），`stalled=true` 連續累積代表 child 活著但**沒有輸出**（不等於沒在做事——等鎖、慢下載、還沒啟動完成都會安靜），該查而不是該等。

**呼叫端不得把長指令接進 tail / head / grep 這類會整段緩衝的過濾器**：實測 `./ops/ios_ops.sh test … 2>&1 | tail -20` 啟動背景任務後，output file 在整段執行期間維持 0 bytes，事後又只剩最後 N 行，會同時遮蔽 heartbeat 與前段進度。要截斷時先讓指令裸跑，或以 `> <log> 2>&1` 保留完整輸出，結束後再讀 log；否則會把正常執行誤判為卡死或 runner 缺陷（`IMP-20260805-f71e9b`）。

ASC live state 必須由 `./ops/asc_reviewer_mirror.py audit ... --commit --bundle-dir <dir>` 取得：它只做 ASC GET 與 CDN image GET，原子寫本地 hash-closed bundle；review detail secrets 僅留 `present`、keyed-HMAC fingerprint 與 ASC ref，demo account name 另留正規化 identity SHA-256，不輸出帳號或密碼原文。`demo-run --live-mirror-bundle <dir>` 從這份 mirror 取得預期 account identity，固定走 physical `iphoneos` Release、無 fixture 的 `LiveDemoAccessUITests`；`ios_test.sh` 先對每個 xctestrun configuration/target 清除並掃描保留的 fixture/live keys，再只把 marker 與 identity SHA 注入唯一 `BlueprintName=BooksAndVocabUITests` target（找不到或多於一個都 fail-closed），禁止 live env 擴散到其他 test target。UITest 必須同時看見 `settings.account.identity.<same-sha>` 與 live backend Pro，receipt 再綁同一 SHA；這證明當下裝置帳號／entitlement，不宣稱已重新走 fresh SSO，後者由 root-bound human attestation 承擔。human 與 agent attestation 皆須綁 pre-attestation evidence root，且未過期才可過 gate。

以上 ASC mirror 與 evidence producer 都不 submit、不撤回、不修改 ASC metadata、不上傳截圖。gate 對缺 spec、producer set 漂移、malformed/缺失/過期 evidence、identity 不一致與離線 observation 一律 fail-closed；完整 PASS 後仍只有 operator 能在 ASC GUI 執行不可逆 submit。

`ios_ops.sh xcode --json` 是 Xcode Project Navigator / destination selector / Devices 視角的 read-only inventory:schema 為 `kg.ios.xcode.v1`,組合 `xcodebuild -version`、`xcode-select -p`、`xcodebuild -list -json`、`xcodebuild -showdestinations` 與 `xcrun simctl list devices --json`。輸出包含 Xcode 版本、DeveloperDir、project configurations/schemes/targets、destinations `available[]`/`ineligible[]`、simulator runtimes/devices 與 booted/available summary。各來源都有 `sources.*.status/exitCode/error`,頂層 `errors[]` 保留 CLI failure 診斷;來源失敗時仍輸出可解析 JSON。文字 alias `environment` 供人掃第一屏;agent 要選 `--destination` 或確認 booted simulator 時讀 JSON。

`ios_ops.sh simulator status --json` / `sim status --json` 是 Simulator GUI 狀態的窄面:schema 為 `kg.ios.simulator.v1`,組合 `xcrun simctl list devices --json`、`xcrun simctl get_app_container booted com.Max0228.BooksBrowser data` 與 host-side `ps -axo pid,command` probe（以 device UDID + `BooksAndVocab.app/BooksAndVocab` 鎖定 simulator app process），回傳 booted device、app data container、app process `running|stopped|skipped|unknown` 與 errors[]。app 沒在跑是觀測狀態(`process.status=stopped`,probe exit 1),不讓整體 status 失敗;沒有 booted simulator 才回穩定 JSON + exit 1。每個 simulator action 現在都會帶 `timings`：`status` 含 `simctlDevicesMs/appContainerMs/appProcessMs/totalMs`，`ensure-booted` 含 `resolveMs/bootMs/bootstatusMs/totalMs`，`launch|terminate` 含 `statusMs/lifecycleMs/appProcessMs/totalMs`，`screenshot` 含 `statusMs/screenshotMs/totalMs`；文字模式也會印對應 `[ios][simulator] timings ...`。`ios_ops.sh simulator launch --json` / `terminate --json` 對齊 Xcode Run/Stop toolbar 的窄面:底層只呼叫官方 `xcrun simctl launch|terminate`,然後重新讀 BooksAndVocab process,回傳 `app.lifecycle` 與 `app.process`。它不 build、不 install、不 boot、不改 ASC;launch 需要 app 已安裝。`ios_ops.sh simulator screenshot --out <png> --json` 只做本機 artifact side effect,底層是 `xcrun simctl io <device> screenshot <png>`。

`ios_ops.sh runs --json` 是 Xcode Report Navigator + Issue Navigator 的輕量對應面:schema 為 `kg.ios.runs.v1`,讀最近 `ios_build.sh` / `ios_test.sh` / `ios_release.sh` 寫出的 verdict file,回傳 build/test/archive result、caller、elapsed、executed tests、log path、xcresult path、artifact 是否仍存在,並在每個 run 內嵌 `diagnostics`:`kg.ios.diagnostics.v1`。若 test run 啟用 `--coverage`，同一份 run 也會保留 `coverage: kg.ios.coverage.v1`，含 target line coverage、門檻 verdict 與最低覆蓋檔案清單。頂層另外有 `summary.verdict` 與 `summary.counts.errors|warnings|failedTests|missing|malformed|failing`，文字模式第一行固定印 `[ios][runs] summary ...`，讓 agent/human 不必逐個 run 自己聚合。diagnostics 優先讀官方 `.xcresult`,不可讀時用 raw log fallback;缺 artifact 時給穩定 `source:"missing-artifacts"` 空摘要,不讓 `runs`/`snapshot` 中斷。新 verdict 優先讀 `.json`（避免含空白 path 被 legacy `KEY=value` 格式截斷）,舊單行 verdict 只作相容 fallback；含空白 path 的準確 artifact 判定以 JSON verdict 為準。archive run 另外保留 `timings.lockWaitMs/archiveMs/exportMs/uploadMs/totalMs`，可直接判斷發版成本花在哪一段。它不重跑 build/test/archive。**verdict 檔案佈局（多 session 競態防護，2026-06-11）**：每次 run 寫**唯一路徑** `${TMPDIR}/kg_ios_<kind>_verdict.<epochTs>-<pid>(.json)`（stdout 的 `verdict=` 印的就是本次唯一路徑）；固定路徑 `kg_ios_<kind>_verdict(.json)` 只是 last-writer-wins 的 **latest pointer**（`runs`/`snapshot` 讀它=「這台機器最近一次 run」，並發時可能是別 session 的）。要驗證「自己這次 run」一律讀 stdout 印的唯一路徑，或用 `KG_IOS_VERDICT_FILE=<path>` pin 住再讀同一路徑——`ios_ops.sh build|test|archive --json` 內部已自動 pin，payload 不受並發 session 覆蓋影響。verdict 內容自帶辨識欄位：單行格式尾端 `ts=<epoch> pid=<pid> cwd=<worktree>`、JSON 有 `invocation{ts,pid,cwd,verdictFile}`，stale / 外來 verdict 一眼可辨。

`ios_ops.sh logs --json` 是 Xcode Console 的輕量對應面:schema 為 `kg.ios.logs.v1`,資料源是 Apple Unified Logging 官方 CLI `/usr/bin/log show --style ndjson`（回溯快照）。輸出包含 `summary.rawCount` / `filteredCount` / `emittedCount` / `byEventType` 與 `entries[]`（timestamp、eventType、processID、subsystem、category、message、sender）；常見 RunningBoard/WebKit assertion 噪音會先過濾。`--limit` 只限制輸出的 entries 數量,不重跑 app。

`ios_ops.sh logs --follow` 是同一面的即時串流變體,改走 `/usr/bin/log stream`（compact 文字;`--json` 改 `log stream --style ndjson`,逐行輸出 `kg.ios.log-stream.v1`,一行一 JSON 物件便於串流消費）。沿用同一份 noise 過濾;`--limit N` 在 follow 模式是 stop-after-N gate（預設無界）,`--since` 不適用。串流長駐,適合 `simulator launch` 後即時盯 log;主線請用鐵律 5 的背景執行(`run_in_background`),由 notification 取增量。底層 producer 被 `head` 關閉(達 limit)收 SIGPIPE 視為正常終止,真實 `log stream` 失敗才傳遞非零 exit。

`ops/ios_log_assert.py` 是 log 之上的 **assertion/summary 面**（test/ops 端純消費,不碰 app logging）。吃 `ios_ops.sh logs --json` 的 `kg.ios.logs.v1` envelope、bare JSON array、或 raw `log stream|show --style ndjson`（auto-detect,壞行靜默跳過）,吐 `kg.ios.log-assert.v1`:`byCategory`/`byEventType`/`byLevel`/`errorRate`（Error+Fault 比例;envelope 因 jq 投影丟掉 `messageType` 故回 `null`,要 error-rate 請餵 raw ndjson）/`metrics`/`frames`/`features`。用法 `ios_ops.sh logs --json | ./ops/ios_log_assert.py [--json]`;`--max-error-rate`/`--min-events`/`--require-feature`/`--require-metric` 任一未過 exit 1,可當 smoke gate。`metrics` 依 **Performance Baseline Naming Contract**（`ops/ios_perf_naming.py`,SoT）從 message 抽 `feature.scenario.action.metric` token（恰 4 段 lowerCamel;例 `podcast.player.play.readyLatency`、`reader.open.load.firstPaint`、`notebook.list.scroll.frames`）並依第 4 段 word 分桶 `frame`/`latency`/`count`。**新增 perf 量測時先 `./ops/ios_perf_naming.py validate <name>` 過 grammar,別自己發明 bucket**;app 端尚未發 metric line（命名僅測試端定義,不改 app）。

`ios_ops.sh snapshot --json` 是 agent 第一輪狀態入口:schema 為 `kg.ios.snapshot.v1`,合併 project、Organizer latest、TestFlight latest、`readiness[]`、release `workflow.steps[]`、release `gate` verdict、Xcode `xcode` inventory、Simulator `simulator` 狀態與最近 `runs`。頂層 `summary` 是第一屏判讀層:`summary.verdict=pass|warn|block`,`summary.counts` 不只聚合 gate/build/test/archive/xcode/simulator/runtime counts,也直接提升 `doctor.summary.counts` 與 `workflow.summary.counts` 成 `readinessOk|readinessWarns|readinessBlocks|workflowReady|workflowTodos|workflowWarns|workflowBlocks|workflowManual`,讓 agent 不必再下鑽 `.readiness[]` / `.workflow.steps[]` 才知道 release 管理面狀態。`summary.nextActions[]` 會把 gate hard-stop/todo/manual、build/test/archive diagnostics、xcode/simulator observation errors 轉成可直接執行或檢查的 action。非 JSON 文字模式也共用同一份 snapshot JSON formatter,第一行固定是 `[ios][summary]`,後續先列 `[ios][next]`,不再輸出舊式 `phase=doctor` dump。`runs.build.diagnostics` / `runs.test.diagnostics` / `runs.archive.diagnostics` 仍保留完整 `kg.ios.diagnostics.v1`,讓第一輪 payload 就有可行動問題,不用再二次跑 `issues` 或 grep log。預設不查 unified log,所以 `logs` 欄位為 `null`;需要 Xcode Console 視角時加 `--include-logs --log-since 5m --log-limit 200`,snapshot 會內嵌同一份 `kg.ios.logs.v1`。預設會查 `kg.ios.xcode.v1` 讓 agent 第一輪就有 scheme/destination/simulator inventory 視角;需要快速 dashboard 時加 `--skip-xcode`,此時 `xcode:null`。預設也會查 `kg.ios.simulator.v1` 讓 agent 第一輪知道 booted device、app container 與 BooksAndVocab process `running|stopped|skipped|unknown`;需要跳過 Simulator GUI 狀態時加 `--skip-simulator`,此時 `simulator:null`。沒有 booted simulator 時 snapshot 仍回 0 並把 `.simulator.status` 設為 `error`,避免 dashboard 因觀測缺口中斷;log provider 失敗則仍傳遞非零 exit。snapshot 只做觀測並回傳 gate 物件,不因 gate warn/block 自己失敗;需要 hard-stop exit code 時跑 `ios_ops.sh gate release --json`。它仍是 read-only，只組合既有 `doctor --json`、`workflow release --json`、gate helper、`xcode --json`、`simulator status --json`、`runs --json` 與可選 `logs --json`;人要看文字 dashboard 可用 `ios_ops.sh snapshot` 或 alias `dashboard`。

`ios_ops.sh quality list|impact|validate` 是 iOS façade 上的 UI 品質控制面 discovery 入口，read-only 委派 `ops/ui_quality_plane.py`。改 UI 檔時先用 `./ops/ios_ops.sh quality impact --files <paths...> --json` 取得 static-code / structure / behavior / perf 候選 gate，再依語意決定跑哪個 gate。Catalog 是按需視覺工作台，不是品質 plane 的強制 coverage gate。

改複習卡版面或 `ReviewCardLayoutProfile` 時，必須同步更新 `ios/BooksAndVocabTests/Golden/review_card_layout.json`，並讓 `ReviewCardLayoutGoldenTests` 與 `review-card-golden` 回歸組在同一個變更中通過。

`ios_ops.sh commands --json` 是 agent capability catalog:schema 為 `kg.ios.commands.v1`,列每個 subcommand 的 `key`、`aliases`、`sideEffect`、固定 `delegate` 欄位（無委派為 `null`）、用途與輸出 JSON schema。`jsonSchemas[]` 不只列 top-level schema，也必須包含 payload 內穩定內嵌的 child schema（例如 `build/test/archive/runs` 內的 `kg.ios.diagnostics.v1`、`test --coverage` 內的 `kg.ios.coverage.v1`、`doctor` 內的 `kg.ios.sentry.v1`、`snapshot` 內的 `kg.ios.workflow.v1` / `kg.ios.runs.v1` / `kg.ios.sentry.v1`）。新 agent 不確定能不能寫入或該讀哪個 schema 時先查這個,不要解析 help 文字。

## iOS 編譯 3 步驟 SOP

### Step 1：靜默編譯，直擊錯誤

```bash
./ops/ios_ops.sh build                 # 預設 iPhone Simulator
./ops/ios_ops.sh build --catalyst      # Mac Catalyst（platform=macOS,variant=Mac Catalyst）
./ops/ios_ops.sh build --destination '<xcodebuild destination>'  # 自訂 destination
./ops/ios_ops.sh build --catalyst --dry-run   # 只印實際要餵給 xcodebuild 的 argv，不編譯
```

- Exit Code `0` → 編譯成功;仍看 `[ios][issues] warnings=...`，release 前不可無視新增 warnings
- Exit Code 非 `0` → 第一屏 diagnostics 會列官方 `.xcresult` top errors/warnings + raw log path，進 Step 2
- 預設 `build` 使用 `xcodebuild build-for-testing`：除 app target 外，也會編譯 `BooksAndVocab` scheme 宣告的 test targets；它只驗編譯、不執行測試。故意植入無法編譯的測試檔時，這道 gate 必須非零；行為驗證仍走 `test`。
- 動到三平台 navigation / Catalyst 專屬路徑時，`--catalyst` 與預設各跑一次驗證（`--timeout` 預設 600s）
- `--dry-run` 印的 argv 與真實 build 消費的是**同一個陣列**（`ios_build.sh:xcodebuild_argv`），所以 plan 不可能與 run 分岔。它不寫 verdict，因此**與 `--json` 互斥**（否則會把上一次的 run 當成這次的結果回報）。

#### `--catalyst` 一律不簽章編譯（IMP-0039）

`--catalyst` 隱含 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`。它是 compile gate——「模擬器綠 ≠ Catalyst 綠」——而 macOS 沒有 `Mac Development` 憑證就拒絕簽章，只出 Apple Distribution 的機器永遠沒有那張。要求它等於讓 `ios-build-catalyst` block gate 結構上不可能綠。

- 要覆寫必須**兩個一起帶**：`--extra-settings CODE_SIGNING_ALLOWED=YES --extra-settings CODE_SIGNING_REQUIRED=YES`（後到者勝）。只帶前者會留下 `CODE_SIGNING_REQUIRED=NO`，變成「嘗試簽章但簽不動也不失敗」——一道不可能紅的 gate，比原本更糟。
- **已知覆蓋缺口（刻意接受）**：`ops/ios_release.sh` 的 archive 是 `-destination 'generic/platform=iOS'`，**本 repo 從不簽 Mac Catalyst 產物**。因此 Catalyst 的簽章 / entitlement-vs-profile 相容性（`app-sandbox`、`icloud-container-identifiers`、`applesignin`、`aps-environment`、`DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER` 的 bundle-id↔container 映射）目前**無處驗證**。接受理由：不以 Catalyst 出貨，且模擬器 `ios-build` gate 仍跑 `ProcessProductPackaging`，entitlements plist 本身壞掉照樣紅。要改成出貨 Catalyst，這個缺口必須先補。
- `ops/ios_test.sh` 對 Mac Catalyst / macOS destination 直接 `exit 2`，並在 stderr 說明它是 iOS-only、其產物解析不支援 Catalyst bundle layout；Catalyst 目前只到 compile，入口是 `ops/ios_build.sh --catalyst`。
- live-only UITest compile gate 的 `generic/platform=iOS` 同樣是 compile-only：`ops/ios_test.sh` 只對這個精確 destination 加 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`；具名實機 destination 保留正常簽章。兩者的 signing mode 進入 test cache key，unsigned generic 產物不可被 exact-device 路徑重用。

### Step 2：還原案發現場

**不要只看單行錯誤就動手改。** 根據錯誤的**檔名 + 行號**，讀取該行**上下至少 20 行**原始碼，結合 Swift/SwiftUI 語法特性完整分析脈絡。

常見需要讀上下文的場景：
- `@ViewBuilder` 限制（return type、條件分支問題）
- Optional unwrap 導致的型別不符
- `@State` / `@Binding` / `@ObservableObject` 使用錯誤
- `async/await` 上下文缺失

### Step 3：對症下藥並驗證

修復後立刻重跑 Step 1。反覆「編譯 → 讀上下文 → 修改」直到 Exit Code 歸零。

## CloudKit 環境與本機資料隔離

本 app 的 CloudKit 環境設定以 `ios/BooksAndVocab/BooksAndVocab.entitlements` 為準；目前 entitlement 明確固定為 `Production`，所以不可只憑「Xcode Debug」推定它連到 Development。變更 entitlement 或簽章設定前，先核對 build 的 resolved entitlement。曾發生環境切換造成書列 purge/reimport，再被 reconciler 的去重 export 放大成刪除；不要在正式使用中的 iPhone 上測試環境切換。需要隔離驗證時使用 disposable simulator 或獨立測試裝置，並避免刪除正式 app 資料來排除同步問題。

新增 CloudKit-backed `@Model` 後，Development schema 成功不代表 Production 已就緒；發布前須確認 schema 已部署到 app 實際使用的 Production CloudKit container。遇到 mirroring 失敗時，保留原始 `CKErrorDomain` 與 nested partial errors，逐層定位子錯誤，不要只依外層錯誤碼重置本機資料。

## iOS 測試入口（`ops/ios_ops.sh test` / `ops/ios_test.sh`）

`ops/ios_test.sh` 與 `ios_build.sh` 共用 `/tmp/kg-ios-build.lock`。**鎖是細粒度的**：只在 `build-for-testing`（共享 DerivedData 的唯一寫者）期間持有，`test-without-building` 執行階段**不持鎖**。test 產物為 content-keyed 且寫入完成後加 `.kg-test-cache-complete` sentinel（hit 偵測與 double-check 都要求 sentinel，擋住中斷留下的 half-written cache），故並行 agent 可各自在獨立模擬器上同時跑測試而不互相排隊。build 走 `<主repo>/.cache/ios-build-derived-data`（`git-common-dir` 錨定，所有 worktree 同一路徑，禁止改用 Xcode 全域預設位置否則洩漏路徑雜湊孤兒）；test 走 `.cache/ios-test-derived-data`（platform/arch keyed，pool 各 sim 共享暖快取）。政策與根因詳見 [`docs/reference/ios_deriveddata_policy.md`](../reference/ios_deriveddata_policy.md)。

### 磁碟預算與 writer gate

所有 iOS build/test intermediate cache 與 release archive/export 只可寫入已知的 `.cache/` 或 `ios/build/` roots；這些受管理 writer cache 合計以 **16 GiB** 為固定預算，寫入前另保留 **6 GiB headroom**，並要求檔案系統至少有 **20 GiB free**。Xcode 全域 `BooksAndVocab-*` DerivedData 不混入這個 aggregate，另由 `KG_DISK_GUARD_DERIVED_DATA_BUDGET_GIB` 預設 **4 GiB** 的固定 byte cap 管理。`ops/kg_disk_guard.sh` 每 5 分鐘以同一份 atomic receipt 記錄兩個預算、overflow 與清理動作；healthy free space 也會對 global DD 超額啟動 oldest-first repair，只有 process probe clear、沒有 active consumer 且成功持有既有 build lock 才可刪除可重建目錄。active／未知 process、FIFO ticket 或 lock contention 只會 `deferred-*`，不刪產物；guard 的 dry-run 與既有 exit semantics 不變。

`ops/ios_build.sh` 與 `ops/ios_release.sh` 在取得 writer lock 後執行同一個 `kg_ios_disk_budget_preflight`。若 free space、快取大小或設定無法可靠讀取，或預算／headroom 不足，command 以 **exit 75** fail-closed，並輸出 `kg.ios.disk-budget.v1` 的原因；這不是產品測試失敗，也不是繼續寫入的許可。**guard 判決在租 simulator 與取 build lock 之前就讀**（`ios_test.sh`／`ios_ops.sh build` 入口）：被擋時數秒內回報，不佔 lease／鎖佇列，且 `ios_ops.sh build|test --json` 仍輸出 `result:"inconclusive"` 的 verdict（真實 `exit` 75／77 加 `reason`：`disk-guard-structural-block`／`disk-guard-blocked`；鎖內被擋同樣寫 verdict），不會讀成 `missing`；`ios_test.sh --prepare-cache` 鎖內被擋時 wrapper 的 exit 同 preflight 的 75／77（其他 build 失敗仍是 1）；鎖內的 preflight 只量真實磁碟空間；提早讀 guard 時若需 inline refresh，tick 以 `BUILD_LOCK_HELD=0` 執行（自己搶鎖或 `deferred-build-lock`，不會在沒持鎖時刪 cache），只有鎖內 preflight 才傳 1。取捨：early verdict 之後排隊久了不會每次重讀，但超過 guard state 最大年齡（`KG_IOS_DISK_GUARD_MAX_AGE_SECONDS`，預設 900 秒）就在鎖內重讀（鎖內重讀同樣可能是 77：`ios_build.sh`／`ios_test.sh`／`ios_release.sh` 一律把 preflight 自己的 rc 當 exit code 傳出，只有 75 才印「clean rebuildable cache」提示，77 印 `retryable=no`；`ios_release.sh` 沒有 early verdict，它的 guard 讀取一律在鎖內）；呼叫端自行預設 `KG_IOS_DISK_GUARD_ALREADY_CHECKED=1` 不會繞過（需 `kg_ios_disk_guard_mark_checked` 同時寫入的時間戳）。**exit code 契約**：**75 = 暫時**（空間／預算不足、state stale，清 cache 或等待後可重試）；**77 = 結構性、retryable=no**（lane 報告的 `blocking_reasons` 含 dirty／unknown／duplicate／`physical-identity-mismatch`／`registry-records-invalid` 這類 worktree 問題，或 XCTestDevices／simulator runtime 需人工審查（unregistered worktree 不在此列：它只以 `unregistered-physical-worktree:<path>` 警告並附 remedy，超出 lane 配額時才以 `lane-budget-exceeded:<path>` 擋下，為 75；issue #2905）；判準看 lane 報告的 `blocking_reasons`，不是 guard reason 本身——`lane-usage-report-blocked` 也會因 lane 配額超額（`lane-budget-exceeded:*`／`lane-total-budget-exceeded`）、量測不完整、報告 timeout／crash（`lane_usage_rc` 非 0／75；掃描被 supervisor kill 記為 124），或報告比寫出該 guard state 的 tick 舊超過 120 秒（stale，輸出 `laneUsageFresh=no`、名單印 `unknown`、不得當結構性證據）而出現，這些下個 tick 或 `guard --refresh` 後會解除，仍是 75；等待或清 cache 都不會解除，輸出含 `retryable=no` 與 guard 自己的 `guardReason`／`guardAction`）——**看到 77 不要輪詢**：處理 `unregisteredWorktrees=` 等列出的 worktree 後跑 `./ops/ios_ops.sh guard --refresh`，否則依 BLOCKED 回報。若原因是 `disk-guard-blocked`，輸出的 `blockingReasons=`／`unregisteredWorktrees=` 指出被擋的 worktree（不是磁碟空間問題），可用 `./ops/ios_ops.sh guard --refresh` 立即重新評估（Claude subagent 的 `agent-*` worktree 不計入阻擋，見 `ios_deriveddata_policy.md`）。先讓 guard 清理安全的 rebuildable cache，或由維運者透過既有 `ios_clean_derived_data.sh` dry-run／apply 流程收斂後再重試。這個預算只約束 KG 管理的 iOS writer cache，不是對整台 APFS 或使用者資料的刪除授權。

`ios_test.sh` 的 keyed cache eviction 也套用同一 aggregate budget，但仍保留 current key 與 reader safety window；因此並行測試不會因另一個 run 的清理而讀到被刪的產物。不要在工作樹內自行呼叫不帶 `-derivedDataPath` 的 `xcodebuild`，也不要把大型 log、xcresult、截圖或 video 放進 source tree；非 retain 的 run artifact 必須留在帶 TTL 的暫存 bundle。

**並行測試（多 agent）**：`./ops/ios_ops.sh simulator lease`/`release` 提供有界的 per-agent 模擬器 pool（`kg-pool-1..N`，env `KG_IOS_SIM_POOL_SIZE` 預設 3）。最簡用法：`./ops/ios_test.sh --unit --lease` 自動租一台 pool 模擬器、結束釋放；或手動 `--device <udid|name>` / `--destination '<xcodebuild destination>'` 指定。`--file` 的 `.swift` 後綴可省（裸型別名亦可，多檔同名會報錯列候選）。`-g` 同時匹配測試**方法名**與 **suite/容器名**（@Suite struct / class）——`-g FooTests` 直接跑整個 suite，不匹配檔名；重複 `-g` 累積成 OR。test runner 的 unit scope 走 dedicated `BooksAndVocabUnitTests` scheme，UI scope 走 dedicated `BooksAndVocabUITests` scheme，先走 `simulator ensure-booted`，再採 cache-first `build-for-testing` / `test-without-building` 重用 `.cache/ios-test-derived-data`；`./ops/ios_ops.sh test --cache-status|--prepare-cache|--clean-cache [--unit|--ui|--all-targets] [--json]` 可顯式管理這層 warm cache。**同一台 simulator 的 `test-without-building` 現在額外受 per-device execution lock 保護**：沒租不同裝置時，平行 run 會序列化在同一台機器上，不再互相污染；要拿到真正重疊，仍要用 `--lease` 或手動指定不同 `--device`。另外，在 `/.codex/worktrees/`、`WORKTREE_BRANCH` 或 `CI` 這類 agent/並行情境，`ios_test.sh` 會直接拒絕共享預設 simulator，要求顯式 `--lease` / `--device` / `--destination`；只有單機除錯才可設 `KG_IOS_TEST_ALLOW_SHARED_SIM=1` 明示 opt-out。verdict JSON 會寫 `timings.lockWaitMs/deviceRunLockWaitMs/bootMs/buildForTestingMs/testInvocationMs/testBodyMs/xcresultSessionMs/xcresultHarnessOverheadMs/appLaunchAverageMs/appLaunchSamples/invocationOverheadMs/xcodebuildMs/totalMs` 與 `cache.status`（`lockWaitMs` = 等 `/tmp/kg-ios-build.lock` 排隊時間；`deviceRunLockWaitMs` = 等同一台 simulator 執行鎖的時間，先分出「同機排隊」再談真正執行慢）。stdout 第一屏也會印這兩個 wait time；若 xcresult 含 `XCTApplicationLaunchMetric` 另會印 `[ios][perf] metric=AppLaunch averageMs=...`。長 UI 測試會每 30 秒輸出 heartbeat（elapsed / xcodebuild pid / log path / 最近 test event），這只是可觀測性，不是「無輸出就殺掉」的失敗判準；實際 liveness 由 XCTest per-test allowance 與外層 job／命令 timeout 負責。不要讓 6 分鐘以上的 launch permutations 變黑盒。由 `ios_ui_run_many.py` 驅動的報告批次會把每個 run 的 log、xcresult、step screenshot、review page、video 與 temporary producer data 限制在唯一的 run-scoped staging root；預設 root 在系統暫存目錄並帶 TTL，成功、失敗與中止都可回收。只有明示 `--retain` 才會把精簡後的報告 bundle 提升到 `build/ios-report/retained/`；沒有 retain 的 run 不得作為報告矩陣的永久證據。失敗／中止 run 依 manifest 的 TTL 走 `ios_ui_run_many.py cleanup`，先 preview，再確認 PID、xcodebuild／runner、lock 都不存在後 `--commit`。

**第一性原理流程**：測試系統已具備 scope、heartbeat、log preserve、false-green 防護與 DB lock retry；因此 iOS 開發不再採「不主動跑測試」的保守規則，而是採**最小足夠驗證**。

```bash
./ops/ios_ops.sh build --json                              # machine-readable kg.ios.run.v1
./ops/ios_ops.sh test --timeout 1200                       # 預設只跑 BooksAndVocabTests unit target
./ops/ios_ops.sh test --json                               # machine-readable kg.ios.run.v1
./ops/ios_ops.sh test --coverage --coverage-fail-under 80 --json # 產出 kg.ios.coverage.v1 並可設 line coverage gate
./ops/ios_ops.sh test --file NotebookCoverContrastTests.swift
./ops/ios_ops.sh test -g "sanitizeOutbox"                  # 匹配方法名
./ops/ios_ops.sh test -g "NotebookSyncTests"               # 匹配 suite/容器名 → 跑整個 suite
./ops/ios_ops.sh test --ui --file BooksAndVocabUITests.swift # 只跑 UI test 檔案
./ops/ios_ops.sh test --ui testLaunchShowsAllTabs       # 只跑 UI test method
./ops/ios_ops.sh test --launch-benchmark
./ops/ios_ops.sh test --ui --ui-launch-profile standard testLaunchShowsAllTabs
./ops/ios_ops.sh test --ui --dataset marketing_demo -g FixtureDatasetUITests # 注入 named UI World（ops/fixtures/ui_worlds/<name>.json）
./ops/ios_ops.sh test --all-targets --dataset marketing_demo --timeout 1200          # scheme 全量：unit + UI
./ops/ios_ops.sh test --file FooTests.swift --list          # 只列 resolved -only-testing selectors
```

- `--all-targets` 與 `--ui` 同守：必須帶 `--dataset`／`--dataset-file`（無 dataset 會被拒，否則 UI 測試對空世界大量失敗；dataset env 注入 xctestrun 全部 target）。`--timeout` 只限制 lock 等待，**不**限制 xcodebuild 執行時間；單測上限由 XCTest allowance 與外層命令 timeout 負責。`test --clean-cache` 會在 build lock 內連同 `.cache/ios-build-derived-data` 一併清除（它計入 disk budget，不清會讓 build 後的 test 撞 exit 75）。
- 預設 scope 是 `unit`，會自動加 `-only-testing:BooksAndVocabTests`；UI tests 不會被誤混進 unit full。
- `./ops/ios_ops.sh build --json` / 一般 `test --json` 會把 delegate stdout/stderr 導到 stderr，stdout 保留單一 `kg.ios.run.v1` payload；`test --coverage --json` 會在同一 payload 內嵌 `coverage: kg.ios.coverage.v1`；已存在原生 JSON 契約的 `test --cache-status|--prepare-cache|--clean-cache --json` 維持原 schema，不再包一層 run report。
- **裸方法名（positional）會反查自己的容器**：`test --ui testLaunchShowsAllTabs` 這種不含 `/` 的參數，runner 會掃該 scope 的 test 目錄，把方法歸到它**自己所屬**的 `class` / `@Suite` 容器（Swift Testing id 會帶簽名如 `foo()`），不再硬拼成「與 target 同名的 class」。找不到就在 **parse 期 exit 1**（訊息會指向 `Class/method` 規則），不會白跑一整輪 build+test 才在尾端撞 false-green guard。**「找不到」會分辨兩種成因**：名字真的不存在 → 印通用規則；名字其實住在**另一個 target**（少給 `--ui` / `--unit`，最常見的形狀就是拿 UI test 名字跑預設 unit scope）→ 錯誤會**指名它所屬的 target/容器**並印出可直接複製的修正命令。兩種都仍 exit 1，runner **不會**自作主張改跑另一個 scope。掃描**不遞迴**：測試若放在子目錄就找不到，改用 `Class/method` 形式——那是永遠直通、不做存在性檢查的逃生口（例：`test --ui ExploreNavigationUITests/testExploreTabIsReachableAndRendersSection`）。
- `--ui` 會把 discovery target 切到 `BooksAndVocabUITests`，支援 `--file` / method selector；未明示時會自動帶 `--ui-launch-profile ui-smoke`，把 UI smoke 驗證切到較輕的 app launch profile。若要回到完整 startup 行為做 baseline / A/B，明示 `--ui-launch-profile standard`。
- `--ui` 實際執行必須明示 `--dataset <name>` / `--dataset-file <path>`。named dataset 解析到 `ops/fixtures/ui_worlds/<name>.json`；UI World（`kg.fixture.dataset.v2`）結構化描述資料、auth、Keychain token state、entitlements、preferences、SwiftData rows 與 file-backed assets。runner 以 deflate-base64 注入 app；完整 schema、跨引用與資產完整性由 `ops/ui_world_manifest.py validate` 和 app decoder fail-fast 驗證。
- **改 UI 測試的 bookshelf fixture id 前先跑 `./ops/ui_fixture_lint.sh`（秒級，不編譯）**。它把「傳了 enum 的 *case 名稱* 而非 rawValue」從一場模擬器 crash 降成一行 `file:line`：`BookshelfFixtureID` 的 rawValue 是 snake_case（`with_books_library`），傳 camelCase 的 `withBooksLibrary` 會讓 `BookshelfFixtureID(rawValue:)` 回 nil、app 在 init 就 `preconditionFailure`，測試以「crashed in \<external symbol\>」形式紅掉。這個錯誤形狀在 repo 裡活了兩個月沒人發現，因為**沒有任何日常 gate 會跑 UI target**（本地 gate 會在改動 UITest 時路由 UI 測試，整套 UI suite 又因已知 flakiness 被刻意排除在 block gate 外）。lint 已註冊進 `ops/ui_quality_plane.yml`（`static.ui_fixture_id`，fast tier），`--list` 印出當前 allowlist，行內豁免走 `// ui-fixture-allow: <reason>`（在 UITests 目錄裡引用壞形狀寫回歸註解時用它，別去改 lint）。另一半是排程 sweep `ops/launchd/com.kg.uisweep.plist`（每日跑完整 UI target，**advisory、跑在 oscar**，felix 沒有 Xcode），細節見 `docs/reference/tech_index.md`。
- `--dataset` / `--dataset-file` 不只 app 端 decode 會驗：host-side `ios_test.sh` 與 `catalog list|open` 都先跑 `ops/ui_world_manifest.py validate`；`ui_quality_gate.py` 與 `uitest_flow_matrix.py` 也共用該 preflight。invalid world 不會進 simulator 或 dry-run plan。
- `--launch-benchmark` 是正式的 UI launch perf 入口，固定跑 `BooksAndVocabUITests/testLaunchPerformance`；目前以 XCTest 內建 `XCTApplicationLaunchMetric` 預設行為為準，會在第一屏輸出 `appLaunchAverageMs` / `appLaunchSamples` 供比較。
- `--coverage` 會對 `build-for-testing` / `test-without-building` 加 `-enableCodeCoverage YES`，測試後用 `ops/ios_coverage.py` 讀 `xccov view --report --json` 產出 `kg.ios.coverage.v1`。`summary.lowestFiles[]` 預設列出 selected target 最低覆蓋的前 10 個檔案，第一屏會印前三個 `[ios][coverage][low]`，用來決定下一輪補測試焦點。`--coverage-fail-under <percent>` 低於 BooksAndVocab target line coverage 門檻時，即使 tests passed 也會讓 run 以 `reason=coverage-fail-under` 失敗；coverage build cache key 會和一般 test 分開，避免重用無 coverage 的 `.xctestrun`。只調 parser 輸出時可直接跑 `ops/ios_coverage.py --max-low-files <n>`。
- `--all-targets` 跑整個 scheme TestAction，不能和 `--file` / `-g` / specific method 混用。
- 測試結束第一屏會列 `[ios][issues] source=xcresult-test-results` 與 `[ios][tests] tests=... passed=... failed=...`；false-green 執行數優先取官方 `.xcresult`，raw log 只作 fallback。
- 失敗或 inconclusive 時保留完整 xcodebuild log 與 `.xcresult`，stdout 會印出 log / xcresult path；成功時 verdict 也記錄 log / xcresult path。
- UI scope（`--ui` / `--all-targets`）預設只驗證行為與狀態；`test --ui --visual` 或專用 `run_ui_evidence.sh`／`ios_ui_run_many.py` 視覺 run 才會產生 full `contact_sheet.png`、`quick4_contact_sheet.png`、`review_manifest.json`、`UIreview.html` 與 video。這些檔案全部位於系統暫存的單一 run bundle 並帶 TTL；只有明示 `--retain` 才提升到 `build/ios-report/retained/`。`test --json` 的 `kg.ios.run.v1` 仍回 `uiVisualReview{...}`（行為 run 為 `null`）與頂層 `device`；需要視覺觀察時，應在 bundle 過期前讀取該 run 的 review page／quick sheet，完成後立即清理，永久只保留必要 receipt。
- 若 Xcode 回 `build.db database is locked` / `unable to attach DB`，runner 會在同一把 repo lock 內短暫等待並重試，避免把 infrastructure lock 誤判成測試失敗。
- 若要把 build-for-testing 成本拆出日常迭代回路，先跑 `./ops/ios_ops.sh test --prepare-cache --unit` 或 `--ui`，後續 scoped `test` 會優先重用 `.xctestrun`；`--cache-status --json` 會回 `kg.ios.test-cache.v1`，含 `productsReady` / `xctestrunPath` / `timings.bootMs/buildForTestingMs`。
- 若要讓 agent/human 在第一屏就看懂時間分布與 release readiness，不要只翻 raw log：`./ops/ios_ops.sh runs --json` 會保留每次 build/test/archive 的 `options` / `cache` / `timings`；`./ops/ios_ops.sh snapshot --json` 會再把它們收斂成 `summary.timings.build|test|archive|simulator`，並把 `doctor/workflow` 聚合成 `summary.counts.readiness*` / `workflow*`；文字模式固定在 `[ios][summary]` 後緊接 `[ios][timing] build ...` / `[ios][timing] test ...` / `[ios][timing] archive ...` / `[ios][timing] simulator ...`。

### 何謂「正常」：退出碼 / cacheStatus / 秒數基準（agent 判讀用）

數字為 2026-06-09 dogfood 實測（Apple Silicon、iOS 26.4 sim、`--file` 跑單一綠燈套件除非註明），供 agent 判斷一個 run 是否正常、卡在哪。**先看 `lockWaitMs` 排除排隊，再看執行段。**

**退出碼（exit code）— 三者語意不同，別一律當「失敗」：**

| exit | 意義 | verdict result |
|---|---|---|
| `0` | 測試全綠 | `ok` |
| `1` | 測試有紅 / false-green（編譯成功但 0 test 執行）| `fail` |
| `65` | **建置/編譯失敗**（xcodebuild 原生碼，與「測試紅」可區分）| `inconclusive` |
| `128+N`（`143`=SIGTERM、`129`=SIGHUP、`130`=SIGINT）| **被訊號中止**：cleanup 已跑一次（鎖與租借模擬器已釋放），中斷點之後的步驟未執行 | 無 verdict（run 未完成）|
| 其他非零 | inconclusive（infra 異常等）| `inconclusive` |

看到 `65` = 程式碼編不過，去看 `[ios][error] category=compiler` 那行真錯誤，**不是** runner 壞。

**訊號中止不再以 0 偽綠收場（2026-08-06 起）。** 在此之前 `ios_test.sh` 用 `trap cleanup EXIT INT TERM` 綁訊號卻不 re-raise：實測被 SIGTERM 打中後，它跑完 cleanup、**從中斷點繼續往下執行**、印出完整正常輸出、最後 `exit 0`，且 cleanup 又在 EXIT 再跑一次。危險的是後半段——cleanup 已釋放 `/tmp/kg-ios-build.lock` 與租借模擬器，實測留下 **19.35 秒「鎖已釋放但行程仍在寫共享 DerivedData」** 的視窗；`ops/lib/streaming_command.py` 對逾時 child 送 SIGTERM 後要等 5 秒才升級 SIGKILL，正好落在這個視窗裡。現由 `ops/lib/signal_traps.sh` 保證 cleanup 恰好一次並以 128+N 死亡（同一探針量到 0 個 lockless 取樣、訊號後 0.71 秒死亡）。看到 `143` 就是**有人／有東西砍了這個 run**，不是測試結果，別當紅也別當綠——重跑。回歸：`ops/tests/test_ios_signal_traps.sh`。

**`cache.status` — 自我描述，不用再交叉比對 `buildForTestingMs`：**

| status | 意義 |
|---|---|
| `miss` | 此 key 無暖快取，本次會建置 |
| `prepared` | **本 run 親自做了 build-for-testing**（`buildForTestingMs` 大）|
| `hit` | 重用暖快取（含「等鎖後 double-check 命中、跳過重建」的並行等待者，`buildForTestingMs=0`）|
| `rebuild-after-failure` | 命中後出現 cache / infrastructure failure（例如 `.xctestrun` 失效）才回頭重建一次再跑；**真 `TEST FAILED` 不會被洗成綠燈** |

**秒數基準（ms；超出範圍才需懷疑）：**

| 階段 | 正常範圍 | 備註 |
|---|---|---|
| `bootMs`（暖 sim）| 300–600 | cold boot 才會數秒；`ensure-booted` 已吃掉這層 |
| `buildForTestingMs`（冷建）| 80,000–100,000 | 單次 build-for-testing；warm hit 時為 `0` |
| `testInvocationMs`（單套件）| 10,000–15,000 | 多數是 harness 開銷，非斷言本身 |
| `testInvocationMs`（full unit 1121 tests）| ~38,000 | full 套件總 `totalMs` ~100s |
| `testBodyMs` | 10–40 | 真正跑斷言的時間極小，**不要**拿它當整體效能 |
| `xcresultSessionMs` / `xcresultHarnessOverheadMs` | 8,000–25,000 | xcresult 解析/harness 固定開銷，warm hit 的 wall time 多半卡這裡 |
| warm `hit` run `totalMs` | 11,000–35,000 | 編譯為 0，但仍有 boot+harness+xcresult 開銷,**10–35s 是正常的** |
| 編譯失敗 `totalMs` | 50,000–90,000 | 失敗在 build 階段,exit 65 |

**並行（多 agent）正常樣態：**
- 每個 `--lease` run 各租**不同** `kg-pool-*` 模擬器；lease slot 現在綁定呼叫者 pid 與 owner token，**live run 不會因 TTL 被另一個 agent reclaim**；cleanup 也只會釋放自己的 lease，不會誤刪別人的 slot。N 個同時冷啟時，**恰一個** `cache=prepared`（建置者，`lockWaitMs`≈0），其餘 `cache=hit` 且 **`lockWaitMs ≈ 建置者的 buildForTestingMs`（~80s）— 這是等鎖,正常,不是卡死**。建置者放鎖後等待者靠 sentinel + double-check 跳過重建直接跑測試。
- 暖快取下 N 並行：全 `hit`、`lockWaitMs=0`、`totalMs` 差距小（真重疊）。
- 若沒租不同 simulator，暖快取下同一台預設機器的平行 run 會在 `deviceRunLockWaitMs` 上排隊；這是防污染的刻意序列化，不是 cache regression。
- agent/worktree/CI 若還想直接打共享預設 simulator，runner 會 fail-fast；這不是功能缺失，而是刻意把「隱性排隊 + 共享 state」變成顯性契約違反。真的只是在單機除錯，才用 `KG_IOS_TEST_ALLOW_SHARED_SIM=1`。
- 每個 run 原子 append 一行到 `<主repo>/.cache/ios-run-metrics.jsonl`（含全部 `timings` + `result` + `cache` + `caller`）。設 `WORKTREE_BRANCH=<標籤>` 可讓該行 `caller` 自帶標籤,便於並行歸戶。並發寫入無交錯損壞。

### iOS 測試效能經驗固化

- `simulator ensure-booted` 很重要，但它只吃掉 cold boot 那層；若 warm path 仍慢，下一個嫌疑通常是 `test-without-building` 的 host/session，而不是 simulator 本身。
- 要判斷「是不是 simulator lifecycle 在吞時間」，先看 `kg.ios.simulator.v1.timings`：`bootMs/bootstatusMs` 高代表 cold boot，`statusMs` 高代表你在 launch/terminate/screenshot 前就花在狀態探測，`lifecycleMs` 高才是 `simctl launch|terminate` 本體慢。
- 不要再依賴 simulator 內 `pgrep` 類工具做 app process probe：iOS 26.4 runtime 上 `pgrep` 會卡 `sysmond service not found`，而且 `simctl spawn` 對 bare command name 的 PATH 行為也不穩。現行做法改成 host-side `ps` + device UDID + app executable path，穩定性更高。
- `build-for-testing` 要顯式拆出日常回路；不先做 cache reuse，就會把每次 scoped test 的固定成本看錯成 render 成本。
- `XCTApplicationLaunchMetric` 的 `appLaunchAverageMs` 是單次 app launch 平均，不是整個 UI benchmark wall time；判讀時要同時看 `testBodyMs`、`xcresultSessionMs`、`invocationOverheadMs`。
- 任何「好像有變快」都不算結論，除非 timing 已回寫到 verdict JSON / `runs` / `snapshot`；沒有進控制面的數字，下一輪 agent 就無法延續判讀。
- 若某個優化旗標沒有在 xcresult sample count 或 timing 上留下可驗證差異，就不要把它留成表面功能。
- **先分「排隊」再分「執行」**:build/test/archive verdict 都有 `timings.lockWaitMs`(共享 `/tmp/kg-ios-build.lock` 的排隊等待,三者同義)。一個 run 看起來慢,先看 `lockWaitMs` 是不是卡在別的 worktree 後面,再看 `xcodebuildMs`/`testInvocationMs` 等執行段;沒有 lock-wait 數字時,排隊延遲會偽裝成執行慢。
- **uniform image 改走 warning 語意**:`uniform-image-detected` 現在只會讓 `validation.status:"warn"` 與頂層 `status:"warn"`，不再把已成功產出的 PNG 誤判成 fatal `error`。真正 fatal 的仍是 `png-count-mismatch`、degenerate dimensions、xcodebuild/test/copy 失敗。

### GitHub-hosted CI 的量測邊界（2026-08-19）

本機表格是 Apple Silicon 的 warm-loop 基準；GitHub-hosted macOS job 是全新 VM，不能把兩者混為同一個 SLA。PR #1025 的 cold hosted baseline 顯示 compile 為主因：build 約 `131s` boot + `642s` xcodebuild；full unit 約 `519s` build-for-testing + `209s` test invocation；UI smoke 約 `280s` build-for-testing + `124s` test invocation。這些是分段實測，不是 `required` merge gate 的耗時。

Hosted workflow 以 committed `Package.resolved` 建立 SwiftPM source cache；每個 job 都還原，只有成功的 `main` push 可回寫。cache hit 前不可宣稱加速，應用 Actions 的 `cache-hit` 與同一組分段 timing 驗證。`ios-quality` 的 `workflow_dispatch` 可選 `macos-26` 或 `macos-26-intel` 做一次性 benchmark；PR 預設不變，且兩種 runner 都保留 Xcode／runtime／simulator preflight。iOS jobs 屬完整 `confidence`，其 `25` 分鐘 timeout 是防掛死的 hard stop，不是 `required` 的全域串行門檻。`ios-quality` 的 concurrency 只讓 `pull_request` run 取消被取代的舊 run（`cancel-in-progress: ${{ github.event_name == 'pull_request' }}`）；`main` push 與 manual dispatch 共用同一 group 但不互相取消，GitHub 保留一個執行中加一個 pending（較新的 pending 取代較舊的），所以連續 merge 時最新的 `main` commit 一定會跑完，這是唯一的 post-merge iOS 健康訊號；`ops/tests/test_github_workflows.sh` 釘住此規則，且任何有 `push` trigger 的 workflow 都不得無條件 `cancel-in-progress: true`。

### 日常 warm-loop 建議

- 日常局部迭代先做兩件事：`./ops/ios_ops.sh simulator ensure-booted --json`、`./ops/ios_ops.sh test --prepare-cache --unit` 或 `--ui`。這會把 cold boot 與 `build-for-testing` 從主回路拆出去。
- 接著才跑 scoped test：`./ops/ios_ops.sh test --file FooTests.swift`、`./ops/ios_ops.sh test --ui testLaunchShowsAllTabs`。看 `cache.status` 是否為 `hit`，以及 `timings.testInvocationMs` / `xcresultSessionMs` 是否仍然偏高。
- 若要看整條回路花在哪，不要自己猜：先跑 `./ops/ios_ops.sh snapshot --json --skip-xcode`，讀 `summary.timings.build|test|simulator`；若只想看測試暖機層，跑 `./ops/ios_ops.sh test --cache-status --json` 與 `./ops/ios_ops.sh runs --json`。
- 只有在 scoped 回路已 warm、仍有異常延遲時，才去懷疑 UI host / XCUI harness / app launch profile。不要在 cold path 上討論 render 成本。

### iOS 開發驗證梯度

| 變更 / 狀態 | 必跑 |
|---|---|
| 純註解 / doc-only | 不跑 iOS test;跑 docs gate 即可 |
| iOS 編譯面或簡單型別修正 | `./ops/ios_ops.sh build` |
| iOS model/service/presenter/test 邏輯 | `./ops/ios_ops.sh test --file <相關Tests.swift>` 或 `-g <pattern>` + `./ops/ios_ops.sh build` |
| UI / navigation / accessibility / app launch | 相關 unit test + `./ops/ios_ops.sh test --ui ...` + `./ops/ios_ops.sh build` |
| test runner / scheme / SwiftData model / sync lifecycle / 跨 feature 共用面 | `./ops/ios_ops.sh test --all-targets --dataset marketing_demo --timeout 1200` + `./ops/ios_ops.sh build` |
| 多個 test 失敗或原因不清 | `./ops/ios_test_matrix.sh --timeout 300 [--start-at File.swift]`,逐檔定位後再修 |
| release / cleanup all / 宣稱 iOS 全綠 | `./ops/ios_ops.sh test --all-targets --dataset marketing_demo --timeout 1200` + `./ops/ios_ops.sh build` |

原則:
- 不用 `--all-targets` 當第一反應;先跑最小可證明範圍,避免把多個根因混在一起。
- 不用 build 代替 test;build 只證明可編譯,不證明行為。
- 看到 tool failure / inconclusive / false green 先修 runner 或 invocation,不要將就。
- 長 UI permutations 正常會跑數分鐘;依 heartbeat 判斷進度,不要因短期無 test case output 就殺掉。

### 在模擬器上實跑 app 看畫面（人工／agent 自檢視覺）

自動化測試證明不了的東西（材質、glass、動畫手感）只能實跑。這條路有四個會讓你**看到舊畫面卻毫無警訊**的坑。

**1. `.app` 不在 Xcode 的 DerivedData。** `ios_build.sh` 用 `-derivedDataPath $PROJECT_ROOT/.cache/ios-build-derived-data`（worktree 下走 git-common-dir 的同名路徑），build log 自己會印 `derivedDataRoot=`。`~/Library/Developer/Xcode/DerivedData/` 是 Xcode GUI 建的，可能停在數天前。

```bash
find .cache/ios-build-derived-data -name BooksAndVocab.app -path "*Debug-iphonesimulator*"
```

**2. 視覺驗收前先過安裝入口。** `ios_build.sh` 會在 app 旁寫入 worktree path + HEAD 的 provenance sidecar；`ios_install.sh` 在安裝前核對 sidecar 與當前工作樹，對不上就非零退出。不要手打 Xcode 的安裝命令，也不要把警告當判準。

裝完仍可用 `BooksAndVocab.debug.dylib` 的 mtime 做輔助觀察：Xcode 16+ 的 debug-dylib 機制下 app code 在這顆 dylib，主執行檔 `BooksAndVocab` 只是 launcher，比對它會誤判。mtime 不能取代 provenance gate。

**3. 換 build 用安裝入口覆蓋，不要 `uninstall`。** 例如：`./ops/ios_install.sh --simulator <udid> --app <path-to-BooksAndVocab.app>`。入口通過 provenance 後才會覆蓋安裝；`uninstall` 會連 data container 一起刪（書庫／登入／語言／閱讀進度），而這些用 fixture 重建的成本遠高於省下的那一步。

**4. 偏好設定的真相來源是 iCloud KVS，不是 app 的 plist。** `AppLanguageStore` 等偏好讀 `cloud.string(forKey:) ?? defaults.string(forKey:)`（`ios/BooksAndVocab/Services/CloudPreferencesSync.swift` = `NSUbiquitousKeyValueStore`），所以直接改 `<container>/Library/Preferences/<bundleid>.plist` **不會生效**，且該值不在 `<device>/data` 底下（grep 不到）。要改就走 app 自己的 Settings UI（同時寫 defaults + KVS）。懷疑某條 preference path 沒被讀時，設一個明顯不同的第三值重啟做差別測試，比逐一猜 key 快。

**從外部手動觸發 UI fixture**（不經 `ios_test.sh`）要自己注入 UI World：`simulator launch` 不帶 env，得改用 simctl 並以 `SIMCTL_CHILD_` 前綴傳遞。

```bash
source ops/lib/fixture_dataset_env.sh
export SIMCTL_CHILD_KG_FIXTURE_DATASET_DEFLATE_B64="$(kg_fixture_dataset_deflate_b64 ops/fixtures/ui_worlds/marketing_demo.json)"
xcrun simctl launch --terminate-running-process <udid> com.Max0228.BooksBrowser \
  -ui-testing -seedFixture:bookshelf:with_books_library
```

**fixture 失敗是 `preconditionFailure`（SIGTRAP），而訊息不在 `.ips`**（crash report 的 `asi` 是空的，只有 backtrace 符號）。要撈訊息：

```bash
xcrun simctl spawn <udid> log show --last 5m --style compact --predicate 'process == "BooksAndVocab"'
```

**併發**：`kg-pool-*` 是 `ios_ops.sh simulator lease` 的 test 專用 pool，可能正被別的 session 佔用（同時期會看到 `BooksAndVocabUITests-Runner` 的 crash log）。自己看畫面請挑 pool 以外的獨立裝置。

## 真機 / 本機 crash 自動取證（lldb stop-hook）

**問題**：Xcode debugger 攔截 crash 時 iOS 不落 `.ips`，backtrace 只存在於 Xcode UI —— agent 的觀測介面淪為使用者截圖 + 人肉轉貼。**管線**：`ops/lldb_crash_forensics.py` 以 lldb stop-hook 在任何 exception / 致命 signal stop **自動**寫全量取證檔到 `/tmp/kg_lldb_forensics/`（`KG_LLDB_DUMP_DIR` 可覆寫），agent 直接讀檔。

- **安裝（一次）**：`ops/install_lldb_forensics.sh`（idempotent 寫 `~/.lldbinit`；`--uninstall` 移除）。之後所有 lldb session —— 含 Xcode debug session —— 自動生效（dummy-target stop-hook 繼承已驗證）。
- **既有 paused session**（事發當下沒裝）：lldb console 跑 `command script import <repo>/ops/lldb_crash_forensics.py` 再 `kgdump`。
- **dump 內容**：stop reason、stack region（bounds/size/headroom）、**全量 frame 表含 fp 差分 frame size**（stack overflow 直接點名誰吃 stack）、frame 0 registers、其他 thread top frames。`LATEST.txt` 恆指最新。
- **判讀備忘**：`___chkstk_darwin` + `EXC_BAD_ACCESS code=2` + 位址貼近 region base = stack overflow；真機 main thread stack **1MB**、sim（macOS process）**8MB** —— sim 永遠測不出真機 stack overflow。breakpoint stop 不會觸發 dump；任意 stop 點可 `kgdump` 手動取證。
- **測試**：`ops/tests/test_lldb_crash_forensics.sh`（自動 dump / 全量 frame / fp 差分 / breakpoint 不誤觸 / kgdump）+ `ops/tests/test_lldb_forensics_timeout.sh`（有界性守衛）。
- **手跑 lldb 取證時務必帶 `-k quit`**：`lldb --batch` 遇 crash 會回到互動 prompt 不退（dump 其實早就寫好了），非互動情境下會直接掛住。測試裡四顆 lldb 都帶它，另有 180s 預算兜底。

**debugger 不在場**（直跑 app / TestFlight / 使用者日用）時 crash 落 `.ips` 在裝置上，lldb 管線抓不到 —— 走 `ops/ios_device_logs.sh`（pymobiledevice3 經 uvx，免安裝）：

- `crashes`（列裝置 `.ips`）→ `pull-crashes --parse`（拉本 app 的 .ips + remote `crash parse-latest` 直接吐可讀 stack；Debug build 的 `.debug.dylib` frame 自帶函式名）。
- 平台事實：iOS 會把**已讀過的 .ips retire 進 `/Retired/`**，而 pymobiledevice3 的 ls/pull/parse-latest enumerate 都不遞迴 —— 工具已固化 `crashes` 帶 depth 2、`pull-crashes` 雙掃 top-level + `/Retired`、`--parse` 自動 fallback，別繞工具裸呼叫然後誤判「沒有 crash」。
- `syslog [--proc] [--duration]`：真機 live log 串流，**含 debug 級與 stdout**（unified log 不持久化 debug 級，事後撈必空 —— 這是唯一即時通道）。
- `collect`：拉 `.logarchive`，事後 `log show --archive` 撈真機 default+ 級。
- 陷阱：`ios_ops.sh logs` 非 sim 路徑跑的是 Mac 本機 `/usr/bin/log show`（Catalyst 用），**讀不到 iPhone**；真機 log 一律走本工具。
- sim 對應面：sim crash 的 `.ips` 直接落 Mac `~/Library/Logs/DiagnosticReports/`（無需工具）；sim 容器檔案用 `ios_device_files.sh --simulator`。
- **測試**：`ops/tests/test_ios_device_logs.sh`（`test_ops.sh ios-device-logs`）。

## 發版 / TestFlight（`ops/ios_release.sh`）

App Store / TestFlight 出 `.ipa`。用 App Store Connect API key 的簽章基建，**無需手動匯入 Apple Distribution 憑證**（cert/profile 已一次性建置，含重建步驟見 `~/.secrets/apple/README.md`）。

> 版號 bump / candidate / tag / changelog 走 **`ops/release.sh`**（`status`/`bump`/`bump-build`/`changelog`/`tag`(原名 `publish`，別名保留)/`release`/`resubmit`/`resume`/`finalize`/`shipped`，單一入口；寫入面一律 dry-run 預設）。`release`/`resubmit` 的 `--yes` 只在 dedicated lane 產生 candidate commit 並交回 IM，不 push protected `main`、不上傳、不 deploy；`tag --yes` 與 `finalize --yes` 都是 tag-only push，不夾帶 branch ref。
>
> **iOS 有兩種 tag，語意不同**：`ios/<x.y.z>` = 該 marketing version **上架 App Store** 的那顆 commit，**只由 `release.sh shipped ios` 依 ASC 查證後物化**、immutable；`ios/<x.y.z>+<build>` = 該 (version, build) 的**封版** commit（只有 exact ASC proof 後才可由正常流程產生）。`--new-version-after-ready` **已移除**——上架 tag 存在本身就是上架證據，新版 guard 直接檢查它。candidate 先經 `release/resubmit` dedicated lane → supported hand-back → IM PR → required/native queue → merged main sync；之後 `resume ios ... --pr ... --merged-source ... --yes` 才會 exact ASC probe、必要時 upload，再由 `finalize` tag-only 封版。若 merged main 已含目標 tuple，candidate 會拒絕重造 build；upload／ASC propagation failure 保留同一 tuple，先查 exact ASC，不產生下一顆 build。細節見 `docs/sop/release.md`。

> **Candidate / resume / finalize closure**：`release ios` 與 `resubmit ios` 在 dedicated lane 只 commit candidate，不 push 或 upload；由 `ops/worktree_orchestrate.py hand-back` 交 IM 發 PR。PR 通過 required/native merge queue 後，CM 以 exact merged receipt 同步 canonical `main`。此時執行 `resume ios <version> <build> --pr <number> --merged-source <sha> --yes`：先做 exact GitHub PR readback（唯一 PR、`MERGED`、`baseRefName=main`、`headRefOid=merged-source`、`mergeCommit` 是 live `origin/main` 的 exact commit ancestor、`baseRefOid` 同時為 source/live ancestor），再查 exact ASC；只有查不到該 tuple 才執行 `ios_release.sh --upload`，再以 exact ASC proof 進 `finalize`。live main 可在 PR merge 後繼續前進；release agent 應在 PR merge 且 canonical main sync 後，以新的 live readback resume。PR readback 失敗、wrong/open PR、source mismatch 或 merge/base ancestry mismatch 都在 ASC/tag 前 hard-stop；不猜 PR body 或 branch。`finalize` 不要求 candidate SHA 直接等於 `origin/main`，只要求 exact PR/source evidence、merged source 是 live main ancestor、current main 已同步，且只推 `ios/<x.y.z>+<build>` tag。upload 或 propagation failure 時保留同一 merged source；重跑 resume 先查 ASC，已接受就跳過 upload，不產生新 build。測試／替代 PR readback 可注入 `KG_PR_CMD`；`KG_ASC_BUILD_CMD`、`KG_RELEASE_ASC_WAIT_SECS`（預設 120）、`KG_RELEASE_ASC_POLL_SECS`（預設 5）控制 exact proof。

### 版號命名決策（下一個 build 該叫什麼）

兩個獨立計數器：`MARKETING_VERSION`（`x.y.z`，對使用者的版本故事）與 `CURRENT_PROJECT_VERSION`（build 號）。**build 號不是所有流程都以 local +1 作為 SoT**：同版 resubmit 先查 ASC，目標固定為 `max(local build, ASC latest)+1`；一般新版本 release 才由 `release_bump.sh` 維持 local +1。Apple 的硬要求是同一個 marketing 版號下 build 唯一，任何查詢失敗都不得猜測。marketing 版號怎麼跳看情境：

| 情境 | marketing | build | 命令 |
|---|---|---|---|
| 同版**未上架/被拒重送**（還在同一輪審查，只換 binary 給審查員） | **不動** | `max(本地 build, ASC TestFlight latest)+1` | `release.sh resubmit ios` candidate → PR/queue/merge → `resume ios ... --yes` |
| 已上架後**新版本**：純修 bug | patch（第三位+1，如 2.0.0→2.0.1） | +1 | `release.sh release ios <x.y.z>` candidate → PR/queue/merge → `resume ios ... --yes` |
| 已上架後新版本：加功能不破壞 | minor（第二位+1，如 2.0.0→2.1.0） | +1 | 同上 |
| 已上架後新版本：大改版/破壞性/里程碑（如 podcast 正式放出） | major（第一位+1，如 2.0.0→3.0.0） | +1 | 同上 |

- semver 判斷**看改動語意、不看 commit 數**（`release.sh status` 的「建議版號」是數量啟發式，僅參考——2.0.0 該輪工具建議 minor、實際是 major）。版號與 changelog 由執行 release 的 agent 自行決定、不需使用者確認，並在回報與 PR 寫明選定版本與一行理由。
- **判斷「同版重送」還是「新版本」的唯一準則 = 上一個 marketing 版號有沒有真的上架**（這條準則沒變，變的是怎麼落實它）。PREPARE_FOR_SUBMISSION / REJECTED / 審查中 = 還沒上架 → 走「同版重送」列，`resubmit ios`，不動 marketing。**這個判斷現在由工具做，不由 operator 打字背書**：上架事實靠 `release.sh shipped ios --yes` 從 ASC 查證後物化成 `ios/<x.y.z>`，`release ios` 的 guard 再讀它。所以**上架後第一件事就是補跑 `shipped ios --yes`**——沒補，下一版會被 guard 正確地擋下來。
- **每顆 build 都要留封版紀錄**。`ios/<x.y.z>+<build>` 記的是「這顆 (version, build) 由哪顆 merged-main commit 封版」，而 **Apple 不保留 source commit**（ASC 只有一筆 version 記錄、`versionString` 可變、build number 每版重新計數），所以它必須在 exact ASC proof 後捕捉。`resubmit ios` 先以 `./ops/asc.sh builds` 讀 TestFlight latest，計畫 build 固定為 `max(CURRENT_PROJECT_VERSION, ASC latest)+1`，只建立 dedicated-lane candidate；查詢失敗或非數字會在 candidate 前硬停。merge 後若已有 candidate，使用 `resume` 或 `finalize`，不要重跑 release 產生新 build。歷史後果見 `docs/sop/release.md`「機制上線前的舊 tag」。

- **workflow launcher contract**：`ios_ops workflow release` 的 App Review gate 由 `ops/lib/project_python.sh` 的 `kg_project_uv_bin` 解析 uv；缺依賴時輸出 typed `gate.execution` block，不把空 executable 交給 streaming runner，也不以 traceback 代替 gate verdict。

> ⚠ **看發版狀態只信 App Store Connect / TestFlight（server 真相），別信 Xcode Organizer**。Organizer 只列 Xcode.app GUI 出的 archive（存 `~/Library/Developer/Xcode/Archives/`）；本 repo 走 CLI（`ios_release.sh` archive 到 `ios/build/`），CLI 出的 build **永遠不進 Organizer**——Organizer 停在最後一次 GUI 出包（1.6(3)/2026-04）不代表後續 build 遺失。TestFlight `asc.sh builds` 才是實況。

```bash
./ops/ios_ops.sh archive              # archive + export 出 .ipa（無對外副作用，預設）
./ops/ios_ops.sh archive --json       # machine-readable kg.ios.archive.v1
./ops/ios_ops.sh archive --upload     # 額外上傳 → TestFlight（對外副作用，需明示）
./ops/ios_release.sh                  # primitive:同 archive
./ops/ios_release.sh --upload         # primitive:同 archive --upload
./ops/ios_release.sh --key 6Y7DC88RUY # 換 ASC API key（預設 TCXVHFRXMS / App Manager）
./ops/ios_release.sh --timeout 900    # 自訂 build lock 等待秒數
```

- **產物**：`ios/build/export/BooksAndVocab.ipa`（git-ignored）。
- **JSON façade**：`./ops/ios_ops.sh archive --json` 會把 delegate stdout/stderr 導到 stderr，stdout 保留單一 `kg.ios.archive.v1` payload；語意分成 `archive` / `export` / `upload` 三段，不與一般 `kg.ios.run.v1` 混用。
- **diagnostics**：archive 階段保留 raw log 與 `Archive.xcresult`，並在第一屏用 `ios_diagnostics.py` 列 warnings/errors；archive 失敗時先看 `[ios][issues]` 與 `xcresult=` path。
- **簽章**：manual signing — Apple Distribution cert（keychain）+ `KG App Store` profile（`ios/ExportOptions.plist`）。`method=app-store`（Xcode 26 印 deprecated 警告但可用；新式 `app-store-connect` 即使 manual 仍強制 Xcode 內登入 ASC account，純 CLI 不適用）。
- **外部識別子鎖定**：live ASC app `bundleId` 已固定為 `com.Max0228.BooksBrowser`，本地 `APPLE_BUNDLE_ID` / Xcode project / simulator fixture 必須對齊它；`com.wordnexus.pro.monthly`（StoreKit/ASC product ID）、`KG App Store`（provisioning profile 名）、`wordnexus.lol`（正式網域）與 `com.Max0228.BooksAndVocab.web`（Sign in with Apple service ID，需 Apple Developer Portal 同步）屬外部契約，沒有同步改外部系統前不可只改 repo。
- **build-number guard**：`--upload` 前比對本機 `CURRENT_PROJECT_VERSION`（`-target BooksAndVocab`）與 TestFlight 最新 build，重複即中止 — 須先 bump 版號。archive/export 不受此限。
- **keychain 免互動**：codesign 存取私鑰需 partition list 授權（一次性 `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <登入密碼> ~/Library/Keychains/login.keychain-db`）；未設則互動 terminal 彈授權框、背景/CI 會 hang。
- **key 選擇**：`TCXVHFRXMS`(App Manager) 可送審;`6Y7DC88RUY`(Developer) 僅 TestFlight。後端訂閱驗簽用 `6Y7DC88RUY`，**勿 revoke**。
- 共用 `ios_build.sh` 的 `/tmp/kg-ios-build.lock`，多 worktree 安全。

### App Store Connect 控制台（`ops/asc.sh`）

`ios_release.sh` 出 build；`asc.sh` 補「ASC 全表面查詢 + metadata/結構讀寫」——近乎完整的 ASC 控制台（App 資訊 / 版本文案 / 審查資訊 / 評論回覆 / 無障礙 / 營利 / 發布控制 / 送審佇列）。主體是 codemagic CLI 包裝（同 `ios_release.sh` 的 `asc()` wrapper），無手刻 JWT；codemagic 暴露不到的物件由旁路 helper 補、JWT 只活在 helper、不污染主檔：唯讀走 `ops/asc_get.py`（GET），**寫入**走 `ops/asc_write.py`（一般化 PATCH/POST/DELETE，body 由 stdin 餵 JSON；4xx/5xx 回 `{_httpError,_detail}`、204 回 `{_ok}`，不裸 crash）。所有寫入經單一 `emit_write` gate：**預設 dry-run**（印舊→新 + copy-paste 指令），`--yes` 才真送。

批次審文案 / 重寫 / 上傳走 `ops/asc_text_bundle.py`: `dump --output asc.json` 一次拉 App 層文案、版本文案、版本 copyright、審查資訊、訂閱文字、截圖/價格/評論摘要；編輯 JSON 後 `apply asc.json` 先 dry-run diff，`apply asc.json --yes` 才 PATCH 低風險文字欄位。它不送審、不撤回、不上傳截圖、不改價格 / 發布控制。

```bash
# ── 唯讀查詢 ──
./ops/asc.sh versions / builds / info             # 版本+審查 state / TestFlight build / app 層級
./ops/asc.sh build <version> <build>              # exact ASC build JSON proof（唯讀）
./ops/asc_text_bundle.py dump -o asc.json         # 整包文案/審查資料 JSON
./ops/asc.sh metadata --locale zh-Hant            # 某版本某語系文案
./ops/asc.sh review-status / review-detail        # 審查提交 state / 審查聯絡+demo+送審備註
./ops/asc.sh submissions [N]                      # 送審佇列 reviewSubmissions + 每筆打包項目數
./ops/asc.sh screenshots / categories             # 截圖逐張 state / 可用分類 ID
./ops/asc.sh reviews [N] / accessibility          # 用戶評論+是否已回覆 / 無障礙宣告
./ops/asc.sh subscriptions / iap / pricing        # 訂閱群組→方案 / 一次性購買 / 基礎定價+供應
./ops/asc.sh sub-offers <subId>                   # 訂閱優惠：介紹性/促銷/兌換碼
./ops/asc.sh release-plan                         # 發布方式 releaseType + 分階段發布狀態
# ── 寫入（皆 dry-run 預設，--yes 才送）──
./ops/asc.sh set <field> <value>                  # 版本文案 appStoreVersionLocalization
./ops/asc.sh set-review <field> <value>           # 審查資訊 appStoreReviewDetail
./ops/asc.sh set-appinfo <field> <value>          # App 層本地化：name/subtitle/privacy-url
./ops/asc.sh set-eula <text> / set-content-rights <uses|none>
./ops/asc.sh set-category <primary|secondary> <ID> / set-rating <attr> <value>
./ops/asc.sh reply-review <reviewId> <text>       # 回覆用戶評論（POST/PATCH upsert）
./ops/asc.sh set-sub-name|set-sub-desc|set-sub-review-note <subId> <value>
./ops/asc.sh set-sub-price <subId> <territory> <customerPrice>   # ⚠ 動真實計費
./ops/asc.sh set-release-type <manual|auto|scheduled> [ISO8601]  # auto=審核過自動上架
./ops/asc.sh phased <start|pause|resume|complete|cancel>         # 分階段發布7天ramp
./ops/asc_text_bundle.py apply asc.json [--yes]   # 整包文案 diff / PATCH（dry-run 預設）
```

**物件邊界**（用錯子命令會互相指路）：`set`→`appStoreVersionLocalization`（逐語系版本文案）；`set-review`→`appStoreReviewDetail`（整版一份審查資訊）；`set-appinfo`→`appInfoLocalization`（App 層逐語系 name/subtitle/privacy-url）；另有 App 層結構寫入（EULA/內容版權/分類/年齡分級）、營利寫入（`set-sub-*` → subscriptionLocalization/Price，`set-sub-price` 用 `preserveCurrentPrice:true` 保護既有訂戶 + 印三重 ⚠，後端以 key `6Y7DC88RUY` 驗訂閱權益）、發布控制（`set-release-type` PATCH appStoreVersions、`phased` POST/PATCH/DELETE appStoreVersionPhasedReleases，complete/cancel 不可逆會警告）。dry-run header 印目標版本字串+state（如 `1.6 (REJECTED)`）避免誤寫。

- **set 可寫 field**：`description / keywords / whats-new / marketing-url / support-url / promotional-text`，空值被擋。
- **刻意不做**：submit-for-review / 撤回送審（避免誤送誤撤，走 GUI）；IAP 寫面（KG `inAppPurchasesV2=0` 無對象）；訂閱優惠建立/刪除（逐地區 price point 繁瑣高風險且罕見，走 GUI）。
- **key**：預設 `TCXVHFRXMS`（App Manager，可寫）；`.p8` 路徑 `${ASC_KEY_DIR:-~/.secrets/apple}/AuthKey_<KEY_ID>.p8`（CI/部署機可覆寫 `ASC_KEY_DIR`）。

#### GUI 可讀 vs API 可讀/可寫

| GUI 區塊 | `asc.sh` 能力 |
|---|---|
| 版本 / 審查 state / build / 文案 metadata / IAP / 分析數字 | ✅ codemagic 讀；文案 `set` 可寫 |
| App 副標/名稱/隱私URL、分類、年齡分級、EULA、內容版權 | ✅ raw 讀寫（set-appinfo/set-category/set-rating/set-eula/set-content-rights） |
| 審查聯絡/demo/送審備註、截圖逐張 state | ✅ raw 讀（review-detail/screenshots）；審查資訊另可寫（set-review） |
| 用戶評論、無障礙宣告 | ✅ 讀（reviews/accessibility）；評論可回覆（reply-review）；無障礙建立走 GUI |
| 訂閱方案/價格/優惠、基礎定價、發布方式、分階段發布、送審佇列 | ✅ raw 讀（subscriptions/pricing/sub-offers/release-plan/submissions）；訂閱名/描述/備註/價格、發布方式、分階段發布可寫 |
| **App 隱私權營養標**（資料蒐集/追蹤宣告） | ❌ public API 不提供，**只能 GUI** |
| **截圖/preview 上傳**、**供應地區設定** | ❌ 無 API/codemagic 命令，**GUI 或 Transporter** |
| **被拒原因（Resolution Center 對話文字）** | ❌ public API 不提供，**只能 GUI 看** |
| 截圖圖檔「內容」是否含已移除功能 | ⚠ API 只給 fileName/state，須 fetch 縮圖目視 |

#### App Store 改動的審核成本判斷

| 想改什麼 | 審核成本 / 流程 |
|---|---|
| `promotionalText` 促銷文 | 低。可不提交新版更新；仍需保持真實、不可宣稱未實作功能。 |
| 價格、供應地區、分階段發布、release type | 不走一般 App Review，但屬真實商務/發布控制；一律先 dry-run，價格變更須確認訂戶影響。 |
| support URL、privacy URL、review notes、demo account | 低到中。依當前 version/submission state 可改；review notes/demo 是審查員資訊，重送前必查是否過期。 |
| description、keywords、subtitle、marketing URL、copyright | 中。屬 metadata；`REJECTED` / `METADATA_REJECTED` / `PREPARE_FOR_SUBMISSION` 通常可修後重送同版，同一輪不可寫欄位以 ASC API 回 `STATE_ERROR` 為準。 |
| screenshots / app previews | 中高。送審中通常不能改；已上架版本核准後，主產品頁截圖/preview 更新通常要建下一個 app version 再送審。API 目前只列 state，不負責上傳。 |
| 訂閱名稱、描述、review note、review screenshot、intro offer | 中高。訂閱物件本身可能進 subscription review；文案必須和 paywall / StoreKit 顯示一致。價格/優惠尤其高風險，逐地區 GUI 檢查。 |
| app binary、功能、UI、權限、登入/IAP 實作 | 高。必須新 build + App Review；同 `MARKETING_VERSION` 重送也要 bump `CURRENT_PROJECT_VERSION`，並重新綁新 build。 |
| App Privacy nutrition labels、Resolution Center 對話 | GUI-only。public API 讀不到/寫不到；被拒原因一定要人工進 ASC GUI 看。 |

#### 被拒處理 SOP（resubmit-readiness 演練，每次重送跑一遍）

1. `./ops/asc.sh review-status` 確認最新提交為 `UNRESOLVED_ISSUES`。
2. 到 ASC GUI「App 審查 → 解決中心」讀 Apple 的拒絕理由（API 讀不到）。
3. **掃殘留**：被拒功能名若已移除，`asc.sh metadata` + `review-detail` + app 副標全 grep 一遍確認 0 命中；`asc.sh screenshots` 列出截圖、fetch 縮圖目視無殘影。
4. **查備註是否過期**：`asc.sh review-detail` 的 notes 常沿用上一輪舊文（KG 實例曾停在 3.1.2(c) EULA 而非當輪原因）；重送時若需更新送審備註，直接 `asc.sh set-review notes "..."`（dry-run 看舊→新，`--yes` 才寫）對應「本輪」原因；向審查員對話回覆仍須 GUI 解決中心。
5. 改 code/文案（`asc.sh set …` 或改 app 碼）→ **`./ops/release.sh resubmit ios`（dry-run 先看計畫，`--yes` 才執行）**：先由 `./ops/asc.sh builds` 取 TestFlight 最新 build，選 `max(local build, ASC latest)+1`；ASC 查詢失敗或非數字直接 hard-stop，不用 local+1 猜測。接著 bump `CURRENT_PROJECT_VERSION`（`MARKETING_VERSION` 不動）→ supported hand-back → IM PR → required/native queue → CM sync merged main。最後執行 `resume ios <version> <build> --pr <number> --merged-source <sha> --yes`；它先查 exact ASC，必要時才 `ios_release.sh --upload`，再 `finalize` tag-only。**別再手跑 `bump-build ios --yes` + `ios_release.sh --upload`**：那條路徑不留完整 candidate provenance。upload／ASC propagation failure 保留同一 tuple；不要重跑 release/resubmit 產生新 build，先查 exact ASC，已接受就沿用同一 merged source finalize；沒有當下 exact proof 不宣稱 ASC/TestFlight 已完成。
6. 加密合規順手：本專案 `GENERATE_INFOPLIST_FILE = YES`（無 source Info.plist），故設 build setting `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`（多數 app 免出口加密，省每次上傳被問）。

#### 已知缺口（待辦，本輪未工具化）

screenshots / app preview **上傳**（list 已做；上傳 codemagic 無命令，須 GUI 或 Transporter + raw multipart）、**多語 localizations**（現僅 `zh-Hant`，缺 `en-US` 易被拒）、`appStoreVersions create`（重送下一版前須先建版本 row）、App 隱私權營養標（無 public API，GUI-only）。submit-for-review / 撤回送審、IAP 寫面、訂閱優惠建立為**刻意不做**（非缺口，理由見上「刻意不做」）。

## App 架構速查

### 主要 Services

| Service | 職責 |
|---------|------|
| `AuthManager.swift` | 單例，Apple/Google SSO、Keychain token、登入狀態 |
| `KGService.swift` | 後端 API 呼叫（拆 10 個 extension：+Graph / +Health / +Models / +Notebook / +Request / +ServerURL / +Stats / +Sync / +UserConfig / +VocabCRUD） |
| `BackgroundSyncActor` | `@ModelActor`，背景同步（push review/stats、pull cards、flush bilateral ops） |
| `SyncCoordinator` | 同步協調（手動同步入口、orphan cleanup） |
| `BookshelfImportService` | Multi-format import（EPUB/TXT/MD/PDF） |
| `AppToastCoordinator` | Toast notification 管理（EnvironmentKey 注入） |
| `AppCrashReporting` | Sentry bootstrap；opt-in via `Info.plist` `SentryDSN`；`bootstrap()` 於 `BooksAndVocabApp.init()` 第一步呼叫；`setUser(id:)` 連動 `authManager.isLoggedIn` 變化；`record(_:context:)` 手動 capture |

### 主要 Views

| View | 說明 |
|------|------|
| `Settings/SettingsView` | 登入登出、伺服器設定、第三方整合 |
| `Reader/ReaderView` | EPUB 閱讀器（iOS only），查詞 → batchAdd → triggerPipeline |
| `Reader/PDFReaderView` | PDF 閱讀器（iOS only） |
| `Vocabulary/` | 單字瀏覽、知識圖譜視覺化、手動同步、hide/unhide links |
| `Vocabulary/Scenes/StatsPresenter` | 統計總覽 + graph thumbnail + health blob |
| `Vocabulary/Scenes/TodayReviewPresenter` | 每日複習 |
| `Bookshelf/BookshelfView` | 書架 + multi-format import |
| `Welcome/WelcomeView` | 首次啟動 / guest 引導（含 login entry points） |

### iOS 資料同步流程

```
Reader 查詞
  → 暫存 VocabularyEntry（syncStatus=0, pending）
  → POST /api/vocab（batchAdd）→ 伺服器生成 embedding
  → POST /api/pipeline（fire-and-forget）→ 伺服器背景 Enrich/Link/Difficulty/Optional External Sync
  → GET /api/vocab?since=<上次同步>（pullCardsToLocal）→ 更新 SwiftData
```

### 認證流程

```
Apple/Google SSO
  → Google User ID 或自訂密語（存 Keychain）
  → 作為 Authorization: Bearer <token> 發給後端
  → 後端建立 data/users/<user_id>/ 隔離目錄
  → HTTP 401 → iOS 自動登出 + 清空 SwiftData
```

### Crash Reporting（Sentry）

**iOS env / Info.plist key / 取樣率（SoT）**：`docs/sop/deploy.md §Sentry 錯誤追蹤 → iOS env / Info.plist`。本段僅寫 iOS-side 程式碼層 wiring。

實作要點（`Services/AppCrashReporting.swift` 與同目錄 seams）：
- SPM dep `sentry-cocoa` 在 pbxproj 宣告 `upToNextMajorVersion` 最低 `9.24.0`（9.x 內可升級），實際版本由 `Package.resolved` 鎖定（目前 `9.24.0`）；升級＝更新 `Package.resolved` 並跑 Sentry 單元測試。依賴同時存在於 `Package.resolved`、app target 的 package product dependencies 與 Frameworks build phase；`canImport(Sentry)` 仍保留為 SDK 缺失時的 no-op fallback，但 source guard 本身不再被視為「SDK 已啟用」的證明
- `AppCrashReporting.swift` 是產品 call site 唯一依賴的 facade；`SentryReporter.swift` 是唯一接觸 `SentrySDK` 的 adapter；`SentryConfiguration.swift`、`SentryPrivacyPolicy.swift`、`AppDiagnosticContext.swift` 分別承擔組態、隱私與 bounded local diagnostics
- Bootstrap 順序：`AppCrashReporting.bootstrap()` 在 `BooksAndVocabApp.init()` 第一步執行（早於 `ModelContainer` init，捕捉儲存初始化失敗）
- User 追蹤：`AppCrashReporting.setUser(id:)` 連動 `authManager.isLoggedIn` onChange — 登出時清除，避免多帳戶污染
- `beforeSend` 過濾：丟棄 `CancellationError` / `NSURLErrorCancelled` 噪音；HTTP breadcrumb 只保留 allowlisted API resource root，不保留 dynamic ID/path、query、host 或 userinfo
- `beforeSend` exception 規則全在 `SentryPrivacyPolicy.redactException`（純函式，`SentryPrivacyPolicyTests` 覆蓋）：SDK 產生的 crash／hang／watchdog（mechanism `mach`/`signal`/`nsexception`/`cpp_exception`/`AppHang`/`watchdog_termination`）保留 `mechanism.type`、`mechanism.handled` 與依 mechanism 收斂的 exception type（mach `EXC_[A-Z_]+`、signal `SIG[A-Z0-9]+`、nsexception 限 identifier 且以 `Exception`/`Error` 結尾、cpp 固定 `C++ Exception`、AppHang／watchdog 只收 SDK 固定字串；不符即回 SDK 的固定 generic 名，如 `NSException`）；value 只留非 PII 形式（`Exception N, Code N, Subcode N`、`Signal N, Code N`、App hanging 時長文字、watchdog 固定句、Swift runtime trap 固定片語），NSException／C++ reason 一律丟棄；其他 `handled == false` 只保留 flag 與 mechanism type；captured（handled）Swift error 維持 type allowlist、fallback `ReportedError`、無 value／mechanism。`mechanism.data`/`meta`/`desc`、`event.error`、NSError userInfo 永不外送；event message 只放行 `SentryPrivacyPolicy.verificationMessage`（`-sentryTest`）
- environment：bootstrap 同步值＝Info.plist `SentryEnvironment` 優先，否則 Debug＝`debug`，Release＝UserDefaults `kg.sentry.verifiedDistributionChannel` 快取的上次 verified 通道（`testflight`/`production`），無快取＝`production`，使啟動期 crash 也帶正確 channel。Release 且無覆寫時，bootstrap 後 detached background Task 以 StoreKit 2 `AppTransaction.shared` 判定（verified `.sandbox`＝`testflight`、`.production`＝`production`），寫回快取並 `configureScope.setEnvironment`；錯誤／unverified／`.xcode` 不動快取與 scope。已知缺口：安裝後首次啟動在 lookup 完成前回報 `production`。判定函式 `SentryConfiguration.bootstrapEnvironment`／`verifiedChannel` 為純函式並有單元測試
- 背景同步回報：`kg.sync.*` 與 `pushReviewQuietly`（`kg.sync.push_review_states|events`）經 `KGService.shouldRecordSyncFailure` 過濾，offline／`KGError.networkError`／cancel／401 不送，server／decoding／未知錯誤送出
- agent 不需要 Sentry GUI：`./ops/sentry_tool.py health|issues|issue|events|releases|regressions|route --json` 透過 read-only Web API 取得 normalized contract；API secret 只用 `SENTRY_API_URL`、`SENTRY_AUTH_TOKEN`、`SENTRY_ORG`、`SENTRY_PROJECT_IOS`、`SENTRY_PROJECT_BACKEND`
- `./ops/sentry_tool.py release-health --json`（read-only，#2076）經 `/organizations/{org}/sessions/` 取每個 release 的 crash-free sessions／users；憑證讀 `~/.secrets/sentry.env`，同名 env var 覆寫檔案值
- `sentry_tool.py` 僅能 GET，沒有 resolve、assign、comment、create 或 GitHub write path；`route` 只給 IM routing 建議，且 stacktrace/release 不足時回報 `evidence_incomplete`，不猜根因
- `sentry_tool.py` 的 invalid usage、HTTP/network、pagination truncation、malformed collection 與 redirect/origin failure 都輸出 `kg.sentry.error.v1`；Bearer token 只送往同一個 HTTPS origin，collection 不完整時 fail closed
- `./ops/ios_ops.sh sentry --json` 會回 `kg.ios.sentry.v1`，除了 source/guard/DSN contract，也獨立檢查 `packagePresent`、`targetLinked`，並回報 `readiness.source_present|package_present|target_linked|build_can_import|api_configured|api_authenticated|project_reachable|runtime_event_seen|symbolication_ready`
- `sentry.verdict` 只允許 `ready|partial|blocked|unchecked`：缺 source、package 或 target link 是 `blocked`；靜態 wiring 完整但尚未有 build/API/runtime/symbolication 證據是 `partial`。`build_can_import` 不會被 source grep 假裝成 true，必須由實際 build/test evidence 補足
- `./ops/ios_ops.sh snapshot --json` 現在也內嵌 `sentry` surface，並把 wiring 漂移收斂成 `summary.counts.sentryWarnings`；若只想知道 release dashboard 是否因 Sentry wiring 漂掉而變黃，不必再手動額外跑 `sentry`
- 對這類 wiring surface，不要只測 happy path。`ops/test_ios_ops.sh` 用 fixture env 直接模擬 `source missing / canImport=false / dsnReference=false`；新的 package/target fixture 另可模擬 SDK pin 或 target link 漂移，驗證 `snapshot --json` 會把 drift 轉成 `summary.counts.sentryWarnings` 與 `summary.nextActions[].source=="sentry"`
- 同一個 surface 不能各自重算。`doctor` 的 sentry readiness 與頂層 `doctor.sentry` 現在都直接重用 `sentry_summary_json()`；`snapshot` 也直接吃 `doctor.sentry`，避免 `doctor` / `sentry --json` / `snapshot` 三條路各自 grep、最後判讀不一致
- 連 wiring failure 清單也收斂成單一真相:`sentry_summary_json()` 直接輸出 `issues[]`（逐 wiring failure,含 key/message/command）;`doctor` verdict = `issues|length==0`、`snapshot` nextActions = `map(issues)`、`sentryWarnings` = `issues|length` 全衍生自此。新增一個 wiring check 只改 `issues[]` 一處,不必同步三處列舉——這是「判讀規則(不只資料來源)單一真相」的範例
- **聚合面用動態 passthrough,不用硬編碼 allowlist**:`snapshot` 的 `timing_summary` 從逐欄位 allowlist 改成 `($run.timings // {}) + {cacheStatus}`,wrapper 新增任何 timing 欄位(如 `lockWaitMs`)自動上第一屏,不必改 snapshot。契約測試注入 `probeMs:777` 驗 passthrough(allowlist 會吞掉)。判準:當聚合面只是「轉發子 surface 的欄位」時,passthrough > allowlist;allowlist 每加一個欄位都是一次漏接機會。
- **何時「不」收斂(false-DRY)也要明確固化**:verdict 三段式（`blocks>0→block / warns>0→warn / pass`）在 doctor/workflow/gate/snapshot 重複,但**刻意不抽**——input 異構(readiness / release-block / diag-errors / 跨源 sum)、runs 另有合理的 `unknown` 分支、跨檔 jq def 共用的耦合脆弱性 > 重複 3 行的成本。改用**一致性契約測試**(`test_ios_ops.sh` 的 canonical `rule($b;$w)`)鎖 3 個 count-based surface 不漂移。判準:重複的是「同一規則」就抽或測;重複的只是「同一形狀、不同語義的視圖」就不抽,改用契約測試防 drift。何時不 DRY 本身就是要記錄的控制面決策。

### Hot Reload（InjectionNext + Inject）

開發時免 build 即時更新 SwiftUI，把「改一行等 30 秒 build」縮到秒級。Debug-only，Release builds LLVM-strip 為 no-op，**production 零影響**。

**前置一次性設定**：
1. SPM dep：`https://github.com/krzysztofzablocki/Inject`（已加進 `BooksAndVocab.xcodeproj`）
2. Build Settings → Debug → Other Linker Flags 含 `-Xlinker -interposable`（**只 Debug**）
3. 下載 [InjectionNext.app](https://github.com/johnno1962/InjectionNext) 放 `/Applications/`

**使用方式**：
1. 啟動 InjectionNext.app（menu bar 出現 icon）→ menu bar 點 **Launch Xcode** 開啟 BooksAndVocab.xcworkspace
2. ⌘R 跑 Debug build 到 simulator，console 應出現 `💉 InjectionNext connected`
3. 改任何已加 `.enableInjection()` 的 SwiftUI view → 存檔 → simulator 1-2 秒內重渲染

**hot reload 範圍**：
- `Views/**/*.swift` 下所有 non-private `struct X: View`(排除 Debug/Scenarios、Readium/PDFReader bridging、ViewModifier、`#Preview` 內)已**全面注入三件套**(`import Inject` / `@ObserveInjection` / `.enableInjection()`)— 改任一 leaf view body 都能熱重載
- **可注入**：view body / modifier / layout / 文案 / `AppTheme` 色票 / padding / spacing / radius / shadow / opacity
- **不可注入(仍需 full build)**：stored property 增減、`@State` 初始值、function signature 改動、`enum` case 新增、`@Observable` macro 生成的 code(偶有時延)、Readium C++/ObjC++ bridging 改動、`UIViewRepresentable`

**自動化工具**：
- 新增 leaf view 後若忘加三件套,跑 `./ops/inject_codemod.py --apply` 自動補(idempotent)
- `ops/injection_lint.sh --strict` 守門:三規則 — (R1) 合格 View 必有 `@ObserveInjection`;(R2) 同檔 `@ObserveInjection` 數 == `.enableInjection()` 數;(R3) 有 `@ObserveInjection` 必有 `import Inject`
- 已知例外:body 為 `if` / `switch` 根 expression 時,codemod 跳過 — 手工包 `Group { ... }.enableInjection()`(現有 9 個 case 已處理完)

**故障排除**：
- console 無 `💉` 訊息 → InjectionNext.app 未啟、或 Xcode 不是從 menu bar 「Launch Xcode」開的
- 改 file 後 simulator 沒反應 → 看 console 是否報 `cannot inject ...`（多半是改到 stored property），需 ⌘R 重 build
- Release archive 報錯 → 確認 `-interposable` flag **只在 Debug 配置**，Release 維持原狀

### Catalog agent UI 工作台

Catalog 是開發、debug 與 UI 討論用的單一 agent 工具：它把指定 UI World 注入真實 app，讓 agent 觀察 simulator window。完整定位與安全契約以 `docs/reference/catalog_scope.md` 為 SoT。

```bash
# 列出指定 UI World 可用的 runtime scenarios；完成後自動釋放 simulator
./ops/ios_ops.sh catalog list --dataset marketing_demo --json

# 開啟互動工作台；可用 --scenario '<category>/<title>' 直達
./ops/ios_ops.sh catalog open --dataset marketing_demo --json

# open 回傳 session id；需要靜態圖時擷取真實 simulator window（預設進系統暫存，TTL 到期回收）
./ops/ios_ops.sh catalog capture --session <session-id> --json

# 只有要附入正式報告時才明示保留；保留物集中在 retained root
./ops/ios_ops.sh catalog capture --session <session-id> \
  --out build/ios-report/retained/catalog/<run-id>/example.png --retain --json

# 使用完釋放該 session 擁有的 disposable simulator
./ops/ios_ops.sh catalog close --session <session-id> --json
```

`list` / `open` 必須明示 `--dataset <name>` 或 `--dataset-file <path>`；host 先跑 `ops/ui_world_manifest.py validate`，再把完整 UI World 結構化注入 app。UI World 描述畫面資料、登入、權益、preferences、SwiftData rows 與檔案資產；Catalog 不維護第二套資料。

scenario 是按需加入的 debug 入口，不是新 UI 的完成條件，也沒有 coverage gate。只有預期會反覆檢查、debug 或展示某個狀態時，才在 `Debug/Scenarios/` 新增並於 `CatalogScene.buildPlaybook()` 註冊。

`capture` 透過 `simctl io screenshot` 擷取已顯示在真 window 的畫面，因此會經過 iOS 系統 compositor，可正確觀察 iOS 26 Liquid Glass、backdrop sampling、WebKit 與系統陰影。禁止改回 `CALayer.render(in:)` 的 offscreen 快照；它繞過 compositor，正是舊工具看不到 iOS 26 按鈕材質的根因。

Catalog 僅在 `DEBUG && targetEnvironment(simulator)` 編譯；每次 `open` 使用 disposable simulator，預設網路指向不可達 localhost。capture 預設是帶 TTL 的單次觀察輸出；需要正式報告畫面時才由 agent 明確保留。

互動 session 預設保證 keeper 存活 1800 秒；需要更長 debug 時在 `open` 前設定 `KG_IOS_CATALOG_SESSION_MAX_SECONDS`。即使 agent crash 或忘記 `close`，keeper 到期後 pool 仍可回收該 slot。
## 參考文件

- `docs/sop/ui-design.md` — Motion Contract + 設計系統規範
- `docs/sop/backend.md` — backend 開發主入口；跨前後端資料流問題時一起看
- `docs/reference/ui/components.md` — 現有 component / pattern inventory，開新 UI 前先查
- `docs/reference/ui/state_matrix.md` — 各主畫面 state coverage matrix，補 UX 時先查有哪些狀態不能漏
- `docs/sop/architecture.md` — 完整 iOS ↔ 後端同步協議、認證架構、資料模型詳解
