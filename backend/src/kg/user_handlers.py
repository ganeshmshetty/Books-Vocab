from __future__ import annotations

import contextlib
import logging
import math
import re
import shutil
import sqlite3
import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from logging import Logger
from pathlib import Path
from typing import TYPE_CHECKING, Any, Protocol

from fastapi import HTTPException

from . import (
    judge_log,
    llm_error_log,
    pipeline_log,
    podcast_progress,
    token_tracker,
    translate_log,
    vocab_add_link_operation,
)
from .account_erasure import (
    ObjectStorageClient,
    _asset_object_keys,
    delete_account_assets,
    sweep_account_prefixes,
)
from .api_models import (
    AutoLinkConfig,
    DeleteAccountResponse,
    EntitlementsResponse,
    HealthResponse,
    ReviewClockConfig,
    ReviewModeConfig,
    TranslationLanguageConfig,
    UserConfigRequest,
    UserConfigResponse,
    UserProfileResponse,
    VocabUIConfig,
)
from .ops_cli_shared import _normalize_persisted_bool
from .sentry_init import capture_handled
from .service_factories import evict_user_store_cache
from .types import StoredUserRecord, UserRecord, UsersPayload
from .users_lock import users_file_lock

if TYPE_CHECKING:
    from .shared_decks.store import SharedDeckStore

_logger = logging.getLogger(__name__)


class CardStore(Protocol):
    def count(self) -> int: ...


class GraphStore(Protocol):
    def link_count(self) -> int: ...

    def candidate_count(self) -> int: ...


class CardStoreFactory(Protocol):
    def __call__(self, user_dir: Path) -> CardStore: ...


class GraphStoreFactory(Protocol):
    def __call__(self, user_dir: Path) -> GraphStore: ...


_ACTIVE_NOTEBOOK_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def _finite_or_default(value: Any, default: float) -> float:
    """Legacy users.json rows may hold NaN/Infinity/garbage; never echo them to clients."""
    if isinstance(value, bool):
        return default
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if math.isfinite(number) else default


def _valid_paused_at(value: Any) -> str | None:
    if not isinstance(value, str) or len(value) > 64:
        return None
    try:
        datetime.fromisoformat(value)
    except ValueError:
        return None
    return value


def _valid_active_notebook_id(value: Any) -> str:
    return value if isinstance(value, str) and _ACTIVE_NOTEBOOK_ID_RE.fullmatch(value) else "default"


def _build_user_config_response(config: dict[str, Any]) -> UserConfigResponse:
    translation_data = config.get("translation")
    if isinstance(translation_data, dict):
        translation = TranslationLanguageConfig(
            source_lang=translation_data.get("source_lang", "en"),
            target_lang=translation_data.get("target_lang", "zh-Hant"),
            updated_at=translation_data.get("updated_at"),
        )
    else:
        translation = TranslationLanguageConfig()

    clock_data = config.get("review_clock")
    if isinstance(clock_data, dict):
        review_clock = ReviewClockConfig(
            is_paused=_normalize_persisted_bool(clock_data.get("is_paused"), default=False),
            paused_at=_valid_paused_at(clock_data.get("paused_at")),
            updated_at=clock_data.get("updated_at"),
        )
    else:
        review_clock = ReviewClockConfig()

    mode_data = config.get("review_mode")
    if isinstance(mode_data, dict):
        review_mode = ReviewModeConfig(
            mode=mode_data.get("mode", "relaxed"),
            custom_initial_interval_hours=_finite_or_default(mode_data.get("custom_initial_interval_hours"), 12),
            custom_remembered_multiplier=_finite_or_default(mode_data.get("custom_remembered_multiplier"), 1.9),
            custom_forgot_multiplier=_finite_or_default(mode_data.get("custom_forgot_multiplier"), 0.45),
            custom_minimum_interval_hours=_finite_or_default(mode_data.get("custom_minimum_interval_hours"), 6),
            custom_maximum_interval_hours=_finite_or_default(mode_data.get("custom_maximum_interval_hours"), 1440),
            updated_at=mode_data.get("updated_at"),
        )
    else:
        review_mode = ReviewModeConfig()

    vu_data = config.get("vocab_ui")
    if isinstance(vu_data, dict):
        vocab_ui = VocabUIConfig(
            active_notebook_id=_valid_active_notebook_id(vu_data.get("active_notebook_id")),
            updated_at=vu_data.get("updated_at"),
        )
    else:
        vocab_ui = VocabUIConfig()

    al_data = config.get("auto_link")
    if isinstance(al_data, dict):
        auto_link = AutoLinkConfig(
            enabled=_normalize_persisted_bool(al_data.get("enabled"), default=True),
            updated_at=al_data.get("updated_at"),
        )
    else:
        auto_link = AutoLinkConfig()

    return UserConfigResponse(
        translation=translation,
        review_clock=review_clock,
        review_mode=review_mode,
        vocab_ui=vocab_ui,
        auto_link=auto_link,
    )


