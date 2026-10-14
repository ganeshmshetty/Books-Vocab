---
name: kg-docs-control-plane
description: "新增、修改或退役 KG 文件的閉環 workflow：判定 SoT／owner、把實測流程固化成可重現 docs、同步 registry／metadata／impact／lint，並用 cold-agent dogfood 驗證；不保存產品工作狀態。"
---

# Documentation change control

這是所有文件變更的唯一 workflow skill。它不只是跑 lint，也不把一次性命令抄成長篇手冊；它把「實測得到的穩定知識」轉成一個有 owner、authority、trigger、驗證證據與失敗行為的文件契約。

## Authority order

1. `docs/registry.yml`：文件 ownership、trigger、source hints 與 agent-facing paths。
2. `docs/reference/*`：產品、技術、schema、host 與 feature boundaries。
3. `docs/sop/*`：可執行操作流程。
4. `docs/policy/*`：安全與不可逆邊界。
5. generated／snapshot／archive／legal：依各自 metadata 與生成契約處理。

## Standard flow

```bash
./ops/agent_onboard.py --identity DS --intent docs --entry pr-review --evidence-file '<own worktree>/.cache/agent-scratch/evidence.json' --json
./ops/docs_impact.py --files <path...>            # add --explain only to inspect ! suppressions
./ops/docs_impact.py --surface-scan '<regex>'     # missed-reference check (false negatives)
./ops/docs_lint.sh
./ops/docs_lint.sh --registry
./ops/docs_registry_coverage.py
```

Impact 只是候選；依 registry trigger 與實際 diff 決定是否同步。文件更新與 code 同一 PR 交付，`verified_against` 必須是可達且已存在的 commit。generated entry 必須有 generator 與以自身 path 為目標的 check。

## Add／modify／retire decision

1. **新增**：先確認現有 SoT 不足；選唯一 `reference`／`sop`／`policy`／`runbook` 類型，寫 `doc-meta`，再把 owner、trigger、source hints 登錄到 `docs/registry.yml`。
2. **修改**：先保存實測 command、exit status、exact HEAD、input／device／artifact identity；只把可重現且會再次使用的規則寫入 docs。一次性的 log、聊天、Issue／PR 狀態留在交付證據，不進 docs。
3. **退役／刪除**：先 `rg` 全 repo 引用，確認沒有 agent route、registry、script、workflow 或 SOP 依賴；需要保留歷史理由就移到明確 `archive`／`snapshot`，否則刪除並讓 docs lint／link audit 證明沒有 dangling reference。
4. 文件與 code／test 必須同一 PR；不能先把「可能會做」寫成流程，再補實作。

## 固化實測流程（例如 Simulator）

執行 agent 與文件 agent 分開看待：

1. Worker／Issue Solver 先依自身 onboarding 在 branch/worktree 跑通流程，取得最小穩定 evidence；不在執行中自行宣稱 docs 已成為 SoT。
2. PR description／handoff 明確列出「觀察到的穩定契約、命令、前置條件、失敗分類、artifact provenance、希望固化的文件 surface」。
3. DS 以 `pr-review` 進場，讀 PR diff 與 evidence，將穩定契約寫入對應 SOP／reference；skill 只保留 route、hard stop、輸出與 hand-off。
4. DS 跑 docs impact／registry／lint，接著用無先驗 agent 按 `docs/sop/docs_dogfood.md` 重走 onboarding 與最小流程。dogfood 若需要猜 command、authority、device、artifact retention 或 failure meaning，文件不得封存為完成。
5. PR review 必須同時看到 source evidence、文件 diff、dogfood 結果；缺任一項就是 `partial`／`BLOCK`，不是 PASS。

## Agent-facing surface

改 CLI、flag、env、schema、ops script、skill、workflow 或其他 agent-facing surface 時，使用 registry 的 path list 與 `--surface-scan` 證明引用已同步。不要建立第二份人工清單。

文件新增／修改的完成定義是：唯一 SoT 已選定、metadata／registry 對齊、實測證據可追溯、失敗與副作用邊界明確、docs gates 綠、cold-agent dogfood 通過。`docs_lint` 綠但沒有 dogfood，不代表流程已固化。

## Output

回報實際 impact command、候選文件、決定同步的文件、docs gate 結果與仍存在的 unrelated audit debt。文件沒有語義影響時明確寫 `changed docs: none`。
