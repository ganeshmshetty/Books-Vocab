<!-- doc-meta
tier: sop
authority: derived
update_trigger: delivery-control-dogfood-changed
scope:
  - docs/reference/delivery_model.md
  - ops/delivery.py
  - ops/delivery_control/
  - ops/worktree_registry.py
  - ops/worktree_orchestrate.py
  - .github/workflows/pr-readiness.yml
  - .github/workflows/pr-gate.yml
  - .github/workflows/merge-group-required.yml
verified_against: 9d1fc2de80eb235fa74410b319324e3085cc07b2
-->
# Delivery Control Dogfood SOP

目的：以四個 top-level tasks 讓真實需求持續通過 raw demand → triage → Worker／Issue Solver → typed handback → PR → required → native queue → merge → cleanup，並從一條 production-mode pilot 逐步提升到每小時 12 個 merged PR。這不是另一套 Issue／PR／registry 狀態庫。

本 SOP 固定區分兩種模式：`qualification` 只驗證控制面 clean baseline，不計 production throughput；`pilot` 可在 raw backlog 尚未 drained 時執行一條 bounded 真實需求；`ramp` 才驗證並行度提升；`steady` 只報告一小時 SLO 與吞吐是否達標。`ready=true` 是指定 mode 的觀測結果，不是建立 session、worktree、PR 或 merge 的授權。

角色、hard gate 與生命週期語義以 [`docs/reference/delivery_model.md`](../reference/delivery_model.md) 為準。本 SOP 只定義第一次上線的啟動、觀測、升級與停止程序。

## 啟動前硬條件

正式 tasks 尚未建立前，在 canonical checkout 執行：

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg dogfood-preflight \
  --supervision-worktree /Users/chenliangyu/.codex/worktrees/2366/kg \
  --supervision-worktree /Users/chenliangyu/.codex/worktrees/7e07/kg \
  --supervision-worktree /Users/chenliangyu/.codex/worktrees/be28/kg \
  --supervision-worktree /Users/chenliangyu/.codex/worktrees/e695/kg
```

預設 `dogfood-preflight` 等同 `--mode qualification`，其 `result.ready=true` 只代表 clean-slate qualification 成立。要啟動 production-mode pilot，使用 `--mode pilot`；pilot 不要求 PR 清零、raw backlog 清零、candidate reservoir 補滿或所有 lane 沒有 review／CI blocker，但必須沒有 global freeze，且至少有一個可驗證 candidate 或 direct-assignment packet。preflight 必須同時觀測：

- canonical checkout 是 clean `main`，且 local `main == origin/main`；
- `main` 已 protected、required contexts 包含短 gate `required`、native merge queue 已啟用；
- delivery inventory 中只剩 canonical main；若啟動器使用 detached supervision checkout，必須以
  `--supervision-worktree` 逐一列出 exact path。未列出的 worktree 一律仍算 delivery／unknown
  blocker；不得用 `.codex` 路徑前綴或名稱猜測來排除；
- qualification 才要求沒有可行動的 active development、local handback、cleanup lease、blocked lane、unmapped／duplicate PR 或 **global** source problem；pilot／ramp 只把這些列為對應 lane blocker，global blocker 才停止新 admission；
- 歷史 source problem、owner-recovery residue、無 physical worktree 的 terminal branch residue，以及明確 security/P0/P1 hold
  必須被 control plane 以 quarantine counters 明確標示。它們仍保留原始 evidence、不可 merge／刪除／接管，
  但不能阻塞與其無關的 delivery lane；任何新鮮且可行動的同類問題仍會讓 preflight fail。
- branch-scoped／`git_objects` source observation 若沒有 global uncertainty，不會阻塞無關的 canary；它會出現在
  preflight warning，並讓受影響 branch/object 的 cleanup 與 ramp 保持受限。這種 warning 絕不是 dispatch、cleanup、
  takeover 或 wake 授權；要清除它仍須走原 owner／source lifecycle。舊版 direct-constructed metrics 沒有 scope split
  時，仍以 aggregate source problem fail closed。
- qualification 才要求現存 PR reservoir 為空；security／P0／P1 hold 必須持續有明確 partition，held lane 不得 queue／merge，但不應阻塞有獨立證據的無關 pilot lane。

`backlog_classified=true` 只表示 raw Issue inventory 完整，且每一筆 raw Issue／source entry 都有唯一 disposition；它不要求每筆都成為 candidate，也不表示 `backlog_drained=true`。qualification 的 candidate reservoir 可以是空的；pilot 則需要至少一個可安全派工的 candidate 或 direct-assignment packet。raw backlog 存在時，BS 應輸出 `triage_existing_issues`，不能回報「沒有工作」。

可用的 phase-aware command：

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg dogfood-preflight --mode qualification
./ops/delivery.py --repo /Users/chenliangyu/project/kg dogfood-preflight --mode pilot
./ops/delivery.py --repo /Users/chenliangyu/project/kg dogfood-preflight --mode ramp
./ops/delivery.py --repo /Users/chenliangyu/project/kg dogfood-preflight --mode steady
```