def _should_apply_user_config_group(config: dict[str, Any], group: str, incoming_updated_at: float | None) -> bool:
    """Apply timestamped group writes only when they move the group forward.

    Requests without a timestamp retain the legacy overwrite behavior for
    backwards compatibility with clients that predate the LWW field.
    """
    if incoming_updated_at is None:
        return True
    existing = config.get(group)
    if not isinstance(existing, dict):
        return True
    existing_updated_at = existing.get("updated_at")
    if not isinstance(existing_updated_at, (int, float)) or isinstance(existing_updated_at, bool):
        return True
    return incoming_updated_at > existing_updated_at


def _merge_user_config(config: dict[str, Any], req: UserConfigRequest) -> None:
    # Translation config（source+target 偏好 + 單一 group updated_at 整組 LWW）。
    # 用 `is not None` 對齊其他 group（有送=更新, None=不動既有）；統一語意並消除
    # 「未來 model 變得可 falsy 就誤略過」的隱患（現 model 全 default 不會 falsy）。
    if req.translation is not None and _should_apply_user_config_group(
        config, "translation", req.translation.updated_at
    ):
        config["translation"] = {
            "source_lang": req.translation.source_lang,
            "target_lang": req.translation.target_lang,
            "updated_at": req.translation.updated_at,
        }
    # Review clock (pause state). 複合原子;resume 時 paused_at 已由 ReviewClockConfig
    # validator 正規化為 None。只在 client 有送 review_clock 時更新(None = 不動既有)。
    if req.review_clock is not None and _should_apply_user_config_group(
        config, "review_clock", req.review_clock.updated_at
    ):
        rc = req.review_clock
        config["review_clock"] = {
            "is_paused": rc.is_paused,
            "paused_at": rc.paused_at,
            "updated_at": rc.updated_at,
        }
    # Review mode + 自訂 SRS 參數。複合原子(mode + 5 custom_* 共用單一 updated_at);
    # 非法 mode 已由 ReviewModeConfig validator 正規化。只在 client 有送時更新(None = 不動既有)。
    if req.review_mode is not None and _should_apply_user_config_group(
        config, "review_mode", req.review_mode.updated_at
    ):
        rm = req.review_mode
        config["review_mode"] = {
            "mode": rm.mode,
            "custom_initial_interval_hours": rm.custom_initial_interval_hours,
            "custom_remembered_multiplier": rm.custom_remembered_multiplier,
            "custom_forgot_multiplier": rm.custom_forgot_multiplier,
            "custom_minimum_interval_hours": rm.custom_minimum_interval_hours,
            "custom_maximum_interval_hours": rm.custom_maximum_interval_hours,
            "updated_at": rm.updated_at,
        }
    # Vocab UI(目前僅全域 active notebook 游標)。決定新選詞歸屬;單一 updated_at 驅動
    # 整組跨裝置 LWW。只在 client 有送時更新(None = 不動既有);stale id 由各 client
    # reconcile(後端此階段 passthrough,不驗 notebook 存在性,與其他 group 一致)。
    if req.vocab_ui is not None and _should_apply_user_config_group(config, "vocab_ui", req.vocab_ui.updated_at):
        vu = req.vocab_ui
        config["vocab_ui"] = {
            "active_notebook_id": vu.active_notebook_id,
            "updated_at": vu.updated_at,
        }
    # Auto-link(judge pipeline 自動連結)開關。單一 updated_at 驅動整組 LWW。
    # 只在 client 有送時更新(None = 不動既有);缺省讀取端 fallback enabled=True。
    if req.auto_link is not None and _should_apply_user_config_group(config, "auto_link", req.auto_link.updated_at):
        config["auto_link"] = {
            "enabled": req.auto_link.enabled,
            "updated_at": req.auto_link.updated_at,
        }


