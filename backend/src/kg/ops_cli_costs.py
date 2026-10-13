"""Cost and fleet commands for the readonly ops CLI."""

from __future__ import annotations

import argparse
import http.client
import ipaddress
import json
import os
import sys
import urllib.request
from urllib.parse import urlsplit

from kg.admin_cost_summary import fold_user_summary, query_cost_rows, since_iso
from kg.log_retention import _effective_days
from kg.ops_shared import column_expr, connect_ro, data_dir, emit_json, print_table, provider_column_expr, resolve_uid
from kg.quota_service import token_cost_usd

_BACKEND_URL_ENV = "KG_OPS_BACKEND_URL"
_DEFAULT_BACKEND_URL = "http://127.0.0.1:8000"


def _backend_base_is_trusted(base: str) -> bool:
    """ADMIN_TOKEN may only travel over https, or plaintext to a loopback host (#3570)."""
    parts = urlsplit(base)
    host = parts.hostname
    if not host:
        return False
    if parts.scheme == "https":
        return True
    if parts.scheme != "http":
        return False
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _backend_token_retention_days() -> int | None:
    """Backend's effective token_usage retention from /api/admin/observability, or None if unavailable.

    The pruner runs under the backend env_file, not this CLI's process env, so the backend is the
    authority (#3500). Needs ADMIN_TOKEN in the CLI env; any failure returns None and the caller falls
    back to the local *_RETENTION_DAYS resolution.
    """
    token = os.getenv("ADMIN_TOKEN", "")
    if not token:
        return None
    base = os.getenv(_BACKEND_URL_ENV, _DEFAULT_BACKEND_URL).rstrip("/")
    if not _backend_base_is_trusted(base):
        return None
    req = urllib.request.Request(f"{base}/api/admin/observability", headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            days = json.loads(resp.read())["log_db_health"]["token_usage"]["retention_days"]
    except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException):
        return None
    return days if isinstance(days, int) and not isinstance(days, bool) else None


def cmd_cost(args: argparse.Namespace) -> None:
    uid = resolve_uid(args.uid, data_dir())
    range_ = args.range
    since = since_iso(range_)
    db_path = data_dir() / "token_usage.db"

    summary: dict = {
        "user_id": uid,
        "range": range_,
        "since": since,
        "total_calls": 0,
        "total_input_tokens": 0,
        "total_output_tokens": 0,
        "total_cost_usd": 0.0,
        "by_call_type": {},
    }

    # range=all is only lifetime up to the token_usage prune horizon; disclose it (#3459).
    oldest: str | None = None
    if db_path.exists():
        conn = connect_ro(db_path)
        folded = fold_user_summary(query_cost_rows(conn, user_id=uid, since=since))
        if range_ == "all":
            oldest = conn.execute("SELECT MIN(created_at) FROM token_usage").fetchone()[0]
        conn.close()
        summary["total_calls"] = folded["total_calls"]
        summary["total_input_tokens"] = folded["total_input_tokens"]
        summary["total_output_tokens"] = folded["total_output_tokens"]
        summary["total_cost_usd"] = folded["total_cost_usd"]
        summary["by_call_type"] = folded["by_call_type"]

    retention_days = None
    if range_ == "all":
        retention_days = _backend_token_retention_days()
        if retention_days is None:
            retention_days = _effective_days("token", None)
    if retention_days is not None:
        summary["retention_days"] = retention_days
        summary["oldest_retained_at"] = oldest

    if args.json:
        emit_json(summary)
        return

    window = f"since {since}" if since else "all-time"
    print(f"User: {uid}  |  Range: {range_} ({window})")
    if retention_days is not None:
        print(f"Retention: {retention_days} days  |  oldest retained: {oldest or '-'}")
    print(f"Total: ${summary['total_cost_usd']:.6f}  |  {summary['total_calls']} calls")
    print()
    table_rows = sorted(
        [
            [ct, str(b["calls"]), str(b["input_tokens"]), str(b["output_tokens"]), f"${b['cost_usd']:.6f}"]
            for ct, b in summary["by_call_type"].items()
        ],
        key=lambda r: float(r[4].replace("$", "")),
        reverse=True,
    )
    print_table(["Call Type", "Calls", "In Tokens", "Out Tokens", "Cost (USD)"], table_rows)


def cmd_cost_overview(args: argparse.Namespace) -> None:
    range_ = args.range
    since = since_iso(range_)
    db_path = data_dir() / "token_usage.db"
    result: dict = {"range": range_, "since": since, "users": []}

    if db_path.exists():
        conn = connect_ro(db_path)
        rows = query_cost_rows(conn, user_id=None, since=since)
        conn.close()
        by_uid: dict[str, list] = {}
        for row in rows:
            by_uid.setdefault(row[0], []).append(row)
        per_user: dict[str, dict] = {}
        for user_id, urows in by_uid.items():
            f = fold_user_summary(urows)
            per_user[user_id] = {"total_calls": f["total_calls"], "total_cost_usd": f["total_cost_usd"]}
        result["users"] = sorted(
            (
                {"user_id": uid, "total_calls": u["total_calls"], "total_cost_usd": u["total_cost_usd"]}
                for uid, u in per_user.items()
            ),
            key=lambda u: u["total_cost_usd"],
            reverse=True,
        )

    if args.json:
        result["count"] = len(result["users"])
        emit_json(result)
        return

    window = f"since {since}" if since else "all-time"
    print(f"Range: {range_} ({window})")
    print()
    print_table(
        ["User", "Calls", "Cost (USD)"],
        [[u["user_id"], str(u["total_calls"]), f"${u['total_cost_usd']:.6f}"] for u in result["users"]],
    )


