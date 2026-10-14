#!/usr/bin/env -S uv run --python 3.13
"""Build the mandatory project -> identity -> assignment -> skill -> domain route."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any


OPS_DIR = Path(__file__).resolve().parent
if str(OPS_DIR) not in sys.path:
    sys.path.insert(0, str(OPS_DIR))

import context_route  # noqa: E402
import skill_route  # noqa: E402
from lib.worktree_scope import SCOPE_OPERATIONS, SCOPE_SCHEMA  # noqa: E402


SCHEMA = "kg.agent_onboarding.v2"
TEMPLATE_SCHEMA = "kg.agent_onboarding.evidence_template.v1"
TEMPLATE_HINT = "加 --print-evidence-template 取得此 identity/entry 的全部 evidence key 與可直接複製的範本"
PLACEHOLDER_RULE = (
    "replace every <...> placeholder the template emits; a key still holding one is "
    "reported as unfilled and blocks ready"
)
_SCOPE_PLACEHOLDER = {
    "schema": SCOPE_SCHEMA,
    "files": [
        {
            "path": "<repo-relative file path>",
            "operation": f"<{'|'.join(SCOPE_OPERATIONS)}>",
        }
    ],
}
# Keys whose shape or choices are not obvious from the name; every other key
# falls back to "<key>".
_PLACEHOLDERS: dict[str, Any] = {
    "structured Scope": _SCOPE_PLACEHOLDER,
    "Scope": _SCOPE_PLACEHOLDER,
    "dispatch_channel": f"<{'|'.join(context_route.WORKER_DISPATCH_CHANNELS)}>",
    "dispatch_owner": "<dispatching IM, e.g. IM-1>",
    "Issue assignment packet": "<Issue #N or URL, base SHA>",
    "exact HEAD": "<40-char commit SHA>",
    "base SHA": "<40-char base commit SHA>",
    "GitHub PR": "<PR number #N or https://github.com/OWNER/REPO/pull/N>",
    "review branch": "<local branch under review>",
}
_FULL_SHA = re.compile(r"[0-9a-f]{40}")
# A PR reference, optionally wrapped as a Markdown autolink (brackets balanced).
_PR_CORE = r"(?:#?[1-9]\d*|https://github\.com/[\w.-]+/[\w.-]+/pull/[1-9]\d*/?)"
_PR_REFERENCE = re.compile(rf"{_PR_CORE}|<{_PR_CORE}>")
_SHA_RULE = "full 40-char lowercase hex commit SHA"
_LOCAL_SHA_RULE = f"{_SHA_RULE} that exists locally (git cat-file -e <sha>^{{commit}})"
_PR_RULE = "real PR number (#N or N) or https://github.com/OWNER/REPO/pull/N; a pre-PR review uses entry lane-review"
# (identity, entry) -> evidence key -> (rule, must exist as a local commit).
_VALUE_RULES: dict[tuple[str, str], dict[str, tuple[str, bool]]] = {
    ("cr", "pr-review"): {
        "GitHub PR": (_PR_RULE, False),
        "exact HEAD": (_SHA_RULE, False),
    },
    ("cr", "lane-review"): {
        "exact HEAD": (_LOCAL_SHA_RULE, True),
        "base SHA": (_LOCAL_SHA_RULE, True),
    },
}


class OnboardingError(ValueError):
    """The agent cannot safely enter the requested task route."""


class EvidenceError(OnboardingError):
    """The supplied assignment evidence is malformed or carries an invalid value."""


def _template_value(key: str) -> Any:
    return _PLACEHOLDERS.get(key, f"<{key}>")


def _leaves(value: Any) -> list[Any]:
    if isinstance(value, dict):
        return [leaf for item in value.values() for leaf in _leaves(item)]
    if isinstance(value, list):
        return [leaf for item in value for leaf in _leaves(item)]
    return [value]


def _is_unfilled(key: str, value: Any) -> bool:
    """Whether value still holds a placeholder the template emits for key.

    Only the exact emitted placeholders count, so angle-bracketed evidence the
    caller wrote (a Markdown autolink, "<none>") stays evidence.
    """
    emitted = {
        leaf
        for leaf in _leaves(_template_value(key))
        if isinstance(leaf, str) and leaf.startswith("<") and leaf.endswith(">")
    }
    return any(
        isinstance(leaf, str) and leaf.strip() in emitted for leaf in _leaves(value)
    )


def _non_empty(value: Any) -> bool:
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, (dict, list)):
        return bool(value)
    return value is not None


def _evidence_value_present(key: str, value: Any) -> bool:
    return _non_empty(value) and not _is_unfilled(key, value)


def _next_action(role_def: dict[str, Any], entry: str) -> str:
    """Entry-specific guidance when the role defines it, else the role default."""
    return role_def.get("entry_next_action", {}).get(entry, role_def["next_action"])


def _root(root: Path | None) -> Path:
    return (root or OPS_DIR.parent).resolve()


def _identity_payload(definition: dict[str, Any], identity_id: str) -> dict[str, Any]:
    payload = {
        "id": identity_id,
        "label": definition["label"],
        "owns": definition["owns"],
        "not_owns": definition["not_owns"],
    }
    for key in ("allowed_surfaces", "forbidden_surfaces", "handoff_contract"):
        if key in definition:
            payload[key] = definition[key]
    return payload


def _is_im_target(value: Any) -> bool:
    return isinstance(value, str) and bool(
        re.fullmatch(r"im(?:[-_ ].+)?", value.strip(), re.IGNORECASE)
    )


def _is_worker_dispatch(identity_id: str, entry: str) -> bool:
    return identity_id == "worker" and entry == "direct-assignment"


def _dispatch_channel(evidence: dict[str, Any]) -> str | None:
    value = evidence.get("dispatch_channel")
    if not _evidence_value_present("dispatch_channel", value):
        return None
    # A non-string value is present but can never name a channel; keep it
    # visible so it is reported as invalid rather than silently ignored.
    return value.strip().casefold() if isinstance(value, str) else json.dumps(value)


def _evidence_spec(identity_id: str, entry: str, required: list[str]) -> dict[str, Any]:
    """Every evidence key the route reads: manifest keys plus the coded dispatch contract."""
    spec: dict[str, Any] = {
        "required": list(required),
        "conditional": [],
        "optional": [],
        "allowed_values": {},
        "value_rules": {
            key: rule
            for key, (rule, _) in _VALUE_RULES.get((identity_id, entry), {}).items()
        },
        "placeholder_rule": PLACEHOLDER_RULE,
    }
    if _is_worker_dispatch(identity_id, entry):
        spec["allowed_values"]["dispatch_channel"] = list(
            context_route.WORKER_DISPATCH_CHANNELS
        )
        spec["conditional"].append(
            {
                "key": "dispatch_owner",
                "required_when": {"dispatch_channel": "im"},
                "rule": "dispatching IM name (im, IM-<name>); hand-back returns to this IM; omit when dispatch_channel=user",
            }
        )
        spec["optional"].append(
            {
                "key": "handback_target",
                "rule": "IM name; must equal dispatch_owner when dispatch_channel=im; "
                "when dispatch_channel=user it names the hand-back IM, otherwise the Worker selects one before hand-back",
            }
        )
    return spec


def _applicable_keys(spec: dict[str, Any], evidence: dict[str, Any]) -> list[str]:
    """Required keys plus the conditional keys whose condition the evidence does not rule out."""
    keys = list(spec["required"])
    channel = _dispatch_channel(evidence)
    if channel not in context_route.WORKER_DISPATCH_CHANNELS:
        # An invalid channel decides nothing; keep its conditional keys visible.
        channel = None
    for conditional in spec["conditional"]:
        expected = conditional["required_when"]["dispatch_channel"]
        if channel is None or channel == expected:
            keys.append(conditional["key"])
    return keys


def _missing_evidence(spec: dict[str, Any], evidence: dict[str, Any]) -> list[str]:
    """Required (and triggered conditional) keys that are absent or empty.

    A key that is present but still holds a template placeholder is reported
    as unfilled instead.
    """
    channel = _dispatch_channel(evidence)
    keys = list(spec["required"])
    # An undecided channel is already reported; the conditional key is then
    # shown in the template instead of guessed as required.
    keys += [
        conditional["key"]
        for conditional in spec["conditional"]
        if channel == conditional["required_when"]["dispatch_channel"]
    ]
    return [key for key in keys if not _non_empty(evidence.get(key))]


def _unfilled_evidence(evidence: dict[str, Any]) -> list[str]:
    return [key for key, value in evidence.items() if _is_unfilled(key, value)]


def _evidence_template(
    spec: dict[str, Any],
    evidence: dict[str, Any],
    invalid_keys: frozenset[str] = frozenset(),
) -> dict[str, Any]:
    """Supplied values kept as written; every value the caller still has to fix is a placeholder."""
    template = {
        key: evidence[key]
        if _non_empty(evidence.get(key)) and key not in invalid_keys
        else _template_value(key)
        for key in _applicable_keys(spec, evidence)
    }
    for key, value in evidence.items():
        if key in template:
            continue
        if key in invalid_keys:
            template[key] = _template_value(key)
        elif _evidence_value_present(key, value):
            template[key] = value
    return template


def _onboard_command(
    identity_label: str,
    intent: str,
    entry: str,
    specialist_intent: str | None,
    evidence: dict[str, Any],
    evidence_file: str | None = None,
) -> str:
    """Copyable rerun command; with evidence_file the caller rewrites that file instead of inlining JSON."""
    argv = [
        "./ops/agent_onboard.py",
        "--identity",
        identity_label,
        "--intent",
        intent,
        "--entry",
        entry,
    ]
    if specialist_intent:
        argv += ["--specialist-intent", specialist_intent]
    if evidence_file is not None:
        argv += ["--evidence-file", evidence_file]
    else:
        argv += [
            "--evidence",
            json.dumps(evidence, ensure_ascii=False, separators=(",", ":")),
        ]
    argv.append("--json")
    return shlex.join(argv)


def _worker_dispatch_problems(
    identity_id: str, entry: str, evidence: dict[str, Any]
) -> list[dict[str, str]]:
    """Every invalid supplied dispatch value; absent values are missing and placeholders unfilled instead."""
    if not _is_worker_dispatch(identity_id, entry):
        return []
    problems: list[dict[str, str]] = []
    channel = _dispatch_channel(evidence)
    if channel is not None and channel not in context_route.WORKER_DISPATCH_CHANNELS:
        problems.append(
            {
                "key": "dispatch_channel",
                "reason": "worker direct assignment 的 dispatch_channel 必須是 im 或 user",
            }
        )
    owner = evidence.get("dispatch_owner")
    target = evidence.get("handback_target")
    if (
        channel == "im"
        and _evidence_value_present("dispatch_owner", owner)
        and not _is_im_target(owner)
    ):
        problems.append(
            {
                "key": "dispatch_owner",
                "reason": "IM dispatch 必須提供有效的 dispatch_owner",
            }
        )
    if target is not None and not _is_unfilled("handback_target", target):
        if not _is_im_target(target):
            problems.append(
                {"key": "handback_target", "reason": "handback_target 必須是 IM"}
            )
        elif (
            channel == "im"
            and _is_im_target(owner)
            and target.strip().casefold() != owner.strip().casefold()
        ):
            problems.append(
                {
                    "key": "handback_target",
                    "reason": "IM dispatch 的 handback_target 必須等於 same dispatching IM",
                }
            )
    return problems


def _local_commit_exists(root: Path, sha: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "cat-file", "-e", f"{sha}^{{commit}}"],
            cwd=root,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _rev_commit(root: Path, rev: str) -> str | None:
    """Full SHA the local ref resolves to, or None; a leading '-' is never a ref."""
    if rev.startswith("-"):
        return None
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def _is_ancestor(root: Path, ancestor: str, descendant: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", ancestor, descendant],
            cwd=root,
            capture_output=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _lane_review_problems(
    root: Path, evidence: dict[str, Any], already_invalid: set[str]
) -> list[dict[str, str]]:
    """review branch must resolve to exact HEAD and base SHA must be its ancestor.

    Skipped for any key already reported (absent, placeholder or malformed), so
    each defect is reported once.
    """
    branch = evidence.get("review branch")
    head = evidence.get("exact HEAD")
    base = evidence.get("base SHA")
    problems: list[dict[str, str]] = []
    head_ok = (
        "exact HEAD" not in already_invalid
        and _evidence_value_present("exact HEAD", head)
        and isinstance(head, str)
    )
    if _evidence_value_present("review branch", branch) and head_ok:
        branch_text = branch.strip() if isinstance(branch, str) else ""
        if _rev_commit(root, branch_text) != head.strip():
            problems.append(
                {
                    "key": "review branch",
                    "reason": f"review branch {branch_text!r} 必須是本機 ref 且指向 exact HEAD {head.strip()}；"
                    "branch 已前進或名稱錯誤時重新取得 HEAD 再重跑",
                }
            )
    if (
        head_ok
        and "base SHA" not in already_invalid
        and _evidence_value_present("base SHA", base)
        and isinstance(base, str)
        and not _is_ancestor(root, base.strip(), head.strip())
    ):
        problems.append(
            {
                "key": "base SHA",
                "reason": "base SHA 必須是 exact HEAD 的 ancestor（git merge-base --is-ancestor）",
            }
        )
    return problems


def _value_rule_problems(
    root: Path, identity_id: str, entry: str, evidence: dict[str, Any]
) -> list[dict[str, str]]:
    """Supplied values that break the route's format rule; absent and placeholder values are reported elsewhere."""
    problems: list[dict[str, str]] = []
    for key, (rule, must_exist) in _VALUE_RULES.get((identity_id, entry), {}).items():
        value = evidence.get(key)
        if not _evidence_value_present(key, value):
            continue
        text = value.strip() if isinstance(value, str) else ""
        pattern = _PR_REFERENCE if key == "GitHub PR" else _FULL_SHA
        if not pattern.fullmatch(text):
            problems.append({"key": key, "reason": f"{key} 必須是 {rule}"})
        elif must_exist and not _local_commit_exists(root, text):
            problems.append(
                {
                    "key": key,
                    "reason": f"{key} {text} 不是本機 commit（git cat-file -e 失敗）；先 fetch 該 branch 再重跑",
                }
            )
    if (identity_id, entry) == ("cr", "lane-review"):
        problems += _lane_review_problems(
            root, evidence, {problem["key"] for problem in problems}
        )
    return problems


