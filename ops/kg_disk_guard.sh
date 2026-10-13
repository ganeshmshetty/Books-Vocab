#!/usr/bin/env bash
# Bounded disk-growth monitor and conservative cache guard.
# State is atomically replaced; no append-only log is created.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The tick publishes host-global state (STATE_FILE, LANE_USAGE_STATE) that every
# lane reads, so its default root is the canonical checkout (the git-common-dir
# anchor shared with the iOS caches), never the linked worktree that happens to
# hold this copy.  Rooting at a lane makes the report read
# <lane>/.cache/worktree_registry.json (registry-missing) and list the canonical
# checkout as an unregistered lane.  Only a non-Git copy falls back to the
# script-relative checkout.
kg_disk_guard_default_workspace() {
  local common=""
  common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common" && -d "$common" && -d "$(dirname "$common")" ]]; then
    (cd "$(dirname "$common")" && pwd)
  else
    (cd "$SCRIPT_DIR/.." && pwd)
  fi
}
WORKSPACE="${KG_DISK_GUARD_WORKSPACE:-$(kg_disk_guard_default_workspace)}"
# shellcheck source=lib/userland_compat.sh
source "$SCRIPT_DIR/lib/userland_compat.sh"
STATE_FILE="${KG_DISK_GUARD_STATE:-$HOME/Library/Application Support/KG/disk_guard.json}"
REGISTRY_STATE="${KG_DISK_GUARD_REGISTRY_STATE:-$WORKSPACE/.cache/worktree_registry.json}"
LANE_USAGE_STATE="${KG_DISK_GUARD_LANE_USAGE_STATE:-$HOME/Library/Application Support/KG/lane_disk_usage.json}"
XCTEST_DEVICES_ROOT="${KG_DISK_GUARD_XCTEST_DEVICES_ROOT:-${KG_XCTEST_DEVICES_ROOT:-$HOME/Library/Developer/XCTestDevices}}"
XCTEST_DEVICES_BUDGET_GIB="${KG_DISK_GUARD_XCTEST_DEVICES_BUDGET_GIB:-${KG_XCTEST_DEVICES_BUDGET_GIB:-16}}"
[[ "$XCTEST_DEVICES_BUDGET_GIB" =~ ^[0-9]+$ ]] || XCTEST_DEVICES_BUDGET_GIB=16
XCTEST_DEVICES_BUDGET_KB=$((XCTEST_DEVICES_BUDGET_GIB * 1048576))
XCTEST_DEVICES_AUTO_RECLAIM="${KG_DISK_GUARD_XCTEST_DEVICES_AUTO_RECLAIM:-0}"
SIMULATOR_RUNTIME_BUDGET_GIB="${KG_DISK_GUARD_SIMULATOR_RUNTIME_BUDGET_GIB:-${KG_SIMULATOR_RUNTIME_BUDGET_GIB:-56}}"
[[ "$SIMULATOR_RUNTIME_BUDGET_GIB" =~ ^[0-9]+$ ]] || SIMULATOR_RUNTIME_BUDGET_GIB=56
SIMULATOR_RUNTIME_BUDGET_KB=$((SIMULATOR_RUNTIME_BUDGET_GIB * 1048576))
DERIVED_DATA_GLOBAL="${KG_DISK_GUARD_DERIVED_DATA_GLOBAL:-$HOME/Library/Developer/Xcode/DerivedData}"
WARN_FREE_GIB="${KG_DISK_GUARD_WARN_FREE_GIB:-50}"
CRIT_FREE_GIB="${KG_DISK_GUARD_CRIT_FREE_GIB:-36}"
GROWTH_WARN_GIB="${KG_DISK_GUARD_GROWTH_WARN_GIB:-5}"
DOCKER_WARN_GIB="${KG_DISK_GUARD_DOCKER_WARN_GIB:-2}"
DOCKER_PRUNE_UNTIL="${KG_DISK_GUARD_DOCKER_PRUNE_UNTIL:-168h}"
CACHE_BUDGET_GIB="${KG_DISK_GUARD_CACHE_BUDGET_GIB:-${KG_IOS_DISK_CACHE_BUDGET_GIB:-16}}"
CACHE_HEADROOM_GIB="${KG_DISK_GUARD_CACHE_HEADROOM_GIB:-${KG_IOS_DISK_CACHE_HEADROOM_GIB:-6}}"
[[ "$CACHE_BUDGET_GIB" =~ ^[0-9]+$ ]] || CACHE_BUDGET_GIB=16
[[ "$CACHE_HEADROOM_GIB" =~ ^[0-9]+$ ]] || CACHE_HEADROOM_GIB=6
CACHE_BUDGET_KB=$((CACHE_BUDGET_GIB * 1048576))
CACHE_HEADROOM_KB=$((CACHE_HEADROOM_GIB * 1048576))
if (( CACHE_HEADROOM_GIB <= CACHE_BUDGET_GIB )); then
  CACHE_WRITER_LIMIT_KB=$(((CACHE_BUDGET_GIB - CACHE_HEADROOM_GIB) * 1048576))
else
  CACHE_WRITER_LIMIT_KB=0
fi
DERIVED_DATA_BUDGET_GIB="${KG_DISK_GUARD_DERIVED_DATA_BUDGET_GIB:-4}"
[[ "$DERIVED_DATA_BUDGET_GIB" =~ ^[0-9]+$ ]] || DERIVED_DATA_BUDGET_GIB=4
DERIVED_DATA_BUDGET_KB=$((DERIVED_DATA_BUDGET_GIB * 1048576))
KEEP="${KG_DISK_GUARD_CACHE_KEEP:-3}"
# Ordinary cap sweeps preserve the reader window.  An explicit writer-budget
# repair drops that window only after the process probe is clear and the build
# lock is held; manual sweeps keep their longer age policy.
MIN_AGE_HOURS="${KG_DISK_GUARD_CACHE_MIN_AGE_HOURS:-0}"
READER_WINDOW_HOURS="${KG_DISK_GUARD_CACHE_READER_WINDOW_HOURS:-1}"
DERIVED_DATA_MIN_AGE_HOURS="${KG_DISK_GUARD_DERIVED_DATA_MIN_AGE_HOURS:-6}"
WORKTREE_CACHE_KEEP="${KG_DISK_GUARD_WORKTREE_CACHE_KEEP:-3}"
WORKTREE_CACHE_MIN_AGE_HOURS="${KG_DISK_GUARD_WORKTREE_CACHE_MIN_AGE_HOURS:-0}"
WORKTREE_READER_WINDOW_HOURS="${KG_DISK_GUARD_WORKTREE_READER_WINDOW_HOURS:-1}"
BUILD_LOCK_FILE="${KG_DISK_GUARD_BUILD_LOCK_FILE:-/tmp/kg-ios-build.lock}"
GUARD_LOCK_FILE="${KG_DISK_GUARD_LOCK_FILE:-/tmp/kg-disk-guard.lock}"
DRY_RUN="${KG_DISK_GUARD_DRY_RUN:-0}"
UV_BIN="${KG_DISK_GUARD_UV_BIN:-$HOME/.local/bin/uv}"
LANE_USAGE_BUDGET_SECONDS="${KG_DISK_GUARD_LANE_USAGE_BUDGET_SECONDS:-240}"
[[ "$LANE_USAGE_BUDGET_SECONDS" =~ ^[0-9]+$ ]] || LANE_USAGE_BUDGET_SECONDS=240
(( LANE_USAGE_BUDGET_SECONDS > 240 )) && LANE_USAGE_BUDGET_SECONDS=240
# The supervisor's kill sits GRACE seconds past the scan's own deadline.  Both
# used to be 240s from nearly the same instant, so the kill always won and a
# scan that needed the whole window never got to write the partial report its
# deadline exists to produce (2026-10-08: the report stayed 80 minutes stale).
LANE_USAGE_GRACE_SECONDS="${KG_DISK_GUARD_LANE_USAGE_GRACE_SECONDS:-60}"
[[ "$LANE_USAGE_GRACE_SECONDS" =~ ^[0-9]+$ ]] || LANE_USAGE_GRACE_SECONDS=60
(( LANE_USAGE_GRACE_SECONDS < 1 )) && LANE_USAGE_GRACE_SECONDS=1
(( LANE_USAGE_GRACE_SECONDS > 120 )) && LANE_USAGE_GRACE_SECONDS=120
# disk_usage.py exits 0 or 75 only after it atomically wrote its report.  A scan
# the supervisor had to kill gets the conventional timeout(1) status instead of
# sharing 75 with "report written".  The kill may land after this run already
# wrote a current report; only that report can feed the tick (write_lane_usage).
LANE_USAGE_KILLED_RC=124
LANE_USAGE_RC=0
LANE_USAGE_VERDICT="unavailable"
LANE_USAGE_EXCLUSIONS_JSON='[]'
LANE_USAGE_STRUCTURAL_BLOCKERS=0
XCTEST_DEVICES_KB=0
XCTEST_DEVICES_OVERFLOW_KB=0
XCTEST_DEVICES_COUNT=0
XCTEST_DEVICES_VERDICT="unavailable"
XCTEST_DEVICES_RECLAIM_STATUS="not-requested"
XCTEST_DEVICES_MANUAL_REVIEW=0
XCTEST_DEVICES_TIME_LIMITED=0
XCTEST_DEVICES_REPORT_ERROR=0
SIMULATOR_RUNTIME_KB=0
SIMULATOR_RUNTIME_OVERFLOW_KB=0
SIMULATOR_RUNTIME_COUNT=0
SIMULATOR_RUNTIME_VERDICT="unavailable"
SIMULATOR_RUNTIME_RECLAIM_STATUS="not-supported"
SIMULATOR_RUNTIME_MANUAL_REVIEW=0
SIMULATOR_RUNTIME_REPORT_ERROR=0
SUPERVISION_WORKTREE_ARGS=()
CACHE_EVICTION_ATTEMPTED=0
CACHE_EVICTION_EVICTED=0
CACHE_EVICTION_FAILED=0
CACHE_BUDGET_REPAIRED=0

