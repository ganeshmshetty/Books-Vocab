<!-- doc-meta
tier: reference
authority: SoT
update_trigger: code-change
scope:
  - backend/ops_edit.py
  - backend/ops_cli.py
  - backend/src/kg/ops_cli_app.py
  - backend/src/kg/ops_cli_parser.py
  - backend/src/kg/ops_cli_queries.py
  - backend/src/kg/ops_cli_dictionary.py
  - backend/src/kg/ops_edit_app.py
  - backend/src/kg/ops_edit_commands.py
  - backend/src/kg/ops_edit_parser.py
  - backend/src/kg/ops_edit_shared.py
  - backend/src/kg/ops_world_projection.py
  - backend/src/kg/ops_world_expectation.py
  - backend/src/kg/ops_world_export.py
  - backend/src/kg/ops_world_diff.py
  - ops/ui_world_manifest.py
verified_against: 51ce9228ce64c1897850b8fcab672364b17f8731
-->
# Ops Product-State Plane（產品狀態控制面）

> 這份不重複 `tech_index.md` 的「什麼指令做什麼」。它管 index 裝不下的三件事：**雙面對齊契約**、**已知結構限制 ledger**、**官方牌組 emitter 的入口偏差**。改 `ops_edit` / `ops_cli` / projection 前讀這份，避免重踩已知坑。

`ops_edit`(寫)+ `ops_cli`(讀)不是「截圖假資料工具」,是同一份 production schema 上的讀/寫雙生面,服務 iOS / backend / admin / 截圖 / smoke / support 共用的同一資料世界。`KG_DATA_DIR` 是唯一生產↔sandbox 切換點,注入 sandbox dir 即**結構性**零生產風險(非紀律保證)。

## 1. 讀寫雙面對齊契約(加可斷言欄位前必讀)

兩面**物理隔離、無 schema version；public wrapper 與實作模組已拆開**:

- 寫面 `backend/ops_edit.py` 現在只是 thin wrapper；真正的 command dispatch 在 `backend/src/kg/ops_edit_app.py` + `ops_edit_parser.py` + `ops_edit_commands.py`。實際落地仍走 app per-user store（`CardStore` / `NotebookStore` / `GraphStore`），複用 NFC/dedup/graph merge，不重刻資料寫路徑。
- 讀面 `backend/ops_cli.py` 也是 thin wrapper；真正的 readonly control plane 在 `backend/src/kg/ops_cli_app.py`，再拆成 `ops_cli_parser.py` / `ops_cli_queries.py` / `ops_cli_observability.py` / `ops_cli_costs.py` / `ops_cli_dictionary.py` / `ops_cli_shared.py`。query 已不再塞在單一大檔，但仍是獨立於寫面的讀取邏輯。`ops_cli_dictionary.py` 只讀全域 `lexical_cache.db`，投影 provider/cache/budget/lookup health；lookup integration 沒有 per-user Card 寫面，故不適用下方的讀寫雙面對齊契約。缺 cache DB 或觀測表時回空健康面，不讀或推導使用者 Card。
- state-diff 的投影面 `project_user_world`（`ops_world_projection.py`）仍是**第三條獨立讀盤路徑**：cards 走 `_load_cards` 動態 SELECT，graph 走 `_load_graphs` 直讀 `graph_*.json`，刻意繞過 GraphStore 快取。
- seed-replay 的導出面 `export_seed_spec`（`ops_world_export.py`，`ops-cli world-export`）是**第四條獨立讀盤路徑**：與 projection 不同，它導出 seed 可**無損重放**的全欄位（含 review 計數器），`connect_ro` + 直讀 `graph_*.json`。它的對齊契約不是 expectation diff，而是 roundtrip 不變量（見 §1.1）。

**state-diff identity safety（#1094）**：`ops_world_diff` 對 notebooks 的 aliases／identities 及 graph／link keys 一律拒絕 duplicate；actual 或 expected 任一側出現重複都產生 mismatch，不以 last-write-wins 解析。沒有重複時仍維持 expectation 的 subset comparison，duplicate mismatch path 以穩定順序回報。

**後果(結構限制,非 bug)**:寫面寫進 DB 的欄位,讀面/投影面**不保證撈得到**。現在雖然已把 CLI/EDIT monolith 拆成模組,但三面仍各自演進；新增欄位若沒同步到 readonly query 與 projection,照樣會 silent drift。

**verbatim-safe 判準**——一個欄位可被「導出 expectation 並斷言」**當且僅當**:

```
可斷言  ⟺  (ops_edit 直寫)  ∩  (project_user_world projection 有 SELECT surface)
```

寫進 DB **不充分**,projection 必須也撈得到。否則導出的 expectation 會對真讀盤產生 false `missing-key` mismatch。

`project_user_world._load_cards` 當前 surface（PRAGMA 動態裁剪）:
`id / content / meaning / notebook_id / mode / review_count / review_streak / lapse_count / review_interval_hours / next_review_at / last_reviewed_at / source`。

**踩過的坑(回歸測試已固化)**:
- `pos` —— `ops_edit` 寫入但 `_load_cards` 不撈 → 不可導(`test_pos_excluded_not_surfaced_by_projection`)。
- `source` —— seed 裡是 nested object,落 DB 是轉換後字串 → 導 raw 會 false-fail。
- `review` 聚合 / active-notebook(name→id)—— 是 intended transform,導 raw false-fail、導 computed 是 tautology → 一律不導。

**加新可斷言欄位的 checklist**:① 確認 `ops_edit` 直寫該欄(非 store 衍生);② grep `_load_cards`/`_load_graphs` SELECT 確認 projection 撈得到該**原始值**(非 transform 後);③ 在 `ops_world_expectation.py` 的 `_*_VERBATIM_FIELDS` 加欄;④ 跑 real-parity(`test_ops_world_expectation.py::TestRealParity`)→ `mismatches==[]` + tamper 必 FAIL。少任一步 = drift 風險。

防 tautology 鐵則:**derive 只讀宣告 spec,絕不讀 DB**;diff 的 actual 側才走真讀盤。兩條路徑獨立才有鑑別力。

### 1.1 world-export ↔ seed 的 roundtrip 契約（改 seed 欄位 / export surface 前必讀）

`ops-cli world-export <uid> [--out]` 把帳號 vocab 層 dump 成 `ops-edit seed` 相容 spec（`kg.seed_spec.v1`），是 UI World seed **可復現性**地基。它與 seed 之間的不變量（`test_ops_world_export.py::TestRoundtrip` 固化）：

```
seed(spec) → export → seed(新沙盒) → export  ⇒  兩份 export 相等（payload 無 uid/路徑 → byte 相等）
```

支撐這條不變量的設計約束，**改任一面都必須守住**：

- **欄位對稱**：export 導出的每個欄位，seed 必須吃得進去且無損落盤。現況全集 = notebooks(`name/color/cover_pattern/sort_order/is_default` + `source_shared_deck_id` 與 `source_version` omit-if-null) + cards(內容欄 + `root_form/inflections/is_archived` + review 7 計數器 + `source` 與 `source_shared_card_guid` omit-if-null) + links(content 參照)。**`source` 不是原樣回顯 DB 字串**:一律過 `VocabSource` 收斂到 **seed 會落盤的那個形**（`model_dump(exclude_none=True)`:去 null 鍵、鍵序依 model 宣告、丟未知鍵；`_canonical_source`）。理由是這欄有兩個形狀不同的寫面——生產 `vocab_intake.py` 走 `model_dump_json()` **保留 null 鍵**，seed `ops_edit_support._source_to_json` 走 `exclude_none=True`——原樣回顯會讓 export A 多一個 `"url": null`、seed B 落盤時去掉、export B 就少一個鍵,上面那條 fixpoint 對**每張真實有 source 的卡**破功(VocabSource 三個 optional 欄位,任何具體來源必留至少一個 null:book→url、web→chapter)。export 與 seed 因此共用同一個 source 權威,而不是各自手寫一份欄位表。**給 Card/Notebook 加新欄位時，export 與 seed 要同 PR 對齊**，否則 roundtrip 靜默有損。
  - **欄位分類的機器可驗證來源（不再是散文紀律，IMP-0016）**：`ops_world_export.py` 的 `EXPORTED_CARD_COLUMNS` / `EXPORT_IGNORED_CARD_COLUMNS` / `EXPORTED_NOTEBOOK_COLUMNS` / `EXPORT_IGNORED_NOTEBOOK_COLUMNS`（EXPORTED 的值 = 該欄在 payload 的路徑；IGNORED 的值 = 不導的理由，不得空白）。`test_ops_world_export.py::TestFieldSymmetry` 守兩條鏈：① 對 **model**——兩集合聯集恰等於 `Card` / `Notebook` 的欄位集且互斥，**加欄位而未表態即紅**；② 對 **emitter**——EXPORTED 的每條路徑都要真的出現在 export 輸出（防死宣告），且 export 不得吐出未宣告的鍵。常數必須手寫 literal，**禁止**從 model / PRAGMA 反射產生（那會讓宣告恆等於現實、lint 淪為 tautology）。roundtrip fixpoint（`export_a == export_b`）抓不到這個方向：兩份 export 出自同一個 emitter，從沒導出的欄位永遠不會被想念。
  - **Phase 2 shared-deck copy 的對稱點**（`ops_world_export.py`↔`ops_edit_seed_commands.py`）：① card `source_shared_card_guid` 為 omit-if-null，export 只在非 NULL 時 emit key、seed 以 `key in c` 對稱吃進，原生建立的卡維持 NULL、byte-equal roundtrip 不破；② notebook 的 `source_shared_deck_id` 與 `source_version` 各自 omit-if-null，必須逐欄獨立 emit/ingest，稀疏值由 `test_notebook_provenance_columns_emit_independently` 釘住；③ `is_staged`（複製中暫存本）whitelist out，export/projection 在 `is_deleted=0` 之上再排除 staged，半成品永不進資料世界。
