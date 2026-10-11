#!/usr/bin/env bash
# ci_macos_queue_probe.sh — a measurement, never a gate: records how long this macOS
# job waited for a runner (started_at - created_at). It runs after the job already got
# its runner, so failing here only forces a rerun that queues again. This revises the
# #2641 done-when "a starved job fails fast" by owner decision 2026-10-11: starvation
# warns with ::warning:: and the named cause (also in the step summary); exit 0 always.
set -uo pipefail

max_min="${KG_MACOS_QUEUE_MAX_MIN:-20}"
repo="${GITHUB_REPOSITORY:-}"
run_id="${GITHUB_RUN_ID:-}"
attempt="${GITHUB_RUN_ATTEMPT:-1}"
runner="${RUNNER_NAME:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

warn() { printf 'macos-queue-probe: %s\n' "$1" >&2; }

# A malformed budget would make the (( )) compare below fail or misreport: a whole
# number of minutes only, so the starved verdict is never silently dropped (#2641).
# No `set -e`: a failed summary write must not turn a healthy build red.
if [[ ! "$max_min" =~ ^[1-9][0-9]{0,4}$ ]]; then
  warn "KG_MACOS_QUEUE_MAX_MIN='$max_min' is not a whole number of minutes (1-99999); using 20"
  max_min=20
fi

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
  printf '::warning::macos-capacity starved: job waited %ss for a macos-26 runner (budget %smin)\n' "$wait_s" "$max_min"
  printf 'macos-capacity starved: job waited %ss for a macos-26 runner (budget %smin)\n' "$wait_s" "$max_min" >&2
  printf '\n**macos-capacity starved**: job waited %ss for a macos-26 runner (budget %s min). Report only; the job is not failed.\n' "$wait_s" "$max_min" >>"$summary"
fi
exit 0