本地 `worktree` 測試群組會先取得 repository common Git directory 下的 blocking
test-execution lock。這只序列化會共用 registry fixture／mutation lock 的測試程序；production
`OperationLock` 預設仍是 non-blocking、fail-closed 語義，不會因測試互斥而改變實際交付命令。
ops pytest 另由 `ops/tests/conftest.py` 的 autouse fixture 設定 `KG_DELIVERY_LOCK_DIR` 到 per-test tmp 目錄，
讓 `OperationLock` 在測試中使用隔離的 lock 檔（依 canonical repo 雜湊命名），因此真實 delivery 正持有
`.cache/delivery-control.operation.lock` 時，測試不會因 `delivery mutation already in progress` 變紅。
該變數僅供測試：任何 operator、launchd 或 CI 的真實 delivery 環境都不得設定，否則使用不同值的程序彼此不再互斥，會削弱 fail-closed lease；production 不設定時路徑不變。
不要平行直接啟動 registry mutation 測試；使用 `./ops/test_ops.sh worktree`，讓 wrapper
在不同 linked worktree 之間共用同一把鎖。程序中止時由作業系統釋放鎖，不建立第二套 registry 狀態。

`OperationLock` 取鎖失敗後每約 0.1 秒重試，預設最久 `DEFAULT_WAIT_SECONDS`（30 秒，#2423／#2871），逾時才拋出與原本完全相同的
`delivery mutation already in progress` 訊息。`KG_DELIVERY_LOCK_WAIT_SECONDS=N` 覆寫此預設：N 為大於 0 的數字時等待 N 秒（上限 3600）；
`0`、負值、無法解析或 NaN 一律單次 fail-fast。未設定時走預設（#2871 前為 fail-fast）。同一程序內的 re-entrant 取鎖不受影響。
輪詢不保證 FIFO，只降低、不消除競爭者被餓死的機率。`deliver.py --lock-timeout` 優先於此環境變數。
`cleanup-merged` 預設等待 120 秒（`DEFAULT_LOCK_WAIT_SECONDS`）。測試隔離 hook `KG_DELIVERY_LOCK_DIR` 存在時，未設定的預設等待退為 0（fail-fast，#2871）。

`publish`、`drain`、`cleanup-merged`、`release-published` 在第一個 GitHub 讀取之前先做 busy probe（`BUSY_PROBE_COMMANDS`，#2871）：
取不到 lease 即在任何 GitHub／registry 讀取前拒絕，零 GitHub 成本；probe 只驗可用性，真正的寫入仍由各本機區段 lease 守住，
網路 I/O 不進 lease（#2236）。probe 與區段 lease 之間的極短競態仍會在區段處拒絕，屬已知殘餘。`queue` 不取 lease（只寫 GitHub），不受 probe 影響。

`OperationLock` 的持有範圍：`publish`、`sync-main`、`record-published-base`、`abandon-pr`、`discard-*`、main preservation、
`admit-candidate`、`issue-intake` 等 mutating command 仍整段持有；`queue`、`cleanup-merged`、`release-published`
只在本機區段取得（#2236），GitHub API、`ls-remote` 與 `push` 都在 lease 之外。`queue` 完全不取 lease：它只寫 GitHub，
由 `expectedHeadOid` 與 enqueue 前後的 body／base／head／state 讀回守住。`cleanup-merged`、`release-published` 只在
canonical main 檢查、registry `cleanup_pending`／terminal read-modify-write、worktree 移除與 local branch 刪除這幾段持有；
receipt-less legacy `cleanup-merged`（migration-only）仍整段持有。因此 `delivery mutation already in progress` 可能在
命令中途出現：已完成的區段保留在 registry `cleanup_pending` lease 之下，重跑同一命令即從該處續做（已不存在的
worktree／branch 冪等跳過）。

`./ops/test_ops.sh` 對 `worktree`、`delivery-control`、`docs-lint`、`disk-guard`、`doctor` 這五個 heavy
group 另有 host-wide slot limiter（`ops/lib/heavy_slots.sh`，名單為 `test_ops.sh` 的 `HEAVY_TESTS`）：
同一台機器上同時最多 `KG_HEAVY_SLOTS`（預設 3）個 heavy group 在跑，其餘等待並印出目前持有者
（slot、pid、group、起始時間）。slot 目錄在 `$HOME/Library/Caches/kg/heavy-slots`
（`KG_HEAVY_SLOTS_DIR` 可覆寫）；持有者 pid 已死或啟動時間不符（pid 被重用）即視為 stale，回收時以 per-slot mutex 序列化並在 mutex 內重驗（防止晚到的等待者踢掉剛重新佔位的活 holder）。
等待上限 `KG_HEAVY_SLOTS_WAIT`（預設 1800 秒），逾時回 rc=75（inconclusive，不是 pass）並列出持有者，
不會死鎖；`KG_HEAVY_SLOTS=0` 停用。非 heavy group 不受影響。多代理併發把 load 推到 60–110
（10 核）會造成 timing 測試假紅，這是它存在的原因；契約測試為 `test_ops.sh heavy-slots`。

