#!/usr/bin/env bash
# test_github_workflows.sh — keep the GitHub-native CI topology executable.
#
# The component workflows are reusable building blocks. pr-gate owns the
# pull_request entrypoint and merge-group-required owns the merge queue
# entrypoint; both expose the same `required` context without importing
# the slow confidence fan-out into the merge queue.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

failures=0
fail() {
  printf '✗ %s\n' "$1" >&2
  failures=$((failures + 1))
}

component_workflows=(
  backend-quality
  design-system
  llm-eval
  ops-suite
  ui-quality-gate
  ios-quality
)

for workflow in "${component_workflows[@]}"; do
  path=".github/workflows/${workflow}.yml"
  [[ -f "$path" ]] || { fail "missing component workflow: $path"; continue; }
  grep -q '^  workflow_call:' "$path" || fail "$path is not reusable via workflow_call"
  if grep -q '^  pull_request:' "$path"; then
    fail "$path owns a pull_request trigger; pr-gate must be the only PR entrypoint"
  fi
done

grep -Fqx "      - '.claude/skills/devops/SKILL.md'" .github/workflows/backend-quality.yml \
  || fail "backend-quality main push trigger omits the devops skill roster contract"

# Issue #2326: cross-tree test dependencies must trigger the post-merge push run
# of the suite that reads them, mirroring ops/ci_scope_router.sh.
for dep in 'ops/data_inspect.py' 'ops/official_decks/**' 'ops/seeds/marketing_demo.json' 'docs/registry.yml' 'docs/reference/testing/backend_strategy.md' 'ios/BooksAndVocab/Views/Podcast/PodcastAccess.swift'; do
  grep -Fqx "      - '$dep'" .github/workflows/backend-quality.yml \
    || fail "backend-quality push paths omit cross-tree dependency: $dep"
done
for dep in 'backend/ops_cli.py' 'backend/ops_edit.py' 'backend/src/kg/ops_*' 'backend/tests/ops_helpers.py'; do
  grep -Fqx "      - '$dep'" .github/workflows/ops-suite.yml \
    || fail "ops-suite push paths omit backend ops-CLI dependency: $dep"
done

