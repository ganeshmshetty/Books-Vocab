from __future__ import annotations

import importlib.util
import json
import shlex
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ops" / "agent_onboard.py"
SPEC = importlib.util.spec_from_file_location("agent_onboard", SCRIPT)
assert SPEC and SPEC.loader
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


def _local_commit(rev: str) -> str:
    return subprocess.run(
        ["git", "rev-parse", f"{rev}^{{commit}}"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


LANE_HEAD = _local_commit("HEAD")
LANE_BASE = _local_commit("HEAD~1")
# The review branch must resolve to exact HEAD; "HEAD" does even when detached.
LANE_BRANCH = subprocess.run(
    ["git", "rev-parse", "--abbrev-ref", "HEAD"],
    cwd=ROOT,
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()
ABSENT_SHA = "0123456789abcdef0123456789abcdef01234567"

EVIDENCE = {
    "lane-review": {
        "review branch": LANE_BRANCH,
        "exact HEAD": LANE_HEAD,
        "base SHA": LANE_BASE,
    },
    "direct-assignment": {
        "User/IM assignment": "audit the onboarding route",
        "acceptance": "route and tests are green",
        "structured Scope": "ops/agent_onboard.py and route tests",
        "dispatch_channel": "im",
        "dispatch_owner": "IM-1",
    },
    "issue": {
        "Issue assignment packet": "#boundary-contract",
        "Issue acceptance": "route and tests are green",
        "structured Scope": "ops/agent_onboard.py and route tests",
    },
    "pr-review": {
        "GitHub PR": "#123",
        "exact HEAD": "51ce9228ce64c1897850b8fcab672364b17f8731",
        "required checks": "context-routing",
    },
    "ds-pr-review": {
        "GitHub PR diff": "#123 diff",
        "changed paths": "ops/agent_onboard.py",
    },
    "release": {
        "explicit approval": "approved for dry-run only",
        "target": "test target",
        "rollback candidate": "previous test version",
        "health gate": "test health gate",
    },
    "merge": {
        "GitHub PR": "#123",
        "required checks": "context-routing",
        "CR/DS result": "review complete",
    },
    "issue-planning": {
        "GitHub Issue": "#123",
        "Issue priority/state labels": "P1 ready-for-solver",
    },
}


def test_worker_direct_assignment_loads_project_identity_skill_then_domain() -> None:
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="delivery",
        entry="direct-assignment",
        evidence=EVIDENCE["direct-assignment"],
    )

    assert payload["schema"] == "kg.agent_onboarding.v2"
    assert payload["status"] == "ready"
    assert payload["identity"]["id"] == "worker"
    assert "machine_role" not in payload["identity"]
    assert payload["task"]["entry"] == "direct-assignment"
    assert payload["skills"]["primary"] == "worktree-flow"
    assert "route_command" not in payload["skills"]
    assert payload["load_order"][0] == {
        "phase": "project",
        "required": True,
        "sources": ["docs/reference/project_onboarding.md"],
    }
    assert [step["phase"] for step in payload["load_order"]] == [
        "project",
        "identity",
        "assignment",
        "skill",
        "domain",
    ]
    assert (
        payload["assignment"]["evidence"]["acceptance"] == "route and tests are green"
    )
    assert len(payload["assignment"]["evidence_digest"]) == 64
    assert payload["authority"]["granted"] is False
    assert payload["assignment"]["dispatch"] == {
        "channel": "im",
        "discussion_with": "IM-1",
        "handback": {
            "policy": "same-dispatching-im",
            "requested_target": None,
            "resolved_target": "IM-1",
            "selection_required": False,
        },
    }


def test_worker_user_dispatch_discusses_with_user_and_hands_back_to_named_im() -> None:
    evidence = {
        **EVIDENCE["direct-assignment"],
        "dispatch_channel": "user",
        "handback_target": "IM-2",
    }
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="delivery",
        entry="direct-assignment",
        evidence=evidence,
    )

    assert payload["assignment"]["dispatch"] == {
        "channel": "user",
        "discussion_with": "User",
        "handback": {
            "policy": "specified-or-worker-selected-im",
            "requested_target": "IM-2",
            "resolved_target": "IM-2",
            "selection_required": False,
        },
    }


def test_worker_user_dispatch_requires_im_selection_before_hand_back_when_unspecified() -> (
    None
):
    evidence = {
        **EVIDENCE["direct-assignment"],
        "dispatch_channel": "user",
    }
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="delivery",
        entry="direct-assignment",
        evidence=evidence,
    )

    assert payload["assignment"]["dispatch"]["discussion_with"] == "User"
    assert payload["assignment"]["dispatch"]["handback"] == {
        "policy": "specified-or-worker-selected-im",
        "requested_target": None,
        "resolved_target": None,
        "selection_required": True,
    }


