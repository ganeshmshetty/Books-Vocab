from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters import github_client
from delivery_control.adapters.errors import AdapterCommandError, AdapterPayloadError
from delivery_control.adapters.github_cache_root import github_cache_dir
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
    tmp_path: Path,
    runner: StaticRunner,
    sleeps: list[float] | None = None,
    *,
    now: float = NOW,
) -> GitHubCliClient:
    return GitHubCliClient(
        repo=tmp_path,
        runner=runner,
        cache_dir=tmp_path / "cache",
        now=lambda: now,
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
    assert governor.decide("core") == (QuotaDecision.PROCEED, 0.0)
    governor.observe("core", QuotaSnapshot(remaining=49, reset_epoch=NOW + 300))
    assert governor.decide("core") == (QuotaDecision.WAIT_FOR_RESET, 300.0)
    assert governor.decide("graphql") == (QuotaDecision.PROCEED, 0.0)


def test_cached_body_is_revalidated_by_etag_even_under_moderate_quota(
    tmp_path: Path,
) -> None:
    # Quota 700 is above the wait floor. A PR's files cached at T0 must not
    # decide admission at T0+120 after a new commit changed them.
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, '["ops/a.py"]', etag='"v1"', remaining=700), ""
            ),
            CommandResult(
                ("gh",),
                0,
                _http(200, '["ops/a.py", "backend/x.py"]', etag='"v2"', remaining=699),
                "",
            ),
        ]
    )
    client = _client(tmp_path, runner)

    assert client.load_json(_ARGV) == ["ops/a.py"]
    assert client.load_json(_ARGV) == ["ops/a.py", "backend/x.py"]
    assert len(runner.calls) == 2
    assert 'If-None-Match: "v1"' in runner.calls[1]
    assert _spend(tmp_path)[-1]["served"] == "network"


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


def test_http_response_without_rate_limit_headers_is_spend_logged_unquota(
    tmp_path: Path,
) -> None:
    runner = StaticRunner([CommandResult(("gh",), 0, _http(200, "[1]"), "")])
    client = _client(tmp_path, runner)

    assert client.load_json(_ARGV) == [1]
    record = _spend(tmp_path)[-1]
    assert record["served"] == "network"
    assert record["status"] == 200
    assert record["remaining"] is None


def test_quota_thresholds_are_inclusive_at_800_and_50() -> None:
    governor = QuotaGovernor(now=lambda: NOW)
    governor.observe("core", QuotaSnapshot(remaining=800, reset_epoch=NOW + 60))
    assert governor.decide("core") == (QuotaDecision.PROCEED, 0.0)
    governor.observe("core", QuotaSnapshot(remaining=799, reset_epoch=NOW + 60))
    assert governor.decide("core") == (QuotaDecision.PROCEED, 0.0)
    governor.observe("core", QuotaSnapshot(remaining=50, reset_epoch=NOW + 60))
    assert governor.decide("core") == (QuotaDecision.PROCEED, 0.0)
    governor.observe("core", QuotaSnapshot(remaining=49, reset_epoch=NOW + 60))
    assert governor.decide("core") == (QuotaDecision.WAIT_FOR_RESET, 60.0)


def test_fresh_client_seeds_low_quota_from_spend_log_and_waits(tmp_path: Path) -> None:
    first = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, "[1]", remaining=40, reset=NOW + 120), ""
            )
        ]
    )
    _client(tmp_path, first).load_json(_ARGV)
    sleeps: list[float] = []
    second = StaticRunner(
        [CommandResult(("gh",), 0, _http(200, "[2]", remaining=4000), "")]
    )

    assert _client(tmp_path, second, sleeps).load_json(_OTHER) == [2]
    assert sleeps == [120.0]


def test_seeded_quota_with_passed_reset_is_not_waited_on(tmp_path: Path) -> None:
    first = StaticRunner(
        [CommandResult(("gh",), 0, _http(200, "[1]", remaining=40, reset=NOW - 10), "")]
    )
    _client(tmp_path, first).load_json(_ARGV)
    sleeps: list[float] = []
    second = StaticRunner(
        [CommandResult(("gh",), 0, _http(200, "[2]", remaining=4000), "")]
    )

    assert _client(tmp_path, second, sleeps).load_json(_OTHER) == [2]
    assert sleeps == []