這些條件任一失敗都只修該 blocker；不得以人工改 registry、刪 dirty worktree、跳過 branch rule 或降低 hard gate 讓 preflight 變綠。
quarantine 是可驗證的隔離投影，不是 cleanup 成功、owner 恢復、PR mapping 或 security clearance 的替代品。

控制面 PR 合併前不得預先修改 production repository rules。部署順序固定為：合併本控制面 PR → canonical `main` ff-only 同步 → 在 repository settings 啟用 native merge queue 並把 `required` 設為 required context → 用 read-only API 讀回 merge queue 與 branch protection → 清到只剩 canonical worktree → 跑 preflight → 最後才建立四個 tasks。

## 四個 tasks 與唯一職責

| Task | 唯一責任 | 可用 mutation | 禁止事項 |
|---|---|---|---|
| Backlog Scout（BS） | 先完整 inventory 所有 open Issues、逐條產生 disposition／triage plan；再把已核准且無 hold／collision 的 Issue admission 成 typed candidate，將 20–30 視為供給觀測目標而非硬上限，依 `desired_new_solvers` fan-out | 單一 Issue 的明確 admission、Issue Solver 的正常 admission | 批量重寫 Issue；push／PR／merge；自己實作 product code；保存第二套 backlog |
| PR Integrator（PI） | 事件式消費 typed handback；建立／更新唯一 PR；readback；publication 後立即釋放 local assets；metadata／required repair | `publish`、`release-published`、`repair-pr-metadata`、exact terminal cleanup | 修改 product code；接管 owner branch；merge／enqueue |
| Codebase Manager（CM） | 只處理 merge-front；exact admission；native enqueue；landing 後 ff-only sync；把 merged receipt 交給 PI cleanup | `queue`、`sync-main`、明確 hold reconcile | 修 PR body／product code；等待 routine advisory；手動 merge |
| Supervisor | 以約 300 秒 watchdog tick 讀取 deterministic facts 與四個 task 活動；控制 freeze／ramp；升級事故 | task-level freeze／resume 與明確事故升級 | 成為產品 owner；替 BS／PI／CM 執行 mutation；把 agent 自述當 facts |

四個 top-level tasks 彼此直接交接事件；Supervisor 不當 routine progress recipient。所有可硬性判定的 gate 由 `ops/delivery.py`、registry CAS、GitHub rules 與 Actions 執行，agent 只選擇 bounded next action。

事件只負責喚醒下一個責任人，不能取代 current facts。固定路由如下：

| Event | 直接接收者 | 接收後唯一動作 |
|---|---|---|
| raw Issue inventory／triage disposition changed | BS | 先重讀 raw／registry／PR facts，逐條 triage；不把 raw count 當 candidate count |
| candidate admitted／capacity slot opened | BS | 派一條 exact owner／Scope 的 IS lane |
| `kg.worktree.handback.v1` | PI | 立即 publish／readback／local release |
| PR contract／required outcome | PI | body-only repair、required trigger，或同 owner `resume-published` |
| confidence／CR／DS outcome | PI | 非嚴重者送 BS 建 follow-up；P0／P1／security 先 durable hold，再送 BS |
| exact required SUCCESS、無 hold | CM | final read；可入列即 native enqueue |
| merge landing | CM → PI | CM ff-only sync；PI exact terminal cleanup |
| baseline／candidate occupancy changed | PI／CM → BS | 只重讀 GitHub／registry facts，再補供給 |
| 事故、SLO／capacity 失守、無法分類 | 該 owner → Supervisor | 只送 exact blocker；Supervisor freeze／ramp，不代做 mutation |

事件可以延遲、重送或遺失；每個 receiver 都必須先重讀 GitHub／Git／registry，依 idempotent command 收斂。禁止用 task 訊息計數、推定 Ready、保存 PR queue 或回報 routine progress 給 Supervisor。

## Lifecycle conformance matrix

第一次 dogfood 前，用下表核對原始 delivery lifecycle；「agent decision」只能用於無法純機械判斷的 bounded judgment，其輸出仍須落回 GitHub／registry durable facts。