def test_worker_dispatch_contract_rejects_invalid_channel_or_mismatched_im() -> None:
    with pytest.raises(mod.OnboardingError, match="dispatch_channel"):
        mod.build_onboarding(
            ROOT,
            identity="Worker",
            intent="delivery",
            entry="direct-assignment",
            evidence={**EVIDENCE["direct-assignment"], "dispatch_channel": "cm"},
        )

    with pytest.raises(mod.OnboardingError, match="dispatch_owner"):
        mod.build_onboarding(
            ROOT,
            identity="Worker",
            intent="delivery",
            entry="direct-assignment",
            evidence={
                **EVIDENCE["direct-assignment"],
                "dispatch_channel": "im",
                "dispatch_owner": "CM",
            },
        )

    with pytest.raises(mod.OnboardingError, match="same dispatching IM"):
        mod.build_onboarding(
            ROOT,
            identity="Worker",
            intent="delivery",
            entry="direct-assignment",
            evidence={
                **EVIDENCE["direct-assignment"],
                "dispatch_channel": "im",
                "dispatch_owner": "IM-1",
                "handback_target": "IM-2",
            },
        )

    with pytest.raises(mod.OnboardingError, match="handback_target"):
        mod.build_onboarding(
            ROOT,
            identity="Worker",
            intent="delivery",
            entry="direct-assignment",
            evidence={
                **EVIDENCE["direct-assignment"],
                "dispatch_channel": "user",
                "handback_target": "CM",
            },
        )


def test_issue_solver_requires_issue_entry_and_domain_sources():
    payload = mod.build_onboarding(
        ROOT,
        identity="issue-solver",
        intent="backend",
        entry="issue",
        evidence=EVIDENCE["issue"],
    )

    assert payload["identity"]["id"] == "issue-solver"
    assert payload["task"]["intent"] == "backend"
    assert payload["task"]["skill_intent"] == "delivery-worktree"
    assert payload["assignment"]["required_external"] == [
        "Issue assignment packet",
        "Issue acceptance",
        "structured Scope",
    ]
    assert "docs/sop/backend.md" in payload["domain_sources"]


def test_ios_worker_loads_delivery_dependency_and_ios_specialist():
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="ios",
        entry="direct-assignment",
        evidence=EVIDENCE["direct-assignment"],
    )

    assert payload["skills"]["primary"] == "ios-simulator-verification"
    assert payload["skills"]["selected"] == [
        "kg-router",
        "worktree-flow",
        "ios-simulator-verification",
    ]


def test_ios_simulator_skill_trigger_excludes_non_ui_model_service_changes():
    # #3769: Worker ios routes to this skill by intent alone; the skill must itself
    # say that non-UI iOS model/service changes do not need Simulator evidence.
    text = (ROOT / ".claude/skills/ios-simulator-verification/SKILL.md").read_text(
        encoding="utf-8"
    )
    trigger = text.split("## 觸發與前置", 1)[1].split("## 固定執行路徑", 1)[0]

    assert "非 UI" in trigger
    assert "delivery-worktree" in trigger
    assert "unit tests" in trigger


def test_backend_worker_can_select_an_explicit_debug_specialist():
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="backend",
        entry="direct-assignment",
        specialist_intent="bug",
        evidence=EVIDENCE["direct-assignment"],
    )

    assert payload["task"]["skill_intent"] == "delivery-worktree"
    assert payload["task"]["specialist_intent"] == "bug"
    assert payload["task"]["effective_skill_intent"] == "bug"
    assert payload["skills"]["control_primary"] == "worktree-flow"
    assert payload["skills"]["primary"] == "app-debug"
    assert "control_route_command" not in payload["skills"]
    assert payload["skills"]["selected"] == ["kg-router", "worktree-flow", "app-debug"]
    assert "docs/sop/debug.md" in payload["domain_sources"]


def test_specialist_domain_sources_follow_the_effective_route():
    payload = mod.build_onboarding(
        ROOT,
        identity="Release operator",
        intent="release",
        entry="release",
        specialist_intent="podcast-publish",
        evidence=EVIDENCE["release"],
    )

    assert payload["skills"]["primary"] == "podcast-publish"
    assert "docs/sop/podcast_pipeline.md" in payload["domain_sources"]
    assert "docs/sop/podcast_pipeline.md" in payload["load_order"][-1]["sources"]


def test_cm_can_route_read_only_cost_analysis_without_loading_delivery_tools():
    payload = mod.build_onboarding(
        ROOT,
        identity="CM",
        intent="delivery",
        entry="coordination",
        specialist_intent="billing",
        evidence={
            "GitHub Issue/PR or direct assignment": "monthly cost review",
            "Scope decision": "read-only provider and baseline data",
        },
    )

    assert payload["skills"]["primary"] == "billing"
    assert payload["skills"]["selected"] == ["kg-router", "billing"]
    assert "docs/sop/cost_review.md" in payload["domain_sources"]