# shellcheck source=lib/ios_cache_evict.sh
CACHE_LIB="${KG_DISK_GUARD_CACHE_LIB:-$SCRIPT_DIR/lib/ios_cache_evict.sh}"
[[ -f "$CACHE_LIB" ]] || CACHE_LIB="$HOME/butler/bin/kg_ios_cache_evict_lib.sh"
if [[ -f "$CACHE_LIB" ]]; then
  source "$CACHE_LIB"
else
  kg_ios_cache_evict() { return 0; }
fi

number() {
  case "$1" in ''|*[!0-9-]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

previous_free() {
  [[ -f "$STATE_FILE" ]] || { printf '0'; return; }
  sed -n 's/.*"free_bytes":\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" | head -1
}

free_bytes() {
  if [[ -n "${KG_DISK_GUARD_FREE_BYTES:-}" ]]; then
    printf '%s' "$KG_DISK_GUARD_FREE_BYTES"
  else
    df -Pk "$WORKSPACE" 2>/dev/null | awk 'NR==2 {print $4 * 1024; exit}'
  fi
}

# One argv line per process.  Callers anchor on argv[0] (the executable as
# invoked), so text that merely mentions a command never matches (#3444).
process_snapshot() {
  [[ "${KG_DISK_GUARD_PROCESS_PROBE_FAIL:-0}" == "1" ]] && return 1
  ps -axww -o args= 2>/dev/null
}

# One executable path per line.  macOS prints the full path, spaces included, so
# callers match the basename of the whole line and never split it.
process_command_snapshot() {
  [[ "${KG_DISK_GUARD_PROCESS_PROBE_FAIL:-0}" == "1" ]] && return 1
  ps -axo comm= 2>/dev/null
}

# True when PID $1 is this process or one of its ancestors.
caller_tree_has_pid() {
  local target="$1" pid="$$" parent hops=0
  while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && "$hops" -lt 64 ]]; do
    [[ "$pid" == "$target" ]] && return 0
    parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ "$parent" != "$pid" ]] || break
    pid="$parent"; hops=$((hops + 1))
  done
  return 1
}

# Live owner of the machine-global iOS build lock (shlock writes the owner PID).
# A lock the caller holds is not a competing build: the guard's own PID, the
# caller's process tree (ios_ops.sh runs the guard as a child of the holder),
# and BUILD_LOCK_HELD=1 (the caller declares it holds the lock) never count.
build_lock_has_live_owner() {
  local holder
  [[ "${KG_DISK_GUARD_BUILD_LOCK_HELD:-0}" == "1" ]] && return 1
  holder="$(cat "$BUILD_LOCK_FILE" 2>/dev/null || true)"
  case "$holder" in ''|*[!0-9]*) return 1 ;; esac
  [[ "$holder" != "$$" ]] || return 1
  kill -0 "$holder" 2>/dev/null || return 1
  ! caller_tree_has_pid "$holder"
}

# A build is an xcodebuild executable or a live build-lock owner.  Argv text is
# never a signal: `deliver.py` runs, shell wrappers and `ios_ops.sh guard
# --refresh` name build scripts without building, and counting them deferred
# floor eviction indefinitely (#3400).
active_build() {
  if [[ -n "${KG_DISK_GUARD_ACTIVE_BUILD:-}" ]]; then
    [[ "$KG_DISK_GUARD_ACTIVE_BUILD" == "1" ]] && printf '1' || printf '0'
    return
  fi
  local commands
  commands="$(process_command_snapshot)" || { printf '2'; return; }
  if grep -Eq '(^|/)xcodebuild$' <<<"$commands" || build_lock_has_live_owner; then
    printf '1'
  else
    printf '0'
  fi
}

shared_cache_roots() {
  local root
  for root in \
    "$WORKSPACE/.cache/ios-build-derived-data" \
    "$WORKSPACE/.cache/ios-test-derived-data" \
    "$WORKSPACE/.cache/ios-catalyst-derived-data" \
    "$WORKSPACE/.cache/ios-release-derived-data" \
    "$WORKSPACE/.cache/ops-swift-build" \
    "$WORKSPACE/ios/build"; do
    [[ -d "$root" ]] && printf '%s\n' "$root"
  done
}

# These are the only in-repo roots whose first-level directories are
# content-keyed cache generations.  Build and release DerivedData have Xcode's
# own internal first-level layout and must never be passed to the keyed-cache
# evictor.
shared_keyed_cache_roots() {
  local root
  for root in \
    "$WORKSPACE/.cache/ios-test-derived-data" \
    "$WORKSPACE/.cache/ios-catalog-derived-data"; do
    [[ -d "$root" ]] && printf '%s\n' "$root"
  done
}

# Do not recursively walk every worktree on each tick.  The cache roots are a
# fixed, shallow layout; globbing them is both bounded and immune to a giant
# DerivedData subtree making the monitor itself consume the machine.
worktree_topology_roots() {
  printf '%s\n' "$WORKSPACE/.claude/worktrees"
  printf '%s\n' "${KG_DISK_GUARD_CODEX_WORKTREE_ROOT:-$HOME/.codex/worktrees}"
}

