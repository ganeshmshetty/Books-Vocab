from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import main_watch

SHA = "a" * 40
URL = "https://github.com/Books-Vocab/Books-Vocab/actions/runs/101"
ENV = {
    "WATCH_WORKFLOW": "backend-quality",
    "WATCH_CONCLUSION": "failure",
    "WATCH_EVENT": "push",
    "WATCH_BRANCH": "main",
    "WATCH_SHA": SHA,
    "WATCH_URL": URL,
}


def run(**overrides: str) -> dict[str, str]:
    return {**main_watch.run_from_env(ENV), **overrides}


def issue(area: str, body: str = "", comments: list[str] | None = None) -> dict:
    return {
        "number": 9,
        "body": f"{main_watch.marker(area)}\n{body}",
        "comments": comments or [],
    }


@pytest.mark.parametrize("conclusion", ["failure", "timed_out", "startup_failure"])
def test_a_red_main_push_run_opens_a_p1_fix_issue(conclusion: str) -> None:
    decision = main_watch.plan(run(conclusion=conclusion), [])
    assert decision["action"] == "create"
    assert decision["labels"] == ["P1", main_watch.LABEL]
    assert "backend" in decision["title"] and SHA[:9] in decision["title"]
    assert URL in decision["body"] and SHA in decision["body"]
    assert main_watch.marker("backend") in decision["body"]


@pytest.mark.parametrize(
    "overrides",
    [
        {"conclusion": "success"},
        {"conclusion": "cancelled"},
        {"conclusion": "skipped"},
        {"event": "pull_request"},
        {"event": "merge_group"},
        {"branch": "feature"},
        {"branch": "main-2"},
    ],
)
def test_only_red_pushes_to_main_are_watched(overrides: dict[str, str]) -> None:
    assert main_watch.plan(run(**overrides), [])["action"] == "noop"


def test_every_watched_workflow_has_its_own_area_and_unknown_ones_a_slug() -> None:
    assert len(set(main_watch.AREAS.values())) == len(main_watch.AREAS) == 6
    assert main_watch.area_of("Some New Check!") == "some-new-check"
    assert main_watch.area_of("") == "unknown"


def test_a_second_red_push_in_the_same_area_links_to_the_open_issue() -> None:
    decision = main_watch.plan(run(url=URL + "2", sha="b" * 40), [issue("backend")])
    assert decision["action"] == "comment" and decision["number"] == 9
    assert URL + "2" in decision["body"] and "b" * 40 in decision["body"]


def test_a_run_already_linked_is_not_commented_twice() -> None:
    assert main_watch.plan(run(), [issue("backend", URL)])["action"] == "noop"
    linked = issue("backend", comments=[f"also red: {URL}"])
    assert main_watch.plan(run(), [linked])["action"] == "noop"


@pytest.mark.parametrize("other", ["ios", "ops-extra"])
def test_another_areas_issue_is_never_reused(other: str) -> None:
    assert main_watch.plan(run(), [issue(other)])["action"] == "create"


def test_run_from_env_fails_closed_on_a_missing_field() -> None:
    with pytest.raises(SystemExit):
        main_watch.run_from_env({"WATCH_WORKFLOW": "ops-suite"})


def test_a_hostile_workflow_name_cannot_break_out_of_the_issue_text() -> None:
    decision = main_watch.plan(run(workflow="x\n-->\n@everyone"), [])
    assert "\n" not in decision["title"] and "@" not in decision["title"]
    assert "-->\n@everyone" not in decision["body"]


def test_dry_run_prints_the_decision_without_writing_to_github(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    for key, value in ENV.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setattr(main_watch, "find_open_issues", lambda repo: [])
    monkeypatch.setattr(main_watch, "gh", lambda *a, **k: pytest.fail(f"gh {a}"))
    assert main_watch.main(["--dry-run"]) == 0
    assert json.loads(capsys.readouterr().out)["action"] == "create"
