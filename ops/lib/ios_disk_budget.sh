#!/usr/bin/env bash
# Bounded disk policy shared by iOS build, test, release, and the recurring guard.
#
# This file is sourced by callers that already own the iOS build lock.  It must
# stay side-effect free: it only measures known, rebuildable KG cache roots and
# returns a structured fail-closed result when the writer budget is exhausted.

KG_IOS_DISK_BUDGET_EXIT=75
# Structural guard block (unregistered/dirty/unknown worktree, or a state that
# needs human review): waiting never clears it, so it must not share the
# temporary exit 75 that agents poll on.  Mirrors EXIT_STRUCTURAL_BLOCK in
# ops/lib/exit_codes.py.
KG_IOS_DISK_STRUCTURAL_EXIT=77
KG_IOS_DISK_GUARD_STATE_DEFAULT="${HOME}/Library/Application Support/KG/disk_guard.json"
# Set to 1 by kg_ios_disk_budget_guard_state when its block came from a lane-usage
# report the cited tick did not write, so kg_ios_disk_budget_blocked_hint does not
# send the caller to clean a cache that is not the problem.
KG_IOS_DISK_GUARD_STALE_LANE_REPORT=0

# kg_stat_mtime: one BSD/GNU-safe mtime reader (see lib/userland_compat.sh).
if [[ "$(type -t kg_stat_mtime)" != function ]]; then
  # shellcheck source=./userland_compat.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/userland_compat.sh"
fi

kg_ios_disk_budget_roots() {
  local project_root="${1:?project root is required}"
  local configured_root
  if [[ -n "${KG_IOS_DISK_CACHE_ROOTS:-}" ]]; then
    while IFS= read -r configured_root; do
      [[ -d "$configured_root" ]] && printf '%s\n' "$configured_root"
    done < <(printf '%s\n' "$KG_IOS_DISK_CACHE_ROOTS" | tr ':' '\n')
    return 0
  fi
  local root
  for root in \
    "$project_root/.cache/ios-build-derived-data" \
    "$project_root/.cache/ios-test-derived-data" \
    "$project_root/.cache/ios-catalyst-derived-data" \
    "$project_root/.cache/ios-release-derived-data" \
    "$project_root/.cache/ops-swift-build" \
    "$project_root/ios/build"; do
    [[ -d "$root" ]] && printf '%s\n' "$root"
  done
}

kg_ios_disk_budget_free_bytes() {
  local project_root="${1:?project root is required}"
  if [[ -n "${KG_IOS_DISK_FREE_BYTES:-}" ]]; then
    case "$KG_IOS_DISK_FREE_BYTES" in
      ''|*[!0-9]*) printf '' ;;
      *) printf '%s' "$KG_IOS_DISK_FREE_BYTES" ;;
    esac
    return 0
  fi
  df -Pk "$project_root" 2>/dev/null | awk 'NR==2 {print $4 * 1024; exit}'
}

kg_ios_disk_budget_cache_kb() {
  local project_root="${1:?project root is required}"
  local root size total=0
  while IFS= read -r root; do
    size="$(du -sk "$root" 2>/dev/null | awk 'NR==1 {print $1}')"
    [[ "$size" =~ ^[0-9]+$ ]] || return 2
    total=$((total + size))
  done < <(kg_ios_disk_budget_roots "$project_root")
  printf '%s' "$total"
}

kg_ios_disk_budget_config() {
  local budget_gib="${KG_IOS_DISK_CACHE_BUDGET_GIB:-16}"
  local headroom_gib="${KG_IOS_DISK_CACHE_HEADROOM_GIB:-6}"
  local min_free_gib="${KG_IOS_DISK_MIN_FREE_GIB:-20}"
  [[ "$budget_gib" =~ ^[0-9]+$ && "$headroom_gib" =~ ^[0-9]+$ && "$min_free_gib" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s %s\n' "$((budget_gib * 1048576))" "$((headroom_gib * 1048576))" "$((min_free_gib * 1073741824))"
}

kg_ios_disk_guard_json_string() {
  local state="$1" key="$2"
  sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$state" \
    | head -1
}

kg_ios_disk_guard_timestamp_epoch() {
  local timestamp="$1" epoch
  epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%s" 2>/dev/null || true)"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s' "$epoch"
    return 0
  fi
  epoch="$(date -u -d "$timestamp" "+%s" 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$epoch"
}

# Print the items of one JSON string array (as written by json.dump(indent=2))
# joined by ';'.  Empty or absent arrays print nothing.
kg_ios_disk_json_array() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -v key="\"${key}\":" '
    !inarr && $1 == key { if ($0 ~ /\[\]/) exit; inarr = 1; next }
    inarr {
      if ($0 ~ /^[[:space:]]*\]/) exit
      sub(/^[[:space:]]*"/, ""); sub(/",?$/, "")
      printf "%s%s", (n++ ? ";" : ""), $0
    }
  ' "$file"
}

