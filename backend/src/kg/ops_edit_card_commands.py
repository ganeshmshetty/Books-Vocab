from __future__ import annotations

import argparse
import csv
import json
import logging
from contextlib import closing
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from kg.ops_shared import data_dir

from .ops_edit_shared import EditContext, EditError
from .ops_edit_support import (
    _CARD_UPDATABLE_FIELDS,
    _VALID_REVIEW_STATES,
    _as_utc,
    _card_brief,
    _card_store,
    _graph_store,
    _notebook_store,
    _resolve_card_id,
    _review_fields,
    _split_multi,
    validate_review_interval,
)

logger = logging.getLogger(__name__)


def _resolve_notebook_id_for_command(user_dir: Path, ref: str) -> str:
    """Resolve a notebook reference while owning the temporary store."""
    if ref == "default":
        return "default"
    with closing(_notebook_store(user_dir)) as store:
        if store.exists(ref):
            return ref
        for notebook in store.all():
            if notebook.name == ref:
                return notebook.id
    raise EditError(f"notebook not found: {ref!r}(既非既存 id 也非既存 name;先 notebook-create)")


def cmd_card_add(args: argparse.Namespace) -> int:
    dd = data_dir()
    ctx = EditContext(data_dir=dd, uid=args.uid, commit=args.commit, json_mode=args.json)
    nb = _resolve_notebook_id_for_command(ctx.user_dir, args.notebook)
    plan = {
        "content": args.content,
        "meaning": args.meaning,
        "pos": args.pos,
        "notebook_id": nb,
        "mode": args.mode,
        "examples": args.example or [],
        "collocations": args.collocation or [],
        "review": args.review,
    }

    def apply_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            card = store.add(
                content=args.content,
                meaning=args.meaning,
                pos=args.pos,
                examples=args.example or [],
                collocations=args.collocation or [],
                mode=args.mode,
                notebook_id=nb,
            )
            updates: dict[str, Any] = {}
            if args.note is not None:
                updates["note"] = args.note
            if args.difficulty is not None:
                updates["difficulty"] = args.difficulty
            if args.review:
                updates.update(_review_fields(args.review, args.interval, datetime.now(tz=UTC)))
            if updates:
                card = store.update(card.id, **updates) or card
            return {"card": _card_brief(card)}

    def verify_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            found = store.find_by_content(args.content, notebook_id=nb)
            return {"ok": found is not None and not found.is_deleted}

    return ctx.run(action="card-add", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)


def cmd_card_update(args: argparse.Namespace) -> int:
    dd = data_dir()
    ctx = EditContext(data_dir=dd, uid=args.uid, commit=args.commit, json_mode=args.json)
    # --set field=value(可重複);value 走 JSON 解析(數字/字串/陣列皆可)。
    updates: dict[str, Any] = {}
    for pair in args.set or []:
        if "=" not in pair:
            raise EditError(f"--set 需 field=value 形式:{pair!r}")
        field, _, raw = pair.partition("=")
        field = field.strip()
        if field not in _CARD_UPDATABLE_FIELDS:
            raise EditError(
                f"欄位不可改:{field!r}。可寫欄位={sorted(_CARD_UPDATABLE_FIELDS)};"
                "複習態用 card-set-review、刪除用 card-delete"
            )
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            logger.debug(
                "Failed to parse --set value as JSON for user command (field=%s, raw=%r), treating as string",
                field,
                raw,
            )
            value = raw  # 裸字串
        updates[field] = value
    if not updates:
        raise EditError("card-update 需至少一個 --set field=value")

    plan = {"card_ref": args.card, "updates": updates}
    state: dict[str, Any] = {}

    def apply_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            card = _resolve_card_id(store, args.card)
            # content 改值前驗同 notebook 衝突:unique index 是 (content, notebook_id),
            # 跨 notebook 重複不觸發 IntegrityError,但會讓 content-based 解析
            # (_resolve_card_id / find_by_content)變非確定性(dogfood A HIGH-3)。同本內
            # 已有同名卡即擋,避免悄悄造出無法被 content 唯一定位的卡。
            new_content = updates.get("content")
            if isinstance(new_content, str):
                clash = store.find_by_content(new_content, notebook_id=card.notebook_id)
                if clash is not None and clash.id != card.id:
                    raise EditError(
                        f"content 衝突:notebook {card.notebook_id} 內已有 "
                        f"content={new_content!r} 的卡 {clash.id};content 須在本內唯一"
                    )
            updated = store.update(card.id, **updates)
            if updated is None:
                raise EditError(f"update 失敗(卡可能已刪除):{card.id}")
            state["card_id"] = updated.id
            return {"card": _card_brief(updated)}

    def verify_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            c = store.get(state["card_id"])
            if c is None or c.is_deleted:
                return {"ok": False, "reason": "card missing/deleted"}
            mismatched = [k for k, v in updates.items() if getattr(c, k, None) != v]
            return {"ok": not mismatched, "mismatched_fields": mismatched}

    return ctx.run(action="card-update", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)


