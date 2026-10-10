<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - ops/kg_backup.sh
  - ops/launchd/com.kg.backup.plist
  - ops/cron/kg-backup.cron
verified_against: f69f5e53d6b2ac6e3b6f96febb8456a7ed58b477
-->
# Backup / Restore SOP

> 「沒做過 restore 演練 = 薛丁格的 backup」。本文是 KG 生產 SQLite 資料從 AWS S3 異地 backup **完整還原**的 step-by-step。事故當下下一個 agent 直接讀這份即能恢復服務,**不需問人**。
>
> **過渡狀態（2026-06-15 起）**：正式站遷到家用常駐機 `standby`（macOS / OrbStack docker）。**現役 data 目錄 = `~/kg-data/`（standby；2026-06-16 移出 git worktree，原 `~/project/kg/backend/data/`）**，不再是 Lightsail `/home/ubuntu/knowledge_graph_api/data/`。S3 backup 由 standby launchd（`ops/launchd/com.kg.backup.plist`）跑同一支 `ops/kg_backup.sh`，bucket / IAM / 物件格式不變。**§2 標準流程下方已給 standby 指令**。
>
> **⚠ Lightsail instance 已於 2026-06-19 terminate**：原「快速回滾到 Lightsail」路徑**不再可用**（無 instance、無 elastic IP、無 STOP 容器可 `up`）。§3 的 Lightsail 內容**僅供「從零重建」參考**，不再是現成回滾目標。現役唯一防線 = AWS S3 異地 backup（§2），host 故障時於可達 host（standby 或新建機）上重建 + 拉 S3。

---

## 0. 受 backup 涵蓋的內容

現役（standby）：`~/kg-data/`（2026-06-16 移出 git worktree）。（舊 Lightsail data `/home/ubuntu/knowledge_graph_api/data/` 隨 instance 2026-06-19 terminate 一併消失，僅 S3 backup 留存。）內容：

| 子目錄 | 內容 |
|---|---|
| `users/<user_id>/cards.db` | 詞庫 / KG / 學習紀錄 |
| `users/<user_id>/review_events.db` | TodayReview 複習事件 |
| `users/users.json` | user index |
| `podcasts/<series_id>/...` | podcast 音頻 + metadata(Track B 遷移完成後改由 S3 直接保留,本 backup 仍含過渡期 disk-mode 資產) |
| `judge_log.db` | 評審 log |

**不含**:`.env`、`certs/`、`compose.yml`、docker images(這些由 git + scp 流程恢復)。

---

## 1. Backup 配置(現況，2026-06-15 起 standby)

| 項目 | 值 |
|---|---|
| Bucket | `kg-backups-prod-967512079054` |
| Region | `ap-northeast-1` |
| Versioning | Enabled + **MFA Delete**(由 root user 設) |
| Public access | Block all |
| Encryption | SSE-S3 (AES256) |
| Lifecycle | **無**(AWS 強制 lifecycle 與 MFA Delete 互斥)— backup 永久累積,要清舊版需手動走 root+MFA(見 §7) |
| Key 格式 | `data/YYYY-MM-DD.tar.gz`(UTC 日期) |
| **排程（現役）** | **standby launchd `~/Library/LaunchAgents/com.kg.backup.plist`** → 每天 11:00 台北(= UTC 03:00)。源檔 `ops/launchd/com.kg.backup.plist` |
| **排程（已停用）** | 舊 Lightsail `/etc/cron.d/kg-backup`（cron）— 遷移後停用 |
| Script | `ops/kg_backup.sh`（standby/Lightsail 共用，靠 `KG_DATA_DIR`/`KG_BACKUP_BUCKET`/`KG_BACKUP_LOG` env 參數化，無需改 code） |
| DB 擷取 | backend 以 WAL 模式常駐連線，已提交 rows 可能只在 `<db>-wal`。每個 `*.db` 先以 SQLite online backup（`.backup`，不 checkpoint、不建立 live DB）快照進 mktemp staging 並要求 `quick_check=ok`；非 DB 檔 hardlink（跨檔案系統改 `cp -p`）。archive 由 staging 打包，第一層仍是 `kg-data/`，不含 `-wal`/`-shm`/`-journal`/`._*`/`.DS_Store`；staging 由 trap 清除（含 INT/TERM/HUP）。任一快照、走訪失敗或缺 `sqlite3` → 上傳前 `exit=3`，絕不退回直接打包 live 檔（Issue #2250） |
| Log（現役） | standby `~/Library/Logs/kg_backup.log`(每執行一行；成功 `exit=0 bytes=… sha256=… key=…`，上傳前中止 `exit=<rc> <原因>`，`backup_status.sh` 只認前者) |
| Log（舊 Lightsail） | `/var/log/kg_backup.log` |
| IAM | `kg-backup-agent` 僅 `s3:PutObject*`,**無 Delete / 無 List**(限制 blast radius)。同一主體跨機沿用(creds 由 Lightsail `/root/.aws` 複製到 standby `~/.aws/credentials`) |
| 本機操作身份 | `MaxChen228`(admin),用 `~/.aws/credentials` 預設 profile |