worktree_cache_roots() {
  local worktree_root worktree kind root
  while IFS= read -r worktree_root; do
    [[ -d "$worktree_root" ]] || continue
    for worktree in "$worktree_root"/*; do
      [[ -d "$worktree" ]] || continue
      for kind in ios-build-derived-data ios-test-derived-data ios-catalyst-derived-data; do
        root="$worktree/.cache/$kind"
        [[ -d "$root" ]] && printf '%s\n' "$root"
      done
    done
  done < <(worktree_topology_roots)
}

worktree_keyed_cache_roots() {
  local worktree_root worktree kind root
  while IFS= read -r worktree_root; do
    [[ -d "$worktree_root" ]] || continue
    for worktree in "$worktree_root"/*; do
      [[ -d "$worktree" ]] || continue
      for kind in ios-test-derived-data ios-catalog-derived-data; do
        root="$worktree/.cache/$kind"
        [[ -d "$root" ]] && printf '%s\n' "$root"
      done
    done
  done < <(worktree_topology_roots)
}

# A physical worktree is reclaimable only after the registry identifies it as
# terminal.  Missing or unreadable ownership evidence is deliberately
# fail-closed: the guard must never remove an unknown or active lane's cache.
worktree_is_reclaimable() {
  # Worktree lifecycle belongs to the registry/orchestrator owner.  The disk
  # guard observes these paths but never evicts active, unknown, or terminal
  # worktree residue.
  return 1
}

reclaimable_worktree_keyed_cache_roots() {
  local root worktree
  while IFS= read -r root; do
    worktree="${root%/.cache/*}"
    [[ -n "$worktree" && "$worktree" != "$root" ]] || continue
    worktree_is_reclaimable "$worktree" && printf '%s\n' "$root"
  done < <(worktree_keyed_cache_roots)
}

cache_roots() {
  shared_cache_roots
  # Worktree DerivedData can be multi-GB and `du` may legitimately take minutes
  # while xcodebuild owns it.  The recurring guard must stay cheap; an operator
  # may opt in to the bounded max-depth sweep for a one-off audit.
  if [[ "${KG_DISK_GUARD_SCAN_WORKTREES:-0}" == "1" ]]; then
    worktree_cache_roots
  fi
}

worktree_cache_keys() {
  local root count total=0
  while IFS= read -r root; do
    count="$(find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$count" =~ ^[0-9]+$ ]] && total=$((total + count))
  done < <(worktree_keyed_cache_roots)
  printf '%s' "$total"
}

worktree_cache_overflow_keys() {
  local root count total=0
  while IFS= read -r root; do
    count="$(find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$count" =~ ^[0-9]+$ ]] || continue
    (( count > WORKTREE_CACHE_KEEP )) && total=$((total + count - WORKTREE_CACHE_KEEP))
  done < <(worktree_keyed_cache_roots)
  printf '%s' "$total"
}

keyed_cache_overflow_keys() {
  local root count total=0
  while IFS= read -r root; do
    count="$(find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$count" =~ ^[0-9]+$ ]] || continue
    (( count > KEEP )) && total=$((total + count - KEEP))
  done < <(shared_keyed_cache_roots)
  printf '%s' "$total"
}

cache_budget_overflow_kb() {
  local cache="$1" budget_gib="$CACHE_BUDGET_GIB"
  local budget_kb
  [[ "$budget_gib" =~ ^[0-9]+$ ]] || budget_gib=16
  budget_kb=$((budget_gib * 1048576))
  (( cache > budget_kb )) && printf '%s' "$((cache - budget_kb))" || printf '0'
}

derived_data_kb() {
  local root="$DERIVED_DATA_GLOBAL" path size total=0
  [[ -d "$root" ]] || { printf '0'; return; }
  while IFS= read -r path; do
    size="$(du -sk "$path" 2>/dev/null | awk 'NR==1 {print $1}')"
    [[ "$size" =~ ^[0-9]+$ ]] && total=$((total + size))
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'BooksAndVocab-*' -print 2>/dev/null)
  printf '%s' "$total"
}

derived_data_overflow_kb() {
  local derived_data="$1"
  (( derived_data > DERIVED_DATA_BUDGET_KB )) \
    && printf '%s' "$((derived_data - DERIVED_DATA_BUDGET_KB))" \
    || printf '0'
}

cache_headroom_overflow_kb() {
  local cache="$1" limit="$CACHE_WRITER_LIMIT_KB"
  [[ "$cache" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ ]] || { printf '0'; return; }
  (( cache > limit )) && printf '%s' "$((cache - limit))" || printf '0'
}

worktree_cache_kb() {
  local root count total=0 size
  # APFS free bytes is the authoritative size signal.  A recursive `du` over
  # active DerivedData can itself consume minutes and I/O; only an explicit
  # one-off audit opts into the expensive byte attribution.
  [[ "${KG_DISK_GUARD_WORKTREE_SIZE_SCAN:-0}" == "1" ]] || { printf '0'; return; }
  while IFS= read -r root; do
    count="$(find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$count" =~ ^[0-9]+$ ]] || continue
    (( count > WORKTREE_CACHE_KEEP )) || continue
    size="$(du -sk "$root" 2>/dev/null | awk 'NR==1 {print $1}')"
    [[ "$size" =~ ^[0-9]+$ ]] && total=$((total + size))
  done < <(worktree_keyed_cache_roots)
  printf '%s' "$total"
}

cache_kb() {
  local root total=0 size
  while IFS= read -r root; do
    # A root with no entries holds nothing; block-charging filesystems (ext4)
    # still bill its own directory block, which a zero budget would misread as
    # unreleased cache.
    [[ -n "$(find "$root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || continue
    size="$(du -sk "$root" 2>/dev/null | awk 'NR==1 {print $1}')"
    [[ "$size" =~ ^[0-9]+$ ]] && total=$((total + size))
  done < <(cache_roots)
  printf '%s' "$total"
}

size_to_kb() {
  local raw="$1" n unit
  n="$(printf '%s' "$raw" | sed -E 's/^([0-9]+([.][0-9]+)?).*/\1/')"
  unit="$(printf '%s' "$raw" | sed -E 's/^[0-9]+([.][0-9]+)?([A-Za-z]+).*/\2/')"
  [[ "$n" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '0'; return; }
  awk -v n="$n" -v unit="$unit" 'BEGIN{m=1; if(unit=="KB"||unit=="K")m=1; else if(unit=="MB"||unit=="M")m=1024; else if(unit=="GB"||unit=="G")m=1048576; else if(unit=="TB"||unit=="T")m=1073741824; printf "%.0f",n*m}'
}

docker_cache_kb() {
  if [[ -n "${KG_DISK_GUARD_DOCKER_CACHE_BYTES:-}" ]]; then
    printf '%s' "$((KG_DISK_GUARD_DOCKER_CACHE_BYTES / 1024))"; return
  fi
  command -v docker >/dev/null 2>&1 || { printf '0'; return; }
  local reclaim
  reclaim="$(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null \
    | awk -F'|' '$1=="Build Cache"{print $2}' | sed 's/[[:space:]].*$//' | head -1)"
  [[ -n "$reclaim" ]] && size_to_kb "$reclaim" || printf '0'
}

# A docker build is a per-invocation build process: the buildx plugin running a
# build or bake subcommand (matched by argv, so `docker buildx ls/inspect` is
# not a build), or the docker CLI whose argv[0] is docker and whose subcommand
# is a build.  Argv text that merely mentions a build (wrappers, log tails,
# deliver notes) never matches.  Long-lived docker daemons are deliberately not
# counted: they run whether or not a build does and would defer eviction forever.
docker_active() {
  if [[ -n "${KG_DISK_GUARD_DOCKER_ACTIVE:-}" ]]; then
    [[ "$KG_DISK_GUARD_DOCKER_ACTIVE" == "1" ]] && printf '1' || printf '0'; return
  fi
  local argv
  process_command_snapshot >/dev/null || { printf '2'; return; }
  argv="$(process_snapshot)" || { printf '2'; return; }
  if grep -Eq '(^|/)docker-buildx (build|bake)( |$)' <<<"$argv" \
    || grep -Eq '^([^ ]*/)?docker (build|builder build|buildx build|compose build)( |$)' <<<"$argv"; then
    printf '1'
  else
    printf '0'
  fi
}

prune_docker_cache() {
  command -v docker >/dev/null 2>&1 || return 0
  if [[ -n "${KG_DISK_GUARD_DOCKER_CACHE_BYTES:-}" ]]; then return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then
    logger -t kg-disk-guard "would-prune docker builder cache until=$DOCKER_PRUNE_UNTIL" 2>/dev/null || true
  else
    docker builder prune --force --filter "until=$DOCKER_PRUNE_UNTIL" >/dev/null 2>&1 || true
    logger -t kg-disk-guard "pruned docker builder cache until=$DOCKER_PRUNE_UNTIL" 2>/dev/null || true
  fi
}

trim_logs() {
  local raw file size max_kb keep_kb tmp
  raw="${KG_DISK_GUARD_LOG_FILES:-}"
  [[ -n "$raw" ]] || return 0
  max_kb="${KG_DISK_GUARD_LOG_MAX_KB:-2048}"
  keep_kb="${KG_DISK_GUARD_LOG_KEEP_KB:-512}"
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    size="$(du -k "$file" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    (( size <= max_kb )) && continue
    if [[ "$DRY_RUN" == "1" ]]; then
      logger -t kg-disk-guard "would-trim-log path=$file sizeKB=$size keepKB=$keep_kb" 2>/dev/null || true
      continue
    fi
    tmp="$file.$$.$RANDOM.tmp"
    tail -c "$((keep_kb * 1024))" "$file" > "$tmp" 2>/dev/null && cat "$tmp" > "$file" 2>/dev/null && rm -f "$tmp"
    logger -t kg-disk-guard "trimmed-log path=$file oldKB=$size keepKB=$keep_kb" 2>/dev/null || true
  done < <(printf '%s\n' "$raw" | tr ':' '\n')
}

kill_process_tree() {
  local pid="$1" signal="$2" children child
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  children="$(pgrep -P "$pid" 2>/dev/null || true)"
  if [[ -z "$children" ]]; then
    children="$(ps -axo pid=,ppid= 2>/dev/null | awk -v parent="$pid" '$2 == parent {print $1}' || true)"
  fi
  for child in $children; do
    kill_process_tree "$child" "$signal"
  done
  kill "-$signal" "$pid" 2>/dev/null || true
}

run_bounded_command() {
  local pid deadline timeout_seconds
  "$@" >/dev/null 2>&1 &
  pid="$!"
  # The kill is budget + grace, strictly after the scan's own deadline: the
  # scan needs process startup before its clock starts and a short tail after
  # it expires to atomically write its explicit timeout report (this also
  # covers a zero budget).  A stuck external process remains bounded.
  timeout_seconds=$((LANE_USAGE_BUDGET_SECONDS + LANE_USAGE_GRACE_SECONDS))
  deadline=$((SECONDS + timeout_seconds))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill_process_tree "$pid" TERM
      kill_process_tree "$pid" KILL
      wait "$pid" 2>/dev/null || true
      return "$LANE_USAGE_KILLED_RC"
    fi
    sleep 0.1
  done
  wait "$pid"
}

write_lane_usage() {
  local rc=0 observed="unavailable" path started_epoch report_mtime report_is_current=0
  started_epoch="$(date +%s)"
  local -a command_args=(
    --workspace "$WORKSPACE"
    --state "$REGISTRY_STATE"
    --output "$LANE_USAGE_STATE"
    --time-budget-seconds "$LANE_USAGE_BUDGET_SECONDS"
    --xctest-devices-root "$XCTEST_DEVICES_ROOT"
    --xctest-devices-budget-gib "$XCTEST_DEVICES_BUDGET_GIB"
    --simulator-runtime-budget-gib "$SIMULATOR_RUNTIME_BUDGET_GIB"
  )
  [[ "$XCTEST_DEVICES_AUTO_RECLAIM" == "1" ]] && command_args+=(--auto-reclaim-xctest-devices)
  for path in "${SUPERVISION_WORKTREE_ARGS[@]-}"; do
    [[ -n "$path" ]] || continue
    command_args+=(--supervision-worktree "$path")
  done
  if [[ -x "$UV_BIN" ]]; then
    run_bounded_command "$UV_BIN" run --no-project --python 3.13 "$SCRIPT_DIR/disk_usage.py" \
      "${command_args[@]}" \
      >/dev/null 2>&1 || rc=$?
  else
    run_bounded_command "$SCRIPT_DIR/disk_usage.py" "${command_args[@]}" \
      >/dev/null 2>&1 || rc=$?
  fi
  # Only a report this run wrote may feed this tick's state.  A killed or crashed
  # scan leaves the previous file in place; parsing it would launder hours-old
  # platform numbers and exclusions into a state stamped "now".  (-1s: mtime has
  # whole-second granularity.)
  if [[ -f "$LANE_USAGE_STATE" ]]; then
    report_mtime="$(kg_stat_mtime "$LANE_USAGE_STATE" 2>/dev/null || true)"
    if [[ "$report_mtime" =~ ^[0-9]+$ ]] && (( report_mtime >= started_epoch - 1 )); then
      report_is_current=1
    fi
  fi
  if (( rc != 0 )); then
    logger -t kg-disk-guard "lane-usage-report=blocked rc=$rc budget=${LANE_USAGE_BUDGET_SECONDS}s grace=${LANE_USAGE_GRACE_SECONDS}s killed=$(( rc == LANE_USAGE_KILLED_RC )) state=$LANE_USAGE_STATE" 2>/dev/null || true
  fi
  if (( report_is_current == 1 )); then
    observed="$(sed -n 's/^[[:space:]]*"verdict": "\([^"]*\)".*/\1/p' "$LANE_USAGE_STATE" | head -1)"
    case "$observed" in
      pass|warning|block) ;;
      *) observed="unavailable" ;;
    esac
  fi
  (( rc != 0 )) && observed="block"
  if (( report_is_current == 1 )) && command -v jq >/dev/null 2>&1; then
    LANE_USAGE_EXCLUSIONS_JSON="$(
      jq -c '.exclusions.supervision_worktree_paths // []' "$LANE_USAGE_STATE" \
        2>/dev/null || printf '[]'
    )"
  else
    LANE_USAGE_EXCLUSIONS_JSON='[]'
  fi
  # Structural findings in the current report: worktree problems and manual-review
  # causes, the same families kg_ios_disk_structural_lane_reason (lib/ios_disk_budget.sh)
  # treats as needing a human.  Counted from policy.blocking_reasons; an unreadable
  # current report counts as one, so the time-limit cannot mask it (fail closed).
  LANE_USAGE_STRUCTURAL_BLOCKERS=0
  if (( report_is_current == 1 )) && command -v jq >/dev/null 2>&1; then
    LANE_USAGE_STRUCTURAL_BLOCKERS="$(
      jq -r '[(.policy.blocking_reasons // [])[] | select(test("^(dirty|unknown|duplicate)-|^(physical-identity-mismatch|registry-records-invalid|supervision-path-registered)$|-manual-review-required$"))] | length' \
        "$LANE_USAGE_STATE" 2>/dev/null || printf '1'
    )"
  fi
  LANE_USAGE_RC="$rc"
  LANE_USAGE_VERDICT="$observed"
  XCTEST_DEVICES_KB=0
  XCTEST_DEVICES_OVERFLOW_KB=0
  XCTEST_DEVICES_COUNT=0
  XCTEST_DEVICES_VERDICT="unavailable"
  XCTEST_DEVICES_RECLAIM_STATUS="not-requested"
  XCTEST_DEVICES_MANUAL_REVIEW=0
  XCTEST_DEVICES_TIME_LIMITED=0
  XCTEST_DEVICES_REPORT_ERROR=0
  SIMULATOR_RUNTIME_KB=0
  SIMULATOR_RUNTIME_OVERFLOW_KB=0
  SIMULATOR_RUNTIME_COUNT=0
  SIMULATOR_RUNTIME_VERDICT="unavailable"
  SIMULATOR_RUNTIME_RECLAIM_STATUS="not-supported"
  SIMULATOR_RUNTIME_MANUAL_REVIEW=0
  SIMULATOR_RUNTIME_REPORT_ERROR=0
  if (( report_is_current == 1 )) && command -v jq >/dev/null 2>&1; then
    if jq -e '.accounting.shared_platform_storage.xctest_devices' "$LANE_USAGE_STATE" >/dev/null 2>&1; then
      XCTEST_DEVICES_KB="$(jq -r '(.accounting.shared_platform_storage.xctest_devices.budget_allocated_bytes // .accounting.shared_platform_storage.xctest_devices.allocated_bytes // 0) / 1024 | floor' "$LANE_USAGE_STATE")"
      XCTEST_DEVICES_OVERFLOW_KB="$(jq -r '(.accounting.shared_platform_storage.xctest_devices.budget_overflow_bytes // 0) / 1024 | floor' "$LANE_USAGE_STATE")"
      XCTEST_DEVICES_COUNT="$(jq -r '.accounting.shared_platform_storage.xctest_devices.device_count // 0' "$LANE_USAGE_STATE")"
      XCTEST_DEVICES_VERDICT="$(jq -r 'if .accounting.shared_platform_storage.xctest_devices.exists != true then "absent" elif .accounting.shared_platform_storage.xctest_devices.measurement_complete != true or .accounting.shared_platform_storage.xctest_devices.metadata_complete != true or .accounting.shared_platform_storage.xctest_devices.budget_exceeded == true then "block" else "pass" end' "$LANE_USAGE_STATE")"
      XCTEST_DEVICES_RECLAIM_STATUS="$(jq -r '.accounting.shared_platform_storage.xctest_devices.reclaim.status // "not-requested"' "$LANE_USAGE_STATE")"
      if [[ "$XCTEST_DEVICES_VERDICT" == "block" ]] && [[ "$XCTEST_DEVICES_RECLAIM_STATUS" != "reclaimed" ]]; then
        # A walk that only ran out of time (the 226k-file physical-extent pass
        # needs 150-220 s) is not a finding a human can act on: it clears on a
        # later tick, so it stays a temporary block instead of the structural
        # manual-review one.  Every other incompleteness (unreadable path,
        # missing metadata) and a real budget overrun still need a human.
        XCTEST_DEVICES_TIME_LIMITED="$(jq -r '.accounting.shared_platform_storage.xctest_devices as $x | (((($x.measurement_errors // []) + ($x.physical_measurement_errors // [])) | length) > 0 and ((($x.measurement_errors // []) + ($x.physical_measurement_errors // [])) | all(contains("measurement-time-budget-exceeded"))) and $x.metadata_complete == true and $x.budget_exceeded != true) | if . then 1 else 0 end' "$LANE_USAGE_STATE" 2>/dev/null || echo 0)"
        [[ "$XCTEST_DEVICES_TIME_LIMITED" == "1" ]] || XCTEST_DEVICES_TIME_LIMITED=0
        (( XCTEST_DEVICES_TIME_LIMITED == 1 )) || XCTEST_DEVICES_MANUAL_REVIEW=1
      fi
    else
      XCTEST_DEVICES_REPORT_ERROR=1
    fi
  else
    XCTEST_DEVICES_REPORT_ERROR=1
  fi
  if (( report_is_current == 1 )) && command -v jq >/dev/null 2>&1; then
    if jq -e '.accounting.shared_platform_storage.simulator_runtimes' "$LANE_USAGE_STATE" >/dev/null 2>&1; then
      SIMULATOR_RUNTIME_KB="$(jq -r '(.accounting.shared_platform_storage.simulator_runtimes.budget_allocated_bytes // .accounting.shared_platform_storage.simulator_runtimes.allocated_bytes // 0) / 1024 | floor' "$LANE_USAGE_STATE")"
      SIMULATOR_RUNTIME_OVERFLOW_KB="$(jq -r '(.accounting.shared_platform_storage.simulator_runtimes.budget_overflow_bytes // 0) / 1024 | floor' "$LANE_USAGE_STATE")"
      SIMULATOR_RUNTIME_COUNT="$(jq -r '.accounting.shared_platform_storage.simulator_runtimes.runtime_count // 0' "$LANE_USAGE_STATE")"
      SIMULATOR_RUNTIME_VERDICT="$(jq -r 'if (.accounting.shared_platform_storage.simulator_runtimes.exists != true) and ((.accounting.shared_platform_storage.simulator_runtimes.status // "") == "absent" or (.accounting.shared_platform_storage.simulator_runtimes.status // "") == "unsupported") then "absent" elif .accounting.shared_platform_storage.simulator_runtimes.measurement_complete != true or .accounting.shared_platform_storage.simulator_runtimes.budget_exceeded == true then "block" else "pass" end' "$LANE_USAGE_STATE")"
      SIMULATOR_RUNTIME_RECLAIM_STATUS="$(jq -r '.accounting.shared_platform_storage.simulator_runtimes.reclaim.status // "not-supported"' "$LANE_USAGE_STATE")"
      if [[ "$SIMULATOR_RUNTIME_VERDICT" == "block" ]]; then
        SIMULATOR_RUNTIME_MANUAL_REVIEW=1
      fi
    else
      SIMULATOR_RUNTIME_REPORT_ERROR=1
    fi
  else
    SIMULATOR_RUNTIME_REPORT_ERROR=1
  fi
}

