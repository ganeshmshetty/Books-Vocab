"""Tests for /api/podcasts/*/progress endpoints.

Contract:
* Authenticated endpoints: 401 without Bearer.
* POST writes per-user (series_id, ep_num, position_sec, duration_sec,
  updated_at). Last-write-wins by `updated_at` (older payload ignored).
* GET list returns all of the caller's progress rows.
* GET single returns 404 when no row exists.
* Cross-user isolation: user A cannot see user B's progress.
* series_id / ep_num validation matches the existing podcast routes.
"""

from __future__ import annotations

import re

import pytest

from kg import podcast_progress as progress_store
from kg.routers import podcast as _podcast_mod

_ISO_NOW = "2026-05-14T12:00:00+00:00"
_ISO_LATER = "2026-05-14T12:05:00+00:00"
_ISO_EARLIER = "2026-05-14T11:55:00+00:00"
# These strings are deliberately ordered opposite to their UTC instants:
# 12:00+01:00 is 11:00 UTC, while 11:30+00:00 is 11:30 UTC.
_ISO_OFFSET_EARLIER = "2026-05-14T12:00:00+01:00"
_ISO_OFFSET_LATER = "2026-05-14T11:30:00+00:00"

# Same wall-clock instant in two ISO8601 widths. iOS now emits fractional
# seconds (`.withFractionalSeconds`); older clients / older rows are
# integer-second. A bare lexicographic compare is WRONG here because ASCII
# '+' (0x2B) < '.' (0x2E): "...:00+00:00" always sorts before
# "...:00.000000+00:00" even though they are the same moment.
_ISO_INT_SEC = "2026-05-14T12:00:00+00:00"
_ISO_FRAC_SEC = "2026-05-14T12:00:00.000000+00:00"
# An *earlier* instant expressed with fractional seconds — must lose to a
# *newer* integer-second stored row despite sorting later as a string.
_ISO_FRAC_EARLIER = "2026-05-14T11:55:00.250000+00:00"


def _post_progress(api, series, ep, *, position, duration, updated_at, headers=None):
    return api.client.post(
        f"/api/podcasts/{series}/{ep}/progress",
        json={
            "position_sec": position,
            "duration_sec": duration,
            "updated_at": updated_at,
        },
        headers=headers or api.headers,
    )


# ---------------------------------------------------------------------------
# Auth gates
# ---------------------------------------------------------------------------


def test_post_progress_requires_auth(isolated_api):
    resp = isolated_api.client.post(
        "/api/podcasts/series_a/1/progress",
        json={"position_sec": 10.0, "duration_sec": 100.0, "updated_at": _ISO_NOW},
    )
    assert resp.status_code == 401


def test_get_progress_list_requires_auth(isolated_api):
    resp = isolated_api.client.get("/api/podcasts/progress")
    assert resp.status_code == 401


def test_get_progress_single_requires_auth(isolated_api):
    resp = isolated_api.client.get("/api/podcasts/series_a/1/progress")
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------


def test_post_progress_creates_row(isolated_api):
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=42.5,
        duration=300.0,
        updated_at=_ISO_NOW,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["series_id"] == "series_a"
    assert body["ep_num"] == 1
    assert body["position_sec"] == 42.5
    assert body["duration_sec"] == 300.0
    assert body["updated_at"] == _ISO_NOW


def test_get_single_after_post(isolated_api):
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=42.5,
        duration=300.0,
        updated_at=_ISO_NOW,
    )
    resp = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=isolated_api.headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["series_id"] == "series_a"
    assert body["ep_num"] == 1
    assert body["position_sec"] == 42.5


def test_get_single_404_when_no_row(isolated_api):
    resp = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=isolated_api.headers,
    )
    assert resp.status_code == 404


