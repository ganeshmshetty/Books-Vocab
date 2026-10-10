from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.errors import AdapterCommandError, AdapterPayloadError
from delivery_control.adapters.github_client import GitHubCliClient
from delivery_control.adapters.github_rate_governor import (
    QuotaDecision,
    QuotaGovernor,
    QuotaSnapshot,
)
from delivery_control.domain.errors import DeliverySourceError
from delivery_control.ports.process import CommandResult

NOW = 1_000.0
_ARGV = ("gh", "api", "repos/owner/repo/pulls/12/files?per_page=100&page=1")
_OTHER = ("gh", "api", "repos/owner/repo/other")


class StaticRunner:
    def __init__(self, responses: list[CommandResult]) -> None:
        self.responses = list(responses)
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        return self.responses.pop(0)


def _http(
    status: int,
    body: str = "",
    *,
    etag: str | None = None,
    remaining: int | None = None,
    reset: float = NOW + 3600,
    resource: str = "core",
) -> str:
    lines = [f"HTTP/2.0 {status} {'OK' if status == 200 else 'Not Modified'}"]
    if etag is not None:
        lines.append(f"Etag: {etag}")
    if remaining is not None:
        lines += [
            f"X-Ratelimit-Remaining: {remaining}",
            f"X-Ratelimit-Reset: {int(reset)}",
            f"X-Ratelimit-Resource: {resource}",
        ]
    return "\r\n".join(lines) + "\r\n\r\n" + body


def _client(
    tmp_path: Path, runner: StaticRunner, sleeps: list[float] | None = None
) -> GitHubCliClient:
    return GitHubCliClient(
        repo=tmp_path,
        runner=runner,
        cache_dir=tmp_path / "cache",
        now=lambda: NOW,
        sleep=(sleeps.append if sleeps is not None else (lambda _seconds: None)),
    )


def _spend(tmp_path: Path) -> list[dict[str, object]]:
    lines = (
        (tmp_path / "cache" / "spend.jsonl").read_text(encoding="utf-8").splitlines()
    )
    return [json.loads(line) for line in lines]


def test_governor_maps_remaining_to_decisions_per_resource() -> None:
    governor = QuotaGovernor(now=lambda: NOW)
    assert governor.decide("core") == (QuotaDecision.PROCEED, 0.0)
    governor.observe("core", QuotaSnapshot(remaining=799, reset_epoch=NOW + 60))
    assert governor.decide("core") == (QuotaDecision.SERVE_STALE, 0.0)
    governor.observe("core", QuotaSnapshot(remaining=49, reset_epoch=NOW + 300))
    assert governor.decide("core") == (QuotaDecision.WAIT_FOR_RESET, 300.0)
    assert governor.decide("graphql") == (QuotaDecision.PROCEED, 0.0)


def test_low_quota_serves_cached_body_without_network(tmp_path: Path) -> None:
    body = '[{"filename": "ops/a.py"}]'
    runner = StaticRunner(
        [CommandResult(("gh",), 0, _http(200, body, etag='"v1"', remaining=500), "")]
    )
    client = _client(tmp_path, runner)

    assert client.load_json(_ARGV) == json.loads(body)
    assert client.load_json(_ARGV) == json.loads(body)
    assert len(runner.calls) == 1
    assert _spend(tmp_path)[-1]["served"] == "stale-cache"


def test_exhausted_quota_waits_for_reset_before_next_network_call(
    tmp_path: Path,
) -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, "[1]", remaining=40, reset=NOW + 120), ""
            ),
            CommandResult(("gh",), 0, _http(200, "[2]", remaining=4000), ""),
        ]
    )
    sleeps: list[float] = []
    client = _client(tmp_path, runner, sleeps)

    assert client.load_json(_ARGV) == [1]
    assert client.load_json(_OTHER) == [2]
    assert sleeps == [120.0]


def test_quota_wait_beyond_budget_fails_closed(tmp_path: Path) -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, "[1]", remaining=40, reset=NOW + 99_999), ""
            )
        ]
    )
    client = _client(tmp_path, runner, [])

    assert client.load_json(_ARGV) == [1]
    with pytest.raises(DeliverySourceError, match="quota exhausted"):
        client.load_json(_OTHER)
    assert len(runner.calls) == 1