def cmd_card_set_review(args: argparse.Namespace) -> int:
    dd = data_dir()
    ctx = EditContext(data_dir=dd, uid=args.uid, commit=args.commit, json_mode=args.json)
    if args.state not in _VALID_REVIEW_STATES:
        raise EditError(f"--state 須為 {_VALID_REVIEW_STATES}")
    plan = {"card_ref": args.card, "state": args.state, "interval": args.interval}
    state: dict[str, Any] = {}

    def apply_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            card = _resolve_card_id(store, args.card)
            fields = _review_fields(args.state, args.interval, datetime.now(tz=UTC))
            updated = store.update(card.id, **fields) or card
            state["card_id"] = updated.id
            state["expect_rc"] = fields["review_count"]
            state["expect_fb"] = fields["last_review_feedback"]
            return {"card": _card_brief(updated)}

    def verify_fn() -> dict[str, Any]:
        # 不只驗 review_count(`new` 的 rc=0 與初始卡無區分度,update 沒跑也 pass)——
        # 改驗 review_count + feedback + next_review_at 的**時間不變量**(TodayReview
        # 撈取依據):new→next 為空、due→next 在過去、reviewed→next 在未來。方向性
        # 檢查避開 aware/naive datetime 等值比對陷阱(dogfood C5 / A MED-5)。
        with closing(_card_store(ctx.user_dir)) as store:
            c = store.get(state["card_id"])
            if c is None or c.is_deleted:
                return {"ok": False, "reason": "card missing/deleted"}
            now = datetime.now(tz=UTC)
            nxt = c.next_review_at
            if args.state == "new":
                time_ok = nxt is None
            elif args.state == "due":
                time_ok = nxt is not None and _as_utc(nxt) < now
            else:  # reviewed
                time_ok = nxt is not None and _as_utc(nxt) > now
            ok = c.review_count == state["expect_rc"] and c.last_review_feedback == state["expect_fb"] and time_ok
            return {"ok": ok, "review_count": c.review_count, "next_review_at": str(nxt), "time_invariant_ok": time_ok}

    return ctx.run(action="card-set-review", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)


def _embedding_store(user_dir: Path, notebook_id: str):
    # evict-only:llm=None 合法(create_embedding_store 設計如此)。function-level
    # import 與 _graph_store 同理:避免 card 操作無謂拉 numpy 重依賴。
    from kg.service_factories import create_embedding_store

    return create_embedding_store(user_dir, llm=None, notebook_id=notebook_id)


def _evict_embedding(user_dir: Path, notebook_id: str, card_id: str) -> None:
    """Best-effort 向量逐出;卡狀態已 commit,逐出失敗只記 log(同 API 路徑)。"""
    try:
        _embedding_store(user_dir, notebook_id).remove(card_id)
    except Exception:
        logger.warning("Failed to evict embedding for card %s in %s", card_id, notebook_id, exc_info=True)


