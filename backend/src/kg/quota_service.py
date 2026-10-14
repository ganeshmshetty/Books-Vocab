"""Per-user daily quota tracking based on actual LLM token cost (USD).

Reuses the same token_usage.db from token_tracker (shared connection + lock).
Only exposes fraction (0.0–1.0) to clients — never absolute numbers.
"""

from __future__ import annotations

import asyncio
import itertools
import logging
import sqlite3
import threading
import time
from contextlib import asynccontextmanager, contextmanager
from datetime import UTC, datetime, timedelta
from typing import NamedTuple

from .exceptions import QuotaExceededError
from .llm.providers import REGISTRY, LLMProvider, provider_for
from .token_tracker import _get_conn, _lock
from .types import QuotaCheck, QuotaState

logger = logging.getLogger(__name__)

# Gemini reference pricing (USD per 1M tokens). Per-call cost is computed
# provider-aware in token_cost_usd(); these constants are the gemini baseline
# surfaced by the admin cost views.
_GEMINI = REGISTRY["gemini"]
INPUT_PER_M = _GEMINI.input_price_per_m
OUTPUT_PER_M = _GEMINI.output_price_per_m
EMBED_PER_M = _GEMINI.embed_price_per_m

# Defaults; overridden at runtime via configure_limits() from app startup.
# Canonical values live in KGSettings (settings.py); these are only fallbacks
# for the brief window before configure_limits() runs.
PRO_DAILY_LIMIT_USD: float = 0.30
FREE_DAILY_LIMIT_USD: float = 0.03
_ROLLING_WINDOW_SECONDS = 86400  # 24 h


def configure_limits(*, pro: float, free: float) -> None:
    """Called from app startup to sync limits with KGSettings."""
    global PRO_DAILY_LIMIT_USD, FREE_DAILY_LIMIT_USD
    PRO_DAILY_LIMIT_USD = pro
    FREE_DAILY_LIMIT_USD = free


def _daily_limit(is_pro: bool) -> float:
    return PRO_DAILY_LIMIT_USD if is_pro else FREE_DAILY_LIMIT_USD


def _pricing_provider(call_type: str, provider: str | None) -> LLMProvider:
    """Resolve the LLMProvider used to price a recorded row.

    A non-NULL ``provider`` name pins pricing to that provider — this is
    the per-row truth written since the token_usage schema gained the
    column. An unknown name (e.g. a since-removed provider still tagged on
    old rows) falls back to the call_type's current route rather than
    raising: a historical quota read must never blow up on stale data.
    A NULL ``provider`` (legacy rows predating the column) likewise prices
    at the current route — the documented best-effort for un-tagged history.
    """
    if provider:
        p = REGISTRY.get(provider)
        if p is not None:
            return p
        # A non-NULL name absent from REGISTRY is a data anomaly (a
        # since-removed provider, or a write bug). Pricing degrades to the
        # routed provider, but the anomaly itself must not stay silent.
        logger.warning(
            "token_usage row tagged unknown provider %r; pricing %s at routed provider",
            provider,
            call_type,
        )
    return provider_for(call_type)


def token_cost_usd(
    call_type: str,
    input_tokens: int,
    output_tokens: int,
    *,
    provider: str | None = None,
    cached_tokens: int = 0,
) -> float:
    """USD cost of a recorded call.

    ``cached_tokens`` (prompt-cache hits, a subset of ``input_tokens``) are
    priced at the provider's cache rate, clamped to ``[0, input_tokens]``;
    embeddings ignore it.

    When ``provider`` is given (the per-row value from token_usage), cost
    is priced at that provider's rates — so a Gemini→DeepSeek switch does
    NOT reprice history. When ``provider`` is None/unknown, falls back to
    the provider currently routed for ``call_type`` (legacy un-tagged rows).

    Raises ValueError if a NULL-provider call_type routes to an unknown
    provider — a deploy misconfiguration that fails loudly here, as it
    does at every call site.
    """
    p = _pricing_provider(call_type, provider)
    if call_type == "embed":
        return (input_tokens / 1_000_000) * p.embed_price_per_m
    cached = min(max(int(cached_tokens or 0), 0), input_tokens)
    return (
        ((input_tokens - cached) / 1_000_000) * p.input_price_per_m
        + (cached / 1_000_000) * p.cache_price_per_m
        + (output_tokens / 1_000_000) * p.output_price_per_m
    )