def test_cache_is_pruned_to_entry_cap(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(github_client, "_MAX_CACHE_ENTRIES", 2)
    argvs = (_ARGV, _OTHER, ("gh", "api", "repos/owner/repo/third"))
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, "[1]", etag=f'"v{i}"', remaining=4000), ""
            )
            for i in range(3)
        ]
    )
    client = _client(tmp_path, runner)
    for argv in argvs:
        client.load_json(argv)

    entries = list((tmp_path / "cache" / "etag").glob("*.json"))
    assert len(entries) == 2
    assert not list((tmp_path / "cache" / "etag").glob("*.tmp"))


def test_quota_wait_announces_itself_on_stderr(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, "[1]", remaining=40, reset=NOW + 120), ""
            ),
            CommandResult(("gh",), 0, '[{"number": 2}]', ""),
        ]
    )
    client = _client(tmp_path, runner)
    client.load_json(_ARGV)
    capsys.readouterr()

    client.load_json(_OTHER)
    assert "waiting 120s" in capsys.readouterr().err


def test_worktrees_of_one_git_common_dir_share_the_default_cache(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    common = tmp_path / "main" / ".git"
    for name in ("wt1", "wt2"):
        gitdir = common / "worktrees" / name
        gitdir.mkdir(parents=True)
        (gitdir / "commondir").write_text("../..\n", encoding="utf-8")
        worktree = tmp_path / name
        worktree.mkdir()
        (worktree / ".git").write_text(f"gitdir: {gitdir}\n", encoding="utf-8")

    assert github_cache_dir(tmp_path / "wt1") == github_cache_dir(tmp_path / "wt2")
    assert github_cache_dir(tmp_path / "wt1").is_relative_to(common)

    first = StaticRunner(
        [CommandResult(("gh",), 0, _http(200, "[1]", etag='"v1"', remaining=4000), "")]
    )
    GitHubCliClient(repo=tmp_path / "wt1", runner=first, now=lambda: NOW).load_json(
        _ARGV
    )
    second = StaticRunner(
        [CommandResult(("gh",), 0, _http(304, etag='"v1"', remaining=3999), "")]
    )
    client = GitHubCliClient(repo=tmp_path / "wt2", runner=second, now=lambda: NOW)

    assert client.load_json(_ARGV) == [1]
    assert 'If-None-Match: "v1"' in second.calls[0]


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


def test_subcommand_reads_have_no_cached_body_so_low_quota_still_hits_network(
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


def test_graphql_body_has_no_etag_so_every_read_hits_the_network(
    tmp_path: Path,
) -> None:
    body = '{"data": {"viewer": {"login": "bot"}}}'
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",), 0, _http(200, body, remaining=500, resource="graphql"), ""
            ),
            CommandResult(
                ("gh",), 0, _http(200, body, remaining=499, resource="graphql"), ""
            ),
        ]
    )
    client = _client(tmp_path, runner)

    assert client.load_json(_GRAPHQL_ARGV) == json.loads(body)
    assert client.load_json(_GRAPHQL_ARGV) == json.loads(body)
    assert len(runner.calls) == 2
    assert all("If-None-Match" not in call for call in runner.calls)
    assert [row["served"] for row in _spend(tmp_path)[-2:]] == ["network", "network"]


def test_seeding_reads_only_the_bounded_tail_of_a_large_spend_log(
    tmp_path: Path,
) -> None:
    cache = tmp_path / "cache"
    cache.mkdir()
    old_reading = {
        "ts": NOW,
        "resource": "core",
        "served": "network",
        "remaining": "40",
        "reset": str(NOW + 120),
    }
    filler = {
        "ts": NOW,
        "resource": "graphql",
        "served": "network",
        "remaining": None,
        "reset": None,
        "padding": "x" * 200,
    }
    lines = [json.dumps(old_reading)] + [json.dumps(filler)] * 2000
    (cache / "spend.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    sleeps: list[float] = []
    runner = StaticRunner(
        [CommandResult(("gh",), 0, _http(200, "[2]", remaining=4000), "")]
    )

    # The 40-remaining reading sits beyond the tail window, so it is not seeded.
    assert _client(tmp_path, runner, sleeps).load_json(_OTHER) == [2]
    assert sleeps == []


def test_spend_log_rotates_once_it_outgrows_its_cap(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(github_client, "_SPEND_ROTATE_BYTES", 64)
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / "spend.jsonl").write_text("x" * 128 + "\n", encoding="utf-8")
    runner = StaticRunner([CommandResult(("gh",), 0, _http(200, "[1]"), "")])

    assert _client(tmp_path, runner).load_json(_ARGV) == [1]

    assert (cache / "spend.jsonl.1").read_text(encoding="utf-8").startswith("xxx")
    assert len(_spend(tmp_path)) == 1
