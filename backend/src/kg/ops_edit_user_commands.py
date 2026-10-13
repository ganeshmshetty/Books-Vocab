from __future__ import annotations

import argparse
import logging
import shutil
import tarfile
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from kg.account_erasure import delete_account_assets, sweep_account_prefixes
from kg.api_models.graph import AutoLinkConfig
from kg.api_models.notebook import VocabUIConfig
from kg.api_models.review import ReviewClockConfig, ReviewModeConfig
from kg.api_models.translate import TranslationLanguageConfig
from kg.external_api_keys import purge_external_api_keys
from kg.ops_shared import data_dir
from kg.settings import load_settings
from kg.user_store import load_users_from, parse_datetime

from .ops_edit_shared import EditContext, EditError, assert_safe_uid, emit, user_dir_for, users_file
from .ops_edit_support import (
    _USER_BACKUP_META_DIR,
    _USER_BACKUP_RECORD,
    _card_store,
    _extract_user_backup_members,
    _graph_store,
    _mutate_users,
    _notebook_store,
    _passthrough_normalize,
    _restore_user_record_snapshot,
    list_user_backups,
)


def _resolve_notebook_id_for_command(user_dir: Path, ref: str) -> str:
    """Resolve a notebook reference while owning the store lifecycle.

    ``_resolve_notebook_id`` predates the command entry points and leaves its
    temporary ``NotebookStore`` open.  These commands are short-lived CLI
    operations, so the command layer must close the store on both the success
    and error paths instead of relying on process teardown.
    """
    if ref == "default":
        return "default"

    store = _notebook_store(user_dir)
    try:
        # ID matching takes precedence over name matching, matching the shared
        # resolver's semantics and avoiding a name/ID collision ambiguity.
        if store.exists(ref):
            return ref
        for notebook in store.all():
            if notebook.name == ref:
                return notebook.id
        raise EditError(f"notebook not found: {ref!r}(既非既存 id 也非既存 name;先 notebook-create)")
    finally:
        store.close()


def cmd_user_create(args: argparse.Namespace) -> int:
    uid = args.uid
    assert_safe_uid(uid)
    dd = data_dir()
    uf = users_file(dd)
    existing_users = load_users_from(uf, _passthrough_normalize) if uf.exists() else {}
    already = uid in existing_users or user_dir_for(dd, uid).exists()
    email_index = existing_users.get("_email_index")
    email_owner = email_index.get(args.email) if args.email and isinstance(email_index, dict) else None
    email_conflict = email_owner is not None and email_owner != uid

    plan = {
        "uid": uid,
        "provider": args.provider,
        "email": args.email,
        "already_exists": already,
        "email_owner": email_owner,
        "email_conflict": email_conflict,
        "creates_dir": str(user_dir_for(dd, uid)),
    }

    if already and not args.allow_existing:
        emit(
            {
                "mode": "error",
                "action": "user-create",
                "uid": uid,
                "plan": plan,
                "committed": False,
                "error": "user 已存在;確認後加 --allow-existing 才會 merge record",
            },
            json_mode=args.json,
        )
        return 1

    ctx = EditContext(data_dir=dd, uid=uid, commit=args.commit, json_mode=args.json, require_user=False)

    def apply_fn() -> dict[str, Any]:
        now = datetime.now(tz=UTC).isoformat()

        def mutate(users: dict[str, Any]) -> dict[str, Any]:
            # 鎖內重判存在性:L?? 的 early read 在 FileLock 外,兩個並發
            # user-create 可能都讀到「不存在」再雙雙進鎖覆寫。鎖內 re-check 關掉
            # 這個 TOCTOU —— 第二個進鎖者若發現已存在且未 --allow-existing 即中止。
            if uid in users and not args.allow_existing:
                raise EditError("user 已存在(鎖內偵測);加 --allow-existing 才會 merge record")
            idx = users.setdefault("_email_index", {})
            record = users.get(uid, {}) if isinstance(users.get(uid), dict) else {}
            record.setdefault("config", {})
            record["provider"] = args.provider
            if args.email:
                owner = idx.get(args.email)
                if owner is not None and owner != uid and not args.reassign_email:
                    raise EditError(
                        f"email {args.email!r} 已屬於 uid {owner!r};建立會讓該帳號下次登入被併到 {uid!r}。"
                        "確認要搶走才加 --reassign-email"
                    )
                record["email"] = args.email
                idx[args.email] = uid
            record.setdefault("created_at", now)
            record["last_login"] = now
            users[uid] = record
            return record

        record = _mutate_users(dd, mutate)
        user_dir_for(dd, uid).mkdir(parents=True, exist_ok=True)
        # 建好預設筆記本,讓帳號一登入就有 default notebook。
        notebook_store = _notebook_store(user_dir_for(dd, uid))
        try:
            notebook_store.ensure_default()
        finally:
            notebook_store.close()
        return {"record": record}

    def verify_fn() -> dict[str, Any]:
        users = load_users_from(uf, _passthrough_normalize)
        return {"ok": uid in users and user_dir_for(dd, uid).exists()}

    return ctx.run(action="user-create", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)