# Conservative per-call cost estimate (USD) held as an in-flight reservation
# while an LLM request is in progress. It only needs to be large enough that
# a burst of concurrent same-user calls can't all clear the gate before any
# real cost is recorded — it does NOT need to be accurate, because the real
# cost replaces it the instant `token_tracker.record()` lands. Chosen so a
# Free user ($0.03/day) admits ~2-3 in-flight calls, not an unbounded burst.
ESTIMATED_CALL_COST_USD: float = 0.012
ESTIMATED_EMBED_COST_USD: float = 0.0005


def estimate_call_cost(call_type: str) -> float:
    """Reservation estimate for a single LLM call of the given type."""
    return ESTIMATED_EMBED_COST_USD if call_type == "embed" else ESTIMATED_CALL_COST_USD


# ── In-flight reservation registry ───────────────────────────────────
#
# Why this exists: the quota gate (`check_quota`) is consulted BEFORE an
# LLM call, but `token_tracker.record()` only lands AFTER it completes.
# Concurrent same-user requests — multi-tab translate, or a single
# pipeline run fanning out 5-way enrich batches via ThreadPoolExecutor —
# all observe `used=0` and pass the gate before the first record() lands,
# producing unbounded over-spend (a Free user's $0.03/day budget is tiny).
#
# A reservation is an optimistic, in-memory estimate of an in-flight
# call's cost. The gate counts outstanding reservations on top of
# recorded usage; the reservation is released once the call finishes
# (its real cost is by then in token_usage.db). Purely process-local —
# no schema change, no new dependency. Cross-process workers still each
# enforce their own slice; the dominant concurrency (one Uvicorn worker,
# threadpool fan-out, asyncio tasks) is fully covered.
#
# DEPLOYMENT INVARIANT: correctness here depends on a single-worker
# deploy. With N workers each holds its own `_reservations`, so the
# effective over-spend ceiling becomes N × the real per-user limit.
# This is locked by Dockerfile's `--workers 1`; see also docs/sop/deploy.md.
# Scaling out requires moving reservations to shared storage (Redis/DB) first.

_reservations: dict[int, tuple[str, float]] = {}
_reservation_ids = itertools.count(1)
_reservation_lock = threading.Lock()
_reservation_version = 0


def _reserved_usd(user_id: str) -> float:
    """Sum of outstanding in-flight reservations for a user."""
    with _reservation_lock:
        return _reserved_usd_unlocked(user_id)


def _reserved_usd_unlocked(user_id: str) -> float:
    return sum(cost for uid, cost in _reservations.values() if uid == user_id)


def _admission_usage_snapshot(user_id: str) -> tuple[float, float]:
    """Return a conservative recorded/reserved snapshot for admission.

    SQLite reads must happen outside `_reservation_lock` to avoid lock-order
    inversion with token recording. If any reservation changes while the DB
    read is in progress, an in-flight call may have moved from "reserved" to
    "recorded"; retry so the recorded side catches up instead of under-counting
    both sides. A version check catches equal-sum swaps (A releases, B adds)
    that a plain reserved total comparison would miss.
    """
    while True:
        with _reservation_lock:
            version_before = _reservation_version
        recorded = _recorded_usd(user_id)
        with _reservation_lock:
            version_after = _reservation_version
            reserved_after = _reserved_usd_unlocked(user_id)
        if version_after == version_before:
            return recorded, reserved_after


# Max seconds a caller waits for same-user in-flight reservations to release
# before admission gives up with QuotaExceededError. Sized to a few LLM calls:
# only in-flight contention waits; real exhaustion (recorded >= limit, the same
# rule the pre-flight gate uses) raises immediately.
_ADMISSION_WAIT_SECONDS: float = 120.0
_ADMISSION_POLL_SECONDS: float = 0.05
_release_cond = threading.Condition(_reservation_lock)


