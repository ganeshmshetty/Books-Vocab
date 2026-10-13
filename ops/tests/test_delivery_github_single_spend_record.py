"""One gh read is admitted and recorded once: by the governed runner, never by the client.

#3361: ``GitHubCliClient`` used to carry its own ``QuotaGovernor`` and a second spend
ledger (``<cache>/spend.jsonl``) on top of ``GitHubQuotaGovernor``. Every conditional
read was therefore admitted twice and billed in two logs.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.github_client import GitHubCliClient
from delivery_control.adapters.github_governed_runner import govern_runner
from delivery_control.adapters.github_quota import GitHubQuotaGovernor
from delivery_control.ports.process import CommandResult

ENDPOINT = "repos/owner/name/pulls/7"
_PR_LIST = ("gh", "pr", "list", "--state", "open", "--json", "number")


def _probe_stdout(resource: str) -> str:
    return (
        "HTTP/2.0 200 OK\n"
        "Content-Type: application/json; charset=utf-8\n"
        "X-Ratelimit-Limit: 5000\n"
        "X-Ratelimit-Remaining: 5000\n"
        "X-Ratelimit-Reset: 9999\n"
        f"X-Ratelimit-Resource: {resource}\n"
        "\n"
        "{}\n"
    )


class FakeServer:
    """Budget probes, a conditional REST endpoint with an ETag, and one subcommand read."""

    def __init__(self) -> None:
        self.etag = '"v1"'
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        if argv[:3] == ("gh", "api", "-i"):
            resource = "graphql" if "graphql" in argv else "core"
            return CommandResult(argv, 0, _probe_stdout(resource), "")
        if "--include" in argv:
            if f"If-None-Match: {self.etag}" in argv:
                stdout = f"HTTP/2.0 304 Not Modified\nEtag: {self.etag}\n\n"
            else:
                stdout = (
                    "HTTP/2.0 200 OK\n"
                    "Content-Type: application/json\n"
                    f"Etag: {self.etag}\n"
                    "\n"
                    '{"body": "A"}\n'
                )
            return CommandResult(argv, 0, stdout, "")
        if argv[:2] == ("gh", "pr"):
            return CommandResult(argv, 0, '[{"number": 2}]', "")
        raise AssertionError(f"unexpected gh argv: {argv}")


def _client(tmp_path: Path, server: FakeServer) -> tuple[GitHubCliClient, Path]:
    spend_log = tmp_path / "github_spend.ndjson"
    governor = GitHubQuotaGovernor(repo=tmp_path, runner=server, spend_log=spend_log)
    client = GitHubCliClient(
        repo=tmp_path,
        runner=govern_runner(server, governor),
        cache_dir=tmp_path / "cache",
    )
    return client, spend_log


def _reads(spend_log: Path) -> list[dict[str, object]]:
    """Rows for served gh calls; probe rows are the governor's own budget checks."""
    rows = [json.loads(line) for line in spend_log.read_text().splitlines()]
    return [row for row in rows if row["outcome"] != "probe"]


def test_one_conditional_read_is_recorded_once_by_the_governor(tmp_path: Path) -> None:
    server = FakeServer()
    client, spend_log = _client(tmp_path, server)

    assert client.load_json(("gh", "api", ENDPOINT)) == {"body": "A"}

    assert [row["outcome"] for row in _reads(spend_log)] == ["network"]
    assert sum("--include" in call for call in server.calls) == 1
    assert not (tmp_path / "cache" / "spend.jsonl").exists()


def test_revalidated_304_read_adds_exactly_one_governed_record(tmp_path: Path) -> None:
    server = FakeServer()
    client, spend_log = _client(tmp_path, server)

    assert client.load_json(("gh", "api", ENDPOINT)) == {"body": "A"}
    assert client.load_json(("gh", "api", ENDPOINT)) == {"body": "A"}

    assert sum("--include" in call for call in server.calls) == 2
    assert len(_reads(spend_log)) == 2
    assert not (tmp_path / "cache" / "spend.jsonl").exists()


def test_subcommand_read_is_recorded_once_by_the_governor(tmp_path: Path) -> None:
    server = FakeServer()
    client, spend_log = _client(tmp_path, server)

    assert client.load_json(_PR_LIST) == [{"number": 2}]

    assert len(_reads(spend_log)) == 1
    assert not (tmp_path / "cache" / "spend.jsonl").exists()
