from __future__ import annotations

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/agent-review.yml"


def _workflow() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def test_agent_review_runs_from_trusted_events_only() -> None:
    source = _workflow()

    assert "pull_request_target:" in source
    assert "pull_request_review:" in source
    assert "pull_request_review_comment:" in source
    assert "issue_comment:" in source
    assert "\n  pull_request:\n" not in source
    assert (
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1" in source
    )
    assert (
        "astral-sh/setup-uv@20cfd1bf945f4377ade1205e4dbc17946fc9a30d # v10.0.1"
        in source
    )
    assert "ref: ${{ github.event.repository.default_branch }}" in source
    assert "github.event.pull_request.head.sha" not in source
    assert "github.event.comment.body, '@codex review'" in source


def test_agent_review_has_read_only_source_permissions_and_check_write() -> None:
    source = _workflow()

    assert "contents: read" in source
    assert "issues: read" in source
    assert "pull-requests: read" in source
    assert "checks: write" in source
    assert "REVIEW_BOT: chatgpt-codex-connector[bot]" in source


def test_agent_review_is_bound_to_pr_head_and_emits_exact_check() -> None:
    source = _workflow()

    assert 'head_sha="$(jq -r' in source
    assert 'gh_api_retry "repos/$REPOSITORY/commits/$head_sha"' in source
    assert '--arg head_sha "$head_sha"' in source
    assert 'status:"completed"' in source
    assert "conclusion:$conclusion" in source
    assert "repos/$REPOSITORY/check-runs" in source


def test_agent_review_rejects_hard_findings_but_accepts_nonblocking_review() -> None:
    source = _workflow()

    assert "P(0|1)" in source
    assert "security" in source
    assert "blocker_evidence" in source
    assert 'review_evidence" -gt 0 || "$reviewed_issue_evidence" -gt 0' in source
    assert "P2" not in source


def test_agent_review_missing_evidence_is_neutral_advisory_not_failure() -> None:
    source = _workflow()

    assert (
        'create_check completed neutral "Independent agent review unavailable"'
        in source
    )
    assert (
        'create_check completed failure "Independent agent review is missing"'
        not in source
    )
    assert '"No exact-head review or fresh reviewer reaction' in source
    assert 'echo "Independent agent review unavailable' in source
    assert "exit 0" in source


def test_agent_review_evidence_has_one_required_check_identity() -> None:
    source = _workflow()

    # The workflow posts the optional ``agent-review`` check explicitly.  Its
    # Actions job must use a different name so the job and evidence remain
    # separately observable for quality diagnostics.
    assert "\n  agent-review:\n" not in source
    assert "\n  agent-review-evidence:\n" in source


def test_agent_review_emits_trusted_workflow_run_provenance() -> None:
    source = _workflow()

    assert "GITHUB_RUN_ID" in source
    assert "actions/runs/$GITHUB_RUN_ID" in source
    assert "external_id" in source
    assert "kg.agent-review.v1" in source
    assert "details_url" in source


def test_agent_review_accepts_exact_head_codex_issue_comment() -> None:
    source = _workflow()

    assert "issues/$PR_NUMBER/comments" in source
    assert "Reviewed commit" in source
    assert "reviewed_issue_evidence" in source


