<!-- doc-meta
tier: runbook
authority: derived
update_trigger: manual
scope:
  - devops.sh
  - ops/devops_kg_safe.sh
  - ops/lib/devops_run_guard.sh
  - ops/lib/hermetic_ops_test.sh
  - ops/test_devops.sh
  - ops/test_ops.sh
verified_against: f3987a05c8f9a732ed810555e1a3ee4b6324465a
-->
# Incident 2026-10-09：ops 測試刪除 felix 正式資料目錄（P0）

一個 ops 測試的「必須被擋」負向對照，在 guard 有洞時被轉給**真的** `devops.sh`，經 ssh 在 felix 上執行
`rm -rf /Users/chenliangyu/kg-data`，刪光所有用戶資料。資料已從備份還原；本文件記錄時間線、根因、
監控為何沒抓到、以及讓它不可能重演的分層修復。政策 SoT 是 [`docs/policy/safety.md`](../../policy/safety.md)，
部署與備份還原細節見 [`docs/sop/deploy.md`](../../sop/deploy.md)、[`docs/sop/backup_restore.md`](../../sop/backup_restore.md)。

## 時間線（UTC）

| 時間 | 事件 |
|---|---|
| 2026-10-09 03:04 | 最後一份可用備份 `data/2026-10-09.tar.gz` 完成（排程 launchd `com.kg.backup` → S3；sha256 `7e81425c…5734b61`）。 |
| 2026-10-09 12:27:42 | **`~/kg-data` 被刪除**（正式資料目錄 `/Users/chenliangyu/kg-data` 全部清空）。 |
| 2026-10-09 12:27 – 15:23 | 無人察覺（約 2 小時 56 分）。 |
| 2026-10-09 15:23:43 | 第一個用戶可見的 HTTP 500。 |
| 2026-10-09（首個 500 之後） | 由**用戶回報**得知，不是監控告警。 |
| 2026-10-09 ~16:11 | 從 `data/2026-10-09.tar.gz` 還原完成，服務恢復（刪除後約 3 小時 43 分；首個 500 後約 47 分）。 |

## 資料遺失窗

還原點是 03:04Z 的每日備份，因此 **03:04Z – 12:27Z 之間發生在伺服器端的寫入全部遺失**（備份頻率為每日一份，
刪除前的最後一刻狀態沒有更近的還原點）。伺服器獨有的寫入（該窗口內的新用戶、訂閱／額度變動、server 端產生的資料）
需另行對帳；客戶端本地資料能否回補不在本文件判定範圍。

## 根因

`ops/test_devops.sh` 的 BYPASS 迴圈（「must be blocked」的負向對照）以**沒有 stub base** 的方式呼叫 safe wrapper：

```bash
output=$(bash "$WORKSPACE/ops/devops_kg_safe.sh" run "$cmd" 2>&1 || true)
echo "$output" | grep -q "blocked" && ok ... || fail_t ...
```

當 guard **沒有**擋下某個命令，wrapper 會把它原樣轉給預設 base，也就是真的 `devops.sh run`，它經 ssh 在
production felix 上執行（oscar 對 felix 有免密碼 ssh）。測試以為自己在驗證「會被擋」，實際上是在**賭 guard 沒有洞**，
輸了就是真刪。放行的 SAFE 迴圈（第 270 行）有 `KG_DEVOPS_BASE=/usr/bin/true`，BYPASS 迴圈與其上方的
blocklist 檢查（`docker system prune`、`compose down -v`、各種 `rm` 變體）沒有。

觸發：#2753 的一條 TDD lane 在 BYPASS 加了 `'rm -rf /Users/chenliangyu/kg-data@macOS home path'` 並跑紅燈階段。
當時 guard 還沒有 `/Users` 規則，命令通過 guard、真的在 felix 上執行。**紅燈階段本來就預期「guard 不擋」**——
所以這類測試的紅燈就等於對 production 執行該命令。