# Issue #3439: every macos_ops=true router path outside ops/** must also trigger a main
# push run of ops-suite (otherwise e.g. an ios-sentry-wiring input change never runs it).
macos_patterns="$(awk 'prev ~ /\)$/ && /^      macos_ops=true$/ {print prev} {prev=$0}' ops/ci_scope_router.sh | tr -d ' ')"
[[ -n "$macos_patterns" ]] || fail "could not extract macos_ops case patterns from ci_scope_router.sh"
push_paths="$(awk '/^  push:$/{on=1;next} /^[^ #]/{on=0} /^  [a-z_]+:/{on=0} on' .github/workflows/ops-suite.yml)"
grep -Fqx "      - 'ops/**'" <<<"$push_paths" || fail "ops-suite push paths omit ops/**"
IFS='|' read -r -a macos_pattern_list <<<"${macos_patterns%)}"
for pattern in "${macos_pattern_list[@]}"; do
  [[ "$pattern" != ops/* ]] || continue
  grep -Fqx "      - '$pattern'" <<<"$push_paths" \
    || fail "ops-suite push paths omit macos_ops=true router path: $pattern"
done

PR_GATE=".github/workflows/pr-gate.yml"
grep -q '^  pull_request:' "$PR_GATE" || fail "pr-gate has no pull_request trigger"
grep -Fq 'if: ${{ github.event_name == '\''workflow_dispatch'\'' }}' "$PR_GATE" \
  || fail "pr-gate does not guard manual dispatches"
grep -Fq 'if [[ "$EVENT_SHA" != "$HEAD_SHA" ]]' "$PR_GATE" \
  || fail "pr-gate does not bind manual dispatches to the event SHA"
# A deleted file cannot be format-checked (ruff errors on the missing path), so every
# changed-file listing feeding the format step must exclude deletions or any PR that
# removes a Python file fails repo-gate.
listings="$(grep -c 'git diff --name-only' "$PR_GATE" || true)"
filtered="$(grep -c 'git diff --name-only --diff-filter=d' "$PR_GATE" || true)"
{ [[ "$listings" -ge 1 ]] && [[ "$listings" == "$filtered" ]]; } \
  || fail "pr-gate lists deleted files for the format check (${filtered}/${listings} listings filter deletions)"
if grep -Eq '^[[:space:]]*merge_group:' "$PR_GATE"; then
  fail "pr-gate still owns a merge_group trigger; merge queue requires the short dedicated workflow"
fi

PR_READINESS=".github/workflows/pr-readiness.yml"
grep -Eq 'types: \[[^]]*edited' "$PR_READINESS" \
  || fail "pr-readiness does not rerun after PR body metadata repair"
grep -q '^  workflow_dispatch:' "$PR_READINESS" \
  || fail "pr-readiness has no explicit metadata-race dispatch path"
grep -q 'pr_number:' "$PR_READINESS" \
  || fail "pr-readiness dispatch has no exact PR number input"
grep -q 'head_sha:' "$PR_READINESS" \
  || fail "pr-readiness dispatch has no exact HEAD input"
grep -Fq 'gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER"' "$PR_READINESS" \
  || fail "pr-readiness does not read the live PR body"
grep -Fq './ops/delivery.py validate-pr-body --head-sha "$HEAD_SHA"' "$PR_READINESS" \
  || fail "pr-readiness does not use the typed delivery receipt validator"
if grep -Eq 'grep .*Base SHA|perl -ne.*Digest' "$PR_READINESS"; then
  fail "pr-readiness duplicates typed receipt parsing in workflow shell"
fi
# A draft-to-ready transition changes review metadata, not source. The latest
# `opened`/`synchronize` run already carries the relevant candidate evidence;
# triggering again would cancel or duplicate its full confidence fan-out.
if grep -Eq '^[[:space:]]*types:.*ready_for_review' "$PR_GATE"; then
  fail "pr-gate reruns on ready_for_review without a source change"
fi
grep -q '^  required:' "$PR_GATE" || fail "pr-gate has no final required job"
grep -q '^  changed-paths:' "$PR_GATE" || fail "pr-gate has no fail-closed confidence path classifier"
grep -q 'ops/ci_scope_router.sh' "$PR_GATE" \
  || fail "pr-gate does not invoke the confidence path classifier"
grep -q 'ops/ci_confidence_verdict.sh' "$PR_GATE" \
  || fail "pr-gate does not verify selected versus skipped confidence suites"
grep -Fq 'needs: [repo-gate]' "$PR_GATE" \
  || fail "pr-gate required job is not repo-gate-only"
grep -q '^  confidence:' "$PR_GATE" \
  || fail "pr-gate has no non-blocking full-confidence aggregator"
grep -q 'needs: \[changed-paths, repo-gate, backend-quality, llm-eval, design-system, ui-quality-gate, ops-suite, ios-quality\]' "$PR_GATE" \
  || fail "pr-gate confidence job does not depend on every component gate"
# `confidence` runs on a separate runner, so it must check out its own
# workspace before invoking the verdict helper.
if ! awk '
  /^  confidence:/ { in_confidence=1; next }
  in_confidence && /^  [A-Za-z0-9_-]+:/ { exit }
  in_confidence && index($0, "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1") { checkout=NR }
  in_confidence && index($0, "name: Report the complete validation fan-out") { report=NR }
  END { exit !(checkout && report && checkout < report) }
' "$PR_GATE"; then
  fail "pr-gate confidence job does not check out the workspace before its verdict"
fi
required_block="$(awk '
  /^  required:/ { in_required=1; next }
  in_required && /^  [A-Za-z0-9_-]+:/ { exit }
  in_required { print }
' "$PR_GATE")"
grep -Fqx '    needs: [repo-gate]' <<<"$required_block" \
  || fail "pr-gate required job is not the short repo-gate-only merge gate"
if grep -q 'backend-quality\|ops-suite\|ios-quality' <<<"$required_block"; then
  fail "slow backend/ops/iOS jobs are still merge-blocking"
fi
repo_gate_block="$(awk '
  /^  repo-gate:/ { in_repo_gate=1; next }
  in_repo_gate && /^  [A-Za-z0-9_-]+:/ { exit }
  in_repo_gate { print }
' "$PR_GATE")"
grep -q 'timeout-minutes: 15' <<<"$repo_gate_block" \
  || fail "repo-gate is not hard-bounded to fifteen minutes (ripgrep installer worst case 515s + measured gate; see the pr-gate.yml comment)"
grep -Fq './ops/test_ops.sh docs-lint worktree context-routing github-workflows delivery-control' <<<"$repo_gate_block" \
  || fail "repo-gate does not execute the delivery-control regression group"
grep -Fq '      - name: Check changed Python formatting' <<<"$repo_gate_block" \
  || fail "repo-gate has no bounded changed-Python format step"
grep -Fq 'for sha_name in BASE_SHA HEAD_SHA; do' <<<"$repo_gate_block" \
  || fail "changed-Python format step does not validate both exact refs"
grep -Fq 'git rev-parse --verify "$sha^{commit}"' <<<"$repo_gate_block" \
  || fail "changed-Python format step does not fail closed on an unresolved base/head"
grep -Fq 'actual_sha="$(git rev-parse HEAD)"' <<<"$repo_gate_block" \
  || fail "changed-Python format step does not bind the checkout to HEAD_SHA"
grep -Fq 'while IFS= read -r path; do' <<<"$repo_gate_block" \
  || fail "changed-Python format step is not Bash 3.2-compatible"
grep -Fq '[[ -n "$path" ]] && changed_python+=("$path")' <<<"$repo_gate_block" \
  || fail "changed-Python format step does not collect non-empty paths safely"
grep -Fq 'done < <(git diff --name-only --diff-filter=d "$diff_base_sha" "$HEAD_SHA" -- '\''*.py'\'')' <<<"$repo_gate_block" \
  || fail "changed-Python format step is not bound to the merge-base/head diff"
grep -Fq 'git diff --check "$(git merge-base "$BASE_SHA" "$HEAD_SHA")" "$HEAD_SHA"' <<<"$repo_gate_block" \
  || fail "repo-gate whitespace check is not bound to the merge-base/head diff"
grep -Fq 'if ((${#changed_python[@]} == 0)); then' <<<"$repo_gate_block" \
  || fail "changed-Python format step has no empty-set pass path"
grep -Fq 'uv run --no-project --python 3.13 --with '\''ruff==0.16.3'\'' ruff format --check "${changed_python[@]}"' <<<"$repo_gate_block" \
  || fail "changed-Python format step does not invoke the pinned ruff formatter"
# Issue #3028 (CR on #3062): hosted runners do not guarantee ripgrep, and the
# github-workflows fixtures fail loudly without it.  Every job that runs that group
# must install rg from an unmasked step before its first group run.  Jobs are found
# by the command they run, not a hand-kept list, so a new job cannot skip the install.
rg_contract_rows="$(ruby -ryaml -e '
  Dir.glob(".github/workflows/*.yml").sort.each do |path|
    (YAML.load_file(path)["jobs"] || {}).each do |job_id, job|
      steps = job["steps"] || []
      gate = steps.index { |s| s["run"].to_s.match?(/test_ops\.sh[^\n]*\bgithub-workflows\b/) }
      next if gate.nil?
      install = steps.index { |s| s["run"].to_s.match?(/ci_apt_install\.sh ripgrep|\[rg\]=ripgrep/) }
      step = install && steps[install]
      masked = step && (step.key?("if") || step.key?("continue-on-error") || step["run"].to_s.include?("||"))
      puts [path, job_id, install.inspect, gate, masked ? "masked" : "clear"].join(" ")
    end
  end
')" || { fail "cannot read workflow jobs for the ripgrep install contract"; rg_contract_rows=""; }
rg_jobs=0
while read -r rg_path rg_job rg_install rg_gate rg_mask; do
  rg_jobs=$((rg_jobs + 1))
  if [[ ! "$rg_install" =~ ^[0-9]+$ ]]; then
    fail "$rg_path job $rg_job runs the github-workflows group without a ripgrep install step (ops/ci_apt_install.sh ripgrep before the group)"
  elif (( rg_install >= rg_gate )); then
    fail "$rg_path job $rg_job: ripgrep install (step $rg_install) does not precede the github-workflows group (step $rg_gate)"
  fi
  [[ "$rg_mask" != masked ]] \
    || fail "$rg_path job $rg_job: ripgrep install step is conditional, continue-on-error or masked with ||"
done <<<"$rg_contract_rows"
(( rg_jobs >= 2 )) \
  || fail "expected pr-gate repo-gate and merge-group required to run the github-workflows group, found $rg_jobs job(s)"
# Issue #3028 (CR on #3063): the bounded ripgrep installer can spend its whole retry budget
# before rg exists. A job that installs rg through it must time out only after that worst
# case, or GitHub kills the required check mid-retry. The worst case is derived from the
# installer's own constants (attempts, timeouts, backoff step), never hand-copied.
installer_worst="$(ruby -e '
  src = File.read("ops/ci_apt_install.sh", encoding: "UTF-8")
  c =->(name) { Integer(src[/^#{name}=(\d+)$/, 1]) }
  step = Integer(src[/sleep \$\(\( attempt \* (\d+) \)\)/, 1])
  a = c.("attempts")
  puts a * (c.("install_timeout") + c.("kill_after")) + (a - 1) * (c.("update_timeout") + c.("kill_after")) + step * (a - 1) * a / 2
')" || { fail "cannot derive the ripgrep installer worst case from ops/ci_apt_install.sh"; installer_worst=""; }
rg_timeout_rows="$(ruby -ryaml -e '
  Dir.glob(".github/workflows/*.yml").sort.each do |path|
    (YAML.load_file(path)["jobs"] || {}).each do |job_id, job|
      installs = (job["steps"] || []).any? { |s| s["run"].to_s.match?(/ci_apt_install\.sh ripgrep|\[rg\]=ripgrep/) }
      puts [path, job_id, job["timeout-minutes"].inspect].join(" ") if installs
    end
  end
')" || { fail "cannot read workflow jobs that install ripgrep through the installer"; rg_timeout_rows=""; }
rg_timeout_jobs=0
while read -r t_path t_job t_minutes; do
  [[ -n "$t_job" ]] || continue
  rg_timeout_jobs=$((rg_timeout_jobs + 1))
  if [[ ! "$t_minutes" =~ ^[0-9]+$ ]]; then
    fail "$t_path job $t_job installs ripgrep through ops/ci_apt_install.sh but sets no explicit timeout-minutes"
  elif [[ -z "$installer_worst" ]] || (( t_minutes * 60 <= installer_worst )); then
    fail "$t_path job $t_job timeout ${t_minutes}m does not exceed the ripgrep installer worst case ${installer_worst:-unknown}s"
  fi
done <<<"$rg_timeout_rows"
(( rg_timeout_jobs >= 3 )) \
  || fail "expected repo-gate, merge-group required and ops-suite suite to install ripgrep through the installer, found $rg_timeout_jobs job(s)"
# The Linux ops shard runs its groups from a discovered list, so the command scan above
# cannot see it: its ripgrep install must precede the discovered-group run by name.
suite_order="$(ruby -ryaml -e '
  steps = YAML.load_file(ARGV[0])["jobs"]["suite"]["steps"]
  verify = steps.index { |s| s["run"].to_s.include?("[rg]=ripgrep") }
  run = steps.index { |s| s["run"].to_s.include?("./ops/test_ops.sh \"${selected[@]}\"") }
  puts [verify.inspect, run.inspect].join(" ")
' .github/workflows/ops-suite.yml)" || suite_order="nil nil"
read -r suite_verify suite_run <<<"$suite_order" || true
if [[ ! "$suite_verify" =~ ^[0-9]+$ || ! "$suite_run" =~ ^[0-9]+$ ]]; then
  fail "ops-suite shard has no ripgrep install step before its Linux group run (step indices: $suite_order)"
elif (( suite_verify >= suite_run )); then
  fail "ops-suite ripgrep install (step $suite_verify) does not precede the Linux group run (step $suite_run)"
fi
delivery_control_group="$(awk '
  /delivery-control\)/ { in_group=1 }
  in_group { print }
  in_group && /^[[:space:]]*;;$/ { exit }
' ops/test_ops.sh)"
grep -Fq 'delivery_tests=(ops/tests/test_delivery_*.py)' <<<"$delivery_control_group" \
  || fail "delivery-control group does not declare the complete delivery-test glob"
grep -Fq '"${delivery_tests[@]}"' <<<"$delivery_control_group" \
  || fail "delivery-control group does not execute the discovered delivery-test array"
for workflow in "${component_workflows[@]}"; do
  grep -q "uses: ./.github/workflows/${workflow}.yml" "$PR_GATE" \
    || fail "pr-gate does not call ${workflow}"
done
grep -q "needs.changed-paths.outputs.backend == 'true'" "$PR_GATE" \
  || fail "backend confidence is not path-selected"
grep -q "needs.changed-paths.outputs.ops == 'true'" "$PR_GATE" \
  || fail "ops confidence is not path-selected"
grep -q "needs.changed-paths.outputs.ios == 'true'" "$PR_GATE" \
  || fail "iOS confidence is not path-selected"

# Every required-path component needs its own three-minute ceiling.  The final
# `required` aggregator cannot make a dependency fast if that dependency is
# still allowed to run for fifteen minutes.
for workflow in llm-eval design-system ui-quality-gate; do
  grep -q '^    timeout-minutes: 3$' ".github/workflows/${workflow}.yml" \
    || fail "${workflow} is not hard-bounded to three minutes"
done
grep -q 'timeout-minutes: 1' <<<"$required_block" \
  || fail "required aggregator is not hard-bounded to one minute"

MERGE_GROUP_REQUIRED=".github/workflows/merge-group-required.yml"
[[ -f "$MERGE_GROUP_REQUIRED" ]] \
  || fail "missing dedicated merge-group required workflow: $MERGE_GROUP_REQUIRED"
if [[ -f "$MERGE_GROUP_REQUIRED" ]]; then
  grep -q '^  merge_group:' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group required workflow has no merge_group trigger"
  grep -Fqx '    types: [checks_requested]' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group required workflow is not limited to checks_requested"
  grep -q '^  short-gate:' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group required workflow has no short-gate job"
  grep -q '^  required:' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group required workflow has no required aggregator job"
  # The short gate owns the repository checks; `required` (the context branch
  # protection reads) is only an aggregator over it and the iOS suite.
  merge_group_required_block="$(awk '
    /^  short-gate:/ { in_required=1; next }
    in_required && /^  [A-Za-z0-9_-]+:/ { exit }
    in_required { print }
  ' "$MERGE_GROUP_REQUIRED")"
  # Job-level bound only (4-space indent): short gate plus the backend pytest
  # suite must fit; 15 minutes was too tight for both.
  grep -Eq '^    timeout-minutes: 25$' <<<"$merge_group_required_block" \
    || fail "merge-group required gate is not hard-bounded to twenty-five minutes"
  # ubuntu-latest is a moving label; the apt ffmpeg series follows the image and
  # the podcast preview skip allowlist turns a changed series into a red queue.
  grep -Eq '^    runs-on: ubuntu-24\.04$' <<<"$merge_group_required_block" \
    || fail "merge-group required gate is not pinned to ubuntu-24.04"
  grep -Fq "version: '0.8.23'" <<<"$merge_group_required_block" \
    || fail "merge-group required gate does not pin uv to the backend-quality version"
  # merge_group.base_sha is the group directly ahead (delta routing). Only the diff
  # base resolver may read it; the diff check and scope router consume its verified output.
  base_sha_reads="$(grep -c 'github.event.merge_group.base_sha' <<<"$merge_group_required_block" || true)"
  [[ "$base_sha_reads" == 1 ]] \
    || fail "merge-group short gate must read merge_group.base_sha exactly once, in the diff base resolver (found ${base_sha_reads})"
  grep -q 'github.event.merge_group.head_sha' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group required gate does not use the merge-group head SHA"
  grep -Fq './ops/test_ops.sh docs-lint worktree context-routing github-workflows delivery-control' <<<"$merge_group_required_block" \
    || fail "merge-group required gate does not execute the delivery-control regression group"
  if grep -Eq 'ops-suite|ios-quality|llm-eval|ui-quality-gate|confidence' <<<"$merge_group_required_block"; then
    fail "merge-group required gate imports slow confidence jobs"
  fi
  # ops-suite joins the merge queue's blocking set (#2956, CM decision 2026-10-12): its
  # Linux shards run as their own job behind the router's ops decision, and `required`
  # fails closed unless they pass or were not requested. macOS native ops stay off the
  # queue (macos_ops=false), so only the Linux pool is spent per merge group.
  ops_wiring_err="$(ruby -ryaml -e '
    jobs = YAML.load_file(ARGV[0])["jobs"]
    ops = jobs["ops-suite"] || {}
    errs = []
    errs << "short-gate does not expose the router ops decision" unless jobs.dig("short-gate", "outputs", "ops").to_s.include?("steps.scope.outputs.ops")
    errs << "no ops-suite job" if ops.empty?
    errs << "ops-suite does not call ./.github/workflows/ops-suite.yml" unless ops["uses"] == "./.github/workflows/ops-suite.yml"
    errs << "ops-suite is not gated on the router ops decision" unless ops["if"].to_s.match?(/needs\.short-gate\.outputs\.ops == [\x27"]true[\x27"]/)
    errs << "ops-suite does not pin macos_ops to false" unless ops.dig("with", "macos_ops") == "false"
    errs << "ops-suite does not wait for short-gate" unless Array(ops["needs"]).include?("short-gate")
    errs << "required does not need ops-suite" unless Array(jobs.dig("required", "needs")).include?("ops-suite")
    puts errs
  ' "$MERGE_GROUP_REQUIRED")" || ops_wiring_err="ruby could not parse the merge-group workflow"
  [[ -z "$ops_wiring_err" ]] || fail "merge-group ops-suite wiring: $ops_wiring_err"
  # Behavioural pin: run the required aggregator's own step against router/shard outcomes.
  # A red routed ops shard must fail `required`; skipped is a pass only when not requested.
  ops_gate_run="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["required"]["steps"].last["run"]' "$MERGE_GROUP_REQUIRED")" \
    || fail "cannot extract the merge-group required aggregator step"
  mkdir -p "$ROOT/.cache"
  ops_gate_tmp="$(mktemp -d "$ROOT/.cache/test-ops-gate-XXXXXX")"
  printf '%s\n' "$ops_gate_run" >"$ops_gate_tmp/step.sh"
  ops_gate_case() {  # $1 = router ops decision, $2 = ops-suite result; exit status is the verdict
    NEEDS_JSON="{\"short-gate\":{\"result\":\"success\",\"outputs\":{\"ios\":\"false\",\"ops\":\"$1\"}},\"ios-quality\":{\"result\":\"skipped\"},\"ops-suite\":{\"result\":\"$2\"}}" \
      bash "$ops_gate_tmp/step.sh" >/dev/null 2>&1
  }
  ops_gate_case true success || fail "merge-group required rejects a green routed ops-suite"
  ops_gate_case true failure && fail "merge-group required passes with a red routed ops-suite"
  ops_gate_case true cancelled && fail "merge-group required passes with a cancelled routed ops-suite"
  ops_gate_case true skipped && fail "merge-group required passes with a skipped routed ops-suite"
  ops_gate_case false skipped || fail "merge-group required fails when ops-suite was not requested"
  ops_gate_case maybe skipped && fail "merge-group required accepts a malformed router ops decision"
  rm -rf "$ops_gate_tmp"
  if grep -Eq 'uses:[[:space:]]*\./\.github/workflows/backend-quality\.yml' <<<"$merge_group_required_block"; then
    fail "merge-group required gate must run the backend suite inline, not import backend-quality"
  fi
  # Backend suite runs inline, but only behind the fail-closed scope router.
  # The required check must not be able to pass vacuously: the router step and
  # the pytest step may not be skipped, softened or masked, so assert on the
  # step blocks themselves rather than on the pytest `if:` alone.
  merge_group_step_containing() {
    awk -v needle="$1" '
      /^      - / { if (in_step && hit) { printf "%s", buf; done=1; exit } in_step=1; hit=0; buf="" }
      in_step { buf = buf $0 "\n" }
      index($0, needle) { hit=1 }
      END { if (!done && in_step && hit) printf "%s", buf }
    ' <<<"$merge_group_required_block"
  }
  # A step must run unconditionally and fail closed: no step-level if/continue-on-error,
  # no `||` fallback masking a non-zero exit, and errexit enabled in its script.
  merge_group_assert_unmasked_step() {
    local label="$1" block="$2" allow_if="$3"
    if [[ "$allow_if" != "yes" ]] && grep -Eq '^        if:' <<<"$block"; then
      fail "merge-group ${label} step is conditional (if:) and can be skipped"
    fi
    if grep -Eq '^[[:space:]]*continue-on-error:' <<<"$block"; then
      fail "merge-group ${label} step sets continue-on-error"
    fi
    if grep -Fq '||' <<<"$block"; then
      fail "merge-group ${label} step masks failures with a || fallback"
    fi
    grep -Fq 'set -euo pipefail' <<<"$block" \
      || fail "merge-group ${label} step does not run with set -euo pipefail"
  }
  # ripgrep must come from its own step before the short gate (its fixture runs the
  # strict lint) and before the strict lint step; inside the lint step it comes too late.
  rg_install_step="$(merge_group_step_containing 'ci_apt_install.sh ripgrep')"
  if [[ -z "$rg_install_step" ]]; then
    fail "merge-group required gate has no ripgrep install step (ops/ci_apt_install.sh ripgrep) before the short repository gate"
  else
    merge_group_assert_unmasked_step "ripgrep install" "$rg_install_step" no
  fi
  rg_order="$(ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0])["jobs"]["short-gate"]["steps"]
    find = lambda { |needle| steps.index { |s| s["run"].to_s.include?(needle) } }
    positions = [
      find.call("ci_apt_install.sh ripgrep"),
      find.call("./ops/test_ops.sh docs-lint worktree context-routing github-workflows delivery-control"),
      find.call("ops/i18n_lint.sh --strict"),
    ]
    puts positions.map { |i| i.nil? ? "missing" : i.to_s }.join(" ")
  ' "$MERGE_GROUP_REQUIRED")" || rg_order="missing missing missing"
  read -r rg_step gate_step lint_step <<<"$rg_order" || true
  if [[ ! "$rg_step" =~ ^[0-9]+$ || ! "$gate_step" =~ ^[0-9]+$ || ! "$lint_step" =~ ^[0-9]+$ ]]; then
    fail "merge-group required gate lacks an ordered ripgrep install, short gate or strict lint step (step indices: $rg_order)"
  else
    (( rg_step < gate_step )) \
      || fail "merge-group ripgrep install (step $rg_step) does not precede the short repository gate (step $gate_step)"
    (( rg_step < lint_step )) \
      || fail "merge-group ripgrep install (step $rg_step) does not precede the strict i18n lint (step $lint_step)"
  fi
  # Shared Localizable.strings catalogs leave the PR-time static.i18n check unserialised,
  # so the merge queue re-runs the full strict lint on the merged tree.  Run the
  # workflow's own step block against fixture catalogs (KG_I18N_SRC): a clean tree
  # passes, a non-adjacent duplicate key fails, and a key used in Swift but absent
  # from en.lproj (the write-skew of a deleted key) fails.  The uv shim answers only
  # `python find`, so the lint's interpreter lookup is hermetic.
  i18n_step="$(merge_group_step_containing 'ops/i18n_lint.sh --strict')"
  if [[ -z "$i18n_step" ]]; then
    fail "merge-group required gate has no strict i18n lint step (shared catalogs leave the merge queue as the only re-check)"
  elif ! command -v rg >/dev/null 2>&1; then
    # Without rg every fixture fails for that reason alone; name the cause instead.
    fail "strict i18n lint fixtures need ripgrep (rg) on PATH; install it first with ops/ci_apt_install.sh ripgrep"
  else
    merge_group_assert_unmasked_step "strict i18n lint" "$i18n_step" no
    # Fixtures live under the repo root (gitignored .cache): the key extractor
    # reports paths relative to its root and fails closed on anything outside it.
    mkdir -p "$ROOT/.cache"
    i18n_tmp="$(mktemp -d "$ROOT/.cache/test-i18n-XXXXXX")"
    i18n_run="$i18n_tmp/step.sh"
    ruby -ryaml -e '
      steps = YAML.load_file(ARGV[0])["jobs"]["short-gate"]["steps"]
      step = steps.find { |s| s["run"].to_s.include?("ops/i18n_lint.sh --strict") }
      abort("no strict i18n lint step") unless step
      File.write(ARGV[1], step["run"])
    ' "$MERGE_GROUP_REQUIRED" "$i18n_run" \
      || fail "cannot extract the strict i18n lint step run block"
    mkdir -p "$i18n_tmp/bin"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$(command -v python3)"' >"$i18n_tmp/bin/uv"
    chmod +x "$i18n_tmp/bin/uv"
    printf 'findings=0\nlocalized_calls=0\n' >"$i18n_tmp/baseline.txt"
    i18n_fixture() {  # $1 = name, $2 = key used in Swift, $3 = extra en.lproj line (optional)
      local root="$i18n_tmp/fx-$1" loc
      for loc in en zh-Hans ja ko; do
        mkdir -p "$root/$loc.lproj"
        printf '%s\n' '"kept" = "Kept";' >"$root/$loc.lproj/Localizable.strings"
      done
      [[ -z "${3:-}" ]] || printf '%s\n' "$3" >>"$root/en.lproj/Localizable.strings"
      printf 'let title = L10n.string("%s")\n' "$2" >"$root/Feature.swift"
    }
    run_i18n_step() {  # $1 = fixture name; the step's exit status is the result
      (cd "$ROOT" && UV_BIN="$i18n_tmp/bin/uv" KG_I18N_SRC="$i18n_tmp/fx-$1" KG_I18N_BASELINE="$i18n_tmp/baseline.txt" bash "$i18n_run" 2>&1)
    }
    i18n_fixture clean kept
    i18n_fixture dup kept '"kept" = "Again";'
    i18n_fixture missing gone
    run_i18n_step clean >/dev/null \
      || fail "strict i18n lint step rejects a clean catalog tree"
    if out="$(run_i18n_step dup)"; then
      fail "strict i18n lint step passes a non-adjacent duplicate key (the merge queue must fail on it)"
    fi
    grep -Fq 'duplicate key "kept"' <<<"$out" \
      || fail "strict i18n lint duplicate-key case does not name the duplicate"
    if out="$(run_i18n_step missing)"; then
      fail "strict i18n lint step passes a Swift key missing from en.lproj (write-skew of a deleted key)"
    fi
    grep -Fq 'missing_key: gone' <<<"$out" \
      || fail "strict i18n lint missing-key case does not name the missing key"
    rm -rf "$i18n_tmp"
  fi
  # Hidden-PATH proof: the install step's own block runs with PATH = bash/env/chmod only
  # (rg absent by construction) and a stub installer; the second run must not reinstall.
  mkdir -p "$ROOT/.cache"
  rg_tmp="$(mktemp -d "$ROOT/.cache/test-rg-XXXXXX")"
  ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0])["jobs"]["short-gate"]["steps"]
    step = steps.find { |s| s["run"].to_s.include?("ci_apt_install.sh ripgrep") }
    abort("no ripgrep install step") unless step
    File.write(ARGV[1], step["run"])
  ' "$MERGE_GROUP_REQUIRED" "$rg_tmp/step.sh" \
    || fail "cannot extract the ripgrep install step run block"
  mkdir -p "$rg_tmp/root/ops" "$rg_tmp/tools" "$rg_tmp/stub-bin"
  for tool in bash env chmod; do
    ln -s "$(command -v "$tool")" "$rg_tmp/tools/$tool"
  done
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >>"$RG_INSTALL_LOG"' \
    'printf "%s\n" "#!/usr/bin/env bash" "echo ripgrep-stub" >"$RG_STUB_BIN/rg"' \
    'chmod +x "$RG_STUB_BIN/rg"' >"$rg_tmp/root/ops/ci_apt_install.sh"
  chmod +x "$rg_tmp/root/ops/ci_apt_install.sh"
  rg_step_run() {  # the step's combined output; its exit status is the result
    (cd "$rg_tmp/root" && env -i PATH="$rg_tmp/tools:$rg_tmp/stub-bin" \
      RG_INSTALL_LOG="$rg_tmp/install.log" RG_STUB_BIN="$rg_tmp/stub-bin" \
      "$(command -v bash)" "$rg_tmp/step.sh" 2>&1)
  }
  if ! out="$(rg_step_run)"; then
    fail "ripgrep install step fails on a PATH without rg: $out"
  elif [[ ! -f "$rg_tmp/install.log" ]]; then
    fail "ripgrep install step does not call the installer when rg is absent"
  else
    rm -f "$rg_tmp/install.log"
    rg_step_run >/dev/null || fail "ripgrep install step fails when rg is already on PATH"
    [[ ! -e "$rg_tmp/install.log" ]] || fail "ripgrep install step reinstalls although rg is already on PATH"
  fi
  rm -rf "$rg_tmp"
  scope_step_id="$(awk '
    /^      - name:/ { id="" }
    /^        id:/ { id=$2 }
    /ci_scope_router\.sh --base "\$BASE_SHA" --head "\$HEAD_SHA" --format github-output/ { print id; exit }
  ' <<<"$merge_group_required_block")"
  [[ -n "$scope_step_id" ]] \
    || fail "merge-group required gate has no id'd step running ci_scope_router.sh --format github-output"
  scope_router_step="$(merge_group_step_containing 'ci_scope_router.sh --base')"
  [[ -n "$scope_router_step" ]] \
    || fail "merge-group required gate has no scope router step block"
  merge_group_assert_unmasked_step "scope router" "$scope_router_step" no
  # Parallel merges can each fit the base headroom yet jointly exceed the ceiling (#2869):
  # the merge group must run the complexity budget against the resolved fork point.
  complexity_step="$(merge_group_step_containing './ops/complexity.py check')"
  [[ -n "$complexity_step" ]] \
    || fail "merge-group required gate has no ./ops/complexity.py check step"
  grep -Eq '^[[:space:]]+\./ops/complexity\.py check --base "\$BASE_SHA" --no-fork-points[[:space:]]*$' <<<"$complexity_step" \
    || fail "merge-group complexity step does not check against the resolved merge-group base with --no-fork-points (--base \"\$BASE_SHA\")"
  grep -Fq 'BASE_SHA: ${{ steps.base.outputs.sha }}' <<<"$complexity_step" \
    || fail "merge-group complexity BASE_SHA is not the resolved origin/main merge base"
  merge_group_assert_unmasked_step "complexity" "$complexity_step" no
  if grep -Eq '^    continue-on-error:' <<<"$merge_group_required_block"; then
    fail "merge-group required job sets job-level continue-on-error"
  fi
  # A job-level `if:` that evaluates false skips the whole job, and a skipped
  # required check is reported as passing to the merge queue. Only the two
  # backend steps may be conditional, never the gate itself.
  if grep -Eq "^    [\"']?if[\"']?[[:space:]]*:" <<<"$merge_group_required_block"; then
    fail "merge-group required job sets a job-level if: and can be skipped (a skipped required check counts as passing)"
  fi
  # The router is only a gate if its verdict reaches the backend steps: the
  # output must be appended to $GITHUB_OUTPUT on the router command line itself,
  # and the BASE/HEAD env must carry the merge-group SHAs it classifies.
  scope_router_lines="$(grep -Fc 'ci_scope_router.sh --base' <<<"$scope_router_step" || true)"
  [[ "$scope_router_lines" == 1 ]] \
    || fail "merge-group scope router step must invoke ci_scope_router.sh on exactly one line, found ${scope_router_lines}"
  grep -Eq 'ci_scope_router\.sh --base .*--format github-output[[:space:]]*>>[[:space:]]*"\$GITHUB_OUTPUT"[[:space:]]*$' <<<"$scope_router_step" \
    || fail "merge-group scope router output is not appended to \"\$GITHUB_OUTPUT\" on the ci_scope_router.sh line, so backend steps never see it"
  # The diff base is resolved once and fed to both consumers: merge_group.base_sha
  # (the group directly ahead) when verified, else origin/main's fork point.
  base_step_id="$(awk '
    /^      - name:/ { id="" }
    /^        id:/ { id=$2 }
    /git merge-base refs\/remotes\/origin\/main "\$HEAD_SHA"/ { print id; exit }
  ' <<<"$merge_group_required_block")"
  base_step="$(merge_group_step_containing 'git merge-base')"
  diff_check_step="$(merge_group_step_containing 'git diff --check')"
  if [[ -z "$base_step_id" || -z "$base_step" || -z "$diff_check_step" ]]; then
    fail "merge-group required gate has no id'd 'git merge-base refs/remotes/origin/main \"\$HEAD_SHA\"' step feeding the diff check"
  else
    merge_group_assert_unmasked_step "diff base" "$base_step" no
    for base_consumer in "diff check:$diff_check_step" "scope router:$scope_router_step"; do
      grep -Fqx "          BASE_SHA: \${{ steps.${base_step_id}.outputs.sha }}" <<<"${base_consumer#*:}" \
        || fail "merge-group ${base_consumer%%:*} BASE_SHA is not the resolved origin/main merge base (steps.${base_step_id}.outputs.sha)"
    done
  fi
  grep -Fqx '          HEAD_SHA: ${{ github.event.merge_group.head_sha }}' <<<"$scope_router_step" \
    || fail "merge-group scope router HEAD_SHA is not the merge-group head SHA"
  # Delta routing needs the resolver to verify merge_group.base_sha before trusting it:
  # exact 40-hex, present in the checkout, and an ancestor of HEAD.  Anything else
  # falls back to the cumulative base (checked behaviourally below).
  grep -Fqx '          MERGE_GROUP_BASE_SHA: ${{ github.event.merge_group.base_sha }}' <<<"$base_step" \
    || fail "merge-group diff base step does not bind merge_group.base_sha through MERGE_GROUP_BASE_SHA"
  grep -Fq '[[ "$MERGE_GROUP_BASE_SHA" =~ ^[0-9a-f]{40}$ ]]' <<<"$base_step" \
    || fail "merge-group diff base step does not require merge_group.base_sha to be an exact commit SHA"
  grep -Fq 'git cat-file -e "$MERGE_GROUP_BASE_SHA^{commit}"' <<<"$base_step" \
    || fail "merge-group diff base step does not require merge_group.base_sha to be present in the checkout"
  grep -Fq 'git merge-base --is-ancestor "$MERGE_GROUP_BASE_SHA" "$HEAD_SHA"' <<<"$base_step" \
    || fail "merge-group diff base step does not require merge_group.base_sha to be an ancestor of HEAD"
  grep -Fq 'using cumulative base' <<<"$base_step" \
    || fail "merge-group diff base step does not fall back to the cumulative base with a printed reason"
  # Delta routing is sound only under ALLGREEN. The workflow states the dependency and
  # the runbook pins the strategy, so a HEADGREEN revert cannot land without cumulative routing.
  grep -Fq 'queue uses ALLGREEN' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group workflow does not state that delta routing depends on the ALLGREEN queue"
  grep -Fq 'ruleset 為 ALLGREEN' docs/runbook/system.md \
    || fail "runbook does not record the merge-queue grouping strategy as ALLGREEN"
  # The route job classifies the same delta as short-gate, so it resolves the base identically.
  route_block="$(awk '
    /^  route:/ { in_route=1; next }
    in_route && /^  [A-Za-z0-9_-]+:/ { exit }
    in_route { print }
  ' "$MERGE_GROUP_REQUIRED")"
  grep -Fqx '          MERGE_GROUP_BASE_SHA: ${{ github.event.merge_group.base_sha }}' <<<"$route_block" \
    || fail "merge-group route job does not resolve its diff base from merge_group.base_sha"
  grep -Fq 'git merge-base --is-ancestor "$MERGE_GROUP_BASE_SHA" "$HEAD_SHA"' <<<"$route_block" \
    || fail "merge-group route job does not verify merge_group.base_sha is an ancestor of HEAD"
  # Positive control + mutation check: replay the base/diff/router steps of the
  # workflow file itself (env expressions included, so a revert of BASE_SHA to
  # merge_group.base_sha changes the result) against fixture repos, and require
  # the verdict to reach $GITHUB_OUTPUT.  A cumulative group (#8 behind #7)
  # carries #7's change at its head while merge_group.base_sha is #7's merge.
  read -r -d '' group_sim_rb <<'RUBY' || true
require "yaml"
require "tmpdir"
require "open3"
workflow, repo, group_base, group_head = ARGV
steps = YAML.load_file(workflow)["jobs"]["short-gate"]["steps"]
event = { "github.event.merge_group.base_sha" => group_base, "github.event.merge_group.head_sha" => group_head }
outputs = {}
Dir.mktmpdir do |tmp|
  steps.each_with_index do |step, index|
    next if step["run"].to_s.include?("complexity.py check") && !File.exist?(File.join(repo, "ops", "complexity.py"))
    next unless ["git merge-base", "git diff --check", "ci_scope_router.sh", "complexity.py check"].any? { |needle| step["run"].to_s.include?(needle) }
    out_file = File.join(tmp, "output-#{index}")
    File.write(out_file, "")
    env = { "GITHUB_OUTPUT" => out_file }
    (step["env"] || {}).each do |key, value|
      env[key] = value.to_s.gsub(/\$\{\{\s*(.+?)\s*\}\}/) do
        expr = Regexp.last_match(1)
        ref = expr.match(/\Asteps\.([\w-]+)\.outputs\.([\w-]+)\z/)
        if event.key?(expr) then event[expr]
        elsif ref then (outputs[ref[1]] || {}).fetch(ref[2], "")
        else abort("unsupported expression: #{expr}")
        end
      end
    end
    stdout, stderr, status = Open3.capture3(env, "bash", "-e", "-c", step["run"], chdir: repo)
    warn stderr if status.success? && !stderr.empty?
    unless status.success?
      warn "step '#{step["name"]}' failed with #{status.exitstatus}: #{stdout}#{stderr}"
      exit 1
    end
    pairs = File.readlines(out_file, chomp: true).map { |line| line.split("=", 2) }.select { |pair| pair.size == 2 }.to_h
    outputs[step["id"]] = pairs if step["id"]
    pairs.each { |key, value| puts "#{step["id"]}.#{key}=#{value}" }
  end
end
RUBY
  scope_tmp="$(mktemp -d)"
  scope_repo="$scope_tmp/repo"
  sfx() { git -C "$scope_repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
  sim_group() { # workflow group_base group_head -> "step-id.key=value" lines; status 1 = a step failed (reason in $scope_tmp/err)
    ruby -e "$group_sim_rb" "$1" "$scope_repo" "$2" "$3" 2>"$scope_tmp/err"
  }
  mk_group() { # name path7 content7 -> "<#7 merge> <#8 merge>": #7 writes path7 and #8 a docs file, both on s_base
    local name="$1" path7="$2" content7="$3" q7
    sfx checkout -q -b "$name-pr7" "$s_base"
    mkdir -p "$scope_repo/$(dirname "$path7")"
    printf '%s\n' "$content7" >"$scope_repo/$path7"
    sfx add "$path7"
    sfx commit -q -m "$name pr7"
    sfx checkout -q -b "$name-q7" "$s_base"
    sfx merge -q --no-ff "$name-pr7" -m "Merge pull request #7 from Books-Vocab/$name"
    q7="$(sfx rev-parse HEAD)"
    sfx checkout -q -b "$name-pr8" "$s_base"
    mkdir -p "$scope_repo/docs"
    printf '%s\n' "$name" >"$scope_repo/docs/$name-8.md"
    sfx add "docs/$name-8.md"
    sfx commit -q -m "$name pr8"
    sfx checkout -q -b "$name-q8" "$q7"
    sfx merge -q --no-ff "$name-pr8" -m "Merge pull request #8 from Books-Vocab/$name"
    printf '%s %s\n' "$q7" "$(sfx rev-parse HEAD)"
  }
  git init -q -b main "$scope_repo"
  mkdir -p "$scope_repo/ops"
  cp ops/ci_scope_router.sh "$scope_repo/ops/ci_scope_router.sh"
  sfx add ops/ci_scope_router.sh
  sfx commit -q -m base
  s_base="$(sfx rev-parse HEAD)"
  # actions/checkout (fetch-depth: 0) materialises refs/remotes/origin/main.
  sfx update-ref refs/remotes/origin/main "$s_base"
  mkdir -p "$scope_repo/backend/app"
  : >"$scope_repo/backend/app/changed.py"
  sfx add backend
  sfx commit -q -m backend-change
  s_backend="$(sfx rev-parse HEAD)"
  sfx checkout -q -b docs-only "$s_base"
  mkdir -p "$scope_repo/docs"
  : >"$scope_repo/docs/only.md"
  sfx add docs
  sfx commit -q -m docs-only
  s_docs_only="$(sfx rev-parse HEAD)"
  out="$(sim_group "$MERGE_GROUP_REQUIRED" "$s_base" "$s_backend" || true)"
  grep -Fxq "${scope_step_id}.backend=true" <<<"$out" \
    || fail "scope router step, backend change: backend=true did not reach \$GITHUB_OUTPUT, got '$out': $(cat "$scope_tmp/err")"
  out="$(sim_group "$MERGE_GROUP_REQUIRED" "$s_base" "$s_docs_only" || true)"
  grep -Fxq "${scope_step_id}.backend=false" <<<"$out" \
    || fail "scope router step, docs-only change: backend=false did not reach \$GITHUB_OUTPUT, got '$out': $(cat "$scope_tmp/err")"
  # Delta routing (ALLGREEN): #7 (backend) is queued ahead of #8 (docs only). The group
  # head contains both, but merge_group.base_sha is #7's group head, so #8's group routes
  # only its own delta. #7's backend change is verified by #7's own group (base origin/main),
  # which ALLGREEN requires to be green before #8 can merge.
  read -r g_base g_head < <(mk_group backend-7 backend/app/pr7.py 'x = 1')
  out="$(sim_group "$MERGE_GROUP_REQUIRED" "$s_base" "$g_base" || true)"
  grep -Fxq "${scope_step_id}.backend=true" <<<"$out" \
    || fail "#7's own group (backend change, base origin/main) did not route backend=true, got '$out': $(cat "$scope_tmp/err")"
  out="$(sim_group "$MERGE_GROUP_REQUIRED" "$g_base" "$g_head" || true)"
  grep -Fxq "${base_step_id}.sha=$g_base" <<<"$out" \
    || fail "delta base: #8's group must diff from merge_group.base_sha $g_base, got '$out': $(cat "$scope_tmp/err")"
  grep -Fxq "${scope_step_id}.backend=false" <<<"$out" \
    || fail "delta routing: #8's group (docs only, base #7's group head) must not re-run backend for #7, got '$out'"
  # The whitespace check is per group too: #7's own group must reject its whitespace error.
  read -r w_base w_head < <(mk_group ws-7 docs/ws7.md 'trailing space ')
  if sim_group "$MERGE_GROUP_REQUIRED" "$s_base" "$w_base" >/dev/null; then
    fail "#7's own group accepts its trailing whitespace error; ALLGREEN depends on it failing in #7's own group"
  elif ! grep -Fq 'trailing whitespace' "$scope_tmp/err"; then
    fail "#7's own group rejected the whitespace error for the wrong reason: $(cat "$scope_tmp/err")"
  fi
  sim_group "$MERGE_GROUP_REQUIRED" "$w_base" "$w_head" >/dev/null \
    || fail "#8's group (base #7's group head) re-checked #7's delta: $(cat "$scope_tmp/err")"
  # Fail closed: a missing, malformed, unknown, or non-ancestor merge_group.base_sha falls
  # back to the cumulative base (origin/main's fork point) and prints why.
  for bad_base in '' 'not-a-sha' 0123456789abcdef0123456789abcdef01234567 "$s_docs_only"; do
    out="$(sim_group "$MERGE_GROUP_REQUIRED" "$bad_base" "$g_head" || true)"
    grep -Fxq "${base_step_id}.sha=$s_base" <<<"$out" \
      || fail "fallback: base_sha '$bad_base' must fall back to the cumulative base $s_base, got '$out': $(cat "$scope_tmp/err")"
    grep -Fq 'using cumulative base' "$scope_tmp/err" \
      || fail "fallback: base_sha '$bad_base' fell back without printing the reason: $(cat "$scope_tmp/err")"
    grep -Fxq "${scope_step_id}.backend=true" <<<"$out" \
      || fail "fallback: cumulative base must route #7's backend change at the group head, base_sha '$bad_base', got '$out'"
  done
  # Once #7 has landed on origin/main, #8 is the whole pending delta again.
  sfx update-ref refs/remotes/origin/main "$g_base"
  out="$(sim_group "$MERGE_GROUP_REQUIRED" "$g_base" "$g_head" || true)"
  { grep -Fxq "${base_step_id}.sha=$g_base" <<<"$out" && grep -Fxq "${scope_step_id}.backend=false" <<<"$out"; } \
    || fail "after #7 landed on origin/main only #8's docs delta may be classified, got '$out': $(cat "$scope_tmp/err")"
  sfx update-ref refs/remotes/origin/main "$s_base"
  # Fail closed: no origin/main, no merge base, or no head cannot be bounded.
  sfx update-ref -d refs/remotes/origin/main
  if sim_group "$MERGE_GROUP_REQUIRED" "$g_base" "$g_head" >/dev/null; then
    fail "diff base step resolves a base without origin/main"
  elif ! grep -Fq 'origin/main is unavailable' "$scope_tmp/err"; then
    fail "diff base step without origin/main failed for the wrong reason: $(cat "$scope_tmp/err")"
  fi
  sfx update-ref refs/remotes/origin/main "$s_base"
  s_orphan="$(sfx commit-tree "$(sfx mktree </dev/null)" -m unrelated)"
  for unbounded_head in "$s_orphan" ""; do
    if sim_group "$MERGE_GROUP_REQUIRED" "$g_base" "$unbounded_head" >/dev/null; then
      fail "diff base step resolves a base for head '$unbounded_head' that shares no history with origin/main"
    elif ! grep -Fq 'shares no history with merge-group head' "$scope_tmp/err"; then
      fail "diff base step failed for the wrong reason on head '$unbounded_head': $(cat "$scope_tmp/err")"
    fi
  done
  # #2869 behavioral proof: sibling A (8 ops lines) is already on origin/main, the group head is
  # merge(main, B (8 lines)); A+B exceeds the 10-line headroom and the real workflow step must go red.
  # Dropping --no-fork-points lets B's own fork allowance hide A, so the mutant must pass (the hole).
  cx_ops="$(wc -l <ops/ci_scope_router.sh)"
  sfx checkout -q -b cx-base "$s_base"
  mkdir -p "$scope_repo/ops"
  cp ops/complexity.py "$scope_repo/ops/complexity.py"
  cx_ops="$((cx_ops + $(wc -l <ops/complexity.py)))"
  printf '{"schema":"kg.complexity-budget.v1","slack":{"ops":50,"docs":50,"workflows":50},"ceilings":{"ops":%s,"docs":0,"workflows":0}}\n' "$((cx_ops + 10))" >"$scope_repo/ops/complexity_budget.json"
  sfx add ops
  sfx commit -q -m cx-base
  cx_base="$(sfx rev-parse HEAD)"
  sfx checkout -q -b cx-pr-b "$cx_base"
  seq 8 >"$scope_repo/ops/b_lane.sh"
  sfx add ops
  sfx commit -q -m cx-pr-b
  sfx checkout -q -b cx-main "$cx_base"
  seq 8 >"$scope_repo/ops/a_lane.sh"
  sfx add ops
  sfx commit -q -m cx-pr-a
  cx_main="$(sfx rev-parse HEAD)"
  sfx checkout -q -b cx-group "$cx_main"
  sfx merge -q --no-ff cx-pr-b -m "cx group head"
  cx_head="$(sfx rev-parse HEAD)"
  sfx update-ref refs/remotes/origin/main "$cx_main"
  if sim_group "$MERGE_GROUP_REQUIRED" "$cx_main" "$cx_head" >/dev/null; then
    fail "merge-group complexity step accepts sibling A + B jointly exceeding the ops ceiling"
  elif ! grep -Fq 'raise the ceiling' "$scope_tmp/err"; then
    fail "merge-group complexity step failed for the wrong reason: $(cat "$scope_tmp/err")"
  fi
  sed 's/ --no-fork-points//' "$MERGE_GROUP_REQUIRED" >"$scope_tmp/mutant-complexity.yml"
  sim_group "$scope_tmp/mutant-complexity.yml" "$cx_main" "$cx_head" >/dev/null \
    || fail "mutation check: without --no-fork-points the joint overflow must slip through (the #2869 hole), but it failed: $(cat "$scope_tmp/err")"
  sfx update-ref refs/remotes/origin/main "$cx_base"
  cx_solo="$(sfx commit-tree "$(sfx rev-parse cx-pr-b^{tree})" -p "$cx_base" -m solo)"
  sfx checkout -q --detach "$cx_solo"
  sim_group "$MERGE_GROUP_REQUIRED" "$cx_base" "$cx_solo" >/dev/null \
    || fail "positive control: B alone within the headroom must pass the merge-group complexity step: $(cat "$scope_tmp/err")"
  rm -rf "$scope_tmp"
  backend_pytest_step="$(merge_group_step_containing 'uv run python -m pytest -q -rs --skip-allowlist=tests/skip_allowlist.json')"
  [[ -n "$backend_pytest_step" ]] \
    || fail "merge-group required gate does not run the backend pytest suite"
  # Anchored to a live step-level key: a commented-out `# if: ...` must not pass.
  grep -Eq "^        if: steps\.${scope_step_id}\.outputs\.backend == 'true'\$" <<<"$backend_pytest_step" \
    || fail "merge-group backend pytest step is not guarded by the router backend output"
  merge_group_assert_unmasked_step "backend pytest" "$backend_pytest_step" yes
  # Exact command line: appended or injected selection flags (-k, --deselect,
  # --ignore, -m, --co, ...) or PYTEST_ADDOPTS can run zero tests and still pass.
  grep -Fqx '          uv run python -m pytest -q -rs --skip-allowlist=tests/skip_allowlist.json' <<<"$backend_pytest_step" \
    || fail "merge-group backend pytest command line is not exactly 'uv run python -m pytest -q -rs --skip-allowlist=tests/skip_allowlist.json'; extra flags can silently narrow the suite"
  if grep -Fq 'PYTEST_ADDOPTS' "$MERGE_GROUP_REQUIRED"; then
    fail "merge-group required workflow sets PYTEST_ADDOPTS, which can silently narrow the backend suite"
  fi
  ffmpeg_step="$(merge_group_step_containing 'install -y --no-install-recommends ffmpeg')"
  [[ -n "$ffmpeg_step" ]] \
    || fail "merge-group required gate has no ffmpeg install step"
  grep -Eq "^        if: steps\.${scope_step_id}\.outputs\.backend == 'true'\$" <<<"$ffmpeg_step" \
    || fail "merge-group ffmpeg step is not guarded by the router backend output"
  merge_group_assert_unmasked_step "ffmpeg" "$ffmpeg_step" yes
  ffmpeg_line="$(grep -n 'install -y --no-install-recommends ffmpeg' <<<"$merge_group_required_block" | head -n 1 | cut -d: -f1)"
  pytest_line="$(grep -n 'uv run python -m pytest' <<<"$merge_group_required_block" | head -n 1 | cut -d: -f1)"
  { [[ -n "$ffmpeg_line" && -n "$pytest_line" ]] && (( ffmpeg_line < pytest_line )); } \
    || fail "merge-group ffmpeg step is not ordered before the backend pytest step"
  grep -Fq 'working-directory: backend' <<<"$backend_pytest_step" \
    || fail "merge-group backend pytest step does not run in backend/"
  grep -Fq 'uv sync --locked' <<<"$backend_pytest_step" \
    || fail "merge-group backend pytest step does not sync the locked environment"
  grep -q '^  agent-review:' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group required workflow has no independent review gate"
  agent_review_block="$(awk '
    /^  agent-review:/ { in_review=1; next }
    in_review && /^  [A-Za-z0-9_-]+:/ { exit }
    in_review { print }
  ' "$MERGE_GROUP_REQUIRED")"
  grep -q '^    name: agent-review$' <<<"$agent_review_block" \
    || fail "merge-group independent review gate does not emit the required context"
  # Vacuous-pass contract, parsed structurally (not by regex) so quoted keys and
  # flow-style YAML cannot slip past it. Branch protection and the merge queue
  # match the job's `name:`, not its YAML key, so a renamed `required` job leaves
  # the context never reported; a skipped or soft-failed job counts as passing.
  #
  # ACCEPTED residuals: this static test cannot see inside a run script, so it
  # does NOT catch a deliberate `exit 0` / `if false` wrapping in a script, a
  # later `backend=false` write to $GITHUB_OUTPUT, or shell function shadowing
  # (e.g. redefining `git` or `uv`). Those are out of scope for a static
  # contract test; reviewing the workflow diff owns them.
  while IFS= read -r contract_failure; do
    [[ -n "$contract_failure" ]] && fail "$contract_failure"
  done < <(ruby -e 'require "yaml"
    jobs = (YAML.load_file(ARGV[0]) || {})["jobs"] || {}
    required = jobs["short-gate"].is_a?(Hash) ? jobs["short-gate"] : {}
    review = jobs["agent-review"].is_a?(Hash) ? jobs["agent-review"] : {}
    out = []
    unless required["name"] == "short-gate"
      out << "merge-group short-gate job name is #{required["name"].inspect}, not exactly short-gate; the required aggregator is checked separately"
    end
    if review.key?("if")
      out << "merge-group agent-review job sets a job-level if: and can be skipped (a skipped required check counts as passing)"
    end
    if review.key?("continue-on-error")
      out << "merge-group agent-review job sets job-level continue-on-error"
    end
    steps = required["steps"].is_a?(Array) ? required["steps"] : []
    { "short repository gate" => "./ops/test_ops.sh", "diff check" => "git diff --check" }.each do |label, needle|
      hits = steps.select { |s| s.is_a?(Hash) && s["run"].to_s.include?(needle) }
      if hits.size != 1
        out << "merge-group required job must have exactly one #{label} step running #{needle}, found #{hits.size}"
        next
      end
      step = hits.first
      out << "merge-group #{label} step is conditional (if:) and can be skipped" if step.key?("if")
      out << "merge-group #{label} step sets continue-on-error" if step.key?("continue-on-error")
      out << "merge-group #{label} step masks failures with a || fallback" if step["run"].to_s.include?("||")
    end
    puts out' "$MERGE_GROUP_REQUIRED" 2>&1 || echo "merge-group contract check could not parse $MERGE_GROUP_REQUIRED")
  grep -q 'github.event.merge_group.head_sha' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate is not bound to the merge-group HEAD"
  grep -q 'mergeQueue' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not read queue membership"
  if grep -q 'headCommit.oid == "\$group_sha"' "$MERGE_GROUP_REQUIRED"; then
    fail "merge-group independent review gate compares the synthetic group SHA to the PR head"
  fi
  grep -q 'pullRequest.headRefOid' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not bind queue membership to the PR head ref"
  if grep -q 'solo == true' "$MERGE_GROUP_REQUIRED"; then
    fail "merge-group independent review gate incorrectly rejects grouped entries"
  fi
  grep -q 'group_pr_numbers' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not enumerate grouped PRs"
  grep -q 'target_position' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not bound group membership by queue position"
  grep -q 'MERGE_GROUP_PR_NUMBERS' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not consume derived membership"
  # The merge_group event payload carries no pull_requests list, so a join()
  # over it is always empty and the gate failed on every run.
  if grep -q 'merge_group.pull_requests' "$MERGE_GROUP_REQUIRED"; then
    fail "merge-group independent review gate reads merge_group.pull_requests, which the event payload never provides"
  fi
  grep -Fq 'MERGE_GROUP_PR_NUMBERS: ${{ steps.membership.outputs.pr_numbers }}' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not take membership from the derive step output"
  grep -q 'membership evidence' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not fail closed without membership evidence"
  membership_step="$(awk '
    /^      - name: Derive merge-group membership$/ { in_step=1; next }
    in_step && /^      - name:/ { exit }
    in_step && /^  [A-Za-z0-9_-]+:/ { exit }
    in_step { print }
  ' "$MERGE_GROUP_REQUIRED")"
  [[ -n "$membership_step" ]] \
    || fail "merge-group workflow has no 'Derive merge-group membership' step"
  grep -q '^        id: membership$' <<<"$membership_step" \
    || fail "merge-group membership step has no id: membership"
  grep -Fq 'github.event.merge_group.head_ref' <<<"$membership_step" \
    || fail "merge-group membership step does not derive PRs from merge_group.head_ref"
  membership_script="$(awk '
    /^        run: \|$/ { grab=1; next }
    grab { sub(/^          /, ""); print }
  ' <<<"$membership_step")"
  if [[ -z "$membership_script" ]]; then
    fail "merge-group membership step has no run script"
  else
    # Behavioural check: execute the step's own script against a fixture repo.
    membership_tmp="$(mktemp -d)"
    membership_repo="$membership_tmp/repo"
    mfx() { git -C "$membership_repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
    run_membership() { # head_ref base_sha head_sha -> GITHUB_OUTPUT content; status = script status
      : >"$membership_tmp/out"
      (cd "$membership_repo" && GITHUB_OUTPUT="$membership_tmp/out" GITHUB_REF="" \
        MERGE_GROUP_HEAD_REF="$1" MERGE_GROUP_BASE_SHA="$2" MERGE_GROUP_HEAD_SHA="$3" \
        bash -c "$membership_script") >/dev/null 2>&1 || return 1
      cat "$membership_tmp/out"
    }
    git init -q -b main "$membership_repo"
    mfx commit -q --allow-empty -m base
    m_base="$(mfx rev-parse HEAD)"
    # actions/checkout (fetch-depth: 0) materialises refs/remotes/origin/main.
    mfx update-ref refs/remotes/origin/main "$m_base"
    mfx checkout -q -b pr11
    mfx commit -q --allow-empty -m "Merge pull request #99 from evil/forged-subject-on-plain-commit"
    mfx checkout -q main
    mfx merge -q --no-ff pr11 -m "Merge pull request #11 from Books-Vocab/lane-a"
    m_solo="$(mfx rev-parse HEAD)"
    mfx checkout -q -b pr12
    mfx commit -q --allow-empty -m work
    mfx checkout -q main
    mfx merge -q --no-ff pr12 -m "Merge pull request #12 from Books-Vocab/lane-b"
    m_group="$(mfx rev-parse HEAD)"
    out="$(run_membership "refs/heads/gh-readonly-queue/main/pr-11-$m_base" "$m_base" "$m_solo" || true)"
    [[ "$out" == "pr_numbers=11" ]] \
      || fail "membership step, solo group: expected pr_numbers=11, got '$out' (a plain commit with a forged subject must be ignored)"
    out="$(run_membership "refs/heads/gh-readonly-queue/main/pr-12-$m_base" "$m_base" "$m_group" || true)"
    [[ "$out" == "pr_numbers=11,12" ]] \
      || fail "membership step, multi-PR group: expected pr_numbers=11,12, got '$out'"
    out="$(run_membership "refs/heads/gh-readonly-queue/main/pr-7-$m_base" "$m_base" "$m_base" || true)"
    [[ "$out" == "pr_numbers=7" ]] \
      || fail "membership step must still name the head_ref PR when history has no merge commits, got '$out'"
    if run_membership "refs/heads/gh-readonly-queue/main/no-pr-here" "$m_base" "$m_solo" >/dev/null; then
      fail "membership step accepts a head_ref that names no PR"
    fi
    # Cumulative group (review P1 on #2621): PR #12 is queued behind #11 and
    # GitHub sets base_sha to #11's synthetic merge, so base_sha..head_sha holds
    # only #12.  Membership must still name #11, whose changes are in the ref.
    out="$(run_membership "refs/heads/gh-readonly-queue/main/pr-12-$m_solo" "$m_solo" "$m_group" || true)"
    [[ "$out" == "pr_numbers=11,12" ]] \
      || fail "membership step, cumulative group (base_sha = preceding PR's merge): expected pr_numbers=11,12, got '$out'"
    # Once #11 is on origin/main it is no longer part of the pending group.
    mfx update-ref refs/remotes/origin/main "$m_solo"
    out="$(run_membership "refs/heads/gh-readonly-queue/main/pr-12-$m_solo" "$m_solo" "$m_group" || true)"
    [[ "$out" == "pr_numbers=12" ]] \
      || fail "membership step must drop a PR already merged into origin/main, got '$out'"
    # A base that is not an ancestor of the head cannot bound the group.
    if run_membership "refs/heads/gh-readonly-queue/main/pr-12-$m_solo" "$m_group" "$m_solo" >/dev/null; then
      fail "membership step accepts a base_sha that is not an ancestor of head_sha"
    fi
    # Without origin/main the group cannot be bounded: fail closed.
    mfx update-ref -d refs/remotes/origin/main
    if run_membership "refs/heads/gh-readonly-queue/main/pr-12-$m_base" "$m_base" "$m_group" >/dev/null; then
      fail "membership step derives a group without origin/main to bound it"
    fi
    rm -rf "$membership_tmp"
  fi

  # Behavioural check of the live-queue cross-check: run the verify step's own
  # script against a fake gh so completeness is proven, not just grepped.
  verify_step="$(awk '
    /^      - name: Verify exact queued PR has independent review evidence$/ { in_step=1; next }
    in_step && /^      - name:/ { exit }
    in_step && /^  [A-Za-z0-9_-]+:/ { exit }
    in_step { print }
  ' "$MERGE_GROUP_REQUIRED")"
  verify_script="$(awk '
    /^        run: \|$/ { grab=1; next }
    grab { sub(/^          /, ""); print }
  ' <<<"$verify_step")"
  if [[ -z "$verify_script" ]]; then
    fail "merge-group verify step has no run script"
  else
    verify_tmp="$(mktemp -d)"
    mkdir -p "$verify_tmp/bin"
    cat >"$verify_tmp/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake gh: PR N has head sha %040x(N) and a passing trusted agent-review run 9000+N.
# Per-PR faults: FAKE_NO_REVIEW_FOR=N (no review check-run), FAKE_FAIL_REVIEW_FOR=N
# (review concluded failure), FAKE_DRIFT_FOR=N (pulls API head differs from the queue),
# FAKE_ISSUE_COMMENT_RUN_FOR=N (N's review run is an unbound issue_comment run).
set -euo pipefail
[[ "${1:-}" == "api" ]] || exit 2
endpoint="${2:-}"
case "$endpoint" in
  graphql)
    [[ -s "$FAKE_QUEUE_FILE" ]] || { echo "fake gh: merge queue unreadable" >&2; exit 1; }
    cat "$FAKE_QUEUE_FILE" ;;
  repos/*/actions/workflows/agent-review.yml) echo 4242 ;;
  repos/*/commits/*/check-runs*)
    sha="${endpoint#*/commits/}"; sha="${sha%%/*}"
    n=$((16#${sha: -8}))
    [[ "${FAKE_NO_REVIEW_FOR:-}" != "$n" ]] || { echo '{"check_runs": []}'; exit 0; }
    conclusion=success; [[ "${FAKE_FAIL_REVIEW_FOR:-}" != "$n" ]] || conclusion=failure
    jq -n --arg sha "$sha" --arg conclusion "$conclusion" --argjson run "$((9000 + n))" '{check_runs: [{
      id: $run, name: "agent-review", head_sha: $sha, status: "completed", conclusion: $conclusion,
      external_id: "kg.agent-review.v1:\($run):\($sha)",
      details_url: "https://github.com/Books-Vocab/Books-Vocab/actions/runs/\($run)",
      output: {title: "Independent agent review passed", summary: "Exact head \($sha) reviewed"}}]}' ;;
  repos/*/actions/runs/*)
    run_n=$(( ${endpoint##*/} - 9000 ))
    if [[ "${FAKE_ISSUE_COMMENT_RUN_FOR:-}" == "$run_n" ]]; then
      jq -n '{path: ".github/workflows/agent-review.yml", event: "issue_comment", head_branch: "main", workflow_id: 4242, pull_requests: []}'
    else
      jq -n --argjson n "$run_n" --arg sha "$(printf '%040x' "$run_n")" '{path: ".github/workflows/agent-review.yml", event: "pull_request_target", head_branch: "lane", workflow_id: 4242, pull_requests: [{number: $n, head: {sha: $sha}, base: {ref: "main"}}]}'
    fi ;;
  repos/*/pulls/*)
    n="${endpoint##*/}"; shown="$n"; [[ "${FAKE_DRIFT_FOR:-}" != "$n" ]] || shown=$((n + 1000))
    jq -n --arg sha "$(printf '%040x' "$shown")" '{state: "open", base: {ref: "main"}, head: {sha: $sha}}' ;;
  *) echo "fake gh: unexpected endpoint $endpoint" >&2; exit 2 ;;