def test_specialist_route_is_identity_scoped():
    with pytest.raises(mod.OnboardingError, match="不允許 specialist"):
        mod.build_onboarding(
            ROOT,
            identity="DS",
            intent="docs",
            entry="pr-review",
            specialist_intent="bug",
            evidence=EVIDENCE["ds-pr-review"],
        )


def test_identity_intent_entry_mismatch_fails_closed():
    with pytest.raises(mod.OnboardingError, match="identity 不允許 intent"):
        mod.build_onboarding(
            ROOT, identity="Worker", intent="review", entry="pr-review"
        )

    with pytest.raises(mod.OnboardingError, match="entry 不符合 identity"):
        mod.build_onboarding(
            ROOT, identity="Issue Solver", intent="backend", entry="direct-assignment"
        )


@pytest.mark.parametrize(
    ("identity", "intent", "entry", "primary"),
    [
        ("CR", "review", "pr-review", "code-review"),
        ("CR", "review", "lane-review", "code-review"),
        ("DS", "docs", "pr-review", "kg-docs-control-plane"),
        ("Release operator", "release", "release", "source-command-release"),
        ("IM", "delivery", "issue-planning", "github-coordination"),
        ("CM", "release", "merge", "source-command-release"),
    ],
)
def test_every_canonical_identity_has_a_real_onboarding_route(
    identity, intent, entry, primary
):
    evidence_key = "ds-pr-review" if identity == "DS" else entry
    payload = mod.build_onboarding(
        ROOT,
        identity=identity,
        intent=intent,
        entry=entry,
        evidence=EVIDENCE[evidence_key],
    )
    assert payload["status"] == "ready"
    assert payload["skills"]["primary"] == primary
    assert [step["phase"] for step in payload["load_order"]] == [
        "project",
        "identity",
        "assignment",
        "skill",
        "domain",
    ]


@pytest.mark.parametrize(
    ("identity", "entry", "evidence_key"),
    [
        ("Worker", "direct-assignment", "direct-assignment"),
        ("Issue Solver", "issue", "issue"),
    ],
)
def test_implementers_may_read_github_but_never_write(
    identity, entry, evidence_key
) -> None:
    payload = mod.build_onboarding(
        ROOT,
        identity=identity,
        intent="delivery",
        entry=entry,
        evidence=EVIDENCE[evidence_key],
    )

    surfaces = payload["identity"]
    assert "github:read" in surfaces["allowed_surfaces"]
    # No forbidden surface may also cover reads; writes stay forbidden.
    assert not [s for s in surfaces["forbidden_surfaces"] if "read" in s]
    assert "github:any-mutation" in surfaces["forbidden_surfaces"]
    assert "GitHub read" in surfaces["owns"]


def test_lane_review_onboards_a_pre_pr_review_of_a_local_commit() -> None:
    payload = mod.build_onboarding(
        ROOT,
        identity="CR",
        intent="review",
        entry="lane-review",
        evidence=EVIDENCE["lane-review"],
    )

    assert payload["status"] == "ready"
    assert payload["assignment"]["required_external"] == [
        "review branch",
        "exact HEAD",
        "base SHA",
    ]
    assert payload["skills"]["primary"] == "code-review"


@pytest.mark.parametrize(
    ("key", "value", "reason"),
    [
        ("exact HEAD", "tip of lane-onboarding-v2", "40"),
        ("exact HEAD", LANE_HEAD[:12], "40"),
        ("exact HEAD", ABSENT_SHA, "git cat-file"),
        ("base SHA", "main", "40"),
        ("base SHA", ABSENT_SHA, "git cat-file"),
    ],
)
def test_lane_review_requires_full_shas_that_exist_locally(key, value, reason) -> None:
    with pytest.raises(mod.EvidenceError, match=reason) as excinfo:
        mod.build_onboarding(
            ROOT,
            identity="CR",
            intent="review",
            entry="lane-review",
            evidence={**EVIDENCE["lane-review"], key: value},
        )
    assert key in str(excinfo.value)


def _lane_review(**overrides):
    return mod.build_onboarding(
        ROOT,
        identity="CR",
        intent="review",
        entry="lane-review",
        evidence={**EVIDENCE["lane-review"], **overrides},
    )


def test_lane_review_branch_must_resolve_to_exact_head() -> None:
    # HEAD~1 is a real ref, but not the commit under review.
    with pytest.raises(mod.EvidenceError, match="review branch") as excinfo:
        _lane_review(**{"review branch": "HEAD~1"})
    assert "exact HEAD" in str(excinfo.value)


@pytest.mark.parametrize(
    "branch", ["no-such-branch-xyz", "-HEAD", "origin/no-such-xyz"]
)
def test_lane_review_branch_must_exist_locally(branch) -> None:
    with pytest.raises(mod.EvidenceError, match="review branch"):
        _lane_review(**{"review branch": branch})