kg_ios_disk_lane_usage_state() {
  local state="${1:?guard state is required}"
  printf '%s' "${KG_IOS_DISK_LANE_USAGE_STATE:-$(dirname "$state")/lane_disk_usage.json}"
}

# A lane-usage report decides a block only if the tick that published the guard
# state also wrote it.  The tick writes the report seconds before the state's
# "at", so a healthy pair differs by a few seconds; a report older than the slack
# (default 120s, under the 300s tick interval so the previous tick's report never
# passes) was not written by that tick: its scan was killed, or the tick that
# should have rewritten it never finished.  Sets KG_IOS_DISK_LANE_REPORT_LAG to
# the lag in seconds, or "missing"; returns 1 when the report is stale or missing.
kg_ios_disk_lane_report_is_fresh() {
  local state="${1:?guard state is required}" lane_state at epoch report_mtime slack
  lane_state="$(kg_ios_disk_lane_usage_state "$state")"
  KG_IOS_DISK_LANE_REPORT_LAG="missing"
  [[ -f "$lane_state" ]] || return 1
  slack="${KG_IOS_DISK_LANE_REPORT_SLACK_SECONDS:-120}"
  [[ "$slack" =~ ^[0-9]+$ ]] || slack=120
  at="$(kg_ios_disk_guard_json_string "$state" at)"
  epoch="$(kg_ios_disk_guard_timestamp_epoch "$at" 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || epoch="$(kg_stat_mtime "$state" 2>/dev/null || true)"
  report_mtime="$(kg_stat_mtime "$lane_state" 2>/dev/null || true)"
  # No readable reference or mtime means freshness cannot be shown: not fresh.
  [[ "$epoch" =~ ^[0-9]+$ && "$report_mtime" =~ ^[0-9]+$ ]] || return 1
  KG_IOS_DISK_LANE_REPORT_LAG=$((epoch - report_mtime))
  (( KG_IOS_DISK_LANE_REPORT_LAG <= slack ))
}

# Say WHICH worktrees and reasons made the shared guard block, so a blocked
# agent does not read a lane-attribution verdict as a disk-space problem.  A
# stale report's lists are history, not current fact, so they print as unknown.
kg_ios_disk_guard_diagnose() {
  local operation="$1" state="$2" lane_state reasons unregistered dirty unknown mismatches repairs fresh="yes"
  lane_state="$(kg_ios_disk_lane_usage_state "$state")"
  if kg_ios_disk_lane_report_is_fresh "$state"; then
    reasons="$(kg_ios_disk_json_array "$lane_state" blocking_reasons)"
    unregistered="$(kg_ios_disk_json_array "$lane_state" unregistered_physical_worktrees)"
    dirty="$(kg_ios_disk_json_array "$lane_state" blocking_dirty_physical_worktrees)"
    unknown="$(kg_ios_disk_json_array "$lane_state" unknown_physical_worktrees)"
    mismatches="$(kg_ios_disk_json_array "$lane_state" physical_identity_mismatches)"
    repairs="$(kg_ios_disk_json_array "$lane_state" physical_identity_repairs)"
  else
    fresh="no"
    reasons="unknown"; unregistered="unknown"; dirty="unknown"; unknown="unknown"; mismatches="unknown"; repairs="unknown"
  fi
  echo "schema=kg.ios.disk-budget.v1 operation=$operation detail=guard-block guardReason=$(kg_ios_disk_guard_json_string "$state" reason) guardAction=$(kg_ios_disk_guard_json_string "$state" action) laneUsageVerdict=$(kg_ios_disk_guard_json_string "$state" lane_usage_verdict) laneUsageFresh=$fresh laneUsageLagSeconds=$KG_IOS_DISK_LANE_REPORT_LAG blockingReasons=${reasons:-none} unregisteredWorktrees=${unregistered:-none} dirtyWorktrees=${dirty:-none} unknownWorktrees=${unknown:-none} identityMismatchWorktrees=${mismatches:-none} identityRepairs=\"${repairs:-none}\" laneUsage=$lane_state refresh=\"./ops/ios_ops.sh guard --refresh\"" >&2
}

