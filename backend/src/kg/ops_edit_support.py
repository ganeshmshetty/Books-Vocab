#!/usr/bin/env python3
"""ops_edit.py — container 內部署的**寫入**工具(`ops_cli.py` 唯讀面的可寫對應)。

`ops_cli.py` 唯讀查詢;本檔負責**安全地編輯** production 業務資料:建用戶 / 增改刪
單字卡 / 設複習態 / 建筆記本 / 連結知識圖譜 / 一次性 seed 整套 demo 帳號 / restore。

安全模型(全部由 `kg.ops_edit_shared.EditContext` 強制)
-----------------------------------------------------
* **dry-run 預設** —— 不加 `--commit` 只印 plan,零磁碟寫入。
* **寫前自動 tar 備份** 整個 user_dir 到 `data_dir/_ops_backups/`(可 restore)。
* **uid path-safe guard** + 預設要求 user 已存在(`user-create` / `restore` 除外)。
* **落地後讀回驗證** + append 到 `_ops_edit_audit.jsonl`。

寫入一律走 app 的 per-user store(`CardStore`/`GraphStore`/`NotebookStore`)——
NFC 正規化 / unique index / graph filelock merge 都是它們的 SoT,本檔不重刻。
容器內 `PYTHONPATH=/app/src` 使 `import kg.*` 可用;`KG_DATA_DIR` 切資料根
(dogfooding 注入 sandbox dir 即可零生產風險地完整演練)。
"""

from __future__ import annotations

import argparse  # noqa: F401 - re-exported for ops_edit_* command modules
import csv  # noqa: F401 - re-exported for ops_edit_* command modules
import hashlib
import json
import shutil
import sqlite3
import sys  # noqa: F401 - re-exported for ops_edit_* command modules
import tarfile
import tempfile  # noqa: F401 - re-exported for ops_edit_* command modules
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from kg.api_models.common import VocabSource
from kg.api_models.graph import AutoLinkConfig  # noqa: F401 - re-exported for ops_edit_* command modules
from kg.api_models.notebook import VocabUIConfig  # noqa: F401 - re-exported for ops_edit_* command modules
from kg.api_models.review import (  # noqa: F401 - re-exported for ops_edit_* command modules
    ReviewClockConfig,
    ReviewModeConfig,
)
from kg.api_models.translate import TranslationLanguageConfig  # noqa: F401 - re-exported for ops_edit_* command modules
from kg.cards import CardStore
from kg.cards.model import Card
from kg.demo_review_synth import CardReviewState, synthesize_many  # noqa: F401 - synthesize_many re-exported
from kg.graph.models import LinkKind  # noqa: F401 - re-exported for ops_edit_* command modules
from kg.notebook import NotebookStore
from kg.ops_edit_shared import (
    EditContext,  # noqa: F401 - re-exported for ops_edit_* command modules
    EditError,
    assert_safe_uid,  # noqa: F401 - re-exported for ops_edit_* command modules
    backup_world,  # noqa: F401 - re-exported for ops_edit_* command modules
    emit,  # noqa: F401 - re-exported for ops_edit_* command modules
    list_user_backups,  # noqa: F401 - re-exported for ops_edit_* command modules
    user_dir_for,  # noqa: F401 - re-exported for ops_edit_* command modules
    users_file,
    users_lock_file,
    world_backup_root,
)
from kg.ops_shared import NOTEBOOK_FILE_SPECS, data_dir  # noqa: F401 - re-exported for ops_edit_* command modules
from kg.ops_world_projection import project_user_world  # noqa: F401 - re-exported for ops_edit_* command modules
from kg.review_events import ReviewEventStore
from kg.user_store import load_users_from, parse_datetime, save_users_to
from kg.users_lock import bounded_users_filelock
from kg.worker_guard import WORKER_LOCK_FILENAME

_VALID_REVIEW_STATES = ("new", "due", "reviewed")
_USER_BACKUP_META_DIR = ".ops_meta"
_USER_BACKUP_RECORD = "user_record.json"
_USER_BACKUP_EMAIL_INDEX = "email_index.json"
_WORLD_BACKUP_ROOT = "__kg_world__"

