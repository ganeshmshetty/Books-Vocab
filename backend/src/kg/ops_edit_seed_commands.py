from __future__ import annotations

import argparse
import json
import shutil
import tarfile
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from functools import partial
from pathlib import Path
from typing import Any

from kg.demo_review_synth import CardReviewState, synthesize_many
from kg.graph.models import LinkKind
from kg.ops_shared import data_dir
from kg.review_events import ReviewEventStore
from kg.user_store import load_users_from

from .ops_edit_shared import (
    EditContext,
    EditError,
    assert_safe_uid,
    backup_world,
    emit,
    user_dir_for,
    users_file,
    world_backup_root,
)
from .ops_edit_support import (
    _CLONE_TMP_SUFFIX,
    _VALID_REVIEW_STATES,
    _WORLD_BACKUP_ROOT,
    _assert_clean_notebook_name,
    _card_store,
    _clone_source_files,
    _clone_source_fingerprint,
    _count_active_cards,
    _count_graph_links,
    _count_review_events,
    _graph_store,
    _is_vocab_file,
    _list_world_backups,
    _notebook_store,
    _parse_seed_datetime,
    _passthrough_normalize,
    _read_card_review_states,
    _replace_world_from_snapshot,
    _resolve_card_in_notebook,
    _review_fields,
    _source_to_json,
    _sqlite_online_backup,
    _world_members,
)
from .text_utils import normalize_nfc_lower

# 擴充 review 形式(計數器直設,`ops_cli world-export` 的無損重放面)的合法鍵。
_REVIEW_COUNTER_KEYS = frozenset(
    {
        "review_count",
        "review_streak",
        "lapse_count",
        "review_interval_hours",
        "next_review_at",
        "last_reviewed_at",
        "last_review_feedback",
    }
)


def _review_form(rv: Any, label: str) -> str:
    """判定 card review 形式:legacy ``state`` / 擴充 ``counters`` / ``none``。

    兩形式混用 fail-loud —— state 是「語意態 + anchor 推導時間」,counters 是
    「絕對值直設」,混填會產生互相矛盾的欄位來源。
    """
    if not isinstance(rv, dict):
        return "none"
    has_state = rv.get("state") not in (None, "")
    has_counters = any(k in rv for k in _REVIEW_COUNTER_KEYS)
    if has_state and has_counters:
        raise EditError(f"{label} 不可混用 state 形式與計數器形式:{sorted(rv)}")
    if has_counters:
        return "counters"
    if has_state:
        return "state"
    return "none"


def _parse_review_counters(rv: dict[str, Any], label: str) -> dict[str, Any]:
    """擴充 review 形式 → card update 欄位(僅回傳 spec 有宣告的鍵)。

    嚴格白名單鍵(typo fail-loud,對齊 seed 其餘預驗風格);``review_count > 0``
    必須帶 ``last_reviewed_at``:它是 review events 確定式合成的時間錨
    (對齊 `_read_card_review_states` 的合成前提),缺錨的計數器會產出
    iOS heatmap/streak 對不上的半套狀態。
    """
    unknown = set(rv) - _REVIEW_COUNTER_KEYS
    if unknown:
        raise EditError(f"{label} 計數器形式含未知鍵 {sorted(unknown)}(允許 {sorted(_REVIEW_COUNTER_KEYS)})")
    out: dict[str, Any] = {}
    for key in ("review_count", "review_streak", "lapse_count"):
        if key in rv:
            val = rv[key]
            if isinstance(val, bool) or not isinstance(val, int) or val < 0:
                raise EditError(f"{label}.{key} 須為 >= 0 整數:{val!r}")
            out[key] = val
    if "last_review_feedback" in rv:
        val = rv["last_review_feedback"]
        if isinstance(val, bool) or val not in (-1, 0, 1):
            raise EditError(f"{label}.last_review_feedback 須為 -1/0/1:{val!r}")
        out["last_review_feedback"] = val
    if "review_interval_hours" in rv:
        val = rv["review_interval_hours"]
        if isinstance(val, bool) or not isinstance(val, (int, float)) or val <= 0:
            raise EditError(f"{label}.review_interval_hours 須為 > 0 數值:{val!r}")
        out["review_interval_hours"] = float(val)
    for key in ("next_review_at", "last_reviewed_at"):
        if key in rv:
            out[key] = _parse_seed_datetime(rv[key], f"{label}.{key}")
    if out.get("review_count", 0) > 0 and out.get("last_reviewed_at") is None:
        raise EditError(f"{label}: review_count > 0 需同時提供 last_reviewed_at(review events 合成錨點)")
    return out


def _seed_shape_diff(expected: list[dict[str, Any]], actual: list[tuple[str, str]]) -> tuple[list[str], list[str]]:
    """spec 期望的卡片形狀 vs 磁碟實況,回 ``(extra, missing)``。

    比對鍵是 ``(notebook_id, normalize_nfc_lower(content))`` —— 與 `CardStore.add`
    的查重(``content = ? COLLATE NOCASE AND notebook_id = ?``)及
    `CardStore.find_by_content` 的 ``content_nfc_lower`` 索引同鍵,否則大小寫 /
    NFD 差異會被誤報成 extra+missing 一對。**按本比對而非只按 content**:跨本
    同 content 是合法形狀(見 `test_cross_notebook_same_content_verify_ok`)。
    """
    exp = {(c["nb_id"], normalize_nfc_lower(c["content"])) for c in expected}
    act = {(nb, normalize_nfc_lower(ct)) for nb, ct in actual}
    extra = sorted(f"{ct}@{nb}" for nb, ct in act - exp)
    missing = sorted(f"{ct}@{nb}" for nb, ct in exp - act)
    return extra, missing