> 跨 VM 限制：快照在 macOS host 讀取，writer 在 OrbStack VM 內經 bind mount 寫入；SQLite 不保證 WAL shared memory 跨此邊界一致。還原演練時抽一個活躍用戶，比對容器內 live DB 與還原檔的近期 rows；若 host 端漏 frame，改為在容器內快照。

防線層級（遷移後）:

1. ~~**Lightsail AutoSnapshot**~~ — **已消滅**（Lightsail instance 2026-06-19 terminate，snapshot 與 instance 一併不存；standby 無 instance 級替代，見 `backup.md`）。
2. **本機冷快照（2026-08-08 復役）** — `./ops/devops_kg_safe.sh backup` 從 standby 拉 `~/kg-data` 回本機並自動驗 SQLite integrity + sha256。原記「寫死 Lightsail 故 OFFLINE」已不成立（`devops.sh` 2026-06-19 即 retarget standby）；真正的病灶是 `cmd_backup` 傳 GNU 專屬的 `--info=progress2`，macOS 內建 openrsync 不認 → 印 usage 後中止（IMP-0023 / IMP-20260806-02bf8d，現已依 rsync flavor 分流；rsync 非零退出改為具名拒絕並指向下方第 3 層）。
3. **AWS S3 異地 backup（現役主防線）** — 本 SOP。standby launchd 每日跑，粒度小、可逐日選版本。

---

## 2. Restore — 標準流程(RTO ~15 分鐘)

> 假設場景:`data/` 目錄被誤刪 / DB 損壞 / 需回到指定日期，host 本身可達。
>
> **機器對照（現役 = standby）**：下方 §2.2–2.8 的指令以 Lightsail 範本寫成（`ssh ubuntu@13.193.212.134`、`/home/ubuntu/knowledge_graph_api/`、`/var/log/kg_backup.log`）。**在現役 standby 上等價替換**：
> - SSH：`ssh chenliangyu@100.118.39.104`（Tailscale，公鑰免密碼）
> - data 目錄：`~/kg-data/`，archive 第一層即 `kg-data/`（`basename(KG_DATA_DIR)`，非 `data/`）（**不是** `~/project/kg/backend/data/`——2026-06-16 已移出 worktree；同檔 :15 / :23 為準）。工作區（compose / `.env`）：`~/kg-prod/backend/`（`devops.sh:21` `REMOTE_DIR`；`~/project/kg` 是 dev-only clone，會靜默腐爛，別拿它當生產）
> - backup log（查 sha256 對照）：standby `~/Library/Logs/kg_backup.log`
> - 容器名：`knowledge-graph-api`（OrbStack）；`sudo` 在 macOS 通常不需（檔案 owner = `chenliangyu`，非容器 root drift）
> - 拉 S3：standby 上若 `kg-backup-agent` 只有 PutObject 遇 `AccessDenied`，改用主力機 admin profile 拉再 scp 到 standby（同 §2.3 備援）。

### 2.1 列出可用 backup

```bash
# 列當前 versions
aws s3 ls s3://kg-backups-prod-967512079054/data/ --region ap-northeast-1

# 含 noncurrent versions(若某日 backup 被新版本覆蓋,可救回)
aws s3api list-object-versions \
  --bucket kg-backups-prod-967512079054 \
  --prefix data/ \
  --region ap-northeast-1 \
  --query 'Versions[].{Key:Key,VersionId:VersionId,LastModified:LastModified,Size:Size}' \
  --output table
```

### 2.2 確認目標 backup 的 sha256(從 server log)

```bash
ssh ubuntu@13.193.212.134 'sudo grep "<YYYY-MM-DD>" /var/log/kg_backup.log'
# 範例:
# 2026-05-31T16:14:42Z exit=0 bytes=353618986 sha256=61b9f656... key=data/2026-05-31.tar.gz
```