def get_user_config_response(user: UserRecord) -> UserConfigResponse:
    return _build_user_config_response(user["config"])


def get_user_profile_response(user: UserRecord) -> UserProfileResponse:
    """Read identity (displayName/email/provider) from the stored user record.

    `provider`/`email` are persisted at login (auth_service.resolve_and_link_user).
    `displayName` prefers an explicit `display_name`, then the email local-part,
    else None — never fabricated from the opaque user id.
    """
    record = user.get("record") or {}
    record = record if isinstance(record, dict) else {}

    email = record.get("email")
    provider = record.get("provider")

    display_name = record.get("display_name")
    if not display_name:
        display_name = email.split("@", 1)[0] if isinstance(email, str) and "@" in email else None

    return UserProfileResponse(
        displayName=display_name,
        email=email,
        provider=provider,
    )


def get_user_entitlements_response(
    user: UserRecord,
    *,
    build_entitlements_response: Callable[[StoredUserRecord | None], EntitlementsResponse],
) -> EntitlementsResponse:
    return build_entitlements_response(user.get("record"))


def update_user_config_response(
    req: UserConfigRequest,
    user: UserRecord,
    *,
    users_lock_file: Path,
    load_users: Callable[[], UsersPayload],
    save_users: Callable[[UsersPayload], None],
) -> UserConfigResponse:
    with users_file_lock(users_lock_file):
        users = load_users()
        user_id = user["id"]

        if user_id not in users:
            terminated = users.get("_terminated")
            if isinstance(terminated, list) and user_id in terminated:
                raise HTTPException(
                    status_code=401,
                    detail="Account was deleted. Please sign in again.",
                    headers={"WWW-Authenticate": "Bearer"},
                )
            users[user_id] = {}

        if "config" not in users[user_id]:
            users[user_id]["config"] = {}

        _merge_user_config(users[user_id]["config"], req)

        save_users(users)

    return _build_user_config_response(users[user_id]["config"])


# Remote assets are deleted outside the users lock, so a concurrent sign-in may
# link one more identity meanwhile; each pass erases what it found and re-checks.
_MAX_ERASURE_PASSES = 4


def _tombstone_accounts(
    users: UsersPayload,
    ids_to_delete: list[str],
    *,
    purge_external_api_keys: Callable[[UsersPayload, list[str]], None] | None,
) -> None:
    """Revoke, permanently terminate and remove ``ids_to_delete`` in place,
    dropping every email / subscription index entry that maps to them."""
    # Stamped at commit time (under the lock) so tokens issued while remote
    # assets were being deleted are revoked too.
    now_iso = datetime.now(tz=UTC).isoformat()
    revoked_before = users.get("_revoked_before")
    if not isinstance(revoked_before, dict):
        revoked_before = {}
    for uid in ids_to_delete:
        revoked_before[uid] = now_iso
    users["_revoked_before"] = revoked_before

    # Mark every purged id as permanently terminated. This makes the
    # revocation watermark irreversible: a later login (even with the
    # same sub, or the same email via another provider) must NOT be able
    # to clear `_revoked_before` for these ids — see resolve_and_link_user.
    terminated = users.get("_terminated")
    terminated_ids = set(terminated) if isinstance(terminated, list) else set()
    terminated_ids.update(ids_to_delete)
    users["_terminated"] = sorted(terminated_ids)

    # Scrub both identity indexes, like the operator delete (cmd_user_delete):
    # a surviving `_subscription_index` entry would let a later App Store
    # notification re-create the erased record through the snapshot writer.
    for bucket_name in ("_email_index", "_subscription_index"):
        bucket = users.get(bucket_name)
        if not isinstance(bucket, dict):
            continue
        stale_keys = [key for key, mapped_uid in bucket.items() if mapped_uid in ids_to_delete]
        for key in stale_keys:
            bucket.pop(key, None)
        if not bucket:
            users.pop(bucket_name, None)

    for uid in ids_to_delete:
        users.pop(uid, None)

    if purge_external_api_keys is not None:
        purge_external_api_keys(users, ids_to_delete)


