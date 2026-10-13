#!/usr/bin/env bash
# Keep the hosted-Linux shard bootstrap narrow, fail-closed, and bounded.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/ops-suite.yml"

failures=0
fail() {
  printf '✗ %s\n' "$1" >&2
  failures=$((failures + 1))
}

bootstrap="$(
  awk '
    /^      - name: Verify tools the shard needs$/ { in_step=1; next }
    in_step && /^      - name: / { exit }
    in_step { print }
  ' "$WORKFLOW"
)"

if [[ -z "$bootstrap" ]]; then
  fail "ops-suite has no Linux shard tool-bootstrap step"
fi

require_bootstrap_literal() {
  local needle="$1"
  local description="$2"
  if ! grep -Fq -- "$needle" <<<"$bootstrap"; then
    fail "$description"
  fi
}

require_bootstrap_literal 'set -euo pipefail' "tool-bootstrap is not fail-closed"
require_bootstrap_literal 'declare -A packages=(' "tool-bootstrap has no explicit tool package map"
for mapping in '[rg]=ripgrep' '[jq]=jq' '[sqlite3]=sqlite3' '[python3]=python3' '[ssh]=openssh-client' '[zsh]=zsh'; do
  require_bootstrap_literal "$mapping" "tool-bootstrap omits explicit map entry: $mapping"
done
require_bootstrap_literal 'missing=()' "tool-bootstrap does not collect missing packages"
require_bootstrap_literal 'command -v "$command_name" >/dev/null 2>&1 || missing+=("${packages[$command_name]}")' "tool-bootstrap does not map missing commands to explicit packages"

if grep -Eq '(^|[[:space:]])apt(-get)?[[:space:]]' <<<"$bootstrap"; then
  fail "tool-bootstrap calls apt directly instead of the bounded retrying installer"
fi

# The installer owns timeout, retry and update bounds (ops/tests/test_ci_apt_install.sh).
bounded_install='./ops/ci_apt_install.sh "${missing[@]}"'
require_bootstrap_literal "$bounded_install" "missing-tool provisioning does not go through ops/ci_apt_install.sh"

install_count="$(grep -Fc 'ci_apt_install.sh' <<<"$bootstrap" || true)"
if [[ "$install_count" != 1 ]]; then
  fail "tool-bootstrap has broad or duplicate apt package installation"
fi

post_install_check='command -v "$command_name" >/dev/null 2>&1'
if ! awk -v bounded_install="$bounded_install" -v post_install_check="$post_install_check" '
  index($0, bounded_install) { provisioned=1; next }
  provisioned && index($0, post_install_check) { verified=1 }
  END { exit !verified }
' <<<"$bootstrap"; then
  fail "tool-bootstrap does not fail closed after bounded provisioning"
fi

if ! grep -Fq '      - name: Run assigned Linux ops groups' "$WORKFLOW"; then
  fail "ops-suite no longer runs assigned Linux groups after tool verification"
fi
if ! grep -Fq './ops/test_ops.sh "${selected[@]}"' "$WORKFLOW"; then
  fail "ops-suite no longer executes the assigned Linux groups"
fi

# --- Targeted PR fan-out (#3467) ----------------------------------------------
# The planner decides which Linux groups a PR runs. The merge group never
# targets: it stays on the full suite (merge-group-required.yml passes no scope).
PLAN="$ROOT/ops/ci_ops_suite_plan.py"
UV_CMD="${UV_BIN:-}"
if [[ -z "$UV_CMD" ]]; then
  if [[ -x "$HOME/.local/bin/uv" ]]; then UV_CMD="$HOME/.local/bin/uv"; else UV_CMD="uv"; fi
fi

# plan_for <scope> <changed paths...>: the planner's JSON on stdout.
plan_for() {
  local scope="$1"
  shift
  printf '%s\n' "$@" | "$UV_CMD" run --no-project --python 3.13 "$PLAN" --scope "$scope" --paths-stdin
}

# expect_plan <label> <scope> <jq filter> <changed paths...>
expect_plan() {
  local label="$1" scope="$2" filter="$3" out
  shift 3
  if ! out="$(plan_for "$scope" "$@")"; then
    fail "$label: planner did not run"
    return
  fi
  if ! jq -e "$filter" <<<"$out" >/dev/null; then
    fail "$label: planner returned $out"
  fi
}

linux_json="$("$ROOT/ops/tests/test_ops_ci_coverage.sh" --print-linux-groups | jq -R -s -c 'split("\n") | map(select(length > 0))')"

# Fixture paths for non-Python files are assembled at run time: the planner maps a
# non-Python path to every routed test that names it literally, and this file
# would otherwise name its own fixtures and select a group by accident.
doc_leaf="vocabulary.md"
docs_fixture="docs/reference/feature_boundary/$doc_leaf"
probe="new_tool"
unmapped_fixture="ops/unmapped_$probe.xyz"

# (a) backend-only and docs-only changes yield zero Linux shards.
expect_plan 'backend-only and docs-only change yields zero Linux groups' targeted \
  '.mode == "targeted" and .groups == [] and .shard_count == 0' \
  backend/src/kg/vocab_graph_ops.py "$docs_fixture"