def _evidence_problems(
    root: Path, identity_id: str, entry: str, evidence: dict[str, Any]
) -> list[dict[str, str]]:
    return _worker_dispatch_problems(
        identity_id, entry, evidence
    ) + _value_rule_problems(root, identity_id, entry, evidence)


def _resolve_worker_dispatch(
    identity_id: str, entry: str, evidence: dict[str, Any]
) -> dict[str, Any] | None:
    """Resolve discussion/hand-back recipients from evidence already checked by _worker_dispatch_problems."""
    if not _is_worker_dispatch(identity_id, entry):
        return None

    channel = _dispatch_channel(evidence)
    requested_target = evidence.get("handback_target")

    if channel == "im":
        dispatch_owner = evidence["dispatch_owner"]
        requested_im_target = (
            requested_target.strip() if isinstance(requested_target, str) else None
        )
        return {
            "channel": channel,
            "discussion_with": dispatch_owner.strip(),
            "handback": {
                "policy": context_route.WORKER_DISPATCH_CHANNELS[channel][
                    "handback_policy"
                ],
                "requested_target": requested_im_target,
                "resolved_target": dispatch_owner.strip(),
                "selection_required": False,
            },
        }

    target = requested_target.strip() if isinstance(requested_target, str) else None
    return {
        "channel": channel,
        "discussion_with": context_route.WORKER_DISPATCH_CHANNELS[channel][
            "discussion_with"
        ],
        "handback": {
            "policy": context_route.WORKER_DISPATCH_CHANNELS[channel][
                "handback_policy"
            ],
            "requested_target": target,
            "resolved_target": target,
            "selection_required": target is None,
        },
    }


