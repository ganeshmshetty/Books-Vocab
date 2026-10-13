"""ops_edit_shared.py — 寫入專用 ops infra（``ops_shared.py`` 唯讀面的可寫對應）。

`ops_shared` 一律唯讀（`connect_ro` / `assert_readonly_sql`）。本 module 是它的
**可寫對應面**:dry-run 框架、寫前自動備份、audit log、uid 安全 guard、統一
JSON/human 輸出契約。供 `backend/ops_edit.py`(container 內 `/app/ops_edit.py`)使用。

設計原則
--------
1. **複用 app 的 per-user store 作為寫入 SoT** —— 不重刻 NFC 正規化 /
   unique partial index / graph filelock merge / WAL。`CardStore` /
   `GraphStore` / `NotebookStore` 就是真相;edit 工具只是它們的 CLI 殼。
   只 import **per-user** store,**不**碰會「開檔即寫」的全域 log 單例
   (`pipeline_log` / `token_tracker` / `judge_log` …)。
2. **dry-run 預設,`--commit` 才落地** —— 對齊 `release.sh` / `asc.sh` 慣例。
   未 commit 時零磁碟寫入,只印 plan。
3. **每次 commit 前自動 tar 整個 user_dir** —— 寫壞可一鍵 `restore`。
4. **uid path-safe guard** —— 與 `user_context._USER_ID_ALLOWED` 同源,
   crafted uid 不可逃出 per-user sandbox。
"""

from __future__ import annotations

import json
import logging
import os
import re
import shlex
import shutil
import sqlite3
import stat
import tarfile
import tempfile
from datetime import UTC, datetime
from io import BytesIO
from pathlib import Path
from typing import Any, Protocol

# uid 會被 join 進檔案系統路徑(`data_dir/users/<uid>`),必須限制在 path-safe
# 白名單,否則 crafted uid 可用 `/` 或 `..` 逃出 sandbox。鏡像
# `user_context._USER_ID_ALLOWED`(Apple sub 帶點故允許 `.`;`.`/`..` 另外擋)。
_USER_ID_ALLOWED = re.compile(r"^[a-zA-Z0-9_.-]+$")

_BACKUP_DIRNAME = "_ops_backups"
_WORLD_BACKUP_DIRNAME = "_ops_world_backups"
_AUDIT_FILENAME = "_ops_edit_audit.jsonl"
_META_DIRNAME = ".ops_meta"
_USER_RECORD_SNAPSHOT = "user_record.json"
_EMAIL_INDEX_SNAPSHOT = "email_index.json"
_BACKUP_MANIFEST = "backup_manifest.json"
_WORLD_ROOT_ARCNAME = "__kg_world__"
# 檔名上限保守值(macOS/Linux 單段 255 bytes;留 buffer 給備份檔的 timestamp 後綴)。
_MAX_UID_LEN = 200
_SQLITE_SIDECAR_SUFFIXES = (".db-wal", ".db-shm", ".db-journal")


logger = logging.getLogger(__name__)


class EditError(Exception):
    """使用者可讀的編輯失敗(訊息直接呈現,不附 traceback)。"""


class ApplyFn(Protocol):
    def __call__(self) -> object: ...


class VerifyFn(Protocol):
    def __call__(self) -> dict[str, object] | None: ...


def assert_safe_uid(uid: str) -> None:
    """擋掉非 path-safe 的 uid。違反 raise :class:`EditError`。

    白名單字元外,**明確**擋掉 `.` 與 `..`:單獨的 `.` 會讓
    ``user_dir_for(dd, '.')`` 坍縮成 ``data_dir/users/`` 根目錄(破壞 per-user
    隔離,且備份會把全體用戶打包),而字元白名單 `^[a-zA-Z0-9_.-]+$` 本身放行
    孤立的 `.`。亦擋以 `.` 開頭的 uid(`.hidden`):它會建出隱藏 user_dir 與隱藏
    備份檔(`ls` 不加 `-a` 看不見),讓 operator 誤判帳號/備份不存在;真實 OAuth
    sub(Google 純數字、Apple `NNN.hex`)永不以 `.` 起首,擋掉無誤傷。過長 uid 在
    `Path.exists()` 會丟 OSError,先擋成結構化錯誤。
    """
    if not uid or uid in {".", ".."} or ".." in uid or uid.startswith(".") or not _USER_ID_ALLOWED.match(uid):
        raise EditError(f"unsafe user id: {uid!r}(僅允許 [a-zA-Z0-9_.-]、不可為 '.' / '..' 或 '.' 起首)")
    if len(uid) > _MAX_UID_LEN:
        raise EditError(f"user id 過長(>{_MAX_UID_LEN} chars):{len(uid)}")


