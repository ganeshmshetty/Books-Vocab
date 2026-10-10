#!/usr/bin/env bash
# test_ci_confidence_verdict.sh — confidence accepts only the declared fan-out.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERDICT="$ROOT/ops/ci_confidence_verdict.sh"

failures=0
pass() {
  printf '✓ %s\n' "$1"
}

fail() {
  printf '✗ %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_accepts() {
  local label="$1"
  local plan="$2"
  local needs="$3"
  if "$VERDICT" --plan "$plan" --needs "$needs" >/dev/null; then
    pass "$label"
  else
    fail "$label: valid confidence plan was rejected"
  fi
}

assert_rejects() {
  local label="$1"
  local plan="$2"
  local needs="$3"
  if "$VERDICT" --plan "$plan" --needs "$needs" >/dev/null 2>&1; then
    fail "$label: invalid confidence plan was accepted"
  else
    pass "$label"
  fi
}

plan='{"backend":"false","ops":"true","ios":"false","macos_ops":"false"}'
needs="$(jq -cn '{
  "changed-paths": {result: "success"},
  "repo-gate": {result: "success"},
  "backend-quality": {result: "skipped"},
  "llm-eval": {result: "success"},
  "design-system": {result: "success"},
  "ui-quality-gate": {result: "success"},
  "ops-suite": {result: "success"},
  "ios-quality": {result: "skipped"}
}')"

assert_accepts 'selected suite succeeds and unselected suites are skipped' "$plan" "$needs"
assert_rejects 'selected suite cannot be skipped' \
  "$plan" \
  "$(jq -c '."ops-suite".result = "skipped"' <<<"$needs")"
assert_rejects 'unselected suite cannot silently consume CI' \
  "$plan" \
  "$(jq -c '."backend-quality".result = "success"' <<<"$needs")"
assert_rejects 'unselected suite failure remains a confidence failure' \
  "$plan" \
  "$(jq -c '."backend-quality".result = "failure"' <<<"$needs")"
for status in failure cancelled neutral skipped; do
  assert_rejects "unknown dependency $status remains a confidence failure" \
    "$plan" \
    "$(jq -c --arg status "$status" '. + {"security-gate": {result: $status}}' <<<"$needs")"
done
assert_rejects 'failed path classification is never confidence green' \
  "$plan" \
  "$(jq -c '."changed-paths".result = "failure"' <<<"$needs")"
assert_rejects 'incomplete selector output is never confidence green' \
  '{"backend":"false","ops":"true"}' \
  "$needs"
assert_rejects 'plan without macos_ops is incomplete (fail closed)' \
  '{"backend":"false","ops":"true","ios":"false"}' \
  "$needs"

# macOS-only changes (for example a UITests-only change) schedule ops-suite for
# its macos-native-ops job while ops stays false (CR P2-1, #2641 r2 review).
macos_plan='{"backend":"false","ops":"false","ios":"true","macos_ops":"true"}'
macos_needs="$(jq -cn '{
  "changed-paths": {result: "success"},
  "repo-gate": {result: "success"},
  "backend-quality": {result: "skipped"},
  "llm-eval": {result: "success"},
  "design-system": {result: "success"},
  "ui-quality-gate": {result: "success"},
  "ops-suite": {result: "success"},
  "ios-quality": {result: "success"}
}')"
assert_accepts 'macOS-only plan expects ops-suite to run' "$macos_plan" "$macos_needs"
assert_rejects 'macOS-only plan cannot skip ops-suite' \
  "$macos_plan" \
  "$(jq -c '."ops-suite".result = "skipped"' <<<"$macos_needs")"
assert_rejects 'ops-suite must be skipped when neither ops nor macos_ops is selected' \
  '{"backend":"false","ops":"false","ios":"true","macos_ops":"false"}' \
  "$macos_needs"

if (( failures > 0 )); then
  printf 'ci confidence verdict: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'ci confidence verdict: PASS\n'