# Directories whose rmtree failed are parked here (outside ``users/``), so a
# same-sub re-login's ``mkdir(exist_ok=True)`` can never re-attach erased data.
_QUARANTINE_DIRNAME = ".deleting"


def _sweep_quarantine(data_dir: Path, logger: Logger) -> None:
    """Best-effort removal of leftovers from earlier failed erasures."""
    root = data_dir / _QUARANTINE_DIRNAME
    if not root.is_dir():
        return
    for batch in root.iterdir():
        try:
            shutil.rmtree(batch)
        except OSError:
            logger.exception("Failed to sweep quarantined user data %s", batch)


def _remove_user_dir(data_dir: Path, uid: str) -> bool:
    """Remove ``users/<uid>``; return whether a directory existed.

    The directory is first renamed into the quarantine, so even if the rmtree
    fails nothing remains at the live path.
    """
    user_dir = data_dir / "users" / uid
    if not user_dir.exists():
        return False
    batch = data_dir / _QUARANTINE_DIRNAME / uuid.uuid4().hex
    batch.mkdir(parents=True)
    quarantined = batch / uid
    user_dir.rename(quarantined)
    shutil.rmtree(quarantined)
    batch.rmdir()
    return True


def delete_user_account_response(
    user: UserRecord,
    *,
    users_lock_file: Path,
    load_users: Callable[[], UsersPayload],
    save_users: Callable[[UsersPayload], None],
    collect_account_ids_for_deletion: Callable[[UsersPayload, str], tuple[str, list[str]]],
    data_dir: Path,
    logger: Logger,
    library_bucket: str | None = None,
    library_s3_client: ObjectStorageClient | None = None,
    purge_external_api_keys: Callable[[UsersPayload, list[str]], None] | None = None,
    shared_deck_store: SharedDeckStore | None = None,
) -> DeleteAccountResponse:
    user_id = user["id"]
    erased: set[str] = set()
    erased_keys: set[str] = set()
    _sweep_quarantine(data_dir, logger)

    for _ in range(_MAX_ERASURE_PASSES):
        with users_file_lock(users_lock_file):
            users = load_users()
            canonical_id, ids_to_delete = collect_account_ids_for_deletion(users, user_id)
            pending = [uid for uid in ids_to_delete if uid not in erased]
            # Re-read the key ledger under the lock: an upload registered while
            # the previous pass was talking to object storage (#2702) must be
            # erased before the tombstone revokes the token.
            new_keys = set(_asset_object_keys(data_dir, ids_to_delete)) - erased_keys if library_bucket else set()
            if not pending and not new_keys:
                podcast_progress.delete_for_users(ids_to_delete)
                vocab_add_link_operation.delete_for_users(ids_to_delete)
                translate_log.delete_for_users(ids_to_delete)
                judge_log.delete_for_users(ids_to_delete)
                llm_error_log.delete_for_users(ids_to_delete)
                token_tracker.delete_for_users(ids_to_delete)
                pipeline_log.delete_for_users(ids_to_delete)
                if shared_deck_store is not None:
                    shared_deck_store.delete_copy_logs_for(ids_to_delete)
                _tombstone_accounts(users, ids_to_delete, purge_external_api_keys=purge_external_api_keys)
                save_users(users)
                # users.json is now tombstoned: drop the cached stores at once
                # so a same-sub re-login during the rmtree below cannot be
                # handed the pre-deletion GraphStore / SQLite handles.
                for uid in ids_to_delete:
                    evict_user_store_cache(data_dir / "users" / uid)
                break
        # One network round trip per remote asset: never hold the shared users
        # lock (every login / config / billing write) across them (#2060). A
        # failure here leaves users.json and the directories untouched, so the
        # request stays retryable; the next pass re-reads the linked ids.
        erased_keys.update(
            delete_account_assets(
                data_dir,
                ids_to_delete,
                library_bucket=library_bucket,
                library_s3_client=library_s3_client,
            )
        )
        erased.update(ids_to_delete)
    else:
        raise HTTPException(status_code=409, detail="Account changed during deletion; please retry")

    deleted_dirs: list[str] = []
    failed_uids: list[str] = []
    try:
        # users.json is already tombstoned, so a failure on one directory must
        # not strand the remaining linked ids: remove what can be removed, then
        # report the failures.
        for uid in ids_to_delete:
            try:
                if _remove_user_dir(data_dir, uid):
                    deleted_dirs.append(uid)
            except OSError:
                logger.exception("Failed to delete user directory for %s", uid)
                failed_uids.append(uid)
    finally:
        # Evict again after the files are gone (a store reopened during the
        # rmtree window would otherwise outlive its unlinked files), for every
        # linked id even if a failure interrupted the loop.
        for uid in ids_to_delete:
            evict_user_store_cache(data_dir / "users" / uid)
    # The tombstone is durable and registration is now rejected under the lock
    # (#2702), but a presigned PUT minted earlier can still land after the
    # ledger-driven delete. Sweep the whole account prefix, outside the lock and
    # after local removal (#2929), so a stalled S3 call cannot delay it. Best-
    # effort: the client cannot retry (its token is revoked), so a failure is
    # logged and reported to Sentry, which is the operator alert path. A PUT
    # completing after this sweep is bounded by the URL TTL (one hour, see
    # docs/sop/architecture.md), not by this request.
    try:
        sweep_account_prefixes(ids_to_delete, library_bucket=library_bucket, library_s3_client=library_s3_client)
    except Exception as exc:
        capture_handled(exc, context="account_erasure.prefix_sweep")
        logger.exception("Library prefix sweep failed after account tombstone for %s", ids_to_delete)
    if failed_uids:
        raise HTTPException(status_code=500, detail=f"Failed to remove user data for {', '.join(failed_uids)}")

    logger.warning(
        "Account deletion: uid=%s canonical=%s ids=%s dirs=%s",
        user_id,
        canonical_id,
        ids_to_delete,
        deleted_dirs,
    )

    return DeleteAccountResponse(
        deleted_user_id=canonical_id,
        linked_ids=[uid for uid in ids_to_delete if uid != canonical_id],
        deleted_dirs=deleted_dirs,
    )