| Lifecycle contract | Deterministic owner／evidence | Agent responsibility |
|---|---|---|
| User direct assignment 或 BS Issue intake | `kg.delivery.candidate.v1`、exact label、GitHub Issue；direct packet 不強制建 Issue | BS 去重、Severity／Priority／Acceptance 判斷 |
| Issue Solver／Worker dispatch | candidate occupancy、registry external IDs、owner／Scope admission | BS 依 `desired_new_solvers` fan-out；不自行實作 |
| branch／worktree claim | registry lock、generation、exact Scope、collision | IS／Worker 只在指定 worktree 實作 |
| focused implementation → commit | Git clean HEAD、exact diff operations | IS／Worker 做最小修復與 focused proof |
| typed handback | `kg.worktree.handback.v1` seal、digest、origin main、Validation、initial holds | owner 交回；PI 不改 code／不補造證據 |
| handback → durable PR | `delivery.py receipt/publish`、unique PR mapping、CAS push、exact readback | PI 事件式立即執行 |
| publication 後 local release | cleanup lease、worktree／local branch absence readback | PI 立即清理；不以等待 CI 為理由保留 |
| exact abandoned PR | unique PR／typed body／published registry／local absence／remote SHA readback | PI 只對已證明可放棄的同一 PR 執行 `abandon-pr`；dirty、unknown、remote drift 一律保留 |
| readiness／required | typed PR receipt validator、`required`、exact manual retrigger | PI 修 metadata／trigger transient retry |
| required code failure | `resume-published` same-owner generation+1 transaction | 原 owner 修 code、fresh handback；PI 更新同一 PR |
| full confidence／CR／DS | GitHub check／review facts；typed／label hold | PI 分類 follow-up；嚴重者先 durable hold |
| merge-front conflict | `reanchor` same-owner CAS、fresh handback／PR required；只落後 main 而 mergeable 的 PR 不需 reanchor | CM 只選隊首，不批次重建後方 PR |
| admission／merge | exact queue gate、native merge queue、merge-group `required` | CM enqueue，不手動 merge、不等 routine advisory |
| landing／main sync／cleanup | `sync-main` ff-only CAS、`cleanup-merged` terminal proof | CM sync；PI 刪 exact remote residue並 terminalize |
| release／deploy | 獨立 release／deploy SOP、approval／health／rollback | 不因一般 merge 自動觸發 |

## 事件與命令

### BS：維持供應

1. 先執行 `issue-inventory`，raw count 必須與分頁讀取結果一致；source problem、security、legacy、blocked、owner-bound、published 與 terminal history 都留在結果中，不能因 quarantine 從 backlog 隱藏。
2. 執行 `triage-plan`，只為一個 Issue 產生完整 triage evidence。`needs-triage`、未分類或 legacy 不會自動進候選；已有 owner／PR mapping 的 Issue 走 recovery，不重開第二條線。
3. 對明確可安全派工的單一 Issue，先以 `render-candidate-body`／`validate-candidate-body` 產生 exact contract，再執行 `admit-candidate`。admission 是串行 read-before/write/readback；任何 fingerprint drift、Scope collision、hold、label 缺失或 readback mismatch 都停止，不自動重試或覆寫人工內容。
4. 只有 `backlog_classified=true` 且 dispatchable reservoir 低於 20 時，才執行 `replenish_candidates`；BS fan-out 的 auditors 仍先做 Issue／PR history、active Scope、physical worktree 去重。raw backlog 未分類時先 `triage_existing_issues`，但不會阻止既有 verified candidate 的獨立 dispatch。
5. `desired_new_solvers` 只消費 controller 已排除 nonterminal registry occupancy 的既有 candidates；Issue Solver 仍只跑 focused proof，commit clean 後以 supported registry command 產生 `kg.worktree.handback.v1`；Issue contract 的每個初始 hard hold 都必須以 `hand-back --hold` 原樣寫入 immutable seal，PI 不可自行推測或清除。

```bash
./ops/delivery.py render-candidate-body --payload-file '<candidate.json>' > '<issue-body.md>'
./ops/delivery.py validate-candidate-body --body-file '<issue-body.md>'
./ops/delivery.py issue-inventory
./ops/delivery.py triage-plan
./ops/delivery.py admit-candidate --issue '<number>' \
  --expected-updated-at '<updatedAt>' \
  --expected-body-sha256 '<sha256>' \
  --payload-file '<candidate.json>' \
  --triage-reason '<bounded reason>' \
  --operator '<identity>'
./ops/worktree_registry.py hand-back --branch '<branch>' --outcomes '<validation.json>' [--hold security]
```

pilot 先限制為一條完整 lane；pilot terminal proof 後才進入多 lane promotion，不能直接為追求數量忽略 owner／Scope／registry／磁碟背壓。`ramp_ready=false` 只表示不能升級並行度，不表示 pilot 不可開始；不存在人工的 5、8 或 12 lane 上限。

### PI：handback 到 PR