_logger = logging.getLogger(__name__)

# Same quarantine the in-app erasure uses (user_handlers._QUARANTINE_DIRNAME):
# the directory is renamed out of users/ before rmtree, so a partial removal
# never leaves a live path behind.
_QUARANTINE_DIRNAME = ".deleting"


def _sweep_quarantine(data_dir_path: Path) -> None:
    """Best-effort removal of leftovers from earlier failed removals."""
    root = data_dir_path / _QUARANTINE_DIRNAME
    if not root.is_dir():
        return
    for batch in root.iterdir():
        try:
            shutil.rmtree(batch)
        except OSError:
            _logger.exception("Failed to sweep quarantined user data %s", batch)


def _remove_user_dir_quarantined(data_dir_path: Path, uid: str) -> None:
    target = user_dir_for(data_dir_path, uid)
    if not target.exists():
        return
    batch = data_dir_path / _QUARANTINE_DIRNAME / uuid.uuid4().hex
    batch.mkdir(parents=True)
    quarantined = batch / uid
    target.rename(quarantined)
    shutil.rmtree(quarantined)
    batch.rmdir()


def _library_object_storage() -> tuple[str | None, Any]:
    """Library bucket and S3 client as the app wires them; ``(None, None)`` when local-only."""
    settings = load_settings()
    if not settings.library_bucket:
        return None, None
    from .routers.library import _library_s3_client

    return settings.library_bucket, _library_s3_client(settings)


