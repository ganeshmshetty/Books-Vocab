"""HTTP regression for the review-state progress override (#2042).

Exercises PATCH /api/vocab/review end to end: the body union must parse an
``override`` entry, a server-newer card must be reset, and an override pushed
by another user must never touch the owner's card.
"""

from __future__ import annotations

from contextlib import closing
from datetime import UTC, datetime, timedelta

from conftest import make_jwt
from kg.cards import CardStore


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _seed_reviewed_card(api, *, last_reviewed_at: datetime):
    with closing(CardStore(api.data_dir / "users" / api.user_id / "cards.db")) as store:
        card = store.add(content="progress", meaning="進度", notebook_id="default")
        store.update(
            card.id,
            last_reviewed_at=last_reviewed_at,
            review_count=9,
            lapse_count=4,
            review_interval_hours=96.0,
            review_streak=5,
            last_review_feedback=1,
        )
        return card.id


def _read_card(api, card_id: str):
    with closing(CardStore(api.data_dir / "users" / api.user_id / "cards.db")) as store:
        return store.get(card_id)


def _override_entry(card_id: str, *, client_last: datetime, reset_at: datetime) -> dict:
    return {
        "word": "progress",
        "card_id": card_id,
        "review_interval_hours": 12.0,
        "next_review_at": _iso(reset_at),
        "last_reviewed_at": _iso(client_last),
        "review_count": 0,
        "lapse_count": 0,
        "review_streak": 0,
        "last_review_feedback": -1,
        "override": True,
    }


def test_patch_review_override_resets_server_newer_card(isolated_api):
    now = datetime.now(UTC)
    card_id = _seed_reviewed_card(isolated_api, last_reviewed_at=now)

    r = isolated_api.client.patch(
        "/api/vocab/review",
        json={
            "entries": [
                _override_entry(card_id, client_last=now - timedelta(hours=1), reset_at=now),
            ]
        },
        headers=isolated_api.headers,
    )

    assert r.status_code == 200, r.text
    assert r.json() == {"updated": 1, "skipped": 0}
    card = _read_card(isolated_api, card_id)
    assert card.review_count == 0
    assert card.lapse_count == 0
    assert card.review_interval_hours == 12.0
    assert card.review_streak == 0
    assert card.last_review_feedback == -1


def test_patch_review_override_from_other_user_never_touches_owner_card(isolated_api):
    now = datetime.now(UTC)
    card_id = _seed_reviewed_card(isolated_api, last_reviewed_at=now)
    other_headers = {"Authorization": f"Bearer {make_jwt('other_user')}"}

    r = isolated_api.client.patch(
        "/api/vocab/review",
        json={
            "entries": [
                _override_entry(card_id, client_last=now + timedelta(hours=1), reset_at=now),
            ]
        },
        headers=other_headers,
    )

    assert r.status_code == 200, r.text
    assert r.json() == {"updated": 0, "skipped": 1}
    card = _read_card(isolated_api, card_id)
    assert card.review_count == 9
    assert card.lapse_count == 4
    assert card.review_interval_hours == 96.0
    assert card.review_streak == 5
    assert card.last_review_feedback == 1