收到 handback 事件即執行：

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg receipt --lane '<lane-id>'
./ops/delivery.py --repo /Users/chenliangyu/project/kg publish --lane '<lane-id>' --title '<title>'
```

`publish` 驗證 owner／generation／branch／path／base／parent／HEAD／Scope／digest，push 並建立或更新唯一 PR，做 exact remote-head readback，再以 registry CAS 記錄 GitHub target 的 `published_base_sha`，最後用 cleanup lease 移除 local worktree／local branch。原始 typed hand-back 的 `base_sha` 保持 immutable，不會被 PR target 漂移覆寫；若 PR 已 durable 但 CAS 中斷，可對同一 PR 重跑 `record-published-base`，由 exact tuple／head／body／Scope guards 收斂。歷史 base 可以 durable publish；不要求 current-base，也不等待大型 local gate 或 GitHub CI。

同一 branch 可以保留已合併或已關閉的 PR history；`record-published-base` 的唯一性只投影 branch inventory 中的 current `OPEN` PR。它必須恰好找到一筆，且 number 必須等於本次明確傳入的 PR；歷史 records 仍保留為 evidence，不會被刪除或當成 current candidate。若沒有、超過一筆 `OPEN`，指定 PR 不在 `OPEN` candidates，或 history inventory 有 source problem，命令一律 fail closed。

若 publication 已成功、local release 中斷，只重試：

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg release-published --pr '<number>'
```

已確認是 owner 無法繼續、PR 未 merge、registry 與 remote branch 完整對應，且 local assets 已不存在時，才可執行可重試的 terminal abandonment：

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg abandon-pr --pr '<number>'
```

這不是一般 cleanup，也不是 dirty／unknown worktree 的刪除捷徑；transaction 會先 exact-readback，關閉唯一 PR、CAS terminalize registry、以預期 SHA 刪除 remote branch，再做 final readback。任一步不吻合就 fail closed，保留可恢復狀態。

metadata 漂移只修同一 PR：

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg repair-pr-metadata --pr '<number>'
```

若 controller 回傳 `trigger_required` 或確認 exact required `FAILURE`，PI 只對同一 published tuple 觸發 deterministic repair：

`trigger-required` 讀回 `result.dispatched=false`（`dispatch_action=wait`）代表 exact `pr-gate` run 正在合法等待 runner 或已部分執行，`dispatch_reason` 說明原因；這不是失敗，不得手動 `gh run cancel`／重跑，下一個 tick 再評估。只有 `recover_wedged_run`（零 job 已開始且超過 wedged 門檻）才會 cancel。

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg trigger-required --pr '<number>'
```

command 會再次驗證 unique PR mapping、typed receipt、registry generation、Scope／paths、base／HEAD 與 canonical body；required 已 `PENDING`／`SUCCESS` 時拒絕。dispatch 保留所有 P0／P1／security holds，且不代表 Ready／merge eligibility。若 metrics 已以 `security_hold_global=false` 證明 hold 只屬於 exact Issue／PR lane，其他無關 candidate 可以繼續受控 birth；held lane 仍不可 queue／merge，`pipeline_ready`／`ramp_ready` 仍為 false。legacy 或 scope 不完整的 metrics 為 `null`，必須 fail-closed throttle，不能用計數猜測 hold 不相干。

若 required failure 是 code failure而不是可重觸發的 transient failure，publication 後的 local assets 已被正確清除，PI 不可要求 owner 在不存在的 worktree 修 code。先用 original published generation、owner、branch 與 exact remote HEAD 重建同一 owner lane：

```bash
./ops/worktree_orchestrate.py resume-published \
  --lane '<lane-id>' --branch '<branch>' \
  --owner-thread-id '<thread-id>' --claim-generation '<generation>' \
  --expected-remote-head '<exact-pr-head>' --path '<new-worktree-path>'
```

command 只在 remote branch／receipt／owner／Scope 與 released local assets exact 時，把舊 published generation terminalize 並建立 generation+1 active claim；它不跑測試、不 hand-back、不 push，也不 force-push。原 owner 修復、commit、fresh typed handback 後，PI 只更新既有唯一 PR。

`confidence`／CR／DS 是 parallel advisory evidence，PI 不等待它們才發布或交給 CM。若在 merge 前揭露 P0／P1／security，PI 必須先用 `reconcile-holds` durable 表示；其他失敗送 BS 建獨立 follow-up。若結果在 landing 後才完成，不能改寫成 PASS，仍依 severity 走 follow-up 或 release／rollback 升級。

PI 的每次 metadata／hold／required 修復都保留原始 commit、owner、Scope 與 PR identity；新 generation 只能由 same-owner transaction 建立，不能用 body repair 或 reanchor 洗掉 initial hold。

### CM：merge-front 與 landing

CM 只選一個 merge-front。`reanchor_front` 出現時先要求原 owner 對既有 `LaneState.REANCHOR` 使用 supported JIT reanchor；不重建後方 PR、不批次 rebase。supported command 會原子保存舊 generation 的 publication audit、建立同 owner 的 fresh generation 與 worktree，但不代替 owner rebase／測試／hand-back／push：

```bash
./ops/worktree_orchestrate.py reanchor \
  --merge-front-pr '<number>' --lane '<lane-id>' --branch '<branch>' \
  --owner-thread-id '<thread-id>' --claim-generation '<generation>' \
  --expected-remote-head '<old-pr-head>' --live-main '<exact-origin-main>' \
  --path '<new-worktree-path>'
