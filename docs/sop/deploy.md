<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - backend/
  - devops.sh
  - ops/
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# 後端部署指南

> **Reconciler rollback evidence**：`000／000000` 表示沒有任何 HTTP 回應；真實 status（例如 502）是服務鏈證據，必須回滾。

> ⚠️ **生產禁用指令邊界**：本文件所有 ops 動作都受 [`docs/policy/safety.md`](../policy/safety.md) 約束。任何 `docker compose down -v`、`docker system prune -a`、`rm -rf` 涉及 data dir 的操作一律禁止，走 `ops/devops_kg_safe.sh` wrapper。
>
> **狀態（2026-06-15 遷移，2026-06-19 wrapper retarget）**：正式站已遷到家用常駐機 `standby`，經 Cloudflare Tunnel 對外（無 Caddy / 無 inbound 埠）。Lightsail instance 已 terminate（僅作冷重建 rollback 備援）。`./ops/devops_kg_safe.sh deploy/restart/migrate/backup` 已 retarget standby（transport 變數 `KG_SERVER`/`KG_REMOTE_DIR`/`KG_REMOTE_DATA_DIR`，default felix；`KG_ALLOW_LIGHTSAIL` guard 已移除）；`deploy` = 遠端 `git pull --ff-only` + 寫 VERSION + `docker compose up -d --build --force-recreate` + health + smoke（§標準部署流程）。下方 §Lightsail rollback 段為冷重建歷史語境，保留供災難回滾。Host topology SoT 見 [`docs/reference/host_topology.md`](../reference/host_topology.md)；服務層部署正本見 butler `~/butler/docs/kg-backend-deployment.md`。

## 核心資訊

- **primary 伺服器**: 家用常駐機 `chenliangyusAir`（M3 Air），user `chenliangyu`，Tailscale `100.118.39.104`，OrbStack docker
- **Edge**: Cloudflare Tunnel（名 `kg-standby`，CF 邊緣終結 TLS）；**無 Caddy、不開 inbound 埠**
- **Domain**: `wordnexus.lol`（CF DNS apex proxied CNAME → tunnel → standby localhost:8000）
- **SSH**: `ssh chenliangyu@100.118.39.104`（主力機公鑰免密碼）
- **primary 工作區**: `~/project/kg/backend`（git 同步，非 rsync）。⚠ 三平面拓樸下**生產容器實際跑在專用 clone `~/kg-prod/backend`**（reconciler 盯 origin/prod、compose 從此 build）；`~/project/kg` 為 dev/resume-only。下方 §標準部署流程的手動路徑若要碰生產容器須在 `~/kg-prod/backend` 執行（同 project name 在 `~/project/kg` 跑 compose 會劫持生產容器）。三平面語意與切換 runbook 見 [`docs/sop/release.md`](release.md)
- **rollback 伺服器**: AWS Lightsail `booksbrowser-kg-api-2gb`，IP `13.193.212.134`，SSH key `~/.secrets/lightsail_kg_prod`，工作區 `~/knowledge_graph_api`（容器 STOP）

---

## 標準部署流程（standby，手動）

> standby 程式碼靠 **git 同步**（非 rsync），部署 = `git pull --ff-only` + 重建容器。

```bash
ssh chenliangyu@100.118.39.104
cd ~/kg-prod/backend
git pull --ff-only                         # 生產專用 clone；不碰 ~/project/kg dev/resume tree
git rev-parse HEAD > VERSION               # 完整 sha（= Sentry release kg-backend@<sha>；/api/system/info 讀此檔）
docker compose up -d --build --force-recreate  # 重建+起；確保 VERSION bind mount 重新讀取
curl -s http://localhost:8000/api/system/info   # 驗 version 對上
```

- 純 `.py`/`.html` 改動理論可只 `docker compose restart`，但 compose 用 build image，仍建議 `up -d --build`。
- **migration**：app 啟動自動跑（`migration_version` 暴露於 `/api/system/info`）；如需手動 `docker exec knowledge-graph-api <cmd>`。
- **.env 改動**：直接編輯 standby `~/kg-prod/backend/.env` 後 `docker compose up -d --build --force-recreate`（容器讀新值需重建，不能只 restart）。⚠ `JWT_SECRET` 必須維持 prod 值，否則全用戶被登出。

### 部署後驗證（standby）

```bash
# 經公網（CF→tunnel→standby）
curl -s https://wordnexus.lol/api/system/info        # 期望 200 + version == git rev-parse HEAD（完整 sha）
curl -s -o /dev/null -w '%{http_code}\n' https://wordnexus.lol/api/health   # 期望 401（CurrentUser 端點，無 JWT 本就擋）

# DNS 卡舊 IP 時繞過快取直打 CF 邊緣驗服務本身
curl -s --resolve wordnexus.lol:443:104.21.85.113 https://wordnexus.lol/api/system/info

# 直連 standby（繞過 CF，分層驗容器/隧道）
./ops/devops_kg_safe.sh docker-ps; ./ops/devops_kg_safe.sh caddy-status --json
```

`version` 不等於 deploy sha = git pull 沒生效 / VERSION 沒寫 / 容器沒 `--build`。

---

## reconciler：release=deploy 自動收斂（felix-local，launchd 週期）

> **一句話**：**`origin/prod`** 一前進（只由 `ops/release.sh promote backend` 推進（FF-only、含守衛））就自動把 wordnexus.lol 收斂到最新版，免人工 SSH。GitHub `origin/main` 是合併後產品主幹，reconciler **不直接追 main**。上面的 §標準部署流程仍是手動路徑；本段是它的自動化包裝，兩者**共用同一把 deploy 鎖**互斥。main、production ref 與 rollback 邊界見 [`docs/sop/release.md`](release.md)。

