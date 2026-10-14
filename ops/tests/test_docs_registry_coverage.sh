#!/usr/bin/env bash
# Regression tests for docs registry coverage reporting.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/kg_docs_registry_coverage.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

./ops/docs_registry_coverage.py --help >"$tmpdir/help.out"
grep -q "active_unregistered" "$tmpdir/help.out"
grep -q "historical_unregistered" "$tmpdir/help.out"
grep -q "Exit nonzero only when active_unregistered docs exist" "$tmpdir/help.out"

./ops/docs_registry_coverage.py >"$tmpdir/coverage.out"
grep -q "docs_registry_coverage:" "$tmpdir/coverage.out"
grep -q "registered=" "$tmpdir/coverage.out"
grep -q "unregistered=" "$tmpdir/coverage.out"
grep -q "active_unregistered=" "$tmpdir/coverage.out"
grep -q "historical_unregistered=" "$tmpdir/coverage.out"
grep -q "no active registry debt; historical docs below are informational only" "$tmpdir/coverage.out"
grep -q "historical classification is path-based" "$tmpdir/coverage.out"
grep -q "HISTORICAL_UNREGISTERED" "$tmpdir/coverage.out"
grep -q "docs/plans/2026-05-23-notebook-editorial-stack.md" "$tmpdir/coverage.out"
if grep -q "^UNREGISTERED " "$tmpdir/coverage.out"; then
  echo "coverage human output should not duplicate historical entries as generic UNREGISTERED rows" >&2
  cat "$tmpdir/coverage.out" >&2
  exit 1
fi
if grep -q "ACTIVE_UNREGISTERED" "$tmpdir/coverage.out"; then
  echo "active docs should all be registered; only historical docs may remain unregistered" >&2
  cat "$tmpdir/coverage.out" >&2
  exit 1
fi
if grep -q "docs/sop/figma-token-workflow.md" "$tmpdir/coverage.out"; then
  echo "Figma token workflow is an active SOP and should be registered" >&2
  cat "$tmpdir/coverage.out" >&2
  exit 1
fi
if grep -q "docs/reference/feature_boundary/" "$tmpdir/coverage.out"; then
  echo "feature boundary docs should all be registered" >&2
  cat "$tmpdir/coverage.out" >&2
  exit 1
fi
if grep -Eq "docs/(sop/ui-design|reference/ui/)" "$tmpdir/coverage.out"; then
  echo "UI design docs should all be registered" >&2
  cat "$tmpdir/coverage.out" >&2
  exit 1
fi
if grep -Eq "docs/(runbook/system|reference/testing/(backend_strategy|smoke_checklist)|reference/cost_baseline|sop/(cost_review|review_discipline))\\.md" "$tmpdir/coverage.out"; then
  echo "agent-routed operational docs should all be registered" >&2
  cat "$tmpdir/coverage.out" >&2
  exit 1
fi
if grep -Eq "docs/(sop/(architecture|backup|backup_restore|i18n_lint|i18n_plural_keys|podcast_pipeline|llm_eval)|reference/llm_eval)\\.md" "$tmpdir/coverage.out"; then
  echo "agent-routed architecture/i18n/podcast/eval docs should all be registered" >&2
  cat "$tmpdir/coverage.out" >&2
  exit 1
fi

./ops/docs_registry_coverage.py --json >"$tmpdir/coverage.json"
grep -q '"registered_count"' "$tmpdir/coverage.json"
grep -q '"unregistered_by_tier"' "$tmpdir/coverage.json"
grep -q '"active_unregistered_count": 0' "$tmpdir/coverage.json"
grep -q '"historical_unregistered_count"' "$tmpdir/coverage.json"
grep -q '"historical_unregistered"' "$tmpdir/coverage.json"
grep -q '"docs/plans/2026-05-23-notebook-editorial-stack.md"' "$tmpdir/coverage.json"
if grep -q '"docs/sop/figma-token-workflow.md"' "$tmpdir/coverage.json"; then
  echo "Figma token workflow should be registered in JSON output" >&2
  cat "$tmpdir/coverage.json" >&2
  exit 1
fi
if grep -q '"docs/reference/feature_boundary/' "$tmpdir/coverage.json"; then
  echo "feature boundary docs should all be registered in JSON output" >&2
  cat "$tmpdir/coverage.json" >&2
  exit 1
fi
if grep -Eq '"docs/(sop/ui-design|reference/ui/)' "$tmpdir/coverage.json"; then
  echo "UI design docs should all be registered in JSON output" >&2
  cat "$tmpdir/coverage.json" >&2
  exit 1
fi
if grep -Eq '"docs/(runbook/system|reference/testing/(backend_strategy|smoke_checklist)|reference/cost_baseline|sop/(cost_review|review_discipline))\\.md' "$tmpdir/coverage.json"; then
  echo "agent-routed operational docs should all be registered in JSON output" >&2
  cat "$tmpdir/coverage.json" >&2
  exit 1
fi
if grep -Eq '"docs/(sop/(architecture|backup|backup_restore|i18n_lint|i18n_plural_keys|podcast_pipeline|llm_eval)|reference/llm_eval)\\.md' "$tmpdir/coverage.json"; then
  echo "agent-routed architecture/i18n/podcast/eval docs should all be registered in JSON output" >&2
  cat "$tmpdir/coverage.json" >&2
  exit 1
fi

./ops/docs_registry_coverage.py --strict >"$tmpdir/strict.out"
grep -q "active_unregistered=0" "$tmpdir/strict.out"

