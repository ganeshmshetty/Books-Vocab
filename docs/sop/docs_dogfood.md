<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - docs/
  - docs/reference/project_onboarding.md
  - .claude/agents/
  - .claude/skills/
  - .claude/skills/catalog.json
  - ops/agent_onboard.py
  - ops/context_plane.json
  - ops/context_route.py
  - ops/skill_route.py
  - ops/docs_impact.py
  - ops/docs_lint.sh
verified_against: 2d9f6fdbebca9fe0f2aa9a790f1498dded80050d
-->
# Docs Dogfood SOP

目的:用「完全無知的下一個 agent 能不能低成本做對」驗證 onboarding、身份邊界、skill loading 與 docs routing，不驗證作者意圖。dogfood agent 只做讀取、推理、命令驗證與報告，不改檔、不寫 GitHub、不建立 worktree、不執行 release／deploy。

## Mandatory cold start

測試 harness 不預先告知 role、intent、SoT 或 skill 名稱；只提供 repo path、任務與不可變更限制。agent 必須先從 assignment 選出 canonical identity、intent、entry，執行：

```bash
./ops/agent_onboard.py --identity '<identity>' --intent '<intent>' --entry '<entry>' [--specialist-intent '<identity-scoped specialist>'] --evidence-file '<own worktree>/.cache/agent-scratch/evidence.json' --json
```

只有 `status=ready` 才能讀 `load_order` 後續的 skill／domain 文件。必須觀察 project → identity → assignment → skill → domain 五個 phase；缺少 evidence 時先停在 `awaiting-assignment`；若 identity、入口、PR／Issue、Scope 或 fresh evidence 不足，agent 應停止並回報，不得以預設 `delivery` 繞過（maintenance 的 audit-only 例外見下節）。

## Audit-only DS evidence（maintenance 專用）

maintenance 是純文檔系統審計，沒有 PR、diff 或真實 changed paths，因此「沒有 PR／changed paths 就停止」的規則對此角色**不適用**。它的 DS evidence 必須是明確標示的 placeholder；這組值不是真實 assignment，不得偽裝成真實 PR 或 changed paths：

- `GitHub PR diff`：`dogfood placeholder, no real PR (audit-only), not a real assignment`
- `changed paths`：`docs/reference/tech_index.md (placeholder changed-path set for audit-only dogfood)`

兩個值都不得含 `<...>`（那會被 onboarding 判為未填）。這組 evidence 只讓 onboarding 進入 `status=ready` 以供審計閱讀，不代表任何文件已變更、不得據以判定 synced；findings 只回報給 harness，不建立 Issue／PR／worktree 狀態。

## 測試任務

每個 agent 選一個角色執行:

| 角色 | 任務 | 必查入口 |
|---|---|---|
| backend-change | 假設要改 `backend/src/kg/routers/vocab.py`,判斷需同步哪些 docs | `docs/registry.yml`, `ops/docs_impact.py`, `docs/reference/tech_index.md`, `docs/sop/doc_sync.md` |
| ops-change | 假設要改 `ops/devops_kg_safe.sh`,判斷 docs gate 會提示什麼,哪些提示是必要/噪音 | `docs/registry.yml`, `ops/docs_impact.py`, `docs/policy/safety.md`, `docs/sop/deploy.md`, `docs/sop/debug.md` |
| docs-tooling-change | 假設要改 `ops/docs_lint.sh`,判斷 impact hints 是否足夠精準;噪音用 `--explain` 追 `!` 抑制來源,漏報用 `--surface-scan PATTERN` 掃 agent-facing surface | `ops/docs_impact.py` (含 `--surface-scan`), `docs/registry.yml`, `docs/sop/doc_sync.md` |
| ios-feature-change | 假設要改 `ios/BooksAndVocab/Models/Book.swift`,判斷該查哪些 feature boundary / snapshot | `docs/registry.yml`, `docs/reference/tech_index.md`, `docs/reference/feature_boundary/bookshelf.md` |
| simulator-solidification | 假設已跑通一個 Simulator 流程，要求把它固化成 SOP／skill，驗證執行 agent 與 DS 是否能分工完成閉環 | `ios-simulator-verification`、`docs/sop/ios.md`、`docs/sop/doc_sync.md`、`docs/registry.yml` |
| maintenance | 只看文檔系統本身(audit-only，無 PR)，判斷新 agent 如何知道該跑哪些 gate；先走 onboarding，DS evidence 依下節 audit-only 慣例，再按 DS/docs route deep dive | `CLAUDE.md`, `docs/reference/project_onboarding.md`, `docs/registry.yml`, `docs/sop/doc_sync.md` |

## 必跑命令

