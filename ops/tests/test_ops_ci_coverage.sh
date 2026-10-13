#!/usr/bin/env bash
# Keep the GitHub Actions ops-suite classification total and unambiguous.
#
# The test dispatcher is the source of truth for available groups. This file only
# answers which groups can run on the Linux Actions runner; it is not a second test
# router and it does not describe product work.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LINUX_GROUPS=(
  backup-verify devops deploy-smoke infra-health disk-guard reconcile sentry-release branch-audit
  exit-code-contract worktree delivery-control capability-matrix context-routing doctor ui-token plain-deadzone tap-a11y
  ui-deadcode ui-graph log-assert python-entrypoints
  lint-baselines injection-lint ui-fixture-lint ops-ci-coverage pipefail-echo-grep
  ui-quality-plane ui-quality-gate review-card-golden docs-lint gen-ios-baseline
  github-workflows
  ios-signal-traps ios-install-provenance ios-run-verdict ios-device-lock
  ios-cache-evict review-flip-probe ios-device-files ios-device-logs ios-test-discovery
  userland-portability script-help install-hooks lib-sourcing heavy-slots podcast-ops
  streaming-command app-review demo-data catalog-agent uitest-contact-sheet
  release ios-release sim-pool-disposable review-probe
  sentry-tool
  worktree-extended ios-ui-review review-preflight lab-podcast asc
)

# Groups intentionally executed by ci_expected_fail_exclusions.sh on Linux to
# prove they fail there.  Empty is valid: the former three (release, ios-ops,
# lldb-forensics) are either Linux-portable or run natively in the macOS job.
# Add a group here only for a real, unportable macOS-only dependency.
MAC_GROUPS=()

# Native macOS groups run in their own macOS job and must not be treated as an
# expected Linux failure.  They still belong to the complete classification.
MAC_NATIVE_GROUPS=(
  ios-sentry-wiring ios-ops lldb-forensics
)

# declared_groups <dispatcher> <DEFAULT_TESTS|OPTIONAL_TESTS>
declared_groups() {
  awk -v name="$2" '
    index($0, name "=(") == 1 { inside=1; next }
    inside && /^\)/ { inside=0; next }
    inside { sub(/#.*/, ""); gsub(/[[:space:]]/, ""); if ($0 != "") print }
  ' "$1"
}

contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

declared=()
while IFS= read -r group; do
  [[ -n "$group" ]] && declared+=("$group")
done < <(declared_groups ops/test_ops.sh DEFAULT_TESTS)
MAC_ALL_GROUPS=(${MAC_GROUPS[@]+"${MAC_GROUPS[@]}"} "${MAC_NATIVE_GROUPS[@]}")
all=("${LINUX_GROUPS[@]}" "${MAC_ALL_GROUPS[@]}")
failed=0

for group in "${declared[@]}"; do
  if ! contains "$group" "${all[@]}"; then
    echo "✗ unclassified ops test group: $group" >&2
    failed=1
  fi
done
for group in "${all[@]}"; do
  if ! contains "$group" "${declared[@]}"; then
    echo "✗ classified group is absent from ops/test_ops.sh: $group" >&2
    failed=1
  fi
done

for group in "${LINUX_GROUPS[@]}"; do
  if contains "$group" "${MAC_ALL_GROUPS[@]}"; then
    echo "✗ group appears in both Linux and macOS classifications: $group" >&2
    failed=1
  fi
done
for group in ${MAC_GROUPS[@]+"${MAC_GROUPS[@]}"}; do
  if contains "$group" "${MAC_NATIVE_GROUPS[@]}"; then
    echo "✗ group appears in both expected-fail and native macOS classifications: $group" >&2
    failed=1
  fi
done

# Group pinning for tests whose group is load-bearing (IMP-20260818-2167f4).
# Format "<group>:<test file>": the group's case arm in ops/test_ops.sh must
# mention the file.  Reachability of every test file is the full scan below.
ROUTED_TESTS=(
  "ui-graph:ops/tests/test_ui_graph_contract.py"
  "worktree:ops/tests/test_worktree_scope.py"
  "doctor:ops/tests/test_doctor.py"
  "doctor:ops/tests/test_release_train.py"
  "doctor:ops/tests/test_complexity.py"
  "doctor:ops/tests/test_doctor_issue.py"
  "doctor:ops/tests/test_delivery_metrics.py"
  "capability-matrix:ops/tests/test_compute_cli.py"
  "capability-matrix:ops/tests/test_compute_router.py"
  "capability-matrix:ops/tests/test_felix_compute_launcher.py"
  "capability-matrix:ops/tests/test_xmachine_transport.py"
  "capability-matrix:ops/tests/test_compute_gate_adapter.py"
  "capability-matrix:ops/tests/test_compute_history.py"
  "capability-matrix:ops/tests/test_compute_hosts.py"
  "github-workflows:ops/tests/test_ops_suite_bootstrap.sh"
)

# Print one group's case arm from a test_ops.sh-shaped file.
group_arm() {
  awk -v g="$1" '
    index($0, "    " g ")") == 1 { inside=1; print; next }
    inside && /^    [a-z0-9-]+\)/ { exit }
    inside { print }
  ' "$2"
}