def _exhausted_error(user_id: str, *, limit: float, recorded: float, reserved: float) -> QuotaExceededError:
    """429 built from the admission snapshot that rejected the call, with the
    same arithmetic as the pre-flight gate (`_quota_view`): fraction over
    recorded + reserved, reset from the recorded rows. Reads SQLite, so it must
    never be called while holding `_reservation_lock`."""
    remaining = max(limit - recorded - reserved, 0.0)
    fraction = round(remaining / limit, 4) if limit > 0 else 0.0
    reset = _reset_seconds(user_id, limit, recorded)
    return QuotaExceededError(
        reset,
        headers={"X-Quota-Fraction": str(fraction), "X-Quota-Reset": str(reset)},
    )


def _try_admit(user_id: str, estimated_usd: float, enforce: bool, is_pro: bool) -> tuple[int | None, int, float, float]:
    """One admission attempt: ``(rid, version, recorded, reserved)``; ``rid`` is
    None when same-user in-flight reservations block (caller may wait). Raises
    QuotaExceededError on real exhaustion (recorded >= limit)."""
    global _reservation_version
    rid = next(_reservation_ids)
    # Do SQLite reads outside `_reservation_lock`; `_admission_usage_snapshot`
    # retries if a concurrent reservation is released during the read.
    recorded, reserved = _admission_usage_snapshot(user_id) if enforce else (0.0, 0.0)
    limit = _daily_limit(is_pro)
    if enforce and recorded >= limit:
        raise _exhausted_error(user_id, limit=limit, recorded=recorded, reserved=reserved)
    with _reservation_lock:
        if enforce:
            reserved = max(reserved, _reserved_usd_unlocked(user_id))
            # Waiting is only justified by other in-flight calls. With none in
            # flight, a call under the recorded limit is admitted, matching the gate.
            if reserved > 0 and recorded + reserved + float(estimated_usd) > limit:
                return None, _reservation_version, recorded, reserved
        _reservations[rid] = (user_id, float(estimated_usd))
        _reservation_version += 1
        return rid, _reservation_version, recorded, reserved


def _release(rid: int) -> None:
    global _reservation_version
    with _reservation_lock:
        if _reservations.pop(rid, None) is not None:
            _reservation_version += 1
            _release_cond.notify_all()


@contextmanager
def reserve(user_id: str, estimated_usd: float, *, enforce: bool = False, is_pro: bool = False):
    """Hold an in-flight quota reservation for the duration of a call.

    Usage::

        with reserve(user["id"], estimate):
            result = llm_call()

    The reservation counts against the quota gate while held and is
    released on block exit — including when the body raises — so a
    failed handler never leaks budget.

    With ``enforce=True``, real exhaustion raises immediately; when only the
    same user's other in-flight reservations push the total over the limit,
    the caller blocks (bounded by ``_ADMISSION_WAIT_SECONDS``) until one
    releases. Blocking: for event-loop callers use :func:`areserve`.
    """
    if not user_id or estimated_usd <= 0:
        # Nothing to reserve; still yield so callers can wrap freely.
        yield
        return
    deadline = time.monotonic() + _ADMISSION_WAIT_SECONDS
    while True:
        rid, version, recorded, reserved = _try_admit(user_id, estimated_usd, enforce, is_pro)
        if rid is not None:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise _exhausted_error(user_id, limit=_daily_limit(is_pro), recorded=recorded, reserved=reserved)
        with _release_cond:
            _release_cond.wait_for(lambda v=version: _reservation_version != v, timeout=remaining)
    try:
        yield
    finally:
        _release(rid)


@asynccontextmanager
async def areserve(user_id: str, estimated_usd: float, *, enforce: bool = False, is_pro: bool = False):
    """Async twin of :func:`reserve`: in-flight contention polls with
    ``asyncio.sleep`` so the event loop is never blocked."""
    if not user_id or estimated_usd <= 0:
        yield
        return
    deadline = time.monotonic() + _ADMISSION_WAIT_SECONDS
    while True:
        rid, _version, recorded, reserved = _try_admit(user_id, estimated_usd, enforce, is_pro)
        if rid is not None:
            break
        if deadline - time.monotonic() <= 0:
            raise _exhausted_error(user_id, limit=_daily_limit(is_pro), recorded=recorded, reserved=reserved)
        await asyncio.sleep(_ADMISSION_POLL_SECONDS)
    try:
        yield
    finally:
        _release(rid)