def cmd_user_delete(args: argparse.Namespace) -> int:
    """刪除用戶:移除 user dir + users.json record + email/subscription index。

    可逆性沿用 EditContext:寫前自動 tar 備份 user_dir 到 data_dir/_ops_backups/
    (在 users/<uid>/ 之外,rmtree 吃不到),`ops-edit restore <uid>` 可還原。
    一個非對稱:還原只回復 record + email index,永不回復 _subscription_index,
    故 delete→restore 會遺失 App Store transaction-id → uid 的對應。
    """
    uid = args.uid
    assert_safe_uid(uid)
    dd = data_dir()
    uf = users_file(dd)
    users = load_users_from(uf, _passthrough_normalize) if uf.exists() else {}

    def _keys_pointing_at(bucket_name: str) -> list[str]:
        bucket = users.get(bucket_name)
        if not isinstance(bucket, dict):
            return []
        return [k for k, v in bucket.items() if v == uid]

    plan = {
        "uid": uid,
        "removes_dir": str(user_dir_for(dd, uid)),
        "had_record": isinstance(users.get(uid), dict),
        "email_index_keys": _keys_pointing_at("_email_index"),
        "subscription_index_keys": _keys_pointing_at("_subscription_index"),
        "restore_caveat": "restore 只回復 record + email index,不回復 _subscription_index",
    }

    ctx = EditContext(data_dir=dd, uid=uid, commit=args.commit, json_mode=args.json)

    def apply_fn() -> dict[str, Any]:
        def mutate(current: dict[str, Any]) -> dict[str, Any]:
            removed_record = current.pop(uid, None)
            dropped: dict[str, list[str]] = {}
            for bucket_name in ("_email_index", "_subscription_index"):
                bucket = current.get(bucket_name)
                if not isinstance(bucket, dict):
                    continue
                stale = [k for k, v in bucket.items() if v == uid]
                for key in stale:
                    bucket.pop(key, None)
                dropped[bucket_name] = stale
            # 與 app 內刪帳(_tombstone_accounts)一致:撤銷既發 JWT 並永久標記 terminated,
            # 否則 resolve_current_user 會放行舊 token 並重建 user dir,sign-in 也會清掉水位。
            revoked = current.get("_revoked_before")
            if not isinstance(revoked, dict):
                revoked = {}
            revoked[uid] = datetime.now(tz=UTC).isoformat()
            current["_revoked_before"] = revoked
            terminated = current.get("_terminated")
            terminated_ids = set(terminated) if isinstance(terminated, list) else set()
            terminated_ids.add(uid)
            current["_terminated"] = sorted(terminated_ids)
            # 與 app 內刪帳一致:撤銷外部 API key,否則重新登入後舊 key 仍可通過 authenticate_api_key。
            purge_external_api_keys(current, [uid])
            return {
                "removed_record": removed_record is not None,
                "dropped_index_keys": dropped,
            }

        # Remote assets go first, as in the in-app erasure: a failure here leaves
        # users.json and the directory untouched, so the command stays retryable.
        # Marked destructive before the first S3 delete, since that is irreversible.
        ctx.mark_destructive()
        _sweep_quarantine(dd)
        library_bucket, library_s3_client = _library_object_storage()
        delete_account_assets(dd, [uid], library_bucket=library_bucket, library_s3_client=library_s3_client)
        result = _mutate_users(dd, mutate)
        # Runs after the tombstone: a presigned PUT minted earlier can land after the ledger delete.
        sweep_account_prefixes([uid], library_bucket=library_bucket, library_s3_client=library_s3_client)
        _remove_user_dir_quarantined(dd, uid)
        return result

    def verify_fn() -> dict[str, Any]:
        current = load_users_from(uf, _passthrough_normalize) if uf.exists() else {}
        leftovers = [
            key
            for bucket_name in ("_email_index", "_subscription_index")
            if isinstance(current.get(bucket_name), dict)
            for key, value in current[bucket_name].items()
            if value == uid
        ]
        tombstoned = uid in current.get("_revoked_before", {}) and uid in current.get("_terminated", [])
        return {"ok": uid not in current and not user_dir_for(dd, uid).exists() and not leftovers and tombstoned}

    return ctx.run(action="user-delete", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)