def _dangling_active_notebook(dd: Path, uid: str, live_nb_ids: set[str]) -> list[str]:
    """`vocab_ui.active_notebook_id` 是否指向已不存在的 notebook(回具名理由清單)。

    **讀 users.json 的任何失敗一律收斂成一筆紅,絕不往外拋。** 呼叫點在
    `EditContext.run` 的 verify 階段,而 `verified = verify_fn()` 在它的
    try/except **外面**(except 只包到 apply),且此時破壞性 wipe 已經落地。
    裸 traceback 會污染 `--json` stdout —— `cmd_seed` 自己為 spec 解析捍衛過
    同一條契約 —— 而 operator 會拿到空 stdout 卻已經沒有資料。

    壞掉**不轉綠**:`backup_user_dir` 走的 `_load_users_json_raw` 刻意容忍壞
    JSON(所以前面不會先擋下來),但這裡若也跟著容忍成 `{}`,壞掉的 config 就
    會靜默通過。要的是具名的紅。
    """
    try:
        users = load_users_from(users_file(dd), _passthrough_normalize)
    except (OSError, json.JSONDecodeError) as exc:
        return [f"users.json unreadable: {exc}"]
    if not isinstance(users, dict):
        return [f"users.json 頂層不是 object:{type(users).__name__}"]
    record = users.get(uid) if isinstance(users.get(uid), dict) else {}
    cfg = record.get("config") if isinstance(record.get("config"), dict) else {}
    vu = cfg.get("vocab_ui") if isinstance(cfg.get("vocab_ui"), dict) else {}
    active_nb = vu.get("active_notebook_id")
    if active_nb is None or active_nb == "":
        return []
    # 葉子值必須是字串才能拿去查集合 —— dict/list 會在 `in` 就 unhashable 炸掉,
    # 而那個炸點同樣在 try 之外。isinstance 階梯守到這裡才算守完。
    if not isinstance(active_nb, str):
        return [f"vocab_ui.active_notebook_id 型別非法:{active_nb!r}"]
    if active_nb in live_nb_ids:
        return []
    return [
        f"vocab_ui.active_notebook_id={active_nb} 指向已不存在的 notebook"
        f"(修法:ops-edit user-config-set {uid} --active-notebook <name|id>)"
    ]


def _seed_replace_verdict(
    expected: list[dict[str, Any]],
    actual: list[tuple[str, str]],
    *,
    link_errors: list[str],
    field_mismatches: list[str],
    dangling_config: list[str],
) -> dict[str, Any]:
    """``--replace`` 路徑的 verify 判準(純函式)。

    刻意抽成純函式而非留在 verify_fn 的閉包裡:這條判準只有在「wipe 沒清乾淨」時
    才會轉紅,而那個狀態走 CLI **產不出來**(cards 只住 cards.db,wipe 必清它)。
    留在閉包裡就只能靠 mutation 證明它會紅,平時無人執行 —— 而「沒人查的判準等於
    假的」正是本條目要修的病。抽出來後可以直接餵一份髒狀態斷言它轉紅。

    判準用 ``len(actual)`` 而非另一次 ``count()`` 查詢:同一份讀取推導出報告值與
    判斷值,避免兩個讀取者對同一個磁碟狀態各說各話。

    ``dangling_config`` 是同族的第三種說謊:``--replace`` 不動 identity/users.json
    (刻意),於是 ``vocab_ui.active_notebook_id`` 會指向被清掉的舊 notebook id ——
    卡的形狀完全正確,demo 帳號的「新選詞歸哪本」卻懸空。只看卡就報綠會漏掉它。
    """
    extra, missing = _seed_shape_diff(expected, actual)
    return {
        "ok": (
            len(actual) == len(expected)
            and not link_errors
            and not field_mismatches
            and not extra
            and not missing
            and not dangling_config
        ),
        # 「筆數不符但 extra/missing 皆空」= 同本大小寫變體重複。沒有 expected_cards
        # 這個對照數字,那個形狀的紅看起來會像沉默。
        "expected_cards": len(expected),
        "extra_cards": extra[:5],
        "missing_cards": missing[:5],
        # 不截斷:現況最多一筆。等 config 面再擴充時要與上面兩者一致改成 [:5]。
        "dangling_config": dangling_config,
    }