- **腳本**：`ops/kg_reconcile.sh`（`--once`／`--dry-run`／`--help`）。它**跑在 felix 本機的專用生產 clone `~/kg-prod`**（由 launchd `KG_RECON_REPO` 指定；`~/project/kg` 為 dev/resume-only，reconciler 絕不碰）。不走 SSH，git/docker/curl 全本機；一輪冪等 tick 跑完即退。
- **驅動**：`ops/launchd/com.kg.reconcile.plist`（`StartInterval=90` 秒輪詢、`RunAtLoad`、**不 KeepAlive**、`ThrottleInterval=60`；生產切換後 ProgramArguments 與 `KG_RECON_REPO` 皆指向 `~/kg-prod`）。log → `~/Library/Logs/kg_reconcile.{out,err}.log`。
- **收斂真相**：`deployed_sha` = felix `backend/VERSION`（容器 serving 版本）；`origin_sha` = `origin/prod`。差異檔 = `git diff <deployed_sha>..origin/prod`。origin/prod 未 seed → 優雅 noop。
- **crash-consistency 交叉驗證**（felix 無 UPS）：`backend/VERSION` 於 deploy 時 build/health 確認「之前」就寫入，若該窗口斷電/被 kill，VERSION 會宣稱 new 但容器實際仍 serving 舊 image。故每輪 tick 先用 live 容器自報 version（`localhost /api/system/info`）交叉驗證：與 `VERSION` 不符（或 `VERSION` 缺失/不可解析）且 live 版可解析 → **以 live 實際版為準**覆蓋 `deployed_sha` 並修正 `VERSION` 游標，從實際狀態重新收斂（自癒 crash-window drift、亦救 `VERSION` 遺失但容器健在）。VERSION 缺失且容器亦無回應 → 大聲告警 + no-op（等人工 seed，不做「驚訝的」rebuild）。

### path-filter 判準（哪些變更才 rebuild）
只有變更命中 backend 觸發正則才 `compose up --build`；否則只 `git pull --ff-only origin prod`（追 felix repo HEAD、含 release 時自我更新本腳本），**不動容器**、**且刻意不寫 `backend/VERSION` 游標**（VERSION 只在真正 build 健康後才寫，代表容器 serving 版本；非 backend 變更沒重建容器，寫 VERSION 會謊報部署狀態）。觸發集（錨定 `backend/`）：`src/`、`tests/`、`static/`、`pyproject.toml`、`uv.lock`、`pytest.ini`、`Dockerfile`、`docker-compose.yml`、`ops_{cli,analyze,edit}.py`、`{index,privacy,support,terms,guide}.html`。
- **`backend/uv.lock` 與 `pyproject.toml` 在觸發集內（#2088）**：image 依 `uv.lock` 安裝（`uv export --locked --no-default-groups --group image-test` → `pip install --no-deps --require-hashes`，見 `backend/Dockerfile`；backend-quality 的 `image-lock` job 以 `backend/scripts/check_image_lock.py` 驗證已安裝版本 == lock），所以 lock-only 變更（例如 `uv lock --upgrade-package`）會改 image，必須走 build 路徑，否則 origin/prod 前進、生產卻停在舊依賴版本。
- **刻意排除**（皆不進 image）：`backend/.env*`、`backend/VERSION`、`backend/data/**`、`backend/certs/**`、`backend/scripts/**`、`backend/docs/**`、`ios/**`、`lab/**`、`docs/**`、`ops/**`、`design-system/**`。判準正本在 `ops/kg_reconcile.sh` 的 `BACKEND_TRIGGER_RE`。

### rollback + poison 行為
DEPLOY 前捕捉 `ROLLBACK_SHA=deployed_sha`。健康 gate = localhost `/api/system/info`（200 且 version==新 sha）→ 外部 smoke（`wordnexus.lol` info 對齊 + `/api/health` 存在）→ `ops/infra_health.sh`（exit 0 pass／1 warn 仍 pass／2 crit **原則上** fail，唯一例外見下段）。localhost 失敗、infra 失敗、以及**外部 smoke 判 `bad`** → `git reset --hard ROLLBACK_SHA` + 寫回 VERSION + `compose up --build` 回舊版，並把該 `origin_sha` 記入 `backups/reconciler.state` 為 **poison**（cooldown `KG_RECON_POISON_COOLDOWN`，預設 1h）；cooldown 內同 sha 不重試（等 origin 前進到新 sha 或 cooldown 過），避免壞 commit 每 90 秒撞牆。rollback 走 stderr 大聲 ALERT（launchd err log 收）、exit 非 0，且**回滾自己那次 compose 的退出碼會被檢查**——失敗時發的是「回滾未生效，容器很可能仍跑新版」而不是「生產可能雙壞」（後者只在回滾真的跑完、舊版卻起不來時才發）。

**reconciler 呼叫 `infra_health` 時會設 `KG_HEALTH_DEPLOY_DRIFT=0`（IMP-0022）**。那組 metric（`deploy_drift` / `reconciler_tick_age_s` / `reconciler_poison_active`）量的是「生產有沒有收斂到 `origin/prod`、reconciler 還活著沒」，而**那正是 reconciler 自己的職責**——把自己的收斂狀態納入自己的健康條件會構成迴圈：release 推進 `origin/prod` 後、下一輪收斂完成前必然 drift，於是這一關會回滾一次本來健康的部署。故自我 gate 關掉該組；人工或監控呼叫 `ops/infra_health.sh` 時預設啟用。`deploy_drift` 本身另設計成**永不 crit**（只 ok/warn），因為那個瞬態 drift 是正常的。

**外部 smoke 是三分類，不是二分類（IMP-0061）**。判準：**回滾只有在證據指控被部署的那份 code 時才正當**，而走到這一步 localhost 已經證明新 sha 起來了、正在 serving。

| class | 什麼情況 | 結果 |
|---|---|---|
| `ok` | info 對齊且 `/api/health` 回 200/401/403（404 視為跳過） | 通過 |
| `bad` | **拿得到 HTTP 回應**但不合格——5xx、版本不符、CF 錯誤頁（502/530/1033 皆算） | 回滾 + poison + ALERT，**行為不變** |
| `unreachable` | **每次嘗試都拿不到任何 HTTP 回應**（`HTTP=000`／DNS 失敗／連不出去） | **不回滾**：部署照常落地、不寫 poison，發 ALERT 要人從第二個地點確認，並在 verdict 與 `backups/deploy.log` 記 `smoke=unverified` |

`unreachable` 不回滾有兩個獨立理由：① 沒有任何證據指控這份 code，「我這台量不到」與「服務真的壞了」不是同一件事；② 回滾要跑 `--build`，而 2026-08-04 事故裡它正是被同一場 DNS 故障弄死的（IMP-0060 C2）——**兩個失效是相關的**，gate 最容易假失敗的時候正是回滾最不可能成功的時候。放行後 gate 剩下 localhost 與 `infra_health`，而**`infra_health` 並不純本機**——它自己也會從這台機器打同一個對外 URL（`ops/infra_health.sh:40` 的 `PROBE_URL`，非 200 一律 crit、crit 即 exit 2），所以它對同一場斷網**沒有免疫力**。刻意**只問「到底有沒有拿到回應」，不問是幾號**，所以不需要「CF tunnel 各種故障回什麼 code」那份對照表。