# `card-update --set` 的可寫欄位白名單。`CardStore.update` 本身用 hasattr 放行
# **任何**模型欄位(含 id / is_deleted / notebook_id / content_nfc_lower /
# timestamps),CLI 層必須收斂成明確白名單,否則 operator 可注入主鍵、繞過
# card-delete 軟刪、把卡移到不存在的筆記本。複習態走 `card-set-review`(語意
# sugar)、刪除走 `card-delete`,故 review_* 與 is_deleted 刻意不在白名單。
_CARD_UPDATABLE_FIELDS = frozenset(
    {
        "content",
        "meaning",
        "pos",
        "examples",
        "collocations",
        "note",
        "difficulty",
        "mode",
        "root_form",
        "inflections",
    }
)


def _passthrough_normalize(users: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    """users.json 的 identity normalize:原樣讀寫,不碰 subscription 正規化。

    app 的 `normalize_users_payload` 需 `default_subscription_payload`
    (啟動期 wiring 的事);建/改 demo user record 與那些無關。passthrough 讓我們
    複用 `save_users_to` 的 atomic tmp→replace 寫入,同時**完整保留**既有 record
    的任何欄位(subscription / linked_ids / secret …),不破壞。
    """
    return users, False


# ── store helpers ──────────────────────────────────────────


def _card_store(user_dir: Path) -> CardStore:
    return CardStore(user_dir / "cards.db")


def _notebook_store(user_dir: Path) -> NotebookStore:
    return NotebookStore(user_dir / "notebooks.db")


def _graph_store(user_dir: Path, notebook_id: str = "default"):
    # function-level import:graph 路徑解析含 default-notebook legacy 遷移,
    # 借用 service_factories(它順帶 import embeddings/numpy);card/notebook
    # 操作不需要它,故不在 module top import,免無謂拉重依賴。
    from kg.service_factories import create_graph_store

    return create_graph_store(user_dir, notebook_id)


def _card_brief(card: Card) -> dict[str, Any]:
    return {
        "id": card.id,
        "content": card.content,
        "meaning": card.meaning,
        "pos": card.pos,
        "notebook_id": card.notebook_id,
        "review_count": card.review_count,
        "next_review_at": card.next_review_at,
        "last_review_feedback": card.last_review_feedback,
    }


def _split_multi(raw: str | None) -> list[str]:
    """CSV 風格多值:`a|b|c` → ['a','b','c'];空字串 → []。"""
    if not raw:
        return []
    return [s for s in (part.strip() for part in raw.split("|")) if s]


def _assert_clean_notebook_name(name: str) -> None:
    """notebook name 基本 sanity:非空、無控制字元、不過長。

    name 會顯示在 iOS UI 且被 seed 的 name→id 映射使用,放任 `\\n` / 超長 /
    `../../x` 類字串進來會傷 demo 帳號品質與映射可讀性。graph 檔路徑用隨機 hex id
    故無路徑逃逸,但路徑符號(`/` `\\` NUL)進到 name 仍是髒值(iOS 顯示異常、
    audit 可讀性差),一併擋掉。
    """
    if not name or not name.strip():
        raise EditError("notebook name 不可空白")
    if any(ord(ch) < 0x20 for ch in name):
        raise EditError("notebook name 不可含控制字元(換行/tab 等)")
    if any(ch in name for ch in ("/", "\\", "\x00")):
        raise EditError("notebook name 不可含路徑符號(/ \\ NUL)")
    if len(name) > 100:
        raise EditError(f"notebook name 過長(>100 chars):{len(name)}")


def _review_fields(state: str, interval_hours: float | None, now: datetime) -> dict[str, Any]:
    """把語意化的複習態映成 card 欄位(spaced-review state)。

    new       —— 從未複習(生詞庫「未學習」桶)。
    due       —— 已學過、現在到期(next_review_at 在過去,TodayReview 會撈)。
    reviewed  —— 剛複習完、下次在未來(「已複習」桶)。

    未知 state **fail-loud** raise(而非靜默落入 else 兜底成 reviewed):dogfood
    抓到 seed 路徑把 `{"state":"bogus"}` 當 reviewed 寫入,無聲污染複習態分布。
    在此 defense-in-depth 一次根治所有呼叫端(seed / card-add / card-set-review)。
    """
    if state not in _VALID_REVIEW_STATES:
        raise EditError(f"未知複習態 {state!r}(僅允許 {_VALID_REVIEW_STATES})")
    # interval 須 > 0:負/零會讓 due 的 last_reviewed 落到未來、reviewed 的 next_review
    # 落到過去,破壞「reviewed→next 在未來」「due→last 在過去」不變量。argparse type=float
    # 不擋負值,在此一次根治所有呼叫端(card-add/card-set-review/card-import/seed)。
    if interval_hours is not None and interval_hours <= 0:
        raise EditError(f"複習間隔須 > 0 小時,得到 {interval_hours}")
    if state == "new":
        return {
            "review_count": 0,
            "review_streak": 0,
            "lapse_count": 0,
            "next_review_at": None,
            "last_reviewed_at": None,
            "last_review_feedback": -1,
            "review_interval_hours": interval_hours or 12.0,
        }
    iv = interval_hours or (12.0 if state == "due" else 24.0)
    if state == "due":
        # 內部自洽:last_reviewed + interval == next_review,且 next_review 落在
        # 過去(now - 1h)確保 TodayReview 撈得到。故 last = now - (iv + 1h)。
        last = now - timedelta(hours=iv + 1)
        return {
            "review_count": 1,
            "review_streak": 1,
            "lapse_count": 0,
            "last_reviewed_at": last,
            "next_review_at": last + timedelta(hours=iv),  # == now - 1h,已到期且自洽
            "last_review_feedback": 1,
            "review_interval_hours": iv,
        }
    # reviewed
    return {
        "review_count": 2,
        "review_streak": 2,
        "lapse_count": 0,
        "last_reviewed_at": now,
        "next_review_at": now + timedelta(hours=iv),
        "last_review_feedback": 1,
        "review_interval_hours": iv,
    }


def _parse_seed_datetime(raw: Any, label: str) -> datetime | None:
    parsed = parse_datetime(raw)
    if raw is not None and parsed is None:
        raise EditError(f"{label} 必須是 ISO datetime 或 Unix timestamp:{raw!r}")
    return parsed


def _source_to_json(raw: Any, label: str) -> str | None:
    if raw is None:
        return None
    if isinstance(raw, str):
        if not raw.strip():
            return None
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise EditError(f"{label} 字串必須是 VocabSource JSON object") from exc
    if not isinstance(raw, dict):
        raise EditError(f"{label} 必須是 VocabSource object 或 JSON string")
    try:
        source = VocabSource(**raw)
    except Exception as exc:
        raise EditError(f"{label} 不符合 VocabSource schema:{exc}") from exc
    return source.model_dump_json(exclude_none=True)


def _as_utc(dt: datetime) -> datetime:
    """把 store 讀回的 datetime 統一成 aware UTC。

    SQLModel/SQLAlchemy 的 DateTime 欄位不存時區,寫入 aware、讀回 **naive**;
    直接拿讀回值與 `datetime.now(UTC)` 比較會炸 TypeError(naive vs aware)。
    naive 視為 UTC(寫入端一律 UTC),aware 原樣。
    """
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=UTC)