```

fresh typed handback 更新同一 PR 並重跑 required 後，CM 執行：

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg queue --pr '<number>'
```

`queue` 必須 final-read exact PR／published registry base、head／Scope／receipt、non-draft、mergeable、required SUCCESS、native merge queue 與無 durable P0／P1／security hold。main 有 native merge queue 且 required contexts 含 `required` 時，merge group 會在合併結果上重跑 required，因此 PR base 只落後 live main 不是拒絕理由，enqueue CAS 綁 PR 已記錄的 base；GitHub `CONFLICTING` 以 `reanchor_required` 拒絕並投影為 `LaneState.REANCHOR`；沒有 `required` context 時仍要求 base == live main（此組態不受支援，`dogfood-preflight` 會擋；lane projection 不讀 queue 設定，落後 PR 仍顯示 READY_TO_QUEUE 而由 `queue` 以 stale 拒絕）。只有 GitHub exact readback 已證明 PR landed，才執行：

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg sync-main
```

`sync-main` 只允許 clean `main` 的 ff-only CAS；queue admission 本身不等於 merge landing。

PI 收到 exact merged PR receipt 後完成：

```bash
./ops/delivery.py --repo /Users/chenliangyu/project/kg cleanup-merged --pr '<number>'
```

完成 readback 必須是 remote branch、local worktree、local branch皆不存在，registry 保存 validated terminal proof。

### Supervisor：只看 facts

```bash
SUPERVISION_ARGS=(
  --supervision-worktree /Users/chenliangyu/.codex/worktrees/2366/kg
  --supervision-worktree /Users/chenliangyu/.codex/worktrees/7e07/kg
  --supervision-worktree /Users/chenliangyu/.codex/worktrees/be28/kg
  --supervision-worktree /Users/chenliangyu/.codex/worktrees/e695/kg
)
./ops/delivery.py --repo /Users/chenliangyu/project/kg inspect "${SUPERVISION_ARGS[@]}"
./ops/delivery.py --repo /Users/chenliangyu/project/kg metrics "${SUPERVISION_ARGS[@]}"
./ops/delivery.py --repo /Users/chenliangyu/project/kg plan "${SUPERVISION_ARGS[@]}"
```

`metrics` 與 `plan` 必須沿用 preflight 的 explicit supervision paths；不傳這些參數時，命令會把 supervision infrastructure checkout 當成 delivery worktree，不能拿來判斷 dogfood readiness。

固定看：最近一小時 merges、inter-merge p50／p95、raw Issues／triage-required／dispatchable candidates／active solver／handback／open PR／required-green／merge queue depth、六段 latency p95、collision rate、required failure rate、idle worktree、source problems，以及
quarantined source／lane／PR／terminal residue 與 `recoverable_quarantine` counters。agent 說「正在做」不計入容量；quarantine counters 也不算 active supply。Supervisor 固定用「raw backlog 有 N 個；目前可安全派工 M 個；目前可發布 handback K 個」描述狀態，`candidate_issues=0` 不能翻譯成「沒有工作」。

Supervisor 的 watchdog tick 只用來避免 supervisor 睡死，不代表每 300 秒執行一次完整 pipeline，也不代表自動喚醒被 freeze／archived 的角色。Supervisor 在 turn 開始、每個 bounded progress checkpoint 與正常結束時，以 `runtime-receipt` atomic replace 更新同一份 `kg.delivery.runtime.v1` receipt；新 cycle 必須清除上一個 wake action。唯讀觀測使用 `watchdog`；外部 scheduler 要喚醒時必須改用 `watchdog-claim`，並且只有 exact JSON 結果 `action=wake` 且 `wake_claimed=true` 才能建立一次 turn。`watchdog-claim` 在 dispatch 前以 cycle／last-action CAS 原子保留 wake；同一 stale receipt 的競爭呼叫會得到 `escalate`，不得建立第二個 session，也不得自行 retry。缺 receipt 只能 `escalate`；`frozen`／`archived` 永遠 `noop`；`RUNNING` 但 lease／progress 過期只能 `escalate` 並要求查詢真實 Codex thread 狀態，絕不建立第二個 turn；只有 thread 已非 active 且 receipt 是 stale `IDLE` 或到期 `WAITING` 時，才可發出一次 `wake_id`。Supervisor 的 deterministic plan 會把低水位轉成具體 action：`replenish_candidates`、`fill_required_capacity`、`restore_merge_buffer`、`reanchor_front`、`trigger_required`、`reconcile_idle_worktrees` 或 `recover_merge_cadence`。它只發出可驗證的 bounded action，不替角色寫 code、推 branch 或手動修 registry；任何 unknown／dirty／remote drift 轉成 exact blocker 並 freeze 相關 birth。

## 壞帳終態處置（IM 專屬，預設 dry-run）

供給枯竭常因兩類壞帳：無 owner 的 active claim 佔住 Scope，以及已有 terminal 證據卻仍開著的 Issue 佔住 backlog。兩個指令都預設 dry-run，只有 `--apply` 才寫入；進度走 stderr、結果 JSON 走 stdout。Worker／Issue Solver 不可執行；只有已被使用者授權終態處置的 IM 可用，且必須先看過同一對象的 dry-run 輸出才可 `--apply`。

```bash
# 1) ownerless active claim：先 dry-run 取得 pins，再以 pins 寫入
./ops/delivery.py --repo /Users/chenliangyu/project/kg dispose-ownerless-claim --branch '<branch>'
./ops/delivery.py --repo /Users/chenliangyu/project/kg dispose-ownerless-claim --branch '<branch>' --apply \
  --expected-claim-generation '<generation>' --expected-head-sha '<head>' \
  --operator '<identity>' --reason '<bounded reason>'