def clear_reservations() -> None:
    """Drop all outstanding reservations (test isolation / shutdown)."""
    with _reservation_lock:
        global _reservation_version
        if _reservations:
            _reservations.clear()
            _reservation_version += 1
            _release_cond.notify_all()


def _row_cost(
    call_type: str,
    provider: str | None,
    total_in: int | None,
    total_out: int | None,
    total_cached: int | None = 0,
) -> float:
    """USD cost of one ``GROUP BY call_type, provider`` row, normalising NULL
    token sums (no rows in window) to 0."""
    return token_cost_usd(
        call_type,
        int(total_in or 0),
        int(total_out or 0),
        provider=provider,
        cached_tokens=int(total_cached or 0),
    )


def _cached_sum_col(conn: sqlite3.Connection) -> str:
    """Per-row cached_input_tokens, 0 for a legacy table lacking it."""
    from .ops_shared import column_expr

    return f"COALESCE({column_expr(conn, 'token_usage', 'cached_input_tokens')}, 0)"


def _cached_sum(conn: sqlite3.Connection) -> str:
    """``SUM`` expression over cached_input_tokens, 0 for a legacy table lacking it."""
    from .ops_shared import column_expr

    return f"SUM(COALESCE({column_expr(conn, 'token_usage', 'cached_input_tokens')}, 0))"


def _window_cutoff_iso() -> str:
    """ISO (UTC) lower bound of the rolling quota window: now − window seconds."""
    cutoff = datetime.now(UTC).timestamp() - _ROLLING_WINDOW_SECONDS
    return datetime.fromtimestamp(cutoff, tz=UTC).isoformat()


def _utc_instant_cutoff_bounds(cutoff_iso: str) -> tuple[str, str]:
    """Return an indexed candidate bound and an exact UTC-instant cutoff."""
    cutoff = datetime.fromisoformat(cutoff_iso)
    # The textual candidate bound must be based on the cutoff's UTC date. A
    # local-date bound can exclude an equivalent timestamp with a negative
    # offset before the local cutoff date, even when it is exactly on/after the
    # UTC instant boundary.
    cutoff_utc = cutoff if cutoff.tzinfo is None else cutoff.astimezone(UTC)
    candidate_bound = (cutoff_utc.date() - timedelta(days=1)).isoformat()
    return candidate_bound, cutoff_iso


def _utc_instant_predicate(column: str) -> str:
    """Build the SQL predicate for an ISO-8601 UTC instant column."""
    return f"{column} >= ? AND julianday({column}) >= julianday(?)"


def _recorded_usd(user_id: str) -> float:
    """Recorded USD cost (last 24 h), excluding in-flight reservations."""
    cutoff_iso = _window_cutoff_iso()
    candidate_bound, cutoff_iso = _utc_instant_cutoff_bounds(cutoff_iso)

    with _lock:
        conn = _get_conn()
        rows = conn.execute(
            f"""
            SELECT call_type, provider,
                   SUM(input_tokens) AS total_in, SUM(output_tokens) AS total_out,
                   {_cached_sum(conn)} AS total_cached
            FROM token_usage
            WHERE user_id = ? AND {_utc_instant_predicate("created_at")}
            GROUP BY call_type, provider
            """,
            (user_id, candidate_bound, cutoff_iso),
        ).fetchall()

    total = 0.0
    for call_type, provider, total_in, total_out, total_cached in rows:
        total += _row_cost(call_type, provider, total_in, total_out, total_cached)
    return total


def _used_usd(user_id: str) -> float:
    """Recorded USD cost (last 24 h) PLUS outstanding in-flight reservations.

    Folding reservations in here means every quota reader — `check_quota`,
    `check_and_get_quota`, `get_quota_state` — defends the pre-flight gap
    without each having to know about reservations.
    """
    recorded, reserved = _admission_usage_snapshot(user_id)
    return recorded + reserved


class _QuotaView(NamedTuple):
    limit: float
    used: float
    fraction: float