def _resolve_card_id(store: CardStore, ref: str, notebook_id: str | None = None) -> Card:
    """把 card 參照(id 或 content)解析成 Card。找不到 raise EditError。"""
    card = store.get(ref)
    if card and not card.is_deleted:
        return card
    card = store.find_by_content(ref, notebook_id=notebook_id)
    if card and not card.is_deleted:
        return card
    raise EditError(f"card not found: {ref!r}(既非 id 也非現存 content)")


def _resolve_card_in_notebook(store: CardStore, ref: str, notebook_id: str) -> Card:
    """同本解析 link 端點 card(id 或 content),嚴格限定在 ``notebook_id`` 內。

    KG 圖譜是 **per-notebook**,link 兩端必須同本(graph_<nb>.json 只裝該本的 link)。
    故 link 場景的 card 解析不可跨本 fallback。卡在別本時給精準錯誤(而非籠統
    「card not found」),引導 operator 把 card 與 link 對齊到同一 notebook。
    link-add 與 seed 的 link 解析共用。
    """
    card = store.get(ref)
    if card and not card.is_deleted and card.notebook_id == notebook_id:
        return card
    card = store.find_by_content(ref, notebook_id=notebook_id)
    if card and not card.is_deleted:
        return card
    elsewhere = store.find_by_content(ref, notebook_id=None)
    if elsewhere is not None and not elsewhere.is_deleted:
        raise EditError(
            f"card {ref!r} 在別的 notebook({elsewhere.notebook_id}),但 link 兩端須與 link "
            f"同在 notebook {notebook_id}(圖譜為 per-notebook,不支援跨本 link)"
        )
    raise EditError(f"card not found in notebook {notebook_id}: {ref!r}")