**infra_health 的 CRIT 不再一律回滾（IMP-0061 review D1）**。`run_health_gate` 改吃 `infra_health --json` 並**看它為什麼 crit**，不是只看 exit code；呼叫時把 `KG_HEALTH_PROBE_URL` 釘成 smoke 剛探過的同一個 URL，讓「同一個問題被問了兩次」是結構事實而非對預設值的假設。放行條件是**三個都成立**：① 本輪 `EXTERNAL_SMOKE_CLASS == unreachable`（外部 smoke 已獨立、重試到預算用盡地證明拿不到任何 HTTP 回應）；② crit 的 metric key **恰好只有 `http_probe` 一個**；③ 該 metric 的 value 必須是 **`000`／`000000`**，即連 HTTP 回應都沒有。拿得到真實 status（包括 502/530/1033）就是服務鏈的新證據，不能歸因為同一場斷網。此時發 ALERT、仍記 `smoke=unverified`、**不回滾**。其餘任何 crit（容器不見了／磁碟爆了／記憶體／tunnel 掛了／憑證過期／host 指標收不到…）都是關於這台機器或這個服務的真證據，**照舊回滾 + poison**——斷網不是 infra 這關的免死金牌。JSON 抽不出任何 crit key 或 metric value（壞掉／版本不合／被替換）→ **fail-closed 回滾**：「看不懂」不等於「沒問題」。少了這個判準，主機端斷網會原封不動地變成 `reason=infra` + 回滾 + poison（行為與修法前一模一樣，只是換了個理由字串），而且同一輪 tick 會先發「故不回滾」再發「回滾」兩則互相矛盾的 ALERT。判準正本 `ops/kg_reconcile.sh` 的 `infra_crit_is_same_outage`。

⚠ `smoke=unverified` 的落地**必須有人看**：stderr ALERT 只是次要通知（沒人保證有人在讀 launchd err log），持久可 grep 的證據是 `backups/deploy.log` 那行與 verdict 的 `smoke` 欄位。查最近有沒有這種落地：`grep 'smoke=unverified' backups/deploy.log`。

**兩個健康探針都會重試**，共用 `KG_RECON_HEALTH_ATTEMPTS`（預設 5）與 `KG_RECON_HEALTH_DELAY`（預設 5s）。預算算法看**失敗是快是慢**：`--max-time 10` 只在「連得上但回應慢」時吃滿；DNS `no such host` 之類是瞬間返回，所以快失敗的總預算只有 `(attempts-1) × delay` = 20s。這個區別是 2026-08-04 事故的核心（IMP-0060）：external 探針當時**完全沒有重試**，一發打在 felix 主機 DNS 中斷的窗口上就回滾了一個健康的部署。20s 仍蓋不住觀測到上界 ~90s 的主機端連通性中斷，但自 IMP-0061 起**那不再是風險，只是延遲**：預算用盡後的結論已從「回滾」改成「落地 + `smoke=unverified` + 告警」（見上方三分類表）。所以這兩個 knob 現在買的是「多等一下也許就驗到了」，不是「賭中斷有多長」。

### 與人工 deploy 共鎖
鎖是 **deploy host（felix）上的 `/tmp/kg-deploy.lock`**：reconciler 在 felix 本機 `mkdir`，`devops.sh` 的 `acquire_deploy_lock` / `release_deploy_lock` 經 SSH 在 felix 執行 `mkdir` / `rmdir`（本機不留任何鎖，所以是同一把）。鎖被持有時 reconciler 一律 `verdict=locked` exit 0 讓路、下一 tick 再收斂：DEPLOY 取不到鎖，且 step 2b 的 VERSION 自癒在鎖存在時直接略過（人工 deploy 持鎖期間 VERSION 先於容器更新，不是 crash drift，不可改寫）。反之 reconciler 持鎖時，人工 `devops.sh deploy/restart/migrate` 會被同一把鎖擋住。

### verdict（stdout 單行 JSON，schema `kg.deploy.reconcile.v1`）
`verdict ∈ {noop, ff-only, deployed, rolled-back, rollback-failed, poisoned-skip, locked, dry-run}`；欄位 `deployed_sha/origin_sha/backend_changed/smoke/ts`。人類進度/告警走 stderr。

`rollback-failed` 表示部署健康 gate 失敗後，rollback compose 也以非零退出；此時仍寫 poison 以避免立即重試，`backups/deploy.log` 寫 `ROLLBACK_FAILED from=<new> to=<old> reason=<reason> compose_rc=<rc>`，git tree/VERSION 已回到舊版但容器可能仍跑新版，不能寫 `ROLLED_BACK`。只有 rollback compose 成功的分支才輸出 `rolled-back` 並寫 `ROLLED_BACK`。

`smoke ∈ {n/a, ok, unverified, bad}`（IMP-0061 新增）——外部 smoke 這一關的結果，語意刻意與 `verdict` 正交：

| 值 | 意思 |
|---|---|
| `n/a` | 外部 smoke 沒跑到（`noop`/`ff-only`/`locked`/`dry-run`，或 gate 在 localhost/build 階段就先失敗） |
| `ok` | 驗過且通過 |
| `unverified` | 跑了、預算用盡，但**全程沒拿到任何 HTTP 回應** → 判 host 端斷網，照樣落地（`verdict=deployed`） |
| `bad` | 跑了、拿得到回應但不合格 → 回滾（`verdict=rolled-back`，`deploy.log` 記 `reason=smoke`） |

### 安全不變式
絕不碰 `~/kg-data`（生產資料權威副本，已於 2026-06-16 搬出 git worktree，`reset --hard` 只作用 repo working tree）；絕不 `git clean`／不 reset 到未知 sha（只回 ROLLBACK_SHA）／不 `compose down`／不 prune／不 `rm -rf`；fetch/pull 一律 `--ff-only`，origin rewind 不 force、告警待人工。

### 首次啟用 origin/prod

> **首次啟用是一次性拓樸遷移**（建生產 clone `~/kg-prod`、seed `origin/prod`、原地 recreate 容器、換 plist 指向 `~/kg-prod`），已完成，拓樸見 [`host_topology.md`](../reference/host_topology.md)。**日常推進 `origin/prod` 只走** `./ops/release.sh promote backend <sha>`，前置守衛、驗證與 rollback 見 [`docs/sop/release.md`](release.md) §felix 生產切換。本段不重抄。