def test_get_list_returns_all_rows(isolated_api):
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=10.0,
        duration=100.0,
        updated_at=_ISO_NOW,
    )
    _post_progress(
        isolated_api,
        "series_a",
        2,
        position=20.0,
        duration=200.0,
        updated_at=_ISO_NOW,
    )
    _post_progress(
        isolated_api,
        "series_b",
        1,
        position=30.0,
        duration=300.0,
        updated_at=_ISO_NOW,
    )
    resp = isolated_api.client.get("/api/podcasts/progress", headers=isolated_api.headers)
    assert resp.status_code == 200
    items = resp.json()["items"]
    assert len(items) == 3
    keys = {(it["series_id"], it["ep_num"]) for it in items}
    assert keys == {("series_a", 1), ("series_a", 2), ("series_b", 1)}


def test_list_for_user_orders_offset_timestamps_by_utc_instant(isolated_api):
    from kg import podcast_progress

    podcast_progress.upsert(
        user_id=isolated_api.user_id,
        series_id="series_earlier",
        ep_num=1,
        position_sec=10.0,
        duration_sec=100.0,
        updated_at=_ISO_OFFSET_EARLIER,
    )
    podcast_progress.upsert(
        user_id=isolated_api.user_id,
        series_id="series_later",
        ep_num=1,
        position_sec=20.0,
        duration_sec=200.0,
        updated_at=_ISO_OFFSET_LATER,
    )

    items = podcast_progress.list_for_user(user_id=isolated_api.user_id)
    assert [(item["series_id"], item["updated_at"]) for item in items] == [
        ("series_later", _ISO_OFFSET_LATER),
        ("series_earlier", _ISO_OFFSET_EARLIER),
    ]


def test_list_for_user_orders_and_limits_in_sql(isolated_api):
    from kg import podcast_progress

    podcast_progress.upsert(
        user_id=isolated_api.user_id,
        series_id="series_earlier",
        ep_num=1,
        position_sec=10.0,
        duration_sec=100.0,
        updated_at=_ISO_OFFSET_EARLIER,
    )
    podcast_progress.upsert(
        user_id=isolated_api.user_id,
        series_id="series_later",
        ep_num=1,
        position_sec=20.0,
        duration_sec=200.0,
        updated_at=_ISO_OFFSET_LATER,
    )

    statements = []
    conn = podcast_progress._get_conn()
    conn.set_trace_callback(statements.append)
    try:
        items = podcast_progress.list_for_user(
            user_id=isolated_api.user_id,
            limit=1,
        )
    finally:
        conn.set_trace_callback(None)

    assert [(item["series_id"], item["updated_at"]) for item in items] == [
        ("series_later", _ISO_OFFSET_LATER),
    ]
    select = next(statement for statement in statements if statement.startswith("SELECT"))
    assert "LIMIT 1" in select


def test_get_list_empty_returns_empty_items(isolated_api):
    resp = isolated_api.client.get("/api/podcasts/progress", headers=isolated_api.headers)
    assert resp.status_code == 200
    assert resp.json() == {"items": []}


# ---------------------------------------------------------------------------
# Last-write-wins
# ---------------------------------------------------------------------------


def test_repost_with_newer_updated_at_overwrites(isolated_api):
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=10.0,
        duration=300.0,
        updated_at=_ISO_NOW,
    )
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=120.0,
        duration=300.0,
        updated_at=_ISO_LATER,
    )
    resp = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=isolated_api.headers,
    )
    body = resp.json()
    assert body["position_sec"] == 120.0
    assert body["updated_at"] == _ISO_LATER


def test_repost_with_older_updated_at_ignored(isolated_api):
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=120.0,
        duration=300.0,
        updated_at=_ISO_NOW,
    )
    # Older payload arrives (e.g. delayed sync from another device) — must not clobber.
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=10.0,
        duration=300.0,
        updated_at=_ISO_EARLIER,
    )
    assert resp.status_code == 200
    body = resp.json()
    # Returned row should reflect the latest (existing) record, not the stale write.
    assert body["position_sec"] == 120.0
    assert body["updated_at"] == _ISO_NOW

    resp_get = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=isolated_api.headers,
    )
    assert resp_get.json()["position_sec"] == 120.0