def cmd_user_config_set(args: argparse.Namespace) -> int:
    """更新 users.json 內的 per-user config，供 marketing / mock surface 造景。"""
    dd = data_dir()
    ctx = EditContext(data_dir=dd, uid=args.uid, commit=args.commit, json_mode=args.json)
    now_epoch = datetime.now(tz=UTC).timestamp()
    updates: dict[str, Any] = {}

    if args.translation_source is not None or args.translation_target is not None:
        updates["translation"] = {
            "source_lang": args.translation_source,
            "target_lang": args.translation_target,
        }

    if args.paused_at is not None and args.review_clock != "paused":
        raise EditError("--paused-at 需搭配 --review-clock paused")
    if args.review_clock is not None:
        if args.paused_at is not None:
            if parse_datetime(args.paused_at) is None:
                raise EditError(f"--paused-at 必須是 ISO datetime 或 Unix timestamp:{args.paused_at!r}")
            paused_at = args.paused_at
        elif args.review_clock == "paused":
            paused_at = datetime.now(tz=UTC).isoformat()
        else:
            paused_at = None
        updates["review_clock"] = {
            "is_paused": args.review_clock == "paused",
            "paused_at": paused_at,
        }

    review_mode_fields = (
        args.review_mode,
        args.custom_initial_interval_hours,
        args.custom_remembered_multiplier,
        args.custom_forgot_multiplier,
        args.custom_minimum_interval_hours,
        args.custom_maximum_interval_hours,
    )
    if any(v is not None for v in review_mode_fields):
        updates["review_mode"] = {
            "mode": args.review_mode,
            "custom_initial_interval_hours": args.custom_initial_interval_hours,
            "custom_remembered_multiplier": args.custom_remembered_multiplier,
            "custom_forgot_multiplier": args.custom_forgot_multiplier,
            "custom_minimum_interval_hours": args.custom_minimum_interval_hours,
            "custom_maximum_interval_hours": args.custom_maximum_interval_hours,
        }

    resolved_nb_id = None
    if args.active_notebook is not None:
        resolved_nb_id = _resolve_notebook_id_for_command(ctx.user_dir, args.active_notebook)
        updates["vocab_ui"] = {"active_notebook_id": resolved_nb_id}

    if args.auto_link is not None:
        updates["auto_link"] = {"enabled": args.auto_link == "on"}

    if not updates:
        raise EditError("user-config-set 需至少一個 translation/review_clock/review_mode/vocab_ui/auto_link 相關旗標")

    plan = {"updates": updates}
    state: dict[str, Any] = {}

    def apply_fn() -> dict[str, Any]:
        def mutate(users: dict[str, Any]) -> dict[str, Any]:
            record = users.get(args.uid, {}) if isinstance(users.get(args.uid), dict) else {}
            config = record.get("config", {}) if isinstance(record.get("config"), dict) else {}

            if "translation" in updates:
                current = config.get("translation", {}) if isinstance(config.get("translation"), dict) else {}
                translation = TranslationLanguageConfig(
                    source_lang=updates["translation"]["source_lang"] or current.get("source_lang", "en"),
                    target_lang=updates["translation"]["target_lang"] or current.get("target_lang", "zh-Hant"),
                    updated_at=now_epoch,
                )
                config["translation"] = {
                    "source_lang": translation.source_lang,
                    "target_lang": translation.target_lang,
                    "updated_at": translation.updated_at,
                }

            if "review_clock" in updates:
                clock = ReviewClockConfig(
                    is_paused=updates["review_clock"]["is_paused"],
                    paused_at=updates["review_clock"]["paused_at"],
                    updated_at=now_epoch,
                )
                config["review_clock"] = {
                    "is_paused": clock.is_paused,
                    "paused_at": clock.paused_at,
                    "updated_at": clock.updated_at,
                }

            if "review_mode" in updates:
                current = config.get("review_mode", {}) if isinstance(config.get("review_mode"), dict) else {}
                mode = ReviewModeConfig(
                    mode=updates["review_mode"]["mode"] or current.get("mode", "relaxed"),
                    custom_initial_interval_hours=(
                        updates["review_mode"]["custom_initial_interval_hours"]
                        if updates["review_mode"]["custom_initial_interval_hours"] is not None
                        else current.get("custom_initial_interval_hours", 12)
                    ),
                    custom_remembered_multiplier=(
                        updates["review_mode"]["custom_remembered_multiplier"]
                        if updates["review_mode"]["custom_remembered_multiplier"] is not None
                        else current.get("custom_remembered_multiplier", 1.9)
                    ),
                    custom_forgot_multiplier=(
                        updates["review_mode"]["custom_forgot_multiplier"]
                        if updates["review_mode"]["custom_forgot_multiplier"] is not None
                        else current.get("custom_forgot_multiplier", 0.45)
                    ),
                    custom_minimum_interval_hours=(
                        updates["review_mode"]["custom_minimum_interval_hours"]
                        if updates["review_mode"]["custom_minimum_interval_hours"] is not None
                        else current.get("custom_minimum_interval_hours", 6)
                    ),
                    custom_maximum_interval_hours=(
                        updates["review_mode"]["custom_maximum_interval_hours"]
                        if updates["review_mode"]["custom_maximum_interval_hours"] is not None
                        else current.get("custom_maximum_interval_hours", 1440)
                    ),
                    updated_at=now_epoch,
                )
                config["review_mode"] = {
                    "mode": mode.mode,
                    "custom_initial_interval_hours": mode.custom_initial_interval_hours,
                    "custom_remembered_multiplier": mode.custom_remembered_multiplier,
                    "custom_forgot_multiplier": mode.custom_forgot_multiplier,
                    "custom_minimum_interval_hours": mode.custom_minimum_interval_hours,
                    "custom_maximum_interval_hours": mode.custom_maximum_interval_hours,
                    "updated_at": mode.updated_at,
                }

            if "vocab_ui" in updates:
                vocab_ui = VocabUIConfig(
                    active_notebook_id=updates["vocab_ui"]["active_notebook_id"],
                    updated_at=now_epoch,
                )
                config["vocab_ui"] = {
                    "active_notebook_id": vocab_ui.active_notebook_id,
                    "updated_at": vocab_ui.updated_at,
                }

            if "auto_link" in updates:
                auto_link = AutoLinkConfig(
                    enabled=updates["auto_link"]["enabled"],
                    updated_at=now_epoch,
                )
                config["auto_link"] = {
                    "enabled": auto_link.enabled,
                    "updated_at": auto_link.updated_at,
                }

            record["config"] = config
            users[args.uid] = record
            return config

        cfg = _mutate_users(dd, mutate)
        state["config"] = cfg
        return {"config": cfg}

    def verify_fn() -> dict[str, Any]:
        users = load_users_from(users_file(dd), _passthrough_normalize)
        record = users.get(args.uid, {}) if isinstance(users.get(args.uid), dict) else {}
        config = record.get("config", {}) if isinstance(record.get("config"), dict) else {}
        mismatches: list[str] = []
        if "translation" in updates:
            tr = config.get("translation", {}) if isinstance(config.get("translation"), dict) else {}
            exp = state.get("config", {}).get("translation", {})
            if tr.get("source_lang") != exp.get("source_lang"):
                mismatches.append("translation.source_lang")
            if tr.get("target_lang") != exp.get("target_lang"):
                mismatches.append("translation.target_lang")
        if "review_clock" in updates:
            rc = config.get("review_clock", {}) if isinstance(config.get("review_clock"), dict) else {}
            exp = state.get("config", {}).get("review_clock", {})
            if rc.get("is_paused") != exp.get("is_paused"):
                mismatches.append("review_clock.is_paused")
            if rc.get("paused_at") != exp.get("paused_at"):
                mismatches.append("review_clock.paused_at")
        if "review_mode" in updates:
            rm = config.get("review_mode", {}) if isinstance(config.get("review_mode"), dict) else {}
            for key, value in state.get("config", {}).get("review_mode", {}).items():
                if key == "updated_at":
                    continue
                if rm.get(key) != value:
                    mismatches.append(f"review_mode.{key}")
        if "vocab_ui" in updates:
            vu = config.get("vocab_ui", {}) if isinstance(config.get("vocab_ui"), dict) else {}
            if vu.get("active_notebook_id") != resolved_nb_id:
                mismatches.append("vocab_ui.active_notebook_id")
        if "auto_link" in updates:
            al = config.get("auto_link", {}) if isinstance(config.get("auto_link"), dict) else {}
            if al.get("enabled") != updates["auto_link"]["enabled"]:
                mismatches.append("auto_link.enabled")
        return {"ok": not mismatches, "mismatched": mismatches}

    return ctx.run(action="user-config-set", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)