check_routed() {
  local script="$1" entry group file
  for entry in "${ROUTED_TESTS[@]}"; do
    group="${entry%%:*}"; file="${entry#*:}"
    [[ -f "$file" ]] || { echo "✗ routed test file missing: $file" >&2; return 1; }
    group_arm "$group" "$script" | grep -qF "$file" \
      || { echo "✗ $file is not executed by group $group in $script" >&2; return 1; }
  done
}

check_routed ops/test_ops.sh || failed=1

# Static-contract reachability (Issue #2114). Files under ios/StaticTests belong
# to no Xcode target, so nothing executes them unless a runner names them; an
# unnamed file is a contract that rots while readers assume it is enforced. A
# runner is ops/test_ops.sh or a GitHub workflow, and only non-comment lines
# count: a path that appears in a comment is not executed.
STATIC_TESTS_DIR=ios/StaticTests

check_static_tests_run() {
  local root="$1" file rel runner_text workflow status=0
  [[ -d "$root/$STATIC_TESTS_DIR" ]] || return 0
  local runners=("$root/ops/test_ops.sh")
  for workflow in "$root"/.github/workflows/*.yml; do
    [[ -f "$workflow" ]] && runners+=("$workflow")
  done
  # No pipe into `grep -q`: under pipefail an early exit there can SIGPIPE the
  # producer and report a referenced file as missing.
  runner_text="$(grep -hv '^[[:space:]]*#' "${runners[@]}" 2>/dev/null || true)"
  while IFS= read -r -d '' file; do
    rel="${file#"$root"/}"
    if [[ "$runner_text" != *"$rel"* ]]; then
      echo "✗ $rel is not executed by ops/test_ops.sh or any .github/workflows/*.yml" >&2
      status=1
    fi
  done < <(find "$root/$STATIC_TESTS_DIR" -type f ! -name '.DS_Store' -print0)
  return "$status"
}

check_static_tests_run "$ROOT" || failed=1

# Falsification: a file named only in a comment is unrun (must be red); naming
# it on an executable runner line must turn the check green.
static_fixture="$(mktemp -d)"
mkdir -p "$static_fixture/$STATIC_TESTS_DIR" "$static_fixture/ops" "$static_fixture/.github/workflows"
printf 'print("orphan")\n' >"$static_fixture/$STATIC_TESTS_DIR/orphan.swift"
printf '# swift %s/orphan.swift\n' "$STATIC_TESTS_DIR" >"$static_fixture/ops/test_ops.sh"
if check_static_tests_run "$static_fixture" 2>/dev/null; then
  echo "✗ falsification failed: an unrun static test stayed green" >&2
  failed=1
fi
printf '    static) swift %s/orphan.swift ;;\n' "$STATIC_TESTS_DIR" >>"$static_fixture/ops/test_ops.sh"
if ! check_static_tests_run "$static_fixture" 2>/dev/null; then
  echo "✗ positive control failed: a static test named by a runner was reported as unrun" >&2
  failed=1
fi
rm -rf "$static_fixture"

# Falsification: dropping the routing must turn the check red.
mutant="$(mktemp)"
trap 'rm -f "$mutant"' EXIT
grep -vF 'test_ui_graph_contract.py' ops/test_ops.sh >"$mutant" || true
if check_routed "$mutant" 2>/dev/null; then
  echo "✗ falsification failed: routed-test check stayed green without the routing" >&2
  failed=1
fi

# ── Full reachability (Issue #2065) ─────────────────────────────────────────
# Every tracked test file matched below must be executed by the case arm of a
# declared DEFAULT_TESTS group in ops/test_ops.sh (OPTIONAL_TESTS never run in CI and do not count, #2764), or sit
# in UNROUTED_TESTS with the reason it cannot run yet.  An arm reaches a file by
# naming it or through a glob it expands at run time (ops/tests/test_delivery_*.py);
# a path that only appears in a comment, or in the arm of an undeclared group,
# does not count.
REACHABILITY_PATHSPECS=(
  ':(glob)ops/test_*.py' ':(glob)ops/test_*.sh'
  ':(glob)ops/tests/test_*.py' ':(glob)ops/tests/test_*.sh'
  ':(glob).claude/skills/**/test_*.py' ':(glob).claude/skills/**/test_*.sh'
  ':(glob)lab/podcast/test_*.py' ':(glob)lab/podcast/monitor/test_*.py'
)
# "<test file>|<why it is not executed>".  An entry is tracked debt with a
# follow-up, not an exemption: one that is routed, untracked or has no reason
# turns this check red.  Empty today.
UNROUTED_TESTS=()