已啟用後的日常 dry-run / 掛載 / 停用（在 `~/kg-prod`；務必先 dry-run，絕不 mutate）：
```bash
# felix 上，先 dry-run 驗（印出會做什麼 + JSON verdict，必為 noop 除非 origin/prod 真前進）
cd ~/kg-prod && KG_RECON_REPO=~/kg-prod ops/kg_reconcile.sh --dry-run
# 掛載 / 停用 launchd（跑在 auto-login session）
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kg.reconcile.plist
launchctl bootout gui/$(id -u)/com.kg.reconcile
```
（log 修剪不需 launchd 掛載：唯一觸發是 backend 行程內的 `log_retention_scheduler`，每日台北時間 04:17 執行；無 launchd manifest，見 host_topology.md。）
單元測試：`bash ops/tests/test_kg_reconcile.sh`（全離線、mock git/compose/curl/infra_health）。

---

## Lightsail rollback 部署流程（僅回滾時用）

> ⚠️ **僅在 standby 嚴重故障需回滾時執行**。Lightsail instance 已 terminate，回滾 = 從零冷重建（建 instance → bootstrap → Caddy → 搬 standby data）。`devops.sh` 已 retarget standby（不再寫死 Lightsail），故下方一鍵 `./devops.sh deploy` 流程**僅為歷史 Lightsail 語境參考**；冷重建須重新指向新站（`KG_SERVER=ubuntu@<新IP>` 等）或手動執行。回滾完整步驟（含 CF apex 改回 A 記錄）見 [`docs/reference/host_topology.md` §Rollback](../reference/host_topology.md) 與 butler `~/butler/docs/kg-backend-deployment.md §6`。

> 以下決策樹與 `deploy` 內部流程為**舊 Lightsail wrapper 行為的歷史記錄**（rsync + fast/full + force-recreate）。現役 `devops.sh` 已 retarget standby（git pull + compose，無 rsync）；`KG_ALLOW_LIGHTSAIL` env var 已移除。冷重建 Lightsail 時須另指向新站或手動執行對應步驟。

```
舊 Lightsail wrapper 行為（歷史記錄，現役不適用）
│
├─ 首次部署 / .env 有改動？  → ./devops.sh setup    ← push-env + deploy 一條龍
├─ 只是代碼更新（.env 未變）？ → ./devops.sh deploy   ← rsync + build + migrate + health
├─ 只需重啟（不需重新 build）？ → ./devops.sh restart  ← 快 10 倍，保留現有鏡像
└─ 只跑 DB migration？        → ./devops.sh migrate
```

**舊黃金原則**：`restart` 比 `deploy` 快 10 倍，只有代碼真的改了才 `deploy`。

舊 Lightsail `deploy` 內部流程：backup → env-check → **寫入 VERSION（git SHA）** → rsync → docker build + **force-recreate** → migrate → 容器內 health check → **追加 deploy.log** → **外部 smoke verify**。（舊流程；現行 standby deploy 不執行 env-drift）

> 現役 standby `deploy` 內部流程見上方 §標準部署流程：`git pull --ff-only` → 寫 VERSION → `docker compose up -d --build --force-recreate` → health（`api/system/info`）→ 外部 smoke verify；migration 由 app 啟動自動跑，deploy 不再自動 backup/migrate。**force-recreate 仍在**——2026-06-19 retarget 時掉了，紅了 6.5 週才被發現並回補（IMP-0052）。**自動路徑（`ops/kg_reconcile.sh`）2026-08-04 起同樣兩處都帶此旗標**（deploy 與 rollback），理由與代價相同；少了它會每小時假回滾一次（IMP-0056）。代價是不進 image 的 commit 也會斷幾秒、且前一顆容器的 json-file log（`docker-logs` 看得到的範圍）會消失；換的是版本游標與容器自報值一致，smoke gate 與 Sentry release tag 都靠它。

部署完成後確認遠端版本：
- `./devops.sh status` — 顯示部署版本 + 最近部署記錄
- `curl https://wordnexus.lol/api/system/info` — 無需 auth，回傳 version、uptime、migration 狀態

> 📍 **以下到 §特殊情境 SOP 之間的段落（smoke verify / 排查 / Rollback）皆為 Lightsail rollback 語境**（Caddy / `13.193.212.134` / `devops.sh` 流程）。standby primary 的部署後驗證見上方 §標準部署流程；standby 上 TLS 由 CF 邊緣處理，無 Caddy。

### 外部 smoke verify（deploy 末段自動執行）

容器健康檢查只走 `localhost:8000/docs`，無法保證 Caddy/TLS/公網路徑完好。`cmd_deploy` 末段會從本地透過公網打三層 verify：

1. `GET https://wordnexus.lol/api/system/info` — 預期 HTTP 200，**且** body 內 `version` 欄位必須等於本次 `git rev-parse HEAD`（完整 40 字元 sha）。版本不對齊 = rsync/build 未生效，立刻失敗。
2. `GET https://wordnexus.lol/api/health` — unauth 預期 401/403（受 `Depends(get_current_user)` 保護，代表 endpoint 存在 + auth 系統 wire 正常）。HTTP 404 = endpoint 從 router 消失，**視為跳過**而非失敗（保留向後相容空間）；HTTP 000/500 = 真的壞，失敗。
3. `SENTRY_VERIFY=1` 時：`GET /api/system/sentry-test` — endpoint 是 admin-only，unauth 預期 401/403；若 endpoint 已被移除（404）則 fallback 檢查 `/api/system/info` body 是否含 `sentry` 欄位作為「DSN 已讀取」的存在性證據。

任何一層失敗：紅字錯誤 + 自動印出容器最近 30 行 log + 非零 exit。build 失敗、版本不對齊或 smoke 失敗時 `deploy.log` 不寫入、Sentry 也不記錄；需人工 `./devops.sh logs 100` + 決定是否 rollback。

#### 控制 env

| Env | 預設 | 用途 |
|-----|------|------|
| `KG_SKIP_SMOKE=1` | 0 | 只跳過外部 smoke（CF → tunnel → host）；host 內 `/api/system/info` version == deploy_sha 對齊 gate 與 compose build 失敗仍為 fatal（緊急 deploy 用，不建議） |
| `SENTRY_VERIFY=1` | 0 | 額外加做 sentry endpoint 探測 |
| `SMOKE_BASE_URL` | `https://wordnexus.lol` | 改打 staging / 自訂 domain |
| `CURL_BIN` | `curl` | 注入 mock curl（測試專用，見 `ops/tests/test_deploy_smoke.sh`） |

預估開銷：3 個 curl 串行，每個 `--max-time 10`，順利情況下加 < 1 秒；失敗情境最多多 ~30 秒。

