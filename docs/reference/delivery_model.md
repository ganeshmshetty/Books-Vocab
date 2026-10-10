<!-- doc-meta
tier: reference
authority: SoT
update_trigger: delivery-model-changed
scope:
  - CLAUDE.md
  - .github/
  - .claude/agents/
  - .claude/skills/
  - .claude/skills/catalog.json
  - docs/reference/project_onboarding.md
  - docs/reference/agent_context.md
  - docs/runbook/system.md
  - docs/sop/review_discipline.md
  - docs/sop/doc_sync.md
  - docs/sop/delivery_control_dogfood.md
  - docs/sop/release.md
  - ops/context_plane.json
  - ops/context_route.py
  - ops/agent_onboard.py
  - ops/task_registry.py
  - ops/lib/streaming_command.py
  - ops/delivery.py
  - ops/delivery_control/
  - ops/worktree_registry.py
  - ops/worktree_orchestrate.py
  - docs/reference/kg-delivery-lifecycle.mmd
  - docs/reference/架構.rtf
verified_against: 5b5ac2fa158ec2f9508c0befa835720009a60fe5
-->
# GitHub-native Delivery Model

這是 KG 交付模型的唯一權威文件。它定義工作如何進入系統、如何收斂到 PR，以及本機工具不能承擔什麼；它不記錄某一張 Issue、某一個 PR 或某一輪工作的即時狀態。

人讀版的伴隨產物是 [lifecycle Mermaid 圖](kg-delivery-lifecycle.mmd) 與 [架構 RTF](架構.rtf)。兩者都是 derived artifacts，不另立交付語義；本文件、相關 SOP 或控制面契約改變時，必須在同一輪同步檢查並更新它們。

## 第一性原理

GitHub 是整套交付控制面：

| 交付問題 | 唯一 owner |
|---|---|
| 新工作、風險與缺口的發現 | User／Backlog Scout（observation） |
| 需要排序、追蹤或 fan-out 的 durable demand | GitHub Issue |
| 要不要做、為什麼做、完成判準 | GitHub Issue（可選） |
| 優先順序、狀態、認領 | GitHub Issue 的 `P0`–`P3`／狀態 label 與公開認領留言（正本 [`issue_management.md`](issue_management.md)）；不使用 GitHub Project 或 assignee |
| 一次實作的隔離空間 | branch + local worktree |
| 變更、討論、review、驗證、合併請求 | Pull Request |
| 自動測試與 required checks | GitHub Actions |
| 合併後的產品真相 | GitHub `main` |
| 合併後的正式發布與生產安全 | Release／Deploy SOP |

最重要的規則是：

> Issue 是規劃與派工工具，不是程式碼交付工具；PR 是所有程式碼變更的共同交付入口。

所有 code change 都要走：

```text
branch → commit → PR → required + optional agent-review／confidence／CR／DS → CM merge → main → release/deploy（若有明確意圖）
```

`main` 不接受直接寫入。merge 不是 production approval；release、deploy、health gate、rollback 仍由各自安全邊界控制。

## Agent onboarding contract

所有代理先經 [`project_onboarding.md`](project_onboarding.md) 建立 KG 的共同概覽，再確認 canonical identity、工作入口與 assignment，最後才載入 primary skill 和 bounded domain docs。可執行入口是：

```bash
./ops/agent_onboard.py --identity '<identity>' --intent '<intent>' --entry '<entry>' [--specialist-intent '<identity-scoped specialist>'] --evidence '<JSON object containing the required assignment evidence>' --json
```

`--evidence` 缺少任一 assignment requirement 時，onboarding 會在 assignment fail closed；只有 `status=ready` 才會載入 skill 與 domain。`ops/context_plane.json` 是身份、入口、context intent 與 skill intent mapping 的 machine-readable SoT；`.claude/skills/catalog.json` 是 primary skill、dependency、optional、forbidden 與 closure 的 SoT。`ops/context_route.py` 與 `ops/skill_route.py` 只保留給 maintainer 做 `validate`／`--diagnostic` cross-validation；agent-facing loader 唯一是 `ops/agent_onboard.py`。

Onboarding 的成功只代表上下文 contract 完整，不代表 GitHub、merge、release、deploy 或 production 授權。route、identity、worktree hand-back 與 process evidence 都不能取代 branch protection、Actions required checks、environment approval 或 production safety wrapper。文件記技術與操作真相；skill 記載代理的載入、協調與交接方法，不保存 Issue／PR／Project 狀態。

## 角色

角色是責任邊界，不是本機組織階層，也不是第二套權限系統。GitHub repository rules、branch protection、Actions environment approval、production wrapper 與帳號權限才是真正的授權來源。

| 角色 | 責任 | 不負責 |
|---|---|---|
| **CM — Codebase Manager** | 協調整體交付；驗證 exact Ready tuple；控制 merge queue／merge；每次 landing 後讓本地 `main` 與 `origin/main` 精確同步 | 修改產品 code、修改 Worker／Issue Solver worktree、修 PR body／registry、代替 IM 發 PR |
| **IM — Issues Manager** | 管理 GitHub Issue（label 與公開認領，不用 Project）；排序與派工；控制本地 worktree lifecycle；接收 Worker／Issue Solver 的 local hand-back；push 已提交的 exact branch、建立／更新 PR、維護 PR metadata／readiness；收到 CM terminal receipt 後清理三項 Git 資產 | 修改產品 code、替 Worker commit／解 code conflict、merge／enqueue、代替 CM 決定 merge |
| **Worker** | 接受 User／IM 的直接指派；依 `dispatch_channel` 與派遣者討論，只在指定 local branch/worktree 修改 code／test、驗證、建立 local commit，交回乾淨 exact HEAD | 不寫 GitHub（`gh` 只限唯讀，見嚴格責任邊界）；不建立或修改 Issue／PR、不 push、不 review、不 merge／enqueue、不碰其他 worktree |
| **Issue Solver** | 只消除已進入 GitHub Issue 的工作；接受 IM 傳入的 Issue assignment packet，只在指定 local branch/worktree 修改 code／test、驗證、建立 local commit，交回乾淨 exact HEAD | 不寫 GitHub（`gh` 只限唯讀）；不接手未進 Issue 的直接指派，不 claim／修改 Issue、不建立或修改 PR、不 push、不 review、不 merge／enqueue |
| **CR — Code Reviewer** | 對所有 PR 做獨立的正確性、測試、回歸、架構與安全審查；把結論留在 PR | 管理 Issue；擁有 merge 權限；建立本地 review cycle |
| **DS — Docs Steward** | 對所有 PR 判斷文件 impact；維護 registry、metadata、SoT domain SOP／reference，執行 docs lint | 建立本地工作項目資料庫；複製 PR lifecycle |

Release operator 是 CM 所管理的執行能力，不是另一套產品管理層：它只能依 release SOP 與明確批准執行發布、部署或 rollback。

### Backlog Scout 與 PI 控制職能

Backlog Scout 與 PI 是交付控制迴圈中的職能，不是新的 canonical onboarding identity，也不擁有本地 backlog／PR lifecycle：

- **Backlog Scout** 接收 User 發現或主動觀測缺口；需要排序、追蹤、拆解或未來 fan-out 時，先把需求與 acceptance 固化到 GitHub Issue。Scout 可依 deterministic controller 的 capacity 建議 fan-out：Issue-backed 工作交 Issue Solver；只有已具備 User／IM direct-assignment packet、`dispatch_channel` 與 recipient 的 bounded 工作才交 Worker。聊天只運送 assignment，不是需求或狀態 SoT。
- **PI** 是 IM 承擔的 publication/integration execution 職能。它收到 exact typed hand-back 後立即把 branch／PR 發布到 GitHub，再釋放 local worktree／branch；不等待 CI 才建立 PR，也不把 publication 誤報成 Ready。GitHub remote branch + PR 才是等待 required／advisory outcomes 的 durable queue。
- **Supervisor** 在 dogfood 階段只讀取 delivery facts、容量決策與四個 top-level thread 活動，負責 freeze/ramp 與事故升級；它不成為產品 owner、不接管 worktree，也不替 PI／CM 執行 mutation。穩態成立後可降低監控頻率，但不能移除 deterministic gates。
- Scout fan-out 與 PI publication 都只消費 GitHub、Git、registry 與 typed receipt 的 current facts；controller CLI 不發訊息、不建立 agent chat 狀態，也不另存 Issue／PR／queue lifecycle。

### 嚴格責任邊界

本模型明確分離「本地實作面」與「GitHub 控制面」：

- Worker／Issue Solver 的輸入是 assignment packet，不是 GitHub session。IM 將 Issue URL／acceptance／structured Scope／base SHA 傳入；實作者可唯讀 GitHub（`gh issue view`、`gh pr view`、`gh api` GET 讀 review comments，surface `github:read`）以讀全 assignment 引用的 Issue／PR，讓每條 lane 從同一份輸入起跑；任何 GitHub 寫入（含 comment、label、review、push）仍只屬 IM。
- Worker／Issue Solver 可以在本地建立 commit；這是 code hand-back 的一部分，不是 GitHub 交付。hand-back 必須是乾淨 worktree、local branch、exact HEAD、Scope 與驗證證據。
- Worker direct assignment 必須明確記錄 `dispatch_channel=im|user`：IM 派遣時 Worker 和同一個 IM 討論並 hand-back 給同一個 IM；User 派遣時 Worker 和 User 討論，hand-back 給 User 指定的 IM，未指定時由 Worker 在 hand-back 前選定一個 IM。
- IM 只處理 Issue、worktree ledger 與 Git transport／PR metadata。它可以 push Worker 已存在的 commit、開／更新 PR、觸發 checks，但不能改檔案、staging、commit 內容或解 code conflict。
- CM 只處理交付協調、Ready admission、merge queue／merge 與 main synchronization。任何 code 或 PR metadata 修正都退回 IM／原 Worker，不由 CM 代修。
- CR／DS 各自把 review／docs impact 結論留在 PR；兩者都不修改 caller worktree。