def users_file(data_dir: Path) -> Path:
    """``data_dir/users.json`` —— 帳號註冊表(settings.users_file 同源)。"""
    return Path(data_dir) / "users.json"


def users_lock_file(data_dir: Path) -> Path:
    """``data_dir/users.json.lock`` —— 與 app 共用的 users.json 寫鎖。"""
    return Path(data_dir) / "users.json.lock"


def user_dir_for(data_dir: Path, uid: str) -> Path:
    """``data_dir/users/<uid>`` —— 單一用戶的 data sandbox。"""
    return Path(data_dir) / "users" / uid


def _now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


def _now_stamp() -> str:
    return datetime.now(tz=UTC).strftime("%Y%m%dT%H%M%SZ")


def _load_users_json_raw(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning("failed to read users.json: path=%s error=%s", path, exc)
        return {}
    return data if isinstance(data, dict) else {}


def _backup_root(data_dir: Path) -> Path:
    return Path(data_dir) / _BACKUP_DIRNAME


def world_backup_root(data_dir: Path) -> Path:
    return Path(data_dir) / _WORLD_BACKUP_DIRNAME


def _add_bytes_member(tar: tarfile.TarFile, arcname: str, payload: bytes) -> None:
    info = tarfile.TarInfo(name=arcname)
    info.size = len(payload)
    info.mtime = int(datetime.now(tz=UTC).timestamp())
    tar.addfile(info, BytesIO(payload))


def _user_meta_arc(uid: str, filename: str) -> str:
    return f"{uid}/{_META_DIRNAME}/{filename}"


def _world_meta_arc(filename: str) -> str:
    return f"{_WORLD_ROOT_ARCNAME}/{_META_DIRNAME}/{filename}"


def _world_snapshot_members(data_dir: Path) -> list[Path]:
    excluded = {
        _BACKUP_DIRNAME,
        _WORLD_BACKUP_DIRNAME,
        _AUDIT_FILENAME,
        "users.json.lock",
    }
    return [p for p in sorted(Path(data_dir).iterdir()) if p.name not in excluded]


def _is_sqlite_sidecar(path: Path) -> bool:
    return path.name.endswith(_SQLITE_SIDECAR_SUFFIXES)


def _sqlite_online_backup(src: Path, dst: Path) -> None:
    """複製 WAL 中的邏輯資料為乾淨單檔，不把 transient sidecar 帶入快照。"""
    src_conn = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    try:
        dst_conn = sqlite3.connect(str(dst))
        try:
            src_conn.backup(dst_conn)
        finally:
            dst_conn.close()
    finally:
        src_conn.close()


def _copy_user_snapshot_tree(src: Path, dst: Path) -> None:
    """把 user tree 複製到穩定 staging；sidecar 消失視為可忽略的 transient。"""
    _copy_snapshot_children(sorted(src.iterdir(), key=lambda path: path.name), dst)


def _copy_snapshot_children(children: list[Path], dst: Path) -> None:
    """把指定的 children 複製進 ``dst``；``.db`` 一律經 online backup，sidecar 跳過。"""
    dst.mkdir(parents=True, exist_ok=True)
    for child in children:
        if _is_sqlite_sidecar(child):
            continue
        target = dst / child.name
        try:
            mode = child.lstat().st_mode
            if stat.S_ISDIR(mode):
                _copy_user_snapshot_tree(child, target)
            elif stat.S_ISREG(mode):
                if child.name.endswith(".db"):
                    _sqlite_online_backup(child, target)
                else:
                    shutil.copy2(child, target)
            elif stat.S_ISLNK(mode):
                target.symlink_to(os.readlink(child))
            else:
                raise OSError(f"unsupported user snapshot member: {child}")
        except FileNotFoundError:
            if _is_sqlite_sidecar(child):
                continue
            raise


def backup_user_dir(data_dir: Path, uid: str) -> Path | None:
    """寫前快照:把整個 ``users/<uid>/`` tar.gz 到 ``data_dir/_ops_backups/``。

    user_dir 不存在(例如 user-create 尚未建)回 ``None``。回傳備份檔路徑。
    備份目錄 `_` 前綴(與 `is_real_user` 一致),不被當成 user。
    """
    src = user_dir_for(data_dir, uid)
    if not src.exists():
        return None
    backup_root = _backup_root(data_dir)
    backup_root.mkdir(parents=True, exist_ok=True)
    dest = backup_root / f"{uid}__{_now_stamp()}.tar.gz"
    # 同秒多次 commit 不覆蓋:碰撞則加序號。
    n = 1
    while dest.exists():
        dest = backup_root / f"{uid}__{_now_stamp()}__{n}.tar.gz"
        n += 1
    users = _load_users_json_raw(users_file(Path(data_dir)))
    record = users.get(uid) if isinstance(users.get(uid), dict) else None
    email_index = users.get("_email_index") if isinstance(users.get("_email_index"), dict) else {}
    scoped_email_index = {k: v for k, v in email_index.items() if v == uid}
    manifest = {
        "schema": "kg.ops_user_backup.v2",
        "uid": uid,
        "capturedAt": _now_iso(),
        "includes": {
            "userDir": True,
            "userRecord": record is not None,
            "emailIndex": bool(scoped_email_index),
        },
    }
    temporary_dest = backup_root / f".{dest.name}.tmp"
    try:
        with tempfile.TemporaryDirectory(prefix="kg-user-backup-") as staging:
            staged_user_dir = Path(staging) / uid
            _copy_user_snapshot_tree(src, staged_user_dir)
            with tarfile.open(temporary_dest, "w:gz") as tar:
                tar.add(staged_user_dir, arcname=uid)
                _add_bytes_member(
                    tar,
                    _user_meta_arc(uid, _BACKUP_MANIFEST),
                    json.dumps(manifest, ensure_ascii=False, default=str).encode("utf-8"),
                )
                if record is not None:
                    _add_bytes_member(
                        tar,
                        _user_meta_arc(uid, _USER_RECORD_SNAPSHOT),
                        json.dumps(record, ensure_ascii=False, default=str).encode("utf-8"),
                    )
                if scoped_email_index:
                    _add_bytes_member(
                        tar,
                        _user_meta_arc(uid, _EMAIL_INDEX_SNAPSHOT),
                        json.dumps(scoped_email_index, ensure_ascii=False, default=str).encode("utf-8"),
                    )
        temporary_dest.replace(dest)
    except Exception:
        temporary_dest.unlink(missing_ok=True)
        raise
    return dest


def backup_world(data_dir: Path, *, label: str = "world") -> Path:
    root = world_backup_root(data_dir)
    root.mkdir(parents=True, exist_ok=True)
    safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-") or "world"
    dest = root / f"{safe_label}__{_now_stamp()}.tar.gz"
    n = 1
    while dest.exists():
        dest = root / f"{safe_label}__{_now_stamp()}__{n}.tar.gz"
        n += 1
    members = _world_snapshot_members(Path(data_dir))
    manifest = {
        "schema": "kg.ops_world_backup.v1",
        "label": safe_label,
        "capturedAt": _now_iso(),
        "members": [p.name for p in members],
    }
    # live WAL 必須先經 online backup 固化成單檔再打包：直接 tar 會把 main .db 與
    # -wal/-shm 分時讀取，遇到並發 checkpoint 即得到互不一致的 torn snapshot。
    with tempfile.TemporaryDirectory(prefix="kg-world-backup-") as staging:
        staged_root = Path(staging) / _WORLD_ROOT_ARCNAME
        _copy_snapshot_children(members, staged_root)
        with tarfile.open(dest, "w:gz") as tar:
            for staged in sorted(staged_root.iterdir(), key=lambda path: path.name):
                tar.add(staged, arcname=f"{_WORLD_ROOT_ARCNAME}/{staged.name}")
            _add_bytes_member(
                tar,
                _world_meta_arc(_BACKUP_MANIFEST),
                json.dumps(manifest, ensure_ascii=False, default=str).encode("utf-8"),
            )
    return dest


def list_user_backups(data_dir: Path, uid: str) -> list[dict[str, Any]]:
    """列出某 uid 的所有備份(最新在前)。供 list-backups / restore 選備份用。

    uid 已由呼叫端 `assert_safe_uid` 過,glob pattern 安全。
    """
    root = Path(data_dir) / _BACKUP_DIRNAME
    if not root.exists():
        return []
    out: list[dict[str, Any]] = []
    for p in sorted(root.glob(f"{uid}__*.tar.gz"), reverse=True):
        st = p.stat()
        out.append(
            {
                "path": str(p),
                "size": st.st_size,
                "mtime": datetime.fromtimestamp(st.st_mtime, tz=UTC).isoformat(),
            }
        )
    return out


def append_audit(data_dir: Path, entry: dict[str, Any]) -> None:
    """把一筆已落地的編輯 append 到 ``data_dir/_ops_edit_audit.jsonl``。

    自管 audit(不 import `admin_audit` 單例,避免耦合會自寫的 DB + sandbox 友善)。
    """
    path = Path(data_dir) / _AUDIT_FILENAME
    line = json.dumps({"ts": _now_iso(), **entry}, ensure_ascii=False, default=str)
    with open(path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def emit(obj: Any, *, json_mode: bool) -> None:
    """統一輸出:`--json` 走純 JSON(stdout),否則人讀摘要。

    與 `ops_shared.emit_json` 對齊(Path/datetime 以 str 序列化)。診斷請走 stderr,
    stdout 只留結構化 payload,讓 dogfooding agent 可直接 `json.loads`。
    """
    if json_mode:
        print(json.dumps(obj, ensure_ascii=False, indent=2, default=str))
        return
    _print_human(obj)


def _print_human(obj: Any) -> None:
    """簡明人讀輸出 —— dogfooding 主走 --json,此處只求可掃讀。"""
    if not isinstance(obj, dict):
        print(obj)
        return
    mode = obj.get("mode", "")
    action = obj.get("action", "")
    icon = {"dry-run": "○", "commit": "●", "error": "✗"}.get(mode, "·")
    print(f"{icon} [{mode}] {action}")
    plan = obj.get("plan")
    if isinstance(plan, dict):
        for k, v in plan.items():
            print(f"    {k}: {v}")
    if obj.get("error"):
        print(f"    error: {obj['error']}")
    if obj.get("backup"):
        print(f"    backup: {obj['backup']}")
    if obj.get("data_mutated"):
        print("    data_mutated: true")
    if obj.get("recovery_path"):
        print(f"    recovery: {obj['recovery_path']}")
    verified = obj.get("verified")
    if verified is not None:
        ok = verified.get("ok") if isinstance(verified, dict) else verified
        print(f"    verified: {'✓' if ok else '✗'}")
    if obj.get("hint"):
        print(f"    → {obj['hint']}")


class EditContext:
    """單一寫操作的編排器:dry-run gate → backup → apply → verify → audit → emit。

    每個子指令把「要做什麼」拆成三件事交給 :meth:`run`:
      * ``plan``  —— 可序列化的變更摘要(dry-run 時就只印它)
      * ``apply_fn`` —— 真正落地的 callable,回傳可序列化 result
      * ``verify_fn`` —— (選用)落地後讀回確認,回傳 ``{"ok": bool, ...}``

    未 ``--commit`` 時 ``apply_fn`` / ``verify_fn`` **完全不被呼叫**,保證零副作用。
    """

    def __init__(
        self,
        *,
        data_dir: Path,
        uid: str,
        commit: bool,
        json_mode: bool,
        require_user: bool = True,
    ) -> None:
        assert_safe_uid(uid)
        self.data_dir = Path(data_dir)
        self.uid = uid
        self.commit = commit
        self.json_mode = json_mode
        self.user_dir = user_dir_for(self.data_dir, uid)
        self._destructive_step_started = False
        if require_user and not self.user_dir.exists():
            raise EditError(f"user not found: {uid}(在 {self.data_dir}/users/ 下無此目錄)")

    def mark_destructive(self) -> None:
        """Mark that the apply callback is about to enter a destructive step.

        The caller must invoke this immediately before the first destructive
        mutation.  If the callback then fails, the error payload explicitly
        directs the operator to the pre-commit backup instead of implying that
        ``committed=false`` means the data was untouched.
        """
        self._destructive_step_started = True

    def run(
        self,
        *,
        action: str,
        plan: dict[str, Any],
        apply_fn: ApplyFn,
        verify_fn: VerifyFn | None = None,
    ) -> int:
        """執行一個寫操作。回傳 process exit code(0 成功 / 1 verify 失敗)。"""
        if not self.commit:
            emit(
                {
                    "mode": "dry-run",
                    "action": action,
                    "uid": self.uid,
                    "plan": plan,
                    "committed": False,
                    "hint": "加 --commit 才會真正寫入(預設 dry-run)",
                },
                json_mode=self.json_mode,
            )
            return 0

        # backup 也包進 try:備份本身可能失敗(目錄不可寫 / 磁碟滿),失敗時必須
        # 走結構化 error 而非拋 traceback 污染 --json。備份在 apply 之前,備份失敗
        # 即中止、不落地 —— 保住「任何寫入前都有可還原快照」的不變式。
        backup = None
        backup_completed = False
        try:
            backup = backup_user_dir(self.data_dir, self.uid)
            backup_completed = True
            result = apply_fn()
        except Exception as exc:  # noqa: BLE001 — 落地失敗要結構化呈現,非 crash
            failure_stage = "backup" if not backup_completed else "apply"
            data_mutated = self._destructive_step_started
            recovery_path = None
            if data_mutated and backup is not None:
                recovery_path = (
                    "cd backend && uv run python ops_edit.py restore "
                    f"{shlex.quote(self.uid)} --backup {shlex.quote(str(backup))} --commit"
                )
            verified = {"ok": False, "stage": failure_stage, "error": str(exc)}
            # 失敗的 commit 也留 audit 痕跡(status=error):備份已建但寫入失敗的
            # 操作此前無任何紀錄,事後審查無跡可查。記下 error + backup,讓 operator
            # 能定位「哪次操作炸了、可從哪個快照回退」。
            append_audit(
                self.data_dir,
                {
                    "action": action,
                    "uid": self.uid,
                    "plan": plan,
                    "status": "error",
                    "error": str(exc),
                    "backup": str(backup) if backup else None,
                    "data_mutated": data_mutated,
                    "recovery_path": recovery_path,
                    "failure_stage": failure_stage,
                    "verified": verified,
                },
            )
            error_payload = {
                "mode": "error",
                "action": action,
                "uid": self.uid,
                "plan": plan,
                "committed": False,
                "error": str(exc),
                "backup": str(backup) if backup else None,
                "data_mutated": data_mutated,
                "recovery_path": recovery_path,
                "failure_stage": failure_stage,
                "verified": verified,
            }
            if failure_stage == "backup":
                error_payload["hint"] = "backup 失敗；未執行資料變更"
            elif data_mutated:
                error_payload["hint"] = (
                    "資料已變更；請依 recovery_path 從 backup 還原"
                    if recovery_path
                    else "資料已變更，但沒有可用 backup；請立即人工處理"
                )
            emit(error_payload, json_mode=self.json_mode)
            logger.warning("Edit operation failed during %s: %s", failure_stage, exc, exc_info=True)
            return 1

        verified = verify_fn() if verify_fn else None
        append_audit(
            self.data_dir,
            {
                "action": action,
                "uid": self.uid,
                "plan": plan,
                "result": result,
                "verified": verified,
                "backup": str(backup) if backup else None,
            },
        )
        emit(
            {
                "mode": "commit",
                "action": action,
                "uid": self.uid,
                "plan": plan,
                "result": result,
                "verified": verified,
                "backup": str(backup) if backup else None,
                "committed": True,
            },
            json_mode=self.json_mode,
        )
        return 0 if (verified is None or verified.get("ok", True)) else 1