結構性問題：「被擋」的判準是輸出含 `blocked` 這個字，而不是「命令從未到達 base」。判準說謊（測試輸出是 `✗ NOT BLOCKED`
的同時，命令已經執行完）。

### 同時發現的 guard 缺口

事故後的探測顯示以下命令當時都通過 guard（保護只比對路徑字面，不比對受保護的**名稱**）：

- `find /Users/chenliangyu/kg-data -delete`
- `rm -rf ~chenliangyu/kg-data`（`~user` 形式）
- `rm -rf /Users/chenliangyu/kg-prod/backend`（正式程式碼目錄）
- `container-run 'rm -rf /app'`（容器內 `/app` 本身）
- `container-run 'cd /app && rm -rf data'`（`cd` 之後的相對路徑）

## 為何監控沒抓到

reconcile 的健康探測拿到的是 **429 或 401**（不是能反映資料狀態的 2xx），而且它**不檢查資料目錄**，所以資料目錄消失
沒有觸發任何告警。只有真的讀寫用戶資料的請求才會回 500，而這類請求要等用戶實際使用時才出現（第一個 500 在 15:23:43Z）。
`infra_health` 雖有 `data_dir_mb` 讀數，但沒有任何告警規則會對「資料目錄突然變空／消失」報警。

## 修復：分層（任何一層單獨都足以擋下本事故）

1. **Harness 層（`ops/lib/hermetic_ops_test.sh`）**：`ops/test_ops.sh` 與獨立執行的 `ops/test_devops.sh` 一律
   `export KG_OPS_TEST=1`、在 PATH 前面放 deny shim（`ssh` `scp` `sftp` `rsync` `aws` 一律印
   `FORBIDDEN: network/production access from an ops test: <argv>` 到 stderr 並 `exit 97`）、把
   `KG_SSH_CMD`／`KG_SCP_CMD`／`GIT_SSH_COMMAND` 指到 deny stub。每次拒絕還會寫入 `KG_OPS_TEST_TRIPWIRE_LOG`，
   `test_ops.sh` 在跑完後只要該檔非空就**判整個 run 失敗**——即使某個測試用 `|| true`、`$(...)`、`2>/dev/null`
   吞掉了退出碼。真正需要假 ssh／rsync／aws 的測試自備 stub 排在 PATH 更前面，不受影響。
2. **測試層（`ops/test_devops.sh`）**：`KG_DEVOPS_BASE` 預設為會留痕的 recording stub，檔內每個 wrapper 呼叫都落在
   stub base；需要真 `devops.sh` 邏輯的測試要明確傳 `KG_DEVOPS_BASE="$KG"` 並搭配假 `KG_SSH_CMD`。
   「被擋」的定義改為：wrapper 非零退出 **且** 輸出含 `✗ blocked` **且** base trace 沒有任何條目
   （`expect_blocked_before_base`）。放行的對照則要求命令**真的抵達** stub base（正控）。
3. **Transport tripwire（`devops.sh`）**：`KG_OPS_TEST=1` 時，`run_remote`／scp／`cmd_backup` 的 rsync／`cmd_ssh`／
   部署後 smoke 的 curl 只要 transport 是真的（`KG_SSH_CMD`／`KG_SCP_CMD` 未設，或指到真的 ssh／scp／rsync／curl 二進位）
   就 `exit 97` 並大聲報錯，不連線。測試自備的 `#!` 腳本 stub 與 `/usr/bin/true` 不受影響；`KG_OPS_TEST` 未設
   （營運者正常使用）時為 no-op。由 `ops/tests/test_devops_transport_tripwire.sh` 證明。