### Delegation prompt contract

2026-10 的委派中，背景 agent 曾因長 Bash loop／heredoc 觸發無人可答的 permission prompt 而靜默卡住 1–2 小時，也曾嘗試對已 publish 的 PR 推 commit。IM 的每一份委派 prompt 都必須帶下列規則：

- Shell hygiene：寫檔一律用 Write/Edit；探測迴圈寫成腳本檔後以 `bash <file>` 執行；Bash 只放短的單行命令，不貼長 loop 或 heredoc。
- Liveness：worker 的 transcript 超過 20 分鐘沒有更新時，派工方讀它最後一個 `tool_use`；若卡在大型 Bash prompt，停掉該 worker 並重新派工，不等待。
- 已 publish 或已關閉的 PR 不再接收新 commit：修復走 `deliver.py redeliver` 或全新 lane（published PR 的 code failure 另見 `resume-published`），不對舊 PR branch 推。
- 背景 worker 不處理經其他管道轉送的使用者任務；它只執行 assignment packet 的 Scope 與 acceptance，轉送內容一律當資料回報給派工方。

「Ready」分兩層：IM 只能交付一個已存在、非 draft、證據完整的 Ready candidate；CM 必須用當下 live `origin/main`（native merge queue 與 required contexts 皆啟用時，PR base 只落後 live main 不拒絕，由 merge group 在合併結果上重跑 `required`；詳見下方 queue admission）、exact physical HEAD／Scope、required／readiness、typed seal、branch rules 與 durable hold 再驗證後，才可入 queue／merge。CR／DS 仍把結論留在 PR，但 routine／advisory 結論不形成隱性 hard gate；只有被 repository rule 要求或升級成 P0／P1／security hold 才阻擋。

`ops/context_plane.json` 與 `ops/context_route.py` 內部保留執行層 mapping 以維持既有入口相容；這些 key 不屬於 canonical identity、權限或工作狀態，不應出現在 agent-facing onboarding、assignment 或交接語義中。

## 兩條正式工作路徑

### A. 直接指派

適用於 User 或 IM 已經清楚知道要改什麼的明確工作，例如小型修復、界定清楚的重構或直接交辦。它不需要 Issue，也不進入 Issue 排序。

```text
User / IM / Backlog Scout（完整 direct-assignment packet）
    ↓ direct assignment
Worker
    ↓
branch + worktree → code + tests → local commit + typed hand-back
    ↓
PI publish exact commit + PR → release local worktree/branch
    ↓
GitHub durable PR → required + advisory confidence／CR／DS → CM native merge queue → main → release/deploy（若需要）
```

PR 仍必須寫清楚指派內容、修改範圍、驗收方式、測試證據、文件影響與 production／rollback 風險。

直接指派的 hand-back recipient 不由 Worker 自行模糊推定：

- `dispatch_channel=im`：`dispatch_owner` 是討論對象，也是唯一 hand-back recipient；若另給 `handback_target`，必須相同。
- `dispatch_channel=user`：討論對象固定是 User；`handback_target` 可指定 IM，省略時 Worker 必須先選定 IM，才能交回 hand-back。

### B. Issue 流程

適用於需要討論、排序、拆解或未來追蹤的工作。

```text
User / Backlog Scout
    ↓
GitHub Issue → P0–P3 + 狀態 label triage → Scout fan-out
    ↓
IM 公開認領（claim 留言 + in-progress）→ Issue Solver
    ↓
IM 建立 dedicated worktree → code + tests → local commit + typed hand-back
    ↓
PI publish exact commit + PR → release local worktree/branch
    ↓
GitHub durable PR → required + advisory confidence／CR／DS → CM native merge queue → main → release/deploy（若需要）
```

Issue 的 acceptance 是需求真相；PR 的 diff、conversation、checks、review 與驗證證據是實作真相。Issue 關聯可由 PR 自動 close，但不把 Issue 狀態再寫入 repo。

Issue 層的規則正本是 [`issue_management.md`](issue_management.md)；本文件只固定它與交付模型的接點：

- **認領必須公開，且只有 IM 寫**：認領是 Issue 上帶 `kg.issue.claim.v1` 機讀標記的留言加 `in-progress` 狀態 label；不使用 assignee。本機 registry 仍是執行層真相（worktree 所有權、Scope overlap、hand-back），但只存在 registry 的認領不算已認領。Worker／Issue Solver 沒有 GitHub 寫入權，不發認領、不改 label。
- **狀態 label**：open Issue 恰有一個狀態（`needs-triage`、`needs-info`、`blocked`、`ready-for-solver`、`in-progress`、`in-review`）與一個優先級（`P0`–`P3`）。認領、釋放、`delivery:candidate` 准入仍只屬 IM／CM。
- **PR 連結**：PR 內文用 `Closes #N` 表示完全解決（合併即自動關閉）、`Refs #N` 表示只解決一部分（Issue 回到 `ready-for-solver`）；整合 PR 逐一列出每個 Issue。手動補關 Issue 必須留言附 commit 證據，`close-terminal-issues` 只作安全網。`delivery.py publish --closes N`／`--refs M` 把 `## Issues` 寫進 canonical body，republish、repair、hold 變更與 queue 都沿用，不手改 body（細節見 `issue_management.md`「PR 與 Issue 連結」）。認領指令（`claim-issue` 等）與 `issue_sync` 尚未落地，此前認領與狀態 label 轉換由 IM 依協議手動留言＋label 執行。