def test_lane_review_base_must_be_an_ancestor_of_exact_head() -> None:
    # HEAD is not an ancestor of HEAD~1, so base=HEAD against head=HEAD~1 is a wrong base.
    with pytest.raises(mod.EvidenceError, match="base SHA") as excinfo:
        _lane_review(
            **{
                "review branch": "HEAD~1",
                "exact HEAD": LANE_BASE,
                "base SHA": LANE_HEAD,
            }
        )
    assert "ancestor" in str(excinfo.value)


def test_lane_review_next_action_has_no_pr_or_checks_wording() -> None:
    payload = _lane_review()
    assert "PR" not in payload["next_action"]
    assert "checks" not in payload["next_action"]
    assert "base" in payload["next_action"]


def test_pr_review_next_action_names_pr_diff_and_checks() -> None:
    payload = mod.build_onboarding(
        ROOT,
        identity="CR",
        intent="review",
        entry="pr-review",
        evidence=EVIDENCE["pr-review"],
    )
    assert "PR diff" in payload["next_action"]
    assert "required checks" in payload["next_action"]


@pytest.mark.parametrize(
    "pr", ["<5", "5>", "<#5", "<https://github.com/Books-Vocab/Books-Vocab/pull/5"]
)
def test_pr_review_rejects_unbalanced_angle_brackets(pr) -> None:
    with pytest.raises(mod.EvidenceError, match="GitHub PR"):
        mod.build_onboarding(
            ROOT,
            identity="CR",
            intent="review",
            entry="pr-review",
            evidence={**EVIDENCE["pr-review"], "GitHub PR": pr},
        )


@pytest.mark.parametrize(
    "pr",
    [
        "none",
        "N/A (pre-PR lane review)",
        "lane-onboarding-v2",
        "PR pending",
        "https://github.com/Books-Vocab/Books-Vocab/tree/main",
    ],
)
def test_pr_review_rejects_a_github_pr_that_is_not_a_pr_reference(pr) -> None:
    with pytest.raises(mod.EvidenceError, match="GitHub PR"):
        mod.build_onboarding(
            ROOT,
            identity="CR",
            intent="review",
            entry="pr-review",
            evidence={**EVIDENCE["pr-review"], "GitHub PR": pr},
        )


@pytest.mark.parametrize(
    "pr",
    [
        "#2123",
        "2123",
        "https://github.com/Books-Vocab/Books-Vocab/pull/2123",
        "<https://github.com/Books-Vocab/Books-Vocab/pull/2123>",
    ],
)
def test_pr_review_accepts_pr_number_or_url(pr) -> None:
    payload = mod.build_onboarding(
        ROOT,
        identity="CR",
        intent="review",
        entry="pr-review",
        evidence={**EVIDENCE["pr-review"], "GitHub PR": pr},
    )
    assert payload["status"] == "ready"


def test_pr_review_requires_a_full_exact_head() -> None:
    with pytest.raises(mod.EvidenceError, match="exact HEAD"):
        mod.build_onboarding(
            ROOT,
            identity="CR",
            intent="review",
            entry="pr-review",
            evidence={**EVIDENCE["pr-review"], "exact HEAD": "latest"},
        )


def test_invalid_review_value_is_reported_with_missing_keys() -> None:
    payload = mod.build_onboarding(
        ROOT,
        identity="CR",
        intent="review",
        entry="pr-review",
        evidence={"GitHub PR": "none"},
    )

    assert payload["status"] == "awaiting-assignment"
    assert payload["assignment"]["missing"] == ["exact HEAD", "required checks"]
    assert [problem["key"] for problem in payload["assignment"]["invalid"]] == [
        "GitHub PR"
    ]
    assert payload["assignment"]["evidence_template"]["GitHub PR"].startswith("<")
    assert "GitHub PR" in payload["assignment"]["evidence_spec"]["value_rules"]


def test_missing_project_onboarding_source_fails_closed(tmp_path: Path):
    manifest = (ROOT / "ops" / "context_plane.json").read_text(encoding="utf-8")
    (tmp_path / "ops").mkdir()
    (tmp_path / "ops" / "context_plane.json").write_text(manifest, encoding="utf-8")
    with pytest.raises(mod.OnboardingError, match="onboarding source"):
        mod.build_onboarding(
            tmp_path, identity="Worker", intent="delivery", entry="direct-assignment"
        )


def test_missing_assignment_evidence_blocks_before_skill_loading() -> None:
    payload = mod.build_onboarding(
        ROOT, identity="Worker", intent="delivery", entry="direct-assignment"
    )
    assert payload["status"] == "awaiting-assignment"
    assert payload["blocked_at"] == "assignment"
    assert payload["assignment"]["missing"] == [
        "User/IM assignment",
        "acceptance",
        "structured Scope",
        "dispatch_channel",
    ]
    assert [step["phase"] for step in payload["load_order"]] == [
        "project",
        "identity",
        "assignment",
    ]
    assert "skills" not in payload


