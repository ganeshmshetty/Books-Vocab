"""Low-level argv-only GitHub CLI execution shared by adapter components."""

from __future__ import annotations

import hashlib
import json
import re
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ..domain.errors import DeliverySourceError
from ..ports.process import CommandResult, CommandRunnerPort
from .errors import AdapterCommandError, AdapterPayloadError
from .github_rate_governor import (
    QuotaDecision,
    QuotaGovernor,
    QuotaSnapshot,
)

_GRAPHQL_NON_QUERY_OPERATION = re.compile(r"\b(?:mutation|subscription)\b")
_READ_ONLY_JSON_COMMANDS = frozenset(
    {
        ("repo", "view"),
        ("issue", "list"),
        ("pr", "list"),
        ("pr", "view"),
        ("label", "list"),
    }
)
# Non-mutating reads that must reach the network every time: required-check status
# gates merges, so a cached "success" must never be replayed. They evict nothing either.
_LIVE_READ_COMMANDS = frozenset({("pr", "checks")})
_TRANSIENT_ERROR_MARKERS = (
    "tls handshake timeout",
    "connection reset",
    "connection refused",
    "temporary network failure",
    "temporary failure in name resolution",
    "network is unreachable",
)
_GH_API_INPUT_FLAGS = frozenset(("-f", "--field", "-F", "--raw-field", "--input"))
_GH_API_VALUE_FLAGS = frozenset(
    (
        "--cache",
        "--field",
        "-f",
        "--header",
        "-H",
        "--hostname",
        "--input",
        "--jq",
        "-q",
        "--method",
        "-X",
        "--preview",
        "--raw-field",
        "-F",
        "--template",
        "-t",
    )
)
_GH_API_FLAG_OPTIONS = frozenset(
    (
        "--help",
        "-h",
        "--include",
        "-i",
        "--paginate",
        "-p",
        "--silent",
        "--slurp",
        "--verbose",
    )
)


@dataclass(frozen=True)
class CommandAttempt:
    """Exact evidence for one subprocess attempt made by the client."""

    argv: tuple[str, ...]
    cwd: Path
    result: CommandResult


def _option_value(argv: tuple[str, ...], *options: str) -> str | None:
    for index, value in enumerate(argv):
        if value in options:
            return argv[index + 1] if index + 1 < len(argv) else None
        for option in options:
            if value.startswith(f"{option}="):
                return value.partition("=")[2]
    return None


def _has_gh_api_input(argv: tuple[str, ...]) -> bool:
    return any(
        value in _GH_API_INPUT_FLAGS
        or value.startswith(("--field=", "--raw-field=", "--input=", "-f", "-F"))
        for value in argv
    )


def _gh_api_endpoint(argv: tuple[str, ...]) -> str | None:
    if len(argv) < 2 or argv[0] != "gh" or argv[1] != "api":
        return None
    index = 2
    while index < len(argv):
        value = argv[index]
        if value == "--":
            return argv[index + 1] if index + 1 < len(argv) else None
        if value in _GH_API_VALUE_FLAGS:
            index += 2
            continue
        if value.startswith("--"):
            option = value.partition("=")[0]
            if option in _GH_API_VALUE_FLAGS or option in _GH_API_FLAG_OPTIONS:
                index += 1
                continue
            if value in _GH_API_FLAG_OPTIONS:
                index += 1
                continue
            return None
        if value in _GH_API_FLAG_OPTIONS:
            index += 1
            continue
        if value == "-X" or value == "-H":
            index += 2
            continue
        if value.startswith(("-f", "-F")) and len(value) > 2:
            index += 1
            continue
        if value.startswith("-"):
            return None
        return value
    return None


def _graphql_query(argv: tuple[str, ...]) -> str | None:
    query_values: list[str] = []
    index = 2
    while index < len(argv):
        value = argv[index]
        if value == "--input" or value.startswith("--input="):
            return None
        if value in {"-f", "--field", "-F", "--raw-field"}:
            if index + 1 >= len(argv):
                return None
            field = argv[index + 1]
            index += 2
        elif value.startswith(("--field=", "--raw-field=")):
            field = value.partition("=")[2]
            index += 1
        elif value.startswith(("-f", "-F")) and len(value) > 2:
            field = value[2:]
            index += 1
        else:
            index += 1
            continue
        if field.startswith("query="):
            query_values.append(field.partition("=")[2])
    if len(query_values) != 1 or not query_values[0].strip():
        return None
    return query_values[0]