def cmd_seed(args: argparse.Namespace) -> int:
    """一次性把 notebooks + cards + links 整套灌入(mock/demo 帳號用)。

    spec JSON 結構:
      {
        "notebooks": [{"name", "color"?, "cover_pattern"?, "sort_order"?,
                       "is_default"?}],
        "cards": [{"content","meaning","pos"?,"examples"?,"collocations"?,
                   "note"?,"difficulty"?,"mode"?,"root_form"?,"inflections"?,
                   "is_archived"?,"is_reader_hidden"?,"is_review_excluded"?,"notebook"?,
                   "review"?: {"state":"new|due|reviewed","interval"?}
                            | {review_count/review_streak/lapse_count/
                               review_interval_hours/next_review_at/
                               last_reviewed_at/last_review_feedback}}],
        "links": [{"from","to","kind","confidence","reason","notebook"?}]
      }
    cards/links 的 "notebook" 可指 spec 建立的、或**既存的** notebook name / id;
    links 的 from/to 用 card content 參照(seed 內先建卡再連結)。

    review 兩形式:legacy ``state`` 由 anchor 推導時間(既有消費者不變);擴充
    計數器形式直設絕對值(`world-export` 產物的無損重放),``review_count > 0``
    會經 `synthesize_many` 確定式合成逐筆 review events 寫入 review_events.db
    (uuid5 event_id,重跑經 store 去重而冪等)。``is_default: true`` 的 notebook
    映射到既存預設本(id 恆 "default",改名不增殖),使導出的預設本可重放。

    ``--replace``:同一個 EditContext 內先清空目標帳號整層 vocab(`_is_vocab_file`
    涵蓋的檔,含 review_events.db;identity/users.json 不動)再灌 spec,語意從
    additive-upsert 變成「spec = 精確最終狀態」。用於把既有帳號 reshape 成新結構
    —— additive 路徑對「同 content 換到別本」會新增第二張卡(`CardStore.add` 查重
    綁 (content, notebook_id)),replace 則得到乾淨結果。verify 在此路徑改用精確
    形狀比對(extra_cards / missing_cards),不再用寬鬆的 ``total >= len(cards)``。
    """

    dd = data_dir()
    ctx = EditContext(data_dir=dd, uid=args.uid, commit=args.commit, json_mode=args.json)
    replace = bool(getattr(args, "replace", False))
    spec = load_seed_spec(Path(args.spec))
    prevalidate_seed(spec, replace=replace)
    plan = build_seed_plan(spec, ctx, replace=replace)
    return _run_seed(spec, ctx, plan, replace=replace)


@dataclass(frozen=True)
class SeedSpec:
    notebooks: list[dict[str, Any]]
    cards: list[dict[str, Any]]
    links: list[dict[str, Any]]
    review_anchor: datetime | None


def _embedding_store(user_dir: Path, *, llm, notebook_id: str = "default"):
    # function-level import(同 ops_edit_support._graph_store):embeddings 拉 numpy,seed 僅 meaning edit 時需要。
    from kg.service_factories import create_embedding_store

    return create_embedding_store(user_dir, llm=llm, notebook_id=notebook_id)


def load_seed_spec(path: Path) -> SeedSpec:
    if not path.exists():
        raise EditError(f"spec not found: {path}")
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise EditError(f"spec JSON 解析失敗:{exc}") from exc
    if not isinstance(raw, dict):
        raise EditError("spec 頂層須為 JSON object(含 notebooks/cards/links 鍵)")
    return SeedSpec(
        notebooks=raw.get("notebooks", []),
        cards=raw.get("cards", []),
        links=raw.get("links", []),
        review_anchor=_parse_seed_datetime(raw.get("review_anchor"), "review_anchor"),
    )


