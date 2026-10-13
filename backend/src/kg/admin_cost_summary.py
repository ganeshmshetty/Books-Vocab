"""AI cost / token summary for a single user (admin observability).

Aggregates ``token_usage.db`` rows into three orthogonal breakdowns —
``by_service`` / ``by_model`` / ``by_call_type`` — plus totals and the
pricing assumptions used to compute USD cost. Time-bounded by ``range``
(default ``month`` = current calendar month, UTC).

Read-only. Never writes.

Assumptions (documented in response under ``pricing_assumptions``):
  * ``by_model`` keys on each row's recorded ``model`` column. Rows
    predating that column (NULL model) fall back to a name inferred
    from ``call_type``:
      - ``embed`` → ``gemini-embedding-2-preview``
      - everything else → ``gemini-2.5-flash-lite``
  * Cost-per-token is priced per row from the recorded ``provider``
    via :func:`kg.quota_service.token_cost_usd`; a NULL ``provider``
    (legacy rows) prices at the call_type's currently-routed provider.
  * Service grouping (judge / translate / pipeline / other) is by
    ``call_type`` prefix — see ``_SERVICE_MAP``.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

# call_type → service bucket.
# ``judge_manual`` is the current manual-link-judge call_type; ``manual_link_judge``
# is its pre-rename predecessor — historic ``token_usage`` rows still carry the
# old string, so both must map into the judge bucket or past cost attribution
# silently drops to ``other``.
_SERVICE_MAP: dict[str, str] = {
    "judge": "judge",
    "judge_manual": "judge",
    "manual_link_judge": "judge",
    "translate_quick": "translate",
    "translate_phrase": "translate",
    "translate_explain": "translate",
    "enrich": "pipeline",
    "embed": "pipeline",
}

# call_type → inferred model name
_MODEL_MAP: dict[str, str] = {
    "embed": "gemini-embedding-2-preview",
}
_DEFAULT_MODEL = "gemini-2.5-flash-lite"


VALID_RANGES = ("24h", "7d", "30d", "month", "all")


def since_iso(range_: str) -> str | None:
    """Resolve range token → ISO cutoff (UTC) or ``None`` for all-time.

    ``month`` = start of current UTC calendar month at 00:00:00.
    """
    now = datetime.now(UTC)
    if range_ == "24h":
        return datetime.fromtimestamp(now.timestamp() - 86400, tz=UTC).isoformat()
    if range_ == "7d":
        return datetime.fromtimestamp(now.timestamp() - 7 * 86400, tz=UTC).isoformat()
    if range_ == "30d":
        return datetime.fromtimestamp(now.timestamp() - 30 * 86400, tz=UTC).isoformat()
    if range_ == "month":
        start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        return start.isoformat()
    if range_ == "all":
        return None
    raise ValueError(f"Invalid range: {range_}")


def service_for(call_type: str) -> str:
    return _SERVICE_MAP.get(call_type, "other")


def model_for(call_type: str) -> str:
    return _MODEL_MAP.get(call_type, _DEFAULT_MODEL)


def _oldest_retained_at(conn: Any) -> str | None:
    """Earliest ``token_usage.created_at`` still on disk (the prune horizon), or None if empty."""
    row = conn.execute("SELECT MIN(created_at) FROM token_usage").fetchone()
    return row[0] if row else None


def query_cost_rows(conn: Any, *, user_id: str | None = None, since: str | None = None) -> list[tuple]:
    """Connection-agnostic:對 ``token_usage`` 跑唯一的 cost 聚合 query。

    cost-by-call_type 業務語意的**單一真相源** —— admin(RW conn)與 ops
    (``connect_ro``)都呼叫本函式,各自只負責「怎麼連」,不重寫「查什麼」。
    回傳 ``(uid, call_type, provider, model, cnt, total_in, total_out, total_cached)``;
    ``user_id=None`` 表跨用戶(供 cost-overview)。``provider``/``model`` 欄缺的
    legacy DB 以 NULL 切片回傳,由 :func:`fold_user_summary` fallback 定價/推斷。
    """
    from .ops_shared import column_expr

    pcol = column_expr(conn, "token_usage", "provider")
    mcol = column_expr(conn, "token_usage", "model")
    ccol = column_expr(conn, "token_usage", "cached_input_tokens")
    # 跨用戶(user_id=None)才投影領頭 uid 欄供 cost-overview 依 row[0] 分組;
    # 單用戶不需要 —— fold_user_summary 只讀 row[-7:],省掉 uid 欄即免去 echo
    # 一個沒人讀的值與位置敏感的雙重 param 綁定。
    uid_select = "user_id AS uid, " if user_id is None else ""
    sql = (
        f"SELECT {uid_select}call_type, {pcol} AS provider, "
        f"{mcol} AS model, COUNT(*) AS cnt, "
        "SUM(input_tokens) AS total_in, SUM(output_tokens) AS total_out, "
        f"SUM(COALESCE({ccol}, 0)) AS total_cached "
        "FROM token_usage"
    )
    where: list[str] = []
    params: list = []
    if user_id is not None:
        where.append("user_id = ?")
        params.append(user_id)
    if since is not None:
        where.append("julianday(created_at) >= julianday(?)")
        params.append(since)
    if where:
        sql += " WHERE " + " AND ".join(where)
    group = "call_type, provider, model" if user_id is not None else "user_id, call_type, provider, model"
    sql += f" GROUP BY {group}"
    return conn.execute(sql, params).fetchall()


def _empty_user_summary() -> dict[str, Any]:
    return {
        "total_calls": 0,
        "total_input_tokens": 0,
        "total_output_tokens": 0,
        "total_tokens": 0,
        "total_cost_usd": 0.0,
        "by_service": {},
        "by_model": {},
        "by_call_type": {},
    }


def fold_user_summary(rows: list[tuple]) -> dict[str, Any]:
    """Pure fold:把 :func:`query_cost_rows` 的列折成 by_service/by_model/
    by_call_type + totals。每個 (call_type, provider) 切片以自身 provider 費率
    定價;NULL provider 的 legacy 列 fallback 到 call_type 當前 route 的 provider。

    只讀每列尾端的 ``call_type, provider, model, cnt, total_in, total_out, total_cached``,
    領頭 uid(若有)忽略 —— 故單用戶/跨用戶共用同一折疊邏輯。
    """
    from .quota_service import token_cost_usd

    out = _empty_user_summary()
    by_call_type = out["by_call_type"]
    by_service = out["by_service"]
    by_model = out["by_model"]
    total_in = total_out = total_calls = 0
    total_cost = 0.0

    for row in rows:
        call_type, provider, model, cnt, t_in, t_out, t_cached = row[-7:]
        ti = int(t_in or 0)
        to = int(t_out or 0)
        c = int(cnt or 0)
        cost = token_cost_usd(call_type, ti, to, provider=provider, cached_tokens=int(t_cached or 0))

        total_in += ti
        total_out += to
        total_cost += cost
        total_calls += c

        mdl = model or model_for(call_type)
        for buckets, key in (
            (by_call_type, call_type),
            (by_service, service_for(call_type)),
            (by_model, mdl),
        ):
            _accumulate(buckets, key, calls=c, input_tokens=ti, output_tokens=to, cost=cost)

    for bucket in (*by_service.values(), *by_model.values(), *by_call_type.values()):
        bucket["cost_usd"] = round(bucket["cost_usd"], 6)

    out["total_calls"] = total_calls
    out["total_input_tokens"] = total_in
    out["total_output_tokens"] = total_out
    out["total_tokens"] = total_in + total_out
    out["total_cost_usd"] = round(total_cost, 6)
    return out


def _accumulate(
    buckets: dict[str, dict[str, Any]],
    key: str,
    *,
    calls: int,
    input_tokens: int,
    output_tokens: int,
    cost: float,
) -> None:
    """Fold one priced row slice into ``buckets[key]``, creating it if absent."""
    bucket = buckets.setdefault(key, {"calls": 0, "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0})
    bucket["calls"] += calls
    bucket["input_tokens"] += input_tokens
    bucket["output_tokens"] += output_tokens
    bucket["cost_usd"] += cost


def get_user_cost_summary(user_id: str, *, range_: str = "month") -> dict[str, Any]:
    """Return per-user token + cost breakdown for the given range.

    Shape:
        ``{user_id, range, since, total_input_tokens, total_output_tokens,
        total_tokens, total_cost_usd, by_service, by_model, by_call_type,
        pricing_assumptions}``

    Empty when no rows match — never raises ``IndexError`` on an empty
    table, never inserts a default user.
    """
    if range_ not in VALID_RANGES:
        raise ValueError(f"Invalid range: {range_}")

    # Import lazily so unit tests can monkeypatch DATA_DIR before module
    # initialises its SQLite connection.
    from .quota_service import EMBED_PER_M, INPUT_PER_M, OUTPUT_PER_M
    from .token_tracker import _get_conn, _lock

    since = since_iso(range_)

    # admin 面只負責「怎麼連」(RW singleton + _lock);「查什麼/怎麼折」
    # 全交給共用核心,與 ops 的 connect_ro 路徑共用同一語意。
    with _lock:
        conn = _get_conn()
        rows = query_cost_rows(conn, user_id=user_id, since=since)
        oldest = _oldest_retained_at(conn) if range_ == "all" else None

    summary = fold_user_summary(rows)

    # range='all' is only lifetime up to the token_usage prune horizon; disclose it.
    retention: dict[str, Any] = {}
    if range_ == "all":
        from .log_retention import _effective_days

        retention = {
            "retention_days": _effective_days("token", None),
            "oldest_retained_at": oldest,
        }

    return {
        "user_id": user_id,
        "range": range_,
        "since": since,
        **retention,
        "total_calls": summary["total_calls"],
        "total_input_tokens": summary["total_input_tokens"],
        "total_output_tokens": summary["total_output_tokens"],
        "total_tokens": summary["total_tokens"],
        "total_cost_usd": summary["total_cost_usd"],
        "by_service": summary["by_service"],
        "by_model": summary["by_model"],
        "by_call_type": summary["by_call_type"],
        "pricing_assumptions": {
            "input_usd_per_m_tokens": INPUT_PER_M,
            "output_usd_per_m_tokens": OUTPUT_PER_M,
            "embed_usd_per_m_tokens": EMBED_PER_M,
            "model_inferred_from_call_type": True,
            "default_model": _DEFAULT_MODEL,
            "embed_model": _MODEL_MAP["embed"],
            "service_map": dict(_SERVICE_MAP),
        },
    }
