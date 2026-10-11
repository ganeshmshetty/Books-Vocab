"""Low-level argv-only GitHub CLI execution shared by adapter components."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ..ports.process import CommandResult, CommandRunnerPort
from .errors import AdapterCommandError, AdapterPayloadError

_READ_ONLY_JSON_COMMANDS = frozenset(
    {
        ("repo", "view"),
        ("issue", "list"),
        ("pr", "list"),
        ("pr", "view"),
        ("label", "list"),
    }
)
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


def _is_read_only_json_query(argv: tuple[str, ...]) -> bool:
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
        operation = query.lstrip()
        return operation.startswith(("query ", "query\t", "query\n", "query{", "{"))
    if endpoint is None:
        return False
    method = _option_value(argv, "--method", "-X")
    if method is not None:
        return method.upper() == "GET"
    return not _has_gh_api_input(argv)


def _is_transient_failure(result: CommandResult) -> bool:
    if result.timed_out:
        return True
    detail = f"{result.stdout}\n{result.stderr}".casefold()
    return any(marker in detail for marker in _TRANSIENT_ERROR_MARKERS)


class GitHubCliClient:
    def __init__(self, *, repo: Path, runner: CommandRunnerPort) -> None:
        self.repo = repo
        self.runner = runner
        self.last_command_attempts: tuple[CommandAttempt, ...] = ()

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
            and _is_read_only_json_query(argv)
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
        output = self._run_result(
            argv,
            allow_nonzero=allow_nonzero,
            retry_read_only=True,
        ).stdout.strip()
        try:
            return json.loads(output)
        except json.JSONDecodeError as error:
            raise AdapterPayloadError(f"invalid JSON from {' '.join(argv)}") from error