def cmd_card_delete(args: argparse.Namespace) -> int:
    dd = data_dir()
    ctx = EditContext(data_dir=dd, uid=args.uid, commit=args.commit, json_mode=args.json)
    plan = {"card_ref": args.card, "kind": "soft-delete"}
    state: dict[str, Any] = {}

    def apply_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            card = _resolve_card_id(store, args.card)
            from kg.vocab_graph_ops import link_peer_ids, touch_peers

            ctx.mark_destructive()
            ok = store.delete(card.id)
            state["card_id"] = card.id
            # API 路徑(delete_vocab_word)同款清理:links 去活化(釋放 peer 的
            # MAX_DEGREE 槽)、candidates/pending_judge/blocked pairs 移除、peer touch、
            # 向量逐出(否則幽靈向量佔 top-k)。
            graph = _graph_store(ctx.user_dir, card.notebook_id)
            peer_ids = link_peer_ids(graph, card.id)
            graph.cleanup_for_card(card.id, remove_blocked=True, source="manual")
            touch_peers(store, peer_ids, card)
            _evict_embedding(ctx.user_dir, card.notebook_id, card.id)
            return {"deleted": ok, "card_id": card.id}

    def verify_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            c = store.get(state["card_id"])
            return {"ok": c is None or c.is_deleted}

    return ctx.run(action="card-delete", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)