def _fill_placeholders(value, key: str = ""):
    """Replace every template placeholder with a value a real assignment would carry."""
    if isinstance(value, dict):
        return {name: _fill_placeholders(item, name) for name, item in value.items()}
    if isinstance(value, list):
        return [_fill_placeholders(item, key) for item in value]
    if isinstance(value, str) and value.startswith("<") and value.endswith(">"):
        return {
            "dispatch_channel": "im",
            "dispatch_owner": "IM-1",
            "operation": "modify",
            "path": "ops/agent_onboard.py",
            "GitHub PR": "#123",
            "exact HEAD": LANE_HEAD,
            "base SHA": LANE_BASE,
            "review branch": LANE_BRANCH,
        }.get(key, f"filled {key}")
    return value


def _route_matrix() -> list[tuple[str, str, str]]:
    manifest = json.loads(
        (ROOT / "ops" / "context_plane.json").read_text(encoding="utf-8")
    )
    return [
        (definition["label"], definition["allowed_intents"][0], entry)
        for definition in manifest["identities"].values()
        for entry in definition["entry_modes"]
    ]


def test_missing_evidence_reports_every_key_and_a_ready_to_copy_template_at_once() -> (
    None
):
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="delivery",
        entry="direct-assignment",
        evidence={"dispatch_channel": "im"},
    )

    assignment = payload["assignment"]
    assert payload["status"] == "awaiting-assignment"
    # The conditional dispatch_owner is reported in the same round as the
    # manifest keys instead of surfacing as a later, separate error.
    assert assignment["missing"] == [
        "User/IM assignment",
        "acceptance",
        "structured Scope",
        "dispatch_owner",
    ]
    assert assignment["invalid"] == []
    assert assignment["evidence_spec"]["conditional"][0]["key"] == "dispatch_owner"
    assert assignment["evidence_spec"]["allowed_values"]["dispatch_channel"] == [
        "im",
        "user",
    ]
    template = assignment["evidence_template"]
    assert list(template) == [
        "User/IM assignment",
        "acceptance",
        "structured Scope",
        "dispatch_channel",
        "dispatch_owner",
    ]
    assert template["dispatch_channel"] == "im"
    assert template["structured Scope"]["schema"] == "kg.worktree.scope.v1"
    command = assignment["retry_command"]
    assert command.startswith(
        "./ops/agent_onboard.py --identity Worker --intent delivery --entry direct-assignment --evidence '"
    )
    assert command.endswith(" --json")


def test_invalid_values_are_reported_together_with_missing_keys() -> None:
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="delivery",
        entry="direct-assignment",
        evidence={"dispatch_channel": "cm"},
    )

    assert payload["status"] == "awaiting-assignment"
    assert payload["assignment"]["missing"] == [
        "User/IM assignment",
        "acceptance",
        "structured Scope",
    ]
    assert [problem["key"] for problem in payload["assignment"]["invalid"]] == [
        "dispatch_channel"
    ]


def test_non_string_dispatch_channel_is_invalid_not_ignored() -> None:
    with pytest.raises(mod.EvidenceError, match="dispatch_channel"):
        mod.build_onboarding(
            ROOT,
            identity="Worker",
            intent="delivery",
            entry="direct-assignment",
            evidence={**EVIDENCE["direct-assignment"], "dispatch_channel": 1},
        )


@pytest.mark.parametrize(("identity", "intent", "entry"), _route_matrix())
def test_unedited_template_fails_closed_and_filled_template_is_ready(
    identity, intent, entry
) -> None:
    template_payload = mod.build_evidence_template(
        ROOT, identity=identity, intent=intent, entry=entry
    )
    template = template_payload["evidence_template"]
    assert template_payload["schema"] == "kg.agent_onboarding.evidence_template.v1"
    assert set(template_payload["evidence_spec"]["required"]) <= set(template)

    # Copying the template verbatim must never satisfy the assignment boundary;
    # the keys are present, so they are reported as unfilled, not missing.
    unedited = mod.build_onboarding(
        ROOT, identity=identity, intent=intent, entry=entry, evidence=template
    )
    assert unedited["status"] == "awaiting-assignment"
    assert unedited["assignment"]["missing"] == []
    assert set(unedited["assignment"]["required_external"]) <= set(
        unedited["assignment"]["unfilled"]
    )

    filled = mod.build_onboarding(
        ROOT,
        identity=identity,
        intent=intent,
        entry=entry,
        evidence=_fill_placeholders(template),
    )
    assert filled["status"] == "ready"


def _emitted_placeholder(identity: str, intent: str, entry: str, key: str):
    return mod.build_evidence_template(
        ROOT, identity=identity, intent=intent, entry=entry
    )["evidence_template"][key]