# (b) ops/deliver.py yields the delivery-control group plus the contract groups.
expect_plan 'ops/deliver.py yields delivery-control plus the contract groups' targeted \
  '.mode == "targeted" and (.groups | sort) == ["delivery-control", "docs-lint", "ops-ci-coverage"] and .shard_count == 2' \
  ops/deliver.py
# (c) the dispatcher and the suite contract run the full suite.
expect_plan 'a change to ops/test_ops.sh runs the full suite' targeted \
  '.mode == "full" and .shard_count == 8' \
  ops/test_ops.sh
expect_plan 'a change to ops-suite.yml runs the full suite' targeted \
  '.mode == "full" and .shard_count == 8' \
  .github/workflows/ops-suite.yml
expect_plan 'a change to the router runs the full suite' targeted \
  '.mode == "full" and .shard_count == 8' \
  ops/ci_scope_router.sh
# (e) an unmapped ops path runs the full suite.
expect_plan 'unmapped ops path falls back to the full suite' targeted \
  '.mode == "full" and .shard_count == 8' \
  "$unmapped_fixture"
expect_plan 'ops module with no test reference falls back to the full suite' targeted \
  '.mode == "full" and .shard_count == 8' \
  ops/zz_unreferenced_module.py
# (f) a complexity budget fragment (one per ops lane) selects the groups that read the directory.
expect_plan 'complexity budget fragment selects the groups that read its directory' targeted \
  '.mode == "targeted" and (.groups | index("doctor")) != null and .shard_count == 2' \
  "ops/complexity_budget.d/probe_$probe.json"
# A range that is not two exact commit SHAs is a mapping error: fail safe to full.
bad_range="$("$UV_CMD" run --no-project --python 3.13 "$PLAN" --scope targeted --base not-a-sha --head also-not-a-sha 2>/dev/null || true)"
if ! jq -e '.mode == "full"' <<<"$bad_range" >/dev/null 2>&1; then
  fail "targeted scope with a non-SHA range does not fail safe to the full suite: $bad_range"
fi
# (d) the full scope ignores the diff: the merge group always gets every group.
expect_plan 'full scope runs every Linux group regardless of the diff' full \
  ".mode == \"full\" and .shard_count == 8 and .groups == $linux_json" \
  backend/src/kg/vocab_graph_ops.py
if ! [[ -f "$PLAN" ]]; then
  fail "ops/ci_ops_suite_plan.py is missing"
fi

# Workflow contract: the scope input defaults to full, pr-gate targets, merge group stays full.
ruby -ryaml -e '
  c = YAML.load_file(ARGV[0])
  trig = c["on"] || c[true]
  wc = trig.fetch("workflow_call")
  inp = wc.fetch("inputs")
  abort "scope input missing" unless inp.key?("scope")
  abort "scope does not default to full" unless inp["scope"]["default"] == "full"
  %w[base head].each { |k| abort "#{k} input missing" unless inp.key?(k) }
  abort "linux_group_count output missing" unless (wc["outputs"] || {}).key?("linux_group_count")
' "$WORKFLOW" || fail "ops-suite is not a targetable workflow_call (scope default full, base/head inputs, linux_group_count output)"

ruby -ryaml -e '
  w = YAML.load_file(ARGV[0])
  with = w.dig("jobs", "ops-suite", "with") || {}
  abort "pr-gate does not target the ops suite" unless with["scope"] == "targeted"
  abort "pr-gate omits the diff base" unless with.key?("base")
  abort "pr-gate omits the diff head" unless with.key?("head")
  abort "pr-gate stopped forwarding macos_ops" unless with.key?("macos_ops")
' "$ROOT/.github/workflows/pr-gate.yml" || fail "pr-gate does not pass targeted scope with its diff range to ops-suite"

ruby -ryaml -e '
  w = YAML.load_file(ARGV[0])
  with = (w.dig("jobs", "ops-suite", "with") || {})
  abort "merge group requests a targeted ops suite" if with.key?("scope") && with["scope"] != "full"
  abort "merge group lost the macos_ops pin" unless with["macos_ops"] == "false"
' "$ROOT/.github/workflows/merge-group-required.yml" || fail "merge group does not keep the full ops suite"

ruby -ryaml -e '
  w = YAML.load_file(ARGV[0])
  suite = w.dig("jobs", "suite") || {}
  cond = suite["if"].to_s
  abort "suite job is not skipped on an empty shard list" unless cond.include?("needs.discover.outputs.shards") && cond.include?("[]")
  env = suite["steps"].map { |st| st["env"] }.compact.find { |e| e.key?("SHARD_COUNT") } || {}
  abort "SHARD_COUNT is not derived from discover" unless env["SHARD_COUNT"].to_s.include?("needs.discover.outputs.shard-count")
  discover_uses = w.dig("jobs", "discover", "steps").map { |st| st["uses"].to_s }
  abort "discover cannot run the planner without uv" unless discover_uses.any? { |u| u.start_with?("astral-sh/setup-uv@") }
' "$WORKFLOW" || fail "ops-suite does not skip an empty shard list or derive its shard count from discover"

if ! grep -Fq 'ci_ops_suite_plan.py' "$WORKFLOW"; then
  fail "ops-suite discover does not call the targeting planner"
fi

if (( failures > 0 )); then
  printf 'ops-suite bootstrap contract: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'ops-suite bootstrap contract: PASS\n'