def _resolve_notebook_id(user_dir: Path, ref: str) -> str:
    """把 notebook 參照(name 或 id)解析成實際 notebook id。

    operator 直覺會傳 name(「Classic Literature」),但 `CardStore.add` 把 notebook_id
    原樣存進 DB —— 傳 name 會建出 iOS 任何視圖都查不到的**孤兒卡**(dogfood A HIGH-2)。
    此處統一解析:`"default"` / 既存 name / 既存 id → id;否則 fail-loud,絕不靜默把
    name 當 id 存。card-add / card-import / link-add / card-move 共用,語意對齊 seed 的
    `_resolve_nb`。name 撞多本時取 `NotebookStore.all()` 排序首筆(sort_order, created_at)。
    """
    if ref == "default":
        return "default"
    store = _notebook_store(user_dir)
    try:
        # id 精確匹配**優先**於 name 掃描:若某本 name 恰好等於另一本的 hex id,傳該 id
        # 字串應解析成 id 那本,而非 name 那本(dogfood D HIGH-3)。id 是 primary key,
        # get(name) 必為 None,故 exists() 只對真正的 id 為真,不會誤吞 name。
        if store.exists(ref):
            return ref
        for nb in store.all():
            if nb.name == ref:
                return nb.id
        raise EditError(f"notebook not found: {ref!r}(既非既存 id 也非既存 name;先 notebook-create)")
    finally:
        store.close()


def _link_on_disk(graph: Any, link_id: str) -> bool:
    """直接讀 ``graph.links_path`` 的 JSON,確認 link 真的落盤(繞過進程內快取)。

    `create_graph_store` 走 `_get_cached`,apply 與 verify 拿**同一實例**;`get_link`
    讀記憶體 `_links`,若 `_flush_links` 靜默寫失敗,verify 仍報綠(dogfood C1 的架構級
    false-green)。改讀磁碟 JSON,verify 的綠才等於磁碟真相。links 檔可能是 list 或
    以 id 為鍵的 dict,兩種形狀都認。
    """
    p = graph.links_path
    if not p.exists():
        return False
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    entries = data if isinstance(data, list) else list(data.values()) if isinstance(data, dict) else []
    return any(isinstance(e, dict) and e.get("id") == link_id for e in entries)


# ── users.json 編輯(共用 app 的 load/save + FileLock) ──


def _mutate_users(data_dir_path: Path, mutate) -> dict[str, Any]:
    """在 app 的 users.json 寫鎖下 load→mutate→save。回傳 mutate 的結果。"""
    uf = users_file(data_dir_path)
    with bounded_users_filelock(users_lock_file(data_dir_path)):
        users = load_users_from(uf, _passthrough_normalize) if uf.exists() else {}
        result = mutate(users)
        save_users_to(uf, users, _passthrough_normalize)
    return result