def prevalidate_seed(spec: SeedSpec, *, replace: bool) -> None:
    # 預驗(寫入前,確保原子性):任何缺漏在動 DB 前就 raise,不留孤兒 notebook。
    for collection, entries in (
        ("notebooks", spec.notebooks),
        ("cards", spec.cards),
        ("links", spec.links),
    ):
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict):
                raise EditError(f"{collection}[{index}] 須為 JSON object:{entry!r}")

    seen_names: set[str] = set()
    default_entries = 0
    for n in spec.notebooks:
        name = n.get("name") or ""
        _assert_clean_notebook_name(name)
        # spec 內重複 notebook name 會建出多本同名、name→id 映射被後者覆蓋、
        # 前者成孤兒(dogfood A MED-2);寫入前擋掉。
        if name in seen_names:
            raise EditError(f"notebooks 有重複 name:{name!r}")
        seen_names.add(name)
        if "sort_order" in n:
            so = n["sort_order"]
            if isinstance(so, bool) or not isinstance(so, int):
                raise EditError(f"notebooks[{name!r}].sort_order 須為整數:{so!r}")
        for key in ("color", "cover_pattern"):
            value = n.get(key)
            if value is not None and not isinstance(value, str):
                raise EditError(f"notebooks[{name!r}].{key} 須為字串或 null:{value!r}")
        if "source_version" in n:
            source_version = n["source_version"]
            if source_version is not None and (isinstance(source_version, bool) or not isinstance(source_version, int)):
                raise EditError(f"notebooks[{name!r}].source_version 須為整數或 null:{source_version!r}")
        if n.get("is_default"):
            default_entries += 1
    if default_entries > 1:
        # 預設本結構上唯一(id 恆 "default");兩本以上 is_default 是矛盾 spec。
        raise EditError("notebooks 至多一本 is_default: true(預設本唯一)")
    if replace:
        # --replace 把「既存 notebook」這個 additive 路徑的合法參照來源整層刪掉,
        # 所以參照必須在**這裡**驗 —— _prevalidate 跑在 plan 與 wipe 之前,dry-run
        # 也跑。少了這一段,apply_fn 的 _resolve_nb 會在 wipe **之後**才紅:dry-run
        # 報綠、operator 照著下 --commit、整層 vocab 已被 unlink,而 EditContext 的
        # 錯誤輸出寫著 "committed": false —— 工具對自己的狀態說謊,正是本旗標要修的病。
        # wipe 後 ensure_default() 會重建預設本,故 "default" 恆合法;spec 宣告的
        # is_default entry 其 name 也映到 "default",已含在 seen_names 內。既存 id
        # 一律不合法:replace 後那些 id 不復存在(hex id 隨機、不可預先寫進 spec)。
        # **本規則刻意比 apply 嚴一格**:重建的預設本靠它的**顯示名**(localized,
        # 今天是「我的單字本」)其實也解得開 —— apply 的 name_to_id 會收 nb.name。
        # 這裡不放行,因為讓 spec 依賴一個 localized 顯示名本來就脆;擋下來時訊息
        # 會列出合法集合,operator 改寫成 "default" 即可。

        declared = seen_names | {"default"}
        for i, c in enumerate(spec.cards):
            ref = c.get("notebook", "default")
            if ref not in declared:
                raise EditError(
                    f"cards[{i}] 在 --replace 下指向未宣告的 notebook {ref!r}:"
                    f'replace 會先清空整層 vocab,只能引用本 spec 宣告的本或 "default"'
                    f"(本 spec 宣告:{sorted(declared)})"
                )
        for i, lk in enumerate(spec.links):
            ref = lk.get("notebook", "default")
            if ref not in declared:
                raise EditError(
                    f"links[{i}] 在 --replace 下指向未宣告的 notebook {ref!r}:"
                    f'replace 會先清空整層 vocab,只能引用本 spec 宣告的本或 "default"'
                    f"(本 spec 宣告:{sorted(declared)})"
                )
    for i, c in enumerate(spec.cards):
        if not (c.get("content") or "").strip():
            raise EditError(f"cards[{i}] content 空白:{c!r}")
        # meaning 空白與 card-import 一致擋掉:demo 卡需有定義(dogfood A MED-1)。
        if not (c.get("meaning") or "").strip():
            raise EditError(f"cards[{i}] meaning 空白:{c.get('content')!r}")
        for key in ("note", "pos"):
            value = c.get(key)
            if value is not None and not isinstance(value, str):
                raise EditError(f"cards[{i}].{key} 須為字串或 null:{value!r}")
        if "difficulty" in c:
            difficulty = c["difficulty"]
            if difficulty is not None and (isinstance(difficulty, bool) or not isinstance(difficulty, (int, float))):
                raise EditError(f"cards[{i}].difficulty 須為數值或 null:{difficulty!r}")
        for key in ("is_archived", "is_reader_hidden", "is_review_excluded"):
            if key in c and not isinstance(c[key], bool):
                raise EditError(f"cards[{i}].{key} 須為布林值:{c[key]!r}")
        # review.state 非法值 fail-loud,而非靜默當 reviewed(dogfood B5 / A LOW-1)。
        rv = c.get("review")
        if isinstance(rv, dict):
            form = _review_form(rv, f"cards[{i}].review")
            if form == "counters":
                _parse_review_counters(rv, f"cards[{i}].review")
            else:
                st = rv.get("state")
                if st not in (None, "") and st not in _VALID_REVIEW_STATES:
                    raise EditError(f"cards[{i}] review.state 非法:{st!r}(僅 {_VALID_REVIEW_STATES})")
                _parse_seed_datetime(rv.get("anchor"), f"cards[{i}].review.anchor")
        if "source" in c:
            _source_to_json(c.get("source"), f"cards[{i}].source")
    for i, lk in enumerate(spec.links):
        for k in ("from", "to", "kind", "confidence", "reason"):
            if lk.get(k) in (None, ""):
                raise EditError(f"links[{i}] 缺 {k}:{lk!r}")
        if lk["kind"] not in (LinkKind.CONTRASTS_WITH, LinkKind.SHARES_USAGE):
            raise EditError(f"links[{i}] kind 非法:{lk['kind']!r}")
        try:
            conf = float(lk["confidence"])
        except (TypeError, ValueError) as exc:
            raise EditError(f"links[{i}] confidence 非數值:{lk['confidence']!r}") from exc
        if not 0.0 <= conf <= 1.0:
            raise EditError(f"spec.links[{i}] confidence 須在 0.0~1.0:{conf}")


def build_seed_plan(spec: SeedSpec, ctx: EditContext, *, replace: bool) -> dict[str, Any]:
    dist = {"new": 0, "due": 0, "reviewed": 0, "counters": 0, "unspecified": 0}
    for c in spec.cards:
        rv = c.get("review")
        if isinstance(rv, dict) and _review_form(rv, "cards[].review") == "counters":
            dist["counters"] += 1
            continue
        st = rv.get("state") if isinstance(rv, dict) else None
        dist[st if st in _VALID_REVIEW_STATES else "unspecified"] += 1
    plan = {
        "notebooks": len(spec.notebooks),
        "cards": len(spec.cards),
        "links": len(spec.links),
        "notebook_names": [n.get("name") for n in spec.notebooks],
        "card_sample": [c.get("content") for c in spec.cards[:5]],
        "link_sample": [f"{link.get('from')}→{link.get('to')} ({link.get('kind')})" for link in spec.links[:3]],
        "review_distribution": dist,
        "replace": replace,
    }
    if replace:
        # 破壞性旗標必須 dry-run 可預覽會刪什麼 —— operator 在不帶 --commit 時就該
        # 看見「這次會清掉哪幾個檔、目標現有幾張卡」,而不是事後從 backup 反推。
        # 先讀 cards.db，再列 wipe_files，避免 WAL sidecar 漏出預覽。
        plan["target_active_cards_before"] = _count_active_cards(ctx.user_dir / "cards.db")
        plan["wipe_files"] = sorted(p.name for p in ctx.user_dir.iterdir() if p.is_file() and _is_vocab_file(p.name))
    return plan