def cmd_list_backups(args: argparse.Namespace) -> int:
    dd = data_dir()
    assert_safe_uid(args.uid)
    backups = list_user_backups(dd, args.uid)
    emit({"action": "list-backups", "uid": args.uid, "count": len(backups), "backups": backups}, json_mode=args.json)
    return 0


def cmd_link_list(args: argparse.Namespace) -> int:
    """列出某 notebook 的 active 連結(含 link id + 兩端 card content)。唯讀。

    讓 link-update / link-delete 不必手 cat graph JSON 查 link id(dogfood E F3)。
    與 list-backups 同性質 —— 輔助寫操作的唯讀查詢,不走 EditContext。
    """
    dd = data_dir()
    assert_safe_uid(args.uid)
    user_dir = user_dir_for(dd, args.uid)
    if not user_dir.exists():
        raise EditError(f"user not found: {args.uid}")
    nb_id = _resolve_notebook_id_for_command(user_dir, args.notebook)
    cards = _card_store(user_dir)
    graph = None
    try:
        graph = _graph_store(user_dir, nb_id)
        links = []
        for lk in graph.all_links():
            if lk.status != "active":
                continue
            fc = cards.get(lk.from_id)
            tc = cards.get(lk.to_id)
            links.append(
                {
                    "id": lk.id,
                    "from": fc.content if fc else lk.from_id,
                    "to": tc.content if tc else lk.to_id,
                    "kind": str(lk.kind),
                    "confidence": lk.confidence,
                    "reason": lk.reason,
                }
            )
        emit(
            {"action": "link-list", "uid": args.uid, "notebook_id": nb_id, "count": len(links), "links": links},
            json_mode=args.json,
        )
        return 0
    finally:
        if graph is not None:
            close_graph = getattr(graph, "close", None)
            if callable(close_graph):
                close_graph()
        cards.close()


