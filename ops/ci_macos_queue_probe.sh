#!/usr/bin/env bash
# ci_macos_queue_probe.sh — record how long this macOS job waited for a runner
# (started_at - created_at) and fail with a named cause when the pool starved it
# (Issue #2641). A measurement problem (API/permission/clock) only warns: the
# probe must never turn a healthy build red.
set -uo pipefail

max_min="${KG_MACOS_QUEUE_MAX_MIN:-20}"
repo="${GITHUB_REPOSITORY:-}"
run_id="${GITHUB_RUN_ID:-}"
attempt="${GITHUB_RUN_ATTEMPT:-1}"
runner="${RUNNER_NAME:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

warn() { printf 'macos-queue-probe: %s\n' "$1" >&2; }

if [[ -z "$repo" || -z "$run_id" || -z "$runner" ]]; then
  warn "missing GITHUB_REPOSITORY/GITHUB_RUN_ID/RUNNER_NAME; not measured"
  exit 0
fi

# --paginate: the jobs endpoint returns 30 jobs per page, and gh emits one JSON
# object per page; jq -s slurps them so the runner is found on any page (#2641).
jobs_json="$(gh api --paginate "repos/$repo/actions/runs/$run_id/attempts/$attempt/jobs?per_page=100" 2>/dev/null)" || {
  warn "jobs API unavailable; not measured"
  exit 0
}
wait_s="$(printf '%s' "$jobs_json" | jq -rs --arg r "$runner" \
  '[.[].jobs[] | select(.runner_name == $r) | ((.started_at | fromdateiso8601) - (.created_at | fromdateiso8601))] | first // empty' 2>/dev/null)" || wait_s=''
if [[ ! "$wait_s" =~ ^[0-9]+$ ]]; then
  warn "no queue time found for runner '$runner'; not measured"
  exit 0
fi

printf 'macOS queue wait: %ss (budget %smin)\n' "$wait_s" "$max_min"
printf '### macOS runner queue\n\nqueued-to-started: %ss (budget %s min)\n' "$wait_s" "$max_min" >>"$summary"
if (( wait_s > max_min * 60 )); then
  printf 'macos-capacity starved: job waited %ss for a macos-26 runner (budget %smin)\n' "$wait_s" "$max_min" >&2
  exit 1
fi