def health_response(
    user: dict[str, Any],
    *,
    card_store_factory: CardStoreFactory,
    graph_store_factory: GraphStoreFactory,
) -> HealthResponse:
    user_dir: Path = user["dir"]
    cards = card_store_factory(user_dir)
    graph = graph_store_factory(user_dir)

    cards_path = user_dir / "cards.db"
    last_mod = None
    if cards_path.exists():
        ts = cards_path.stat().st_mtime
        last_mod = datetime.fromtimestamp(ts, tz=UTC).isoformat()

    db_ok = True
    card_count = 0
    try:
        card_count = cards.count()
    except (OSError, sqlite3.DatabaseError) as exc:
        _logger.warning("Health check failed for user %s: %s", user.get("uid"), exc)
        db_ok = False

    data_dir_exists = user_dir.exists()

    disk_free_mb: int | None = None
    with contextlib.suppress(OSError):
        disk_free_mb = shutil.disk_usage(user_dir).free // (1024 * 1024)

    return HealthResponse(
        status="ok" if db_ok else "degraded",
        cards=card_count,
        links=graph.link_count(),
        pendingCandidates=graph.candidate_count(),
        lastModified=last_mod,
        db_ok=db_ok,
        disk_free_mb=disk_free_mb,
        data_dir_exists=data_dir_exists,
    )
