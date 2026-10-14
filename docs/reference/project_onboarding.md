<!-- doc-meta
tier: reference
authority: SoT
update_trigger: agent-routing-changed
scope:
  - CLAUDE.md
  - docs/reference/delivery_model.md
  - docs/reference/agent_context.md
  - docs/registry.yml
  - ops/context_plane.json
  - ops/context_route.py
  - ops/skill_route.py
  - ops/agent_onboard.py
  - .claude/agents/
  - .claude/skills/
verified_against: 2d9f6fdbebca9fe0f2aa9a790f1498dded80050d
-->

# KG Agent Project Onboarding

這是所有代理的共同入場文件。它只回答「KG 是什麼、誰負責什麼、接下來怎麼載入上下文」；不記錄 Issue、PR、branch 或本地工作項目的狀態。

## 專案概覽

KG 是 Knowledge Graph 英語學習產品：

- `ios/`：SwiftUI BooksAndVocab app、iOS unit/UI/device 驗證。
- `backend/`：FastAPI、資料與服務 API、backend 測試與品質檢查。
- `lab/`：podcast、LLM evaluation 與研究工具。
- `ops/`：測試入口、GitHub Actions 對應的 gate、worktree 協調、release/deploy safety wrapper。
- `docs/`：產品技術細節、domain SOP、政策與文件路由；不是工作項目資料庫。

GitHub 是交付控制面：Issue（`P0`–`P3`／狀態 label 與 IM 的公開認領留言，見 `docs/reference/issue_management.md`）管規劃與排序，branch／worktree 隔離實作，PR 承載變更、review 與驗證，Actions 執行 required checks，`main` 是合併後真相，release/deploy 依安全 SOP 執行。Worker／Issue Solver 只做 local code/test、commit、hand-back；IM 將 exact commit 發布成 PR；CM 控制 Ready admission、queue／merge 與 local `main == origin/main`。本地 coordinator 只處理多 worktree 的 ownership、Scope、本地驗證與交接，不複製 GitHub 的工作狀態。

## Skill 與 docs 的分工

技能不是技術百科，而是「何時載入、先做什麼、什麼不能做、交付什麼證據」的短流程。技術命令、schema、參數、host、API 與故障細節放在 `docs/registry.yml` 指向的 SoT。

目前 skill catalog 分成四類：

- `kg-router`：唯一 bootstrap kernel，負責 onboarding 與 route，不做產品操作。
- control-plane workflow：GitHub 協調、worktree delivery、CR review、DS docs、release command。
- domain specialist：只在明確 intent 觸發時載入，例如 app debug、billing、data analysis、iOS Simulator、production ops、podcast。
- closure：`kg-receipt` 只在需要 hand-back／PR 收尾時載入。

每次只選一個 primary skill；required dependency 必須由 catalog 明確聲明，forbidden skill 不得同時載入。沒有 assignment evidence 時連 specialist 與 domain docs 都不讀。若指定 `specialist-intent`，它必須經 identity／intent／entry 白名單驗證，並取代 generic high-level route，不能由 agent 自行拼接多條 specialist。若 skill 只有長篇命令清單、沒有獨立觸發條件／邊界／輸出證據，應把內容移到 docs、合併或刪除；若同一 skill 同時涵蓋唯讀監控與外部副作用，則拆成不同 route（podcast 即採 pipeline、monitor、publish 三路）。

## 標準身份與邊界

| canonical identity | 主要責任 | 明確不負責 |
|---|---|---|
| CM | 交付協調、Ready admission、merge queue／merge、local main 同步、release/deploy 邊界 | 修改 code／worktree／PR body／registry；代替 IM 發 PR |
| IM | GitHub Issue（label 與公開認領，不用 Project）、派工、worktree lifecycle、push exact commit、PR metadata／readiness、terminal cleanup | 修改 code、替 Worker commit／解 conflict、merge／enqueue |
| Worker | 接受 User／IM 直接指派，依 `dispatch_channel` 討論並完成 branch/worktree、程式碼、測試、local commit 與 hand-back；可唯讀 GitHub（`github:read`） | 任何 GitHub／Issue／PR mutation、push、review、merge、release/deploy |
| Issue Solver | 只消除已進入 GitHub Issue 的工作；接受 IM 傳入的 Issue assignment packet，完成 branch/worktree、程式碼、測試、local commit 與 hand-back；可唯讀 GitHub（`github:read`） | 接受未進 Issue 的直接指派；任何 GitHub／Issue／PR mutation、push、review、merge、release/deploy |
| CR | 審查 PR diff（`pr-review`）或 PR 發布前 lane 的 `base..HEAD` diff（`lane-review`）的正確性、測試、回歸、架構與安全 | 修改 caller worktree、merge、release |
| DS | 判斷文件影響、維護 registry／SoT、執行 docs lint | 建立文件狀態庫、PR lifecycle、merge |
| Release operator | 依批准與 SOP 執行 release、deploy、health gate、rollback | 自行批准 production、繞過 safety wrapper |