# A guard block that no amount of waiting or cache cleaning clears.  Two sources:
# the guard itself asks for manual review (XCTestDevices / simulator runtime), or
# a FRESH lane-attribution report names a worktree problem (dirty, unknown,
# duplicate, identity mismatch, invalid registry).  An unregistered worktree is
# not on this list: it warns by path and blocks only through the quota (issue
# #2905).  The guard reason
# "lane-usage-report-blocked" alone is NOT enough: it is also emitted for lane
# quota overruns, incomplete measurement and a timed-out/crashed report, all of
# which clear on the next tick or after eviction (temporary, exit 75).
kg_ios_disk_structural_lane_reason() {
  case "$1" in
    dirty-*|unknown-*|duplicate-*|physical-identity-mismatch|registry-records-invalid|supervision-path-registered|*-manual-review-required) return 0 ;;
    *) return 1 ;;
  esac
}

kg_ios_disk_guard_block_is_structural() {
  local state="$1" reason lane_rc lane_state reasons item
  reason="$(kg_ios_disk_guard_json_string "$state" reason)"
  case "$reason" in
    xctest-devices-manual-review-required|simulator-runtime-manual-review-required) return 0 ;;
    lane-usage-report-blocked) ;;
    *) return 1 ;;
  esac
  # disk_usage.py exits 0 or 75 when it wrote a complete report.  A supervisor kill
  # (124) is evidence only when the report that tick wrote before the kill names a
  # structural reason: the kill can land after that write, and waiting still cannot
  # clear such a finding (#3001).  A kill whose report is missing, stale or
  # time-limit-only stays temporary (75).  Any other rc is a crash, never evidence.
  # Producers before 2026-10-08 also recorded a supervisor kill as 75, so the rc
  # alone is not enough: the report must also postdate the tick (checked below).
  lane_rc="$(sed -nE 's/.*"lane_usage_rc"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$state" | head -1)"
  case "${lane_rc:-0}" in 0|75|124) ;; *) return 1 ;; esac
  kg_ios_disk_lane_report_is_fresh "$state" || return 1
  lane_state="$(kg_ios_disk_lane_usage_state "$state")"
  reasons="$(kg_ios_disk_json_array "$lane_state" blocking_reasons)"
  while IFS= read -r item; do
    [[ -n "$item" ]] && kg_ios_disk_structural_lane_reason "$item" && return 0
  done < <(printf '%s
' "$reasons" | tr ';' '
')
  return 1
}

kg_ios_disk_guard_structural_notice() {
  local operation="$1" state="$2"
  echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block exit=$KG_IOS_DISK_STRUCTURAL_EXIT retryable=no reason=$(kg_ios_disk_guard_json_string "$state" reason) guardAction=$(kg_ios_disk_guard_json_string "$state" action)" >&2
  echo "[ios] BLOCKED (structural, exit $KG_IOS_DISK_STRUCTURAL_EXIT, retryable=no): waiting or cleaning cache will not clear this. Resolve the blockingReasons / worktrees named above (register, clean up or remove them), then run './ops/ios_ops.sh guard --refresh'. Do not poll." >&2
}

# Re-evaluate the shared guard now instead of waiting for the 5-minute tick.
# $2=1 only when the caller already owns the iOS build lock (in-lock preflight);
# the lock-free early verdict passes 0 so the tick takes the real lock itself
# (or defers eviction) instead of deleting caches under a running build.
# The host-global state has one writer identity: the canonical checkout's tick,
# i.e. the same code and root the launchd job runs (the product registry lives
# there, not in an agent lane).  A lane's own copy, possibly on an older or
# unmerged base, never publishes into it, and an unresolvable canonical
# checkout fails the refresh instead of falling back to this lane's root.
kg_ios_disk_guard_refresh() {
  local state="${1:?guard state is required}" lib_dir tick workspace common
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  workspace="${KG_DISK_GUARD_WORKSPACE:-}"
  if [[ -z "$workspace" ]]; then
    common="$(git -C "$lib_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [[ -n "$common" && -d "$common" ]] || return 1
    workspace="$(dirname "$common")"
  fi
  tick="${KG_IOS_DISK_GUARD_TICK:-$workspace/ops/kg_disk_guard.sh}"
  [[ -x "$tick" ]] || return 1
  KG_DISK_GUARD_WORKSPACE="$workspace" KG_DISK_GUARD_STATE="$state" \
    KG_DISK_GUARD_LANE_USAGE_STATE="$(kg_ios_disk_lane_usage_state "$state")" \
    KG_DISK_GUARD_BUILD_LOCK_HELD="${2:-0}" "$tick" >/dev/null 2>&1
}