def _restore_user_record_snapshot(
    data_dir_path: Path, uid: str, *, record: dict[str, Any] | None, email_index: dict[str, Any] | None
) -> list[str]:
    """把 per-user backup 內嵌的 users.json snapshot merge 回目前 users.json。

    restore 粒度是「單帳號」，所以不能用備份裡的整份 users.json 覆蓋現況；只回復
    target uid 的 record 與對應 email index 條目，避免誤傷其他帳號。
    """

    skipped: list[str] = []

    def mutate(users: dict[str, Any]) -> dict[str, Any]:
        if record is not None:
            users[uid] = record
        # 還原即撤銷 operator user-delete 蓋的墓碑(無論 snapshot 是否含 record),
        # 否則還原後的帳號 token 永遠 401。
        revoked = users.get("_revoked_before")
        if isinstance(revoked, dict):
            revoked.pop(uid, None)
            if not revoked:
                users.pop("_revoked_before", None)
        terminated = users.get("_terminated")
        if isinstance(terminated, list) and uid in terminated:
            remaining = [t for t in terminated if t != uid]
            if remaining:
                users["_terminated"] = remaining
            else:
                users.pop("_terminated", None)
        idx = users.setdefault("_email_index", {})
        if not isinstance(idx, dict):
            idx = {}
            users["_email_index"] = idx
        stale = [email for email, mapped_uid in idx.items() if mapped_uid == uid]
        for email in stale:
            idx.pop(email, None)
        if email_index:
            for email, mapped_uid in email_index.items():
                if mapped_uid != uid:
                    continue
                owner = idx.get(email)
                if owner is not None and owner != uid:
                    # 該 email 已被他人佔用:不搶,交由 operator 處理(見 #2704)。
                    skipped.append(email)
                    continue
                idx[email] = uid
        return {"restored": uid}

    _mutate_users(data_dir_path, mutate)
    return skipped