完整角色邊界以 [`delivery_model.md`](delivery_model.md) 為準。Onboarding、assignment
與報告一律使用 canonical identity；route manifest 的內部 key 只屬執行層實作，
不是角色、權限或工作狀態，代理不需要記住它們。

## 強制載入順序

每個代理都必須按以下順序啟動，不能跳到 specialist skill 或 domain 文件：

1. **Project**：讀本文件，建立整個 KG 的共同概覽。
2. **Identity**：確認 canonical identity、工作入口與不負責的事情。
3. **Assignment**：CM／IM 確認 GitHub Issue／PR；Worker 接收帶 `dispatch_channel=im|user` 的 direct assignment，Issue Solver 接收由 IM 整理的 Issue assignment packet；兩者都必須取得 acceptance、branch/worktree Scope。
4. **Skill**：由 onboarding kernel 選出唯一 primary skill，再讀 primary 與合法 dependencies；domain specialist 不預載，依 task intent 精準選取。
5. **Domain**：只讀這次工作需要的技術文件，完成驗證並以 local hand-back；PR／必要 SOP 由 IM／CM 收斂。

標準入口：

```bash
./ops/agent_onboard.py \
  --identity '<CM|IM|Worker|Issue Solver|CR|DS|Release operator>' \
  --intent '<delivery|review|docs|release|backend|ios>' \
  --entry '<coordination|merge|direct-assignment|issue|pr-review|lane-review|release>' \
  --specialist-intent '<optional identity-scoped specialist intent>' \
  --evidence-file '<own worktree>/.cache/agent-scratch/evidence.json' \
  --json
```