def is_read_only_json_query(argv: tuple[str, ...]) -> bool:
    if (
        len(argv) >= 3
        and argv[0] == "gh"
        and (argv[1], argv[2]) in _READ_ONLY_JSON_COMMANDS
    ):
        return True
    if len(argv) < 2 or argv[0] != "gh" or argv[1] != "api":
        return False
    endpoint = _gh_api_endpoint(argv)
    if endpoint == "graphql":
        query = _graphql_query(argv)
        if query is None:
            return False
        # A document may hold several operations; one mutation or subscription anywhere
        # makes the whole request a non-read, whatever the first operation is.
        if _GRAPHQL_NON_QUERY_OPERATION.search(query):
            return False
        operation = query.lstrip()
        return operation.startswith(("query ", "query\t", "query\n", "query{", "{"))
    if endpoint is None:
        return False
    method = _option_value(argv, "--method", "-X")
    if method is not None:
        return method.upper() == "GET"
    return not _has_gh_api_input(argv)


def is_live_read_command(argv: tuple[str, ...]) -> bool:
    return (
        len(argv) >= 3 and argv[0] == "gh" and (argv[1], argv[2]) in _LIVE_READ_COMMANDS
    )


def _is_transient_failure(result: CommandResult) -> bool:
    if result.timed_out:
        return True
    detail = f"{result.stdout}\n{result.stderr}".casefold()
    return any(marker in detail for marker in _TRANSIENT_ERROR_MARKERS)


_HTTP_STATUS = re.compile(r"^HTTP/\S+\s+(\d{3})")
_MAX_QUOTA_WAIT_SECONDS = 3900.0


@dataclass(frozen=True)
class _Response:
    """A response parsed from ``gh api --include`` stdout."""

    status: int
    headers: Mapping[str, str]
    body: str


def _parse_include(stdout: str) -> _Response | None:
    if not stdout.startswith("HTTP/"):
        return None
    head, _, body = stdout.replace("\r\n", "\n").partition("\n\n")
    lines = head.split("\n")
    match = _HTTP_STATUS.match(lines[0])
    if match is None:
        return None
    headers = {
        name.strip().lower(): value.strip()
        for name, _, value in (line.partition(":") for line in lines[1:])
    }
    return _Response(int(match.group(1)), headers, body)


def _uncached_read_resources(argv: tuple[str, ...]) -> tuple[str, ...]:
    """Quota buckets an uncached read consumes; subcommands may draw on either."""

    endpoint = _gh_api_endpoint(argv)
    if endpoint == "graphql":
        return ("graphql",)
    if endpoint is not None:
        return ("core",)
    return ("core", "graphql")


def _is_api_read(argv: tuple[str, ...]) -> bool:
    """True for single-request, read-only ``gh api`` calls that can be conditional."""

    if len(argv) < 2 or argv[0] != "gh" or argv[1] != "api":
        return False
    if "--paginate" in argv or "--slurp" in argv:
        return False
    return _is_read_only_json_query(argv)