#### 排查

- `version=X 不等於 deploy_sha=Y` → rsync 沒同步 / VERSION 檔沒寫入 / 容器沒 force-recreate（`/api/system/info` 啟動時快取 `/app/VERSION`）。檢查 `run_remote "cat $REMOTE_DIR/VERSION"` 與 `docker compose ps`。
- `health 000` → 公網斷線、TLS 失敗、Caddy 沒起。`./devops.sh run "sudo systemctl status caddy"`。
- `health 500` → app 起來但 auth middleware 起火。看 `docker compose logs --tail=100`。
- sentry endpoint 期待 401 但拿到 200 → admin auth 失效，立即查 `get_admin_user`。

### Rollback：deploy 失敗後的具體動作

> ⚠️ `devops.sh` **沒有** 內建 rollback 子指令。回滾＝重 deploy 上一個版本 + 視情況還原 data 備份。完整禁用指令邊界見 [`docs/policy/safety.md`](../policy/safety.md)。
>
> 📋 **演練狀態**：以下步驟對照 `devops.sh` 實際指令邏輯撰寫，但**尚未在 staging 跑過完整 dry-run**。首次執行請 step-by-step 對照 `devops.sh` 對應 `cmd_*` 函式（行號見 §Step 註解），不要照抄一鍵跑完。事故發生時優先保留現場再動手。

**Step 0：先確認上次成功的 sha**

```bash
# 本地 deploy.log（位於 ~/kg/backups/deploy.log）
tail -5 ~/kg/backups/deploy.log
# 或遠端 VERSION 檔（容器啟動時讀的）
./devops.sh run "cat ~/knowledge_graph_api/VERSION"
```

每行格式 `<ISO-timestamp> sha=<short-sha> user=<who>`。倒數第二行通常是「上一個會動的版本」。

**Step 1：純程式碼問題（DB schema / data 未動）→ 回滾 code only**

```bash
cd ~/kg
git checkout <previous-sha>      # 例：git checkout c2f2a27
./devops.sh deploy               # 走 fast/full 自動判斷；DEPLOY_FULL=1 強制 full
./devops.sh status               # 確認 VERSION 已切回
```

注意：`devops.sh deploy` 會拒絕 dirty working tree（`DEVOPS_YES=1` 不再 bypass）。先 `git stash` 或在乾淨 tree 上 checkout。

**Step 2：DB migration 已執行 / 資料已被破壞 → 還原 data 備份**

`cmd_backup`（需手動執行；備份排程走 launchd `com.kg.backup`，deploy 不再自動備份）會先把 `$REMOTE_DATA_DIR`（standby `~/kg-data`，**不是** `$REMOTE_DIR/data`）rsync 到本地 repo 根的 `backups/data_<YYYYMMDD_HHMM>/`（`devops.sh:27`）（rsync 依 flavor 分流顯示進度：GNU rsync 用 `--info=progress2 --human-readable`，macOS 內建 openrsync 用 `--progress`）、跑 SQLite integrity check，再打包成 `backups/data_<YYYYMMDD_HHMM>.tar.gz` 並產生 `.sha256`。backup 會排除 `data/_ops_backups/` 與 `data/_ops_world_backups/`，避免把寫入工具產生的備份再備份一次。

rsync 若非零退出，`cmd_backup` 會**具名拒絕**（點出殘留的不完整目錄，並指向 standby 每日 S3 備份 `com.kg.backup` → `ops/kg_backup.sh`）後 exit 1，不再讓 rsync 自己印的 usage 當唯一失敗訊號。

```bash
# 1. 找最新的可信備份
ls -lht ~/kg/backups/data_*.tar.gz | head -5
# 2. 驗 checksum
sha256sum -c ~/kg/backups/data_<timestamp>.tar.gz.sha256
# 3. 停容器（不刪 volume！docker compose down -v 是鐵律 7 禁用）
./devops.sh run "cd ~/knowledge_graph_api && docker compose down"
# 4. scp 備份上去並用「原子 mv」還原 — 保留壞掉的 data 以便事故後回查 / 救回
scp -i ~/.ssh/lightsail_kg_prod ~/kg/backups/data_<timestamp>.tar.gz ubuntu@13.193.212.134:/tmp/
./devops.sh run "cd /tmp && tar -xzf data_<timestamp>.tar.gz && \
  sudo mv ~/knowledge_graph_api/data ~/knowledge_graph_api/data.broken.\$(date +%s) && \
  sudo mv data_<timestamp> ~/knowledge_graph_api/data"
# （鐵律 7 精神：data dir 不直接 rm -rf。data.broken.* 之後人工確認再清。）
# 5. 起容器並 health check（compose down 後容器已移除，restart 對不存在的容器無效，必須 up）
./devops.sh run "cd ~/knowledge_graph_api && docker compose up -d"
./devops.sh status
```

**Step 3：smoke verify 失敗但 health 200 → 部署只是部分壞**

通常是 Caddy 路由或 env drift 問題，**不要立即 rollback**：
- `./devops.sh env-drift` 查本地 / 遠端 `.env` 差異
- `./devops.sh logs 100` 看容器 log
- 修完 env / Caddy 後 `./devops.sh restart`（沒改 code 用 restart，比 deploy 快 10 倍）

**何時必須 rollback vs 何時前推修復**

| 情境 | 動作 |
|------|------|
| app 啟動就 crash / health 500 持續 | rollback code（Step 1）|
| 用戶資料被誤刪 / migration 寫壞 | rollback data（Step 2）|
| 只是 .env 或 Caddy 設定漂移 | 前推修（Step 3），rollback 反而更慢 |
| LLM provider 切換造成 4xx | 改 `LLM_PROVIDER_*` env → push-env → restart |

---

## 特殊情境 SOP

### 新增 / 修改 env 變數

```bash
# 1. 更新本地 .env
# 2. 同步更新 devops.sh 頂部的 REQUIRED_ENV_KEYS
./devops.sh push-env
./devops.sh deploy
```
**注意**：`.env` 變動不能只 `restart`，容器讀不到新值。

### 字典 lookup rollout 開關

四個 env（`settings.py`；索引見 `docs/reference/tech_index.md §Environment Variables`）：

| Env | 預設 | 作用 |
|---|---|---|
| `DICTIONARY_LOOKUP_ENABLED` | `false` | search/detail GET 的 rollout kill switch；`false` 時兩個 endpoint 都回 403 |
| `DICTIONARY_PROVIDER_DEFAULT` | `free_dictionary` | 非此值一律 403（Cambridge 是保留 seam，無持久化授權，不可開） |
| `DICTIONARY_CACHE_TTL_DAYS` | `30` | 正向快取 TTL |
| `DICTIONARY_NEGATIVE_CACHE_TTL_HOURS` | `24` | 負向（查無此字）快取 TTL |

