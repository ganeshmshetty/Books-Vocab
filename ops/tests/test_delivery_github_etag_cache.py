"""GitHubCliClient ETag cache: a body is replayed only on a 304 to its own validator.

Quota admission and spend logging moved to the single governed runner (#3361); see
test_delivery_github_single_spend_record.py. This file pins the cache contract that
stays in the client.
"""

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
from delivery_control.ports.process import CommandResult

NOW = 1_000.0
_ARGV = ("gh", "api", "repos/owner/repo/pulls/12/files?per_page=100&page=1")
_OTHER = ("gh", "api", "repos/owner/repo/other")
_PR_LIST = ("gh", "pr", "list", "--state", "open", "--json", "number")
_GRAPHQL_ARGV = ("gh", "api", "graphql", "-f", "query=query { viewer { login } }")


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


def _client(tmp_path: Path, runner: StaticRunner) -> GitHubCliClient:
    return GitHubCliClient(
        repo=tmp_path,
        runner=runner,
        cache_dir=tmp_path / "cache",
        now=lambda: NOW,
    )


def test_cached_body_is_revalidated_by_etag_not_replayed(tmp_path: Path) -> None:
    # A PR's files cached at T0 must not be replayed at T0+120 after a new commit
    # changed them: the second read has to reach GitHub with the first validator.
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


def test_subcommand_reads_are_never_replayed_from_the_client(tmp_path: Path) -> None:
    # Subcommand reads carry no validator, so each one must reach the runner.
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