def test_placeholder_left_in_an_optional_key_blocks_ready() -> None:
    placeholder = _emitted_placeholder(
        "Worker", "delivery", "direct-assignment", "dispatch_owner"
    )
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="delivery",
        entry="direct-assignment",
        evidence={
            **EVIDENCE["direct-assignment"],
            "dispatch_channel": "user",
            "dispatch_owner": placeholder,
        },
    )

    assert payload["status"] == "awaiting-assignment"
    assert payload["assignment"]["missing"] == []
    assert payload["assignment"]["unfilled"] == ["dispatch_owner"]
    assert "dispatch_owner" not in payload["assignment"]["evidence_template"]


def test_angle_bracketed_real_values_are_not_template_placeholders() -> None:
    # A Markdown autolink or a human "<none>" is evidence the caller wrote,
    # not a placeholder the template emitted.
    evidence = {
        **EVIDENCE["pr-review"],
        "GitHub PR": "<https://github.com/Books-Vocab/kg/pull/2070>",
        "note": "<none>",
    }
    payload = mod.build_onboarding(
        ROOT, identity="CR", intent="review", entry="pr-review", evidence=evidence
    )

    assert payload["status"] == "ready"
    assert payload["assignment"]["evidence"]["GitHub PR"] == evidence["GitHub PR"]


def test_retry_command_keeps_supplied_angle_bracketed_value() -> None:
    evidence = {
        "GitHub PR": "<https://github.com/Books-Vocab/kg/pull/2070>",
        "exact HEAD": EVIDENCE["pr-review"]["exact HEAD"],
    }
    payload = mod.build_onboarding(
        ROOT, identity="CR", intent="review", entry="pr-review", evidence=evidence
    )

    assignment = payload["assignment"]
    assert payload["status"] == "awaiting-assignment"
    assert assignment["missing"] == ["required checks"]
    assert assignment["unfilled"] == []
    assert assignment["evidence_template"]["GitHub PR"] == evidence["GitHub PR"]
    assert json.dumps(evidence["GitHub PR"]) in assignment["retry_command"]


def test_present_required_key_still_holding_its_placeholder_is_unfilled() -> None:
    scope = _emitted_placeholder(
        "Worker", "delivery", "direct-assignment", "structured Scope"
    )
    # Only the path was edited; the operation placeholder is still there.
    half_filled_scope = {
        **scope,
        "files": [{**scope["files"][0], "path": "ops/agent_onboard.py"}],
    }
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="delivery",
        entry="direct-assignment",
        evidence={
            **EVIDENCE["direct-assignment"],
            "acceptance": "<acceptance>",
            "structured Scope": half_filled_scope,
        },
    )

    assignment = payload["assignment"]
    assert payload["status"] == "awaiting-assignment"
    assert assignment["missing"] == []
    assert assignment["unfilled"] == ["acceptance", "structured Scope"]
    assert "acceptance" not in assignment["provided"]


def test_invalid_channel_does_not_hide_other_invalid_dispatch_values() -> None:
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="delivery",
        entry="direct-assignment",
        evidence={"dispatch_channel": "slack", "handback_target": "CM"},
    )

    assert payload["status"] == "awaiting-assignment"
    assert [problem["key"] for problem in payload["assignment"]["invalid"]] == [
        "dispatch_channel",
        "handback_target",
    ]
    # Every value to fix is a placeholder again, and an invalid channel counts
    # as undecided so dispatch_owner is offered in the same round.
    template = payload["assignment"]["evidence_template"]
    assert template["dispatch_channel"] == "<im|user>"
    assert template["handback_target"] == "<handback_target>"
    assert "dispatch_owner" in template


def test_invalid_only_evidence_names_every_invalid_value_in_one_error() -> None:
    with pytest.raises(mod.EvidenceError) as excinfo:
        mod.build_onboarding(
            ROOT,
            identity="Worker",
            intent="delivery",
            entry="direct-assignment",
            evidence={
                **EVIDENCE["direct-assignment"],
                "dispatch_channel": "slack",
                "handback_target": "CM",
            },
        )

    assert "dispatch_channel" in str(excinfo.value)
    assert "handback_target" in str(excinfo.value)


def test_evidence_template_validates_specialist_intent() -> None:
    template = mod.build_evidence_template(
        ROOT,
        identity="Worker",
        intent="backend",
        entry="direct-assignment",
        specialist_intent="bug",
    )
    assert template["task"]["specialist_intent"] == "bug"
    assert " --specialist-intent bug " in template["command"]

    with pytest.raises(mod.OnboardingError, match="specialist skill route 無法解析"):
        mod.build_evidence_template(
            ROOT,
            identity="Worker",
            intent="backend",
            entry="direct-assignment",
            specialist_intent="nonsense",
        )

    with pytest.raises(mod.OnboardingError, match="不允許 specialist"):
        mod.build_evidence_template(
            ROOT,
            identity="DS",
            intent="docs",
            entry="pr-review",
            specialist_intent="bug",
        )