旗標只控制純查詢 integration；開關任一方向都不會建立、改寫或遷移 Card。停用後以 search/detail 的 403 驗證止血，重新啟用後再驗正常查詢與 cache/provider 指標。

**回滾後檢查**：`ops_cli.py dictionary-health --json` 檢查 cache 組成、provider budget、lookup outcome 與 latency；不存在 per-user 字典資料修復步驟。

### App Store 訂閱驗簽必備 env

production 現在預設只接受 signed App Store payload。下列 key 缺一不可：

```bash
# .env 放 HOST 路徑（裸機 ops CLI 直接讀；oscar/felix 同 user 故兩機一致、可攜）
APP_STORE_ROOT_CA_PATH=/Users/chenliangyu/project/kg/backend/certs/apple_root_ca.pem
APP_STORE_CONNECT_ISSUER_ID=<issuer-id>
APP_STORE_CONNECT_KEY_ID=<key-id>
APP_STORE_CONNECT_PRIVATE_KEY_PATH=/Users/chenliangyu/project/kg/backend/certs/AuthKey_<key-id>.p8
```

> **容器部署的路徑分裂（2026-06-16，比照 `KG_DATA_DIR`）**：上列為 **host 路徑**；容器內 app 需 `/app/certs/…`，由 `docker-compose.yml` 的 `environment:` 注入並覆蓋 `env_file`。**勿在 `.env` 寫 `/app/certs`**——那會讓 host 裸機 ops CLI 讀不到 cert，且破壞 `.env` 兩機可攜性。

補充規則：
- `APP_STORE_ALLOW_UNSIGNED_SYNC` 不應在 production 設為 `true`
- `APP_STORE_ALLOW_UNSIGNED_NOTIFICATIONS` 不應在 production 設為 `true`
- `APPLE_BUNDLE_ID` 必須與 App Store Connect 訂閱商品所屬 app 相同

`./devops.sh env-check` 現在會同時檢查：
- 必要 App Store 驗簽 key 是否存在
- unsigned fallback 開關是否被錯誤打開
- backend 自己的啟動規則（直接呼叫 `kg.settings.load_settings` 與 `kg.llm.providers.validate_provider_routing`）：`JWT_SECRET` 存在、非佔位值、長度 >= 32，以及所有已路由 LLM provider 的 API key 非空；細節與 gate 範圍見 `docs/runbook/system.md`「部署前 env-check 的 backend 啟動規則」。env-check 不在 `deploy` 內自動執行，部署前請手動跑 `./ops/devops_kg_safe.sh env-check`；`release_train` 會執行並阻擋

`./devops.sh env-drift` 是手動／advisory 檢查，**deploy 不會自動執行**，drift 也不會讓 deploy 失敗；需要時自行跑，它檢查本地/遠端 `.env` 是否一致：
- 一般 key 要求值完全相同
- host-specific path key（例如 App Store cert path）允許本地/遠端主機路徑不同，但要求檔名一致且位於各自主機 repo 目錄下的 `certs/`（遠端為 `<遠端 repo 真實目錄>/certs/`，與上方 host 路徑 `.env` 佈局一致；不是容器內 `/app/certs`）
- 有 drift 時指令以非 0 結束（僅回報）

### Sentry 錯誤追蹤 **(SoT)**

Sentry 為 **opt-in** — `SENTRY_DSN` 留空時 SDK 完全 no-op，整層免費。本段為 Sentry 環境變數 / 取樣 / 隱私規範的權威來源；iOS bootstrap 程式碼層 wiring 見 `docs/sop/ios.md §Crash Reporting`，架構層概覽見 `docs/sop/architecture.md §Crash Reporting Layer`。

#### Backend env vars

| Env | Default | 用途 |
|-----|---------|------|
| `SENTRY_DSN` | （空）| 主開關；填入 DSN 才會啟動 |
| `SENTRY_ENVIRONMENT` | `production` | release/staging/dev 環境標籤 |
| `SENTRY_RELEASE` | `kg-backend@<`/app/VERSION` 內容>` | 顯式覆寫才設；deploy（reconciler／`devops.sh deploy`）把**完整 git sha** 寫進 `backend/VERSION`，SDK 回報的 release 與 deploy 後記錄的 release 逐字相同 |
| `SENTRY_TRACES_SAMPLE_RATE` | `0.0`（哨兵）| **非 0** 時整層 flat 取樣（debug override）；**0** 時走 per-path `_traces_sampler`：LLM hot paths（pipeline/translate/explain）0.05、health/info 0.0、其他 baseline 0.01 |
| `SENTRY_PROFILES_SAMPLE_RATE` | `0.0` | profile 取樣率（保留，目前生產不開）|

實作：`backend/src/kg/sentry_init.py`
- **Scrub**：`Authorization` / `Cookie` / `X-Admin-Token` header，含 `session` / `token` 的 cookie 鍵，OAuth query（`token` / `admin_session` / `code` / `id_token` / `access_token`）
- **Hardening**：`send_default_pii=False`、`include_local_variables=False`、`max_request_body_size="never"`、`attach_stacktrace=True`
- **User context**：auth dependency 透過 `bind_user(user_id)` 標記 scope，登出無 PII 洩漏
- **Logging**：WARNING+ 轉 breadcrumb，event_level=None 避免與 Starlette exception capture 重複
- 狀態暴露於 `/api/system/info`

Smoke test: `POST /api/admin/sentry/ping` after deploy to verify DSN wired — endpoint is admin-only, dispatches a `capture_message` + caught `capture_exception` via the SDK and returns `{sent, is_active, event_id}` JSON (never raises). 也可從 `/admin` dashboard 右上「Sentry Ping」按鈕直接觸發，按鈕旁顯示 event_id 前 8 碼或 `inactive (no DSN)`。

#### Release 整合（deploy 紀錄／iOS dSYM）