esac
FAKE_GH
    chmod +x "$verify_tmp/bin/gh"
    mk_queue() { # solo pos:pr ... -> graphql payload for the fake gh
      local solo="$1" pair nodes="[]"
      shift
      for pair in "$@"; do
        nodes="$(jq -c --argjson pos "${pair%%:*}" --argjson pr "${pair##*:}" --argjson solo "$solo" \
          --arg sha "$(printf '%040x' "${pair##*:}")" \
          '. + [{position: $pos, solo: $solo, state: "QUEUED", headCommit: {oid: $sha},
                 pullRequest: {number: $pr, headRefOid: $sha, baseRefName: "main", state: "OPEN"}}]' <<<"$nodes")"
      done
      jq -n --argjson nodes "$nodes" \
        '{data: {repository: {mergeQueue: {entries: {pageInfo: {hasNextPage: false}, nodes: $nodes}}}}}' \
        >"$verify_tmp/queue.json"
    }
    run_verify() { # target_pr group_numbers -> status of the verify step script
      (cd "$verify_tmp" && PATH="$verify_tmp/bin:$PATH" FAKE_QUEUE_FILE="$verify_tmp/queue.json" \
        GH_TOKEN=fake GITHUB_REF="" REPOSITORY="Books-Vocab/Books-Vocab" \
        MERGE_GROUP_HEAD_SHA="$(printf '%040x' 99)" \
        MERGE_GROUP_HEAD_REF="refs/heads/gh-readonly-queue/main/pr-$1-$(printf '%040x' 98)" \
        MERGE_GROUP_PR_NUMBERS="$2" bash -c "$verify_script") >"$verify_tmp/log" 2>&1
    }
    verify_expect_pass() { # label target group
      run_verify "$2" "$3" || fail "verify step, $1: expected pass, got failure: $(tail -n 3 "$verify_tmp/log")"
    }
    verify_expect_reject() { # label target group message-fragment
      if run_verify "$2" "$3"; then
        fail "verify step, $1: accepted a membership that must be rejected"
      elif ! grep -Fq -- "$4" "$verify_tmp/log"; then
        fail "verify step, $1: rejected for the wrong reason (wanted '$4'): $(tail -n 3 "$verify_tmp/log")"
      fi
    }
    mk_queue false 1:7 2:8
    verify_expect_pass "cumulative group #7,#8 (positive control)" 8 "7,8"
    # Per-PR loop: the target (#8) is clean, so a rejection can only come from #7.
    FAKE_NO_REVIEW_FOR=7 verify_expect_reject "earlier PR #7 without exact-head review" 8 "7,8" \
      "group PR #7 has no trusted exact-head review provenance"
    FAKE_FAIL_REVIEW_FOR=7 verify_expect_reject "earlier PR #7 with a failing exact-head review" 8 "7,8" \
      "latest trusted exact-head agent-review observation is not completed successfully"
    FAKE_DRIFT_FOR=7 verify_expect_reject "earlier PR #7 whose head drifted from its queue entry" 8 "7,8" \
      "group PR #7 HEAD/base/state drifted"
    FAKE_ISSUE_COMMENT_RUN_FOR=7 verify_expect_reject "comment-triggered run with no PR binding (#2765)" 8 "7,8" \
      "group PR #7 has no trusted exact-head review provenance"
    FAKE_NO_REVIEW_FOR=8 verify_expect_reject "target PR #8 without exact-head review" 8 "7,8" \
      "group PR #8 has no trusted exact-head review provenance"
    verify_expect_reject "singleton subset of a cumulative group (review P1)" 8 "8" "at or ahead of the target"
    mk_queue false 1:6 2:7 3:8
    verify_expect_reject "group omitting an earlier queued PR" 8 "7,8" "at or ahead of the target"
    mk_queue false 1:7 2:8 3:9
    verify_expect_pass "entries queued behind the target are not members" 8 "7,8"
    mk_queue false 1:8
    verify_expect_pass "single-entry queue" 8 "8"
    mk_queue true 1:7 2:8
    verify_expect_reject "solo target hiding a preceding PR" 8 "8" "at or ahead of the target"
    verify_expect_pass "solo target whose ref carries the preceding PR" 8 "7,8"
    rm -f "$verify_tmp/queue.json"
    verify_expect_reject "unreadable merge queue" 8 "7,8" "merge queue unreadable"
    rm -rf "$verify_tmp"
  fi
  if grep -q 'maximumEntriesToMerge\|maximum_entries_to_merge' "$MERGE_GROUP_REQUIRED"; then
    fail "merge-group independent review gate infers membership from a configured ceiling"
  fi
  grep -q 'range(.*target_position' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not prove contiguous queue membership"
  grep -q 'for group_pr_number in' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not validate each grouped PR"
  grep -q 'check-runs' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not read PR check evidence"
  grep -q 'sort_by' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not select the latest exact-head review run"
  grep -q 'last' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not select the latest exact-head review run"
  grep -q 'review_candidates=' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate filters review status before selecting the latest observation"
  grep -q 'updated_at' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not order review observations by update time"
  grep -q 'review_status' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not validate the selected latest review status"
  grep -q 'review_provenance' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not isolate malformed review provenance"
  grep -q 'external_id' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not bind evidence to the trusted review check artifact"
  grep -q 'details_url' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not bind evidence to a workflow run"
  grep -q 'workflow_id' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not verify trusted workflow identity"
  grep -q 'agent-review.yml' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not identify the trusted workflow"
  grep -q '^  actions: read$' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not have Actions read permission"
  grep -q 'pull_requests' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not verify PR association"
  grep -q 'head.sha' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not bind PR association to exact HEAD"
  if grep -q 'issue_comment' "$MERGE_GROUP_REQUIRED"; then
    fail "merge-group independent review gate trusts comment-triggered runs that carry no PR binding (#2765)"
  fi
  grep -q 'Independent agent review' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not validate trusted review output"
  grep -q 'startswith' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not distinguish the trusted review artifact"
  grep -q '== "completed"' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not require completed exact-head evidence"
  grep -q '== "success"' "$MERGE_GROUP_REQUIRED" \
    || fail "merge-group independent review gate does not require successful exact-head evidence"
  queue_membership_fixture='[{"position":2},{"position":3},{"position":4},{"position":5}]'
  jq -e 'map(.position) as $positions | ($positions | length) > 0 and (($positions | max) as $target_position | ($positions | sort) == [range(($positions | min); ($target_position + 1))])' \
    <<<"$queue_membership_fixture" >/dev/null \
    || fail "merge-group fixture rejects a valid group larger than three entries"
  noncontiguous_fixture='[{"position":2},{"position":4}]'
  if jq -e 'map(.position) as $positions | ($positions | length) > 0 and (($positions | max) as $target_position | ($positions | sort) == [range(($positions | min); ($target_position + 1))])' \
    <<<"$noncontiguous_fixture" >/dev/null; then
    fail "merge-group fixture accepts non-contiguous membership"
  fi
  review_fixture='[{"updated_at":"2026-08-26T15:00:00Z","status":"completed","conclusion":"success"},{"updated_at":"2026-08-26T15:01:00Z","status":"in_progress","conclusion":""}]'
  latest_review_status="$(jq -r 'sort_by(.updated_at) | last.status' <<<"$review_fixture")"
  [[ "$latest_review_status" == "in_progress" ]] \
    || fail "review fixture does not select the newer in-progress observation"
  malformed_review_fixture='[{"details_url":"not-a-run","external_id":"wrong"}]'
  [[ "$(jq '[.[] | select((.details_url | startswith("https://github.com/")) and (.external_id | startswith("kg.agent-review.v1:")))] | length' <<<"$malformed_review_fixture")" == "0" ]] \
    || fail "review fixture accepts malformed provenance"
fi

# main-watch (Issue #2642): a red area suite on a main push must reach a fix issue
# without running untrusted code or interpolating event data into a shell.
MAIN_WATCH=".github/workflows/main-watch.yml"
ruby -e 'require "yaml"; y = YAML.load_file(ARGV[0]); w = y[true]["workflow_run"]
  exit 1 unless w["types"] == ["completed"] && w["branches"] == ["main"]
  exit 1 unless (%w[backend-quality ios-quality ops-suite design-system ui-quality-gate llm-eval] - w["workflows"]).empty?
  exit 1 unless y["permissions"] == {"contents" => "read", "issues" => "write"}
  exit 1 unless y["concurrency"]["cancel-in-progress"] == false
  exit 1 unless y["concurrency"]["group"] == "main-watch-${{ github.event.workflow_run.name }}"' "$MAIN_WATCH" \
  || fail "main-watch must watch every area suite on main with contents:read + issues:write and never cancel a run"
if grep -Eq '^[[:space:]]+ref:' "$MAIN_WATCH"; then
  fail "main-watch checks out a non-default ref; it must run default-branch code only"
fi
if awk '/^        run:/ { grab=1 } grab' "$MAIN_WATCH" | grep -q '\${{'; then
  fail "main-watch interpolates event data into a run script; pass it through env"
fi
grep -Fq "github.event.workflow_run.event == 'push'" "$MAIN_WATCH" \
  || fail "main-watch does not watch push-triggered runs on main"
grep -Fq "github.event.workflow_run.event == 'schedule'" "$MAIN_WATCH" \
  || fail "main-watch does not watch scheduled runs on main; the daily iOS run could never open a fix issue"
grep -Fq 'ops/main_watch.py' "$MAIN_WATCH" \
  || fail "main-watch does not run ops/main_watch.py"

# macOS queue-wait probe (Issue #2641): every macos-26 job must run it with actions:read.
ruby -e 'require "yaml"; bad = []
  { ARGV[0] => %w[macos-native-ops], ARGV[1] => %w[ios-build ios-tests ios-targeted] }.each do |f, jobs|
    y = YAML.load_file(f)
    jobs.each do |j|
      job = y["jobs"][j]
      bad << "#{f}:#{j}" unless job["permissions"] == {"contents" => "read", "actions" => "read"} && job["steps"].any? { |s| s["run"] == "./ops/ci_macos_queue_probe.sh" }
    end
  end
  abort bad.join(" ") unless bad.empty?' .github/workflows/ops-suite.yml .github/workflows/ios-quality.yml \
  || fail "macos jobs must run ops/ci_macos_queue_probe.sh with actions: read"

# Reusable-workflow callers must grant at least what callee jobs request (a callee can only downgrade the caller token; otherwise startup_failure).
ruby -e 'require "yaml"; rank = {"none"=>0,"read"=>1,"write"=>2}; bad = []
  y = YAML.load_file(".github/workflows/pr-gate.yml")
  y["jobs"].each do |name, cj|
    next unless cj["uses"]
    eff = cj["permissions"] || y["permissions"] || {}
    callee = YAML.load_file(cj["uses"].sub(%r{^\./}, ""))
    callee["jobs"].each do |jn, job|
      (job["permissions"] || {}).each do |scope, lvl|
        bad << "#{name}->#{jn}:#{scope}" if rank[lvl.to_s] > rank[(eff[scope] || "none").to_s]
      end
    end
  end
  abort bad.join(" ") unless bad.empty?' \
  || fail "pr-gate caller jobs grant less than their reusable-workflow callee jobs request"

# Keep Actions on the Node 24 generation.  Pinned SHAs preserve supply-chain
# review while avoiding the hosted-runner Node 20 deprecation path.
for workflow_path in .github/workflows/*.yml; do
  grep -q 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' "$workflow_path" \
    || fail "${workflow_path} is not pinned to checkout v7"
  grep -q 'astral-sh/setup-uv@20cfd1bf945f4377ade1205e4dbc17946fc9a30d # v10.0.1' "$workflow_path" \
    || fail "${workflow_path} is not pinned to setup-uv v10"
done
grep -q 'actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0' .github/workflows/design-system.yml \
  || fail "design-system is not pinned to setup-node v7"
for workflow_path in .github/workflows/backend-quality.yml .github/workflows/ios-quality.yml; do
  grep -q 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' "$workflow_path" \
    || fail "${workflow_path} is not pinned to upload-artifact v7"
done

IOS=".github/workflows/ios-quality.yml"
grep -q "github.event.inputs.runner || 'macos-26'" "$IOS" \
  || fail "iOS workflow has no safe manual hosted-runner benchmark selector"
grep -q '^    timeout-minutes: 25$' "$IOS" \
  || fail "iOS workflow does not use the measured confidence timeout ceiling"
grep -q 'ios_ops.sh build' "$IOS" || fail "iOS workflow has no real Xcode build invocation"
grep -q -- '--unit' "$IOS" || fail "iOS workflow has no unit-test invocation"
grep -q -- '--ui' "$IOS" || fail "iOS workflow has no UI-test invocation"
grep -q -- '--dataset marketing_demo' "$IOS" || fail "UI tests do not pin a UI World dataset"
grep -q 'simulator ensure-booted' "$IOS" || fail "iOS workflow does not resolve a live simulator"
grep -q 'IOS_SIMULATOR_UDID' "$IOS" || fail "iOS workflow does not export an explicit simulator UDID"
grep -q -- '--device "$IOS_SIMULATOR_UDID"' "$IOS" || fail "iOS tests do not target the resolved simulator UDID"
if grep -q 'KG_IOS_TEST_LOG_IDLE_LIMIT' "$IOS"; then
  fail "hosted iOS workflow uses a raw log-silence watchdog; job/XCTest timeouts own liveness"
fi
grep -q "KG_IOS_TEST_MAX_EXECUTION_TIME_ALLOWANCE: '420'" "$IOS" \
  || fail "iOS workflow does not retain the bounded XCTest per-test timeout"
if grep -Eq 'KG_IOS_TEST_LOG_IDLE_LIMIT|LOG_IDLE_LIMIT|log-idle-timeout|log_idle_seconds' \
  ops/ios_test.sh ops/lib/ios_build_progress.sh; then
  fail "iOS test harness still contains a raw log-silence timeout"
fi
if grep -q 'self-hosted\|pull_request_target' "$IOS"; then
  fail "iOS workflow crosses the public fork/self-hosted trust boundary"
fi
grep -q 'actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0' "$IOS" \
  || fail "iOS workflow does not restore the pinned SwiftPM source cache"
grep -q 'actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0' "$IOS" \
  || fail "iOS workflow does not save the pinned SwiftPM source cache"
if grep -q 'KG_IOS_SWIFTPM_CACHE_DIR: \${{ runner.temp }}/kg-ios-swiftpm' "$IOS"; then
  fail "iOS workflow uses runner.temp in job env, which GitHub rejects before scheduling"
fi
grep -q "KG_IOS_SWIFTPM_CACHE_DIR=%s/kg-ios-swiftpm.*\\\$RUNNER_TEMP" "$IOS" \
  || fail "iOS workflow does not export an external SwiftPM cache root for shell steps"
grep -q 'Package.resolved' "$IOS" || fail "iOS SwiftPM cache key is not lockfile-derived"
grep -q "github.event_name == 'schedule' && github.ref == 'refs/heads/main'" "$IOS" \
  || fail "iOS SwiftPM cache is not written only by the trusted scheduled run on main (merge-queue refs cannot seed PR restores)"
# ios-build skips with tests on (#3238), and the daily run has tests on, so the cache
# save must live on a job that runs there: the unit test leg, written once.
ruby -ryaml -e 'jobs = YAML.load_file(ARGV[0])["jobs"]
  save = ->(job) { Array(jobs.dig(job, "steps")).select { |s| s["uses"].to_s.start_with?("actions/cache/save@") } }
  exit 1 unless save.call("ios-build").empty?
  s = save.call("ios-tests")
  exit 1 unless s.size == 1 && s[0]["if"].to_s.include?("matrix.scope == \x27unit\x27") && s[0]["if"].to_s.include?("github.event_name == \x27schedule\x27")' "$IOS" \
  || fail "SwiftPM cache save is not on the unit test leg of ios-tests (ios-build skips with tests on, so the daily run would never write the cache)"
# A red scheduled unit run must still seed the cache (success() skips it); only a
# cancelled run may skip the save. The cache-hit guard keeps restores from re-saving.
ruby -ryaml -e 'steps = YAML.load_file(ARGV[0])["jobs"]["ios-tests"]["steps"]
  save = Array(steps).select { |s| s["name"] == "Save SwiftPM source cache from trusted main" }
  exit 1 unless save.size == 1
  cond = save[0]["if"].to_s
  exit 1 unless cond.include?("!cancelled()") && !cond.include?("success()") && cond.include?("cache-hit != \x27true\x27")' "$IOS" \
  || fail "SwiftPM cache save step must run unless cancelled (!cancelled(), not success()) and keep the cache-hit != 'true' guard"
# SoT docs must describe that exact writer (#3315): the ios-tests unit leg of a
# scheduled main run that is not cancelled, red runs included. The old wording
# (successful runs only, ios-build as writer) contradicts the save step above.
for doc in docs/sop/ios.md docs/reference/ios_deriveddata_policy.md; do
  grep -q 'ios-tests (unit)' "$doc" && grep -q '未被取消' "$doc" \
    || fail "$doc does not name the SwiftPM cache writer (scheduled main ios-tests unit leg, not cancelled)"
  if grep -Eq '只有成功的排程 `main` run|成功的 `main` push 會寫入|中 `ios-build` job 可 save' "$doc"; then
    fail "$doc still says only successful main runs or ios-build write the SwiftPM cache"
  fi
done

# --- iOS selector-aware routing (Issue #1051) --------------------------------
# The router decides; ios-quality re-validates and owns the full fallback. These
# checks pin both the wiring and the executable shell of the two decision steps.
grep -Fq 'ios_mode: ${{ steps.plan.outputs.ios_mode }}' "$PR_GATE" \
  || fail "pr-gate changed-paths does not export the router ios_mode"
grep -Fq 'ios_selectors: ${{ steps.plan.outputs.ios_selectors }}' "$PR_GATE" \
  || fail "pr-gate changed-paths does not export the router ios_selectors"
grep -Fq 'ios_mode: ${{ needs.changed-paths.outputs.ios_mode }}' "$PR_GATE" \
  || fail "pr-gate does not forward ios_mode to ios-quality"
grep -Fq 'ios_selectors: ${{ needs.changed-paths.outputs.ios_selectors }}' "$PR_GATE" \
  || fail "pr-gate does not forward ios_selectors to ios-quality"

ruby -e 'require "yaml"; y = YAML.load_file(ARGV[0]); i = y[true]["workflow_call"]["inputs"]
  exit 1 unless i["ios_mode"]["default"] == "full" && i["ios_selectors"]["default"] == "" &&
    i["ios_mode"]["type"] == "string" && i["ios_selectors"]["type"] == "string" &&
    i["ios_mode"]["required"] == false && i["ios_selectors"]["required"] == false' "$IOS" \
  || fail "ios-quality workflow_call inputs are not optional string inputs defaulting to full"
grep -q '^  plan:' "$IOS" || fail "ios-quality has no fail-closed plan job"
grep -q '^  ios-targeted:' "$IOS" || fail "ios-quality has no targeted job"
# Full path is the default: both full jobs run unless a validated targeted run
# accepted its own result, and a failed/skipped plan still means full. The
# compile check runs only on a PR (run_tests=false). With tests on, the test
# path compiles the same scheme (ios-tests build-for-testing, ios-targeted), so
# ios-build is skipped (#3238: three macOS jobs per merge-group entry, not two).
# The test jobs never run on a PR.
build_gate="if: \${{ always() && inputs.run_tests == 'false' }}"
tests_gate="if: \${{ always() && inputs.run_tests != 'false' && (needs.plan.outputs.mode != 'targeted' || needs.ios-targeted.outputs.fallback_full == 'true') }}"
grep -Fq "$build_gate" "$IOS" \
  || fail "ios-build is not gated as compile-on-PR only (tests on: the test path compiles the scheme)"
grep -Fq "$tests_gate" "$IOS" \
  || fail "ios-tests is not gated as tests-on-only or full-unless-targeted-accepted"
grep -Fq "if: \${{ needs.plan.outputs.mode == 'targeted' && inputs.run_tests != 'false' }}" "$IOS" \
  || fail "targeted job is not gated on a validated targeted plan with tests on"
# Behavioural pin: run the verdict's outcome check against each job-result combination.
# Tests on: a skipped build is correct only because a test path compiles the scheme;
# a failed or unexpectedly skipped test path must fail closed.
ios_verdict_run="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["ios-verdict"]["steps"].find { |s| s["name"] == "Enforce the expected iOS job outcomes" }&.fetch("run", "")' "$IOS")" \
  || fail "cannot extract the ios-verdict outcome check"
[[ -n "$ios_verdict_run" ]] || fail "ios-verdict has no outcome check step (Enforce the expected iOS job outcomes)"
mkdir -p "$ROOT/.cache"
ios_verdict_tmp="$(mktemp -d "$ROOT/.cache/test-ios-verdict-XXXXXX")"
printf '%s\n' "$ios_verdict_run" >"$ios_verdict_tmp/step.sh"
# $1 RUN_TESTS  $2 PLAN_MODE  $3 FALLBACK_FULL  $4 BUILD  $5 TESTS  $6 TARGETED; exit status is the verdict
ios_verdict_case() {
  RUN_TESTS="$1" PLAN_MODE="$2" FALLBACK_FULL="$3" BUILD_RESULT="$4" TESTS_RESULT="$5" TARGETED_RESULT="$6" \
    bash "$ios_verdict_tmp/step.sh" >/dev/null 2>&1
}
ios_verdict_case false full '' success skipped skipped || fail "iOS verdict rejects a green PR compile check"
ios_verdict_case false full '' failure skipped skipped && fail "iOS verdict passes a red PR compile check"
ios_verdict_case false full '' skipped skipped skipped && fail "iOS verdict accepts a skipped PR compile check"
ios_verdict_case false full '' success success skipped && fail "iOS verdict lets tests run on a PR"
ios_verdict_case true full '' skipped success skipped || fail "iOS verdict rejects a full merge-group path with build skipped and tests green"
ios_verdict_case true full '' skipped failure skipped && fail "iOS verdict passes a full merge-group path with red tests"
ios_verdict_case true full '' skipped skipped skipped && fail "iOS verdict accepts unexpectedly skipped full-path tests"
ios_verdict_case true full '' success success skipped && fail "iOS verdict lets the build run alongside tests"
ios_verdict_case true full '' failure success skipped && fail "iOS verdict passes a red build on the test path"
ios_verdict_case true '' '' skipped success skipped || fail "iOS verdict rejects an unplanned (fail-closed full) green test run"
ios_verdict_case true targeted '' skipped skipped success || fail "iOS verdict rejects an accepted green targeted run"
ios_verdict_case true targeted '' skipped skipped failure && fail "iOS verdict passes a red targeted run"
ios_verdict_case true targeted '' skipped success success && fail "iOS verdict passes an accepted targeted run that also ran full tests"
ios_verdict_case true targeted true skipped success success || fail "iOS verdict rejects a green full run after targeted fallback"
ios_verdict_case true targeted true skipped skipped success && fail "iOS verdict accepts a targeted fallback without the full tests"
rm -rf "$ios_verdict_tmp"
# The matrix is planned (Issue #2641): the full set stays unit + ui-smoke, and
# ui-smoke is dropped only when the router reports ui_smoke=false.
grep -Fq "matrix.scope" "$IOS" && grep -Fq 'scope: ${{ fromJSON(needs.plan.outputs.scopes) }}' "$IOS" \
  || fail "ios-tests matrix is not driven by the plan job's scopes output"
grep -Fq -- "scopes='[\"unit\",\"ui-smoke\"]'" "$IOS" \
  || fail "full iOS matrix (unit, ui-smoke) is not the plan default"
grep -Fq -- "scopes='[\"unit\"]'" "$IOS" \
  || fail "ios-quality plan cannot drop ui-smoke when the router reports ui_smoke=false"
grep -Fq "[[ \"\$REQUESTED_UI_SMOKE\" == 'false' ]]" "$IOS" \
  || fail "ui-smoke is dropped on something other than an explicit ui_smoke=false"
# Issue #3269: the ios-build comment must not claim UITests are compiled
# unconditionally; the unit-only plan (ui_smoke=false) never builds them.
grep -Fq 'UITests included' "$IOS" \
  && fail "ios-build comment claims UITests are always compiled; the unit-only plan does not build them"
grep -Fq 'UITests compiled only on the ui-smoke scope' "$IOS" \
  || fail "ios-build comment does not state that UITests compile only on the ui-smoke scope"
ruby -e 'require "yaml"; y = YAML.load_file(ARGV[0]); i = y[true]["workflow_call"]["inputs"]["ui_smoke"]
  exit 1 unless i["default"] == "true" && i["type"] == "string" && i["required"] == false' "$IOS" \
  || fail "ios-quality ui_smoke input is not an optional string defaulting to true"
grep -Fq 'ui_smoke: ${{ steps.plan.outputs.ui_smoke }}' "$PR_GATE" \
  || fail "pr-gate changed-paths does not export the router ui_smoke"
grep -Fq 'ui_smoke: ${{ needs.changed-paths.outputs.ui_smoke }}' "$PR_GATE" \
  || fail "pr-gate does not forward ui_smoke to ios-quality"
# macOS native ops job (Issue #2641): scoped by the router, fail-open to run on
# push/dispatch where the input is absent.
grep -Fq 'macos_ops: ${{ steps.plan.outputs.macos_ops }}' "$PR_GATE" \
  || fail "pr-gate changed-paths does not export the router macos_ops"
grep -Fq 'macos_ops: ${{ needs.changed-paths.outputs.macos_ops }}' "$PR_GATE" \
  || fail "pr-gate does not forward macos_ops to ops-suite"
# A macOS-only change (for example a UITests-only change, which keeps ops=false
# for the iOS targeted path) must still schedule ops-suite, the only job that
# consumes macos_ops. The confidence plan must carry macos_ops so the verdict
# expects that run (CR P2-1, #2641 r2 review).
ruby -e 'require "yaml"; c = YAML.load_file(ARGV[0])["jobs"]["ops-suite"]["if"].to_s
  exit 1 unless c.include?("needs.changed-paths.outputs.ops == \x27true\x27") && c.include?("needs.changed-paths.outputs.macos_ops == \x27true\x27")' "$PR_GATE" \
  || fail "pr-gate ops-suite is not scheduled for macos_ops-only changes"
grep -Fq '"macos_ops":"${{ needs.changed-paths.outputs.macos_ops }}"' "$PR_GATE" \
  || fail "pr-gate confidence plan does not carry macos_ops to the verdict"
ruby -e 'require "yaml"; y = YAML.load_file(ARGV[0]); i = y[true]["workflow_call"]["inputs"]["macos_ops"]
  exit 1 unless i["default"] == "true" && i["type"] == "string" && i["required"] == false
  exit 1 unless y["jobs"]["macos-native-ops"]["if"].to_s.include?("inputs.macos_ops != \x27false\x27")' ".github/workflows/ops-suite.yml" \
  || fail "ops-suite macos-native-ops is not gated on an explicit macos_ops=false"
# Targeted invocation: exactly the planned selectors, no video/visual capture.
grep -Fq "KG_IOS_VISUAL_CAPTURE: '0'" "$IOS" \
  || fail "targeted iOS run does not pin KG_IOS_VISUAL_CAPTURE=0"
if grep -Eq -- '--visual|--visual-capture|KG_IOS_VISUAL_CAPTURE: .1|KG_IOS_VISUAL_ROOT|--video' "$IOS"; then
  fail "iOS workflow enables visual capture or video"
fi
grep -Fq '"${selectors[@]}"' "$IOS" \
  || fail "targeted iOS run does not pass exactly the planned selectors"
if awk '/^  ios-targeted:/{on=1} on' "$IOS" | grep -Eq -- '--file|--grep|-g '; then
  fail "targeted iOS run widens selection beyond the planned selectors"
fi
grep -Fq 'IOS_TARGETED_SELECTORS: ${{ needs.plan.outputs.selectors }}' "$IOS" \
  || fail "targeted job selectors do not come from the validated plan output"
grep -Fq 'false-green-0-executed' "$IOS" \
  || fail "targeted job does not wire the zero-executed guard to the full fallback"
grep -Fq 'fallback_full: ${{ steps.verdict.outputs.fallback_full }}' "$IOS" \
  || fail "targeted job does not export the full-fallback signal"

extract_step_run() {
  ruby -e 'require "yaml"; y = YAML.load_file(ARGV[0])
    step = y["jobs"][ARGV[1]]["steps"].find { |s| s["id"] == ARGV[2] }
    abort "missing step" unless step
    puts step["run"]' "$IOS" "$1" "$2"
}

wf_tmp="$(mktemp -d)"
trap 'rm -rf "$wf_tmp"' EXIT
extract_step_run plan plan > "$wf_tmp/plan.sh"
extract_step_run ios-targeted verdict > "$wf_tmp/verdict.sh"

# plan: only a strictly valid single-line Suite/Method list stays targeted.
plan_mode() {
  local out="$wf_tmp/plan.out"
  : > "$out"
  REQUESTED_MODE="$1" REQUESTED_SELECTORS="$2" REQUESTED_UI_SMOKE="${PLAN_UI_SMOKE:-}" GITHUB_OUTPUT="$out" bash "$wf_tmp/plan.sh" >/dev/null 2>&1 || { echo ERROR; return; }
  grep '^mode=' "$out" | head -1 | cut -d= -f2-
}
# Full-path test scopes (Issue #2641): only an explicit 'false' drops ui-smoke.
plan_scopes() {
  local out="$wf_tmp/plan.out"
  : > "$out"
  REQUESTED_MODE=full REQUESTED_SELECTORS='' REQUESTED_UI_SMOKE="$1" GITHUB_OUTPUT="$out" bash "$wf_tmp/plan.sh" >/dev/null 2>&1 || { echo ERROR; return; }
  grep '^scopes=' "$out" | head -1 | cut -d= -f2-
}
for ui_value in '' true TRUE garbage; do
  [[ "$(plan_scopes "$ui_value")" == '["unit","ui-smoke"]' ]] \
    || fail "ios plan: ui_smoke='$ui_value' must keep the full (unit, ui-smoke) matrix, got $(plan_scopes "$ui_value")"
done
[[ "$(plan_scopes false)" == '["unit"]' ]] \
  || fail "ios plan: ui_smoke=false must run unit only, got $(plan_scopes false)"
expect_plan() {
  local label="$1" mode="$2" selectors="$3" expected="$4" actual
  actual="$(plan_mode "$mode" "$selectors")"
  [[ "$actual" == "$expected" ]] || fail "ios plan: $label expected $expected, got $actual"
}
expect_plan 'valid single selector' targeted 'OverviewFlowUITests/testA' targeted
expect_plan 'valid multiple selectors' targeted 'OverviewFlowUITests/testA OverviewFlowUITests/testB' targeted
expect_plan 'missing mode' '' 'OverviewFlowUITests/testA' full
expect_plan 'explicit full' full 'OverviewFlowUITests/testA' full
expect_plan 'case-variant mode' TARGETED 'OverviewFlowUITests/testA' full
expect_plan 'unknown mode' narrow 'OverviewFlowUITests/testA' full
expect_plan 'targeted without selectors' targeted '' full
expect_plan 'whitespace-only selectors' targeted '   ' full
expect_plan 'suite-only selector' targeted 'OverviewFlowUITests' full
expect_plan 'target-qualified selector' targeted 'BooksAndVocabUITests/OverviewFlowUITests/testA' full
expect_plan 'valid plus invalid selector' targeted 'OverviewFlowUITests/testA bad' full
expect_plan 'shell metacharacters' targeted 'OverviewFlowUITests/test;rm' full
expect_plan 'command substitution' targeted '$(id)/testA' full
expect_plan 'newline output injection' targeted $'OverviewFlowUITests/testA\nmode=targeted' full

# verdict: success needs the exact executed count; zero-test guard and count
# mismatch fall back to full; genuine red stays red.
run_verdict() {
  local outcome="$1" verdict="$2" out="$wf_tmp/verdict.out" json="$wf_tmp/verdict.json" rc=0
  : > "$out"
  rm -f "$json"
  [[ "$verdict" == '-' ]] || printf '%s\n' "$verdict" > "$json"
  RUN_OUTCOME="$outcome" VERDICT_JSON="$json" IOS_TARGETED_SELECTORS='OverviewFlowUITests/testA OverviewFlowUITests/testB' \
    GITHUB_OUTPUT="$out" bash "$wf_tmp/verdict.sh" >/dev/null 2>&1 || rc=$?
  if grep -qx 'fallback_full=true' "$out"; then
    echo "fallback rc=$rc"
  else
    echo "plain rc=$rc"
  fi
}
expect_verdict() {
  local label="$1" outcome="$2" verdict="$3" expected="$4" actual
  actual="$(run_verdict "$outcome" "$verdict")"
  [[ "$actual" == "$expected" ]] || fail "ios verdict: $label expected '$expected', got '$actual'"
}
expect_verdict 'exact executed count passes' success '{"result":"ok","executed":"2"}' 'plain rc=0'
expect_verdict 'executed below selector count falls back' success '{"result":"ok","executed":"1"}' 'fallback rc=0'
expect_verdict 'executed above selector count falls back' success '{"result":"ok","executed":"3"}' 'fallback rc=0'
expect_verdict 'zero executed falls back' success '{"result":"ok","executed":"0"}' 'fallback rc=0'
expect_verdict 'missing executed falls back' success '{"result":"ok","executed":null}' 'fallback rc=0'
expect_verdict 'non-numeric executed falls back' success '{"result":"ok","executed":"two"}' 'fallback rc=0'
expect_verdict 'success without a verdict file falls back' success - 'fallback rc=0'
expect_verdict 'harness zero-test guard falls back' failure '{"result":"fail","reason":"false-green-0-executed","executed":"0"}' 'fallback rc=0'
expect_verdict 'genuine test failure stays red' failure '{"result":"fail","reason":"tests-failed","executed":"2"}' 'plain rc=1'
expect_verdict 'build failure stays red' failure '{"result":"fail","reason":"build-failed","executed":null}' 'plain rc=1'
expect_verdict 'failure without a verdict stays red' failure - 'plain rc=1'
expect_verdict 'cancelled run stays red' cancelled - 'plain rc=1'


OPS=".github/workflows/ops-suite.yml"
grep -q 'fromJSON' "$OPS" || fail "ops-suite does not derive its matrix from the classified group list"
grep -q 'matrix.shard' "$OPS" || fail "ops-suite has no parallel shard matrix"
grep -q 'SHARD_COUNT' "$OPS" || fail "ops-suite does not pin the shard partition count"
if grep -q 'Run platform-independent ops groups' "$OPS"; then
  fail "ops-suite still runs all Linux groups serially"
fi
# Issue #2064: lab/podcast tests run in the lab-podcast group, so a push that
# only touches lab/podcast must still trigger ops-suite (the PR path is the router).
grep -Fq "      - 'lab/podcast/**'" "$OPS" \
  || fail "ops-suite push paths do not cover lab/podcast/** (lab-podcast group)"

# --- Token scope and liveness ceilings (Issue #2070) -------------------------
# Every workflow pins its own GITHUB_TOKEN scope instead of inheriting the repo
# default (read today, but a settings change would silently widen it), and every
# job that runs steps carries its own timeout. A `uses:` job delegates the
# timeout to the called workflow, but its own permissions are still checked.
# Writes, at workflow or job level, must match an allowlist entry with exactly the
# keys workflow, job (null = workflow-level, else a job name), scope and reason;
# write-all is never allowlistable, and a stale entry is itself a violation.
WRITE_ALLOWLIST="ops/tests/github_workflow_write_allowlist.json"
! compgen -G '.github/workflows/*.yaml' >/dev/null || fail "a .yaml workflow escapes every *.yml guard in this file; rename it to .yml"
workflow_hardening_violations() {
  ruby -e 'require "yaml"; require "json"
    keys = %w[workflow job scope reason]
    allow = JSON.parse(File.read(ARGV.shift))["entries"].each_with_index.select do |e, i|
      e = {} unless e.is_a?(Hash)
      errs = [("missing key(s) #{(keys - e.keys).join(", ")}" if (keys - e.keys).any?),
        ("unknown key(s) #{(e.keys - keys).join(", ")}" if (e.keys - keys).any?)].compact
      errs << "workflow, scope and reason must be non-empty strings" unless errs.any? || %w[workflow scope reason].all? { |k| e[k].is_a?(String) && !e[k].strip.empty? }
      errs << "job must be null (workflow-level) or a non-empty string" unless errs.any? || e["job"].nil? || (e["job"].is_a?(String) && !e["job"].strip.empty?)
      puts("allowlist entry #{i}: #{errs.join("; ")}") if errs.any?
      errs.empty?
    end.map(&:first)
    used = []
    check = lambda do |path, job, perms|
      where = "#{path}: #{job ? "job #{job}" : "top-level"} permissions"
      next puts("#{where} is #{perms.inspect}") unless perms.is_a?(Hash) || perms == "read-all"
      (perms == "read-all" ? {} : perms).each do |scope, value|
        next if %w[read none].include?(value)
        hit = allow.find { |e| [e["workflow"], e["job"], e["scope"]] == [File.basename(path), job, scope] }
        next used << hit if value == "write" && hit
        puts "#{where} #{scope}: #{value.inspect} is not read/none or an allowlisted write"
      end
    end
    ARGV.each do |path|
      y = YAML.load_file(path)
      y.key?("permissions") ? check.(path, nil, y["permissions"]) : puts("#{path}: no top-level permissions")
      (y["jobs"] || {}).each do |name, job|
        check.(path, name, job["permissions"]) if job.key?("permissions")
        next if job.key?("uses")
        puts "#{path}: job #{name} has no timeout-minutes" unless job.key?("timeout-minutes")
      end
    end
    (allow - used).each { |e| puts "allowlist: #{e["workflow"]} #{e["job"] ? "job #{e["job"]}" : "top-level"} #{e["scope"]} matches no write grant" }' "$@"
}
if hardening_report="$(workflow_hardening_violations "$WRITE_ALLOWLIST" .github/workflows/*.yml)"; then
  while IFS= read -r violation; do
    if [[ -n "$violation" ]]; then
      fail "$violation"
    fi
  done <<<"$hardening_report"
else
  fail "workflow hardening checker could not read .github/workflows/*.yml"
fi

# Positive control: the checker must name each defect in a fixture that has
# them (mapped and job-level writes, write-all, invalid or stale allowlist
# entries), and must pass `uses:` jobs, read-only maps and allowlisted writes.
hardening_tmp="$wf_tmp/hardening"
mkdir -p "$hardening_tmp"
cat >"$hardening_tmp/bare.yml" <<'YAML'
on: push
jobs: {steps-job: {steps: [{run: 'true'}]}, reusable-job: {uses: ./.github/workflows/llm-eval.yml}}
YAML
cat >"$hardening_tmp/write-all.yml" <<'YAML'
{on: push, permissions: write-all, jobs: {bounded: {timeout-minutes: 1}}}
YAML
cat >"$hardening_tmp/mixed.yml" <<'YAML'
on: push
permissions: {contents: write, statuses: write, deployments: write}
jobs:
  job-write-all: {timeout-minutes: 1, permissions: write-all}
  job-unlisted: {timeout-minutes: 1, permissions: {pull-requests: write}}
  job-listed: {timeout-minutes: 1, permissions: {issues: write, contents: read}}
  job-read-only: {timeout-minutes: 1, permissions: {contents: read, actions: none}}
  job-read-all: {timeout-minutes: 1, permissions: read-all}
  job-none: {timeout-minutes: 1, permissions: {}}
YAML
# Entries 0-1 are valid grants; 2-8 must not authorize (stale, wrong job, wrong workflow, no reason,
# missing job key, misspelled job key, empty job). 6-7 would otherwise read as job nil = top-level.
cat >"$hardening_tmp/allow.json" <<'JSON'
{"entries": [{"workflow": "mixed.yml", "job": null, "scope": "statuses", "reason": "r"},
  {"workflow": "mixed.yml", "job": "job-listed", "scope": "issues", "reason": "r"},
  {"workflow": "mixed.yml", "job": "job-read-only", "scope": "contents", "reason": "r"},
  {"workflow": "mixed.yml", "job": "job-write-all", "scope": "contents", "reason": "r"},
  {"workflow": "write-all.yml", "job": "job-unlisted", "scope": "pull-requests", "reason": "r"},
  {"workflow": "mixed.yml", "job": "job-unlisted", "scope": "pull-requests", "reason": " "},
  {"workflow": "mixed.yml", "scope": "contents", "reason": "r"},
  {"workflow": "mixed.yml", "jobs": null, "scope": "deployments", "reason": "r"},
  {"workflow": "mixed.yml", "job": "", "scope": "pull-requests", "reason": "r"}]}
JSON
expected_fixture_report="allowlist entry 5: workflow, scope and reason must be non-empty strings
allowlist entry 6: missing key(s) job
allowlist entry 7: missing key(s) job; unknown key(s) jobs
allowlist entry 8: job must be null (workflow-level) or a non-empty string
$hardening_tmp/bare.yml: no top-level permissions
$hardening_tmp/bare.yml: job steps-job has no timeout-minutes
$hardening_tmp/write-all.yml: top-level permissions is \"write-all\"
$hardening_tmp/mixed.yml: top-level permissions contents: \"write\" is not read/none or an allowlisted write
$hardening_tmp/mixed.yml: top-level permissions deployments: \"write\" is not read/none or an allowlisted write
$hardening_tmp/mixed.yml: job job-write-all permissions is \"write-all\"
$hardening_tmp/mixed.yml: job job-unlisted permissions pull-requests: \"write\" is not read/none or an allowlisted write
allowlist: mixed.yml job job-read-only contents matches no write grant
allowlist: mixed.yml job job-write-all contents matches no write grant
allowlist: write-all.yml job job-unlisted pull-requests matches no write grant"
actual_fixture_report="$(workflow_hardening_violations "$hardening_tmp/allow.json" "$hardening_tmp"/{bare,write-all,mixed}.yml 2>&1 || true)"
[[ "$actual_fixture_report" == "$expected_fixture_report" ]] \
  || fail "workflow hardening checker positive control: expected [$expected_fixture_report], got [$actual_fixture_report]"

# Falsification: every real allowlist entry is load-bearing. Dropping any one
# must turn the live check red with exactly that grant.
while IFS=$'\t' read -r index workflow where scope; do
  jq "del(.entries[$index])" "$WRITE_ALLOWLIST" >"$hardening_tmp/drop.json"
  dropped_report="$(workflow_hardening_violations "$hardening_tmp/drop.json" .github/workflows/*.yml 2>&1 || true)"
  grep -Fxq ".github/workflows/$workflow: $where permissions $scope: \"write\" is not read/none or an allowlisted write" <<<"$dropped_report" \
    || fail "dropping allowlist entry $index ($workflow $where $scope) left the live check green: [$dropped_report]"
done < <(jq -r '.entries | to_entries[] | [.key, .value.workflow, (if .value.job then "job \(.value.job)" else "top-level" end), .value.scope] | @tsv' "$WRITE_ALLOWLIST")

# --- iOS test suites run once per change, in the merge queue (2026-10-11) ---
# PR heads compile only: pr-gate passes run_tests=false, so every iOS test job is
# skipped by design and ios-build is the compile check. The merge queue runs the
# full suite once on the exact tree it merges, behind the router, and `required`
# aggregates it. main runs the suite on a daily schedule and has no push trigger.
# Checked on parsed YAML, because a grep cannot tell a trigger from a comment.
cat >"$wf_tmp/ios-suite-contract.rb" <<'RUBY'
require "yaml"

def triggers(workflow)
  workflow[true] || workflow["on"] || {}
end

def hash_or_empty(value)
  value.is_a?(Hash) ? value : {}
end

ios = YAML.load_file(ARGV[0]) || {}
pr = YAML.load_file(ARGV[1]) || {}
mg = YAML.load_file(ARGV[2]) || {}
out = []

on = triggers(ios)
out << "ios-quality still has a push trigger; main is validated once, by the merge queue" if on.key?("push")
unless Array(on["schedule"]).map { |s| s["cron"] } == ["17 19 * * *"]
  out << "ios-quality has no daily schedule at '17 19 * * *' on main"
end
out << "ios-quality lost workflow_dispatch" unless on.key?("workflow_dispatch")
call = hash_or_empty(on["workflow_call"])
run_tests = hash_or_empty(call["inputs"])["run_tests"]
unless hash_or_empty(run_tests)["type"] == "string" && run_tests["default"] == "true" && run_tests["required"] == false
  out << "ios-quality run_tests is not an optional string input defaulting to 'true'"
end
%w[build_result tests_result targeted_result].each do |name|
  value = hash_or_empty(hash_or_empty(call["outputs"])[name])["value"].to_s
  unless value.start_with?("${{ jobs.ios-verdict.outputs.")
    out << "ios-quality workflow_call output #{name} is not read from jobs.ios-verdict"
  end
end

jobs = hash_or_empty(ios["jobs"])
%w[ios-tests ios-targeted].each do |name|
  unless hash_or_empty(jobs[name])["if"].to_s.include?("inputs.run_tests != 'false'")
    out << "ios-quality #{name} is not skipped when run_tests is false (PRs must stay compile-only)"
  end
end
unless hash_or_empty(jobs["ios-build"])["if"].to_s.include?("inputs.run_tests == 'false'")
  out << "ios-build does not run on PRs (run_tests == 'false'), so a PR has no compile check"
end
if hash_or_empty(jobs["plan"]).key?("if")
  out << "ios-plan is gated by a condition; it must always run"
end
verdict = hash_or_empty(jobs["ios-verdict"])
unless Array(verdict["needs"]).sort == %w[ios-build ios-targeted ios-tests plan] && verdict["if"].to_s.include?("always()")
  out << "ios-verdict must aggregate plan, ios-build, ios-tests and ios-targeted under always()"
end

pr_ios = hash_or_empty(hash_or_empty(pr["jobs"])["ios-quality"])
unless hash_or_empty(pr_ios["with"])["run_tests"] == "false"
  out << "pr-gate ios-quality does not pass run_tests: 'false'; PRs would run the iOS test suite"
end

mg_jobs = hash_or_empty(mg["jobs"])
short = hash_or_empty(mg_jobs["short-gate"])
unless short["name"] == "short-gate"
  out << "merge-group short-gate job is missing or not named short-gate"
end
%w[ios ios_mode ios_selectors ui_smoke].each do |key|
  unless hash_or_empty(short["outputs"])[key].to_s == "${{ steps.scope.outputs.#{key} }}"
    out << "merge-group short-gate output #{key} is not read from steps.scope"
  end
end

route = hash_or_empty(mg_jobs["route"])
out << "merge-group route job is missing (the iOS router decision must not wait for short-gate)" if route.empty?
unless Array(route["needs"]).empty?
  out << "merge-group route job must not depend on other jobs"
end
route_out = hash_or_empty(route["outputs"])
%w[ios ios_mode ios_selectors ui_smoke].each do |key|
  unless route_out[key].to_s == "${{ steps.scope.outputs.#{key} }}"
    out << "merge-group route output #{key} is not read from steps.scope"
  end
end
route_run = Array(route["steps"]).map { |s| s["run"].to_s }.join("\n")
unless route_run.include?("ci_scope_router.sh --base") && route_run.include?("--format github-output")
  out << "merge-group route job does not run the scope router"
end

ios_call = hash_or_empty(mg_jobs["ios-quality"])
unless Array(ios_call["needs"]) == ["route"]
  out << "merge-group ios-quality must need only route (not short-gate), so iOS starts in parallel with the short gate"
end
unless ios_call["if"].to_s.include?("needs.route.outputs.ios == 'true'")
  out << "merge-group ios-quality is not gated by the route output ios == 'true'"
end
unless ios_call["uses"] == "./.github/workflows/ios-quality.yml"
  out << "merge-group ios-quality does not call ios-quality.yml"
end
call_with = hash_or_empty(ios_call["with"])
unless call_with["run_tests"] == "true"
  out << "merge-group ios-quality does not run the test suite (run_tests: 'true')"
end
%w[ios_mode ios_selectors ui_smoke].each do |key|
  unless call_with[key].to_s == "${{ needs.route.outputs.#{key} }}"
    out << "merge-group ios-quality #{key} is not forwarded from route"
  end
end
unless ios_call["permissions"] == { "contents" => "read", "actions" => "read" }
  out << "merge-group ios-quality permissions are not exactly contents and actions read"
end

agg = hash_or_empty(mg_jobs["required"])
unless agg["name"] == "required"
  out << "merge-group aggregator is missing or not named required (the context branch protection reads)"
end
out << "merge-group required must run under if: always()" unless agg["if"].to_s.include?("always()")
unless Array(agg["needs"]).sort == %w[ios-quality ops-suite short-gate]
  out << "merge-group required must need exactly short-gate, ios-quality and ops-suite"
end
out << "merge-group required must be bounded to five minutes" unless agg["timeout-minutes"] == 5
if Array(agg["needs"]).include?("agent-review")
  out << "merge-group required must not depend on agent-review (it did not before)"
end
puts out
RUBY
while IFS= read -r contract_failure; do
  [[ -n "$contract_failure" ]] && fail "$contract_failure"
done < <(ruby "$wf_tmp/ios-suite-contract.rb" .github/workflows/ios-quality.yml .github/workflows/pr-gate.yml .github/workflows/merge-group-required.yml 2>&1 || echo "iOS suite contract check could not parse the workflows")

# --- Push-to-main runs must never be cancelled by a newer push ----------------
# Merges land every few minutes. A workflow that has a `push` trigger and an
# unconditional `cancel-in-progress: true` cancels every previous main run when
# the next merge lands, so no post-merge run ever completes (ios-quality lost
# its only post-merge iOS health signal this way). Only pull_request runs may
# cancel in progress; push/dispatch runs queue (one running + one pending, a
# newer pending replaces an older pending), so the latest main commit is always
# validated to completion. Workflows without a `push` trigger are out of scope.
push_cancel_violations() {
  ruby -e 'require "yaml"
    ARGV.each do |path|
      y = YAML.load_file(path)
      on = y[true] || y["on"]
      next unless on.is_a?(Hash) && on.key?("push")
      next unless y["concurrency"].is_a?(Hash)
      cancel = y["concurrency"]["cancel-in-progress"]
      puts "#{path}: push-triggered workflow cancels in-progress runs unconditionally" if cancel == true
    end' "$@"
}
live_push_cancel="$(push_cancel_violations .github/workflows/*.yml 2>&1 || true)"
[[ -z "$live_push_cancel" ]] \
  || fail "push-triggered workflow cancels main runs: [$live_push_cancel]"
grep -Fxq "  cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$IOS" \
  || fail "ios-quality does not restrict cancel-in-progress to pull_request runs"
# Positive control: the checker flags an unconditional cancel next to a push
# trigger and passes the conditional form and a pull_request-only workflow.
cancel_tmp="$wf_tmp/cancel"
mkdir -p "$cancel_tmp"
cat >"$cancel_tmp/push-cancel.yml" <<'YAML'
on: {push: {branches: [main]}}
concurrency: {group: g, cancel-in-progress: true}
jobs: {}
YAML
cat >"$cancel_tmp/push-conditional.yml" <<'YAML'
on: {push: {branches: [main]}}
concurrency: {group: g, cancel-in-progress: "${{ github.event_name == 'pull_request' }}"}
jobs: {}
YAML
cat >"$cancel_tmp/pr-only.yml" <<'YAML'
on: {pull_request: {}}
concurrency: {group: g, cancel-in-progress: true}
jobs: {}
YAML
expected_cancel_report="$cancel_tmp/push-cancel.yml: push-triggered workflow cancels in-progress runs unconditionally"
actual_cancel_report="$(push_cancel_violations "$cancel_tmp"/{push-cancel,push-conditional,pr-only}.yml 2>&1 || true)"
[[ "$actual_cancel_report" == "$expected_cancel_report" ]] \
  || fail "push cancel checker positive control: expected [$expected_cancel_report], got [$actual_cancel_report]"

# --- PR diffs start at the merge base, never at the base branch tip -----------
# `pull_request.base.sha` is main's tip when the run starts, not the PR's fork
# point. Once main has moved past the fork, `git diff BASE HEAD` also contains
# the reverse of every newer main commit, so repo-gate reported whitespace
# errors in files the PR never touched (PR #2291 failed on
# ops/felix_compute_worker.py, which #2285 deleted on main after the fork).
# Any diff that means "this PR's changes" must start from `git merge-base`.
# merge_group workflows are exempt: a queue group's head contains its base, so
# base..head already is the group's change set.
two_point_diff_violations() {
  local file
  for file in "$@"; do
    # Drop `$(git merge-base ...)` operands first: they legitimately mention
    # both SHAs but are the fix, not the defect.
    sed -E 's/\$\(git merge-base [^)]*\)/MERGE_BASE/g' "$file" \
      | grep -nE 'git diff[^|;&]*(\$\{?BASE_SHA\}?"?[[:space:]]+"?\$\{?HEAD_SHA|\$\{?BASE_SHA\}?"?\.\.[^.])' \
      | sed "s|^|${file}:|" || true
  done
}
pr_diff_workflows=()
for workflow_file in .github/workflows/*.yml; do
  grep -Eq '^[[:space:]]*merge_group:' "$workflow_file" || pr_diff_workflows+=("$workflow_file")
done
live_two_point="$(two_point_diff_violations "${pr_diff_workflows[@]}")"
[[ -z "$live_two_point" ]] \
  || fail "PR workflow diffs BASE_SHA against HEAD_SHA directly instead of the merge base: [$live_two_point]"

# Positive control: the checker names each two-point spelling and passes the
# merge-base forms (inline `$(git merge-base ...)`, a variable, three-dot).
tp_tmp="$wf_tmp/two-point"
mkdir -p "$tp_tmp"
cat >"$tp_tmp/bad.yml" <<'YAML'
        run: |
          git diff --check "$BASE_SHA" "$HEAD_SHA"
          git diff --name-only --diff-filter=d "$BASE_SHA" "$HEAD_SHA" -- '*.py'
          git diff --stat ${BASE_SHA} ${HEAD_SHA}
          git diff "$BASE_SHA".."$HEAD_SHA"
YAML
cat >"$tp_tmp/good.yml" <<'YAML'
        run: |
          git diff --check "$(git merge-base "$BASE_SHA" "$HEAD_SHA")" "$HEAD_SHA"
          git diff --check "$merge_base" "$HEAD_SHA"
          git diff "$BASE_SHA"..."$HEAD_SHA"
          git merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA"
YAML
tp_bad_lines="$(two_point_diff_violations "$tp_tmp/bad.yml" | cut -d: -f2 | tr '\n' ' ')"
[[ "$tp_bad_lines" == '2 3 4 5 ' ]] \
  || fail "two-point diff checker positive control: expected lines [2 3 4 5 ], got [$tp_bad_lines]"
tp_good_report="$(two_point_diff_violations "$tp_tmp/good.yml")"
[[ -z "$tp_good_report" ]] \
  || fail "two-point diff checker flags merge-base forms: [$tp_good_report]"

# Behavior: run the real pr-gate steps against a repository whose base branch
# moved past the PR's fork point (deleting a file whose blank line at EOF is a
# `git diff --check` error, and adding a Python file the PR never touched).
extract_named_step_run() {
  ruby -e 'require "yaml"; y = YAML.load_file(ARGV[0])
    step = y["jobs"][ARGV[1]]["steps"].find { |s| s["name"] == ARGV[2] }
    abort "missing step #{ARGV[2]}" unless step
    puts step["run"]' "$1" "$2" "$3"
}
mb_dir="$wf_tmp/merge-base"
mb_repo="$mb_dir/repo"
mkdir -p "$mb_repo" "$mb_dir/bin"
extract_named_step_run "$PR_GATE" repo-gate "Check repository diff" > "$mb_dir/diff-check.sh"
extract_named_step_run "$PR_GATE" repo-gate "Check changed Python formatting" > "$mb_dir/format.sh"
# `uv` stub: record the arguments instead of downloading and running ruff.
cat >"$mb_dir/bin/uv" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$UV_ARGS_OUT"
SH
chmod +x "$mb_dir/bin/uv"
(
  cd "$mb_repo"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  git init -q -b main
  git config commit.gpgsign false
  git config core.hooksPath /dev/null
  printf 'clean\n' > clean.txt
  printf 'quirk\n\n' > legacy.txt
  printf 'x = 1\n' > old.py
  git add -A
  git commit -q -m fork-point
  git checkout -q -b pr
  printf 'feature\n' > feature.txt
  printf 'y = 2\n' > pr.py
  git add -A
  git commit -q -m pr-change
  git checkout -q -b pr-dirty main
  printf 'trailing  \n' > dirty.txt
  git add -A
  git commit -q -m pr-whitespace-error
  git checkout -q main
  git rm -q legacy.txt old.py
  printf 'z = 3\n' > main_only.py
  git add -A
  git commit -q -m main-moves-on
  git checkout -q -b pr-rebased main
  printf 'w = 4\n' > rebased.py
  git add -A
  git commit -q -m pr-on-top-of-main
)
mb_run() { # <script> <base ref> <head ref> -> step exit status; extra env passes through
  local script="$1" base="$2" head="$3" rc=0
  (
    cd "$mb_repo"
    git checkout -q --detach "$head"
    BASE_SHA="$(git rev-parse "$base")" HEAD_SHA="$(git rev-parse "$head")" bash "$script" >/dev/null 2>&1
  ) || rc=$?
  echo "$rc"
}
mb_rc="$(mb_run "$mb_dir/diff-check.sh" main pr)"
[[ "$mb_rc" == 0 ]] \
  || fail "repo-gate diff check fails a PR that never touched a file main deleted after the fork (exit $mb_rc)"
mb_rc="$(mb_run "$mb_dir/diff-check.sh" main pr-dirty)"
[[ "$mb_rc" != 0 ]] \
  || fail "repo-gate diff check passes a PR that introduces trailing whitespace (positive control)"
mb_py() { # <base ref> <head ref> -> python paths handed to ruff
  local out="$mb_dir/uv-args.$1.$2" rc
  rc="$(UV_ARGS_OUT="$out" PATH="$mb_dir/bin:$PATH" mb_run "$mb_dir/format.sh" "$1" "$2")"
  if [[ "$rc" == 0 && -f "$out" ]]; then
    grep -E '\.py$' "$out" | tr '\n' ' '
  else
    printf 'exit-%s' "$rc"
  fi
}
mb_py_got="$(mb_py main pr)"
[[ "$mb_py_got" == 'pr.py ' ]] \
  || fail "format step lists main's post-fork Python changes for a diverged PR: [$mb_py_got]"
mb_py_got="$(mb_py main pr-rebased)"
[[ "$mb_py_got" == 'rebased.py ' ]] \
  || fail "format step mislists Python paths for a PR already on top of base: [$mb_py_got]"

# Parse all workflow YAML with the runner's ubiquitous Ruby runtime. This
# catches indentation/anchor errors before GitHub has to schedule a runner.
# macOS ships Ruby 2.6, whose Psych does not accept the newer `aliases:`
# keyword; ordinary YAML.load_file still parses the anchored path lists used
# here and keeps this local contract compatible with both runner generations.
if ! ruby -e 'require "yaml"; ARGV.each { |path| YAML.load_file(path) }' .github/workflows/*.yml; then
  fail "workflow YAML does not parse"
fi

# --- Closed-PR run cancel (Issue #2641 retro 2026-10-09) ---------------------
# pr-closed-run-cancel may cancel PR-event runs on a closed PR's head, but never
# on the head of an open PR (the old open-PR reaper cancelled 346 runs and let
# #2412 reach main), and never a push run that shares the SHA after a
# fast-forward merge. A stub gh replays fixtures and records POSTs; the workflow's
# own cancel-runs step script is what runs, so the rule itself is exercised.
CANCEL_WF=".github/workflows/pr-closed-run-cancel.yml"
if [[ ! -f "$CANCEL_WF" ]]; then
  fail "$CANCEL_WF is missing: closed PRs keep their queued runs"
else
  ruby -ryaml -e 'y = YAML.load_file(ARGV[0]); on = y.fetch("on", y[true]); exit(on == {"pull_request" => {"types" => ["closed"]}} ? 0 : 1)' "$CANCEL_WF" \
    || fail "$CANCEL_WF must trigger on pull_request types [closed] and nothing else"
  grep -Fq 'github.event.pull_request.head.repo.full_name == github.repository' "$CANCEL_WF" \
    || fail "$CANCEL_WF does not skip fork PRs (their token is read-only)"
  cancel_step="$wf_tmp/cancel-step.sh"
  ruby -ryaml -e 'y = YAML.load_file(ARGV[0]); s = y["jobs"].values.flat_map { |j| j["steps"] || [] }.find { |st| st["id"] == "cancel-runs" }; abort("no cancel-runs step") unless s; File.write(ARGV[1], s["run"])' "$CANCEL_WF" "$cancel_step" 2>/dev/null \
    || fail "$CANCEL_WF has no cancel-runs step"
  cancel_bin="$wf_tmp/cancel-bin"
  mkdir -p "$cancel_bin"
  cat >"$cancel_bin/gh" <<'STUB'
#!/usr/bin/env bash
# Replays the fixture for each GET (--jq applied with real jq) and logs POST paths.
if [[ "$2" == "-X" ]]; then printf '%s\n' "$4" >>"$CANCEL_LOG"; exit 0; fi
case "$*" in
  *pulls*) src="$CANCEL_FIXTURES/open-pulls.json" ;;
  *status=queued*) src="$CANCEL_FIXTURES/runs-queued.json" ;;
  *status=in_progress*) src="$CANCEL_FIXTURES/runs-in_progress.json" ;;
  *) src="$CANCEL_FIXTURES/none.json" ;;
esac
jq_expr="."
while (( $# )); do
  [[ "$1" == --jq ]] && jq_expr="$2"
  shift
done
jq -r "$jq_expr" "$src"
STUB
  chmod +x "$cancel_bin/gh"
  # cancel_case <name> <open-PR head sha> -> cancelled run ids, or step-exit-nonzero
  cancel_case() {
    local dir="$wf_tmp/cancel-$1" closed_sha=cafe0000
    mkdir -p "$dir"
    printf '[{"number": 7, "head": {"sha": "%s"}}]\n' "$2" >"$dir/open-pulls.json"
    printf '{"workflow_runs": [{"id": 11, "event": "pull_request", "head_sha": "%s"}, {"id": 12, "event": "push", "head_sha": "%s"}]}\n' "$closed_sha" "$closed_sha" >"$dir/runs-queued.json"
    # Assumption under test: the in-progress PR run is a pull_request event. The
    # base-context trigger is deliberately absent from the filter (its head_sha is unverified).
    printf '{"workflow_runs": [{"id": 13, "event": "pull_request", "head_sha": "%s"}]}\n' "$closed_sha" >"$dir/runs-in_progress.json"
    printf '{"workflow_runs": []}\n' >"$dir/none.json"
    : >"$dir/posts.log"
    if ! env PATH="$cancel_bin:$PATH" GH_TOKEN=test REPO=owner/repo HEAD_SHA="$closed_sha" \
      CANCEL_FIXTURES="$dir" CANCEL_LOG="$dir/posts.log" bash "$cancel_step" >"$dir/step.log" 2>&1; then
      printf 'step-exit-nonzero'
      return
    fi
    sed -n 's#.*/actions/runs/\([0-9]*\)/cancel#\1#p' "$dir/posts.log" | sort -n | paste -sd' ' -
  }
  got="$(cancel_case free beef0000)"
  [[ "$got" == "11 13" ]] \
    || fail "closed PR head: want PR-event runs 11 and 13 cancelled, push run 12 kept; got [$got]"
  got="$(cancel_case shared cafe0000)"
  [[ -z "$got" ]] \
    || fail "closed PR head is also an open PR's head, yet runs were cancelled: [$got]"
fi

# CR #2641 follow-up: an unpinned checkout of a pull_request event lands the PR
# merge ref on a job holding actions:write; every checkout must pin the default
# branch. The cancel filter must name only pull_request: the head_sha of
# pull_request_target runs is unverified, so that claim is withdrawn.
if [[ -f "$CANCEL_WF" ]]; then
  ruby -ryaml -e 'bad = []; YAML.load_file(ARGV[0])["jobs"].each { |jn, job| (job["steps"] || []).each { |st| next unless st["uses"].to_s.start_with?("actions/checkout@"); bad << jn unless (st["with"] || {})["ref"] == "${{ github.event.repository.default_branch }}" } }; abort bad.join(" ") unless bad.empty?' "$CANCEL_WF" \
    || fail "$CANCEL_WF checkout does not pin ref to github.event.repository.default_branch"
  grep -Fq '.event == "pull_request") | .id' "$CANCEL_WF" \
    || fail "$CANCEL_WF cancel filter must select pull_request runs only"
  grep -Fq 'pull_request_target' "$CANCEL_WF" && fail "$CANCEL_WF still claims pull_request_target"
  ruby -rjson -e 'e = JSON.parse(File.read(ARGV[0]))["entries"].find { |x| x["workflow"] == "pr-closed-run-cancel.yml" }; abort unless e; abort if e["reason"].include?("pull_request_target")' ops/tests/github_workflow_write_allowlist.json \
    || fail "write allowlist reason for pr-closed-run-cancel still claims pull_request_target"
  grep -E '^\| Closed-PR run cancel' docs/reference/tech_index.md | grep -q 'pull_request_target' \
    && fail "tech_index Closed-PR row still claims pull_request_target"
fi

if (( failures > 0 )); then
  printf 'github workflow contract: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'github workflow contract: PASS (%d reusable component workflows, one PR aggregator)\n' "${#component_workflows[@]}"