# ---------------------------------------------------------------------------
# Last-write-wins across mixed timestamp widths (integer vs fractional secs)
# ---------------------------------------------------------------------------
#
# Regression guard for the iOS `.withFractionalSeconds` change (PR #532):
# the client may now POST fractional-second timestamps while older rows in
# the store are integer-second. The LWW comparison must be on the parsed
# instant, not on the raw ISO string, otherwise '+' < '.' in ASCII makes
# the comparison nonsensical across widths.


def test_lww_fractional_older_does_not_clobber_integer_newer(isolated_api):
    """An older fractional-second write must not overwrite a newer
    integer-second stored row (string compare would wrongly let it win)."""
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=120.0,
        duration=300.0,
        updated_at=_ISO_NOW,  # integer secs
    )
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=10.0,
        duration=300.0,
        updated_at=_ISO_FRAC_EARLIER,  # older, fractional
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["position_sec"] == 120.0
    assert body["updated_at"] == _ISO_NOW

    resp_get = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=isolated_api.headers,
    )
    assert resp_get.json()["position_sec"] == 120.0


def test_lww_fractional_newer_overwrites_integer(isolated_api):
    """A newer fractional-second write overwrites an older integer-second row."""
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=10.0,
        duration=300.0,
        updated_at=_ISO_EARLIER,  # older, integer
    )
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=120.0,
        duration=300.0,
        updated_at="2026-05-14T12:05:00.500000+00:00",  # newer, fractional
    )
    resp = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=isolated_api.headers,
    )
    assert resp.json()["position_sec"] == 120.0


def test_lww_same_instant_mixed_width_no_clobber_by_smaller_position(isolated_api):
    """Integer-second and fractional-second strings for the SAME instant must
    compare equal as a tie. The tie is broken by the LARGER position_sec — a
    same-instant write carrying a *smaller* position must NOT clobber the
    stored larger one (matches iOS `mergeRemoteProgress`:
    `remoteWins = item.positionSec > local.lastPlayedTime`)."""
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=120.0,
        duration=300.0,
        updated_at=_ISO_INT_SEC,
    )
    # Same moment, fractional spelling, SMALLER position — tie lost on position.
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=10.0,
        duration=300.0,
        updated_at=_ISO_FRAC_SEC,
    )
    assert resp.status_code == 200
    assert resp.json()["position_sec"] == 120.0


# ---------------------------------------------------------------------------
# Same-second LWW: position tie-break must converge regardless of arrival order
# ---------------------------------------------------------------------------
#
# PR #532 symmetrised the iOS↔iOS same-second merge (`mergeRemoteProgress`
# breaks ties by larger `positionSec`), but the backend `upsert` kept a
# first-writer-wins rule (`stored_dt >= incoming_dt`): a same-instant write
# always lost regardless of position. Two devices pushing different positions
# at the same wall-clock second would never converge with the server — each
# device kept its own larger local position, every pull/push diverged again.
# The backend must adopt the SAME position tie-break so device↔server
# converges to the larger position independently of arrival order.


def test_same_second_larger_position_wins_when_arrives_second(isolated_api):
    """Smaller position stored first, larger position arrives second at the
    SAME instant → larger position wins."""
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=30.0,
        duration=300.0,
        updated_at=_ISO_INT_SEC,
    )
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=200.0,
        duration=300.0,
        updated_at=_ISO_INT_SEC,
    )
    assert resp.status_code == 200
    assert resp.json()["position_sec"] == 200.0
    resp_get = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=isolated_api.headers,
    )
    assert resp_get.json()["position_sec"] == 200.0


def test_same_second_larger_position_wins_when_arrives_first(isolated_api):
    """Larger position stored first, smaller position arrives second at the
    SAME instant → larger (stored) position is retained. Symmetric to the
    previous test: arrival order must not change the converged result."""
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=200.0,
        duration=300.0,
        updated_at=_ISO_INT_SEC,
    )
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=30.0,
        duration=300.0,
        updated_at=_ISO_INT_SEC,
    )
    assert resp.status_code == 200
    assert resp.json()["position_sec"] == 200.0
    resp_get = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=isolated_api.headers,
    )
    assert resp_get.json()["position_sec"] == 200.0