evict_keyed_caches() {
  local root budget_only="${1:-0}" min_age_hours="$MIN_AGE_HOURS" old_budget old_budget_only old_budget_only_set=0
  if [[ "$budget_only" == "1" ]]; then
    min_age_hours=0
  else
    (( READER_WINDOW_HOURS > min_age_hours )) && min_age_hours="$READER_WINDOW_HOURS"
  fi
  old_budget="${KG_IOS_DISK_CACHE_BUDGET_KB:-}"
  [[ "${KG_IOS_CACHE_EVICT_BUDGET_ONLY+x}" == "x" ]] && old_budget_only_set=1
  old_budget_only="${KG_IOS_CACHE_EVICT_BUDGET_ONLY:-}"
  export KG_IOS_CACHE_KEEP="$KEEP"
  export KG_IOS_CACHE_EVICT_MIN_AGE_HOURS="$min_age_hours"
  export KG_IOS_CACHE_EVICT_DRY_RUN="$DRY_RUN"
  export KG_IOS_CACHE_EVICT_BUDGET_ONLY="$budget_only"
  # The shared evictor understands this override and can therefore enforce
  # the writer limit (budget minus headroom), not just the hard cache budget.
  export KG_IOS_DISK_CACHE_BUDGET_KB="$CACHE_WRITER_LIMIT_KB"
  while IFS= read -r root; do
    kg_ios_cache_evict "$root" "" || true
    CACHE_EVICTION_ATTEMPTED=$((CACHE_EVICTION_ATTEMPTED + ${KG_IOS_CACHE_EVICT_ATTEMPTED:-0}))
    CACHE_EVICTION_EVICTED=$((CACHE_EVICTION_EVICTED + ${KG_IOS_CACHE_EVICTED:-0}))
    CACHE_EVICTION_FAILED=$((CACHE_EVICTION_FAILED + ${KG_IOS_CACHE_EVICT_FAILED:-0}))
  done < <(shared_keyed_cache_roots)
  if [[ -n "$old_budget" ]]; then export KG_IOS_DISK_CACHE_BUDGET_KB="$old_budget"; else unset KG_IOS_DISK_CACHE_BUDGET_KB; fi
  if (( old_budget_only_set == 1 )); then export KG_IOS_CACHE_EVICT_BUDGET_ONLY="$old_budget_only"; else unset KG_IOS_CACHE_EVICT_BUDGET_ONLY; fi
}