def apply_seed(
    spec: SeedSpec,
    ctx: EditContext,
    state: dict[str, Any],
    *,
    replace: bool,
) -> dict[str, Any]:
    # _prevalidate() 已在 plan 前跑過(dry-run 也驗);此處不重複。
    now = spec.review_anchor or datetime.now(tz=UTC)
    # --replace:先清整層 vocab,spec 即最終狀態。**必須早於下面任何 store 建立**
    # —— 任何 store 一旦先開檔就持有將被 unlink 的 inode,之後的寫入落到孤兒檔,
    # 磁碟上看不到(SQLite 的 open fd 仍指向已刪除的 inode)。identity(users.json)
    # 不在 _is_vocab_file 涵蓋範圍內,不受影響;EditContext 已在 apply 前建快照。
    removed_files: list[str] = []
    if replace:
        removed_files = sorted(p.name for p in ctx.user_dir.iterdir() if p.is_file() and _is_vocab_file(p.name))
        if removed_files:
            ctx.mark_destructive()
        for name in removed_files:
            (ctx.user_dir / name).unlink()
    nb_store = _notebook_store(ctx.user_dir)
    nb_store.ensure_default()
    # name → id 映射。**先納入所有既存 notebook**(operator 可能先
    # notebook-create 再 seed,spec.cards 用既存 name 指筆記本,不可 fallback 成把
    # name 字串當 notebook_id 存),spec 建立的覆蓋同名既存。
    name_to_id = {"default": "default"}
    for nb in nb_store.all():
        name_to_id[nb.name] = nb.id
    existing_ids = {nb.id for nb in nb_store.all()}
    created_nb = []
    for n in spec.notebooks:
        name = n["name"]
        # 冪等:同名既存(含上輪 seed 建立)直接重用,不重複新建(dogfood A MED-2/MED-4)。
        # seed 是「確保狀態」語意,重跑同 spec 結果應一致、不增殖孤兒 notebook。
        if n.get("is_default"):
            # 預設本 id 恆 "default" 且唯一:is_default entry 映到既存預設本
            # (可改名/改欄位,不增殖新本),使 world-export 導出的預設本可無損重放。
            nb_id, reused = "default", True
        elif name in name_to_id:
            nb_id, reused = name_to_id[name], True
        else:
            nb = nb_store.create(name=name, color=n.get("color"), cover_pattern=n.get("cover_pattern"))
            nb_id, reused = nb.id, False
        # 「確保狀態」語意:spec 宣告的欄位一律 upsert(reuse 者對齊 spec,
        # 新建者冗餘覆蓋無害 —— NotebookStore.update 有 has_changes 檢查)。
        # 用 `key in n` 區分「省略=保留舊值」與「明確 null=清空」,對齊 card 欄位語意。
        nb_updates: dict[str, Any] = {"name": name}
        if "color" in n:
            nb_updates["color"] = n["color"]
        if "cover_pattern" in n:
            nb_updates["cover_pattern"] = n["cover_pattern"]
        if "sort_order" in n:
            nb_updates["sort_order"] = n["sort_order"]
        # Provenance (omit-if-null): export only emits these when set, so
        # `key in n` keeps seed↔export field-symmetric (§1.1 roundtrip).
        if "source_shared_deck_id" in n:
            nb_updates["source_shared_deck_id"] = n["source_shared_deck_id"]
        if "source_version" in n:
            nb_updates["source_version"] = n["source_version"]
        nb_store.update(nb_id, **nb_updates)
        name_to_id[name] = nb_id
        existing_ids.add(nb_id)
        entry = {"id": nb_id, "name": name}
        if reused:
            entry["reused"] = True
        created_nb.append(entry)

    def _resolve_nb(ref: str) -> str:
        # 接受:已知 name、直接給的合法既存 id;否則明確報錯(不靜默存 name)。
        if ref in name_to_id:
            return name_to_id[ref]
        if ref in existing_ids:
            return ref
        raise EditError(f"seed 指向不存在的 notebook {ref!r}(既非 spec 建立、也非既存 name/id)")

    card_store = _card_store(ctx.user_dir)
    # 真實新增數用 pre/post id diff(對齊 card-import)——CardStore.add 對既有
    # content 冪等回舊卡,無腦 +=1 會把 dup 誤報成新增(dogfood C3)。
    pre_ids = {c.id for c in card_store.all()}
    card_checks: list[dict[str, Any]] = []
    synth_states: list[CardReviewState] = []
    meaning_changed_by_nb: dict[str, list[str]] = {}
    for c in spec.cards:
        nb_id = _resolve_nb(c.get("notebook", "default"))
        card = card_store.add(
            content=c["content"],
            meaning=c.get("meaning", ""),
            pos=c.get("pos"),
            examples=c.get("examples") or [],
            collocations=c.get("collocations") or [],
            mode=c.get("mode", "recognition"),
            root_form=c.get("root_form"),
            inflections=c.get("inflections") or [],
            notebook_id=nb_id,
        )
        # dup 卡也 upsert 核心欄位:add 對既有 content 回舊卡、**不更新** meaning,
        # 但 seed 須冪等可重跑(調 spec 再灌)→ 顯式覆蓋 meaning/pos/examples/... ,
        # 否則改了 spec 卻靜默沿用舊值(dogfood C2 false-green)。新卡此處冗餘覆蓋
        # 無害(CardStore.update 有 has_changes 檢查,值同不寫)。
        #
        # 用 `key in c` 而非 `c.get(key)` 判斷:區分「spec 省略該欄」(保留舊值)與
        # 「spec 明確設空 [] / null」(清空)。`if c.get("examples")` 會把 [] 當 falsy
        # 漏掉,讓 operator 無法用 seed 清空欄位(dogfood D MED-2)。
        updates: dict[str, Any] = {"meaning": c.get("meaning", "")}
        if "pos" in c:
            updates["pos"] = c["pos"]
        if "examples" in c:
            updates["examples"] = c["examples"] or []
        if "collocations" in c:
            updates["collocations"] = c["collocations"] or []
        if c.get("mode"):
            updates["mode"] = c["mode"]
        if "note" in c:
            updates["note"] = c["note"]
        if "difficulty" in c:
            updates["difficulty"] = c["difficulty"]
        if "root_form" in c:
            updates["root_form"] = c["root_form"]
        if "inflections" in c:
            updates["inflections"] = c["inflections"] or []
        if "is_archived" in c:
            updates["is_archived"] = bool(c["is_archived"])
        if "is_reader_hidden" in c:
            updates["is_reader_hidden"] = bool(c["is_reader_hidden"])
        if "is_review_excluded" in c:
            updates["is_review_excluded"] = bool(c["is_review_excluded"])
        # Provenance (omit-if-null): export only emits this when set, so
        # `key in c` keeps seed↔export field-symmetric (§1.1 roundtrip). The
        # Phase 2 copy path stamps it; specs without the key leave it NULL.
        if "source_shared_card_guid" in c:
            updates["source_shared_card_guid"] = c["source_shared_card_guid"]
        if "source" in c:
            updates["source"] = _source_to_json(c.get("source"), "spec.cards[].source")
        rv = c.get("review")
        form = _review_form(rv, "spec.cards[].review")
        if form == "state":
            review_now = _parse_seed_datetime(rv.get("anchor"), "spec.cards[].review.anchor") or now
            updates.update(_review_fields(rv["state"], rv.get("interval"), review_now))
        elif form == "counters":
            counters = _parse_review_counters(rv, "spec.cards[].review")
            updates.update(counters)
            if counters.get("review_count", 0) > 0:
                # 計數器 ⇒ 逐筆 review events 一併合成(對齊 clone-demo 的合成
                # 契約),否則 iOS heatmap/streak 與卡片聚合對不上。
                synth_states.append(
                    CardReviewState(
                        card_id=card.id,
                        content=c["content"],
                        notebook_id=nb_id,
                        review_count=counters["review_count"],
                        lapse_count=counters.get("lapse_count", 0),
                        review_streak=counters.get("review_streak", 0),
                        last_review_feedback=counters.get("last_review_feedback", -1),
                        last_reviewed_at=counters["last_reviewed_at"],
                        created_at=card.created_at,
                        review_interval_hours=counters.get("review_interval_hours", 12.0),
                    )
                )
        if updates["meaning"] != card.meaning:
            meaning_changed_by_nb.setdefault(nb_id, []).append(card.id)
        card_store.update(card.id, **updates)
        card_checks.append({"content": c["content"].strip(), "nb_id": nb_id, "meaning": c.get("meaning", "")})
    # 含義被 seed 覆寫的卡(含 dup)必須與 meaning edit 同一套副作用:丟棄舊向量 + 重回 judge 佇列(#2957)。
    # 新卡的 card.meaning 已是 spec 值,不會進此分支。
    if meaning_changed_by_nb:
        from .vocab_crud import reembed_meaning_edits_best_effort

        for nb_id, changed_ids in meaning_changed_by_nb.items():
            reembed_meaning_edits_best_effort(
                changed_ids,
                open_embeddings=partial(_embedding_store, ctx.user_dir, llm=None, notebook_id=nb_id),
                open_graph=partial(_graph_store, ctx.user_dir, nb_id),
            )
    state["card_checks"] = card_checks
    post_ids = {c.id for c in card_store.all()}
    actually_new = len(post_ids - pre_ids)

    added_links = 0
    link_errors: list[str] = []
    for lk in spec.links:
        nb_id = _resolve_nb(lk.get("notebook", "default"))
        try:
            # link 嚴格同本:圖譜為 per-notebook,link 兩端 card 必須與 link 同在
            # nb_id。card 不在該本 → spec 不一致,_resolve_card_in_notebook 給精準
            # 錯誤(指出 card 在哪本)引導修 spec,而非全局硬連成跨本 link。
            from_card = _resolve_card_in_notebook(card_store, lk["from"], nb_id)
            to_card = _resolve_card_in_notebook(card_store, lk["to"], nb_id)
            graph = _graph_store(ctx.user_dir, nb_id)
            graph.add_link(
                from_id=from_card.id,
                to_id=to_card.id,
                kind=LinkKind(lk["kind"]),
                confidence=float(lk["confidence"]),
                reason=lk["reason"],
                source="ops",
            )
            added_links += 1
        except (EditError, ValueError, KeyError) as exc:
            link_errors.append(f"{lk.get('from')}→{lk.get('to')}: {exc}")

    # 計數器形式的卡 → 確定式合成逐筆 review events(uuid5 event_id,
    # store 以 event_id 去重 → 重跑冪等,對齊 seed 整體的「確保狀態」語意)。
    events_written = 0
    if synth_states:
        events = synthesize_many(synth_states)
        if events:
            store = ReviewEventStore(ctx.user_dir / "review_events.db")
            try:
                events_written = store.insert_many(events)["inserted"]
            finally:
                store.close()

    state["link_errors"] = link_errors
    return {
        "notebooks_created": created_nb,
        "cards_added": actually_new,
        "skipped_dup": len(spec.cards) - actually_new,
        "links_added": added_links,
        "link_errors": link_errors,
        "review_events_written": events_written,
        "removed_files": removed_files,
    }


