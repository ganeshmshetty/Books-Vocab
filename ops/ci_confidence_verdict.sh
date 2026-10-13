#!/usr/bin/env bash
# ci_confidence_verdict.sh — fail closed when confidence diverges from its plan.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ops/ci_confidence_verdict.sh --plan <json> --needs <json>

The plan contains string booleans for backend, ops, ios, and macos_ops. The
needs object is GitHub Actions' toJSON(needs) value. ops-suite is selected by
ops or macos_ops (its macos-native-ops job consumes macos_ops). Selected suites
must succeed; explicitly unselected suites must be skipped. The one exception is
a targeted ops-suite that selected zero Linux groups (outputs.linux_group_count
is "0"; docs- or backend-only PR): its nested suite job is skipped by design, so
the caller may read skipped, but only when no macOS ops job was requested. A
selected iOS suite
on a PR is compile-only: ios-build must succeed and the iOS test jobs must be
skipped (pr-gate passes run_tests=false). Every other confidence dependency,
including unknown dependencies, must succeed.
EOF
}

plan=''
needs=''

while (($# > 0)); do
  case "$1" in
    --plan)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      plan="$2"
      shift 2
      ;;
    --needs)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      needs="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$plan" && -n "$needs" ]] || { usage >&2; exit 2; }

if ! jq -e '
  . as $plan
  | type == "object"
    and all(["backend", "ops", "ios", "macos_ops"][]; . as $key | ($plan[$key] == "true" or $plan[$key] == "false"))
' <<<"$plan" >/dev/null; then
  printf 'confidence plan must define backend, ops, ios, and macos_ops as string booleans\n' >&2
  exit 2
fi

printf 'confidence plan: %s\n' "$plan"
printf '%s\n' "$needs" | jq -r 'to_entries[] | "\(.key)=\(.value.result // "missing")"' | sort

if ! jq -e --argjson plan "$plan" '
  def result($name): .[$name].result // "missing";
  def ios($key): (.["ios-quality"].outputs // {})[$key];
  def known($name): [
    "changed-paths",
    "repo-gate",
    "llm-eval",
    "design-system",
    "ui-quality-gate",
    "backend-quality",
    "ops-suite",
    "ios-quality"
  ] | index($name) != null;
  result("changed-paths") == "success"
  and result("repo-gate") == "success"
  and result("llm-eval") == "success"
  and result("design-system") == "success"
  and result("ui-quality-gate") == "success"
  and (
    if $plan.backend == "true"
    then result("backend-quality") == "success"
    else result("backend-quality") == "skipped"
    end
  )
  and (
    if $plan.ops == "true" or $plan.macos_ops == "true"
    then result("ops-suite") == "success"
      or (
        # Targeted PR with zero Linux groups (docs- or backend-only): the nested
        # suite job is skipped by design. Accept only that shape, never a macOS run.
        result("ops-suite") == "skipped"
        and $plan.macos_ops == "false"
        and ((.["ops-suite"].outputs // {}).linux_group_count == "0")
      )
    else result("ops-suite") == "skipped"
    end
  )
  and (
    # PR iOS runs are compile-only (pr-gate passes run_tests=false): ios-build
    # must have succeeded and every iOS test job must be skipped by design.
    # ios-quality exposes each job result as an output, so the aggregate
    # ios-quality result is never the only proof.
    if $plan.ios == "true"
    then result("ios-quality") == "success"
      and ios("build_result") == "success"
      and ios("tests_result") == "skipped"
      and ios("targeted_result") == "skipped"
    else result("ios-quality") == "skipped"
    end
  )
  and all(to_entries[]; known(.key) or .value.result == "success")
' <<<"$needs" >/dev/null; then
  printf 'confidence result does not match its declared fan-out\n' >&2
  exit 1
fi

printf 'confidence verdict: PASS\n'
