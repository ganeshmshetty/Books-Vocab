<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - ops/
  - backend/data        # 2026-06-16 起 live data 移出 git worktree → felix ~/kg-data（由 KG_DATA_DIR 指向）
verified_against: f69f5e53d6b2ac6e3b6f96febb8456a7ed58b477
-->
# Backup 策略總覽

> **過渡狀態（2026-06-15 起，L2 於 2026-08-08 復役）**：正式站遷到家用常駐機 `standby`（OrbStack docker）後，**L1（Lightsail AutoSnapshot）失效**——已無 Lightsail instance。**L3（S3 異地）仍是現役主防線，已從 Lightsail cron 移到 standby launchd**（`ops/launchd/com.kg.backup.plist`，跑同一支 `ops/kg_backup.sh`）。standby 目前**無自動 instance 級快照**（known gap，下表 L1 標 OFFLINE）。
>
> **L2 已回到 ACTIVE（2026-08-08）**：`devops.sh` 早在 2026-06-19 就 retarget 到 standby（`KG_ALLOW_LIGHTSAIL` guard 已移除，全檔無 Lightsail 相依），本文原本記的「`devops.sh` 寫死 Lightsail rsync」已不成立。真正讓 L2 在主力機不可用的是另一件事：`cmd_backup` 無條件傳 GNU 專屬的 `--info=progress2`，macOS 內建 openrsync 不認 → 印 usage 後中止（IMP-0023 / IMP-20260806-02bf8d）。該旗標現已依 rsync flavor 分流，且 rsync 非零退出會具名拒絕並指向 L3，不再拿 usage 當失敗訊號。

KG 原以**三層 backup**互相補位。各層獨立,單一層失效不阻擋整體還原。事故 SOP 走 `docs/sop/backup_restore.md`。

| 層 | 工具 | 範圍 | 頻率 | 保留 | RPO | RTO | 狀態（2026-06-15） |
|---|---|---|---|---|---|---|---|
| L1 | Lightsail AutoSnapshot | **整個 instance**(docker / `.env` / certs / data / OS) | ~~每日 UTC 22:00~~ | 7 份 | 24h | 30–60 min | **OFFLINE**：Lightsail STOP，僅留遷移當下漸舊快照當回滾；standby 無對應替代 |
| L2 | 本機 `devops.sh cmd_backup` + `backup_verify.sh` | standby `~/kg-data`（非 DB 檔 rsync 增量；`*.db` 先在遠端以 SQLite online backup 產生一致快照，再 tar 串流拉回，#3442）| 手動(發版前 / 事故前) | 全部歷史(本機磁碟) | 視操作時機 | 5–10 min | **ACTIVE**（2026-08-08 復役）：rsync 旗標依 flavor 分流，macOS openrsync 用 `--progress` |
| L3 | AWS S3(本 SOP) | `data/`(tar+gz streaming) | 每日 UTC 03:00（**standby launchd**） | Versioning + **MFA Delete**,**無 lifecycle**(AWS 限制兩者互斥)→ 永久累積,需手動清(見 `backup_restore.md §7`) | 24h | ~15 min | **ACTIVE**（現役主防線） |

L2 的 `*.db` 行為：遠端 `find -L` 會跟進目錄與檔案 symlink，其中的 DB 以 `mode=ro` 唯讀開啟（絕不以 rw 開 data 目錄外的檔，#3578），未變者拉回後硬連結至增量基準（#3474）；懸空的非 DB symlink 由 rsync 前置排除並具名警告，不中止快照（#3578）。

## 為什麼三層

- L1 救「整個 instance 被誤刪」、「Docker 配置壞掉」。粒度粗,但唯一能還原 `.env` / `certs`。**遷移後 OFFLINE**——standby 的 `.env`/`certs` 改靠本機 Time Machine + git 重生。
- L2 救「我在發版前怕剛改的 schema 壞了」、「想對比 5/15 vs 5/20 的某張表」— 任意時間點手動拉。**2026-08-08 起在 macOS 主力機恢復可用**（openrsync 旗標分流）；`./ops/devops_kg_safe.sh backup` 即可從 standby 拉冷快照。L2 的 `*.db` 不 raw rsync（backend 以 WAL 持續開著 DB，已 commit 的 row 可能只在 `-wal`）；快照失敗即 `cmd_backup` 非零退出，`migrate-run` 因此不會在無效備份之後執行。
- L3 救「server 上一切被 `rm -rf`,SSH key 也鎖在被刪的目錄裡」(2026-05-30 真實案例)。IAM 邊界硬隔絕,執行角色(`kg-backup-agent`)只能 PutObject、刪不掉歷史。**遷移後仍 ACTIVE**：同一 IAM 主體、同一 bucket，只是跑 script 的主機從 Lightsail cron 換成 standby launchd。

## 不在範圍(共識)

| 缺項 | 原因 | follow-up |
|---|---|---|
| 跨 region replication | RPO 24h 同 region 已夠;成本 |  |
| 跨雲(R2 / GCS / B2) | 過度防護 |  |
| PITR / SQLite WAL streaming | RPO 24h 達標 |  |
| Backup 完整性 alarm | 之後再加,CloudWatch alarm + SNS |  |
| 自動清舊 backup | **AWS 限制**:lifecycle 與 MFA Delete 不可共存,選了 MFA Delete | 約 1-2 年後手動清一次(`backup_restore.md §7`);成本閾值與動作判準走 `docs/reference/cost_baseline.md` **(SoT)** |
| `.env` / `certs/` 異地 backup | 本機 Time Machine 涵蓋,且都可重生 | 月度 reminder:檢查本機 backup 含 `~/.secrets/`、`~/project/kg/backend/{.env,certs/}` |
| standby instance 級快照 | 遷移後 L1 OFFLINE，無對應替代（家用機是 SPOF，無 UPS，已知接受） | follow-up：若需 instance 級保護，評估 macOS 層 Time Machine 含 `~/project/kg/backend` 或週期冷 `tar` |

## 監控

每週看一次（L3，現役）:

```bash
# L3（standby launchd 跑的 S3 backup）：一次唯讀、fail-closed 檢查 job + 最近紀錄
./ops/devops_kg_safe.sh backup-s3-test
# S3 物件數仍可作為容量/保留觀測，但不能取代上面的 freshness 與內容驗證
aws s3 ls s3://kg-backups-prod-967512079054/data/ | wc -l
```

`backup-s3-test` 會拒絕缺 job、缺 log、非零 backup exit、格式錯、key 日期不符或最後一筆超過 36 小時；連 2 天沒新增 S3 物件仍需 ping。（L1 Lightsail AutoSnapshot 已 OFFLINE，不再監控。）

## 相關文件

- `docs/sop/backup_restore.md` — restore step-by-step(事故當下讀這份)
- `docs/sop/debug.md` — 排障(含 CF tunnel / 容器 / Lightsail rollback)
- `docs/sop/deploy.md` — 部署(含 standby 手動快照 / Lightsail rollback 重建)
- `docs/runbook/system.md` — change flow
- `ops/kg_backup.sh` — L3 script（standby/Lightsail 共用，靠 env 參數化）。每個 `*.db` 以 SQLite online backup 快照到 staging 後才打包（含已提交 WAL，archive 無 `-wal`/`-shm`；快照失敗 → 不上傳，Issue #2250），細節見 `backup_restore.md §1`
- `ops/launchd/com.kg.backup.plist` — L3 現役排程（standby）；`ops/cron/kg-backup.cron` — 舊 Lightsail cron（已停用）