記下 sha256 與 size,等下校驗用。**沒 log 對照就不要 restore**(來源不可信)。

### 2.3 拉 backup 到 server(在 server 上跑,不要先拉到本機再 scp)

```bash
ssh ubuntu@13.193.212.134
cd /tmp
DATE=2026-05-31  # 改成你要還原的日期
aws s3 cp "s3://kg-backups-prod-967512079054/data/${DATE}.tar.gz" "/tmp/${DATE}.tar.gz" --region ap-northeast-1
```

> Server 上 `kg-backup-agent` IAM **僅有 PutObject**,如果遇 `AccessDenied`,改用本機 admin profile 拉再 scp:
> ```bash
> # 本機
> aws s3 cp "s3://kg-backups-prod-967512079054/data/${DATE}.tar.gz" /tmp/
> scp -i ~/.ssh/lightsail_kg_prod "/tmp/${DATE}.tar.gz" ubuntu@13.193.212.134:/tmp/
> ```

### 2.4 校驗 sha256

```bash
# 在 server 上
EXPECTED=61b9f656...  # 從 2.2 取得
ACTUAL=$(sha256sum /tmp/${DATE}.tar.gz | awk '{print $1}')
[[ "$EXPECTED" == "$ACTUAL" ]] && echo "✓ MATCH" || { echo "✗ MISMATCH"; exit 1; }
```

校驗失敗 → 改拉 noncurrent version(`--version-id <id>` 加在 `aws s3api get-object` 上)。（舊「退到 Lightsail Snapshot」已不可用：instance 2026-06-19 terminate。）

### 2.5 停容器、備份「壞掉的」現場、解壓覆蓋

archive 第一層是 `basename(KG_DATA_DIR)`（`ops/kg_backup.sh:62`）：standby 為 `kg-data/`，僅舊 Lightsail 為 `data/`。以下以 standby 為準，`DATA` 為現役 data 目錄；先 `tar tzf` 確認第一層名稱 == `basename "$DATA"` 才解壓。archive 不含 `-wal`/`-shm`，所以必須先把壞掉的現場整個移開，不可直接覆蓋（否則殘留 sidecar 與備份後的檔案會混進還原結果）。

```bash
set -e
DATE=2026-05-31  # 同 §2.3
DATA=~/kg-data   # 現役 standby；舊 Lightsail 為 /home/ubuntu/knowledge_graph_api/data
ARCHIVE="/tmp/${DATE}.tar.gz"

# 停容器,避免 SQLite WAL race(compose 在 ~/kg-prod/backend)
(cd ~/kg-prod/backend && docker compose stop)

# 解壓前驗證 archive 第一層 == basename(DATA)
ROOT=$(tar tzf "$ARCHIVE" | head -1 | cut -d/ -f1)
[ "$ROOT" = "$(basename "$DATA")" ] || { echo "root mismatch: $ROOT"; exit 1; }

# 把當前 data rename 成 <DATA>.broken.<ts>(別 rm,留鑑識用);目錄存在但 mv 失敗要中止
TS=$(date +%Y%m%d-%H%M%S)
[ ! -e "$DATA" ] || mv "$DATA" "$DATA.broken.${TS}"

# 解壓到 DATA 的上層目錄,還原出 $(basename "$DATA")/
tar xzf "$ARCHIVE" -C "$(dirname "$DATA")"
ls -la "$DATA/users/" | head
```

### 2.6 修正 owner

standby 上檔案 owner 應為 `chenliangyu`（tar 以當前使用者解壓即是，通常不需處理）。若異常再修正，macOS 不需 `sudo`：

```bash
chown -R "$(id -un)" "$DATA"
```

### 2.7 啟動 + 健康檢查

```bash
(cd ~/kg-prod/backend && docker compose up -d)
sleep 10
curl -s -o /dev/null -w 'docs=%{http_code}\n' http://127.0.0.1:8000/docs
curl -s https://wordnexus.lol/docs | head -5
(cd ~/kg-prod/backend && docker compose logs --tail=30 kg-api)
```

預期:`docs=200`、SwaggerUI 可載入、container log 無 startup error、`/api/system/info` 回 200。

### 2.8 抽樣驗證資料(SQLite integrity_check)

```bash
SAMPLE=$(ls -d "$DATA"/users/*/ | head -1)
for db in "$SAMPLE"*.db; do
  echo "--- $db ---"
  sqlite3 "$db" "PRAGMA integrity_check;"
done
```