evict_rebuildable_caches() {
  local root
  for root in \
    "$WORKSPACE/.cache/ios-build-derived-data" \
    "$WORKSPACE/.cache/ios-release-derived-data" \
    "$WORKSPACE/.cache/ios-catalyst-derived-data" \
    "$WORKSPACE/ios/build/BooksAndVocab.xcarchive" \
    "$WORKSPACE/ios/build/export"; do
    [[ -d "$root" ]] || continue
    if [[ "$DRY_RUN" == "1" ]]; then
      CACHE_EVICTION_ATTEMPTED=$((CACHE_EVICTION_ATTEMPTED + 1))
      logger -t kg-disk-guard "would-evict rebuildable-cache root=$root" 2>/dev/null || true
    else
      CACHE_EVICTION_ATTEMPTED=$((CACHE_EVICTION_ATTEMPTED + 1))
      if rm -rf "$root" 2>/dev/null; then
        CACHE_EVICTION_EVICTED=$((CACHE_EVICTION_EVICTED + 1))
        logger -t kg-disk-guard "evicted rebuildable-cache root=$root" 2>/dev/null || true
      else
        CACHE_EVICTION_FAILED=$((CACHE_EVICTION_FAILED + 1))
        logger -t kg-disk-guard "eviction-failed rebuildable-cache root=$root" 2>/dev/null || true
      fi
    fi
  done
}

evict_worktree_caches() {
  local old_keep old_min old_dry min_age_hours="$WORKTREE_CACHE_MIN_AGE_HOURS" eligible=0
  (( WORKTREE_READER_WINDOW_HOURS > min_age_hours )) && min_age_hours="$WORKTREE_READER_WINDOW_HOURS"
  old_keep="${KG_IOS_CACHE_KEEP:-}"
  old_min="${KG_IOS_CACHE_EVICT_MIN_AGE_HOURS:-}"
  old_dry="${KG_IOS_CACHE_EVICT_DRY_RUN:-}"
  export KG_IOS_CACHE_KEEP="$WORKTREE_CACHE_KEEP"
  export KG_IOS_CACHE_EVICT_MIN_AGE_HOURS="$min_age_hours"
  export KG_IOS_CACHE_EVICT_DRY_RUN="$DRY_RUN"
  while IFS= read -r root; do
    eligible=1
    kg_ios_cache_evict "$root" "" || true
  done < <(reclaimable_worktree_keyed_cache_roots)
  if [[ -n "$old_keep" ]]; then export KG_IOS_CACHE_KEEP="$old_keep"; else unset KG_IOS_CACHE_KEEP; fi
  if [[ -n "$old_min" ]]; then export KG_IOS_CACHE_EVICT_MIN_AGE_HOURS="$old_min"; else unset KG_IOS_CACHE_EVICT_MIN_AGE_HOURS; fi
  if [[ -n "$old_dry" ]]; then export KG_IOS_CACHE_EVICT_DRY_RUN="$old_dry"; else unset KG_IOS_CACHE_EVICT_DRY_RUN; fi
  (( eligible > 0 ))
}

acquire_build_lock_nonblocking() {
  [[ "${KG_DISK_GUARD_BUILD_LOCK_HELD:-0}" == "1" ]] && return 0
  if [[ -d "${BUILD_LOCK_FILE}.queue" ]] && find "${BUILD_LOCK_FILE}.queue" -mindepth 1 -maxdepth 1 -type f -name 'ticket-*' -print -quit 2>/dev/null | grep -q .; then
    # The iOS callers use this queue to preserve FIFO order.  A recurring
    # cleanup tick must never jump ahead of an already queued build/test.
    return 1
  fi
  command -v shlock >/dev/null 2>&1 || return 1
  shlock -f "$BUILD_LOCK_FILE" -p "$$" >/dev/null 2>&1
}

release_build_lock_if_owner() {
  local observed
  observed="$(cat "$BUILD_LOCK_FILE" 2>/dev/null || true)"
  [[ "$observed" == "$$" ]] || return 0
  [[ "$(cat "$BUILD_LOCK_FILE" 2>/dev/null || true)" == "$$" ]] || return 0
  rm -f "$BUILD_LOCK_FILE"
}

acquire_guard_lock_nonblocking() {
  [[ "${KG_DISK_GUARD_GUARD_LOCK_HELD:-0}" == "1" ]] && return 0
  command -v shlock >/dev/null 2>&1 || return 1
  shlock -f "$GUARD_LOCK_FILE" -p "$$" >/dev/null 2>&1
}