def verify_seed(
    spec: SeedSpec,
    ctx: EditContext,
    state: dict[str, Any],
    *,
    replace: bool,
) -> dict[str, Any]:
    card_store = _card_store(ctx.user_dir)
    total = card_store.count()
    errs = state.get("link_errors", [])
    # 抽驗每張 spec 卡的 meaning 真的落盤,獵殺 dup 卡 upsert 沒生效卻報綠的
    # false-green(dogfood C2)。按 (content, **resolved nb_id**) 精確比對 —— 用
    # notebook_id=None 全局查會在跨本同名卡時只找到第一張、誤報 mismatch(dogfood
    # D MED-1,我上輪引入的回歸)。
    field_mismatches: list[str] = []
    for chk in state.get("card_checks", []):
        found = card_store.find_by_content(chk["content"], notebook_id=chk["nb_id"])
        if found is None:
            field_mismatches.append(f"{chk['content']}@{chk['nb_id']}: missing")
        elif chk["meaning"] and found.meaning != chk["meaning"]:
            field_mismatches.append(f"{chk['content']}@{chk['nb_id']}: meaning not applied")
    # link 失敗 / 欄位未落盤都算 verify 失敗 —— 否則無聲失敗報 ok。
    out: dict[str, Any] = {
        "ok": total >= len(spec.cards) and not errs and not field_mismatches,
        "total_cards": total,
        "link_errors": errs,
        "field_mismatches": field_mismatches[:5],
    }
    if replace:
        # replace 宣告「spec = 精確最終狀態」,所以判準也必須是精確的:
        # `total >= len(spec.cards)` 對 additive 是對的(既有卡本來就該留著),但對
        # replace 會把「wipe 沒清乾淨而殘留的重複卡」讀成綠。改為雙向集合差:
        # extra = 磁碟有而 spec 沒有(重複卡 / 殘留卡),missing = spec 有而磁碟沒有。
        actual_pairs = [(c.notebook_id, c.content) for c in card_store.all()]
        # identity 不動 ⇒ 舊的 active notebook 指標會指向剛被清掉的 id。
        live_nb_ids = {nb.id for nb in _notebook_store(ctx.user_dir).all()} | {"default"}
        dangling = _dangling_active_notebook(ctx.data_dir, ctx.uid, live_nb_ids)
        out.update(
            _seed_replace_verdict(
                state.get("card_checks", []),
                actual_pairs,
                link_errors=errs,
                field_mismatches=field_mismatches,
                dangling_config=dangling,
            )
        )
    return out