- **一次性使用者步驟**（`/api/system/info` 回 `"sentry":false` 時；`ops/doctor.py` 的 `sentry` 區塊會提示）：在 Sentry 建 backend project 取 DSN，寫進 felix `~/kg-prod/backend/.env` 的 `SENTRY_DSN=`，再於 felix `cd ~/kg-prod/backend && docker compose up -d --build --force-recreate`（只 restart 讀不到新 env）。接著建 scope `project:releases` 的 auth token，與 `SENTRY_ORG`、`SENTRY_PROJECT_BACKEND`、`SENTRY_PROJECT_IOS`（選填 `SENTRY_API_URL`，預設 `https://sentry.io/api/0`）寫入 `~/.secrets/sentry.env`（Syncthing 兩機同步）。
- **設定解析**：process env 優先，其次 `SENTRY_ENV_FILE`（預設 `~/.secrets/sentry.env`，只解析 `KEY=VALUE`、不 source）。`ops/sentry_api.py`、`ops/sentry_release.sh`、`ops/ios_ops.sh sentry` 的 `api_configured` 同一口徑；`./ops/sentry_release.sh check --json` 只回報 key 是否存在，不印值。
- **backend release 名稱**：backend SDK 回報的 release 是 `kg-backend@<VERSION>`（`VERSION` 取 `KG_VERSION`，其次 `/app/VERSION`＝deploy 寫入的完整 sha）；`SENTRY_RELEASE` 設了就**逐字**覆寫、不加前綴。deploy 記錄的名稱與預設值相同，所以設了 `SENTRY_RELEASE` 會讓 SDK 事件與 deploy 記錄的 release 對不上，除非刻意否則別設。
- **backend release 紀錄**：健康部署落地後（reconciler 的 `deployed`、`devops.sh deploy` 的 smoke 通過後），`ops/sentry_release.sh record-backend` 建立並 finalize `kg-backend@<完整 sha>`，再為 `production` 記一筆 deploy。best-effort：每個 HTTP 呼叫有 timeout、首次失敗即停，reconciler 另有總上限 `KG_RECON_SENTRY_TIMEOUT`（預設 45s）；缺設定印 SKIP、失敗只告警，**永不改變部署結果或 verdict**。回滾不記。
- **iOS dSYM**：`ops/ios_release.sh --upload` 在 archive 成功後把 `<archive>/dSYMs` 交給 `sentry-cli debug-files upload`（pinned `sentry-cli==3.8.0`，經 `uvx` 從 PyPI 官方 wheel 安裝；上限 `KG_SENTRY_DSYM_TIMEOUT`，預設 300s）。缺 token／org／project 時大聲 SKIP，失敗只告警，不讓 release 失敗；結果寫進 archive verdict 的 `sentry.dsyms`（`not-requested`／`ok`／`skipped`／`fail`）。不帶 `--upload` 的 archive 維持無對外副作用。

#### LLM Provider env vars **(SoT)**

LLM 走可插拔 provider registry（`backend/src/kg/llm/providers.py`）。所有 provider 皆 OpenAI-compatible，切換只改 env、不動 code。

| Env | Default | 用途 |
|-----|---------|------|
| `GEMINI_API_KEY` | （必填）| Gemini key；embedding 一律走 Gemini，故永遠必填 |
| `DEEPSEEK_API_KEY` | （空）| DeepSeek key；路由到 deepseek 時必填 |
| `LLM_PROVIDER_DEFAULT` | `gemini` | 所有 chat call_type 的預設 provider |
| `LLM_PROVIDER_TRANSLATE` | 繼承 DEFAULT | 整組 `translate_*`（quick / phrase / explain）|
| `LLM_PROVIDER_<CALL_TYPE>` | 繼承 group/DEFAULT | 單一 call_type 覆寫，如 `LLM_PROVIDER_JUDGE`、`LLM_PROVIDER_ENRICH` |
| `LLM_PROVIDER_EMBED` | `gemini` | embedding provider；**不繼承 DEFAULT**（DeepSeek 無 embedding 端點）|
| `GEMINI_MODEL` / `DEEPSEEK_MODEL` | registry 預設 | 覆寫該 provider 的 chat model |

- 路由優先序：`LLM_PROVIDER_<CALL_TYPE>` > `LLM_PROVIDER_<GROUP>` > `LLM_PROVIDER_DEFAULT` > `gemini`。
- `LLM_PROVIDER_JUDGE` 同時涵蓋 auto pipeline judge（call_type `judge`）與手動連結判定（call_type `judge_manual`）—— 兩者同屬 `JUDGE` group，一個旋鈕同步切換。
- 遷移 DeepSeek：設 `DEEPSEEK_API_KEY` + `LLM_PROVIDER_DEFAULT=deepseek`（embedding 自動留 Gemini）。分階段可只設 `LLM_PROVIDER_TRANSLATE=deepseek` 先驗證。
- 未知 provider 名、或把 `embed` 路由到無 embedding 能力的 provider → 啟動即 `ValueError`，不 silent fallback。
- A/B / prompt / provider 品質比較：使用 `lab/llm_eval/` workbench（需對應 key）。

#### iOS env / Info.plist

iOS 端（`ios/BooksAndVocab/Services/AppCrashReporting.swift`）：
- `Info.plist` `SentryDSN` 鍵為主開關（空 → 全 no-op）
- environment：`Info.plist` `SentryEnvironment` 有值即用；否則 Debug build → `debug`，TestFlight → `testflight`（啟動後立即以 StoreKit `AppTransaction` 的 sandbox 環境判定），App Store → `production`
- `releaseName = <bundleId>@<CFBundleShortVersionString>+<CFBundleVersion>`、`dist = CFBundleVersion`（區分共用版號的 TestFlight build）
- `tracesSampleRate`：release 預設 `0.05`、DEBUG 預設 `0.0`；env `SENTRY_TRACES_SAMPLE_RATE`（launch arg / scheme env）可覆寫
- DEBUG build 預設 `enabled=false`；`SENTRY_ENABLED_IN_DEBUG=1` 或 `-sentryTest` launch arg 啟用
- `setUser(id:)` 連動 `authManager.isLoggedIn` — 登出時清除避免多帳戶污染
- HTTP breadcrumb 自動 strip query string、`CancellationError`/`NSURLErrorCancelled` 由 `beforeSend` 丟棄

### 新增 Card Schema 欄位（SQLite）

```bash
# 1. 在 src/kg/cards/model.py 新增欄位（migration SQL 加在 cards/schema.py）
# 2. 在 devops.sh 的 cmd_migrate() 的 MIGRATIONS 清單加 SQL：
#    ALTER TABLE cards ADD COLUMN <col> <type> DEFAULT <val>;
#    （必須 idempotent，SQLite 不支援 IF NOT EXISTS，用 try/except）
./devops.sh deploy
```

### 首次部署 / 全新伺服器（Lightsail；rollback 重建用）