evict_old_app_derived_data() {
  local dd="$DERIVED_DATA_GLOBAL" now path mtime age
  [[ -d "$dd" ]] || return 0
  now="$(date +%s)"
  while IFS= read -r path; do
    mtime="$(kg_stat_mtime "$path" 2>/dev/null || echo 0)"
    age=$((now - mtime))
    (( age < DERIVED_DATA_MIN_AGE_HOURS * 3600 )) && continue
    if [[ "$DRY_RUN" == "1" ]]; then
      CACHE_EVICTION_ATTEMPTED=$((CACHE_EVICTION_ATTEMPTED + 1))
      logger -t kg-disk-guard "would-evict old app DerivedData path=$path" 2>/dev/null || true
    else
      CACHE_EVICTION_ATTEMPTED=$((CACHE_EVICTION_ATTEMPTED + 1))
      if rm -rf "$path" 2>/dev/null; then
        CACHE_EVICTION_EVICTED=$((CACHE_EVICTION_EVICTED + 1))
        logger -t kg-disk-guard "evicted old app DerivedData path=$path" 2>/dev/null || true
      else
        CACHE_EVICTION_FAILED=$((CACHE_EVICTION_FAILED + 1))
        logger -t kg-disk-guard "eviction-failed old app DerivedData path=$path" 2>/dev/null || true
      fi
    fi
  done < <(
    find "$dd" -mindepth 1 -maxdepth 1 -type d -name 'BooksAndVocab-*' -print 2>/dev/null \
      | while IFS= read -r path; do printf '%s\t%s\n' "$(kg_stat_mtime "$path" 2>/dev/null || echo 0)" "$path"; done \
      | sort -rn | tail -n +2 | cut -f2-
  )
}

evict_global_derived_data() {
  local root="$DERIVED_DATA_GLOBAL" current="$1" now path mtime size age
  [[ -d "$root" ]] || return 0
  now="$(date +%s)"
  while IFS=$'\t' read -r mtime size path; do
    [[ "$mtime" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ && -n "$path" ]] || continue
    (( current <= DERIVED_DATA_BUDGET_KB )) && break
    age=$((now - mtime))
    (( age < DERIVED_DATA_MIN_AGE_HOURS * 3600 )) && continue
    CACHE_EVICTION_ATTEMPTED=$((CACHE_EVICTION_ATTEMPTED + 1))
    if [[ "$DRY_RUN" == "1" ]]; then
      logger -t kg-disk-guard "would-evict global DerivedData path=$path sizeKB=$size" 2>/dev/null || true
      continue
    fi
    if rm -rf "$path" 2>/dev/null; then
      CACHE_EVICTION_EVICTED=$((CACHE_EVICTION_EVICTED + 1))
      current=$((current - size))
      logger -t kg-disk-guard "evicted global DerivedData path=$path sizeKB=$size" 2>/dev/null || true
    else
      CACHE_EVICTION_FAILED=$((CACHE_EVICTION_FAILED + 1))
      logger -t kg-disk-guard "eviction-failed global DerivedData path=$path" 2>/dev/null || true
    fi
  done < <(
    find "$root" -mindepth 1 -maxdepth 1 -type d -name 'BooksAndVocab-*' -print 2>/dev/null \
      | while IFS= read -r path; do
          size="$(du -sk "$path" 2>/dev/null | awk 'NR==1 {print $1}')"
          mtime="$(kg_stat_mtime "$path" 2>/dev/null || echo 0)"
          [[ "$size" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ ]] || continue
          printf '%s\t%s\t%s\n' "$mtime" "$size" "$path"
        done \
      | sort -n -k1,1 -k3,3
  )
}

write_state() {
  local free="$1" prev="$2" growth="$3" active="$4" cache="$5" docker_cache="$6" docker_running="$7" worktree_cache="$8" worktree_keys="$9" worktree_overflow="${10}" cache_overflow="${11}" budget_kb="${12}" budget_overflow="${13}" headroom_kb="${14}" writer_limit_kb="${15}" headroom_overflow="${16}" repair_remaining="${17}" repair_status="${18}" verdict="${19}" reason="${20}" action="${21}" lane_usage_verdict="${22}" lane_usage_rc="${23}" lane_usage_budget_seconds="${24}" lane_usage_exclusions_json="${25}" eviction_attempted="${26}" eviction_evicted="${27}" eviction_failed="${28}" budget_repaired="${29}" derived_data="${30}" derived_data_budget="${31}" derived_data_overflow="${32}" xctest_devices_kb="${33}" xctest_devices_budget_kb="${34}" xctest_devices_overflow_kb="${35}" xctest_devices_count="${36}" xctest_devices_verdict="${37}" xctest_devices_reclaim_status="${38}" xctest_devices_manual_review="${39}" simulator_runtime_kb="${40}" simulator_runtime_budget_kb="${41}" simulator_runtime_overflow_kb="${42}" simulator_runtime_count="${43}" simulator_runtime_verdict="${44}" simulator_runtime_reclaim_status="${45}" simulator_runtime_manual_review="${46}" xctest_devices_time_limited="${47}"
  local dir tmp
  dir="$(dirname "$STATE_FILE")"; mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$STATE_FILE.$$.$RANDOM.tmp"
  printf '{"schema":"kg.disk.guard.v1","host":"%s","free_bytes":%s,"previous_free_bytes":%s,"growth_bytes":%s,"active_build":%s,"cache_kb":%s,"cache_budget_kb":%s,"cache_budget_overflow_kb":%s,"cache_headroom_kb":%s,"cache_writer_limit_kb":%s,"cache_headroom_overflow_kb":%s,"cache_repair_remaining_kb":%s,"cache_repair_status":"%s","cache_eviction_attempted":%s,"cache_eviction_evicted":%s,"cache_eviction_failed":%s,"budget_repaired":%s,"derived_data_kb":%s,"derived_data_budget_kb":%s,"derived_data_overflow_kb":%s,"xctest_devices_kb":%s,"xctest_devices_budget_kb":%s,"xctest_devices_overflow_kb":%s,"xctest_devices_count":%s,"xctest_devices_verdict":"%s","xctest_devices_reclaim_status":"%s","xctest_devices_manual_review":%s,"xctest_devices_time_limited":%s,"simulator_runtime_kb":%s,"simulator_runtime_budget_kb":%s,"simulator_runtime_overflow_kb":%s,"simulator_runtime_count":%s,"simulator_runtime_verdict":"%s","simulator_runtime_reclaim_status":"%s","simulator_runtime_manual_review":%s,"docker_cache_kb":%s,"docker_active":%s,"worktree_cache_kb":%s,"worktree_cache_keys":%s,"worktree_cache_overflow_keys":%s,"cache_overflow_keys":%s,"verdict":"%s","reason":"%s","action":"%s","lane_usage_verdict":"%s","lane_usage_rc":%s,"lane_usage_budget_seconds":%s,"lane_usage_exclusions":%s,"at":"%s"}\n' \
    "$(hostname -s 2>/dev/null || echo unknown)" "$(number "$free")" "$(number "$prev")" "$(number "$growth")" \
    "$(number "$active")" "$(number "$cache")" "$(number "$budget_kb")" "$(number "$budget_overflow")" "$(number "$headroom_kb")" "$(number "$writer_limit_kb")" "$(number "$headroom_overflow")" "$(number "$repair_remaining")" "$repair_status" \
    "$(number "$eviction_attempted")" "$(number "$eviction_evicted")" "$(number "$eviction_failed")" "$(number "$budget_repaired")" \
    "$(number "$derived_data")" "$(number "$derived_data_budget")" "$(number "$derived_data_overflow")" "$(number "$xctest_devices_kb")" "$(number "$xctest_devices_budget_kb")" "$(number "$xctest_devices_overflow_kb")" "$(number "$xctest_devices_count")" "$xctest_devices_verdict" "$xctest_devices_reclaim_status" "$(number "$xctest_devices_manual_review")" "$(number "$xctest_devices_time_limited")" "$(number "$simulator_runtime_kb")" "$(number "$simulator_runtime_budget_kb")" "$(number "$simulator_runtime_overflow_kb")" "$(number "$simulator_runtime_count")" "$simulator_runtime_verdict" "$simulator_runtime_reclaim_status" "$(number "$simulator_runtime_manual_review")" "$(number "$docker_cache")" "$(number "$docker_running")" \
    "$(number "$worktree_cache")" "$(number "$worktree_keys")" "$(number "$worktree_overflow")" "$(number "$cache_overflow")" "$verdict" "$reason" "$action" "$lane_usage_verdict" "$(number "$lane_usage_rc")" "$(number "$lane_usage_budget_seconds")" "$lane_usage_exclusions_json" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$STATE_FILE"
}