預期每個 db 回 `ok`。

### 2.9 紀錄

事故時間、選用 backup 日期、sha256、影響期間、丟失資料窗口寫進 `docs/runbook/incidents/<date>.md`(若不存在就建,參考 `docs/runbook/system.md`)。

---

## 3. Restore — 災難情境(host 也掛)

### 3a. standby 掛（現役 host 故障）

> **⚠ 舊「快速回滾到 Lightsail」已失效**：Lightsail instance 2026-06-19 terminate，無容器可 `up`、無 `13.193.212.134` 可指。standby 掛掉的唯一路徑 = 在可達 host（修好的 standby 或新建機）重建 + 拉 S3。

1. **重建 standby（或任一可達 host）**：機器層建置見 butler `~/butler/docs/standby-host-setup.md`；服務層（容器 + cloudflared + launchd）見 butler `~/butler/docs/kg-backend-deployment.md §3-4` → 拉 S3 backup 到 `~/kg-data/`（2026-06-16 移出 worktree） → 同 §2.5–2.8。完整回滾見 [`docs/reference/host_topology.md` §Rollback](../reference/host_topology.md)。

### 3b. Lightsail 重建（歷史參考，instance 已 terminate）

> Lightsail instance 已於 2026-06-19 terminate，本節**不再是現成回滾目標**，僅保留為「若日後需在雲端 Linux host 從零重建」的參考流程。現役災難回復一律走 §3a（重建可達 host + 拉 S3）。

1. **從 snapshot 還原 instance** — **已不適用**（snapshot 隨 instance 一併 terminate）。如需雲端重建，改走下一步全新建置。
2. **完全空白 instance** → 重跑 `KG_ALLOW_LIGHTSAIL=1 devops.sh deploy`(會 build image, scp `.env`, certs, compose, `VERSION`)→ 拉 S3 backup → 同 §2.5–2.7。RTO 1–2 小時(主要卡 Docker build)。

> 已知陷阱:`compose.yml` 中 `./VERSION:/app/VERSION:ro` 是 bind mount file,如果 `VERSION` 不存在會被 Docker 當成目錄掛,容器秒退 exit 127。`deploy` 流程會寫 `VERSION`,手動還原時 `git rev-parse HEAD > VERSION`(寫**完整 sha**,不是 `--short`:它同時是 Sentry release `kg-backend@<VERSION>` 與 reconciler 游標)不要漏。

---

## 4. 故意搞壞:fire drill 演練

每月一次,選週末晨間:

```bash
# 1. 拉昨天的 backup 到 /tmp/scratch
DRILL=/tmp/restore-drill-$(date -u +%Y%m%d)
mkdir -p "$DRILL" && cd "$DRILL"
DATE=$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
aws s3 cp "s3://kg-backups-prod-967512079054/data/${DATE}.tar.gz" .
tar xzf "${DATE}.tar.gz"

# 2. sha256 比對(查 server log；現役 standby)
ssh chenliangyu@100.118.39.104 "grep ${DATE} ~/Library/Logs/kg_backup.log"
# 回滾到 Lightsail 時：ssh ubuntu@13.193.212.134 "sudo grep ${DATE} /var/log/kg_backup.log"
sha256sum "${DATE}.tar.gz"

# 3. SQLite integrity check（archive 第一層是 kg-data/）
for db in $(find kg-data -name '*.db'); do
  echo "$db: $(sqlite3 "$db" 'PRAGMA integrity_check;' | head -1)"
done

# 4. 清掉
cd /tmp && rm -rf "$DRILL"
```

預期:所有 db 都 `ok`,sha256 與 server log 完全相符。**任何一個 db 不是 `ok` 就視為當天 backup 損壞**:快照在上傳前已過 `quick_check`,所以先查傳輸/S3 物件（sha256 是否相符、改用 noncurrent version），再在 standby 對來源 DB 跑 `PRAGMA integrity_check`。

---

## 5. 故障排除