def cmd_fleet_overview(args: argparse.Namespace) -> None:
    dd = data_dir()
    users_dir = dd / "users"
    since = since_iso("month")
    month_cost: dict[str, float] = {}
    month_calls: dict[str, int] = {}
    last_active: dict[str, str] = {}
    token_db = dd / "token_usage.db"
    if token_db.exists():
        conn = connect_ro(token_db)
        pcol = provider_column_expr(conn)
        ccol = column_expr(conn, "token_usage", "cached_input_tokens")
        sql = (
            f"SELECT user_id, call_type, {pcol} AS provider, COUNT(*), SUM(input_tokens), "
            f"SUM(output_tokens), SUM(COALESCE({ccol}, 0)) FROM token_usage"
        )
        params: list = []
        if since is not None:
            sql += " WHERE julianday(created_at) >= julianday(?)"
            params.append(since)
        sql += f" GROUP BY user_id, call_type, {pcol}"
        for uid, call_type, provider, cnt, t_in, t_out, t_cached in conn.execute(sql, params):
            month_cost[uid] = month_cost.get(uid, 0.0) + token_cost_usd(
                call_type, int(t_in or 0), int(t_out or 0), provider=provider, cached_tokens=int(t_cached or 0)
            )
            month_calls[uid] = month_calls.get(uid, 0) + cnt
        for uid, la in conn.execute("SELECT user_id, max(created_at) FROM token_usage GROUP BY user_id"):
            last_active[uid] = la
        conn.close()

    user_dirs = (
        sorted((p for p in users_dir.iterdir() if p.is_dir()), key=lambda p: p.name) if users_dir.exists() else []
    )
    user_rows: list[dict] = []
    for ud in user_dirs:
        uid = ud.name
        total = active = 0
        cards_db = ud / "cards.db"
        if cards_db.exists():
            c = connect_ro(cards_db)
            try:
                total = c.execute("SELECT count(*) FROM card").fetchone()[0]
                active = c.execute("SELECT count(*) FROM card WHERE is_deleted = 0").fetchone()[0]
            finally:
                c.close()
        links = 0
        corrupt = 0
        for gp in ud.glob("graph_*.json"):
            try:
                raw = json.loads(gp.read_text())
            except (json.JSONDecodeError, ValueError, OSError):
                corrupt += 1
                continue
            if isinstance(raw, (list, dict)):
                links += len(raw)
            else:
                corrupt += 1
        if corrupt:
            print(f"⚠ {uid}: skipped {corrupt} unreadable/bad-shape graph file(s)", file=sys.stderr)
        user_rows.append(
            {
                "user_id": uid,
                "cards_total": total,
                "cards_active": active,
                "cards_deleted": total - active,
                "links": links,
                "last_active": last_active.get(uid),
                "month_cost_usd": round(month_cost.get(uid, 0.0), 6),
                "month_calls": month_calls.get(uid, 0),
            }
        )

    user_rows.sort(key=lambda u: (u["cards_active"], u["month_cost_usd"]), reverse=True)
    totals = {
        "users": len(user_rows),
        "cards_total": sum(u["cards_total"] for u in user_rows),
        "cards_active": sum(u["cards_active"] for u in user_rows),
        "cards_deleted": sum(u["cards_deleted"] for u in user_rows),
        "links": sum(u["links"] for u in user_rows),
        "month_cost_usd": round(sum(u["month_cost_usd"] for u in user_rows), 6),
        "month_calls": sum(u["month_calls"] for u in user_rows),
    }

    if args.json:
        emit_json({"count": len(user_rows), "users": user_rows, "totals": totals})
        return

    print(f"Fleet Overview — {totals['users']} users")
    print(
        f"Cards: {totals['cards_total']} total / {totals['cards_active']} active / "
        f"{totals['cards_deleted']} deleted  |  Links: {totals['links']}  |  "
        f"Month: ${totals['month_cost_usd']:.6f} ({totals['month_calls']} calls)"
    )
    print()
    print_table(
        ["User", "Cards", "Active", "Deleted", "Links", "Last Active", "Month $", "Calls"],
        [
            [
                u["user_id"],
                str(u["cards_total"]),
                str(u["cards_active"]),
                str(u["cards_deleted"]),
                str(u["links"]),
                (u["last_active"] or "-")[:19],
                f"${u['month_cost_usd']:.6f}",
                str(u["month_calls"]),
            ]
            for u in user_rows
        ],
    )
