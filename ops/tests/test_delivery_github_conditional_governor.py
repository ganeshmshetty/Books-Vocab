"""A conditional REST read must reach the network below the governor's stale-serve floor.

The lane's ETag path sends ``If-None-Match`` and trusts a 304 as "unchanged". The
main governor (``github_quota``) replays an identical ``cached-read`` argv from its
own cache below ``STALE_SERVE_BELOW``. Two identical conditional requests carry the
same validator, so the second one would be answered by replaying the first 304 and
the server-side change would stay hidden for up to ``STALE_CACHE_TTL_SECONDS``.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.github_client import GitHubCliClient
from delivery_control.adapters.github_governed_runner import govern_runner
from delivery_control.adapters.github_quota import (
    PROBE_TTL_SECONDS,
    STALE_SERVE_BELOW,
    GitHubQuotaGovernor,
)
from delivery_control.ports.process import CommandResult

ENDPOINT = "repos/owner/name/pulls/7"


def _probe_stdout(*, remaining: int, resource: str) -> str:
    """Stdout of ``gh api -i``: status line, rate-limit headers, blank line, body."""
    return (
        "HTTP/2.0 200 OK\n"
        "Content-Type: application/json; charset=utf-8\n"
        "X-Ratelimit-Limit: 5000\n"
        f"X-Ratelimit-Remaining: {remaining}\n"
        "X-Ratelimit-Reset: 9999\n"
        f"X-Ratelimit-Resource: {resource}\n"
        "\n"
        "{}\n"
    )


class ServerRunner:
    """Budget probes read the remaining quota; the REST resource honours ETags."""

    def __init__(self) -> None:
        self.remaining = 5_000
        self.body = "A"
        self.etag = '"v1"'
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        if argv[:3] == ("gh", "api", "-i"):
            resource = "graphql" if "graphql" in argv else "core"
            stdout = _probe_stdout(remaining=self.remaining, resource=resource)
            return CommandResult(argv, 0, stdout, "")
        if "--include" in argv:
            if f"If-None-Match: {self.etag}" in argv:
                stdout = f"HTTP/2.0 304 Not Modified\nEtag: {self.etag}\n\n"
                return CommandResult(argv, 0, stdout, "")
            stdout = (
                "HTTP/2.0 200 OK\n"
                "Content-Type: application/json\n"
                f"Etag: {self.etag}\n"
                "\n"
                f"{json.dumps({'body': self.body})}\n"
            )
            return CommandResult(argv, 0, stdout, "")
        raise AssertionError(f"unexpected gh argv: {argv}")


class FakeClock:
    def __init__(self) -> None:
        self.t = 1_000.0

    def now(self) -> float:
        return self.t

    def sleep(self, seconds: float) -> None:
        self.t += seconds


def test_identical_conditional_read_below_stale_serve_floor_sees_the_change(
    tmp_path: Path,
) -> None:
    server = ServerRunner()
    clock = FakeClock()
    governor = GitHubQuotaGovernor(
        repo=tmp_path,
        runner=server,
        spend_log=tmp_path / "spend.ndjson",
        clock=clock.now,
        sleep=clock.sleep,
    )
    client = GitHubCliClient(
        repo=tmp_path,
        runner=govern_runner(server, governor),
        cache_dir=tmp_path / "cache",
    )
    argv = ("gh", "api", ENDPOINT)

    assert client.load_json(argv) == {"body": "A"}
    # Unchanged on the server: the second request revalidates to 304 with the same
    # If-None-Match header, so the governor now holds that identical argv.
    assert client.load_json(argv) == {"body": "A"}

    server.body, server.etag = "B", '"v2"'
    server.remaining = STALE_SERVE_BELOW - 1
    clock.t += PROBE_TTL_SECONDS + 1

    assert client.load_json(argv) == {"body": "B"}
