# KG Workspace Guide

KG 是 Knowledge Graph 英語學習產品：`ios/` 是 SwiftUI BooksAndVocab app，`backend/` 是 FastAPI 與官網，`lab/` 是 podcast／評估工具，`ops/` 是測試、部署與安全入口。

交付角色與邊界的唯一 SoT 是 [`docs/reference/delivery_model.md`](docs/reference/delivery_model.md)；本檔只保留啟動時必需的摘要。

每個代理的第一個工作步驟是 onboarding：先用 `ops/agent_onboard.py` 讀取 [`docs/reference/project_onboarding.md`](docs/reference/project_onboarding.md)，確認 canonical identity、intent、entry 與不負責的事情；只有 `status=ready` 後，才依輸出載入 skill 與 domain docs。不要自行猜測角色或權限。

## GitHub-native 心智模型

GitHub 是交付控制面；本機工具只補足多 worktree 與本機驗證，不另建一套產品管理系統。

| 心智模型 | GitHub / 本機對應 | 真正 owner |
|---|---|---|
| 想做什麼、為什麼做、完成判準 | GitHub Issue（需要規劃時） | GitHub Issues |
| 優先序、狀態、認領 | Issue 的 `P0`–`P3`／狀態 label 與 IM 的公開認領留言（無 Project、無 assignee；見 [`issue_management.md`](docs/reference/issue_management.md)） | GitHub Issues |
| 一次實作的隔離環境 | branch + local worktree | Git / `ops/worktree_registry.py` |
| 變更、討論、review、驗證結果 | Pull Request | GitHub PR + review |
| 自動檢查與 required checks | GitHub Actions | `.github/workflows/` |
| 合併後的產品主幹 | `main` | GitHub protected branch |
| 發版、批准、rollback | release／部署 SOP | `ops/release.sh` + `ops/devops_kg_safe.sh` |

有兩條入口：直接指派走 `User／IM → Worker → branch/worktree → local commit + hand-back → IM PR`；需要規劃、排序或追蹤的工作走 `IM → Issue → Issue Solver → branch/worktree → local commit + hand-back → IM PR`。兩條路徑都在 `PR → Actions + CR + DS → CM merge → main` 收斂。Worker／Issue Solver 無 GitHub 寫入權（唯讀 gh 可），認領由 IM 公開留言；IM 發布 PR；CM 控制 admission／queue／merge 與 local `main == origin/main`。Issue、PR 的狀態不在 repo 內複製；本地 registry 不存工作項目生命週期，也不決定合併。

## 本地 coordinator 的窄責任

`ops/worktree_registry.py` 只記錄本機工作樹是否被誰使用、structured Scope、thread identity、branch/path、hand-back 與驗證摘要。IM 使用 `ops/worktree_orchestrate.py` 建立／接管 worktree、檢查 Scope overlap、執行本地 gate、保存 evidence、交回或安全移除工作樹；Worker／Issue Solver 不寫 GitHub（唯讀 gh 允許）。

GitHub 外部 ID 只作 opaque reference；Issue、PR 的生命週期與合併決定都在 GitHub 完成。

## 開發規則

1. 開始前先讀本檔與對應 SoT；涉及陌生 endpoint、schema、env、release 或安全邊界，先查 `docs/registry.yml` 指向的文件。
2. 實作採 TDD：先紅、最小修復、再綠；每個獨立變更保持可 review、可回滾。
3. 分支與 worktree 要有明確 Scope；同一檔案不可被兩個 active worktree 同時認領，唯一例外是 `ops/lib/worktree_scope.py` 的 `SHARED_SCOPE_FILES`（註冊／索引檔與 per-locale 字串目錄 `Localizable.strings`〔重複 key、缺 key、locale parity 由 merge-group 的 strict i18n lint 在合併樹上重驗〕，理由見 `docs/reference/delivery_model.md`）。跨 session 協調以 registry／GitHub PR 為準，不靠聊天紀憶。
4. PR 必須讓 CR 能回答：這是 direct assignment 還是 Issue work、改了什麼、為何改、如何驗證、是否有安全或文件影響。review、required checks 與 DS 的文件判斷留在 PR；不要把它們重新寫成 repo receipt。
5. 遇到工具摩擦先修工具或記錄可重現 blocker，不以手工繞路掩蓋流程缺陷。

## 常用入口

```bash
./ops/agent_onboard.py --identity '<identity>' --intent '<intent>' --entry '<entry>' [--specialist-intent '<identity-scoped specialist>'] --evidence '<JSON object containing the required assignment evidence>' --json
# maintainer cross-validation only
./ops/context_route.py validate --json
./ops/skill_route.py validate --json
./ops/worktree_registry.py list --json
./ops/worktree_orchestrate.py --help
./ops/docs_impact.py --files docs/reference/tech_index.md
./ops/docs_lint.sh
./ops/test_ops.sh worktree
```

Python 一律由 `uv` 管理；backend 測試從 `backend/` 執行 `uv run --locked python -m pytest`。iOS build/test 走 `./ops/ios_ops.sh`，不要直接拼底層命令取代既有安全入口。

## 不可省略的產品與安全邊界

- 真正產品程式碼與測試是主要資產；不要因整理交付工具而刪除它們。
- 生產操作只走 `ops/devops_kg_safe.sh`、`ops/release.sh` 與其 SOP；批准、health gate、rollback 必須保留。
- 網域、CloudKit、資料庫、felix 常駐機、App Store／TestFlight 與 backend deployment 的領域流程，以 `docs/reference/host_topology.md`、`docs/sop/deploy.md`、`docs/sop/ios.md`、`docs/sop/backup*.md` 為準。
- iOS user-facing 字串走既有 i18n lint；UI 修改先讀 `docs/sop/ui-design.md` 與對應 feature boundary。
- 文件控制面只保留 registry、impact、lint 與必要的 SoT；文件不是交付資料庫。

## 回報格式

回報只需要四件事：成果、當下驗證證據、偏離／未解 blocker、已替使用者做的決定。涉及不可逆生產動作、帳號持有人專屬批准、預算或產品策略時才停下來請示；其餘技術判斷自行完成。