def cmd_card_import(args: argparse.Namespace) -> int:
    dd = data_dir()
    ctx = EditContext(data_dir=dd, uid=args.uid, commit=args.commit, json_mode=args.json)
    csv_path = Path(args.csv)
    if not csv_path.exists():
        raise EditError(f"CSV not found: {csv_path}")
    nb_id = _resolve_notebook_id_for_command(ctx.user_dir, args.notebook)
    with open(csv_path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        # header 正規化成小寫:CSV 用 `Content`/`CONTENT` 不該靜默跳過全批。
        fieldnames = [h.strip().lower() for h in (reader.fieldnames or [])]
        reader.fieldnames = fieldnames
        if "content" not in fieldnames:
            raise EditError(
                f"CSV 缺 content 欄;偵測到 headers={fieldnames}。"
                "必要欄:content, meaning;可選:pos, examples, collocations, note, "
                "difficulty, review_state, review_interval(examples/collocations 多值用 | 分隔)"
            )
        all_rows = list(reader)
    rows = [r for r in all_rows if (r.get("content") or "").strip()]
    blank_meaning = sum(1 for r in rows if not (r.get("meaning") or "").strip())
    has_review_col = "review_state" in fieldnames
    with closing(_card_store(ctx.user_dir)) as store:
        # 唯讀預演:帶 review_state 但已存在的重複卡,commit 時只計 skipped_dup、不覆寫複習態。
        dup_review_rows = sum(
            1
            for r in rows
            if (r.get("review_state") or "").strip() in _VALID_REVIEW_STATES
            and store.find_by_content(r["content"].strip(), notebook_id=nb_id) is not None
        )
    plan = {
        "csv": str(csv_path),
        "notebook_id": nb_id,
        "row_count": len(rows),
        "skipped_blank_content": len(all_rows) - len(rows),
        "blank_meaning_rows": blank_meaning,  # >0 會在 commit 時被擋
        "has_review_col": has_review_col,
        "dup_review_rows": dup_review_rows,  # 既有卡且帶 review_state:commit 時不套用複習態
        "sample": [r.get("content") for r in rows[:5]],
    }

    def _prevalidate_rows() -> None:
        """任何 store.add 之前一次掃完整批 —— 失敗即 0 寫入(原子性,dogfood B2)。

        此前 `float(review_interval)` 在逐筆寫入迴圈中途才炸,已寫的卡留在 DB、
        錯誤行之後的卡沒寫,工具卻報 committed=False —— 與磁碟矛盾。把 meaning /
        review_state / review_interval 的格式驗證全部前移到寫入前。
        """
        if blank_meaning:
            raise EditError(f"{blank_meaning} 列 meaning 空白;demo 卡需有定義,檢查 CSV 欄位名/內容")
        for i, r in enumerate(rows):
            rv = (r.get("review_state") or "").strip()
            if not rv:
                continue
            if rv not in _VALID_REVIEW_STATES:
                raise EditError(f"列 {i} review_state 非法:{rv!r}(僅 {_VALID_REVIEW_STATES})")
            raw_iv = (r.get("review_interval") or "").strip()
            if raw_iv:
                try:
                    iv = float(raw_iv)
                except ValueError as exc:
                    raise EditError(f"列 {i} review_interval 非數值:{raw_iv!r}") from exc
                try:
                    validate_review_interval(iv)
                except EditError as exc:
                    raise EditError(f"列 {i} review_interval 不合法:{exc}") from exc

    if not ctx.commit:
        # dry-run 不進 apply_fn:預演同一組格式/數值檢查,讓 preview 與 --commit 同樣失敗(#3910)。
        _prevalidate_rows()

    def apply_fn() -> dict[str, Any]:
        _prevalidate_rows()
        with closing(_card_store(ctx.user_dir)) as store:
            now = datetime.now(tz=UTC)
            # 用 pre/post id diff 算**真實**新增數 —— CardStore.add 對既有 content
            # 冪等回傳舊卡,無腦 +1 會把「跳過的重複」誤計為新增。
            pre_ids = {c.id for c in store.all(notebook_id=nb_id)}
            known_ids = set(pre_ids)
            # 第一筆寫入即進入 destructive 區段:之後任一列失敗都會留下部分寫入(#3910)。
            ctx.mark_destructive()
            for r in rows:
                card = store.add(
                    content=r["content"].strip(),
                    meaning=(r.get("meaning") or "").strip(),
                    pos=(r.get("pos") or "").strip() or None,
                    examples=_split_multi(r.get("examples")),
                    collocations=_split_multi(r.get("collocations")),
                    notebook_id=nb_id,
                )
                # 只對本批新插入的卡套用複習態;重複卡(既有或同批先前已插入)回傳舊列,
                # 套用會把既有 review_count/streak/interval 歸零(#3909)。
                is_new = card.id not in known_ids
                known_ids.add(card.id)
                rv = (r.get("review_state") or "").strip()
                if is_new and rv in _VALID_REVIEW_STATES:
                    raw_iv = (r.get("review_interval") or "").strip()
                    iv = float(raw_iv) if raw_iv else None
                    store.update(card.id, **_review_fields(rv, iv, now))
            post_ids = {c.id for c in store.all(notebook_id=nb_id)}
            actually_new = len(post_ids - pre_ids)
            return {"rows": len(rows), "actually_new": actually_new, "skipped_dup": len(rows) - actually_new}

    def verify_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            missing = [
                r["content"] for r in rows if store.find_by_content(r["content"].strip(), notebook_id=nb_id) is None
            ]
            return {"ok": not missing, "missing_count": len(missing), "missing_sample": missing[:5]}

    return ctx.run(action="card-import", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)


def _preview_link_ids(user_dir: Path, notebook_id: str, card_id: str) -> list[str]:
    """dry-run 專用:唯讀列出 notebook graph 中涉及此卡的 active/hidden link id。

    不經 ``create_graph_store``:它對 default 本會把 legacy ``graph.json`` rename 成
    ``graph_default.json``(遷移)並可能回寫,違反 dry-run 零磁碟寫入契約。這裡只讀檔,
    default 本在新檔不存在時直接讀 legacy ``graph.json``。解析規則與 store 載入共用
    ``kg.graph.store.parse_link_rows``(去重、retired kind、rejected、list 格式限定)。
    """
    from kg.graph.store import read_card_links

    path = user_dir / f"graph_{notebook_id}.json"
    if notebook_id == "default" and not path.exists():
        path = user_dir / "graph.json"
    try:
        links = read_card_links(path, card_id)
    except (ValueError, KeyError, TypeError) as exc:  # pydantic ValidationError 亦為 ValueError
        raise EditError(f"graph {path} 含無法解析的 link row，commit 亦會失敗") from exc
    return [lk.id for lk in links]


def cmd_card_move(args: argparse.Namespace) -> int:
    """把卡移到別的筆記本 —— 修正 card-add 誤存 name 的孤兒卡(dogfood A LOW-4)。

    notebook_id 不在 card-update 白名單(刻意),故移動走此專屬語意:解析目標本、
    驗目標本內無同 content 衝突(unique index)、再改 notebook_id。

    **link 處理**:圖譜為 per-notebook、link 兩端須同本。卡搬本後,原本連著它的
    link 必然變成跨本(另一端還在原本),違反不變量 → **硬刪**那些 link(維持「無跨本
    link」不變式),result 報告刪除數,operator 可在目標本用 link-add 重建(dogfood
    D HIGH-1)。link id 連的是 card id,故掃所有 notebook graph 找涉及此卡的 link。
    """
    dd = data_dir()
    ctx = EditContext(data_dir=dd, uid=args.uid, commit=args.commit, json_mode=args.json)
    target_nb = _resolve_notebook_id_for_command(ctx.user_dir, args.to_notebook)
    plan: dict[str, Any] = {"card_ref": args.card, "to_notebook": target_nb}
    state: dict[str, Any] = {}

    def check_move(store: Any) -> Any:
        card = _resolve_card_id(store, args.card)
        if card.notebook_id == target_nb:
            raise EditError(f"卡已在 notebook {target_nb},無需移動")
        clash = store.find_by_content(card.content, notebook_id=target_nb)
        if clash is not None and clash.id != card.id:
            raise EditError(f"目標 notebook {target_nb} 內已有 content={card.content!r} 的卡 {clash.id}")
        return card

    if not ctx.commit:
        # dry-run 不會呼叫 apply_fn:唯讀部分(解析卡、同本/clash 檢查、link 掃描)在此預演,
        # 讓 preview 與 --commit 同樣失敗,並列出將被硬刪的 link(#2706)。
        with closing(_card_store(ctx.user_dir)) as store:
            card = check_move(store)
        purge_ids: list[str] = []
        with closing(_notebook_store(ctx.user_dir)) as nb_store:
            all_nb_ids = {"default"} | {nb.id for nb in nb_store.all()}
        for gnb in sorted(all_nb_ids):
            purge_ids.extend(_preview_link_ids(ctx.user_dir, gnb, card.id))
        plan["card_id"] = card.id
        plan["purge_link_ids"] = purge_ids
        plan["purge_count"] = len(purge_ids)
        plan["purge_note"] = "commit 會硬刪這些 link 並封鎖該 pair 重新 judge(搬本後必跨本)"

    def apply_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            card = check_move(store)
            moved_id = card.id
            # 搬本前先硬刪所有 notebook graph 中涉及此卡的 link(搬後必跨本)。掃全部本
            # (default + 所有既存)的 graph,找 from/to == moved_id 的 link 刪除。
            ctx.mark_destructive()
            with closing(_notebook_store(ctx.user_dir)) as nb_store:
                all_nb_ids = {"default"} | {nb.id for nb in nb_store.all()}
                # #2898:先開啟並讀取「所有」graph(壞 row 會在載入時拋錯),全部通過才進入刪除,
                # 避免前面的本已硬刪、後面的本才因壞 row 失敗而留下半套狀態。
                graphs = {gnb: _graph_store(ctx.user_dir, gnb) for gnb in sorted(all_nb_ids)}
                pending = {gnb: graph.get_links_for(moved_id) for gnb, graph in graphs.items()}
                purged_links: list[str] = []
                peers_by_nb: dict[str, set[str]] = {}
                for gnb, graph in graphs.items():
                    for lk in pending[gnb]:
                        peer = lk.to_id if lk.from_id == moved_id else lk.from_id
                        peers_by_nb.setdefault(gnb, set()).add(peer)
                        graph.hard_delete_link(lk.id, source="ops")
                        purged_links.append(lk.id)
                    # 舊本的 pending_judge / candidates 也要清,否則下輪 judge 仍會
                    # 拿這張(已搬走的)卡跟舊本卡配對出跨本 link。
                    graph.remove_candidates_for(moved_id)
                    graph.remove_pending_judge_for(moved_id)
            # touch barrier:對端失去 link,須 bump updated_at 讓裝置增量 pull 重讀。
            touched_peers = sum(store.batch_touch(ids, notebook_id=gnb) for gnb, ids in peers_by_nb.items())
            old_nb = card.notebook_id
            updated = store.update(card.id, notebook_id=target_nb)
            if updated is None:
                raise EditError(f"move 失敗(卡可能已刪除):{card.id}")
            # 舊本向量逐出:否則舊本 find_similar 仍回傳此卡(已不在該本)。
            _evict_embedding(ctx.user_dir, old_nb, card.id)
            state["card_id"] = updated.id
            return {
                "card": _card_brief(updated),
                "purged_links": purged_links,
                "purged_count": len(purged_links),
                "touched_peers": touched_peers,
            }

    def verify_fn() -> dict[str, Any]:
        with closing(_card_store(ctx.user_dir)) as store:
            c = store.get(state["card_id"])
            return {"ok": c is not None and not c.is_deleted and c.notebook_id == target_nb}

    return ctx.run(action="card-move", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)