def _route_context(
    root: Path, identity: str, intent: str, entry: str
) -> tuple[dict, dict, str, str]:
    """Load the manifest/catalog and fail closed on an identity/intent/entry mismatch."""
    try:
        manifest = context_route.load_manifest(root)
        catalog = skill_route.load_catalog(root)
        identity_id = context_route.canonical_agent_identity(manifest, identity)
        canonical_intent = context_route.canonical_intent(intent)
    except (context_route.ContextRouteError, skill_route.SkillCatalogError) as exc:
        raise OnboardingError(str(exc)) from exc

    identity_def = manifest["identities"][identity_id]
    if canonical_intent not in identity_def["allowed_intents"]:
        allowed = ", ".join(identity_def["allowed_intents"])
        raise OnboardingError(
            f"identity 不允許 intent: {identity_id} -> {canonical_intent}"
            f"（允許：{allowed}）"
        )
    if entry not in identity_def["entry_modes"]:
        allowed = ", ".join(identity_def["entry_modes"])
        raise OnboardingError(
            f"entry 不符合 identity: {identity_id} -> {entry}（允許：{allowed}）"
        )
    return manifest, catalog, identity_id, canonical_intent


def _resolve_specialist(
    catalog: dict,
    identity_def: dict[str, Any],
    identity_id: str,
    canonical_intent: str,
    entry: str,
    specialist_intent: str,
) -> dict[str, Any]:
    """Resolve a specialist route and fail closed unless identity/intent/entry allows it."""
    try:
        route = skill_route.resolve_route(catalog, specialist_intent)
    except skill_route.SkillCatalogError as exc:
        raise OnboardingError(
            f"specialist skill route 無法解析: {specialist_intent}: {exc}"
        ) from exc
    allowed_specialists = identity_def["specialist_routes"][canonical_intent][entry]
    if route["intent"] not in allowed_specialists:
        allowed = ", ".join(allowed_specialists) or "(none)"
        raise OnboardingError(
            f"identity/intent/entry 不允許 specialist: {identity_id}/{canonical_intent}/{entry} "
            f"-> {route['intent']}; allowed={allowed}"
        )
    return route