main() {
  local free prev growth active cache docker_cache docker_running worktree_cache worktree_keys worktree_overflow cache_overflow derived_data derived_data_overflow cache_budget_kb cache_budget_overflow cache_headroom_kb cache_writer_limit_kb cache_headroom_overflow cache_repair_remaining cache_repair_status cache_after cache_after_budget_overflow cache_after_headroom_overflow free_gib growth_gib docker_gib verdict reason action lock_ready need_shared_cleanup build_lock_owned
  acquire_guard_lock_nonblocking || {
    logger -t kg-disk-guard 'skipped=already-running' 2>/dev/null || true
    return 0
  }
  CACHE_EVICTION_ATTEMPTED=0
  CACHE_EVICTION_EVICTED=0
  CACHE_EVICTION_FAILED=0
  CACHE_BUDGET_REPAIRED=0
  # An unreadable free-space probe must never read as 0 bytes free: that would
  # publish a false critical verdict and evict DerivedData.  Fail closed (no
  # verdict, no eviction, state file untouched) and let the next tick retry.
  free="$(free_bytes)"
  if [[ ! "$free" =~ ^[0-9]+$ ]]; then
    logger -t kg-disk-guard 'skipped=free-space-probe-failed' 2>/dev/null || true
    echo "kg-disk-guard: free-space probe failed; no verdict published, no cleanup performed" >&2
    return 1
  fi
  prev="$(number "$(previous_free)")"
  growth=0; (( prev > free )) && growth=$((prev - free))
  active="$(active_build)"; cache="$(cache_kb)"
  docker_cache="$(docker_cache_kb)"; docker_running="$(docker_active)"
  derived_data="$(derived_data_kb)"; derived_data_overflow="$(derived_data_overflow_kb "$derived_data")"
  worktree_keys="$(worktree_cache_keys)"; worktree_overflow="$(worktree_cache_overflow_keys)"; cache_overflow="$(keyed_cache_overflow_keys)"; worktree_cache="$(worktree_cache_kb)"
  cache_budget_kb="$CACHE_BUDGET_KB"; cache_headroom_kb="$CACHE_HEADROOM_KB"; cache_writer_limit_kb="$CACHE_WRITER_LIMIT_KB"
  cache_budget_overflow="$(cache_budget_overflow_kb "$cache")"; cache_headroom_overflow="$(cache_headroom_overflow_kb "$cache")"
  cache_repair_remaining="$cache_headroom_overflow"; cache_repair_status="not-needed"
  free_gib=$((free / 1073741824)); growth_gib=$((growth / 1073741824))
  docker_gib=$((docker_cache / 1048576)); docker_warn_kb=$((DOCKER_WARN_GIB * 1048576)); verdict="ok"; reason="within-bounds"; action="none"
  if (( free_gib <= CRIT_FREE_GIB )); then
    verdict="critical"; reason="free-below-critical"
  elif (( free_gib <= WARN_FREE_GIB )); then
    verdict="warning"; reason="free-below-warning"
  elif (( growth_gib >= GROWTH_WARN_GIB )); then
    verdict="warning"; reason="rapid-growth"
  elif (( docker_cache >= docker_warn_kb )); then
    verdict="warning"; reason="docker-build-cache"
  elif (( cache_budget_overflow > 0 )); then
    verdict="warning"; reason="cache-budget-exceeded"
  elif (( derived_data_overflow > 0 )); then
    verdict="warning"; reason="derived-data-budget-exceeded"
  elif (( cache_headroom_overflow > 0 )); then
    verdict="warning"; reason="cache-budget-headroom-exhausted"
  elif (( cache_overflow > 0 )); then
    verdict="warning"; reason="ios-cache-overflow"
  elif (( worktree_overflow > 0 )); then
    verdict="warning"; reason="worktree-cache-overflow"
  fi
  if [[ "$verdict" != "ok" ]]; then
    if [[ "$active" == "1" || "$docker_running" == "1" ]]; then
      action="deferred-active-build"
      (( cache_headroom_overflow > 0 )) && cache_repair_status="deferred-active-build"
    elif [[ "$active" != "0" || "$docker_running" != "0" ]]; then
      action="deferred-process-observation"
      (( cache_headroom_overflow > 0 )) && cache_repair_status="deferred-process-observation"
    else
      lock_ready=0
      build_lock_owned=0
      if (( worktree_overflow > 0 )); then
        if acquire_build_lock_nonblocking; then
          lock_ready=1
          [[ "${KG_DISK_GUARD_BUILD_LOCK_HELD:-0}" == "1" ]] || build_lock_owned=1
          if evict_worktree_caches; then
            action="evict-worktree-cache"
          else
            action="deferred-worktree-ownership"
            (( cache_headroom_overflow > 0 )) && cache_repair_status="deferred-worktree-ownership"
          fi
        else
          action="deferred-build-lock"
          (( cache_headroom_overflow > 0 )) && cache_repair_status="deferred-build-lock"
        fi
      fi
      need_shared_cleanup=0
      if [[ "$action" == "none" ]]; then
        need_shared_cleanup=1
      elif [[ "$action" == "evict-worktree-cache" || "$action" == "deferred-worktree-ownership" ]] && (( cache_overflow > 0 || cache_budget_overflow > 0 || cache_headroom_overflow > 0 || derived_data_overflow > 0 || free_gib <= WARN_FREE_GIB )); then
        # Keep the existing pressure cleanup in the same guarded turn, and
        # also enforce the shared keyed-cache cap when disk space is healthy.
        need_shared_cleanup=1
      fi
      if (( need_shared_cleanup > 0 )); then
        if (( lock_ready == 1 )) || acquire_build_lock_nonblocking; then
          build_lock_owned=1
          if (( cache_budget_overflow > 0 || cache_headroom_overflow > 0 )); then
            local old_keep="$KEEP"
            local budget_only=0
            (( cache_headroom_overflow > 0 )) && budget_only=1
            KEEP=0
            evict_keyed_caches "$budget_only"
            KEEP="$old_keep"
            # Preserve incremental build data when keyed eviction alone has
            # released enough writer headroom.  A full build-cache removal is
            # the bounded cold-rebuild fallback, not the first response.
            cache_after="$(cache_kb)"
            cache_after_budget_overflow="$(cache_budget_overflow_kb "$cache_after")"
            cache_after_headroom_overflow="$(cache_headroom_overflow_kb "$cache_after")"
            if (( cache_after_budget_overflow > 0 || cache_after_headroom_overflow > 0 )); then
              evict_rebuildable_caches
            fi
            if (( cache_budget_overflow > 0 )); then
              action="enforce-cache-budget"
            else
              action="enforce-cache-headroom"
            fi
          else
            evict_keyed_caches
          fi
          if (( derived_data_overflow > 0 )); then
            evict_global_derived_data "$derived_data"
            action="enforce-derived-data-budget"
          fi
          if [[ "$action" == "none" ]]; then
            action="evict-old-ios-cache"
          elif [[ "$action" == "evict-worktree-cache" ]]; then
            action="evict-worktree-cache-and-ios-cache"
          fi
        elif [[ "$action" == "none" ]]; then
          action="deferred-build-lock"
          (( cache_headroom_overflow > 0 )) && cache_repair_status="deferred-build-lock"
        fi
      fi
      if (( cache_headroom_overflow > 0 )) && [[ "$cache_repair_status" == "not-needed" || "$cache_repair_status" == "deferred-worktree-ownership" ]]; then
        cache_after="$(cache_kb)"
        cache_repair_remaining="$(cache_headroom_overflow_kb "$cache_after")"
        if (( CACHE_EVICTION_FAILED > 0 )); then
          cache_repair_status="failed"
          reason="cache-budget-repair-failed"
        elif (( cache_repair_remaining > 0 )); then
          cache_repair_status="insufficient"
          reason="cache-budget-headroom-unreleased"
        else
          cache_repair_status="repaired"
          CACHE_BUDGET_REPAIRED=1
        fi
      fi
      if (( docker_cache >= docker_warn_kb )); then
        prune_docker_cache; action="evict-old-ios-cache-and-docker-build-cache"
      fi
      if (( free_gib <= CRIT_FREE_GIB )); then
        evict_old_app_derived_data; action="evict-old-ios-cache-and-derived-data"
      fi
      (( build_lock_owned == 1 )) && release_build_lock_if_owner
    fi
  fi
  if (( CACHE_EVICTION_FAILED > 0 )); then
    CACHE_BUDGET_REPAIRED=0
    [[ "$verdict" == "ok" ]] && verdict="warning"
    reason="cache-eviction-failed"
  fi
  # Known launchd logs are capped every tick, even while disk pressure is healthy.
  # Otherwise a quiet disk can still accumulate a multi-GB service log between alerts.
  trim_logs
  # Keep one atomic, bounded report for every registered and physical worktree.
  # This is observation only: unknown or active lanes are never deleted by the
  # disk guard; their evidence is consumed by the supported lifecycle tools.
  write_lane_usage
  if (( XCTEST_DEVICES_REPORT_ERROR == 1 )); then
    verdict="block"
    reason="xctest-devices-report-unavailable"
    action="manual-review-xctest-devices"
  elif [[ "$XCTEST_DEVICES_VERDICT" == "block" ]]; then
    verdict="block"
    if (( XCTEST_DEVICES_MANUAL_REVIEW == 1 )); then
      reason="xctest-devices-manual-review-required"
      action="manual-review-xctest-devices"
    elif (( XCTEST_DEVICES_TIME_LIMITED == 1 )); then
      reason="xctest-devices-measurement-incomplete"
      action="retry-next-tick"
    else
      reason="xctest-devices-budget-exceeded"
      action="reclaimed-xctest-devices"
    fi
  fi
  if (( SIMULATOR_RUNTIME_REPORT_ERROR == 1 )); then
    verdict="block"
    reason="simulator-runtime-report-unavailable"
    action="manual-review-simulator-runtimes"
  elif [[ "$SIMULATOR_RUNTIME_VERDICT" == "block" ]]; then
    verdict="block"
    reason="simulator-runtime-manual-review-required"
    action="manual-review-simulator-runtimes"
  fi
  # Lane attribution is part of the disk safety boundary. A timed-out,
  # unavailable, or policy-blocked report must never be summarized as a
  # healthy guard state, even when aggregate filesystem pressure is low.
  # Existing lane evidence remains in the report; this only prevents new
  # work from being admitted on incomplete accounting.
  if (( LANE_USAGE_RC != 0 )) || [[ "$LANE_USAGE_VERDICT" == "block" || "$LANE_USAGE_VERDICT" == "unavailable" ]]; then
    # Why only rc 124 keeps the XCTestDevices time-limit reason, and rc 75 does not:
    # - rc 75: the scan finished and its report carries complete lane attribution
    #   with its own block cause.  That finding outranks the time-limit, which is
    #   only a subordinate sub-measurement (test: "lane report that exits 75").
    # - rc 124: the scan was killed, so its attribution is unknown and the
    #   time-limit is the only measured cause in this tick.  It is kept, and it is
    #   retryable.  The reason survives only if write_lane_usage saw a current
    #   report, because XCTEST_DEVICES_TIME_LIMITED is set only from one.
    # A kill with no current report of its own has no measured cause at all.  It
    # deliberately stays lane-usage-report-blocked / manual-review, fail-closed: a
    # scan that dies without writing a report is a persistent hang, and
    # retry-next-tick would hide it.
    # A current report that also names a structural blocker (dirty, unknown or
    # duplicate worktree, identity mismatch, manual-review finding) outranks the
    # time-limit: it is already a complete finding that waiting cannot clear.
    if (( LANE_USAGE_RC == LANE_USAGE_KILLED_RC )) && [[ "$reason" == "xctest-devices-measurement-incomplete" ]] \
      && (( LANE_USAGE_STRUCTURAL_BLOCKERS == 0 )); then
      :
    else
      verdict="block"
      if (( LANE_USAGE_RC != 0 )) || [[ "$LANE_USAGE_VERDICT" == "block" ]]; then
        reason="lane-usage-report-blocked"
      else
        reason="lane-usage-report-unavailable"
      fi
      action="manual-review-lane-attribution"
    fi
  fi
  write_state "$free" "$prev" "$growth" "$active" "$cache" "$docker_cache" "$docker_running" "$worktree_cache" "$worktree_keys" "$worktree_overflow" "$cache_overflow" "$cache_budget_kb" "$cache_budget_overflow" "$cache_headroom_kb" "$cache_writer_limit_kb" "$cache_headroom_overflow" "$cache_repair_remaining" "$cache_repair_status" "$verdict" "$reason" "$action" "$LANE_USAGE_VERDICT" "$LANE_USAGE_RC" "$LANE_USAGE_BUDGET_SECONDS" "$LANE_USAGE_EXCLUSIONS_JSON" "$CACHE_EVICTION_ATTEMPTED" "$CACHE_EVICTION_EVICTED" "$CACHE_EVICTION_FAILED" "$CACHE_BUDGET_REPAIRED" "$derived_data" "$DERIVED_DATA_BUDGET_KB" "$derived_data_overflow" "$XCTEST_DEVICES_KB" "$XCTEST_DEVICES_BUDGET_KB" "$XCTEST_DEVICES_OVERFLOW_KB" "$XCTEST_DEVICES_COUNT" "$XCTEST_DEVICES_VERDICT" "$XCTEST_DEVICES_RECLAIM_STATUS" "$XCTEST_DEVICES_MANUAL_REVIEW" "$SIMULATOR_RUNTIME_KB" "$SIMULATOR_RUNTIME_BUDGET_KB" "$SIMULATOR_RUNTIME_OVERFLOW_KB" "$SIMULATOR_RUNTIME_COUNT" "$SIMULATOR_RUNTIME_VERDICT" "$SIMULATOR_RUNTIME_RECLAIM_STATUS" "$SIMULATOR_RUNTIME_MANUAL_REVIEW" "$XCTEST_DEVICES_TIME_LIMITED"
  logger -t kg-disk-guard "verdict=$verdict freeGiB=$free_gib growthGiB=$growth_gib activeBuild=$active dockerCacheGiB=$docker_gib dockerActive=$docker_running cacheKB=$cache cacheBudgetKB=$cache_budget_kb cacheBudgetOverflowKB=$cache_budget_overflow cacheHeadroomKB=$cache_headroom_kb cacheWriterLimitKB=$cache_writer_limit_kb cacheHeadroomOverflowKB=$cache_headroom_overflow cacheRepairStatus=$cache_repair_status cacheRepairRemainingKB=$cache_repair_remaining derivedDataKB=$derived_data derivedDataBudgetKB=$DERIVED_DATA_BUDGET_KB derivedDataOverflowKB=$derived_data_overflow worktreeCacheKB=$worktree_cache worktreeKeys=$worktree_keys worktreeOverflowKeys=$worktree_overflow cacheOverflowKeys=$cache_overflow simulatorRuntimeKB=$SIMULATOR_RUNTIME_KB simulatorRuntimeBudgetKB=$SIMULATOR_RUNTIME_BUDGET_KB simulatorRuntimeOverflowKB=$SIMULATOR_RUNTIME_OVERFLOW_KB simulatorRuntimeCount=$SIMULATOR_RUNTIME_COUNT simulatorRuntimeVerdict=$SIMULATOR_RUNTIME_VERDICT action=$action" 2>/dev/null || true
}