# 2) terminal_history Issue：dry-run 列出將關閉清單與每筆證據
./ops/delivery.py --repo /Users/chenliangyu/project/kg close-terminal-issues [--issue '<number>' ...]
./ops/delivery.py --repo /Users/chenliangyu/project/kg close-terminal-issues --apply --operator '<identity>' [--issue '<number>' ...]
```

`dispose-ownerless-claim` 只在下列條件**全部**成立時才轉為 `eligible`，任一不成立就 `refused`（exit 2）並逐條列出 `checks`：canonical checkout 為 clean `main`；該 branch 恰有一個 `active` claim；無 owner thread；無 physical worktree 且路徑不在磁碟上；branch 無任何 PR 歷史（open／closed／merged，inventory 不完整也算不成立）；無有效 handback；remote branch 不存在或等於 claim 的 base／local tip；無 hold。`--apply` 另要求 `--expected-claim-generation`／`--expected-head-sha` 與觀測值逐字相符，並以 write-ahead receipt（`.cache/delivery_dispositions.ndjson`，每列自帶 SHA-256，只增不改）夾住 registry 既有 exact CAS：`intent` → `resolve abandoned` → registry readback → `committed`；失敗會留下 `failed` 列。claim 終態後若殘留 branch ref，再走既有 `cleanup-abandoned`。

`close-terminal-issues` 的資格完全沿用 `issue-inventory` 的 `terminal_history` disposition，並使用同一份 `terminal_evidence`，不另寫判定。額外只接受完成級證據（merged PR、merged lane、duplicate／terminal／merged label）才以 `--reason completed` 關閉；只有 abandoned lane 或未 merge 就關閉的 PR 屬歷史、不是完成，會列為 `skipped` 且不關閉。inventory 不完整時 `--apply` 直接拒絕。逐筆以 updatedAt／body SHA-256 做 CAS、加註解（含證據連結）、再讀回 `CLOSED/COMPLETED`；單筆失敗不中斷其他筆，最後 `verdict=partial-failure` 且 exit 1。

## 無可執行動作與 no-progress 規則

當 `plan` 的 `actions` 全為 `audit_*`、`recover_*`、`inspect_sources` 或 `throttle_solvers`，`desired_new_solvers=0`，且本輪沒有任何本角色可對 exact subject 執行的 mutation，agent 不得再空轉。固定行為：

1. **輸出一次 typed blocked report 後停止**。格式：

   ```json
   {
     "schema": "kg.delivery.blocked-report.v1",
     "blocker_class": "ownerless-claim | terminal-backlog | idle-worktree | source-problem | capacity | unknown",
     "fingerprint": "<sha256 of sorted (action, exact subject ids)>",
     "plan_actions": ["audit_ownerless_lanes"],
     "human_decision_needed": "<需要人類或 IM 決定的一件事>",
     "suggested_commands": ["./ops/delivery.py ... dispose-ownerless-claim --branch '<branch>'"],
     "observed_at": "<ISO-8601>",
     "consecutive_observations": 1
   }
   ```

   `blocker_class` 對應處置指令：`ownerless-claim` → `dispose-ownerless-claim`；`terminal-backlog` → `close-terminal-issues`；`idle-worktree` → `reconcile_idle_worktrees` 的 exact worktree；其餘（`source-problem`、`capacity`、`unknown`）只回報 exact blocker，不猜測修法。`suggested_commands` 必須是 dry-run 形式，不得內含 `--apply`。
2. **禁止以 <20 分鐘間隔重複完整 preflight**（`dogfood-preflight`＋`inspect`＋`metrics`＋`plan`）。blocked 後只有兩種事件可提前喚醒：人類／IM 明確回覆已處置，或 GitHub／registry 出現新的 durable fact。
3. **fingerprint 連續三次相同＝no-progress**：同一 `fingerprint` 在三次獨立觀測（相隔 ≥20 分鐘）都不變，第三次改輸出 `escalate` 並**終止**該 agent loop，不再排程下一輪；`consecutive_observations` 必須如實遞增，不得因文字微調重置。fingerprint 任何一個 subject 改變（新 claim、新 Issue、不同 PR）才視為有進展並歸零。
4. blocked report、escalate 與終止都只是觀測輸出：不授權任何 mutation，也不得拿來降低 hard gate；處置仍須由 IM 以 dry-run → `--apply` 明確執行。

## Canary 與容量升級

1. **Canary 1 lane**：只允許一個 Solver，走完整 handback → PR → required → native queue → merge → sync → terminal cleanup。
2. **Promotion proof**：15 分鐘觀測窗內完成至少 3 個 exact merges；沒有 local residue、unmapped PR、source problem 或 hard-hold bypass。
3. **Ramp 4 lanes**：確認 required 並行、PR body repair、conflicting merge-front reanchor 與一條 blocked lane 不會停止其他 lane。
4. **Ramp**：持續派送所有通過 exact owner／Scope／registry／main／CI／磁碟條件的候選；10–15 open PR、active Solver 8–12、candidate 20–30 與至少 3 個 merge-ready 只作觀測水位，不是停止條件。required 同時容量、collision、global source uncertainty 與每 lane 磁碟預算才是背壓；active 與 durable PR 是兩個不同 reservoir。
5. **Steady state**：持續量測候選、active Solver、PR、handback→PR p95 ≤60 秒、required p95 ≤240 秒、required-success→enqueue p95 ≤30 秒、每小時 ≥12 merges、inter-merge p95 ≤300 秒；未達目標時找出瓶頸，不以固定 lane 數字停止。

只有真實 candidate、GitHub、runner 與 merge queue 健康時才評估 merge SLO；供應或平台失效時，輸出 exact capacity blocker，不偽造工作。

這些水位是 feedback control，不是硬湊數字：active Solver、durable open PR、required-running 與 merge-ready queue 是四個不同 reservoir；不能把它們相加後宣稱達標，也不能因 cadence 暫時健康就停止補 active supply。

## Freeze／rollback 條件

以下任一發生，Supervisor 立即禁止新 solver birth，保留既有 GitHub PR 作 durable queue，並只做 bounded recovery：

- actionable source inventory 不完整、actionable unmapped／duplicate PR、unknown／dirty collision；
- live-lane collision pressure >20%；BS 必須重新分割 Scope，不能靠增加 Solver 掩蓋；
- required p95 >240 秒或 runner 容量耗盡；
- native merge queue／required branch rule缺失；
- local main drift／dirty／diverged；
- publication 後仍有 idle local worktree；
- terminal proof、remote branch或 registry readback 不一致；
- P0／P1／security hold 未被 durable 表示或疑似被洗掉。

已 quarantine 的歷史 residue 不會自動解除 freeze；它只從「是否能啟動無關 canary」判斷中隔離，仍需在後續
bounded cleanup／owner recovery cycle 中取得 exact proof 才能 terminalize。任何 quarantine 計數增加、同一 branch
重新出現 physical worktree、或新 PR 沒有 exact owner mapping，都立即回到 actionable blocker。

Freeze 不關閉或重建已發布 PR，也不刪 dirty／unknown worktree。修復後重新跑 `dogfood-preflight`；只有 baseline 或 canary phase 所需條件重新成立才 resume。

## Dogfood 完成判定

第一次 dogfood 只有在下列證據同時存在時才可標記成功：

- 四個 tasks 的角色邊界沒有交叉 mutation；
- 至少一輪 canary promotion 與一輪 ramp，且每次 landing 後 local main同步；
- handback 等待區與 CI 等待中的 local worktree 均為 0；
- PR body、required、merge-group required、hold、cleanup 的正反向案例都有實際或 fixture 證據；
- `inspect`／`metrics`／`plan` 可解釋每個 action，append-only telemetry failure 不阻擋已完成 transaction；
- 完整 tests、workflow contract、docs impact／registry／lint 綠。

本次實作刻意不新增常駐 daemon 或第二套 queue；controller 仍是 deterministic recommendation layer，GitHub／Actions／registry CAS 才是 durable enforcement。這是相對於原始圖的明確偏移，原因是先保留現有 GitHub-native authority boundary，避免把 agent memory 或本地資料庫變成另一個生命週期真相。

若 merge rate 未達 12/hour，結果必須指出當前最慢階段與量測值；不能以增加 agent 數量取代瓶頸診斷。