def cmd_restore(args: argparse.Namespace) -> int:
    """從備份還原 user_dir。commit 前 EditContext 會先備份**當前**狀態,故可回退。"""
    dd = data_dir()
    ctx = EditContext(data_dir=dd, uid=args.uid, commit=args.commit, json_mode=args.json, require_user=False)
    backups = list_user_backups(dd, args.uid)
    if args.backup:
        backup_path = Path(args.backup)
        if not backup_path.exists():
            raise EditError(f"指定的備份不存在:{backup_path}")
    else:
        if not backups:
            raise EditError(f"無備份可還原(data_dir/_ops_backups/ 下無 {args.uid}__*.tar.gz)")
        backup_path = Path(backups[0]["path"])  # 最新

    with tarfile.open(backup_path) as tar:
        names = tar.getnames()
    # B1:備份 tar 頂層目錄必須 == uid。指向他人 uid 的備份會在 rmtree 掉 target
    # user_dir 後、把內容解壓到別的目錄,**靜默消滅** target(dogfood B1)。在動任何
    # 檔案前(rmtree 之前)擋掉 arcname 不符的備份。
    top_dirs = {n.split("/")[0] for n in names if n and not n.startswith("/")}
    if top_dirs != {args.uid}:
        raise EditError(
            f"備份 arcname 與 uid 不符:tar 頂層={sorted(top_dirs)},預期僅 "
            f"{{{args.uid!r}}};拒絕還原(避免消滅 target user_dir)"
        )
    db_files = [n for n in names if n.endswith(".db")]
    graph_files = [n for n in names if n.endswith(".json") and f"/{_USER_BACKUP_META_DIR}/" not in n]
    has_record_snapshot = f"{args.uid}/{_USER_BACKUP_META_DIR}/{_USER_BACKUP_RECORD}" in names
    plan = {
        "restore_from": str(backup_path),
        "target_dir": str(ctx.user_dir),
        "available_backups": len(backups),
        "total_members": len(names),
        "db_files": len(db_files),
        "graph_files": len(graph_files),
        "has_record_snapshot": has_record_snapshot,
        "sample_members": names[:10],
    }

    def apply_fn() -> dict[str, Any]:
        # EditContext 已在此之前備份了當前 user_dir(若存在),所以即使還原錯版本
        # 也能再 restore 回來。先清掉現狀再解壓,避免新舊檔殘留混雜。
        ctx.mark_destructive()
        if ctx.user_dir.exists():
            shutil.rmtree(ctx.user_dir)
        with tarfile.open(backup_path) as tar:
            record, email_index = _extract_user_backup_members(tar, args.uid, ctx.user_dir.parent)
        skipped = _restore_user_record_snapshot(dd, args.uid, record=record, email_index=email_index)
        return {
            "restored_from": str(backup_path),
            "restored_users_record": record is not None,
            "email_index_skipped": skipped,
        }

    def verify_fn() -> dict[str, Any]:
        # 放寬:早期快照(user-create 後、首次 card 操作前)只含 notebooks.db、無
        # cards.db,屬正常合法狀態,不該判失敗(dogfood A HIGH-1)。user_dir 在 + 至少
        # notebooks.db 在即視為成功還原。
        return {"ok": ctx.user_dir.exists() and (ctx.user_dir / "notebooks.db").exists()}

    return ctx.run(action="restore", plan=plan, apply_fn=apply_fn, verify_fn=verify_fn)