- **確定式排序不依賴不可重放值**：排序鍵禁用 created_at / 隨機 id（跨沙盒重放後會變）——notebooks 按 `(sort_order, name)`、cards 按 `(notebook name, content)`、links 按 `(notebook name, from, to, kind)`；datetime 一律正規化 aware UTC isoformat（寫面 naive/aware 落盤不一，export 統一）。
- **review 雙形式**：seed 的 `review` 接 legacy `{state,interval,anchor?}`（語意態，anchor 推導時間，**行為凍結** —— `ops/demo/demo_dataset.json` 等既有消費者依賴）與計數器形式（7 欄直設；`review_count>0` 必帶 `last_reviewed_at`，並經 `synthesize_many` 合成 `review_events.db`，uuid5 event_id 去重冪等）。兩形式混用 fail-loud。export 一律產計數器形式。
- **不可重放資料不進 payload**：孤兒卡（notebook 已刪）、斷鏈 link（端點卡已刪）走 stderr warning，stdout 維持純 spec JSON；active notebook 同名多本、卡 meaning 空白 → export fail-loud（seed 無法重放）。
- **`seed --replace` 與本節的 roundtrip 契約正交（IMP-0024）**：`--replace` 只改「灌之前先不先清空整層 vocab」，不改 spec schema、不改任一欄位的攝入語意，故 `kg.seed_spec.v1` 與上面的 fixpoint 不變量都不受影響（`test_seed_export_seed_export_is_fixpoint` 走的仍是 additive 路徑）。它要修的是另一件事：additive 路徑的 `CardStore.add` 查重綁 `(content, notebook_id)`，所以把既有帳號 **reshape 成結構不同的 spec** 時，「換過本的同一個字」會新增第二張卡而非搬移；而舊 verify 判準 `total >= len(cards)` 對這種殘留只會報綠。replace 路徑因此改用精確形狀比對（`_seed_replace_verdict`：`len(actual) == len(expected)` ∧ 雙向集合差為空，鍵為 `(notebook_id, normalize_nfc_lower(content))`）。**三個 clause 各抓一種說謊，不可只留一個**：集合差抓「換過本 / 殘留在舊本」，筆數相符（`expected_cards`）抓「同本大小寫變體」（正規化後 key 相同，集合差看不見它），`dangling_config` 抓「卡的形狀全對但 `vocab_ui.active_notebook_id` 指向被清掉的本」——`--replace` 刻意不動 identity/users.json，所以每次 reshape 都會製造這個懸空指標，而只看卡的判準會報綠。非 replace 路徑的判準與回傳鍵刻意一字未改——additive 語意下既有卡本來就該留著，`>=` 在那裡是對的（唯一例外是 `plan["replace"]` 這個布林鍵無條件出現）。**另一道防線在 wipe 之前**：`_prevalidate` 在 replace 下要求 `cards[]`/`links[]` 的 `notebook` 只能引用本 spec 宣告的本或 `"default"`，否則 dry-run 當場紅——additive 路徑「可指既存 notebook」的合法來源正是 replace 要清掉的東西，少了這道預驗就會先毀後驗（清空整層才在 `_resolve_nb` 撞紅，而輸出寫著 `"committed": false"`）。
  - **壞掉的 `card.source` 走 warning 不走 abort（IMP-0016 review，刻意的 backup/restore 取捨）**：非法 JSON / 非 JSON object / 不符 `VocabSource` schema 三種都**只略過該欄位**並在 stderr 印一條**具名到卡 content 的 warning**，該卡其餘欄位照導、export rc=0、stdout 仍是可被 seed 重放的純 spec JSON。被否決的兩個選項寫在 `_canonical_source` docstring 裡：原樣回顯 → seed 重放整份 spec 被拒＝備份等於不可用；raise / 未捕捉例外 → 一列壞資料讓整個帳號導不出來（exit 1 + 0 byte stdout + traceback），是 backup 面最糟的失敗模式。此路徑今日無寫面會踩到（兩個寫面都先過 `VocabSource` 驗證），是防禦性的。回歸 `test_unreplayable_source_warns_and_keeps_snapshot_obtainable`（含「產出的 spec 真的被 seed 吃得回去」而非只是「看起來像 spec」）。
