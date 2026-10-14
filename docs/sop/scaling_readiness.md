<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - backend/
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# 水平擴展整備 (Scaling Readiness)

> **狀態：設計文件，未實作。** 本文件盤點後端目前釘死在 **single-worker** 的
> process-local 狀態、釘死它的不變量，以及未來真要水平擴展時的遷移路徑與
> andon 觸發門檻。**現階段（無真實用戶、僅作者自測）single-worker 是正解**，
> 不引入 Redis / 額外協調層。本文件只備未來，不是現在要做的工作。

## TL;DR

- 後端正確性目前**依賴單一 Uvicorn worker**。四處關鍵狀態存在於 process 記憶體，
  跨 worker 不共享；多開 worker 會放大額度超支、破壞 singleflight 去重、製造
  pipeline 孤兒競態。
- 這個不變量被兩道防線釘死：`worker_guard` 的 `flock`（fail-loud）與
  Dockerfile 的 `--workers 1`。
- 真要擴展前，四處狀態都必須先搬到共享儲存（Redis / DB）。在那之前，擴 worker =
  正確性 bug，不是效能優化。

## 一、Process-local 狀態與 single-worker 不變量

| # | 狀態 | 位置 | 跨 worker 多開的後果 |
|---|------|------|----------------------|
| 1 | 額度 in-flight reservation | `backend/src/kg/quota_service.py:138`（`_reservations`） | 每個 worker 各持一份 `_reservations`，有效超支天花板變成 `N × 真實 per-user 上限` |
| 2 | translate singleflight 去重表 | `backend/src/kg/translate_service.py:31`（`_INFLIGHT`） | dedup 只在單 process 內生效；N worker → 同一 (word, context) 最多被重複翻譯 N 次，浪費成本且競態 |
| 3 | pipeline 孤兒 reap | `backend/src/kg/pipeline_log.py:71`（`reap_orphaned_runs(data_root)`，API startup 取得 worker 鎖後對 `settings.data_dir` 觸發） | 每個 worker 啟動都跑一次 reap；多 worker 同時 reap 會互相把對方仍在跑的 `running` row 誤判成 `interrupted` |
| 4 | Google／Apple web OAuth 單次使用 state 簽發表 | `backend/src/kg/routers/web_auth.py`（`_google_states`、`_apple_states`） | login 與 callback 落在不同 worker → 查無 nonce 回 400；需共享儲存才能 scale-out。重啟會遺失進行中的 state（600s 視窗） |

### 不變量如何被釘死

- **`worker_guard.assert_single_worker`**（`backend/src/kg/worker_guard.py:35`）：
  每個 worker process 啟動時對 `<settings.data_dir>/.worker.lock` 取**非阻塞 exclusive `flock`**
  （`fcntl.LOCK_EX | LOCK_NB`）。第二個 worker 搶不到鎖 → raise → 拒絕啟動。
  這是 fail-loud 不變量：誤把 worker 數調大於 1，第二個就**不會默默跑壞資料**，
  而是直接開不起來。由 `app_lifespan` 在 startup 呼叫
  （`backend/src/kg/app_lifespan.py:53`）。
- **Dockerfile `--workers 1`**（`backend/Dockerfile:58`，含警示註解 `:56`）：
  容器層硬性 single-worker。註解明文「`--workers 1` 是硬性不變式，勿改」。

> 兩道防線**互補非冗餘**：Dockerfile 是宣告意圖，`worker_guard` 是執行期保險——
> 即使有人在別處（compose / k8s / 手動 uvicorn）把 worker 數調大，第二個 worker
> 仍會被 flock 擋下。

## 二、遷移路徑（真要擴展時）

四處狀態的搬遷彼此獨立，可分批做；但**任何一處未搬完就擴 worker = 正確性回歸**。

### 1. 額度 reservation → Redis

- 把 `_reservations`（記憶體 dict + `threading.Lock`）換成 Redis：
  per-user 累計用 `INCRBYFLOAT` / 或 reservation set + TTL；release 走原子 `DECR` /
  `SREM`。`_reservation_lock` 的 critical section 改成 Redis 原子操作或
  `WATCH/MULTI` 樂觀鎖。
- 不變量保持：「sum(outstanding) + 本次 estimate ≤ per-user 上限」必須在單一原子步
  完成，避免 check-then-act 競態。
