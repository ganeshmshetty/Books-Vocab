#!/usr/bin/env bash
# test_ci_macos_queue_probe.sh — queue-wait measurement fails only on starvation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE="$ROOT/ops/ci_macos_queue_probe.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() { printf '✗ %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf '✓ %s\n' "$1"; }

stub_gh() { # $1 = created_at, $2 = started_at ("" = API failure)
  mkdir -p "$tmp/bin"
  if [[ -z "$2" ]]; then
    printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/gh"
  else
    printf '#!/bin/sh\necho '"'"'{"jobs":[{"runner_name":"r1","created_at":"%s","started_at":"%s"}]}'"'"'\n' "$1" "$2" >"$tmp/bin/gh"
  fi
  chmod +x "$tmp/bin/gh"
}
run_probe() {
  PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
    RUNNER_NAME="${1:-r1}" GITHUB_STEP_SUMMARY="$tmp/summary" bash "$PROBE" 2>&1
}

stub_gh 2026-01-01T00:00:00Z 2026-01-01T00:05:00Z
out="$(run_probe)" && grep -q 'queue wait: 300s' <<<"$out" && grep -q '300s' "$tmp/summary" \
  && pass "short wait is recorded and passes" || fail "short wait must pass and be recorded: $out"

stub_gh 2026-01-01T00:00:00Z 2026-01-01T00:45:00Z
if out="$(run_probe)"; then fail "starved wait must fail"; \
elif grep -q 'macos-capacity starved' <<<"$out"; then pass "starved wait fails with named cause"; \
else fail "starved failure lacks the named cause: $out"; fi

stub_gh 2026-01-01T00:00:00Z ''
run_probe >/dev/null && pass "API failure only warns" || fail "API failure must not fail the job"
stub_gh 2026-01-01T00:00:00Z 2026-01-01T00:45:00Z
run_probe other >/dev/null && pass "unknown runner is not measured, not failed" || fail "unknown runner must not fail"

(( failures == 0 )) || exit 1