def _quota_view(user_id: str, *, is_pro: bool) -> _QuotaView:
    """Shared quota arithmetic for every reader: (limit, used, fraction).

    ``fraction`` = remaining / limit, guarded against a zero limit (an operator
    may set a tier limit to 0 via ``configure_limits``) so readers degrade to
    0.0 rather than dividing by zero.
    """
    limit = _daily_limit(is_pro)
    used = _used_usd(user_id)
    remaining = max(limit - used, 0.0)
    fraction = round(remaining / limit, 4) if limit > 0 else 0.0
    return _QuotaView(limit, used, fraction)


def _reset_seconds(user_id: str, limit: float, used: float) -> int:
    """Seconds until the rolling window frees quota for ``user_id``.

    Exceeded (``used >= limit``): the expiry of the earliest row whose ageing
    out brings usage under the limit. Otherwise: expiry of the oldest row (when
    usage starts recovering). Falls back to the full window with no usage, or
    when in-flight reservations alone keep the user at the limit.
    """
    cutoff_iso = _window_cutoff_iso()
    candidate_bound, cutoff_iso = _utc_instant_cutoff_bounds(cutoff_iso)
    with _lock:
        conn = _get_conn()
        rows = conn.execute(
            f"""
            SELECT created_at, call_type, provider, input_tokens, output_tokens,
                   {_cached_sum_col(conn)}
            FROM token_usage
            WHERE user_id = ? AND {_utc_instant_predicate("created_at")}
            ORDER BY julianday(created_at)
            """,
            (user_id, candidate_bound, cutoff_iso),
        ).fetchall()
    now = datetime.now(UTC).timestamp()
    freed = 0.0
    for created_at, call_type, provider, t_in, t_out, t_cached in rows:
        freed += _row_cost(call_type, provider, t_in, t_out, t_cached)
        if used >= limit and used - freed >= limit:
            continue
        created = datetime.fromisoformat(created_at)
        if created.tzinfo is None:
            created = created.replace(tzinfo=UTC)
        expiry = created.timestamp() + _ROLLING_WINDOW_SECONDS - now
        return max(0, min(_ROLLING_WINDOW_SECONDS, int(expiry + 0.999)))
    return _ROLLING_WINDOW_SECONDS


def get_quota_state(user_id: str, *, is_pro: bool = False) -> QuotaState:
    """Return {fraction, reset_seconds} where fraction = remaining / limit."""
    limit, used, fraction = _quota_view(user_id, is_pro=is_pro)
    return {"fraction": fraction, "reset_seconds": _reset_seconds(user_id, limit, used)}


def get_all_quota_usage(*, is_pro_by_user: dict[str, bool] | None = None) -> dict[str, dict]:
    """Return 24h quota usage for all users (admin only).

    ``is_pro_by_user`` maps user_id → Pro entitlement, so each user's
    ``limit_usd`` / ``fraction_used`` reflect their actual tier. A user
    absent from the map (or a None map) is priced at the Free limit — the
    conservative default; previously every user was scored against the Pro
    limit, which 10×-underestimated Free users' ``fraction_used``.
    """
    pro_by_user = is_pro_by_user or {}
    cutoff_iso = _window_cutoff_iso()
    candidate_bound, cutoff_iso = _utc_instant_cutoff_bounds(cutoff_iso)

    with _lock:
        conn = _get_conn()
        rows = conn.execute(
            f"""
            SELECT user_id, call_type, provider,
                   COUNT(*) AS cnt,
                   SUM(input_tokens) AS total_in,
                   SUM(output_tokens) AS total_out,
                   {_cached_sum(conn)} AS total_cached
            FROM token_usage
            WHERE {_utc_instant_predicate("created_at")}
            GROUP BY user_id, call_type, provider
            """,
            (candidate_bound, cutoff_iso),
        ).fetchall()

    result: dict[str, dict] = {}
    # call_type is split across providers by GROUP BY; fold each provider's
    # slice back into one per-call_type bucket, priced at its own provider.
    for user_id, call_type, provider, cnt, total_in, total_out, total_cached in rows:
        if user_id not in result:
            limit = _daily_limit(pro_by_user.get(user_id, False))
            result[user_id] = {"used_usd": 0.0, "limit_usd": limit, "calls": {}}
        cost = _row_cost(call_type, provider, total_in, total_out, total_cached)
        result[user_id]["used_usd"] += cost
        bucket = result[user_id]["calls"].setdefault(call_type, {"count": 0, "cost_usd": 0.0})
        bucket["count"] += cnt
        bucket["cost_usd"] = round(bucket["cost_usd"] + cost, 6)

    for uid in result:
        used = result[uid]["used_usd"]
        limit = result[uid]["limit_usd"]
        result[uid]["used_usd"] = round(used, 6)
        # limit is now tier-dependent (runtime-configurable via configure_limits);
        # guard the divisor in case an operator sets a limit to 0.
        result[uid]["fraction_used"] = round(used / limit, 4) if limit > 0 else 0.0

    return result