fixture_root="$tmpdir/fixture"
mkdir -p "$fixture_root/docs/sop" "$fixture_root/docs/plans"
cat >"$fixture_root/docs/registry.yml" <<'YAML'
documents: []
YAML
cat >"$fixture_root/docs/sop/unregistered-active.md" <<'MD'
<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - docs/
verified_against: HEAD
-->
# Active SOP
MD
cat >"$fixture_root/docs/plans/unregistered-historical.md" <<'MD'
<!-- doc-meta
tier: reference
authority: derived
update_trigger: plan-change
scope:
  - docs/
verified_against: HEAD
-->
# Historical plan
MD

if ./ops/docs_registry_coverage.py --root "$fixture_root" --registry docs/registry.yml --strict >"$tmpdir/fixture_strict_fail.out" 2>&1; then
  echo "fixture strict should fail when an active SOP is unregistered" >&2
  cat "$tmpdir/fixture_strict_fail.out" >&2
  exit 1
fi
grep -q "active_unregistered=1" "$tmpdir/fixture_strict_fail.out"

cat >"$fixture_root/docs/registry.yml" <<'YAML'
documents:
  - id: sop.fixture
    path: docs/sop/unregistered-active.md
    kind: sop
    authority: derived
    triggers:
      - fixture_changed
    sources:
      - docs/sop/unregistered-active.md
YAML

./ops/docs_registry_coverage.py --root "$fixture_root" --registry docs/registry.yml --strict >"$tmpdir/fixture_strict_pass.out"
grep -q "active_unregistered=0" "$tmpdir/fixture_strict_pass.out"
grep -q "historical_unregistered=1" "$tmpdir/fixture_strict_pass.out"
grep -q "no active registry debt; historical docs below are informational only" "$tmpdir/fixture_strict_pass.out"

# ── gitignored artifacts are not repo documents ──────────────────────────────
# A generated file that is produced on demand and gitignored (the ledger view, after
# IMP-20260807-b9526c) used to land in ACTIVE_UNREGISTERED the moment anyone ran its
# generator, turning --strict red for a debt nobody could pay: registering a
# gitignored path would then fail its own path check anywhere it had not been
# rendered.
#
# The SECOND case is the one that pins the design. The short fix — count only
# `git ls-files` — passes the first case and silently breaks this one: a doc that has
# been added but not committed is untracked, and that is precisely what coverage
# exists to catch. Without this assertion, "ignored-minus" and "tracked-only" are
# indistinguishable, and the wrong one fails in the direction nobody notices.
git_fixture="$tmpdir/gitfixture"
mkdir -p "$git_fixture/docs/sop"
git init -q "$git_fixture"
cat >"$git_fixture/docs/registry.yml" <<'YAML'
documents: []
YAML
printf 'docs/sop/generated.md\n' >"$git_fixture/.gitignore"
for f in generated brand-new; do
  cat >"$git_fixture/docs/sop/$f.md" <<'MD'
<!-- doc-meta
tier: sop
authority: derived
update_trigger: sop-change
scope:
  - docs/
verified_against: HEAD
-->
# Fixture SOP
MD
done

./ops/docs_registry_coverage.py --root "$git_fixture" --registry docs/registry.yml \
  >"$tmpdir/gitfixture.out" 2>&1 || true
if grep -q "docs/sop/generated.md" "$tmpdir/gitfixture.out"; then
  echo "a gitignored doc was counted as repo coverage debt" >&2
  cat "$tmpdir/gitfixture.out" >&2
  exit 1
fi
if ! grep -q "docs/sop/brand-new.md" "$tmpdir/gitfixture.out"; then
  echo "an untracked-but-not-ignored doc was NOT counted — the filter is tracked-only, not ignored-minus" >&2
  cat "$tmpdir/gitfixture.out" >&2
  exit 1
fi
grep -q "active_unregistered=1" "$tmpdir/gitfixture.out"

# ── sync_lifecycle doc-meta scope must be reachable from registry sources ─────
# contract.sync_lifecycle used to list only routers/ on the backend, so changes to
# the vocab API models, intake/crud modules and handlers were never flagged as an
# exact hit on the sync SoT (#3758). Every backend path in the doc-meta scope must
# now resolve to contract.sync_lifecycle as exact, and the vocabulary iOS boundary
# must no longer claim the backend router as its exact source.
sync_scope_paths=(
  backend/src/kg/api_models/vocab.py
  backend/src/kg/routers/vocab.py
  backend/src/kg/vocab_intake.py
  backend/src/kg/vocab_crud.py
  backend/src/kg/vocab_handlers/intake.py
  backend/src/kg/vocab_handlers/crud.py
)
for scope_path in "${sync_scope_paths[@]}"; do
  ./ops/docs_impact.py --files "$scope_path" >"$tmpdir/impact_sync.out" 2>&1 || true
  if ! grep -q "IMPACT contract.sync_lifecycle .*match_type=exact" "$tmpdir/impact_sync.out"; then
    echo "sync_lifecycle doc-meta scope path is not an exact registry source hit: $scope_path" >&2
    cat "$tmpdir/impact_sync.out" >&2
    exit 1
  fi
done

./ops/docs_impact.py --files backend/src/kg/routers/vocab.py >"$tmpdir/impact_vocab_router.out" 2>&1 || true
if grep -q "IMPACT reference.feature_boundary.vocabulary .*match_type=exact" "$tmpdir/impact_vocab_router.out"; then
  echo "iOS vocabulary feature boundary must not claim backend routers/vocab.py as an exact source" >&2
  cat "$tmpdir/impact_vocab_router.out" >&2
  exit 1
fi