def test_cli_template_with_unknown_specialist_fails_closed(capsys) -> None:
    code = mod.main(
        [
            "--identity",
            "Worker",
            "--intent",
            "backend",
            "--entry",
            "direct-assignment",
            "--specialist-intent",
            "nonsense",
            "--print-evidence-template",
        ]
    )

    assert code == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "nonsense" in captured.err


def test_cli_prints_evidence_template_without_assignment(capsys) -> None:
    code = mod.main(
        [
            "--identity",
            "Issue Solver",
            "--intent",
            "backend",
            "--entry",
            "issue",
            "--print-evidence-template",
            "--json",
        ]
    )

    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["evidence_spec"]["required"] == [
        "Issue assignment packet",
        "Issue acceptance",
        "structured Scope",
    ]
    assert payload["command"].startswith(
        "./ops/agent_onboard.py --identity 'Issue Solver' --intent backend --entry issue --evidence '"
    )


def test_cli_awaiting_assignment_names_every_missing_key_on_stderr(capsys) -> None:
    code = mod.main(
        [
            "--identity",
            "Worker",
            "--intent",
            "delivery",
            "--entry",
            "direct-assignment",
            "--json",
        ]
    )

    assert code == 3
    err = capsys.readouterr().err
    assert (
        "missing: User/IM assignment, acceptance, structured Scope, dispatch_channel"
        in err
    )
    # The last stderr line is the raw, unescaped command an agent can copy.
    assert err.splitlines()[-1].startswith(
        "./ops/agent_onboard.py --identity Worker --intent delivery --entry direct-assignment "
        '--evidence \'{"User/IM assignment":'
    )


def test_cli_plain_template_ends_with_unescaped_command(capsys) -> None:
    code = mod.main(
        [
            "--identity",
            "Worker",
            "--intent",
            "ios",
            "--entry",
            "direct-assignment",
            "--print-evidence-template",
        ]
    )

    assert code == 0
    lines = capsys.readouterr().out.splitlines()
    assert (
        lines[0]
        == "required: User/IM assignment, acceptance, structured Scope, dispatch_channel"
    )
    assert any(
        line.startswith("conditional: dispatch_owner (when dispatch_channel=im)")
        for line in lines
    )
    assert lines[-1].startswith(
        "./ops/agent_onboard.py --identity Worker --intent ios --entry direct-assignment --evidence '{"
    )


def test_cli_invalid_evidence_json_fails_closed_with_template_hint(capsys) -> None:
    code = mod.main(
        [
            "--identity",
            "Worker",
            "--intent",
            "delivery",
            "--entry",
            "direct-assignment",
            "--evidence",
            "{not json",
        ]
    )

    assert code == 2
    err = capsys.readouterr().err
    assert "--evidence" in err and "JSON" in err
    assert "--print-evidence-template" in err


def _worker_argv(*extra: str) -> list[str]:
    return [
        "--identity",
        "Worker",
        "--intent",
        "delivery",
        "--entry",
        "direct-assignment",
        *extra,
    ]


def test_cli_evidence_file_reaches_ready(tmp_path: Path, capsys) -> None:
    evidence_file = tmp_path / "evidence.json"
    evidence_file.write_text(
        json.dumps(EVIDENCE["direct-assignment"], ensure_ascii=False), encoding="utf-8"
    )

    code = mod.main(_worker_argv("--evidence-file", str(evidence_file), "--json"))

    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["status"] == "ready"
    assert payload["assignment"]["evidence"] == EVIDENCE["direct-assignment"]


def test_cli_evidence_file_retry_command_reuses_the_file(
    tmp_path: Path, capsys
) -> None:
    evidence_file = tmp_path / "evidence.json"
    evidence_file.write_text('{"dispatch_channel": "im"}', encoding="utf-8")

    code = mod.main(_worker_argv("--evidence-file", str(evidence_file), "--json"))

    assert code == 3
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    retry = payload["assignment"]["retry_command"]
    assert f"--evidence-file {evidence_file}" in retry
    assert "--evidence '" not in retry
    assert payload["assignment"]["evidence_file"] == str(evidence_file)
    assert captured.err.splitlines()[-1] == retry


@pytest.mark.parametrize(
    ("content", "message"),
    [("{not json", "不是合法 JSON"), ("[]", "JSON object")],
)
def test_cli_bad_evidence_file_fails_closed(
    tmp_path: Path, capsys, content, message
) -> None:
    evidence_file = tmp_path / "evidence.json"
    evidence_file.write_text(content, encoding="utf-8")

    code = mod.main(_worker_argv("--evidence-file", str(evidence_file)))

    assert code == 2
    err = capsys.readouterr().err
    assert "--evidence-file" in err and message in err


def test_cli_unreadable_evidence_file_fails_closed(tmp_path: Path, capsys) -> None:
    # A directory is not a file the agent can still go and write.
    code = mod.main(_worker_argv("--evidence-file", str(tmp_path)))

    assert code == 2
    err = capsys.readouterr().err
    assert "--evidence-file" in err and "無法讀取" in err