def get_user_usage_range(user_id: str, *, since_iso: str | None = None) -> dict:
    """Return per-type usage (calls + cost + tokens) for a user, filtered by time range.

    If `since_iso` is None, returns all-time usage. Used by admin UI for range filter.
    """
    where = "WHERE user_id = ?"
    params: list = [user_id]
    if since_iso is not None:
        candidate_bound, since_iso = _utc_instant_cutoff_bounds(since_iso)
        where += f" AND {_utc_instant_predicate('created_at')}"
        params.extend([candidate_bound, since_iso])

    with _lock:
        conn = _get_conn()
        rows = conn.execute(
            f"""
            SELECT call_type, provider,
                   COUNT(*)          AS cnt,
                   SUM(input_tokens) AS total_in,
                   SUM(output_tokens) AS total_out,
                   {_cached_sum(conn)} AS total_cached
            FROM token_usage
            {where}
            GROUP BY call_type, provider
            """,
            params,
        ).fetchall()

    calls: dict[str, dict] = {}
    tokens: dict[str, dict] = {}
    total_cost = 0.0
    total_calls = 0
    # GROUP BY splits each call_type per provider; fold the slices back into
    # one per-call_type bucket, each priced at its own provider's rate.
    for call_type, provider, cnt, total_in, total_out, total_cached in rows:
        ti = int(total_in or 0)
        to = int(total_out or 0)
        cost = _row_cost(call_type, provider, ti, to, total_cached)
        cbucket = calls.setdefault(call_type, {"count": 0, "cost_usd": 0.0})
        cbucket["count"] += int(cnt)
        cbucket["cost_usd"] = round(cbucket["cost_usd"] + cost, 6)
        tbucket = tokens.setdefault(call_type, {"input_tokens": 0, "output_tokens": 0})
        tbucket["input_tokens"] += ti
        tbucket["output_tokens"] += to
        total_cost += cost
        total_calls += int(cnt)

    return {
        "calls": calls,
        "tokens": tokens,
        "total_calls": total_calls,
        "total_cost_usd": round(total_cost, 6),
    }


def check_quota(user_id: str, call_type: str, *, is_pro: bool = False) -> QuotaCheck:
    """Pre-flight check before a translate call.

    Returns {exceeded: bool, fraction, reset_seconds}. Thin alias over
    ``check_and_get_quota`` — kept as a public symbol for callers that read
    the intent ("just a gate check"); both compute identically.
    """
    return check_and_get_quota(user_id, call_type, is_pro=is_pro)


def check_and_get_quota(user_id: str, call_type: str, *, is_pro: bool = False) -> QuotaCheck:
    """Pre-flight check + state in one query.

    ``exceeded`` uses the admission rule (`_try_admit`): only recorded usage at
    or over the limit is real exhaustion. In-flight reservations are contention,
    which `reserve`/`areserve` wait out, so they must not trip the gate (#3809).
    ``fraction`` still reports the budget left after in-flight reservations.
    """
    limit = _daily_limit(is_pro)
    recorded, reserved = _admission_usage_snapshot(user_id)
    remaining = max(limit - recorded - reserved, 0.0)
    fraction = round(remaining / limit, 4) if limit > 0 else 0.0
    return {
        "exceeded": recorded >= limit,
        "fraction": fraction,
        "reset_seconds": _reset_seconds(user_id, limit, recorded),
    }