Evidence 優先用 `--evidence-file`：先以 Write 把 JSON object 寫進 `<own worktree>/.cache/agent-scratch/`（[shell 規則](#isolated-worktree-shell-rules)第 6 項），再傳路徑；inline `--evidence '<JSON>'` 仍可用但與前者互斥，且易被 harness 以引號拒絕。用檔案時 awaiting 的 `retry_command` 沿用同一個 `--evidence-file`，把 `evidence_template` 補完寫回該檔即可重跑。

Evidence 必須逐項提供該 identity／entry 要求的外部證據；缺少時回傳 `status=awaiting-assignment` 並停在 assignment，不會載入 skill 或 domain 文件。只有 `status=ready` 才能繼續；不可自行猜測身份、Scope 或授權。不確定 key 時先加 `--print-evidence-template`（只讀，exit 0）取得該 identity／entry 的全部 required／conditional（如 `dispatch_channel=im` 時的 `dispatch_owner`）／optional key 與可直接複製的命令；awaiting 輸出（exit 3）一次列出全部 `missing`（缺 key／空值）、`unfilled`（仍是範本原樣輸出的 placeholder；自己寫的 `<https://...>` 不算）與 `invalid`，`assignment.retry_command` 保留已填值、待修值換回 placeholder；只剩無效值時改 exit 2，錯誤訊息同樣列出全部無效值。CR 的值另受 `evidence_spec.value_rules` 約束：`pr-review` 的 `GitHub PR` 必須是真 PR（`#N`、`N` 或 `https://github.com/OWNER/REPO/pull/N`，`none`／自由文字一律 invalid），`exact HEAD` 必須是 40-hex；PR 尚未發布的審查改走 `lane-review`（`review branch`、`exact HEAD`、`base SHA`），兩個 SHA 都要 40-hex 且 `git cat-file -e <sha>^{commit}` 在本機成立。

`--specialist-intent` 是可選但受限的精準路由，例如 bug、docs-impact、production-status 或某個 domain pipeline；可用值由 `ops/context_plane.json` 綁定到 identity／intent／entry，並由 skill catalog 驗證。Simulator 只是其中一個 `ios` specialist 範例，不是 onboarding 的特殊中心。

同一個高階 intent 可能因身份與 entry 選到不同 primary skill：CM／IM 的協調入口走 `github-coordination`，Worker／Issue Solver 的實作入口走 `worktree-flow`，iOS 驗證路徑則是 `ios-simulator-verification` 加上 required `worktree-flow` dependency，CR／DS／Release operator 走各自的 review、docs 或 release route。這個 identity-specific mapping 由 `ops/context_plane.json` 驗證，不能靠代理自行把 `delivery` 解讀成某個角色。

## 不可違反的共同規則

- 不直接寫入 `main`；程式碼變更必須經 branch、PR、Actions 與 review 收斂。
- 不在 repo 內建立本地 backlog、Issue／Project／PR lifecycle 或 merge queue。
- route 是上下文與 skill 載入決策，不是 merge、production 或帳號授權。
- 不把 stale seal、WARN、timeout、baseline failure 或缺少 evidence 報成 PASS。
- production 只走 `ops/release.sh`、`ops/devops_kg_safe.sh` 與對應批准／rollback SOP。
- docs 記錄技術細節與操作真相；skill 規範代理如何載入、協調與交接；兩者不互相複製。

<a id="isolated-worktree-shell-rules"></a>

## 隔離 worktree shell 規則

所有 `.claude/agents/*.md` 角色在隔離 worktree 內共用本節，角色檔只引用、不複製。harness 拒絕無法靜態證明留在本 worktree 的命令；被拒不是 gate 結果，改寫命令即可。

1. **一個 Bash 呼叫只下一條 git 命令**，後面不接任何東西：不加 `;`、`&&`、`|`、重導、`echo $?`。
2. **不用 `git -C`**；cwd 就是自己的 worktree。路徑寫字面絕對路徑，命令與參數不含 `$VAR`／`$(...)`（含 `env`、`uv run` 等包裝命令）。
3. **不用 heredoc**；檔案一律以 Write／Edit 建立。commit 訊息寫成 scratch 檔後 `git commit -F <path>`。
4. **不用 `source`、`eval`、`bash -c`，不在 git／sed／gh 外包 for-loop**；多步驟邏輯寫成 scratch 內的 script 檔再執行。
5. **zsh glob 加引號**（`'*.md'`、`'ops/tests/test_*.py'`），否則 no-match 直接失敗。
6. **Scratch 只用 `<own worktree>/.cache/agent-scratch/`**（`.gitignore` 的 `.cache/` 已涵蓋）：evidence 檔、commit 訊息、log、script 都放這裡。session 共用 scratchpad 不寫不刪，其他 agent 會覆寫或刪掉同名檔。
7. **長命令給足 timeout、不 sleep 輪詢**：有 hooks 的 `git commit`、i18n／docs lint、iOS build/test 的 Bash timeout 設 `600000`；要等背景工作用 `run_in_background` 加 Monitor（先 ToolSearch `select:Monitor` 載入）。

## 實作與審查角色的共同交付契約

所有 `.claude/agents/*.md` 的角色共用本節；角色檔只寫自己的 domain 差異，不重複本節。

1. **驗證必須真跑**：只有實際執行過、取得 exit status 的命令才算證據。不得以讀碼推演、舊 log、別人的結果或預期值代替；命令與 exit code 原樣記錄，不得用管線（`| tail`）或合併 stderr 後再讀 `$?`。
2. **TDD 的紅必須是真失敗（僅實作角色）**：實作角色先寫測試並實際跑出紅（失敗原因要對應待修行為，不是 import／語法／環境錯誤），記下紅的命令與 exit code，再最小修復跑綠。無法先紅（純文件、重構等）要在偏離／未解 blocker 說明。CR 與 DS 不寫測試、不修復，只審查與回報。
3. **gate 跑不起來 = BLOCKED，不是 done**：測試 harness、guard、權限、timeout、磁碟預算（如 `ios_*` exit 75）或缺少工具導致必要 gate 無法執行時，停止宣稱完成，成果狀態寫 `BLOCKED`，附完整命令、exit code、guard 輸出的原因。可以 commit 已完成的 code，但成果狀態不得寫 DONE。不得繞過 guard、改用底層命令（裸 `xcodebuild`）或自行改 registry 取代；能獨立跑的 static check 可附上並標明「不取代被擋的 gate」。
4. **lane 登記由 IM 負責**：`ops/ios_ops.sh` 的 writer 類 command（build／test）其 disk guard 與 hand-back 都以 registry 判斷 worktree 是否為受管 lane，須由 IM 以 `ops/worktree_orchestrate.py` 先登記。開工先 `./ops/worktree_registry.py list --json` 確認本 worktree path 在列；若不在或 guard 以「unregistered／disk budget」fail-closed，這是 BLOCKED：不自行 `register`、不改 registry、不等排程碰運氣，回報給 IM 登記後重派。
5. **outcomes 不可預寫**：hand-back 的 validation／outcomes 只能在命令跑完後依實際結果填入；不得先寫「PASS」再補跑，WARN、timeout、stale evidence 一律如實報告，不寫成 PASS。
6. **交回物（實作角色，有 local commit 時）**：乾淨 worktree 加 handoff footer（放在回報最後，不是回報段落），欄位足以讓 IM 對回已登記的 lane 並驗 Scope：branch、worktree path、tip SHA（`git rev-parse HEAD`，commit 後現量）、declared Scope、assignment 參照（Issue／PR external ID，或 direct assignment 摘要）、變更檔案清單（`git diff --name-only <base>..HEAD`，須為 Scope 子集）；assignment 若帶 lane id、claim generation、owner thread，原樣回填。不 push、不開 PR、不寫 GitHub（唯讀可）；PR 由 IM 發布。沒有 commit 的執行（例如已批准的 release execution）不附 footer，改在證據段列 target、exit status 與 health gate 結果。
7. **隔離 worktree 內只下可靜態驗證的命令**：依[隔離 worktree shell 規則](#isolated-worktree-shell-rules)第 1–5 項。
8. **只動自己的範圍**：暫存只放自己的 scratch（同節第 6 項）；`rm`／覆寫只限自己的 worktree 與自己建立的 scratch 檔，session 共用 scratchpad、其他 worktree、主 checkout 一律不寫不刪。
9. **追修從既有 branch 起跑**：publish 會移除原 worktree，原 agent 也無法 resume；follow-up／fix agent 以 `git switch -c <new> origin/<branch>`（未 push 則用 local branch）接續，不從 `main` 重做。
10. **被擋約 10 分鐘內回報**：lock、guard、權限擋住必要 gate 時只做有上限的等待；約 10 分鐘仍未解即依第 3 項回報 BLOCKED 並附完整輸出，不輪詢一小時。
11. **固定回報骨架**：與根 `CLAUDE.md`「回報格式」一致，最終訊息一律以下列四段、依序、每段不可省略（無內容寫「無」）：

```text
成果: 狀態 <依角色，見下> — 一句話結論（BLOCKED 要寫被擋的 gate）
當下驗證證據: 每條命令一行「命令 → exit N」；紅／綠分開列；未跑的 gate 明列為 NOT RUN 與原因
偏離／未解 blocker: 與指派／計畫不同處、edge case、未解 blocker、工具／文件／guard 摩擦與可重現步驟；無則寫「無」
已替使用者做的決定: 替使用者／IM 做的決定，每項一句理由
```

成果狀態詞彙依角色：

| 角色 | 狀態 | BLOCKED 條件 |
|---|---|---|
| 實作角色 | DONE／PARTIAL／BLOCKED | 必要 gate 無法執行（第 3 項） |
| CR | approve／request changes／comment／BLOCKED | required checks 缺失（`pr-review`）、非目前 exact HEAD、gate 無法執行或 PR／lane commit 無法讀取；不得 approve |
| DS | synced／gap／BLOCKED | docs lint／registry／coverage 無法執行或紅燈未解；不得 synced |

CR 與 DS 不 commit、不改 caller worktree，沒有 handoff footer；證據段列所跑命令與 exit status。審查對象依各自 assignment 證據標示於證據段：CR 一行「審查對象 exact HEAD: <SHA>」與 required checks 來源；DS 一行「審查對象: PR diff 範圍」與 changed docs（PR 已改動的文件）。DS 只審查並指出需同步的 SoT，修改由 PR 作者或 IM 在同一 PR 套用。