- **`is_default: true` 映射預設本**：seed 遇 is_default entry 直接更新 id=`default` 的既存預設本（可改名，不增殖新本），否則 export 的預設本重放後會變成第二本普通 notebook、roundtrip 破功。
- **review events 不在 export 範圍**：export 只涵蓋 cards.db 聚合；重放側由計數器重新合成逐筆事件（legacy seed 的世界本來就無事件，重放後會多出合成事件 —— 這是計數器形式的契約，不是 drift）。
- **link 卡對唯一**：app 語意一對卡至多一條 active link（`add_link` 對既存 pair 拋 ConflictError）。legacy graph 同 pair 存多條時，export 確定式保留 sorted 首條、其餘 stderr warning 略過——照導會產出重放時被冪等吸收的 spec，roundtrip 破功（真實案例：000287 divisiveness↔division 雙向兩條）。
- **export 恆唯讀、無 dry-run 語意**：`world-export` 是 ops-cli 讀面指令，沒有 `--commit` 旗標，任何模式下執行都只讀盤（測試以 cards.db sha 不變固化）；「dry-run 才安全」的心智模型不適用也不需要。
- **下游消費者（Phase 2）**：`ops/demo/build_demo.py emit-ios --spec <export產物> --out <path> [--plan <kg.history_plan.v1>]` 把 seed spec 投影成 iOS UI World v2 fixture（投影規則 SoT = `ops/demo/spec_world.py`）。`--plan`（需搭 `--spec`）額外把 review 時鐘凍結在 plan anchor 末刻＝`anchor_day + 24h − max(render_utc_offset) − 1s`，只動 3 個 `review_settings_progress_*` 鍵 × 兩 store（epoch int），其餘 domain byte-equal baseline；validator（`emit_ios._validate_review_clock_overlay`）鎖死只允許這 3 鍵偏離。給 export payload 加/改欄位時，除 seed 對稱外也要確認 spec 投影是否需要跟進（contract 見 `docs/reference/tech_index.md` fixture 契約段）。

## 2. 已知結構限制 ledger（疊 scenario 層前須知）