while (($#)); do
  case "$1" in
    -h|--help)
      cat <<'USAGE'
Usage: ops/kg_disk_guard.sh [--supervision-worktree PATH ...]

Run one bounded disk-guard tick. The guard records lane attribution, defers
cleanup while an iOS consumer is active, and only evicts rebuildable caches
under its configured budgets. Unknown or active worktrees are never deleted.

Environment:
  KG_DISK_GUARD_WARN_FREE_GIB             warning floor (default: 50)
  KG_DISK_GUARD_CRIT_FREE_GIB             critical floor, inclusive (default: 36)
  KG_DISK_GUARD_SIMULATOR_RUNTIME_BUDGET_GIB
                                          shared mounted runtime cap (default: 56)
  KG_DISK_GUARD_LANE_USAGE_BUDGET_SECONDS  attribution scan budget (default: 240)
                                            values above 240 are clamped to 240
  KG_DISK_GUARD_LANE_USAGE_GRACE_SECONDS   how long past that budget the scan may
                                            still write its report before the
                                            supervisor kills it (default: 60,
                                            range 1-120); a killed scan is
                                            recorded as lane_usage_rc=124
  KG_DISK_GUARD_DERIVED_DATA_BUDGET_GIB  global BooksAndVocab-* cap (default: 4)
  KG_DISK_GUARD_DRY_RUN=1                  report intended cleanup only
  --supervision-worktree PATH               exclude one exact caller-supplied
                                            supervision checkout from lane quota
USAGE
      exit 0
      ;;
    --supervision-worktree)
      if (($# < 2)) || [[ -z "$2" ]]; then
        echo "--supervision-worktree requires an exact path" >&2
        exit 64
      fi
      SUPERVISION_WORKTREE_ARGS+=("$2")
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 64
      ;;
  esac
done

# Sourcing loads the functions without running a tick; tests stub the process
# seams in-process through this boundary (ops/tests/test_kg_disk_guard.sh).
# A sourced load must take no arguments: the argument loop above reads $@.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