| 症狀 | 原因 | 處置 |
|---|---|---|
| `kg_backup.sh` exit=2 | `data/` 目錄缺 | container 還沒起 / path 改了。檢查 `KG_DATA_DIR` env |
| `kg_backup.sh` exit=3 `snapshot failed: <path>` | 該 DB 不是 SQLite／已損毀／被鎖超過 30 秒，或快照 `quick_check` 不是 `ok` | 在 standby 對該檔跑 `sqlite3 <path> 'PRAGMA quick_check'`；修復或移出 data 目錄後重跑。不要改回直接打包 live 檔 |
| `kg_backup.sh` exit=3 `sqlite3 missing` / `file walk failed` | launchd PATH 找不到 `sqlite3`；或 data 目錄有不可讀子目錄 | 補 `sqlite3`（macOS 內建 `/usr/bin/sqlite3`）；修正權限後重跑 |
| `aws` 寫入 `AccessDenied` | IAM `kg-backup-agent` 寫了 `s3:PutObject` 外的動作 | 不該發生。檢查 inline policy `kg-backup-put-only` |
| backup 連續 N 天大小驟減 | 用戶資料異常 / 路徑被偷改 | 不可信。回到上一個正常日期的 backup |
| sha256 不符 | 傳輸中斷或 S3 物件被改 | 改用 noncurrent version,並上 CloudTrail 查改動者 |
| `MFADelete=Enabled` 後想改 lifecycle | MFA 也鎖 PutBucketVersioning | root user + MFA code 重簽 versioning config(暫關 MFADelete → 改 → 再開) |

---

## 6. 已知不在 backup 範圍(顯式宣告)

| 不含 | 怎麼救 |
|---|---|
| `.env` | git 不在;現役 standby `~/project/kg/backend/.env` 為真實檔(`.gitignore`)。事故時從本機/Time Machine 還原（須對齊 prod 值，尤其 `JWT_SECRET`）。Pre-flight 應每月把 `.env` 加密後丟保險櫃。 |
| `certs/AuthKey_*.p8` | Apple Developer Portal 重下載或 `~/Downloads/` 找。**這也應有本機定期備份**。 |
| Docker images | `docker compose build` 重 build。耗時但確定可重現。 |
| Lightsail SSH key（rollback 用）| `~/.secrets/lightsail_kg_prod`（**不跨機同步**，僅主力機持有）。**本機備份必含 `~/.secrets/`**(每日 Time Machine 已含)。掉了 → Lightsail Console 改用 Browser-based SSH 重塞 pubkey。 |
| standby SSH 存取 | Tailscale 公鑰（主力機 → `chenliangyu@100.118.39.104`）。掉了 → 實體前往 standby 重配公鑰。 |

---

## 7. 反向操作(刪舊 backup / 清空間)

> Bucket 沒設 lifecycle(MFA Delete 互斥),backup 永久累積。約每年 ~128 GB(${'\$'}3/月),前 2-3 年不痛,之後可手動清。

**刪除任何 version 都要走 root user + TOTP MFA**(這正是 MFA Delete 的保護)。流程同 §A2 開 MFA Delete 那次:

1. AWS Console 用 root user 登入,IAM → Security credentials → Create access key(臨時)
2. 本機 `aws configure --profile root-tmp` 灌進去
3. 對單一 version 刪:
   ```bash
   aws s3api delete-object \
     --bucket kg-backups-prod-967512079054 \
     --key "data/2025-12-01.tar.gz" \
     --version-id "<VersionId>" \
     --mfa "arn:aws:iam::967512079054:mfa/root-totp <6-digit>" \
     --profile root-tmp
   ```
4. 批量清(例如保留最近 90 天):
   ```bash
   # 列出 90 天前的 versions(用平常 admin profile 就能 list,只有 delete 才需要 root+MFA)
   CUTOFF=$(date -u -v-90d +%Y-%m-%d 2>/dev/null || date -u -d '90 days ago' +%Y-%m-%d)
   aws s3api list-object-versions \
     --bucket kg-backups-prod-967512079054 \
     --prefix data/ \
     --query "Versions[?LastModified<'${CUTOFF}'].[Key,VersionId]" \
     --output text \
   | while read key vid; do
       echo "Will delete: $key $vid"
       # 確認沒問題後加 root+MFA 跑下面這條(每次都要輸入新的 6 位數)
       # aws s3api delete-object --bucket kg-backups-prod-967512079054 \
       #   --key "$key" --version-id "$vid" \
       #   --mfa "arn:aws:iam::967512079054:mfa/root-totp <code>" \
       #   --profile root-tmp
     done
   ```
5. **清完立刻刪 root access key + 清 profile**(同 §A2 步驟 4-5)

**`kg-backup-agent`(server cron 用的身份)完全沒有 Delete 權限**,任何刪除動作只能透過 root+MFA。這是設計上的硬阻擋,不要繞過。