def _run_seed(
    spec: SeedSpec,
    ctx: EditContext,
    plan: dict[str, Any],
    *,
    replace: bool,
) -> int:
    state: dict[str, Any] = {}
    return ctx.run(
        action="seed",
        plan=plan,
        apply_fn=lambda: apply_seed(spec, ctx, state, replace=replace),
        verify_fn=lambda: verify_seed(spec, ctx, state, replace=replace),
    )


def cmd_clone_demo(args: argparse.Namespace) -> int:
    """高保真複製來源帳號 vocab 層到目標 demo 帳號 + 合成 review history。"""
    dd = data_dir()
    src_uid = args.source_uid
    assert_safe_uid(src_uid)  # '../evil' 類在此 fail-loud
    src_dir = user_dir_for(dd, src_uid)
    if not src_dir.exists():
        raise EditError(f"source user not found: {src_uid}(在 {dd}/users/ 下無此目錄)")
    if not (src_dir / "cards.db").exists():
        raise EditError(f"source {src_uid} 無 cards.db,無詞庫可複製")

    # EditContext uid=target:寫前自動備份 target user_dir、要求 target 已存在、audit。
    ctx = EditContext(data_dir=dd, uid=args.target_uid, commit=args.commit, json_mode=args.json)
    if src_dir.resolve() == ctx.user_dir.resolve():
        raise EditError("source 與 target 不可為同一帳號")

    states = _read_card_review_states(src_dir / "cards.db")
    sqlite_files, other_files = _clone_source_files(src_dir)
    source_fingerprint = _clone_source_fingerprint(src_dir)
    if args.expect_source_fingerprint and args.expect_source_fingerprint != source_fingerprint:
        raise EditError(
            f"source fingerprint mismatch: expected {args.expect_source_fingerprint}, got {source_fingerprint}"
        )
    source_links = _count_graph_links(src_dir)
    plan = {
        "source_uid": src_uid,
        "target_uid": args.target_uid,
        "source_fingerprint": source_fingerprint,
        "source_active_cards": _count_active_cards(src_dir / "cards.db"),
        "source_links": source_links,
        "synthesized_events": sum(s.review_count for s in states),
        "files_to_copy": [p.name for p in sqlite_files] + [p.name for p in other_files],
        "target_active_cards_before": _count_active_cards(ctx.user_dir / "cards.db"),
        "note": "identity(users.json)不變更;目標既有 vocab 層將被覆蓋",
    }

    def apply_fn() -> dict[str, Any]:
        tgt = ctx.user_dir
        # 1. 先把來源檔複製到 .clone-tmp(全成功才換入,降半寫風險;EditContext 另有 tar 兜底)。
        staged: list[tuple[Path, Path]] = []
        for sp in sqlite_files:
            tp = tgt / (sp.name + _CLONE_TMP_SUFFIX)
            _sqlite_online_backup(sp, tp)
            staged.append((tgt / sp.name, tp))
        for sp in other_files:
            tp = tgt / (sp.name + _CLONE_TMP_SUFFIX)
            shutil.copy2(sp, tp)
            staged.append((tgt / sp.name, tp))
        # 2. 清掉目標端舊 vocab 層(孤兒 graph/embeddings、-wal/-shm、舊 review_events)。
        ctx.mark_destructive()
        removed = sorted(p.name for p in tgt.iterdir() if p.is_file() and _is_vocab_file(p.name))
        for p in tgt.iterdir():
            if p.is_file() and _is_vocab_file(p.name):
                p.unlink()
        # 3. 暫存換入(換入前清 final 的 -wal/-shm,確保 SQLite 一致)。
        for final_path, tmp_path in staged:
            for suffix in ("-wal", "-shm"):
                (final_path.parent / (final_path.name + suffix)).unlink(missing_ok=True)
            tmp_path.replace(final_path)
        # 4. 由複製後的 cards.db 合成 review events 寫入目標 review_events.db。
        events = synthesize_many(_read_card_review_states(tgt / "cards.db"))
        events_written = 0
        if events:
            store = ReviewEventStore(tgt / "review_events.db")
            try:
                events_written = store.insert_many(events)["inserted"]
            finally:
                store.close()
        return {
            "cloned_sqlite": [p.name for p in sqlite_files],
            "cloned_files": [p.name for p in other_files],
            "removed_target_files": removed,
            "review_events_written": events_written,
            "source_fingerprint": source_fingerprint,
        }

    def verify_fn() -> dict[str, Any]:
        tgt = ctx.user_dir
        active = _count_active_cards(tgt / "cards.db")
        events = _count_review_events(tgt / "review_events.db")
        links = _count_graph_links(tgt)
        # 檔案完整性:衍生檔(copy2 精確複製)逐一比對來源大小,抓 truncated;SQLite 經
        # backup API 重排頁面大小會變,只驗存在且非空。補上 count-only verify 的盲點:
        # 一個 present-but-truncated 的 .npy 不會被卡數/連結數揪出。
        files_ok = all(
            (tgt / sp.name).exists() and (tgt / sp.name).stat().st_size == sp.stat().st_size for sp in other_files
        ) and all((tgt / sp.name).exists() and (tgt / sp.name).stat().st_size > 0 for sp in sqlite_files)
        ok = (
            active == plan["source_active_cards"]
            and events == plan["synthesized_events"]
            and links == plan["source_links"]
            and files_ok
        )
        return {
            "ok": ok,
            "target_active_cards": active,
            "review_events": events,
            "links": links,
            "files_ok": files_ok,
        }

    return ctx.run(action="clone-demo", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)