| # | 限制 | 現況 | 證據 / 須知 |
|---|------|------|------------|
| ① | 跨檔交易 + 單帳號快照含 identity | **已補** | 單帳號 backup 內嵌該 uid 的 `users.json` record + scoped email_index；`restore` 能一起回復 config/identity。原「users.json 不在 tar」破口已關。 |
| ② | 整世界 snapshot/restore | **已補** | `world-snapshot` / `world-restore` 已進 control plane；`backup_world` 含 `users.json`，落 `_ops_world_backups/`。`world-restore --commit` 先取得 `.worker.lock` flock，執行中的 API 持鎖時拒絕且不寫任何檔（`.worker.lock` 不參與還原刪除／覆寫）。同一把鎖也守 `seed --replace --commit` 與 `clone-demo --commit`（它們會 unlink 活體 vocab inode；鎖覆蓋 backup→apply→verify，dry-run 不取）。 |
| ③ | 讀寫不對齊 | **仍在(結構)** | 寫面 store / 讀面模組化 query / 投影面第三路徑，仍無共用 schema version。見 §1。state-diff 必經 `project_user_world` 自定義投影；投影面遇不可讀資料會以 `WorldProjectionError` fail-loud，真正的空資料仍投影成空。 |
| ④ | 冪等語意不一致 | **仍在(刻意)** | `link-add` 冪等但**不更新** confidence/kind/reason，只有 `--if-exists update` 會覆寫；`seed` 是 upsert 覆蓋核心欄；`clone-demo` 是全覆蓋先清後換。三種重跑語意不同，造景前要知道你在用哪種。 |
| ⑤ | graph = per-notebook JSON + 快取 | **仍在(設計)** | `_load_graphs` 直讀 `graph_*.json` 繞快取。任何 graph 斷言/驗證**必讀磁碟**，不可信 GraphStore in-memory 態。ops-edit／restore 從另一個 process 改 `graph_*.json`／`blocked_*.json` 後，API 的快取實例在下次 `create_graph_store` 依檔案簽章（inode、mtime、size）重新同步；之後的 flush 只把自己的 pending 變更 replay 到現行檔案，不會讓已刪的 link 復活，也不會把改過的 link 寫回舊值（#2086）。單一 link 的 mutator（update／hide／unhide／hard-delete／deprecate／restore）開頭也會先同步，編輯的是對方最新的 row；殘餘限制：同一 link 在「mutator 同步後、flush 前」的毫秒級窗口被另一 process 改動時，flush 仍是 row 級 last-writer-wins（本實例的整列覆蓋對方的欄位）。檔案無法解析（損毀且無可用 .bak）時快取原樣續用並記 warning，不當成空圖譜；外來的畸形 row 被略過（留在磁碟、不進記憶體）。candidates／pending_judge 不在此機制內。 |
| ⑥ | clone-demo 綁來源真實內容 | **仍在(本質)** | byte-clone 來源 vocab 層,可重現需 `--expect-source-fingerprint` 鎖來源 uid,否則來源漂移會改 clone 結果。 |

③④⑤⑥ 不是待修 bug,是**疊 scenario/replay 層時要繞開或顯式處理**的已知地形。補坑優先序由實際 world-reset 需求決定,不為補而補。

## 3. 官方牌組注入 emitter（build_official.py）入口偏差宣告

共享牌組庫（Explore）的官方內容注入走**獨立 emitter** `ops/official_decks/build_official.py`，**不是** `ops_edit` subcommand——仿 `ops/demo/build_demo.py` 的 SoT→emit→`--check` drift-gate 範式（git-committed `kg.official_deck.v1` spec → emit 進全域 `shared_decks.db` catalog、`source='official'`/`owner_id=NULL`）。

**為何不掛 `ops_edit`（入口偏差理由）**：

- `ops_edit` 的 `EditContext` 假設 **per-user `user_dir`**（backup/verify/audit 全繞 `backup_user_dir`）；`shared_decks.db` 是 **root-level 全域 store**（OUTSIDE `users/<uid>/`），不在該 scope 內。`build_official.py` 改走 `backup_world`（label `shared-decks-official`，涵蓋 root-level DB）+ 手動 `append_audit`（schema `kg.official_deck_injection.v1`），複用 `EditContext` 的 dry-run 預設 / `--commit` gate 契約精神，但不硬套 per-user 假設。生產注入 approval-gated（U6 precedent），不 auto-deploy。
- 對齊 `build_demo`：官方策展內容與 demo 帳號同屬「git-SoT → emit → `--check`」家族，語意一致、各自獨立 emitter，不與 `ops_edit` 的 per-user 讀寫雙面混淆。

**notebook-scoped export projection（world-export 單 notebook 模式）—— Phase 1 deferred**：架構 SoT（`docs/plans/2026-07-09-shared-decks-library.md §5.3`）原列「world-export 新增單 notebook content-only 模式（strip SRS + force `is_default=false` + assert `card_count>0`）」作發布前置。Phase 1 **刻意不實作**：

- 官方 spec 是 `kg.official_deck.v1`（直接描述 deck content plane），與 `world-export` 產出的 `kg.seed_spec.v1`（§1.1，整帳號 vocab 層 replay spec）**shape 不同**——不是免費 reuse。
- curator 產 spec 是**一次性便利**（可 world-export 拋棄式 scratch 帳號、手動裁剪成 official spec 再 commit），**非 consumer-facing blocker**；不值得在 Phase 1 為它擴 `world-export` 投影面。
- 要做時擴 `ops_world_export.py` 加 `--notebook <id>` content-only 模式，仍須守 §1.1 的欄位對稱與確定式排序不變量。

---
相關:`tech_index.md`(指令/schema 速查)、`product_surface.md`(能力清單)、`docs/sop/architecture.md`(iOS↔backend storage)。