4. **Guard 強化（`ops/lib/devops_run_guard.sh`）**：受保護的是**名稱**——`kg-data`、`kg-prod`、`/app/data`、`/app`
   本身——任何破壞性動詞（`rm` `rmdir` `unlink` `mv` `truncate` `shred`、`find -delete`、`git clean`、`rsync --delete`
   或以其為目的地、`cp`／`install`／`ln` 的目的地、`tar x`、`chmod`／`chown -R`、`tee`、`>`／`>>`、`dd of=`、
   `sed -i`、sqlite3 寫入、python `rmtree`／`os.remove` 等）只要引用它們就擋，不論路徑寫法：絕對、`~`、`~user`、
   `$HOME`、相對、`..`、glob（`kg-d*`、`~/*`）、brace expansion，或是前一個子句 `cd` 進受保護目錄後的相對路徑。
   `container-run`／`migrate-run`（以及任何 `docker exec`）的 cwd 是 `/app`，所以相對路徑 `data` 同樣視為受保護。
   無法解析的變數目標（`rm -rf $DATA_DIR`）直接拒絕。上述五個缺口與事故命令全部成為 BYPASS 項目。
   SAFE 清單照常通過，包括對這些目錄的讀取（`ls`、`du`、`tar czf`、`sqlite3` 讀、`git log`）。
5. **Base 也擋**：同一個 predicate 由 `ops/devops_kg_safe.sh` 與 `devops.sh`（`cmd_run`／`cmd_container_run`／
   `cmd_migrate_run`，guard 排在 `cmd_backup` 之前）共用，safe wrapper 不再是唯一防線；直接呼叫
   `devops.sh run …` 或把 wrapper 指到別的 base 都會撞上同一個檢查。
6. **Lint（`ops/tests/test_ops_hermetic_lint.sh`）**：掃描 `ops/**/test_*.sh` 與 `ops/tests/*`，任何提到
   `devops.sh`／`devops_kg_safe.sh` 的測試檔必須自己呼叫 `hermetic_ops_test_init`（.py 則引用 `KG_OPS_TEST`）、或列入「只當文字讀」的 TEXT_ONLY allowlist（並重新驗證沒有直接執行）；
   stub seam（`KG_DEVOPS_BASE=`／`KG_SSH_CMD=`）已於 #2922 移出合法替代方案，只能作為 init 之後的補充設定，不能單獨滿足 lint；
   另驗證 `test_ops.sh` 先初始化再跑 group、`test_devops.sh` 先封住 base 再碰 wrapper。scanner 本身有正反控制。

## 寫 ops 測試時的規則

- 不要為了「驗證會被擋」把命令送到真的 base。需要 base 就用 recording stub，並斷言 trace 為空。
- 「被擋」不能只看輸出文字；要斷言副作用不存在（base 沒被呼叫、transport 沒被呼叫）。
- 紅燈階段同樣受限：先建好 shim／stub base，再加新的 BYPASS 項目、再跑紅燈。
- 測試需要假 ssh／rsync／aws 時，自備 `#!` 腳本 stub 並排在 PATH 前面，或設自己的 `KG_SSH_CMD`。
- 看到 `FORBIDDEN: network/production access from an ops test` 或 exit 97，代表測試試圖碰外部——修測試，不要繞過 shim。

## 遺留風險

- guard 仍是 deny-list，不是沙箱：`eval`／base64／變數間接，以及不經動詞就能刪資料的直譯器
  （`sqlite3` 以 `;` 分句後的 `DELETE`、`python` 的 `open(...,'w')`）看不穿；真正的第一道牆是「測試不碰 production」。
- 監控缺口**未在本 lane 補**：reconcile／infra_health 仍不會對「資料目錄消失或突然變空」告警。需要另開工作項：
  對 `~/kg-data` 的存在、`users/` 目錄數與 `data_dir_mb` 下降設告警，並在 reconcile 健康探測加入資料目錄檢查。
- 備份頻率仍是每日一份；RPO 最壞 24 小時。是否縮短（或加入寫前快照）是產品／成本取捨，另行決定。
- 直接 `ssh` 到 felix 執行 `rm`（不經 devops）不在任何 guard 之內。