> standby 的機器層建置（OrbStack / cloudflared / launchd）見 butler `~/butler/docs/standby-host-setup.md`，**不走**下方 Lightsail+Caddy 流程。

```bash
# 1. 安裝 Docker
ssh ubuntu@13.193.212.134
curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh
sudo apt-get install docker-compose-plugin -y

# 2. 安裝 Caddy
sudo apt update && sudo apt install -y caddy
echo "wordnexus.lol { reverse_proxy localhost:8000 }" | \
  sudo tee /etc/caddy/Caddyfile > /dev/null
sudo systemctl restart caddy && sudo systemctl enable caddy

# 3. 部署
cd ~/kg
./devops.sh setup

# 4. 開放防火牆
aws lightsail put-instance-public-ports \
  --instance-name booksbrowser-kg-api-2gb \
  --port-infos \
    fromPort=80,toPort=80,protocol=tcp \
    fromPort=443,toPort=443,protocol=tcp \
    fromPort=22,toPort=22,protocol=tcp \
  --region ap-northeast-1
```

**重要**：Caddyfile 必須是全文反向代理（`reverse_proxy localhost:8000`），不要只代理 `/api/*`。

### 緊急只重啟

```bash
./devops.sh restart
```

---

## 部署失敗診斷

```
deploy 失敗
│
├─ env-check → 遠端 .env 缺 key → ./devops.sh push-env
├─ rsync → SSH 問題 → 測試 ssh -i ~/.ssh/lightsail_kg_prod ubuntu@13.193.212.134
├─ docker build → Python 依賴錯誤 → ./devops.sh logs 100
├─ migrate → SQL 語法錯誤 → 確認 MIGRATIONS 是 idempotent
└─ health check 非 200 → FastAPI 啟動失敗 → ./devops.sh logs 100
```

---

## 常用指令速查

`./devops.sh` 子指令完整清單(含 ops-cli / container-script / migrate-run / data_inspect 等進階指令)在 `devops` skill,由其作 SoT。日常常用：`status` / `logs [n]` / `users` / `user-info <id>` / `backup` / `env-check` / `env-drift` / `run "<cmd>"` / `push-env` / `migrate`;觸發 `devops` skill 取完整參考。

---

## 備份 SOP

> 🔒 **異地 S3 backup**：遷移後由 **standby launchd**（`ops/launchd/com.kg.backup.plist`，每日 11:00 台北 = UTC 03:00）跑 `ops/kg_backup.sh`，把 `data/` 串流上傳到 `s3://kg-backups-prod-967512079054/data/<UTC-date>.tar.gz`（同一 PutObject-only IAM principal `kg-backup-agent`）。舊 Lightsail `/etc/cron.d/kg-backup` 已停用。三層備份的過渡現實（L1 失效、L2 已於 2026-08-08 復役、L3 移 standby）與從零還原的權威 SOP 見 [`docs/sop/backup.md`](backup.md) / [`docs/sop/backup_restore.md`](backup_restore.md)，不是本段。`devops_kg_safe.sh backup-s3-test` 會呼叫 checkout 內的 `ops/backup_status.sh`，fail-closed 驗證 launchd job、最近穩定 log、exit=0、bytes、sha256、key 日期與 36 小時 freshness（`KG_ALLOW_LIGHTSAIL` guard 已於 2026-06-19 移除）。

本機冷快照（**首選**，L2）——從 standby 拉回本機並自動驗 integrity + sha256：

```bash
./ops/devops_kg_safe.sh backup
```

手動 `tar` 只在 L2 不可用時當退路。注意生產資料在 standby 的 `~/kg-data`（`~/project/kg` 是 dev-only clone，**備它會備到錯的東西**）：

```bash
ssh chenliangyu@100.118.39.104 'tar czf ~/kg_data_$(date +%Y%m%d).tgz -C ~ kg-data'
# WAL 一致性需冷快照：先 docker compose stop 再 tar
```

---

## 單 worker 不變式（勿改）

後端**必須以單一 uvicorn worker 部署**。`Dockerfile` 的 CMD 已顯式鎖定 `--workers 1`，**不可移除或調高**。

原因：部分狀態是 **process-local**，不跨 worker 共享：

- `quota_service._reservations` — in-flight 額度預留（PR #538）。多 worker 時每個 worker 各有一份，同用戶請求落在不同 worker 時預留互不可見，額度 over-spend 上限變成 `N_workers × 真實限額`，直接繞過額度防線。
- `routers/web_auth.py:_google_states` — Google OAuth 單次使用 state 簽發表（#2804）。多 worker 時 callback 落在與 login 不同的 worker 會因查無 nonce 回 400，scale-out 前必須改為共享儲存。部署／重啟會遺失進行中的登入 state（600s 視窗，用戶重試登入即可）。
- 同類 process-local state：`translate_service` 的 singleflight dedup、in-memory log capture、rate-limit 計數等。

未來若要 scale-out（多 worker / 多容器），**必須先**把上述狀態改為共享儲存（Redis / DB），才能解除單 worker 限制。

---

## Docker 資料安全

`docker-compose.yml` 的 `volumes: ${KG_DATA_DIR:-./data}:/app/data`（2026-06-16 起 data 移出 git worktree → felix host `~/kg-data`，見下方「路徑陷阱」）：
- ✅ `deploy` / `restart` 均不刪除 SQLite / embeddings / graph
- ✅ `restart: always`，伺服器重啟後自動恢復

---

## 路徑陷阱

| 路徑 | 有效位置 |
|------|---------|
| `/app/data/` | 容器內（`docker exec` 才能用） |
| `~/kg-data/`（felix） | **現役 host data 根**（2026-06-16 移出 worktree；`KG_DATA_DIR` 指向它，host 端 ops CLI 讀此） |
| `/home/ubuntu/knowledge_graph_api/data/` | ~~Lightsail host~~ 已隨 Lightsail terminate（保留為歷史） |

data 目錄由容器 root 寫入，host ubuntu user 無法直接 rm，需進容器操作：

```bash
./devops.sh run "docker exec knowledge-graph-api sh -c '<指令>'"
```

---

## rsync 手動指令（Lightsail only）

> standby 程式碼靠 git 同步（`git pull`），**不用 rsync**。下方僅適用回滾到 Lightsail。

```bash
rsync -avz --delete \
  -e "ssh -i ~/.secrets/lightsail_kg_prod" \
  --exclude '.venv' --exclude '__pycache__' --exclude '.git' \
  ~/kg/backend/ \
  ubuntu@13.193.212.134:~/knowledge_graph_api/
```