# Print "<group><TAB><path or glob>" for every test path a case arm of run_one()
# names.  Comments are stripped first; "devops/x" is not "ops/x".
arm_test_refs() {
  awk '
    /^run_one\(\) \{/ { inside=1; next }
    !inside { next }
    /^\}/ { exit }
    {
      line = $0
      if (line ~ /^    \*\)/) { group = ""; next }
      if (match(line, /^    [a-z0-9-]+\)/)) {
        group = substr(line, 5, RLENGTH - 5)
        line = substr(line, RLENGTH + 1)
      }
      sub(/(^|[[:space:]])#.*/, "", line)
      while (group != "" && match(line, /(^|[^A-Za-z0-9_.-])(ops|lab|\.claude)\/[A-Za-z0-9_.\/*-]+/)) {
        token = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (token !~ /^(ops|lab|\.claude)\//) token = substr(token, 2)
        n = split(token, parts, "/")
        if (parts[n] ~ /^test_.*\.(py|sh)$/) print group "\t" token
      }
    }
  ' "$1"
}

scan_tmp="$(mktemp -d)"
trap 'rm -f "$mutant"; rm -rf "$scan_tmp"' EXIT

# scan_reachability <dispatcher>: name every tracked test file that no declared
# group executes and that UNROUTED_TESTS does not explain.
scan_reachability() {
  local dispatcher="$1" declared_list group token entry path reason count rc=0 t="$scan_tmp"
  declared_list="$(declared_groups "$dispatcher" DEFAULT_TESTS)"
  git ls-files -- "${REACHABILITY_PATHSPECS[@]}" >"$t/tracked.raw" \
    || { echo "✗ cannot list tracked test files" >&2; return 1; }
  grep -vFx 'ops/test_ops.sh' "$t/tracked.raw" | LC_ALL=C sort -u >"$t/tracked" || true
  [[ -s "$t/tracked" ]] || { echo "✗ no tracked test files matched the reachability pathspecs" >&2; return 1; }
  : >"$t/routed.raw"
  while IFS=$'\t' read -r group token; do
    grep -Fxq -- "$group" <<<"$declared_list" || continue
    if [[ "$token" == *[*?[]* ]]; then
      compgen -G "$token" >>"$t/routed.raw" || true
    elif [[ -f "$token" ]]; then
      printf '%s\n' "$token" >>"$t/routed.raw"
    else
      echo "✗ group $group names a test file that does not exist: $token" >&2
      rc=1
    fi
  done < <(arm_test_refs "$dispatcher")
  LC_ALL=C sort -u "$t/routed.raw" >"$t/routed"
  : >"$t/allowed"
  for entry in ${UNROUTED_TESTS[@]+"${UNROUTED_TESTS[@]}"}; do
    path="${entry%%|*}" reason="${entry#*|}"
    if [[ "$entry" != *"|"* || -z "${reason//[[:space:]]/}" ]]; then
      echo "✗ UNROUTED_TESTS entry has no reason: $entry" >&2; rc=1; continue
    fi
    grep -Fxq -- "$path" "$t/tracked" \
      || { echo "✗ UNROUTED_TESTS names a file that is not a tracked test: $path" >&2; rc=1; }
    ! grep -Fxq -- "$path" "$t/routed" \
      || { echo "✗ $path is executed by a group; drop it from UNROUTED_TESTS" >&2; rc=1; }
    printf '%s\n' "$path" >>"$t/allowed"
  done
  LC_ALL=C sort -u "$t/routed" "$t/allowed" | LC_ALL=C comm -23 "$t/tracked" - >"$t/unrouted"
  count="$(wc -l <"$t/unrouted" | tr -d ' ')"
  if (( count > 0 )); then
    sed 's/^/✗ unrouted test file: /' "$t/unrouted" >&2
    echo "✗ $count tracked test file(s) run in no declared group of $dispatcher; route each one or list it in UNROUTED_TESTS with a reason" >&2
    rc=1
  fi
  reach_summary="$(wc -l <"$t/tracked" | tr -d ' ') tracked test files reachable ($(LC_ALL=C sort -u "$t/allowed" | wc -l | tr -d ' ') allowlisted)"
  return "$rc"
}

scan_reachability ops/test_ops.sh || failed=1
real_reach_summary="$reach_summary"

# Falsification: dropping a routing, or leaving only a commented-out mention,
# must make the scan name that file.
comment_mutant="$scan_tmp/commented.sh"
sed 's|^\([[:space:]]*\)\(.*ops/tests/test_ui_graph_contract\.py.*\)$|\1# \2|' ops/test_ops.sh >"$comment_mutant"
if cmp -s ops/test_ops.sh "$comment_mutant"; then
  echo "✗ falsification fixture did not apply: test_ui_graph_contract.py is not on its own arm line" >&2
  failed=1
fi
for reach_mutant in "$mutant" "$comment_mutant"; do
  if scan_reachability "$reach_mutant" 2>"$scan_tmp/mutant.err" \
    || ! grep -qF 'unrouted test file: ops/tests/test_ui_graph_contract.py' "$scan_tmp/mutant.err"; then
    echo "✗ falsification failed: reachability scan did not flag a test whose routing was removed ($reach_mutant)" >&2
    failed=1
  fi
done

if [[ "${1:-}" == "--print-linux-groups" ]]; then
  (( failed == 0 )) || exit 1
  printf '%s\n' "${LINUX_GROUPS[@]}"
  exit 0
fi
if [[ "${1:-}" == "--print-mac-groups" ]]; then
  (( failed == 0 )) || exit 1
  (( ${#MAC_GROUPS[@]} == 0 )) || printf '%s\n' "${MAC_GROUPS[@]}"
  exit 0
fi
if (( failed != 0 )); then
  exit 1
fi
echo "✓ ${#declared[@]} ops test groups classified (${#LINUX_GROUPS[@]} Linux, ${#MAC_GROUPS[@]} macOS expected-fail, ${#MAC_NATIVE_GROUPS[@]} native macOS); $real_reach_summary"