def test_spend_log_records_network_and_304_with_quota_fields(tmp_path: Path) -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, "[1]", etag='"v1"', remaining=4000), ""
            ),
            CommandResult(("gh",), 0, _http(304, etag='"v1"', remaining=3999), ""),
        ]
    )
    client = _client(tmp_path, runner)

    assert client.load_json(_ARGV) == [1]
    assert client.load_json(_ARGV) == [1]

    records = _spend(tmp_path)
    assert [record["served"] for record in records] == ["network", "304"]
    assert records[1]["status"] == 304
    assert records[1]["remaining"] == "3999"
    assert {"ts", "endpoint", "resource"} <= set(records[0])


def test_responses_without_rate_limit_headers_write_no_spend_log(
    tmp_path: Path,
) -> None:
    client = _client(
        tmp_path, StaticRunner([CommandResult(("gh",), 0, '["plain"]', "")])
    )

    assert client.load_json(_ARGV) == ["plain"]
    assert not (tmp_path / "cache" / "spend.jsonl").exists()


def test_error_status_raises_and_is_never_cached(tmp_path: Path) -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 1, _http(404, '{"message":"Not Found"}', remaining=4000), ""
            )
        ]
    )
    client = _client(tmp_path, runner)

    with pytest.raises(AdapterCommandError):
        client.load_json(_ARGV)
    assert not (tmp_path / "cache" / "etag").exists()


_PR_LIST = ("gh", "pr", "list", "--state", "open", "--json", "number")


def test_304_without_cached_body_is_rejected_and_never_cached(tmp_path: Path) -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, _http(304, etag='"v1"', remaining=4000), ""),
            CommandResult(
                ("gh",), 0, _http(200, "[7]", etag='"v2"', remaining=3999), ""
            ),
        ]
    )
    client = _client(tmp_path, runner)

    with pytest.raises(AdapterPayloadError, match="304"):
        client.load_json(_ARGV)
    assert not (tmp_path / "cache" / "etag").exists()
    assert client.load_json(_ARGV) == [7]
    assert "If-None-Match" not in " ".join(runner.calls[1])


def test_subcommand_reads_wait_for_quota_reset_and_are_spend_logged(
    tmp_path: Path,
) -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, "[1]", remaining=40, reset=NOW + 120), ""
            ),
            CommandResult(("gh",), 0, '[{"number": 2}]', ""),
        ]
    )
    sleeps: list[float] = []
    client = _client(tmp_path, runner, sleeps)

    assert client.load_json(_ARGV) == [1]
    assert client.load_json(_PR_LIST) == [{"number": 2}]
    assert sleeps == [120.0]
    assert [record["served"] for record in _spend(tmp_path)] == [
        "network",
        "quota-wait",
        "network",
    ]


def test_subcommand_reads_have_no_stale_body_so_low_quota_still_hits_network(
    tmp_path: Path,
) -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, _http(200, "[1]", remaining=500), ""),
            CommandResult(("gh",), 0, '[{"number": 2}]', ""),
        ]
    )
    client = _client(tmp_path, runner)

    assert client.load_json(_ARGV) == [1]
    assert client.load_json(_PR_LIST) == [{"number": 2}]
    assert len(runner.calls) == 2


def test_subcommand_quota_wait_beyond_budget_fails_closed(tmp_path: Path) -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, "[1]", remaining=40, reset=NOW + 99_999), ""
            )
        ]
    )
    client = _client(tmp_path, runner, [])

    assert client.load_json(_ARGV) == [1]
    with pytest.raises(DeliverySourceError, match="quota exhausted"):
        client.load_json(_PR_LIST)
    assert len(runner.calls) == 1


_GRAPHQL_ARGV = ("gh", "api", "graphql", "-f", "query=query { viewer { login } }")


def test_graphql_body_without_etag_is_served_stale_under_low_quota(
    tmp_path: Path,
) -> None:
    body = '{"data": {"viewer": {"login": "bot"}}}'
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, body, remaining=500, resource="graphql"), ""
            )
        ]
    )
    client = _client(tmp_path, runner)

    assert client.load_json(_GRAPHQL_ARGV) == json.loads(body)
    assert client.load_json(_GRAPHQL_ARGV) == json.loads(body)
    assert len(runner.calls) == 1
    assert _spend(tmp_path)[-1]["served"] == "stale-cache"