# $2=1 only from the in-lock preflight (caller owns the iOS build lock); the
# default 0 keeps an inline refresh from claiming a lock nobody holds.
kg_ios_disk_budget_guard_state() {
  local operation="${1:-ios-write}"
  local lock_held="${2:-0}"
  local state="${KG_IOS_DISK_GUARD_STATE:-$KG_IOS_DISK_GUARD_STATE_DEFAULT}"
  local enforce="${KG_IOS_DISK_GUARD_ENFORCE_XCTEST:-0}"
  local max_age="${KG_IOS_DISK_GUARD_MAX_AGE_SECONDS:-900}"
  local schema verdict xctest_verdict manual_review time_limited at epoch now age

  KG_IOS_DISK_GUARD_STALE_LANE_REPORT=0
  [[ "$enforce" == "1" ]] || enforce=0
  if [[ ! -f "$state" ]]; then
    if (( enforce == 1 )); then
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=disk-guard-state-missing state=$state" >&2
      return "$KG_IOS_DISK_BUDGET_EXIT"
    fi
    return 0
  fi

  schema="$(kg_ios_disk_guard_json_string "$state" schema)"
  verdict="$(kg_ios_disk_guard_json_string "$state" verdict)"
  xctest_verdict="$(kg_ios_disk_guard_json_string "$state" xctest_devices_verdict)"
  manual_review="$(sed -nE 's/.*"xctest_devices_manual_review"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$state" | head -1)"
  time_limited="$(sed -nE 's/.*"xctest_devices_time_limited"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$state" | head -1)"
  at="$(kg_ios_disk_guard_json_string "$state" at)"

  if [[ "$schema" != "kg.disk.guard.v1" ]]; then
    echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=disk-guard-state-invalid state=$state" >&2
    return "$KG_IOS_DISK_BUDGET_EXIT"
  fi

  # An explicit platform or global guard block is authoritative even when the
  # caller has not opted into freshness enforcement.  A stale "pass" is only
  # accepted by legacy callers that have not enabled the shared-state gate.
  if [[ "$xctest_verdict" == "block" || "$xctest_verdict" == "critical" ]]; then
    if [[ "$manual_review" == "1" ]]; then
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=xctest-devices-manual-review-required state=$state" >&2
      echo "[ios] BLOCKED (structural, exit $KG_IOS_DISK_STRUCTURAL_EXIT, retryable=no): XCTestDevices needs manual review; waiting will not clear it. Do not poll." >&2
      return "$KG_IOS_DISK_STRUCTURAL_EXIT"
    fi
    # A walk that only ran out of time is temporary and says so.  The guard
    # records that as its own field, because a lane report that exits 75 replaces
    # the guard reason (issue #2905); the reason string is only the fallback for
    # guard states written before the field existed.  Everything else is the
    # budget overrun.
    if [[ "$time_limited" == "1" ]] \
      || [[ "$(kg_ios_disk_guard_json_string "$state" reason)" == xctest-devices-measurement-incomplete ]]; then
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block exit=$KG_IOS_DISK_BUDGET_EXIT retryable=yes reason=xctest-devices-measurement-incomplete state=$state" >&2
    else
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=xctest-devices-budget-exceeded state=$state" >&2
    fi
    return "$KG_IOS_DISK_BUDGET_EXIT"
  fi
  if [[ "$verdict" == "block" || "$verdict" == "critical" ]]; then
    # The state can be up to one tick stale (a lane registered a minute ago is
    # still "unregistered").  Re-evaluate once inline before refusing.
    if [[ "${KG_IOS_DISK_GUARD_REFRESHED:-0}" != "1" && "${KG_IOS_DISK_GUARD_AUTO_REFRESH:-1}" == "1" \
      && "$(kg_ios_disk_guard_json_string "$state" reason)" == lane-usage-report-* ]]; then
      echo "schema=kg.ios.disk-budget.v1 operation=$operation detail=guard-block-refreshing state=$state" >&2
      if kg_ios_disk_guard_refresh "$state" "$lock_held"; then
        KG_IOS_DISK_GUARD_REFRESHED=1 kg_ios_disk_budget_guard_state "$operation" "$lock_held"
        return $?
      fi
    fi
    echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=disk-guard-blocked state=$state" >&2
    kg_ios_disk_guard_diagnose "$operation" "$state"
    if kg_ios_disk_guard_block_is_structural "$state"; then
      kg_ios_disk_guard_structural_notice "$operation" "$state"
      return "$KG_IOS_DISK_STRUCTURAL_EXIT"
    fi
    if [[ "$(kg_ios_disk_guard_json_string "$state" reason)" == lane-usage-report-* ]] \
      && ! kg_ios_disk_lane_report_is_fresh "$state"; then
      KG_IOS_DISK_GUARD_STALE_LANE_REPORT=1
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block exit=$KG_IOS_DISK_BUDGET_EXIT retryable=yes reason=lane-usage-report-stale laneUsageLagSeconds=$KG_IOS_DISK_LANE_REPORT_LAG" >&2
      echo "[ios] BLOCKED (temporary, exit $KG_IOS_DISK_BUDGET_EXIT): the lane-usage report is stale (lag ${KG_IOS_DISK_LANE_REPORT_LAG}s behind the guard tick that cites it; the attribution scan did not finish), so the block above is unattributed, not a worktree finding. Cleaning cache will not clear it. Run './ops/ios_ops.sh guard --refresh' to re-scan, or retry after the next tick. A repeat means the scan overruns its budget (docs/reference/ios_deriveddata_policy.md)." >&2
    fi
    return "$KG_IOS_DISK_BUDGET_EXIT"
  fi

  if (( enforce == 1 )); then
    [[ "$max_age" =~ ^[0-9]+$ ]] || {
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=disk-guard-state-invalid state=$state" >&2
      return "$KG_IOS_DISK_BUDGET_EXIT"
    }
    epoch="$(kg_ios_disk_guard_timestamp_epoch "$at" 2>/dev/null || true)"
    now="$(date +%s)"
    if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=disk-guard-state-invalid state=$state" >&2
      return "$KG_IOS_DISK_BUDGET_EXIT"
    fi
    age=$((now - epoch))
    if (( epoch > now + max_age )); then
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=disk-guard-state-future state=$state ageSeconds=$age maxAgeSeconds=$max_age" >&2
      return "$KG_IOS_DISK_BUDGET_EXIT"
    fi
    if (( age > max_age )); then
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=disk-guard-state-stale state=$state ageSeconds=$age maxAgeSeconds=$max_age" >&2
      return "$KG_IOS_DISK_BUDGET_EXIT"
    fi
    case "$xctest_verdict" in
      pass|absent) ;;
      *)
        echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=disk-guard-state-invalid state=$state" >&2
        return "$KG_IOS_DISK_BUDGET_EXIT"
        ;;
    esac
    case "$verdict" in
      ok|warning) ;;
      *)
        echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=disk-guard-state-invalid state=$state" >&2
        return "$KG_IOS_DISK_BUDGET_EXIT"
        ;;
    esac
  fi
  return 0
}

