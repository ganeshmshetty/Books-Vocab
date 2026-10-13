"""Low-level argv-only GitHub CLI execution shared by adapter components."""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ..ports.process import CommandResult, CommandRunnerPort
from .errors import AdapterCommandError, AdapterPayloadError
from .github_cache_root import github_cache_dir

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
_MAX_CACHE_ENTRIES = 2000


@dataclass(frozen=True)
class _CacheEntry:
    etag: str | None
    body: str
    fetched_at: float


@dataclass(frozen=True)
class _Response:
    """A response parsed from ``gh api --include`` stdout."""

    status: int
    headers: Mapping[str, str]
    body: str


def parse_include(stdout: str) -> _Response | None:
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


def _is_api_read(argv: tuple[str, ...]) -> bool:
    """True for single-request, read-only ``gh api`` calls that can be conditional."""

    if len(argv) < 2 or argv[0] != "gh" or argv[1] != "api":
        return False
    if "--paginate" in argv or "--slurp" in argv:
        return False
    return is_read_only_json_query(argv)


class GitHubCliClient:
    """Argv-only ``gh`` client; quota admission and spend logging belong to the runner.

    The runner handed in is the single governed chokepoint (``govern_runner``), so
    this client only revalidates REST reads by ETag and never keeps a second ledger.
    """

    def __init__(
        self,
        *,
        repo: Path,
        runner: CommandRunnerPort,
        cache_dir: Path | None = None,
        now: Callable[[], float] = time.time,
    ) -> None:
        self.repo = repo
        self.runner = runner
        self.last_command_attempts: tuple[CommandAttempt, ...] = ()
        # Fetch time of the body the last load_json returned; None for non-API reads.
        self.last_fetched_at: float | None = None
        self.cache_dir = cache_dir or github_cache_dir(repo)
        self._now = now

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

    def load_json(
        self,
        argv: tuple[str, ...],
        *,
        allow_nonzero: bool = False,
    ) -> Any:
        """Read JSON; every REST read revalidates live (ETag) or hits the network.

        A cached body is only ever sent back on a 304, so a head-dependent answer can
        never come from a body fetched before a push.
        """

        self.last_fetched_at = None
        if _is_api_read(argv):
            output = self._load_api_read(argv, allow_nonzero=allow_nonzero)
        elif is_read_only_json_query(argv):
            # Subcommand and paginated reads carry no response headers, so they
            # cannot be revalidated; the governed runner admits and records them.
            output = self._run_result(
                argv, allow_nonzero=allow_nonzero, retry_read_only=True
            ).stdout.strip()
        else:
            output = self._run_result(
                argv, allow_nonzero=allow_nonzero, retry_read_only=True
            ).stdout.strip()
        try:
            return json.loads(output)
        except json.JSONDecodeError as error:
            raise AdapterPayloadError(f"invalid JSON from {' '.join(argv)}") from error

    def _load_api_read(self, argv: tuple[str, ...], *, allow_nonzero: bool) -> str:
        """Serve a ``gh api`` read through ETag revalidation; the runner governs quota."""

        key = hashlib.sha256(json.dumps(list(argv)).encode("utf-8")).hexdigest()
        cached = self._cache_get(key)

        extra: tuple[str, ...] = ()
        if cached is not None and cached.etag is not None:
            extra = ("-H", f"If-None-Match: {cached.etag}")
        include = (argv[0], argv[1], "--include", *extra, *argv[2:])
        result = self._run_result(include, allow_nonzero=True, retry_read_only=True)
        fetched_at = self._now()
        self.last_fetched_at = fetched_at
        response = parse_include(result.stdout)
        if response is None:
            if result.exit_code != 0 and not allow_nonzero:
                raise AdapterCommandError(result)
            return result.stdout.strip()

        if response.status == 304:
            # 304 only answers a validator we sent; without a cached body it is
            # unusable and must not be stored as an empty entry.
            if cached is None:
                raise AdapterPayloadError(
                    f"GitHub returned 304 without a cached body for {' '.join(argv)}"
                )
            # GitHub just confirmed the body is current, so its age restarts here.
            self._cache_put(key, cached.etag, cached.body, fetched_at=fetched_at)
            return cached.body
        if response.status >= 400 or result.exit_code != 0:
            if not allow_nonzero:
                raise AdapterCommandError(result)
            return response.body.strip()

        body = response.body.strip()
        etag = response.headers.get("etag")
        # Without an ETag there is nothing to revalidate against, so nothing is kept.
        self._cache_put(key, etag, body, fetched_at=fetched_at)
        return body

    def _cache_path(self, key: str) -> Path:
        return self.cache_dir / "etag" / f"{key}.json"

    def _cache_get(self, key: str) -> _CacheEntry | None:
        try:
            raw = json.loads(self._cache_path(key).read_text(encoding="utf-8"))
            return _CacheEntry(
                etag=raw["etag"], body=raw["body"], fetched_at=float(raw["fetched_at"])
            )
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def _cache_put(
        self,
        key: str,
        etag: str | None,
        body: str,
        *,
        fetched_at: float,
    ) -> None:
        """Store a body that can be revalidated by ETag; drop an untagged entry."""

        path = self._cache_path(key)
        try:
            if etag is None:
                path.unlink(missing_ok=True)
                return
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = json.dumps({"etag": etag, "body": body, "fetched_at": fetched_at})
            # Write-then-rename: a concurrent reader sees the old or the new entry, never a torn one.
            descriptor, tmp_name = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(payload)
            os.replace(tmp_name, path)
        except OSError:
            return
        self._prune_cache(path.parent)

    def _prune_cache(self, directory: Path) -> None:
        """Bound etag/ growth by evicting the least recently written entries."""

        try:
            entries = list(directory.glob("*.json"))
            excess = len(entries) - _MAX_CACHE_ENTRIES
            if excess <= 0:
                return
            for stale in sorted(entries, key=lambda item: item.stat().st_mtime)[
                :excess
            ]:
                stale.unlink(missing_ok=True)
        except OSError:
            return