def test_agent_review_issue_comment_jq_predicates_compile() -> None:
    source = _workflow()
    assert "reviewed_issue_evidence" in source
    assert "issue_comment_blockers" in source

    predicates = (
        (
            '[.[] | select(.user.login == $bot and (.created_at // "") >= $since and '
            '((.body // "") | contains("**Reviewed commit:** `" + $prefix)))] | length'
        ),
        (
            '[.[] | select(.user.login == $bot and (.created_at // "") >= $since and '
            '((.body // "") | contains("**Reviewed commit:** `" + $prefix))) | (.body // "") '
            '| select(test("(^|[^[:alnum:]])P(0|1)([^[:alnum:]]|$)"))] | length'
        ),
    )
    for predicate in predicates:
        result = subprocess.run(
            [
                "jq",
                "-n",
                "--arg",
                "bot",
                "chatgpt-codex-connector[bot]",
                "--arg",
                "prefix",
                "0123456789",
                "--arg",
                "since",
                "2026-01-01T00:00:00Z",
                f"[] | {predicate}",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr


def test_agent_review_rechecks_trusted_codex_response_comments() -> None:
    source = _workflow()

    assert "github.event.comment.user.login == 'chatgpt-codex-connector[bot]'" in source
    assert "contains(github.event.comment.body, '**Reviewed commit:**')" in source


def test_agent_review_binds_inline_findings_to_exact_head_review() -> None:
    source = _workflow()

    # GitHub may expose an inline comment with the PR's latest commit id even
    # when the comment belongs to an older review.  Only comments linked to a
    # trusted review whose commit is the current head may block it.
    assert "current_review_ids" in source
    assert "pull_request_review_id" in source
    assert "review_ids | index($review_id)" in source


def test_agent_review_response_does_not_cancel_pr_event_poller() -> None:
    source = _workflow()

    assert (
        "group: agent-review-${{ github.event.pull_request.number || github.event.issue.number }}-${{ github.event_name }}"
        in source
    )


def _evidence_run_script() -> str:
    lines = _workflow().splitlines()
    start = next(
        i
        for i, line in enumerate(lines)
        if line.strip() == "- name: Evaluate exact-head independent review evidence"
    )
    run_idx = next(
        i for i in range(start, len(lines)) if lines[i].strip() == "run: |"
    )
    body: list[str] = []
    for line in lines[run_idx + 1 :]:
        if line.strip() and not line.startswith(" " * 10):
            break
        body.append(line[10:] if line.strip() else "")
    return "\n".join(body) + "\n"


_FAKE_GH = r"""#!/usr/bin/env bash
state="$STATE_DIR"
sha="$HEAD_SHA"
case "$*" in
  *check-runs*)
    jq -c . >>"$state/posts.jsonl"; echo '{}' ;;
  *pulls/7/reviews*)
    n=$(( $(cat "$state/reviews_calls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$state/reviews_calls"
    if [[ "$FAIL_REVIEWS" == always || ( "$FAIL_REVIEWS" =~ ^[0-9]+$ && "$n" -le "$FAIL_REVIEWS" ) ]]; then
      echo "gh: Server Error (HTTP 500)" >&2; exit 1
    fi
    echo "[[{\"user\":{\"login\":\"chatgpt-codex-connector[bot]\"},\"commit_id\":\"$sha\",\"state\":\"COMMENTED\",\"body\":\"ok\"}]]" ;;
  *pulls/7/comments*|*issues/7/comments*|*issues/7/reactions*)
    echo '[[]]' ;;
  *commits/*)
    echo '{"commit":{"committer":{"date":"2026-10-14T00:00:00Z"}}}' ;;
  *pulls/7)
    echo "{\"head\":{\"sha\":\"$sha\",\"ref\":\"feature\"}}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
"""


def _run_evidence_script(tmp_path: Path, fail_reviews: str) -> tuple[subprocess.CompletedProcess[str], list[dict]]:
    bin_dir = tmp_path / "bin"
    state = tmp_path / "state"
    bin_dir.mkdir()
    state.mkdir()
    (bin_dir / "gh").write_text(_FAKE_GH, encoding="utf-8")
    (bin_dir / "sleep").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    for name in ("gh", "sleep"):
        (bin_dir / name).chmod(0o755)
    script = tmp_path / "evidence.sh"
    script.write_text(_evidence_run_script(), encoding="utf-8")
    sha = "a" * 40
    env = {
        "PATH": f"{bin_dir}:/usr/bin:/bin:/opt/homebrew/bin",
        "STATE_DIR": str(state),
        "HEAD_SHA": sha,
        "FAIL_REVIEWS": fail_reviews,
        "RUNNER_TEMP": str(tmp_path),
        "GH_TOKEN": "x",
        "REPOSITORY": "o/r",
        "PR_NUMBER": "7",
        "EVIDENCE_AFTER": "2026-10-14T00:00:00Z",
        "REVIEW_BOT": "chatgpt-codex-connector[bot]",
        "REVIEW_BOT_CURRENT": "chatgpt-codex-connector",
        "GITHUB_RUN_ID": "12345",
    }
    result = subprocess.run(
        ["bash", str(script)], env=env, capture_output=True, text=True, check=False
    )
    posts_file = state / "posts.jsonl"
    posts = (
        [json.loads(line) for line in posts_file.read_text().splitlines()]
        if posts_file.exists()
        else []
    )
    return result, posts


def test_agent_review_aborted_evidence_finalizes_placeholder_as_neutral(
    tmp_path: Path,
) -> None:
    result, posts = _run_evidence_script(tmp_path, fail_reviews="always")

    assert result.returncode != 0, result.stdout + result.stderr
    assert posts[0]["status"] == "in_progress"
    last = posts[-1]
    assert last["status"] == "completed"
    assert last["conclusion"] == "neutral"
    assert last["name"] == "agent-review"
    assert last["head_sha"] == posts[0]["head_sha"]
    assert last["external_id"] == posts[0]["external_id"]
    assert last["external_id"] == "kg.agent-review.v1:12345:" + "a" * 40
    assert last["output"]["summary"].startswith("Exact head " + "a" * 40 + " ")
    assert sum(1 for p in posts if p["status"] == "completed") == 1


def test_agent_review_retries_transient_5xx_on_evidence_query(tmp_path: Path) -> None:
    result, posts = _run_evidence_script(tmp_path, fail_reviews="1")

    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "state" / "reviews_calls").read_text().strip() == "2"
    assert posts[0]["status"] == "in_progress"
    last = posts[-1]
    assert last["status"] == "completed"
    assert last["conclusion"] == "success"
    assert last["external_id"] == posts[0]["external_id"]
    assert sum(1 for p in posts if p["status"] == "completed") == 1