kg_ios_disk_budget_preflight() {
  local project_root="${1:?project root is required}"
  local operation="${2:-ios-write}"
  local config budget_kb headroom_kb min_free_bytes free_bytes cache_kb
  config="$(kg_ios_disk_budget_config 2>/dev/null || true)"
  if [[ ! "$config" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=invalid-budget-config" >&2
    return "$KG_IOS_DISK_BUDGET_EXIT"
  fi
  read -r budget_kb headroom_kb min_free_bytes <<<"$config"
  free_bytes="$(kg_ios_disk_budget_free_bytes "$project_root")"
  if [[ ! "$free_bytes" =~ ^[0-9]+$ ]]; then
    echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=free-space-unknown" >&2
    return "$KG_IOS_DISK_BUDGET_EXIT"
  fi
  cache_kb="$(kg_ios_disk_budget_cache_kb "$project_root" 2>/dev/null || true)"
  if [[ ! "$cache_kb" =~ ^[0-9]+$ ]]; then
    echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=cache-size-unknown freeBytes=$free_bytes" >&2
    return "$KG_IOS_DISK_BUDGET_EXIT"
  fi
  if (( free_bytes < min_free_bytes )); then
    echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=free-space-below-floor freeBytes=$free_bytes minFreeBytes=$min_free_bytes cacheKB=$cache_kb budgetKB=$budget_kb headroomKB=$headroom_kb" >&2
    return "$KG_IOS_DISK_BUDGET_EXIT"
  fi
  if (( cache_kb + headroom_kb > budget_kb )); then
    if (( cache_kb > budget_kb )); then
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=cache-budget-exceeded freeBytes=$free_bytes cacheKB=$cache_kb budgetKB=$budget_kb headroomKB=$headroom_kb" >&2
    else
      echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=block reason=cache-budget-headroom-exhausted freeBytes=$free_bytes cacheKB=$cache_kb budgetKB=$budget_kb headroomKB=$headroom_kb" >&2
    fi
    return "$KG_IOS_DISK_BUDGET_EXIT"
  fi
  if ! kg_ios_disk_guard_early_check_is_fresh; then
    kg_ios_disk_budget_guard_state "$operation" 1 || return $?
  fi
  echo "schema=kg.ios.disk-budget.v1 operation=$operation verdict=pass freeBytes=$free_bytes cacheKB=$cache_kb budgetKB=$budget_kb headroomKB=$headroom_kb" >&2
  return 0
}

# One-line epilogue for a failed in-lock preflight.  Callers MUST propagate the
# preflight's own rc (75 temporary / 77 structural) as their exit code and call
# this with the same rc: "clean the cache and retry" is only true for 75, and
# printing it for 77 sends agents back into the retry loop the 77 exists to stop.
# The structural reason/action lines were already printed by the guard read.
kg_ios_disk_budget_blocked_hint() {
  local prefix="${1:?caller prefix is required}" rc="${2:-$KG_IOS_DISK_BUDGET_EXIT}"
  if (( rc == KG_IOS_DISK_STRUCTURAL_EXIT )); then
    echo "$prefix blocked by the shared disk guard (exit $rc, structural, retryable=no): see the guard reason and action above; do not poll" >&2
  elif (( rc == KG_IOS_DISK_BUDGET_EXIT )) && [[ "${KG_IOS_DISK_GUARD_STALE_LANE_REPORT:-0}" == "1" ]]; then
    echo "$prefix blocked by the shared disk guard (exit $rc, temporary): its lane-usage report is stale, not a cache problem; run './ops/ios_ops.sh guard --refresh' or retry after the next tick" >&2
  elif (( rc == KG_IOS_DISK_BUDGET_EXIT )); then
    echo "$prefix blocked by disk budget; clean rebuildable cache before retry" >&2
  else
    echo "$prefix disk budget preflight failed (exit $rc)" >&2
  fi
}

# Early verdict for entry points: read the shared guard BEFORE leasing a
# simulator or taking the build lock, so a block costs seconds, not a queue
# slot.  Lock-free by construction (an inline refresh runs the tick with
# BUILD_LOCK_HELD=0).  Real disk space is still measured by the in-lock
# preflight.  Returns 0 (go on), 75 (temporary), or 77 (structural, not retryable).
kg_ios_disk_guard_early_verdict() {
  kg_ios_disk_budget_guard_state "${1:-ios-write}" 0
}

# Record a passed early verdict so the in-lock preflight need not re-read it.
# Both variables are set together by this function only: a caller-preset
# ALREADY_CHECKED=1 without a timestamp is ignored, and a verdict older than
# the guard state's max age (a long queue wait) is re-read in-lock.
kg_ios_disk_guard_mark_checked() {
  export KG_IOS_DISK_GUARD_ALREADY_CHECKED=1
  export KG_IOS_DISK_GUARD_CHECKED_AT
  KG_IOS_DISK_GUARD_CHECKED_AT="$(date +%s)"
}

kg_ios_disk_guard_early_check_is_fresh() {
  local max_age="${KG_IOS_DISK_GUARD_MAX_AGE_SECONDS:-900}" checked_at="${KG_IOS_DISK_GUARD_CHECKED_AT:-}" now
  [[ "${KG_IOS_DISK_GUARD_ALREADY_CHECKED:-0}" == "1" ]] || return 1
  [[ "$checked_at" =~ ^[0-9]+$ && "$max_age" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  (( checked_at <= now && now - checked_at <= max_age ))
}