def test_same_second_position_tiebreak_holds_across_mixed_widths(isolated_api):
    """The position tie-break must also work when the same instant is spelled
    integer-second vs fractional-second — a larger-position fractional write
    overwrites a smaller-position integer row at the same instant."""
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=30.0,
        duration=300.0,
        updated_at=_ISO_INT_SEC,
    )
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=200.0,
        duration=300.0,
        updated_at=_ISO_FRAC_SEC,
    )
    assert resp.status_code == 200
    assert resp.json()["position_sec"] == 200.0


def test_strictly_older_write_still_loses_regardless_of_position(isolated_api):
    """A strictly-older timestamp must lose even when it carries a larger
    position — the position tie-break only applies at the SAME instant, not
    as a general override of the timestamp ordering."""
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=30.0,
        duration=300.0,
        updated_at=_ISO_NOW,
    )
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=999.0,
        duration=300.0,
        updated_at=_ISO_EARLIER,
    )
    assert resp.status_code == 200
    assert resp.json()["position_sec"] == 30.0
    assert resp.json()["updated_at"] == _ISO_NOW


# ---------------------------------------------------------------------------
# Cross-user isolation
# ---------------------------------------------------------------------------


def test_cross_user_isolation_single(isolated_api):
    from conftest import make_jwt  # type: ignore

    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=42.5,
        duration=300.0,
        updated_at=_ISO_NOW,
    )
    other_headers = {"Authorization": f"Bearer {make_jwt('other_user')}"}
    resp = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=other_headers,
    )
    # Other user has no row → 404, never leaks user A's progress.
    assert resp.status_code == 404


def test_cross_user_isolation_list(isolated_api):
    from conftest import make_jwt  # type: ignore

    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=42.5,
        duration=300.0,
        updated_at=_ISO_NOW,
    )
    other_headers = {"Authorization": f"Bearer {make_jwt('other_user')}"}
    resp = isolated_api.client.get("/api/podcasts/progress", headers=other_headers)
    assert resp.status_code == 200
    assert resp.json() == {"items": []}


def test_cross_user_independent_writes(isolated_api):
    from conftest import make_jwt  # type: ignore

    other_headers = {"Authorization": f"Bearer {make_jwt('other_user')}"}
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=10.0,
        duration=100.0,
        updated_at=_ISO_NOW,
    )
    _post_progress(
        isolated_api,
        "series_a",
        1,
        position=80.0,
        duration=100.0,
        updated_at=_ISO_NOW,
        headers=other_headers,
    )
    resp_self = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=isolated_api.headers,
    )
    resp_other = isolated_api.client.get(
        "/api/podcasts/series_a/1/progress",
        headers=other_headers,
    )
    assert resp_self.json()["position_sec"] == 10.0
    assert resp_other.json()["position_sec"] == 80.0


# ---------------------------------------------------------------------------
# Validation (series_id regex + ep_num bounds + body schema)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "bad_id",
    # "..%2fetc" never matches a route (two segments once decoded); "%2e%2e"
    # reaches the handler, see test_post_series_id_guard_blocks_encoded_traversal.
    ["..%2fetc", "series.a", "series-a", "Series_A", "%2e%2e"],
)
def test_post_series_id_rejects_bad_inputs(isolated_api, bad_id):
    resp = _post_progress(
        isolated_api,
        bad_id,
        1,
        position=10.0,
        duration=100.0,
        updated_at=_ISO_NOW,
    )
    assert resp.status_code in (404, 422)


def test_post_ep_num_rejects_zero(isolated_api):
    resp = _post_progress(
        isolated_api,
        "series_a",
        0,
        position=10.0,
        duration=100.0,
        updated_at=_ISO_NOW,
    )
    assert resp.status_code == 422


def test_post_ep_num_rejects_overflow(isolated_api):
    resp = _post_progress(
        isolated_api,
        "series_a",
        10000,
        position=10.0,
        duration=100.0,
        updated_at=_ISO_NOW,
    )
    assert resp.status_code == 422


def test_post_rejects_malformed_updated_at(isolated_api):
    resp = isolated_api.client.post(
        "/api/podcasts/series_a/1/progress",
        json={"position_sec": 10.0, "duration_sec": 100.0, "updated_at": "not-iso"},
        headers=isolated_api.headers,
    )
    assert resp.status_code == 422