def cmd_world_snapshot(args: argparse.Namespace) -> int:
    dd = data_dir()
    members = [p.name for p in _world_members(dd)]
    plan = {
        "label": args.label,
        "members": members,
        "member_count": len(members),
        "backup_root": str(world_backup_root(dd)),
    }
    if not args.commit:
        emit(
            {
                "mode": "dry-run",
                "action": "world-snapshot",
                "plan": plan,
                "committed": False,
                "hint": "加 --commit 才會真正建立 world snapshot",
            },
            json_mode=args.json,
        )
        return 0
    backup = backup_world(dd, label=args.label)
    emit(
        {
            "mode": "commit",
            "action": "world-snapshot",
            "plan": plan,
            "result": {"snapshot": str(backup)},
            "committed": True,
        },
        json_mode=args.json,
    )
    return 0


def cmd_world_restore(args: argparse.Namespace) -> int:
    dd = data_dir()
    snapshots = _list_world_backups(dd)
    if args.snapshot:
        snapshot_path = Path(args.snapshot)
        if not snapshot_path.exists():
            raise EditError(f"指定的 world snapshot 不存在: {snapshot_path}")
    else:
        if not snapshots:
            raise EditError("無 world snapshot 可還原")
        snapshot_path = Path(snapshots[0]["path"])

    with tarfile.open(snapshot_path) as tar:
        names = tar.getnames()
    top_dirs = {n.split("/")[0] for n in names if n and not n.startswith("/")}
    if top_dirs != {_WORLD_BACKUP_ROOT}:
        raise EditError(f"world snapshot root 不符: top={sorted(top_dirs)}, 預期僅 {{{_WORLD_BACKUP_ROOT!r}}}")
    plan = {
        "restore_from": str(snapshot_path),
        "target_data_dir": str(dd),
        "available_snapshots": len(snapshots),
        "total_members": len(names),
    }
    if not args.commit:
        emit(
            {
                "mode": "dry-run",
                "action": "world-restore",
                "plan": plan,
                "committed": False,
                "hint": "加 --commit 才會真正覆蓋整個 data_dir world",
            },
            json_mode=args.json,
        )
        return 0

    pre_restore = backup_world(dd, label="pre-world-restore")
    with tempfile.TemporaryDirectory(prefix="kg-world-restore-") as tmp:
        tmp_root = Path(tmp)
        with tarfile.open(snapshot_path) as tar:
            tar.extractall(tmp_root, filter="data")
        restored = _replace_world_from_snapshot(dd, tmp_root / _WORLD_BACKUP_ROOT)
    emit(
        {
            "mode": "commit",
            "action": "world-restore",
            "plan": plan,
            "result": {
                "restored_from": str(snapshot_path),
                "pre_restore_backup": str(pre_restore),
                "restored_members": restored,
            },
            "verified": {"ok": users_file(dd).exists() and (dd / "users").exists()},
            "committed": True,
        },
        json_mode=args.json,
    )
    return 0