dogfood agent 只跑 onboarding，並依 `status=ready` 的 `load_order` 載入文件；它不直接
呼叫 maintainer-only route CLI。harness／DS 在收集 agent 結果後，再跑 route contract 與
docs gates；兩者分開，避免把診斷命令誤當成 agent loader：

```bash
./ops/agent_onboard.py --identity DS --intent docs --entry pr-review --evidence-file '<own worktree>/.cache/agent-scratch/evidence.json' --json
# maintainer / harness only
./ops/context_route.py validate --json
./ops/skill_route.py validate --json
./ops/skill_route.py route --diagnostic --intent skill-doc-sync --json
./ops/docs_lint.sh
./ops/docs_lint.sh --registry
./ops/docs_lint.sh --audit
./ops/docs_registry_coverage.py
./ops/docs_impact.py --surface-scan '<missed-reference regex>'
```

`docs_impact.py --files ...` 是單一檔案改動的精準樣本；`--explain` 只列出被 `!path` / `!glob` 抑制的 broad 命中（registry 無 `!` 排除時為空），不能揭露漏報。查漏報（該被提到卻沒被 impact 命中的引用）用 `--surface-scan PATTERN` 掃 registry 的 agent-facing surface。`match_type=exact|broad|suppressed-partial|suppressed` 是第一層理由欄位；若仍有有效 impact，`IMPACT` 會帶 `excluded_changed=` / `excluded_by=`。`./ops/docs_lint.sh` 反映目前 checkout 的 range、staged、unstaged 與 untracked 變更；若沒有選到任何文件也會明確報告。`./ops/docs_registry_coverage.py` 的輸出分成 active 與 historical；historical 只供健康盤點，不是日常 gate debt。回報時分開判讀 impact hints 與角色真正需要的文件。

## Simulator 流程固化測試（代表性 fixture，不是唯一 domain）

這個 scenario 不是要求 dogfood agent 碰 production 或保留 raw video；它驗證的是「一個已完成的 Simulator 實測能否被轉成下一個 agent 可重跑的規範」。

1. 執行 agent 以 Worker／Issue Solver 身份 onboarding，讀 `ios-simulator-verification` 與 `docs/sop/ios.md`，只回報 exact command、branch／HEAD、UI World／dataset SHA、selector、Simulator lease／UDID、verdict、log／xcresult／visual evidence，以及失敗分類。
2. DS 以 `DS + docs + pr-review` onboarding，讀 PR diff、上述 evidence、`docs/sop/doc_sync.md`，判斷是修改 iOS SOP、Simulator skill reference、registry，還是根本不應新增文件。
3. DS 只固化穩定契約：觸發、前置、唯一入口、pass／fail／inconclusive 判定、artifact TTL、批准／副作用邊界與 hand-off；不複製一次性 log 或當前 UDID。
4. DS 跑 docs impact、registry／metadata／lint，再由完全無先驗 agent 只看 route output 重走最小命令選擇。若 agent 需要問作者「要跑哪個 selector、什麼叫成功、raw artifact 是否要保留」，dogfood 為 `partial`，不得封存。
5. Simulator PASS 不能升格為真機、TestFlight、App Store 或 production PASS；若文件混淆，直接 `BLOCK`。

同一套測試要套用到其他 domain：把 Simulator 的 selector／UDID／UI World 換成 backend 的 API／fixture／DB schema、deploy 的 target／health gate／rollback candidate、podcast 的 workspace／artifact／publish verification，或 billing 的 time window／provider invoice／baseline。不可因某個 domain 的證據格式不同，就退回作者口頭解釋。

## 回報格式

回報必須使用下列格式:

```text
role: <role>
identity: <canonical identity>
entry: <direct-assignment|issue|pr-review|...>
task_result: pass | partial | fail
time_to_first_authoritative_doc: <short estimate>
onboarding:
- status: <ready|blocked>
- route_schema: <schema>
- primary_skill: <skill>
- loaded_phases: <project,identity,assignment,skill,domain>
commands:
- <command> => <rc/result summary>
loaded_sources:
- <path>
unexpected_actions:
- <none, or command/action that violated the no-write boundary>
findings:
- severity: block | fix | noise | nit
  evidence: <file/command output>
  issue: <concrete issue>
  suggested_change: <specific docs/script/registry change>
missing_links:
- <what was hard to find, or none>
confidence: high | medium | low
```

## 判準

- **pass**:能先完成 onboarding，在 10 分鐘內定位權威 docs、跑對 gate、辨識 doc-sync 範圍，route 不含 forbidden skill，且沒有 block/fix 級問題或副作用。
- **partial**:能完成任務,但有噪音、入口不明、命令輸出需要人工猜測。
- **fail**:找不到權威 docs、gate 輸出誤導、或文檔之間互相矛盾。

dogfood 結果要彙整成「問題 → 證據 → 修法 → 優先級」,再決定是否修改 registry/docs/script。