def _require_evidence_object(evidence: Any) -> dict[str, Any]:
    evidence = {} if evidence is None else evidence
    if not isinstance(evidence, dict):
        raise EvidenceError("assignment evidence 必須是 object")
    return evidence


def build_evidence_template(
    root: Path | None = None,
    *,
    identity: str,
    intent: str,
    entry: str,
    evidence: dict[str, Any] | None = None,
    specialist_intent: str | None = None,
    evidence_file: str | None = None,
) -> dict[str, Any]:
    """Every evidence key for identity/entry and a ready-to-copy --evidence template."""
    manifest, catalog, identity_id, canonical_intent = _route_context(
        _root(root), identity, intent, entry
    )
    evidence = _require_evidence_object(evidence)
    identity_def = manifest["identities"][identity_id]
    # The template's command must be one that can reach ready, so an unknown or
    # disallowed specialist fails here instead of after the evidence is filled.
    canonical_specialist_intent = (
        _resolve_specialist(
            catalog,
            identity_def,
            identity_id,
            canonical_intent,
            entry,
            specialist_intent,
        )["intent"]
        if specialist_intent is not None
        else None
    )
    spec = _evidence_spec(
        identity_id, entry, identity_def["assignment_requirements"][entry]
    )
    invalid_keys = frozenset(
        problem["key"]
        for problem in _evidence_problems(_root(root), identity_id, entry, evidence)
    )
    template = _evidence_template(spec, evidence, invalid_keys)
    return {
        "schema": TEMPLATE_SCHEMA,
        "identity": {"id": identity_id, "label": identity_def["label"]},
        "task": {
            "intent": canonical_intent,
            "entry": entry,
            "specialist_intent": canonical_specialist_intent,
        },
        "evidence_spec": spec,
        "evidence_template": template,
        "command": _onboard_command(
            identity_def["label"],
            canonical_intent,
            entry,
            canonical_specialist_intent,
            template,
            evidence_file,
        ),
    }