def test_cli_missing_evidence_file_prints_template_instead_of_failing(
    tmp_path: Path, capsys
) -> None:
    evidence_file = tmp_path / "not-written-yet.json"

    code = mod.main(_worker_argv("--evidence-file", str(evidence_file), "--json"))

    assert code == 3
    captured = capsys.readouterr()
    assignment = json.loads(captured.out)["assignment"]
    assert assignment["evidence_file"] == str(evidence_file)
    assert "User/IM assignment" in assignment["evidence_template"]
    assert f"--evidence-file {evidence_file}" in assignment["retry_command"]
    assert not evidence_file.exists()


def test_cli_rejects_inline_and_file_evidence_together(tmp_path: Path) -> None:
    evidence_file = tmp_path / "evidence.json"
    evidence_file.write_text("{}", encoding="utf-8")
    with pytest.raises(SystemExit) as excinfo:
        mod.main(
            _worker_argv("--evidence", "{}", "--evidence-file", str(evidence_file))
        )
    assert excinfo.value.code == 2


AGENT_TEMPLATES = sorted((ROOT / ".claude" / "agents").glob("*.md"))
SHELL_RULES_ANCHOR = "isolated-worktree-shell-rules"


def test_shell_rules_block_exists_in_project_onboarding() -> None:
    onboarding = (ROOT / "docs" / "reference" / "project_onboarding.md").read_text(
        encoding="utf-8"
    )
    assert f'<a id="{SHELL_RULES_ANCHOR}"></a>' in onboarding
    assert len(AGENT_TEMPLATES) >= 5


@pytest.mark.parametrize("template", AGENT_TEMPLATES, ids=lambda path: path.name)
def test_agent_template_onboards_via_evidence_file_and_shell_rules(template) -> None:
    text = template.read_text(encoding="utf-8")
    assert f"project_onboarding.md#{SHELL_RULES_ANCHOR}" in text

    commands = [
        line for line in text.splitlines() if line.startswith("./ops/agent_onboard.py")
    ]
    assert commands
    for command in commands:
        args = mod._parser().parse_args(shlex.split(command)[1:])
        assert args.evidence_file and args.evidence is None
        # Every listed route must be a real identity/intent/entry.
        mod.build_evidence_template(
            ROOT, identity=args.identity, intent=args.intent, entry=args.entry
        )
        if args.identity == "Worker":
            assert "dispatch_channel" in text and "dispatch_owner" in text


def test_missing_assignment_blocks_before_invalid_specialist_resolution() -> None:
    payload = mod.build_onboarding(
        ROOT,
        identity="Worker",
        intent="backend",
        entry="direct-assignment",
        specialist_intent="not-a-real-specialist",
    )
    assert payload["status"] == "awaiting-assignment"
    assert payload["blocked_at"] == "assignment"
    assert "skills" not in payload


ONBOARDING_DOCS = [
    ".claude/skills/code-review/SKILL.md",
    ".claude/skills/kg-docs-control-plane/SKILL.md",
    "docs/sop/review_discipline.md",
    "docs/sop/docs_dogfood.md",
    "docs/reference/agent_context.md",
]


@pytest.mark.parametrize("doc", ONBOARDING_DOCS)
def test_docs_show_evidence_file_not_inline_json_for_onboarding(doc) -> None:
    text = (ROOT / doc).read_text(encoding="utf-8")
    commands = [
        line
        for line in text.splitlines()
        if "ops/agent_onboard.py" in line and "--identity" in line
    ]
    assert commands or doc.endswith("agent_context.md")
    for line in commands:
        assert "--evidence '" not in line, f"{doc}: inline --evidence: {line}"


def test_code_review_skill_covers_both_entries_and_scopes_the_stop_rule() -> None:
    text = (ROOT / ".claude/skills/code-review/SKILL.md").read_text(encoding="utf-8")
    assert "--entry lane-review" in text and "--entry pr-review" in text
    assert "base..HEAD" in text or "<base SHA>..<exact HEAD>" in text
    stop_rule = next(line for line in text.splitlines() if "停止並回報缺口" in line)
    assert "pr-review" in stop_rule and "lane-review" in stop_rule


@pytest.mark.parametrize(
    "doc", ["docs/sop/review_discipline.md", "docs/reference/agent_context.md"]
)
def test_cr_onboarding_docs_list_both_review_entries(doc) -> None:
    text = (ROOT / doc).read_text(encoding="utf-8")
    assert "lane-review" in text


def test_root_claude_md_allows_worker_github_reads() -> None:
    text = (ROOT / "CLAUDE.md").read_text(encoding="utf-8")
    assert "不操作 GitHub" not in text
    assert "唯讀 gh" in text or "read-only gh" in text
