"""Route every ``gh`` invocation of a GitHub adapter through one quota governor."""

from __future__ import annotations

from pathlib import Path

from ..ports.process import CommandResult, CommandRunnerPort
from .github_client import is_live_read_command, is_read_only_json_query
from .github_quota import CallKind, GitHubQuotaGovernor


def _call_kind(argv: tuple[str, ...]) -> CallKind:
    """Classify a gh argv; anything not provably a read counts as a mutation (fail safe)."""
    if is_read_only_json_query(argv):
        return "cached-read"
    if is_live_read_command(argv):
        return "live-read"
    return "mutation"


class GovernedCommandRunner:
    """CommandRunnerPort decorator: each gh argv passes the governor exactly once.

    Non-gh argv (git) is forwarded untouched because the governor budgets only the
    GitHub API. Both the raw runner and the governor's probe bypass this decorator,
    so a probe cannot recurse into itself.
    """

    def __init__(
        self, *, runner: CommandRunnerPort, governor: GitHubQuotaGovernor
    ) -> None:
        self._runner = runner
        self._governor = governor

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        if not argv or argv[0] != "gh":
            return self._runner.run(argv, cwd=cwd)
        result, _executed = self._governor.call(
            argv,
            kind=_call_kind(argv),
            execute=lambda: self._runner.run(argv, cwd=cwd),
        )
        return result


def govern_runner(
    runner: CommandRunnerPort, governor: GitHubQuotaGovernor | None
) -> CommandRunnerPort:
    return (
        runner
        if governor is None
        else GovernedCommandRunner(runner=runner, governor=governor)
    )