- reservation 需 TTL / 看門狗，避免 worker crash 後留下永不釋放的孤兒 reservation
  （現行 process-local 版 crash 即清空，Redis 版要顯式處理）。

### 2. translate singleflight → Redis SETNX + pub/sub

- `_INFLIGHT`（`dict[key, asyncio.Future]`）的跨 process 等價物：
  `SET <inflight_key> <leader_id> NX EX <timeout>` 搶 leader；搶到的 worker 做實際
  翻譯，做完把結果寫共享快取並 `PUBLISH` 完成事件；沒搶到的 worker `SUBSCRIBE`
  等該 key 的完成通知（對齊現行 `_INFLIGHT_WAIT_TIMEOUT_S=120` 的等待語義）。
- 注意：跨 process 的 future 等待要有逾時與 leader-死亡 fallback（leader crash →
  NX key 過期 → 後續 worker 重新搶 leader），不能無限等。

### 3. pipeline reap → leader election 或共享 lock

- reap 是「全域只該跑一次」的操作。多 worker 下改為：
  - **leader election**：用 Redis lock / lease 選出單一 reaper，只有 leader 在
    startup（與週期性）跑 `reap_orphaned_runs`；或
  - **共享 advisory lock**：reap 前取一把跨 process lock，拿不到就 skip。
- 另需重新定義「孤兒」判準：single-worker 下「startup 時還是 running = 上次 crash
  殘留」成立；多 worker 下某 row 的 running 可能屬於**另一個活著的 worker**，必須改用
  心跳 / lease 過期判定，不能單看狀態。

### 4. Google／Apple state → shared store

- `_OAuthStateStore`（Google、Apple 各一個實例）的語義（簽發、單次消耗、600s TTL、容量上限）原樣搬到共享儲存即可：
  Redis `SET nonce 1 EX 600`（簽發）＋ `GETDEL nonce`（消耗，原子單次），或 DB 表加
  `expires_at` 並以 `DELETE ... RETURNING` 消耗。
- 搬遷前 login 與 callback 必須落在同一 worker，否則 callback 因查無 nonce 回 400。

## 三、Andon 觸發門檻（何時才真正動手）

在以下訊號出現**之前**，single-worker 是正解，不要為了「未來可能」提前引入 Redis
的維運與失效模式複雜度。任一門檻觸發 = 升級評估，不是自動開工。

- **threadpool 飽和**：FastAPI 把 sync handler 丟 threadpool（anyio 預設 40 個 token）；
  external API 的 `async def` route 在 admission 後也經 `run_in_threadpool` 共用這個池。
  觀測到 threadpool 佇列持續積壓、請求在等執行緒（而非等 I/O）→ 單 worker 的並行度
  封頂訊號。
- **並發用戶 > X**：實測單 worker 在目標 p95 下能穩定服務的並發上限被逼近
  （X 待第一次容量壓測校準後填入；現況無用戶，數字尚未量測）。
- **p99 latency 退化**：核心端點 p99 在無外部依賴退化的前提下持續上升，且歸因到
  CPU / GIL / 單 process 串行，而非 SQLite I/O 或 LLM 上游。
- **SQLite busy_timeout 競爭上升**：`busy_timeout` 命中率 / 寫鎖等待時間上升——
  這是「再加 worker 也會更糟」的訊號（多 worker 對同一 SQLite 檔競爭更兇），代表
  瓶頸在儲存層，擴展前要先處理 DB（連線池 / 遷移到 server-class DB），而非直接多開
  worker。

## 四、明確結論

現階段（無真實用戶、僅作者自測）**single-worker + process-local 狀態是最乾淨、
最少失效模式的正解**。本文件存在的唯一目的，是讓未來「真的需要水平擴展」那一刻，
不必重新考古：哪些狀態要搬、怎麼搬、以及在哪個訊號之前都不該搬。

## 相關

- 部署與 worker 不變量：`docs/sop/deploy.md`
- 後端架構脈絡：`docs/sop/architecture.md`
- 程式碼錨點：`quota_service.py` / `translate_service.py` / `pipeline_log.py` /
  `worker_guard.py` / `app_lifespan.py` / `Dockerfile`（行號見上表）