class GitHubCliClient:
    def __init__(
        self,
        *,
        repo: Path,
        runner: CommandRunnerPort,
        cache_dir: Path | None = None,
        now: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.repo = repo
        self.runner = runner
        self.last_command_attempts: tuple[CommandAttempt, ...] = ()
        self.cache_dir = cache_dir or repo / ".cache" / "delivery-control" / "github"
        self.governor = QuotaGovernor(now=now)
        self._now = now
        self._sleep = sleep

    def _run_result(
        self,
        argv: tuple[str, ...],
        *,
        allow_nonzero: bool = False,
        retry_read_only: bool = False,
    ) -> CommandResult:
        result = self.runner.run(argv, cwd=self.repo)
        attempts = [CommandAttempt(argv=argv, cwd=self.repo, result=result)]
        if (
            retry_read_only
            and is_read_only_json_query(argv)
            and _is_transient_failure(result)
        ):
            result = self.runner.run(argv, cwd=self.repo)
            attempts.append(CommandAttempt(argv=argv, cwd=self.repo, result=result))
        self.last_command_attempts = tuple(attempts)
        if result.exit_code != 0 and (not allow_nonzero or not result.stdout.strip()):
            raise AdapterCommandError(result)
        return result

    def run(self, argv: tuple[str, ...], *, allow_nonzero: bool = False) -> str:
        return self._run_result(argv, allow_nonzero=allow_nonzero).stdout.strip()

    def load_json(self, argv: tuple[str, ...], *, allow_nonzero: bool = False) -> Any:
        if _is_api_read(argv):
            output = self._load_api_read(argv, allow_nonzero=allow_nonzero)
        elif _is_read_only_json_query(argv):
            # Subcommand and paginated reads carry no response headers, so they
            # cannot be revalidated; they are still admitted by the quota gate
            # and recorded in the spend log.
            resources = _uncached_read_resources(argv)
            for resource in resources:
                self._admit_quota(argv, resource)
            output = self._run_result(
                argv, allow_nonzero=allow_nonzero, retry_read_only=True
            ).stdout.strip()
            self._spend(argv, "+".join(resources), "network")
        else:
            output = self._run_result(
                argv, allow_nonzero=allow_nonzero, retry_read_only=True
            ).stdout.strip()
        try:
            return json.loads(output)
        except json.JSONDecodeError as error:
            raise AdapterPayloadError(f"invalid JSON from {' '.join(argv)}") from error

    def _admit_quota(self, argv: tuple[str, ...], resource: str) -> None:
        """Block until the resource is out of its wait window, or fail closed."""

        decision, wait = self.governor.decide(resource)
        if decision is not QuotaDecision.WAIT_FOR_RESET:
            return
        if wait > _MAX_QUOTA_WAIT_SECONDS:
            raise DeliverySourceError(
                f"GitHub {resource} quota exhausted; reset in {wait:.0f}s "
                f"exceeds the {_MAX_QUOTA_WAIT_SECONDS:.0f}s wait budget"
            )
        self._spend(argv, resource, "quota-wait")
        self._sleep(wait)

    def _load_api_read(self, argv: tuple[str, ...], *, allow_nonzero: bool) -> str:
        """Serve a ``gh api`` read through quota governance and ETag revalidation."""

        resource = "graphql" if _gh_api_endpoint(argv) == "graphql" else "core"
        key = hashlib.sha256(json.dumps(list(argv)).encode("utf-8")).hexdigest()
        cached = self._cache_get(key)

        decision, _ = self.governor.decide(resource)
        if decision is QuotaDecision.SERVE_STALE and cached is not None:
            self._spend(argv, resource, "stale-cache")
            return cached[1]
        self._admit_quota(argv, resource)

        extra: tuple[str, ...] = ()
        if cached is not None and cached[0] is not None:
            extra = ("-H", f"If-None-Match: {cached[0]}")
        include = (argv[0], argv[1], "--include", *extra, *argv[2:])
        result = self._run_result(include, allow_nonzero=True, retry_read_only=True)
        response = _parse_include(result.stdout)
        if response is None:
            if result.exit_code != 0 and not allow_nonzero:
                raise AdapterCommandError(result)
            return result.stdout.strip()

        self._observe(resource, response)
        if response.status == 304:
            # 304 only answers a validator we sent; without a cached body it is
            # unusable and must not be stored as an empty entry.
            if cached is None:
                raise AdapterPayloadError(
                    f"GitHub returned 304 without a cached body for {' '.join(argv)}"
                )
            self._spend(argv, resource, "304", response)
            return cached[1]
        if response.status >= 400 or result.exit_code != 0:
            if not allow_nonzero:
                raise AdapterCommandError(result)
            return response.body.strip()

        body = response.body.strip()
        etag = response.headers.get("etag")
        self._cache_put(key, etag, body)
        self._spend(argv, resource, "network", response)
        return body

    def _observe(self, resource: str, response: _Response) -> None:
        try:
            snapshot = QuotaSnapshot(
                remaining=int(response.headers["x-ratelimit-remaining"]),
                reset_epoch=float(response.headers["x-ratelimit-reset"]),
            )
        except (KeyError, ValueError):
            return
        self.governor.observe(
            response.headers.get("x-ratelimit-resource", resource), snapshot
        )

    def _spend(
        self,
        argv: tuple[str, ...],
        resource: str,
        served: str,
        response: _Response | None = None,
    ) -> None:
        """Append one best-effort JSONL record; observability must not fail delivery."""

        record: dict[str, object] = {
            "ts": round(self._now(), 3),
            "resource": resource,
            "endpoint": _gh_api_endpoint(argv) or " ".join(argv[1:3]),
            "served": served,
        }
        if response is not None:
            record.update(
                status=response.status,
                remaining=response.headers.get("x-ratelimit-remaining"),
                reset=response.headers.get("x-ratelimit-reset"),
            )
        try:
            self.cache_dir.mkdir(parents=True, exist_ok=True)
            with (self.cache_dir / "spend.jsonl").open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, sort_keys=True) + "\n")
        except OSError:
            return

    def _cache_path(self, key: str) -> Path:
        return self.cache_dir / "etag" / f"{key}.json"

    def _cache_get(self, key: str) -> tuple[str | None, str] | None:
        try:
            raw = json.loads(self._cache_path(key).read_text(encoding="utf-8"))
            return raw["etag"], raw["body"]
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def _cache_put(self, key: str, etag: str | None, body: str) -> None:
        """Store a validated body, or drop the entry when the response had no ETag."""

        path = self._cache_path(key)
        try:
            if etag is None:
                path.unlink(missing_ok=True)
                return
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"etag": etag, "body": body}), encoding="utf-8")
        except OSError:
            return