def build_onboarding(
    root: Path | None = None,
    *,
    identity: str,
    intent: str,
    entry: str,
    evidence: dict[str, Any] | None = None,
    specialist_intent: str | None = None,
    evidence_file: str | None = None,
) -> dict[str, Any]:
    manifest, catalog, identity_id, canonical_intent = _route_context(
        _root(root), identity, intent, entry
    )
    identity_def = manifest["identities"][identity_id]
    intent_def = manifest["intents"][canonical_intent]
    skill_intent = identity_def["skill_routes"][canonical_intent][entry]
    specialist_route_payload: dict[str, Any] | None = None
    canonical_specialist_intent: str | None = None
    domain_sources: list[str] = []
    for source in intent_def["sources"]:
        if source not in domain_sources:
            domain_sources.append(source)
    onboarding_source = manifest["onboarding"]["source"]
    role_def = manifest["roles"][identity_def["machine_role"]]
    required_external = identity_def["assignment_requirements"][entry]
    evidence = _require_evidence_object(evidence)
    spec = _evidence_spec(identity_id, entry, required_external)
    missing_external = _missing_evidence(spec, evidence)
    unfilled = _unfilled_evidence(evidence)
    invalid = _evidence_problems(_root(root), identity_id, entry, evidence)
    dispatch_resolution = None
    if not missing_external and not unfilled:
        if invalid:
            raise EvidenceError("; ".join(problem["reason"] for problem in invalid))
        dispatch_resolution = _resolve_worker_dispatch(identity_id, entry, evidence)
    base_load_order = [
        {"phase": "project", "required": True, "sources": [onboarding_source]},
        {"phase": "identity", "required": True, "sources": role_def["sources"]},
        {
            "phase": "assignment",
            "required": True,
            "sources": [],
            "required_external": required_external,
        },
    ]
    base_payload = {
        "schema": SCHEMA,
        "project": {
            "source": onboarding_source,
            "overview": "KG product surfaces, GitHub-native delivery control plane, and local coordinator boundary",
        },
        "identity": _identity_payload(identity_def, identity_id),
        "task": {
            "requested_intent": intent,
            "intent": canonical_intent,
            "skill_intent": skill_intent,
            "effective_skill_intent": canonical_specialist_intent or skill_intent,
            "specialist_intent": canonical_specialist_intent,
            "entry": entry,
        },
        "assignment": {
            "required_external": required_external,
            "provided": sorted(
                key
                for key in _applicable_keys(spec, evidence)
                if _evidence_value_present(key, evidence.get(key))
            ),
            "missing": missing_external,
            "evidence": evidence,
            "evidence_digest": hashlib.sha256(
                json.dumps(
                    evidence, ensure_ascii=False, sort_keys=True, separators=(",", ":")
                ).encode("utf-8")
            ).hexdigest(),
            "next_action": _next_action(role_def, entry),
        },
        "load_order": base_load_order,
        "authority": {
            "granted": False,
            "note": "onboarding 只建立上下文，不授予 GitHub、merge 或 production 權限",
        },
    }
    if dispatch_resolution is not None:
        base_payload["assignment"]["dispatch"] = dispatch_resolution
    if missing_external or unfilled:
        template = _evidence_template(
            spec, evidence, frozenset(problem["key"] for problem in invalid)
        )
        base_payload["assignment"].update(
            {
                "unfilled": unfilled,
                "invalid": invalid,
                "evidence_spec": spec,
                "evidence_template": template,
                "retry_command": _onboard_command(
                    identity_def["label"],
                    canonical_intent,
                    entry,
                    specialist_intent,
                    template,
                    evidence_file,
                ),
            }
        )
        if evidence_file is not None:
            base_payload["assignment"]["evidence_file"] = evidence_file
        rerun = (
            "write assignment.evidence_template to assignment.evidence_file with every placeholder filled"
            if evidence_file is not None
            else "fill every placeholder in assignment.evidence_template"
        )
        return {
            **base_payload,
            "status": "awaiting-assignment",
            "blocked_at": "assignment",
            "next_action": f"{rerun} and rerun assignment.retry_command "
            "before loading skills or domain docs",
        }

    # Assignment is the hard boundary. A cold agent with no assignment must
    # stop here even if it also supplied an invalid specialist string.
    if specialist_intent is not None:
        specialist_route_payload = _resolve_specialist(
            catalog,
            identity_def,
            identity_id,
            canonical_intent,
            entry,
            specialist_intent,
        )
        canonical_specialist_intent = specialist_route_payload["intent"]
        for source in manifest["specialist_sources"].get(
            canonical_specialist_intent, []
        ):
            if source not in domain_sources:
                domain_sources.append(source)

    try:
        control_route_payload = skill_route.resolve_route(catalog, skill_intent)
    except skill_route.SkillCatalogError as exc:
        raise OnboardingError(f"skill route 無法解析: {skill_intent}: {exc}") from exc
    effective_route_payload = specialist_route_payload or control_route_payload

    catalog_by_name = {skill["name"]: skill for skill in catalog["skills"]}
    skill_sources = [
        catalog_by_name[name]["path"] for name in effective_route_payload["skills"]
    ]
    skills_payload: dict[str, Any] = {
        "primary": effective_route_payload["primary"],
        "selected": effective_route_payload["skills"],
        "dependencies": effective_route_payload["dependencies"],
    }
    if specialist_route_payload is not None:
        skills_payload["control_primary"] = control_route_payload["primary"]
        skills_payload["specialist"] = {
            "intent": specialist_route_payload["intent"],
            "primary": specialist_route_payload["primary"],
            "selected": specialist_route_payload["skills"],
        }
    ready_assignment = {
        "required_external": required_external,
        "provided": base_payload["assignment"]["provided"],
        "missing": [],
        "evidence": evidence,
        "evidence_digest": base_payload["assignment"]["evidence_digest"],
        "next_action": _next_action(role_def, entry),
    }
    if dispatch_resolution is not None:
        ready_assignment["dispatch"] = dispatch_resolution
    return {
        **base_payload,
        "task": {
            **base_payload["task"],
            "effective_skill_intent": canonical_specialist_intent or skill_intent,
            "specialist_intent": canonical_specialist_intent,
        },
        "status": "ready",
        "assignment": ready_assignment,
        "skills": skills_payload,
        "domain_sources": domain_sources,
        "load_order": [
            *base_load_order,
            {"phase": "skill", "required": True, "sources": skill_sources},
            {"phase": "domain", "required": True, "sources": domain_sources},
        ],
        "next_action": _next_action(role_def, entry),
        "authority": {
            "granted": False,
            "note": "onboarding 只建立上下文，不授予 GitHub、merge 或 production 權限",
        },
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="build the mandatory KG agent onboarding route"
    )
    parser.add_argument("--identity", required=True)
    parser.add_argument("--intent", required=True)
    parser.add_argument("--entry", required=True)
    parser.add_argument(
        "--specialist-intent",
        help="optional canonical specialist route allowed by identity/intent/entry",
    )
    evidence = parser.add_mutually_exclusive_group()
    evidence.add_argument(
        "--evidence",
        help="JSON object containing every required assignment evidence field",
    )
    evidence.add_argument(
        "--evidence-file",
        help="path to a UTF-8 file holding the --evidence JSON object "
        "(preferred: avoids shell quoting of inline JSON)",
    )
    parser.add_argument(
        "--print-evidence-template",
        action="store_true",
        help="print every required/conditional/optional evidence key for identity/intent/entry "
        "and a ready-to-copy onboarding command, then exit 0 (loads no skill or domain docs)",
    )
    parser.add_argument("--root", type=Path)
    parser.add_argument("--json", action="store_true")
    return parser