def _extract_user_backup_members(
    tar: tarfile.TarFile, uid: str, target_parent: Path
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    members = tar.getmembers()
    record: dict[str, Any] | None = None
    email_index: dict[str, Any] | None = None
    for member in members:
        name = member.name.lstrip("./")
        if name == f"{uid}/{_USER_BACKUP_META_DIR}/{_USER_BACKUP_RECORD}":
            fileobj = tar.extractfile(member)
            if fileobj is not None:
                data = json.loads(fileobj.read().decode("utf-8"))
                record = data if isinstance(data, dict) else None
            continue
        if name == f"{uid}/{_USER_BACKUP_META_DIR}/{_USER_BACKUP_EMAIL_INDEX}":
            fileobj = tar.extractfile(member)
            if fileobj is not None:
                data = json.loads(fileobj.read().decode("utf-8"))
                email_index = data if isinstance(data, dict) else None
            continue
        if f"/{_USER_BACKUP_META_DIR}/" in name:
            continue
        tar.extract(member, path=target_parent, filter="data")
    return record, email_index


def _world_members(data_dir_path: Path) -> list[Path]:
    # .worker.lock 是執行中 API 持有的 flock 所在 inode；刪除或換新會讓第二個 worker 拿到鎖。
    excluded = {
        world_backup_root(data_dir_path).name,
        "_ops_backups",
        "_ops_edit_audit.jsonl",
        "users.json.lock",
        WORKER_LOCK_FILENAME,
    }
    return [p for p in sorted(Path(data_dir_path).iterdir()) if p.name not in excluded]


def _replace_world_from_snapshot(data_dir_path: Path, snapshot_root: Path) -> list[str]:
    removed: list[str] = []
    for existing in _world_members(data_dir_path):
        removed.append(existing.name)
        if existing.is_dir():
            shutil.rmtree(existing)
        else:
            existing.unlink()
    restored: list[str] = []
    for item in sorted(snapshot_root.iterdir()):
        if item.name == WORKER_LOCK_FILENAME:
            continue
        dest = Path(data_dir_path) / item.name
        if item.is_dir():
            shutil.copytree(item, dest)
        else:
            shutil.copy2(item, dest)
        restored.append(item.name)
    return restored


# ── clone-demo ─────────────────────────────────────────────
#
# 從一個高品質真帳號 byte-clone 整個 vocab 層(cards/notebooks/graph/embeddings/
# candidates)到目標 demo 帳號,再由 cards.db 的複習聚合合成 review_events.db。
# 走 store 級重放會丟 embeddings 並重算 graph;檔案級 clone 才是高保真。identity
# (users.json,在 data_dir 根、非 user_dir)結構上不被碰,故 demo 帳號保留自己的
# Google provider/email/subscription。

# vocab 層 SQLite(以 online backup API 複製,WAL-safe;不抓 -wal/-shm/.bak)。
# daily_review_stats.db 目前無 producer/consumer(heatmap 走合成的 review_events),
# 但生產 user_dir 實存此檔;為高保真一併複製(.exists() guard,缺則跳過,零風險)。
_CLONE_SQLITE = ("cards.db", "notebooks.db", "daily_review_stats.db")
# vocab 層衍生檔(精確 glob,排除 .bak/.lock/.tmp)。
_CLONE_GLOBS = (
    "graph_*.json",
    "embeddings_*.npy",
    "embeddings_meta_*.json",
    "candidates_*.json",
    "card_ids_*.json",
    "blocked_*.json",
)
# 目標端「屬於 vocab 層」的判定:clone 前清空,避免殘留舊 notebook 的孤兒
# graph/embeddings 與 -wal/-shm/.lock。review_events.db 一併清(由本次合成重建)。
_VOCAB_DB_STEMS = ("cards.db", "notebooks.db", "daily_review_stats.db", "review_events.db")
# 由 ops_shared.NOTEBOOK_FILE_SPECS 推導(含 pending_judge_ 與 notebook 化前的 legacy 檔名),
# 避免 seed --replace / clone-demo 漏清 `_migrate_legacy_file` 會 rename 回來的舊檔。
_VOCAB_PREFIXES = tuple(template.split("{nb}")[0] for template, _ in NOTEBOOK_FILE_SPECS.values())
_VOCAB_LEGACY_NAMES = tuple(legacy for _, legacy in NOTEBOOK_FILE_SPECS.values() if legacy)
_CLONE_TMP_SUFFIX = ".clone-tmp"


def _is_vocab_file(name: str) -> bool:
    """目標端某檔是否屬 clone 會接管的 vocab 層(含其 -wal/-shm/.lock/.bak 旁檔)。"""
    if name.endswith(_CLONE_TMP_SUFFIX):
        return False
    for stem in _VOCAB_DB_STEMS:
        if name == stem or name.startswith(stem + "-") or name.startswith(stem + "."):
            return True
    if any(
        name == legacy or name.startswith(legacy + ".") or name.startswith(legacy + "-")
        for legacy in _VOCAB_LEGACY_NAMES
    ):
        return True
    return any(name.startswith(p) for p in _VOCAB_PREFIXES)


def _sqlite_online_backup(src: Path, dst: Path) -> None:
    """以 SQLite online backup API 複製(WAL-safe,產出乾淨單檔,毋須 -wal/-shm)。

    backup 持有來源讀交易快照:即使來源正被 app 寫入也得一致快照,**不** checkpoint、
    **不**改 main db / -wal。唯一可能的副作用:來源 -shm 不存在且 -wal 有資料時,
    開 mode=ro 會重建一個 -shm sidecar(可再生、無害),故「source 唯讀」指邏輯資料不變。
    """
    src_conn = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    try:
        dst_conn = sqlite3.connect(str(dst))
        try:
            src_conn.backup(dst_conn)
        finally:
            dst_conn.close()
    finally:
        src_conn.close()


def _clone_source_files(src_dir: Path) -> tuple[list[Path], list[Path]]:
    """回傳 (要 backup 的 SQLite 檔, 要直接複製的衍生檔)。"""
    sqlite_files = [src_dir / n for n in _CLONE_SQLITE if (src_dir / n).exists()]
    others: list[Path] = []
    for pat in _CLONE_GLOBS:
        others.extend(p for p in sorted(src_dir.glob(pat)) if p.is_file())
    return sqlite_files, others


def _parse_db_dt(raw: Any) -> datetime | None:
    """解析 cards.db 的 timestamp(naive 'YYYY-MM-DD HH:MM:SS.ffffff' 視為 UTC)。"""
    if not raw:
        return None
    s = str(raw).strip().replace(" ", "T")
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def _read_card_review_states(cards_db: Path) -> list[CardReviewState]:
    """讀有複習紀錄的卡(含已刪 —— 過去複習仍是真實 heatmap 歷史)。"""
    if not cards_db.exists():
        return []
    conn = sqlite3.connect(f"file:{cards_db}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT id, content, notebook_id, review_count, lapse_count, review_streak, "
            "last_review_feedback, last_reviewed_at, created_at, review_interval_hours "
            "FROM card WHERE review_count > 0 AND last_reviewed_at IS NOT NULL"
        ).fetchall()
    finally:
        conn.close()
    states: list[CardReviewState] = []
    for r in rows:
        last = _parse_db_dt(r["last_reviewed_at"])
        if last is None:
            continue
        created = _parse_db_dt(r["created_at"]) or last
        fb = r["last_review_feedback"]
        states.append(
            CardReviewState(
                card_id=r["id"],
                content=r["content"],
                notebook_id=r["notebook_id"] or "default",
                review_count=int(r["review_count"] or 0),
                lapse_count=int(r["lapse_count"] or 0),
                review_streak=int(r["review_streak"] or 0),
                last_review_feedback=int(fb) if fb is not None else -1,
                last_reviewed_at=last,
                created_at=created,
                review_interval_hours=float(r["review_interval_hours"] or 12.0),
            )
        )
    return states


def _count_active_cards(cards_db: Path) -> int:
    if not cards_db.exists():
        return 0
    conn = sqlite3.connect(f"file:{cards_db}?mode=ro", uri=True)
    try:
        return int(conn.execute("SELECT COUNT(*) FROM card WHERE is_deleted = 0").fetchone()[0])
    finally:
        conn.close()


def _count_graph_links(user_dir: Path) -> int:
    """所有 graph_*.json 的 active link 總數。"""
    total = 0
    for p in sorted(user_dir.glob("graph_*.json")):
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        if isinstance(data, list):
            total += sum(1 for lk in data if isinstance(lk, dict) and lk.get("status", "active") == "active")
    return total


def _count_review_events(events_db: Path) -> int:
    if not events_db.exists():
        return 0
    store = ReviewEventStore(events_db)
    try:
        return len(store.all())
    finally:
        store.close()


def _clone_source_fingerprint(src_dir: Path) -> str:
    """對 clone-demo 實際複製的 vocab 層做穩定指紋，讓 scenario 可 pin 來源狀態。"""
    sqlite_files, other_files = _clone_source_files(src_dir)
    digest = hashlib.sha256()
    for path in [*sqlite_files, *other_files]:
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(65536)
                if not chunk:
                    break
                digest.update(chunk)
    return digest.hexdigest()


def _list_world_backups(dd: Path) -> list[dict[str, Any]]:
    root = world_backup_root(dd)
    if not root.exists():
        return []
    out: list[dict[str, Any]] = []
    for p in sorted(root.glob("*.tar.gz"), reverse=True):
        st = p.stat()
        out.append(
            {
                "path": str(p),
                "size": st.st_size,
                "mtime": datetime.fromtimestamp(st.st_mtime, tz=UTC).isoformat(),
            }
        )
    return out


# This module owns semantic helpers only.  Do not derive ``__all__`` from the
# module namespace: doing so turns imported stdlib names, types, and stores
# into an accidental compatibility API for command modules.
__all__ = (
    "_CARD_UPDATABLE_FIELDS",
    "_CLONE_TMP_SUFFIX",
    "_VALID_REVIEW_STATES",
    "_WORLD_BACKUP_ROOT",
    "_as_utc",
    "_assert_clean_notebook_name",
    "_card_brief",
    "_card_store",
    "_clone_source_files",
    "_clone_source_fingerprint",
    "_count_active_cards",
    "_count_graph_links",
    "_count_review_events",
    "_extract_user_backup_members",
    "_graph_store",
    "_is_vocab_file",
    "_link_on_disk",
    "_list_world_backups",
    "_mutate_users",
    "_notebook_store",
    "_parse_db_dt",
    "_parse_seed_datetime",
    "_passthrough_normalize",
    "_read_card_review_states",
    "_replace_world_from_snapshot",
    "_resolve_card_id",
    "_resolve_card_in_notebook",
    "_resolve_notebook_id",
    "_review_fields",
    "_source_to_json",
    "_sqlite_online_backup",
    "_split_multi",
    "_USER_BACKUP_META_DIR",
    "_USER_BACKUP_RECORD",
    "_WORLD_BACKUP_ROOT",
)