只整理既有 Issue、尚未要求 admission 或實作時，依 [`docs/runbook/system.md` 的 Backlog grooming](../runbook/system.md#backlog-grooming) 限定範圍。

## PR 收斂規則

Worker 與 Issue Solver 的實作能力、測試要求與 local hand-back 標準相同，差別是 Worker 處理 direct assignment、Issue Solver 只消除 Issue work。PI 由 IM 負責，從 exact hand-back 立即建立或修復同一個 PR，再釋放 local assets；每個 PR 應讓人能回答：

- 這是 direct assignment 還是 Issue work；若有 Issue，關聯哪一張。
- 改了什麼、為什麼改、範圍與非目標是什麼。
- 哪些測試／Actions 實際通過，命令、exit status 與 exact HEAD 是什麼。
- 是否影響文件、資料、CloudKit、migration、release、deploy 或 rollback。
- CR 與 DS 是否完成各自檢查；未完成時不得宣稱「完整 review／docs 結論已綠」，但不因此偽造未配置的 hard gate。

CM 只在 PR 的 typed contract、required checks、branch rules、mergeability 與安全條件滿足後合併；CR／DS 若揭露 P0／P1／security 必須先成為 durable hold，routine advisory 不等待。PR merge 後才進入 release／deploy SOP；任何外部帳號批准、production 寫入或 rollback 仍是獨立的明確動作。

額外的獨立 LLM review 輪次依 [`docs/sop/review_discipline.md` 的迭代上限](../sop/review_discipline.md#review-iteration-budget)；它不改變 GitHub review、required check 或 merge admission 契約。

### Hand-back、PR 與 cleanup invariant

- local hand-back 不是完成；PI 必須把它轉成真實 PR，否則該工作只能標記為 `hand-back pending PR`，不可算 Ready 或完成。
- hand-back 必須保留 dispatch provenance 與 recipient：IM dispatch 回同一 IM；User dispatch 回指定 IM 或 Worker 在交接前選定的 IM；沒有 recipient 不得宣稱 hand-back 完成。
- typed `kg.worktree.handback.v1` hand-back 必須在交接當下以 `git ls-remote origin refs/heads/main` 捕獲 `origin_main_sha`；delivery control 只把這個 registry seal 正規化成 `kg.delivery.handback.v1`，並以 machine receipt 嵌入 PR body。seal 同時綁定 lane／owner thread／claim generation／branch／absolute worktree path／base／parent／HEAD／observed origin main／content digest／structured Scope／focused Validation／初始 P0、P1、security holds；owner、delegation 或 Scope 變更會開始新 generation 並使舊 hand-back 失效，任一不一致都 fail closed。Issue 上宣告的 `initial_holds` 必須由同一 owner 在 hand-back 時逐項帶入；PI 不可把未清除的初始 hold 洗掉。
- registry 在 `register`／`scope-set` 的同一個 ledger lock 內，同時檢查 external ID 與 structured Scope；`active`、`cleanup_pending` 與尚未 terminal 的 `published` claim 都持續占有 Scope。一般 register 不可把 published branch／path 當成可覆寫 owner；只有 supported same-owner transaction 能先原子終止舊 generation 再建立新 claim。Scope 檔案預設獨占，唯一例外是 `ops/lib/worktree_scope.py` 的 `SHARED_SCOPE_FILES`（exact path、無 glob：`docs/reference/tech_index.md`、`docs/registry.yml`、`ops/complexity_budget.json`、`ops/test_ops.sh`、`ops/tests/test_ops_ci_coverage.sh`）：這些 append-only index、數值 ratchet 與註冊檔照常記入 Scope（hand-back／receipt／PR body 的 Scope 比對仍為 exact），但只有它們重疊時不構成衝突，真正的文字衝突留給 rebase 解。收錄理由逐項如下：`tech_index.md`、`registry.yml` 是 append-only 索引；`complexity_budget.json` 是各條 lane 各調一個數字的 ratchet；`ops/test_ops.sh` 的 `DEFAULT_TESTS` 與各 group case arm、`ops/tests/test_ops_ci_coverage.sh` 的 `LINUX_GROUPS`／`ROUTED_TESTS` 清單是 test group 註冊檔，一次量測（2026-10）下約 10 條排隊 lane 各自只增刪幾行、落在不同 arm／不同條目，獨占 Scope 會把它們逼成 10 輪各 30–40 分鐘的串行交付；同一行或同一 arm 的真衝突在 rebase 時解，merge queue 會對合併後的整體結果重跑測試，所以交付後的驗證不因此減弱。邏輯性檔案（例如 `ops/tests/test_github_workflows.sh`、`.github/workflows/*.yml`）每次修改都是語意變更，不是註冊，不可入列。判斷「兩條 lane 是否重疊」的 gate 一律走同一個 `ops/lib/worktree_scope.py` `overlap_paths()`，因此 registry `register`／`scope-set`／`adopt`、Issue candidate／intake admission、publish preflight（registry claim 與其他 open PR changed paths）、`inspect`／inventory 的 collision 投影、以及 `reanchor-handback`／rebase preflight 的 incoming-main 檢查都一致套用；新增條目須改該常數並附測試。衝突不得延後到 publish 才發現，也不得以 `compact` 消除：compact 只正規化 record shape，不刪除 `active`／`cleanup_pending`／`published`，也不丟棄已驗證的 terminal proof；`merged`／`abandoned` audit history 保持可追溯。Registry normalization 發現 malformed ownership fact 時，global operation（例如 compact）仍 fail closed；branch/path/external ID/Scope 已明確不相交的 target-scoped operation 可以繼續，無法證明不相交或命中該 claim 時必須 fail closed。
- local hand-back 的 `origin_main_sha` 是交接時的觀測證據，不是 publication gate 或 current-main Ready 證據。只要 recorded base 同時是 live `origin/main` 與 worktree HEAD 的 ancestor，歷史 base 的 clean committed hand-back 可立即 durable publish；不要求 live `origin/main` 已是 worktree HEAD 的 ancestor。只有 merge-front 才由 CM 以當下 live `origin/main`、exact PR／registry／receipt base、HEAD／Scope 與 required checks 驗證 freshness；`main` 前進後，已發布 PR 留在 GitHub reservoir，輪到 merge-front 時由 CM 重新驗證；只落後而 `MERGEABLE` 的 PR 直接依 queue admission 入列，與 live main 衝突（`CONFLICTING`）者才由同 owner JIT reanchor（`reanchor` 指令接受 `MERGEABLE` 與 `CONFLICTING`，GitHub `UNKNOWN` 拒絕），舊 receipt 不得直接當成 Ready。
- PI 的 `publish` transaction 先以 exact readback 讓 remote branch + 非 draft PR durable，再以 registry CAS 記錄 PR target 的 `published_base_sha`，最後取得 registry `cleanup_pending` lease；lease 期間同 branch／path 不可重新 claim，local worktree／branch 移除並精確讀回後才完成為 `published`。原始 hand-back 的 `base_sha` 是 immutable provenance，`published_base_sha` 是 GitHub target 的獨立觀測；兩者不可互相覆寫。`published` 只證明 local assets 已可釋放，不複製 GitHub PR 狀態。中斷的 CAS 或 lease 必須由同 receipt／同 PR 重試，PR 等待 CI／review 時只保留 remote branch／PR；需要修改時由 IM 重新開 dedicated worktree。
- publication 後 required 若揭露 code failure，正確的 local resume 不是保留 idle worktree，也不是用一般 register 覆寫 published owner。PI 先以 `resume-published` 對 exact original generation／owner／branch／remote HEAD／Scope 做 CAS；舊 published generation 以 audit evidence terminalize，新 active generation+1 保留原 recorded base，並從 remote PR HEAD 重建 clean worktree。command 不跑測試、不 hand-back、不 push、不 force-push；原 owner 修復後建立 fresh hand-back，PI 只更新既有唯一 PR。與 live main 衝突（`CONFLICTING`）的 merge-front 則使用另一個 `reanchor` transaction，把 fresh generation base 對齊 caller 指定且仍為 live 的 `origin/main`；兩者不可混用。
- `resume-published --mode maintenance` 是同一個 exact owner／branch／HEAD／base／Scope／queue／hold preflight 下的窄修復入口；若 GitHub 尚未產生 `required` context，它可以接受唯一、明確的 `ABSENT` required observation，讓原 owner 修復 gate transport 或 workflow。當既有 exact owner path 仍在 previous hand-back、而 PR branch 已由同一 owner 以 fast-forward 推進時，command 只在 previous hand-back 是 remote HEAD 的 ancestor、worktree clean、branch/path/Scope/CAS 全相符時，以 `git merge --ff-only` 將該原 path 前進到 exact remote HEAD；非 fast-forward、dirty、path drift 或任何 identity mismatch 都 fail closed。這只授權 bounded local repair，絕不把 PR 視為 required-green、merge-ready 或可 dispatch；修復後仍必須重新產生 required check 與 typed hand-back。`required-failure` mode 及有 context 但狀態不一致的 evidence 仍 fail closed。
- 若 published PR 的 required 已是 exact `FAILURE`，但失敗原因是新 `origin/main` 已包含的基線修復，原 owner 可明確使用 `reanchor --allow-required-failure` 進行同 owner 的本地 recovery。這個選項只放行 exact OPEN／main／mergeable 或 `CONFLICTING`（`UNKNOWN` 拒絕）／無 hard hold／未入 native queue／typed receipt identity 相符的 required failure，並重新建立以 current live main 為 base 的本地 worktree；它不宣稱 merge-front、不跳過 required、不授權 queue／merge，也不操作 GitHub。完成後仍須跑 bounded tests、產生新 hand-back、由 PI 重跑 required，通過後才回到一般 CM merge-front 規則。缺少 required、required 非 failure、receipt／owner／head／Scope／CAS 不一致時仍 fail closed。
- publication 後若 registry CAS 或 local removal 中斷，已建立的 PR 不回退；同一 typed receipt 以 idempotent retry 收斂。local removal 前、每一項 local／remote asset mutation 前與 terminal disposition 前，都重新讀取 exact PR target／branch／head／body tuple；任何 drift 都保留 `cleanup_pending` 與尚未處理的資產。CM merge 後，IM／PI 再以 exact merged PR receipt 清除 remote branch，並以帶 digest 的 `kg.worktree.terminal-proof.v1`（lane、PR number、MERGED state、target=`main`、branch、head）把 local disposition terminalize 為 `merged`；一般 orchestrator 不能直接宣告 merged。任何 SHA／Scope／path drift 都只阻擋該 lane，不得 bulk sweep 或跨 lane 清理。
- `worktree_orchestrate.py resolve --remove` 是受 CAS 保護的 local terminal cleanup，而不是一般刪除捷徑。它先驗證 exact expected generation／HEAD、target worktree clean、local branch ref 未漂移且 remote branch 不存在；registry transition 成功後，再重讀 remote／local ref，移除 target worktree，並只在 HEAD 仍 exact 且 remote 仍 absent 時刪除該條 local branch。任何 dirty、remote appearance、ref drift、讀取錯誤或 branch mismatch 都 fail-closed 並保留資產；它永遠不刪 remote branch、canonical `main` 或未知 worktree。這形成「registry disposition → worktree removal → local branch removal → exact readback」閉環，而不把 cleanup 完成誤報成只有 worktree 消失。若 CAS 已成功但後段 cleanup 被擋，以相同 `--expected-generation`／`--expected-head-sha` 重跑同一指令即可：registry 已有同 generation、同 handed-back HEAD 的 `abandoned` 紀錄且無更新的 live claim 時，跳過 CAS 只重新驅動 local cleanup（preflight 與 remote-absence 檢查照舊）。
- 舊版 PR／registry 若沒有 typed receipt，只能走 migration-only 的 terminal cleanup：`cleanup-merged --pr`、`abandon-pr --pr` 與 `cleanup-abandoned --branch` 逐條以唯一 branch／PR、terminal status、exact base／HEAD／Scope、無 dirty／physical collision／remote drift 的 CAS 證據收斂；它們不補寫 receipt、不修 registry、不接管 owner。任何 hold、重複歷史、PR history、head 漂移或無法證明的 branch 都保留並回報 blocker。對已經 abandoned 但仍保留有效 handback 的 ownerless clean branch，先走 owner recovery；確認沒有 owner、PR history、physical worktree 或 ref drift 後，才可由明確 operator 執行 `discard-abandoned-handback`，寫入帶 digest 的 discard proof，再刪除 exact refs。這條路徑不適用於有 owner、dirty、unknown 或 remote-drift 的 branch。
- 每次 merge／queue landing 後，CM 必須 `fetch` 並以安全的 fast-forward 路徑使 local `main` 與 `origin/main` 相同；若 local main dirty、diverged 或 drift，停止後續 admission，不得 force reset 掩蓋問題。

### Required 與 advisory outcomes

`.github/workflows/pr-readiness.yml` 先用 `ops/delivery.py validate-pr-body` 驗證 PR body 只含一份合法 `kg.delivery.handback.v1` machine receipt，並把 receipt 綁到 exact PR HEAD；workflow 不自行重寫另一套 regex schema。`.github/workflows/pr-gate.yml` 的 workflow `pr-gate` 會產生短、可重現的 `required` check run；它只回答這個 PR 是否滿足 repository 基線，不代表所有受影響 domain 都已完整驗證。若 exact published PR 的 required 為 `ABSENT` 或 `FAILURE`，PI 可用 `trigger-required` 重新執行同一 HEAD 上既有的 `pull_request` workflow run；command 會先重讀 unique PR mapping、registry receipt、body、paths、base／HEAD 與目前 check status，再以 branch、HEAD、event 與最新建立時間精確選取既有 run，並拒絕 workflow dispatch run、其他 HEAD 或已成功的 run；進行中的 run 不重跑，改回報 wait decision。active 的 exact run 一律先判定是在等待還是真的卡死：只有 run-level `queued`、`gh run view --json jobs` 讀回零個已開始 job（無 `in_progress`／`completed` job、也無有效 `startedAt`），且目前 attempt 的開始時間（`createdAt`、`startedAt`、`updatedAt` 取最晚者；`createdAt` 在 rerun 後不會重置，所以 recovery 後的新 attempt 會重新累計門檻、不會每個 tick 重複 cancel/rerun）已超過 wedged 門檻（預設 6 小時，`KG_DELIVERY_WEDGED_RUN_AFTER_MINUTES` 可調；macOS runner 排隊 p50 約 2.5 小時、最長近 5 小時，所以 15 分鐘會誤殺正在合法等待的 run）時才算 wedged，此時才可對同一 run ID 執行 supported force-cancel，再重新讀取同一 exact identity；只有 readback 已是 terminal non-success 才以完整 `rerun` 重跑（零 job 沒有綠燈證據可保留）。未達門檻的 queued、任何 job 已開始或 run 已部分完成、`in_progress`／其他 active status，都**不 cancel、不重跑、不另造 run**：command 成功回傳 `dispatched=false`、`dispatch_action=wait` 與 `dispatch_reason`（`kg.delivery.command.v1` 的 `result`），由下一個 reconcile tick 重新評估。已 terminal 的 `failure`／`cancelled`／`timed_out` run 優先 `gh run rerun --failed`，只重跑失敗的 job 以保留已綠的 shard 證據，其餘 terminal 結論才完整 rerun；每個 decision 的 `dispatch_action`（`wait`／`recover_wedged_run`／`rerun_failed_jobs`／`rerun`）與 `dispatch_reason` 都寫進 command output。jobs 證據畸形或門檻設定非法一律 fail closed 且不 cancel。若 cancel 回覆表示 run 已完成、但同一 exact readback 暫時仍為 active，command 只對該明確競態做有限次重讀；讀回 terminal non-success 才可 rerun，readback 仍 active 或其他 cancel/readback 不一致都 fail closed，不以 cancel exit code 代替 GitHub 狀態證據，也不另造 workflow run。這確保新的 `required` 結果仍屬於 PR 的 branch-protection status context，而不是只在 commit API 留下一個 PR 看不見的 observation。找不到可重跑的 exact `pull_request` run 時 fail closed，不用不具 PR 關聯的 manual dispatch 充數；這個修復不清除 hold，也不產生 merge eligibility。

`repo-gate` 的 `git diff --check` 與 changed Python paths 都以 `git merge-base BASE_SHA HEAD_SHA` 到 `HEAD_SHA` 的 diff 為準，不直接比 `BASE_SHA`..`HEAD_SHA`：`pull_request.base.sha` 是 run 開始時的 base 分支 tip，不是 PR 的 fork point，main 在 fork 之後的變更會被兩點 diff 反向算進 PR（曾讓 PR 因其從未碰過、且已在 main 刪除的檔案而紅燈）。`ops/tests/test_github_workflows.sh` 會對非 `merge_group` 的 workflow 擋下兩點 diff；`merge-group-required.yml` 例外，因為 queue group 的 head 包含 base。changed Python paths 非空時以 pinned `ruff format --check` 驗證這個 Scope；沒有 changed Python path 是合法的 bounded pass。這是 required repository contract 的一部分，不能由 advisory `confidence` 的受影響 surface 結果取代；其餘 required／owner／merge 與 security semantics 不變。

若 `trigger-required` 對 wedged exact run 收到「run 已完成」的 cancel 回覆，但 list endpoint 仍暫時回報 active，command 會在同一個 run ID 上 bounded 地讀取 `gh run view` 的完整 identity／status。只有 view 明確讀回相同 branch、HEAD、`pull_request` event 且為 terminal non-success，才允許 rerun；view 仍 active、identity 不一致、或 terminal evidence 不完整都維持 fail closed，不把 cancel 回覆本身當成狀態證據。

同一 workflow 的 `confidence` check run 是 advisory outcome：它提供完整的**受影響** backend／iOS／UI／ops fan-out，nonblocking 只代表不佔用 native merge queue 的串行 gate，不代表可忽略。慢速 backend／ops／iOS lane 由可測的 changed-path policy 選擇：明確無關才會顯示 `skipped`，未知或改動 routing policy 時 fail-closed 為全跑；被選中的 lane 必須 `success`。

iOS lane 另有 selector-aware targeted 模式（Issue #1051），由 `ops/ci_scope_router.sh` 輸出 `ios_mode`／`ios_selectors`、`pr-gate` 轉交 `ios-quality`。**僅**同時滿足以下全部條件才可 `targeted`：merge-base..head 的 NUL-safe diff 恰為一個路徑；該路徑是頂層 `ios/BooksAndVocabUITests/*UITests.swift`（非 `Helpers/`、`Pages/`，basename 不含 fixture／helper／page／support）；現有 `./ops/ios_test.sh --ui --list --file <path>` exit 0 並只回傳完整 `Target/Suite/Method` selector（`matched N` 標頭若存在須與 selector 數相符）；且 `ios/BooksAndVocabTests` 沒有任何 source contract 以路徑讀取該檔（如 `ReviewCardEvidenceContractTests`、`SettingsFixturesTests`，因 targeted 會略過 unit lane，Issue #2114）。其餘一律 `full`：多檔、重複路徑、rename、helper／fixture、app source、project、workflow、router／verdict／其他 CI policy、未知路徑、discovery 失敗／空輸出／suite-only／雜訊、`--all`。`ios-quality` 的 `plan` job 會再次驗證 selector 字串，任何無法證明合法的值都解析為 `full`；targeted job 只以 `KG_IOS_VISUAL_CAPTURE=0` 執行這些 selector（不含 `--visual` 或影片），且 executed 數必須等於 selector 數，zero-executed（`false-green-0-executed`）或數量不符不報成功而是啟動完整 build／unit／ui-smoke；真正的測試失敗維持紅燈。

`agent-review` 是可選的品質與風險觀測 check，不是 repository ruleset 的 hard gate；目前 ruleset 只要求短 `required` context。它可以提供 exact-head 的獨立審查、reviewer provenance 與改進建議，未產生、失敗或延遲本身都不阻塞 native queue、merge、release 或一般 dispatch。若它或其他觀測明確發現 P0、P1 或 security 問題，仍必須以 durable typed hold／label 呈現；真正阻塞來源是該 hold，而不是 `agent-review` check 的 transport 結果。

因此固定採以下判讀：

- GitHub 對 exact PR HEAD 列出的所有 required checks 都成功，才是 merge 的最低 Actions 條件；目前唯一 repository-required context 是 `required`，仍須滿足 typed receipt、live base、branch rules 與其他安全條件。`agent-review`、CR／DS 的 routine advisory 不等待；其 P0／P1／security 發現必須以 durable hold 呈現。
- `confidence` 失敗、缺失、非預期 `skipped`、取消或未完成時，PR 不得宣稱「完整綠」；也不得進入受影響的 release／deploy 路徑。
- CM 只有在 GitHub 已顯示 exact merged `main` 對每個被選中的慢速 surface 啟動等價驗證時，才可取消已被取代的 PR confidence；取消本身不是 PASS，完整結論以該 `main` run 的 terminal 結果為準。
- confidence 結果是 GitHub check run 的證據，不在 repo 內另建本地 confidence／merge 狀態；若要重跑，針對同一 PR HEAD 或 exact `main` 重新觸發 Actions。

GitHub 的 PR `reviewDecision`（`REVIEW_REQUIRED`、`CHANGES_REQUESTED`、`APPROVED`）是獨立的 review observation，不是 required check 結果。缺欄位、格式錯誤或未知值必須保留為 `review-observation-unknown`，不得推論成 approved；`review-gate-unresolved` 只表示仍需觀測／人工審查的 PR 數量。它不授予 approval、merge、native queue 或 Solver dispatch 權限；`plan` 的 review-gate action 僅是 audit signal。若 review inventory 未被量測，metrics 必須維持 unknown，而非靜默當作零；dogfood readiness 也要把 unresolved 或 unknown 與既有 PR reservoir 狀態並列回報。

### GitHub durable queue 與 CM landing

PI publication 後，remote branch + typed PR 是 durable PR reservoir；local worktree 不是等待區。publication 明確建立 target branch=`main`，並在 preflight 與 final readback 拒絕 retarget race；歷史 base 可以先 durable publish，但不能直接 Ready。canonical body 除 Scope／Validation／receipt 外，也固定產生 Impact 與 `kg.delivery.holds.v1`；`delivery-hold:p0`／`delivery-hold:p1`／`delivery-hold:security` labels、typed holds 與 legacy `PUBLISH ONLY` 取聯集，PI 更新 tuple 不得把 hold 洗掉。`base_sha` 保留 hand-back provenance；GitHub PR target 另存為 `published_base_sha`，若 publication 與 registry CAS 分離失敗，`record-published-base --pr` 只能在 exact PR／registry／body／Scope／head readback 後重試，不能覆寫 hand-back base。若 human-readable metadata 漂移但 typed receipt 仍可解析，PI 可在 exact published registry／HEAD／Scope readback 後 body-only 修復同一 PR，不重建 worktree。CM 只把符合以下 exact tuple 的 candidate 送進 GitHub native merge queue：registry `published` receipt、PR body／changed paths／head、PR／receipt／registry base 一致、GitHub required outcomes、mergeability，以及沒有 P0／P1／security hold；PR base 與 live `origin/main` 的關係依下一段 admission 規則。repository 沒有 native merge queue rule 時必須拒絕，不得改成本地 queue 或手動 merge。

native merge queue 以 exact PR／registry 記錄的 base、exact head、canonical typed body 與 target branch=`main` admission。Admission 規則：repository 同時啟用 native merge queue 與 `required` status context 時，merge group 會在實際 `main` 上重跑 `required`，因此 PR base 只落後 live `origin/main` 且 GitHub mergeability 為 `MERGEABLE` 時可入列，enqueue CAS 綁 PR 已記錄的 base（base 與 registry／receipt 不一致仍拒絕）；只有 `CONFLICTING` 或 head 已移動的 PR 以 `reanchor_required` 拒絕，需原 owner `reanchor`。沒有 native merge queue 或沒有 `required` context（queue 不驗證合併結果）時維持嚴格規則：base 必須等於 live `origin/main`，queue 關閉則一律拒絕；此組態不受支援（`dogfood-preflight` 會以 blocker 擋下），lane projection 不讀取 queue 設定，落後的 mergeable PR 仍顯示 READY_TO_QUEUE 而在 `queue` 以 stale 拒絕，不會進入 REANCHOR，需先補齊 repository 規則。adapter 只呼叫 GraphQL `enqueuePullRequest(expectedHeadOid)`，不使用可能直接合併的 auto-merge CLI。`deliver --merge` 在 `queue` 前以 exact head 的 area quality jobs（`backend-quality`、`ops-suite`、`ios-quality`，每名取 `startedAt` 最新一筆）把關：pending 等待、failed／cancelled 拒絕入列、等待逾時為 HOLD；`queue` 成功後若 PR 仍 `OPEN` 而 queue entry 已消失，視為 ejection，立即失敗並列出失敗 check 與 link，不等到 `--timeout`。inventory 直接觀測 GraphQL `mergeQueueEntry` 並把已入列 PR 分成 `pr_queued`；admission 後 `main` tip 前進不是 receipt failure，merge queue 會建立新 merge group 並重跑獨立、短且 blocking 的 `required`。若 PR 被 retarget 或 head／body 改變，只有 queue entry ID 仍是本次 transaction 建立的 entry 才能 `dequeuePullRequest`，replacement entry 必須保留並 fail closed。landing 後 CM 只在 canonical checkout clean、位於 `main` 且 local／origin refs 仍符合 preflight 時做 `--ff-only` sync；任何 race、dirty 或 divergence 都 fail closed。

## Deterministic feedback controller

四個 top-level tasks 的首次上線、canary promotion、freeze／rollback 與完成條件依 [`docs/sop/delivery_control_dogfood.md`](../sop/delivery_control_dogfood.md)；正式 tasks 只能在 deterministic `dogfood-preflight` 通過後建立。

`ops/delivery.py` 是一次一個 command 的 deterministic control surface，不是 daemon、agent dispatcher 或狀態庫。`inspect` 從 registry、physical worktrees、GitHub PR／required checks 與 caller 提供的 owner runtime facts 分類每條 lane；`metrics` 只量測 reservoirs；`plan` 只回傳同一組 facts 推導的 capacity actions。完整 inventory 仍呈現所有 malformed source；raw registry 非 object、無效 external ID 與未知 status 都進入 `source_problems`，不會被 normalization 靜默丟棄。唯讀 `branch-audit`、`branch-review-plan` 與 `unreachable-commit-inspect` 的 `complete=false` 是內容／來源尚未收斂的觀測結果，不是 command transport failure；它們在 JSON 保留 `ok=true`／`verdict=incomplete` 並以 exit 0 返回，caller 必須讀 machine verdict 後再決定下一個 bounded observation，不得以 exit code 建立 session、修改 branch 或把 incomplete 當成成功 cleanup。Git remote-ref queries（包括 `origin/main`、單一 remote branch 與 bulk branch inventory）也有明確 30 秒上限；timeout 或其他非零結果保留 structured command failure，絕不投影成空 ref、missing branch 或 healthy state。`dogfood-preflight` 的 blocked exit 2 與 `watchdog-claim` 的 no-wake exit 2 是明確例外：前者阻止 launch，後者阻止 dispatch。publication 的 collision projection 只解析 active／cleanup Scope，cleanup 則只解析 receipt 指定的 exact claim，因此無關 terminal legacy 問題不會封鎖獨立 transaction，目標 claim／Scope 不可解析仍 fail closed。`source_problems` aggregate 仍讓 readiness 與 audit 保持 fail-closed；metrics 另外輸出 raw `source_problem_scope_counts`（包含 quarantined history）與 `actionable_global_source_problems`。dogfood warning 會分開標示 actionable scoped count 與 raw scope total，避免把歷史觀測量誤讀成目前可執行工作。global source uncertainty、unmapped PR 或 duplicate PR mapping 都把 `desired_new_solvers` 固定為 0，先建議 inspect／bounded recovery；branch-scoped registry residue 與 `git_objects` observation 只阻止受影響的 branch/object cleanup，不能封鎖 exact、無 collision 的其他候選 dispatch。cleanup lease 已有 durable PR，仍計入供給，但該 lane 不會再生新 solver；`cleanup_pending` 只產生原 lane 的 local cleanup action，不是全局 solver throttle，只要其他 global source／PR／collision／CI 安全條件通過，無關 candidate 仍可 dispatch。一條 lane 的 collision、dirty、owner loss、stale tuple 或 required failure 不授權修改其他 lane。`cleanup_pending` 是原 lane 的 local cleanup action，不是全局 solver throttle；只要其他 global source／PR／collision／CI 安全條件通過，無關 candidate 仍可 dispatch。

Watchdog 的 read／claim 邊界也是控制面契約：`watchdog` 只做唯讀決策，永遠輸出 `verdict=observation`、`dispatch_authorized=false` 且 exit 2；即使 action 是 `wake` 或 `escalate`，也不代表可建立 session、重試或 dispatch。外部 scheduler 必須呼叫 `watchdog-claim`，由 runtime receipt 的 cycle／last-action CAS 在 dispatch 前保留唯一 wake。只有 `verdict=wake-authorized`、`action=wake`、`wake_claimed=true` 且 `dispatch_authorized=true` 的 exit 0 結果可以建立一次 Supervisor turn；`verdict=no-wake`、`dispatch_authorized=false`／exit 2 即使 `ok=true` 仍只是有效觀測結果，不得被 shell caller 當成成功 dispatch。`noop`、`escalate` 或 claim conflict 都不得建立 session。若 `last_progress_at`／`observed_at` 晚於 watchdog 的 `now`，或 `last_progress_at` 晚於同一 receipt 的 `observed_at`，時間證據視為 incoherent；watchdog 必須回 `escalate`、不產生 `wake_id`，要求外部 clock／runtime status audit，不能把它當成 healthy/noop 或直接喚醒。這個 claim 不代表 thread 一定可喚醒，也不取代 scheduler 對真實 thread state、freeze／archive 與 receipt freshness 的查詢；它只消除同一 stale receipt 被兩個 scheduler 同時消費的 race。

Issue intake 與 candidate reservoir 是兩個不同的觀測層。`issue-inventory` 先以 `kg.delivery.issue-inventory.v1` 完整分頁讀取所有 open Issues；raw total 永遠包含 quarantine、legacy、malformed、blocked、owner-bound 與已發布／終止歷史，不能用 candidate label 查詢代替。每個可解析 Issue 僅能有一個 deterministic disposition：`source_problem` → `security_hold` → `owner_bound` → `published_pr` → `terminal_history` → `dispatchable_candidate` → `blocked` → `legacy_unmapped` → `triage_required`。Issue body SHA-256、updatedAt、registry mapping、命中的 PR numbers 與原因都隨 inventory 輸出；API 缺欄位或分頁不完整也會保留 raw count 並產生 source problem。

若要把一個已完成去重與 Scope／owner／security preflight 的觀測登記為 GitHub raw Issue，BS／IM 只能使用一次一張的 `issue-intake` command。它要求 exact `title`、`body`、`labels`、`source`、`provenance`、`severity`、`priority`、`acceptance`、structured Scope 與 operator payload；adapter 會在 mutation 前重讀 raw Issue／registry／PR，並在唯一 GraphQL `createIssue` 後 exact readback number／node／URL／title／body／labels／source fingerprint。任何 duplicate、Scope／owner collision、security hold、malformed response 或 readback drift 都 fail closed，沒有自動 retry 或覆寫人工內容。`clientMutationId` 只是同一筆 intake 的 deterministic identity，不是重試授權。這個 command 只建立 raw Issue，不會加入 `delivery:candidate`、candidate reservoir、wake 或 dispatch；建立後仍必須另一次以 expected `updatedAt`／body SHA CAS 執行 `admit-candidate`。raw intake 不是 owner admission、session／worktree 建立或 mutation dispatch 授權。

```bash
./ops/delivery.py issue-intake --payload-file '<issue-intake.json>'
```

Registry `external_ids` 對 Issue 的 mapping 只接受三種 exact identity reference：`#N`、`/issues/N`，或去除前後空白後的 bare positive numeric `N`。bare numeric 只在整個 external ID 完整等於該 Issue number 時成立；任意文字中的數字、前導零或其他 Issue number 都不會被猜測成 mapping。這個 mapping 只修正觀測與 terminal／owner precedence，不會重新 admission、reopen、wake 或授權任何 mutation。

若 registry record 因 claim generation、Scope 或其他 ownership fact malformed 而無法成為 `RegistrySnapshot`，adapter 仍會從同一 raw record 保留合法 `external_ids`。Issue projection 只把命中的 `active`／`cleanup_pending` ID 放入 additive `malformed_active_registry_external_ids` 與 `issues_with_malformed_active_claim`，作為 audit-only provenance；它不會填入 valid `mapped_external_ids`，也不會把 Issue 轉成 owner-bound、建立 session/worktree、wake、takeover、cleanup 或 dispatch。terminal malformed history 不進這個欄位。

PR metrics 也必須區分觀測與供給：`raw_open_prs` 是同一次 GitHub inventory 中去重後所有 state=OPEN PR 的總數，包含 unmapped、security hold 與 quarantine；`open_prs` 保留相容語義，只計有 active／published／cleanup_pending owner mapping 的 durable PR reservoir，供 capacity／merge-front 使用。`unmapped_open_prs`、`quarantined_open_prs` 與 `actionable_unmapped_open_prs` 進一步說明 raw PR 為何不能進入供給；raw count 不授權 publish、queue、merge、wake 或 solver。未提供 raw PR inventory 的 legacy/direct `PipelineMetrics` 必須輸出 `raw_open_prs=null`，不可把未知誤報為零。

現有 `candidate_issues` 語義保持不變：它只是 raw inventory 投影出的、具 exact `delivery:candidate` label 與一份合法 `kg.delivery.candidate.v1` body、且沒有 nonterminal owner／Scope mapping 的可派工子集。candidate contract 的 Severity、Priority、structured Scope、Acceptance 與初始 P0／P1／security holds 必須全部可驗證；label-only、body-only、malformed 或帶安全 hold 的 Issue 都不會進 dispatchable reservoir。controller 不保存本地 backlog 或 Issue lifecycle，GitHub raw inventory 才是完整需求觀測。

逐條處理使用唯讀 `./ops/delivery.py issue-inventory` 與 `./ops/delivery.py triage-plan`。`triage-plan` 每個 item 必須同時輸出唯一 Issue ID、disposition、machine-readable `required_evidence` 與 `next_action`；`required_evidence` 是該 disposition 所需的 fingerprint、Scope／acceptance、owner／registry、PR／remote、hold、blocker 或 terminal proof 清單，不是 admission、wake、cleanup 或 takeover 授權。plan 先列 source／security，再列 triage、可派工 candidate、owner／PR recovery、legacy、blocked 與 terminal evidence；raw backlog 存在時 plan 必須輸出 `triage_existing_issues`，但不阻止已驗證 candidate 的獨立 dispatch。只有 raw inventory 完成分流後、candidate reservoir 低於 20，才輸出 `replenish_candidates`。Supervisor 因此必須分開回報 `raw_open_issues`、`dispatchable_candidate_issues`、`unadmitted_open_issues`、`triage_required_issues`、`legacy_open_issues`、`issues_with_active_claim`、`issues_with_published_pr`、`issues_with_malformed_active_claim`、`issue_source_problems`、`source_problem_scope_counts`、`actionable_global_source_problems`、`recoverable_quarantine`、`backlog_drained`、`pipeline_ready` 與 `ramp_ready`，不能再以「candidate=0」宣稱沒有工作。

任何未提供 raw Issue inventory 證據的 legacy 或 direct `PipelineMetrics` 建構，都必須保持 `raw_open_issues=None`、`unadmitted_open_issues=None`、`issue_inventory_complete=false` 的未知狀態；它不能宣稱 `backlog_drained`／`ramp_ready`，也不能觸發 `replenish_candidates`。這不會阻止已由其他證據驗證的既有 candidate dispatch，但 scheduler 必須先觀測並分流 raw backlog，不能把缺少觀測誤當成空 backlog。

准入只允許一次一張 Issue：`./ops/delivery.py admit-candidate --issue <number> --expected-updated-at <iso> --expected-body-sha256 <sha> --payload-file <candidate.json> --triage-reason <reason> --operator <identity>`。command 會在 mutation 前重讀 Issue／label／registry／PR，驗證 fingerprint、Scope collision、owner mapping 與 hold，再保留原 body、追加唯一 typed block、寫 body、exact readback，最後寫入 `delivery:candidate` label 並再讀回 body／label／contract。這是 application-level read-before/readback，不是假裝 GitHub 提供原子 CAS；任何 drift、label 不存在或 readback mismatch 都停止且不自動 retry／overwrite。Stage 1 的 label／branch-rule／native-queue 設定與單 Issue admission 分離，禁止批量把 raw Issues 改成 candidate。

`metrics.reanchor_required` 只計現有 `LaneState.REANCHOR`，大於 0 時另輸出 `reanchor_front`；controller 不在此重新解釋 REANCHOR 分類語義。`active_development` 只代表已投影且可驗證的開發 lane；為避免把 registry residue 誤報成「沒有進行中工作」，metrics 另外輸出 `active_registry_records`、`raw_active_registry_records`、`active_registry_without_worktree`、`active_registry_without_worktree_owner_bound`、`active_registry_without_worktree_ownerless`、`active_registry_without_worktree_owner_reachable`、`active_registry_without_worktree_owner_unreachable` 與 `malformed_active_registry_records`。其中 `active_registry_records` 只計可解析 claim，`raw_active_registry_records` 包含 malformed active record；malformed 診斷可能同時包含同一 raw record 的多個 reason，但 cardinality 只按 `identity_kind`、identity 與 status 去重，因此不可用 diagnostic entry 數量代替 raw record 數量。若 malformed active record 的 raw path 可驗證且不在 physical worktree inventory，該 record 也會進入 `active_registry_without_worktree` 的 owner split；raw `codex_thread_id` 會保留在 diagnostic observation，ownerless 只能輸出 `audit_ownerless_lanes`，owner-bound malformed observation 不會因缺少可解析 RegistrySnapshot 而獲得 wake／recovery 授權。沒有可驗證 path 的 malformed record 只保留 source audit，不推斷 worktree 缺失。只有 owner-bound 且 runtime status 可達的 split 才能輸出 `recover_owner_bound_lane`，要求原 owner 走 supported lifecycle 恢復；owner-bound 但 archived／notLoaded／unknown／其他不可達 status 只輸出 `audit_unreachable_owner_lanes`，禁止 wake、建立 session／worktree、takeover 或 cleanup；ownerless split 只輸出 `audit_ownerless_lanes`，同樣是 ownership audit signal。直接建構的舊版 metrics 若沒有 reachability split，保留原 aggregate 語義以維持相容；實際 inventory 一律以 runtime readback fail-closed。這些數字是待 owner／registry lifecycle reconciliation 的觀測數，不會被當成 Solver capacity 或授權清理。

每份 metrics snapshot 同時回傳 `live_main_sha` 與 `local_main_sha`，把決策綁定到同一次 inventory 的 `origin/main`／本地 main 讀取；任一值為 null 代表該來源讀取缺失，不能被解讀成「基線未變」或安全同步。metrics 的基線欄位與 `inspect`、`branch-review-plan`、dogfood readiness 使用同一份 inventory 觀測，不另造第二個 SHA 來源。

Branch refs 也是交付資產，但不等於 worktree 或 Solver WIP。metrics 另外投影 `branch_audit_items`、`local_orphan_branches`、`remote_orphan_branches`、`merged_branch_cleanup_ready` 與 `remote_drift_branches`；只要存在需要 reconciliation 的 branch asset，plan 就輸出 `audit_branch_lifecycle`。這個 action 只要求執行唯讀 `branch-audit`／分頁 `branch-review-plan`，不授權刪 branch、cleanup、建立 session 或接管 owner。只有 branch-audit 的 exact CAS preflight 或原 owner supported lifecycle 後續證明，才可進入相應 terminal／publish 路徑。

Remote orphan refs 也有獨立的 CAS 路徑，避免「遠端 branch 已落 main」永久堆積。只有 branch-audit 明確產生 `safe_terminal=true` 的 remote preflight 時，才可執行 `./ops/delivery.py discard-orphan-remote-branch --branch <branch> --expected-head-sha <sha> --operator <id> --reason <reason>`。該 command 必須再次驗證 canonical main clean 且等於 live `origin/main`、registry 無該 branch claim 或 source problem、GitHub 無該 branch 的 PR history、沒有 physical worktree、remote HEAD exact，並確認 branch tip 是 live main ancestor 或 patch-equivalent。若同名 local ref 存在，也必須是同一 exact SHA；command 會先以 local expected-HEAD CAS 刪除 paired local ref，再以 remote expected-HEAD CAS 刪除 remote ref。任一 ref drift、PR、owner、registry、source problem 或未落 main 內容都 fail closed；刪除後還要 exact readback remote/local/worktree 均 absent。這個 command 不修 registry、不關 PR、不建立 handback，也不授權 takeover。

`branch-audit` 的每個 branch asset 若能以 branch 唯一對應 registry record，會以 additive `registry_evidence` 輸出該 record 的 lane、branch/path、status、claim generation、base／published base／handed-back SHA、handback digest、owner、Scope paths 與 external IDs；多筆 record 以 canonical 順序逐筆保留，不能因相同 reason 合併。registry-only active／published residue 也會在 `registry_only_actions[].registry_evidence` 保留同一組 provenance；ownerless、缺少 handback 或其他可解析的空值會明確輸出 `null`／空陣列，沒有 matching record 則輸出空 tuple，絕不猜測。這份 evidence 只是觀測 provenance，不是 owner admission、wake、cleanup、resolve、delete 或任何其他 mutation 授權；既有 disposition、PR／physical facts、schema、verdict 與 exit contract 保持不變。

若 abandoned record 的 typed handback 已被同一 branch 上的一個 merged PR 完整吸收，supported `supersede-abandoned-handback` 才能把它終止為 `superseded_by_merged_pr`。registry evidence 會 additive 保留 merged PR number／head 與 normalized patch fingerprint；這些欄位只是由原 owner／operator 產生的可驗證終止證據，不能把 abandoned handback 重新變成 active、candidate 或 publishable lane。命令仍會重新驗證 canonical main、唯一 PR history、完整 Scope、local／remote ref、內容 fingerprint 與 CAS；驗證成功後才刪除 exact handback／merged branch refs。owner、dirty worktree、remote drift、PR history 不唯一或 fingerprint 不一致時一律保留並 fail closed；不得用 `supersede` 取代 owner recovery、discard proof 或 merged terminal cleanup。

同一 branch name 若同時存在 local 與 remote ref，`assets[]` 與對應 `actions[]` 另以 additive `paired_ref_side`／`paired_ref_sha` 精確指出另一側；兩側 SHA 相同與 remote drift 都保留，不以相似名稱或模糊匹配連結。單側 ref、protected main 或無唯一另一側時兩欄明確為 `null`；pair 只是唯讀 observation，不授權 push、rebase、cleanup、delete、wake 或 owner takeover，既有 disposition、cleanup_action、safe_terminal、owner/registry evidence 與 exit contract 不變。

Capacity action 也嚴格區分「有工作可執行」與「歷史 SLO／quarantine 需要觀測」：`publish_handbacks` 只在 `handbacks_publishable > 0` 時出現；即使歷史 handback→PR p95 超過 60 秒，也只輸出 `audit_transport_slo`，不把不存在的 handback 偽裝成 PI 派工。`recoverable_quarantine > 0` 時輸出 `audit_quarantine`，讓被隔離的 source／lane／PR／terminal residue 有明確的 owner／terminal-evidence reconciliation signal；它不代表可 dispatch、cleanup、建立 session 或重試 mutation。近期 merge 數高於 `merge_to_sync_samples` 時輸出 `audit_sync_telemetry`，要求核對 CM 的 supported main-sync receipt；它是同步閉環的觀測缺口，不是自行執行 sync、建立 session 或重試 mutation 的授權。Dogfood preflight 同時把這個缺口列為 warning，但不把 observation 變成 blocker；只有實際的 main、PR、hold 或來源安全條件才阻止 readiness。`repair_required` 只代表實際 required failure／absence，`enqueue_green` 只代表現有 required-green reservoir；對應的 CI-start／queue-admission latency 超標分別輸出 `audit_ci_start_slo`／`audit_queue_admission_slo`。`recover_merge_cadence` 也只有在 open PR、handback、active development、required-green 或 native queue 供給存在時才出現；只有 cadence SLO 失守而沒有任何可恢復供給時，輸出 `audit_merge_cadence`。所有 observation action 都是告警／調查信號，不是建立 session、建立 worktree 或重試 mutation 的授權。

`branch-audit` 除了盤點 local／remote branch refs，也會以唯讀、最多 30 秒的 `git fsck --unreachable --no-reflogs` 觀測失去 ref 的 commit object。這些 object 只進入 `unreachable_commit_count`／sample quarantine，不會被自動恢復成 branch、推成 PR 或刪除；若 fsck timeout、invalid ref 或出現其他診斷，會以 `complete=false` 保留 machine-readable `source_problems`，並阻止所有受影響的清理判定，而不讓 supervisor heartbeat 無限等待。這讓「branch 已被刪除但 commit 尚未落 main」不再靜默消失，同時不把 Git garbage candidates 誤算成 active Solver。對多個 local orphan branch，orphan preflight 會先建立一個穩定的 canonical／registry／worktree／branch ref snapshot，再逐枝執行必要的 ancestor 檢查；這只消除重複 I/O，不降低任何 owner、PR history、remote ref、physical worktree、ancestor 或 source-problem gate。若 branch tip 不是 live `origin/main` 的 ancestor 且已有足以阻止 discard 的 blocker，會保留 deterministic 的 non-ancestor blocker，並標記 `patch-equivalence not evaluated because other blockers exist`，不再執行不影響 disposition 的昂貴查詢；只有其他 preflight 條件都通過時才唯讀執行 `git cherry <live-main> <branch-tip>`。只有每個 branch-only commit 都回傳 `-`、且所有其他 CAS 條件仍 exact 時，才可視為 patch-equivalent 並安全丟棄本地 orphan ref。任何 `+`、malformed／不可用輸出、owner／PR／remote／worktree／source problem 都維持 fail-closed；patch-equivalence 只是「內容已落 main」的觀測證據，不是 rebase、push、merge 或 owner takeover。

同一份 fsck inventory 會對最多 20 個 sample commit additive 投影 `unreachable_commit_evidence`：保留 exact SHA、parents、subject、bounded changed paths、完整 path count／truncation、content fingerprint、disposition、source problem scope 與 next step。單一 malformed object 只產生 `complete=false` 的 typed evidence 與該 object 的 source problem，不使整份 inventory 崩潰；既有 `unreachable_commit_count` 與 `unreachable_commit_sample` 保持相容。這些 evidence 是 bounded、read-only audit signal，不代表 object 可恢復成 branch、可 push／建立 PR、可建立 owner claim、可 cleanup 或可刪除；3998 個 object 加上最多 20 筆 evidence 也不構成任何 lifecycle 授權。

若 branch ref 已消失但仍有具體 commit SHA，使用唯讀 `./ops/delivery.py unreachable-commit-inspect --commit <sha> --max-paths <n>` 取得 `kg.delivery.unreachable-commit.v1`；`--max-paths N` 的 caller contract 是 `1 <= N <= 200`，超界或非整數是 deterministic contract error，不應重試、建立 session、修改 branch 或觸發 mutation。它先確認 SHA 出現在目前 `fsck` observation，再讀 parent、subject、bounded changed paths 與 path fingerprint；結果的 disposition 只能是保留待 owner／Issue／PR 關聯，或在 source problem／非 unreachable 時 fail closed。即使 fsck 有 malformed ref 等 `git_objects` source problem，只要目標 SHA 已被 stdout observation 看見，工具也會輸出 `complete=false` 的內容證據與 `source_problem_scope=git_objects`；這些證據不可建立 branch、PR、owner claim 或刪除 object，必須先修復 source problem 或完成原 owner lifecycle。

對於沒有 worktree、remote ref、PR history 或 registry claim，但仍含有未落地 commit 的 local orphan，`branch-audit` 不得直接刪除，也不能只回報一個無法行動的 blocker。每個 blocked local orphan 都提供唯讀 `review_command`，可執行 `./ops/delivery.py branch-inspect --branch <branch> --expected-head-sha <sha>`，取得 live main／branch HEAD、ahead／behind commit 數、最多 200 個排序後變更路徑、最多 20 個 bounded commit subjects 與 change fingerprint；`changed_path_count` 與 `changed_paths_truncated` 明確表示是否還有未列出的路徑，而 fingerprint 仍涵蓋完整 raw diff。`branch-inspect` 的 commit-summary 輸出固定受 `1 <= N <= 20` contract bound 保護；目前 command 沒有 caller override，direct adapter caller 也會在任何 Git read 前拒絕超界值。這份 `kg.delivery.branch-content.v1` 只是內容審查證據，不是 owner、Issue、PR 或 hand-back claim；審查後若要發布，仍回到原 owner／Scope lifecycle。若明確判定該 unlanded local-only branch 應丟棄，才可使用 `discard-unregistered-branch`，並同時通過 registry／PR／remote／physical／HEAD／content fingerprint 的雙重 CAS readback 與 `--confirm-unmerged` operator 確認；任何 source problem、owner evidence、remote drift 或物理 worktree 都會 fail closed。這使「發布、保留、明確丟棄」三條路徑都有 machine-readable terminal disposition，不把未落地 commit 靜默當成可刪垃圾。

patch-equivalence 也是 bounded observation：單次 `git cherry` 最多執行 5 秒；批次 orphan preflight 的 patch-equivalence 查詢共用 30 秒總預算。已有其他 blocker 的 non-ancestor branch 不消耗這項查詢預算，並以 `patch_equivalent_to_main=null` 保留「未評估」證據。命令超時或批次預算耗盡時，該 branch 保持 incomplete／fail-closed，後續 branch 不再追加昂貴查詢；source evidence 與 blocker 仍會輸出。這些時間界線只保護 supervisor／branch-audit liveness，不降低 ancestor、owner、PR、remote、worktree 或 CAS 條件，也不授權刪除、rebase、push、merge 或 takeover。

當 local orphan 數量較多時，使用唯讀 `./ops/delivery.py branch-review-plan --offset <n> --limit <m>` 分頁取得 `kg.delivery.branch-content-review-plan.v1`；caller contract 是 `0 <= offset <= total_candidates`，且 `--limit N` 必須滿足 `1 <= N <= 20`。`offset == total_candidates` 是合法的 empty end page，保留既有 `reviewed_count`、`remaining_count=0`、`reviewable_complete` 與 `complete` 語義；`offset > total_candidates` 則是既有 PolicyViolation／structured command contract error，不得 clamp、inspect content 或回傳 `reviewed_count > total_candidates`。caller 遇到超界必須重讀 inventory；不得重試建立 session、修改 branch 或觸發 mutation。它只選取 branch-audit 已經證明是 local orphan、且沒有 worktree／remote／PR／registry owner claim 的項目，並且只把 exact「tip 不是 live main ancestor」或「tip 不是 live main ancestor 且不是 patch-equivalent」內容審查 blocker 送進 review plan；`patch-equivalence not evaluated because other blockers exist` 與 remote ref、PR history、registry claim、physical worktree 或 source problem 都留在 branch-audit／原 owner lifecycle，不會被誤送進 orphan content queue。再逐頁取得內容 fingerprint、ahead／behind、bounded paths 與 commit subjects；每個 review item 最多輸出 20 條排序後的 path sample，`max_paths` direct caller contract 同樣固定為 `1 <= N <= 20`，超界不會 clamp 或執行 Git；但 `changed_path_count`、`changed_paths_truncated` 與 fingerprint 仍保留完整 diff 證據，需看更多路徑時改用單一 branch 的 `branch-inspect`。`remaining_count=0` 只表示從該 offset 起沒有下一頁，不能單獨表示全局 review 完成。新增的 `reviewable_complete` 只有在 `offset=0`、整個 reviewable queue 可由這次回應耗盡、且當頁內容證據完整時才為 true；若從後續 offset 讀取最後一頁，它仍為 false，避免把未被本次命令證明的前頁當成已審查。`complete` 仍 additionally 要求 `audit_complete=true`，因為 remote／owner／registry／source blocker 被刻意排除在 review queue 外。它不會 publish、discard、建立 owner 或修改 registry；每個 review item 仍必須回到原 owner publish，或由 operator 以單一 branch 的 fingerprint＋雙重 CAS 明確丟棄。

預設 feedback policy 的健康吞吐目標是每小時 12 merges，且有健康供給時最長 300 秒至少 landing 一個；這是 capacity SLO，不是繞過 required 或 P0／P1／security hold 的時限。merge cadence 同時輸出最近一小時 count／rate、相鄰 landing 間隔 p50／p95 與距最後一次 landing 秒數。durable open PR floor 10、candidate reservoir 20–30 與 active Solver 8–12 是觀測目標，不是硬性 admission ceiling；controller 不再因固定的 PR／Solver／每 cycle 數字停止已驗證候選。只要 source、Scope、owner、CI、registry、main 與磁碟配額等真正安全條件通過，`desired_new_solvers` 可等於目前可派候選數；required runner、磁碟 lane budget、collision pressure 或 global source uncertainty 才是實際背壓。active Solver 是領先供給 reservoir，若等 cadence 變慢才補貨，實作 lead time 會造成可預測的斷料鋸齒；但「無固定上限」不等於無限建立垃圾 worktree，每條 lane 仍須有唯一 owner／Scope、可歸因磁碟占用與 terminal cleanup proof。controller 會平行建議 drain publishable hand-backs、local release、required-green enqueue、PR contract repair、required trigger／repair、terminal cleanup 與 bounded blocker recovery。`metrics` 從 registry、PR、exact required checks、native merge queue entry 與 append-only duration telemetry 量測最近一小時 hand-back→PR、PR→required-start、required duration、required-success→enqueue、merge→main sync、merge→terminal cleanup 的 sample count／p95，並回傳 required-running／absent、native queue depth、collision pressure、required failure rate、PR-contract failure 與 idle worktree。canary 的 collision pressure 定義為目前 live lanes 中 collision-blocked 的比例；高於 20% 時輸出 `improve_scope_partition` 並停止新 solver birth，等 dogfood 累積 admission event 後再升級為時間窗 collision rate。telemetry 只保存 operation duration evidence，不複製 Issue／PR／registry lifecycle；寫入失敗只能成為 machine-readable warning，不得回滾或阻擋已完成的 delivery mutation。JIT reanchor 的 hand-back timestamp 晚於既有 PR `created_at` 時改讀該 generation 的 publication journal，不把舊 PR 建立時間當負延遲；其他無法由同一 generation／HEAD 解釋的跨來源時間倒流才算 source problem。feedback policy 對前三段 transport／CI-start／admission latency分別採 60／60／30 秒 p95 SLA 並回傳對應 PI／CI／CM action；`plan` 直接用 observed required-duration p95，超過 240 秒即 throttle solver birth，不再依賴 caller 手動注入。

`security_hold_lanes`／`security_hold_issues` 只說明有多少條 lane／Issue 帶有 hard hold，不能單獨推導「全域禁止新 Solver」。測量 inventory 若每個 hold 都有 exact Issue／PR identity，會輸出 `security_hold_global=false`；這仍使 `pipeline_ready`／`ramp_ready` 為 false，且 held lane 不能 queue／merge，只表示不相干的 verified candidate 可以受控 dispatch。legacy/direct `PipelineMetrics` 沒有 scope 證據時為 `null`，capacity 必須 fail-closed，維持 global throttle。

## 本機 coordinator 的窄責任

本機 coordinator 是多 worktree 的執行環境安全工具，不是產品管理系統。`ops/worktree_registry.py` 是相容 command facade；admission、records、handback、lifecycle、storage 與 parser 各自由 `ops/worktree_registry_core/` 的小模組維護，避免把 Git、ledger policy、schema validation 與 CLI parsing 混成單檔。IM 使用它控制 worktree lifecycle；Worker／Issue Solver 只在已指定的 path 內實作：

- 保留 worktree owner、branch/path、structured Scope、檔案 overlap、thread identity。
- 保留本地測試、exact HEAD、log／artifact 與 typed hand-back evidence。
- 幫助 IM／PI 建立、接管、驗證、交回、在 durable PR publication 後釋放 local assets，或在 exact terminal receipt 後安全清理。

它不負責：

- 建立、排序、認領或關閉 GitHub Issue／Project。
- 管理 PR lifecycle、review cycle、merge queue 或 merge permission；registry 的 `published`／`merged` 只是不允許模糊重用的 local disposition。
- 建立本地 backlog、Ticket Factory、Issue lifecycle、Project／board 或批次整合狀態。
- 把 worktree 或 agent 當成產品工作項目。
- 取代 GitHub Actions、CM merge、release、deploy、production approval 或 rollback。

Scope 只回答「本機哪個工作樹可改哪些檔案」；實際 commit 的 changed paths 必須是非空且不重複的 Scope 子集，未觸及宣告中的所有檔案不代表 hand-back 無效；空集合或超出 Scope 的觀測仍 fail closed。Issue acceptance、PR review 與 production approval 各自留在 GitHub 或 domain SOP。local hand-back 是交給 IM 的執行證據，不是第二個交付狀態機，也不等於 PR 已建立。

本地 `worktree_orchestrate gate` 與 typed hand-back 對所有仍存在的 changed Python 檔案，必須執行同一個 pinned formatter contract：`uv run --no-project --python 3.13 --with ruff==0.16.3 ruff format --check <changed Python paths>`；沒有 changed Python 檔案時不產生此 check。這是 local hand-back 的必要證據，remote required check 仍由 GitHub Actions 掌握並保持 authoritative。

same-owner 的 `resume-published`／`reanchor` 必須重用 original published claim 記錄的 exact absolute worktree path；requested target path 與 recorded path 解析後不一致時必須 fail closed。path drift 不會授權建立新 worktree，也不能把同一 owner 的本機 registry／physical ownership 拆成兩份。

尚未建立 durable PR 的 active、owner-bound typed hand-back 若需要在 main 前進後重新對齊，原 owner 只能使用 `reanchor-handback`。它在 local rebase 前、以及 rebase 後 registry claim generation 更新前，以 `git ls-remote origin refs/heads/main` 兩次確認 supplied live SHA；任何遠端主幹讀值缺失或漂移都 fail closed，registry 保持不變，已完成的 rebase 會回復到原 hand-back HEAD。這條命令不測試、不 hand-back、不 push、不建立 PR，也不授權 merge；owner 仍須在同一 registered path 完成 bounded validation 與新的 typed hand-back，才交 PI publish。

branch review queue 只接受兩種 local orphan content blocker：`orphan branch tip is not an ancestor of live origin/main`，以及 `orphan branch tip is not an ancestor of live origin/main and is not patch-equivalent`。remote ref、PR history、owner／registry claim 與 source-incomplete blocker 仍排除；此 queue 只提供 read-only content evidence 與雙重 CAS discard guidance，不授權 mutation。

有效的 typed hand-back 只會釋放它所 seal 的那一個 idle claim 的本機 admission claim：branch/path 必須仍指向乾淨且與 sealed HEAD 相同的 worktree。重新 register、adopt 或 reuse active branch/path 會開始新的 claim，並使先前 receipt 的 admission release 失效；舊 receipt/seal 仍保留作 audit evidence。新的 claim 只有在 fresh hand-back 後才能再次釋放本機 admission，且這不改變 GitHub Issue、PR 或 merge 的狀態。

長任務的本機安全帳本另由 `ops/task_registry.py` 與 `ops/lib/streaming_command.py` 負責。它只記錄 process identity、process group、heartbeat、log path 與 terminal outcome，用來避免誤殺或靜默等待本機程序；它不是 Issue、Project、PR、backlog 或任何產品工作項目的狀態。

branch-audit 的 branch-scoped source problem 會同步投影到該 branch action 的 `source_incomplete` 分類與 blocker；這只改善觀測與下一步提示，不放寬任何 cleanup gate。

`branch-audit` 的每個 `source_problem_action` 另外標示 `actionability`：`blocking` 代表目前仍觀測到相符的 local／remote ref、physical worktree 或 PR，必須先走原 owner／source lifecycle；`quarantined_history` 代表只剩無現存交付資產的 malformed registry history。後者仍保留在完整 audit、並使整體 audit 保持 incomplete，但不應被計成 live WIP、wake、cleanup 或其他 mutation 授權；報告頂層的 `actionable_source_problems` 與 `quarantined_source_problems` 必須能加總回 source-problem action 數量。

`branch-audit.source_problem_actions` 與 `registry_record_problem_actions` 會 additive 保留 malformed raw registry record 的 `record_external_ids`；這些 ID 是 exact Issue／lane correlation 的 audit provenance，不是合法 claim、owner admission、wake、cleanup、takeover 或 dispatch 授權。若 external ID 缺失或來源未能精確綁定，action 仍照原規則 fail closed，不能由 branch 名稱或 reason 猜測 Issue。

`branch-audit` 的 `raw_active_registry_records` 與 metrics 採同一 cardinality 契約：它等於可解析的 active claim，加上 malformed active record 的唯一 `(identity_kind, identity, record_status)` identity。`malformed_registry_records`、`registry_record_problem_actions` 與 `registry_record_problem_status_counts` 則保留每一筆 diagnostic entry；同一 raw record 的多個 reason 不得被靜默刪除，也不得被誤加總成多筆 active record。diagnostic 數與 record cardinality 必須分開閱讀。

## 遷移後的判斷準則

保留真正產品程式碼與測試、backend／iOS 測試入口、GitHub Actions、PR template／required checks、deployment safety wrapper、生產批准／health gate／rollback、CloudKit／資料庫／域名／App Store／TestFlight SOP、docs registry／impact／lint、薄型本地 coordinator，以及長任務 process-safety ledger。凡是只為模擬 GitHub Issue、Project、PR、review、merge 或狀態追蹤而存在的本地描述、資料庫、看板與流程，都不屬於這個模型。
