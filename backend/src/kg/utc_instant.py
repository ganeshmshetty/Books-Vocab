"""Client timestamp parsing as absolute UTC instants (shared by since/updated_at inputs)."""

from __future__ import annotations

from datetime import UTC, datetime


def to_utc_instant(parsed: datetime) -> datetime:
    """Return ``parsed`` as an aware UTC instant; naive values are taken as UTC.

    Raises ``ValueError`` when the instant is not representable in UTC. A
    year-1 timestamp with a positive offset makes ``astimezone`` overflow; that
    is malformed client input, so it is reported like any other invalid value.
    """
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    try:
        return parsed.astimezone(UTC)
    except OverflowError as exc:
        raise ValueError(f"timestamp out of UTC range: {parsed.isoformat()}") from exc


def parse_utc_instant(value: str) -> datetime:
    """Parse an ISO-8601 string as a UTC instant.

    Raises ``ValueError`` for unparseable input and for values outside the
    representable UTC range, so callers map both to a 400.
    """
    return to_utc_instant(datetime.fromisoformat(value.replace("Z", "+00:00")))