def test_post_rejects_negative_position(isolated_api):
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=-1.0,
        duration=100.0,
        updated_at=_ISO_NOW,
    )
    assert resp.status_code == 422


def test_post_rejects_negative_duration(isolated_api):
    resp = _post_progress(
        isolated_api,
        "series_a",
        1,
        position=10.0,
        duration=-100.0,
        updated_at=_ISO_NOW,
    )
    assert resp.status_code == 422


# A literal "/api/podcasts/../x" is stripped to "/api/x" by httpx and 404s on a
# route that does not exist (#2113; banned by test_no_dot_segment_urls).
# "%2e%2e" is sent verbatim and reaches the handler as series_id="..". Each test
# first proves the request lands on the handler with the guard neutralised, then
# proves the real guard stops it.
_TRAVERSAL_URL = "/api/podcasts/%2e%2e/1/progress"


def _request_without_series_id_guard(monkeypatch, send):
    """Positive control: run ``send`` while every series_id passes the guard."""
    with monkeypatch.context() as patched:
        patched.setattr(_podcast_mod, "_SERIES_ID_RE", re.compile(r".+", re.DOTALL))
        return send()


def test_get_single_series_id_guard_blocks_encoded_traversal(isolated_api, monkeypatch):
    progress_store.upsert(
        user_id=isolated_api.user_id,
        series_id="..",
        ep_num=1,
        position_sec=7.0,
        duration_sec=70.0,
        updated_at=_ISO_NOW,
    )

    leaked = _request_without_series_id_guard(
        monkeypatch, lambda: isolated_api.client.get(_TRAVERSAL_URL, headers=isolated_api.headers)
    )
    assert leaked.status_code == 200, "control: the encoded traversal must reach the handler"
    assert leaked.json()["series_id"] == ".."

    resp = isolated_api.client.get(_TRAVERSAL_URL, headers=isolated_api.headers)
    assert resp.status_code == 404
    assert resp.json() == {"detail": "Not Found"}  # the guard's bare 404, not the row


def test_post_series_id_guard_blocks_encoded_traversal(isolated_api, monkeypatch):
    leaked = _request_without_series_id_guard(
        monkeypatch,
        lambda: _post_progress(isolated_api, "%2e%2e", 1, position=7.0, duration=70.0, updated_at=_ISO_NOW),
    )
    assert leaked.status_code == 200, "control: the encoded traversal must reach the handler"
    assert leaked.json()["series_id"] == ".."

    resp = _post_progress(isolated_api, "%2e%2e", 1, position=99.0, duration=70.0, updated_at=_ISO_LATER)
    assert resp.status_code == 404
    stored = progress_store.get_single(user_id=isolated_api.user_id, series_id="..", ep_num=1)
    assert stored is not None and stored["position_sec"] == 7.0  # the guarded write never hit the store


def test_get_single_ep_num_rejects_zero(isolated_api):
    resp = isolated_api.client.get(
        "/api/podcasts/series_a/0/progress",
        headers=isolated_api.headers,
    )
    assert resp.status_code == 422


class _CommitFailsOnce:
    """Proxy whose first commit raises; every other call delegates to the real connection."""

    def __init__(self, real):
        self._real = real
        self._armed = True

    def commit(self):
        if self._armed:
            self._armed = False
            import sqlite3

            raise sqlite3.OperationalError("simulated commit failure")
        self._real.commit()

    def __getattr__(self, name):
        return getattr(self._real, name)


def test_delete_for_users_rolls_back_when_commit_fails(monkeypatch):
    """A failed erasure must leave no open transaction on the shared connection."""
    import sqlite3

    real = progress_store._get_conn()
    proxy = _CommitFailsOnce(real)
    monkeypatch.setattr(progress_store, "_get_conn", lambda *a, **k: proxy)

    with pytest.raises(sqlite3.OperationalError):
        progress_store.delete_for_users(["gone"])

    assert real.in_transaction is False
    assert progress_store.delete_for_users(["gone"]) == 0