def _template_text(template: dict[str, Any]) -> str:
    """Plain-text template view whose last line is the unescaped, ready-to-copy command."""
    spec = template["evidence_spec"]
    lines = [f"required: {', '.join(spec['required'])}"]
    for item in spec["conditional"]:
        condition = ", ".join(
            f"{key}={value}" for key, value in item["required_when"].items()
        )
        lines.append(f"conditional: {item['key']} (when {condition}) - {item['rule']}")
    lines += [f"optional: {item['key']} - {item['rule']}" for item in spec["optional"]]
    lines += [
        f"allowed {key}: {', '.join(values)}"
        for key, values in spec["allowed_values"].items()
    ]
    lines += [f"rule: {spec['placeholder_rule']}", template["command"]]
    return "\n".join(lines)


def _parse_evidence(
    raw: str | None, source: str = "--evidence"
) -> dict[str, Any] | None:
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise EvidenceError(f"{source} 不是合法 JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise EvidenceError(f"{source} 必須是 JSON object")
    return parsed


def _load_evidence(args: argparse.Namespace) -> dict[str, Any] | None:
    if args.evidence_file is None:
        return _parse_evidence(args.evidence)
    source = f"--evidence-file {args.evidence_file}"
    try:
        raw = Path(args.evidence_file).read_text(encoding="utf-8")
    except FileNotFoundError:
        # Not written yet: same as an empty assignment, so the template is printed
        # and the retry command points at the file the agent is about to write.
        return None
    except (OSError, UnicodeDecodeError) as exc:
        raise EvidenceError(f"{source} 無法讀取: {exc}") from exc
    # An empty file is an absent assignment, reported as missing keys.
    return _parse_evidence(raw.strip(), source)


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    route = {
        "identity": args.identity,
        "intent": args.intent,
        "entry": args.entry,
        "evidence_file": args.evidence_file,
    }
    try:
        evidence = _load_evidence(args)
        if args.print_evidence_template:
            template = build_evidence_template(
                args.root,
                **route,
                evidence=evidence,
                specialist_intent=args.specialist_intent,
            )
            print(
                json.dumps(template, ensure_ascii=False, indent=2)
                if args.json
                else _template_text(template)
            )
            return 0
        payload = build_onboarding(
            args.root,
            **route,
            evidence=evidence,
            specialist_intent=args.specialist_intent,
        )
    except EvidenceError as exc:
        print(f"agent_onboard: ERROR: {exc}", file=sys.stderr)
        print(f"agent_onboard: hint: {TEMPLATE_HINT}", file=sys.stderr)
        return 2
    except OnboardingError as exc:
        print(f"agent_onboard: ERROR: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(payload, ensure_ascii=False, indent=2 if args.json else None))
    if payload["status"] == "ready":
        return 0
    assignment = payload["assignment"]
    problems = (
        [f"missing: {', '.join(assignment['missing'])}"]
        if assignment["missing"]
        else []
    )
    if assignment["unfilled"]:
        problems.append(f"unfilled placeholder: {', '.join(assignment['unfilled'])}")
    problems += [
        f"invalid {problem['key']}: {problem['reason']}"
        for problem in assignment["invalid"]
    ]
    print(f"agent_onboard: awaiting-assignment; {'; '.join(problems)}", file=sys.stderr)
    where = (
        f"in assignment.evidence_template and write it to {assignment['evidence_file']}"
        if "evidence_file" in assignment
        else "(assignment.retry_command)"
    )
    print(
        f"agent_onboard: replace every <...> placeholder {where}, then rerun:",
        file=sys.stderr,
    )
    print(assignment["retry_command"], file=sys.stderr)
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
