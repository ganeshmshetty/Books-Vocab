#!/usr/bin/env bash
# ios_build.sh — lock-guarded iOS build for parallel worktree agents
#
# Usage:
#   ./ops/ios_build.sh                           # from project root (any worktree)
#   ./ops/ios_build.sh --timeout 300             # custom lock wait (default: 600s)
#   ./ops/ios_build.sh --extra-settings KEY=VAL  # pass extra xcodebuild settings (repeatable)
#   ./ops/ios_build.sh --swift6                  # shorthand: SWIFT_STRICT_CONCURRENCY=complete
#   ./ops/ios_build.sh --configuration Release   # build configuration (default: Debug)
#   ./ops/ios_build.sh --catalyst --dry-run      # print the app + test-target compile plan
#
# How it works:
#   1. Spin-waits to acquire an exclusive lock (shlock, macOS built-in)
#   2. Runs xcodebuild build-for-testing against ONE shared DerivedData anchored at
#      the main repo; this compiles the app and the scheme's test targets
#      (incremental reuse across worktrees; bounded size; no path-hashed orphans)
#   3. Releases lock via trap on exit
#
# Safe for concurrent calls — second caller blocks until first finishes.

set -euo pipefail

LOCK_FILE="${KG_IOS_BUILD_LOCK_FILE:-/tmp/kg-ios-build.lock}"   # override only for hermetic tests
# Lock spin-wait budget. `--timeout` still overrides per call; the env var exists
# for callers that build their own argv and cannot pass flags — notably
# `worktree_orchestrate.py gate`, which runs several lock-taking gates in
# sequence. On a machine with a handful of active worktrees (they all share this
# one lock, `ios_test.sh` included) 600s is routinely not enough, and the failure
# is ugly: the run exits 1 having never reached xcodebuild, so it produces no
# build log and no verdict file, and the gate records it as a `block`
# indistinguishable from a genuine compile error.
TIMEOUT="${KG_IOS_BUILD_LOCK_TIMEOUT:-600}"
POLL_INTERVAL=3
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro Max'
CONFIGURATION='Debug'
EXTRA_SETTINGS=()
CATALYST=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --destination) DESTINATION="$2"; shift 2 ;;
    --catalyst) DESTINATION='platform=macOS,variant=Mac Catalyst'; CATALYST=1; shift ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --extra-settings) EXTRA_SETTINGS+=("$2"); shift 2 ;;
    --swift6) EXTRA_SETTINGS+=("SWIFT_STRICT_CONCURRENCY=complete"); shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Catalyst is a COMPILE gate ("sim green != Catalyst green"), and compilability
# is orthogonal to signability: macOS refuses to code-sign without a "Mac
# Development" identity, which a machine that only ships via Apple Distribution
# never has. Requiring one here made `ios-build-catalyst` — a BLOCK CI gate
# — unpassable by construction, the mirror image of an unfailable gate: no
# signal, and everyone learns to route around the red (IMP-0039). Real signing
# is proven where it belongs, in ops/ios_release.sh's archive/export.
# Composed here rather than at parse time so the caller's --extra-settings
# always land LAST (xcodebuild takes the last occurrence) regardless of arg order.
SETTINGS=()
if [[ "$CATALYST" == "1" ]]; then
  SETTINGS+=("CODE_SIGNING_ALLOWED=NO" "CODE_SIGNING_REQUIRED=NO")
fi
SETTINGS+=("${EXTRA_SETTINGS[@]+"${EXTRA_SETTINGS[@]}"}")

# Resolve project root from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 必須在第一個 start_build_monitor 呼叫之前 source。少了這行不會炸——兩個呼叫點都在
# `set +e` 區段內——而是無聲降級：整場 build 沒有 heartbeat，收尾印出空的
# `( compile events)`，progress baseline 也永遠寫不進去。ios_test.sh 一直有 source，
# 兩支腳本長得夠像，肉眼 review 看不出差別。回歸由 ops/tests/test_lib_sourcing.sh 擋。
# shellcheck source=lib/ios_build_progress.sh
source "$SCRIPT_DIR/lib/ios_build_progress.sh"
# shellcheck source=lib/ios_lock_wait.sh
source "$SCRIPT_DIR/lib/ios_lock_wait.sh"
# Optional run-metrics logging — additive, must never break the build.
METRICS_LIB="$SCRIPT_DIR/lib/ios_run_metrics.sh"
[[ -f "$METRICS_LIB" ]] && source "$METRICS_LIB"
# Build progress heartbeat. NOT optional: `start_build_monitor` is called
# unconditionally below, and without this source the call fails with
# "command not found" — bash keeps going, MONITOR_PID ends up empty, and the
# build runs completely silent for its full duration (the "compile events"
# count in the success line comes out blank, which is the visible tell). That
# leaves the operator guessing whether a multi-minute build is alive, which is
# exactly what the heartbeat contract exists to prevent. `ios_test.sh` and
# `ios_release.sh` have always sourced it; this script was the odd one out.
# shellcheck source=lib/ios_build_progress.sh
source "$SCRIPT_DIR/lib/ios_build_progress.sh"
# Install provenance is written beside every successful installable iOS app.
# shellcheck source=lib/ios_install_provenance.sh
source "$SCRIPT_DIR/lib/ios_install_provenance.sh"
# shellcheck source=lib/ios_swiftpm_cache.sh
source "$SCRIPT_DIR/lib/ios_swiftpm_cache.sh"
# shellcheck source=lib/ios_disk_budget.sh
source "$SCRIPT_DIR/lib/ios_disk_budget.sh"
XCODEPROJ="$PROJECT_ROOT/ios/BooksAndVocab.xcodeproj"
IOS_OPS="$SCRIPT_DIR/ios_ops.sh"
# DerivedData remains one shared, bounded cache anchored at the MAIN repo;
# install provenance, not cache isolation, distinguishes its producer.
DERIVED_DATA_ROOT="$(kg_ios_shared_derived_data_root "$PROJECT_ROOT")"
# Catalyst is a separate platform product set.  Keeping it in the simulator/device
# cache makes one Gate accumulate two full Xcode trees before the receipt is written.
# The platform suffix also makes cleanup ownership explicit: Catalyst is a compile
# gate artifact, not an install/test cache.
if [[ "$CATALYST" == "1" ]]; then
  DERIVED_DATA_ROOT="$DERIVED_DATA_ROOT/catalyst"
fi

if [[ ! -d "$XCODEPROJ" ]]; then
  echo "error: $XCODEPROJ not found" >&2
  exit 1
fi
kg_ios_swiftpm_configure "$PROJECT_ROOT"

CALLER="${WORKTREE_BRANCH:-$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo 'unknown')}"

ios_build_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

destination_is_simulator() {
  [[ "$DESTINATION" == *"platform=iOS Simulator"* ]]
}

destination_simulator_name() {
  sed -n 's/.*name=\([^,]*\).*/\1/p' <<<"$DESTINATION" | head -1
}

# Progress baseline: compile-event count from last successful build.
# Stored next to DerivedData (shared across worktrees, same cache root).
# First run has no baseline → raw counts only; after first build % is shown.
BUILD_PROGRESS_BASELINE="$DERIVED_DATA_ROOT/kg_build.events_baseline"

# The ONE definition of what xcodebuild is invoked with. `--dry-run` prints it
# and the real build consumes it, so "the plan" and "the run" cannot drift.
# This shape was forced by review: with a separate printer, reverting the
# Catalyst fix at the CALL SITE alone left every --dry-run assertion green —
# the tests measured the printer, not the plumbing. `-resultBundlePath` is the
# one parameterised element (its tempdir is only created after the lock).
xcodebuild_argv() {  # $1 = result bundle path; empty omits the flag
  local -a argv=(
    -project "$XCODEPROJ"
    -scheme BooksAndVocab
    -configuration "$CONFIGURATION"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA_ROOT"
    "${KG_IOS_SWIFTPM_XCODEBUILD_ARGS[@]+"${KG_IOS_SWIFTPM_XCODEBUILD_ARGS[@]}"}"
  )
  [[ -n "${1:-}" ]] && argv+=(-resultBundlePath "$1")
  argv+=("${SETTINGS[@]+"${SETTINGS[@]}"}" build-for-testing)
  printf '%s\n' "${argv[@]}"
}

# Report the resolved invocation without touching the lock, the simulator or
# xcodebuild. Placed AFTER DerivedData resolution so the plan shows the real
# cache root, and BEFORE the lock so inspecting a plan never blocks a build.
if [[ "$DRY_RUN" == "1" ]]; then
  # `--json` pins KG_IOS_VERDICT_FILE (ops/ios_ops.sh) and then reads that file
  # back as this invocation's result. A plan writes no verdict, so the pair
  # would report some earlier run as if it were this one — exit 0 with no
  # evidence, which is the failure mode this branch exists to remove.
  if [[ -n "${KG_IOS_VERDICT_FILE:-}" ]]; then
    echo "error: --dry-run cannot be combined with --json (a plan produces no verdict)" >&2
    exit 1
  fi
  xcodebuild_argv "" | sed 's/^/argv=/'
  exit 0
fi

# --- Early guard verdict: decided BEFORE queueing for the build lock ---
# A structural block (exit 77, retryable=no) or a temporary one (exit 75) costs
# seconds here instead of a lock-queue wait; the in-lock preflight below then
# measures real disk space only.
# Per-invocation verdict paths (see ops/lib/ios_run_verdict.sh). Initialized
# before the first exit that can happen so a refusal still leaves evidence:
# without it `ios_ops.sh build --json` reads back result=missing/exit=null for a
# run that was in fact blocked, indistinguishable from a run that never started.
# shellcheck source=lib/ios_run_verdict.sh
source "$SCRIPT_DIR/lib/ios_run_verdict.sh"
kg_ios_verdict_init build "$PROJECT_ROOT"

# Publish an `inconclusive` verdict (no build ran) carrying the real exit code
# and the guard reason. Same kg.ios.run-verdict.v1 shape as write_json_verdict
# below and as ios_test.sh's write_early_failure_verdict.
write_early_failure_verdict() {
  local reason="$1" exit_code="$2"
  echo "RESULT=inconclusive EXIT=$exit_code reason=$reason caller=$CALLER elapsed=0s $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  jq -nc \
    --arg schema "kg.ios.run-verdict.v1" \
    --arg kind "build" \
    --arg result "inconclusive" \
    --arg exit "$exit_code" \
    --arg reason "$reason" \
    --arg caller "$CALLER" \
    --arg cwd "$PROJECT_ROOT" \
    --arg verdictFile "$VERDICT_FILE" \
    --argjson ts "$(date +%s)" \
    --argjson pid "$$" \
    '{
      schema:$schema,
      kind:$kind,
      status:$result,
      result:$result,
      exit:$exit,
      reason:$reason,
      caller:$caller,
      invocation:{ts:$ts,pid:$pid,cwd:$cwd,verdictFile:$verdictFile},
      elapsed:"0s",
      executed:null,
      artifacts:{log:null,xcresult:null}
    }' >"$VERDICT_JSON_FILE" || true
  kg_ios_verdict_publish
}

early_guard_rc=0
kg_ios_disk_guard_early_verdict "build" || early_guard_rc=$?
if (( early_guard_rc != 0 )); then
  echo "[ios_build] not started: shared disk guard blocked (exit $early_guard_rc); './ops/ios_ops.sh guard' shows the verdict" >&2
  if (( early_guard_rc == KG_IOS_DISK_STRUCTURAL_EXIT )); then
    write_early_failure_verdict "disk-guard-structural-block" "$early_guard_rc"
  else
    write_early_failure_verdict "disk-guard-blocked" "$early_guard_rc"
  fi
  exit "$early_guard_rc"
fi
kg_ios_disk_guard_mark_checked

# --- Lock acquire (shlock spin-wait) ---
MONITOR_PID=""
cleanup() {
  kg_ios_release_shlock_if_owner "$LOCK_FILE" "$$"
  [[ -n "$MONITOR_PID" ]] && kill "$MONITOR_PID" 2>/dev/null || true
  if [[ "$CATALYST" == "1" && "${KG_IOS_CATALYST_KEEP_DERIVED_DATA:-0}" != "1" ]]; then
    rm -rf "$DERIVED_DATA_ROOT" 2>/dev/null ||
      echo "[ios_build] warning: catalyst cache cleanup failed root=$DERIVED_DATA_ROOT" >&2
  fi
}

echo "[ios_build] caller=$CALLER waiting for lock..."
LOCK_WAIT_START_MS="$(ios_build_now_ms)"
if ! kg_ios_wait_for_shlock "[ios_build]" build "$LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL"; then
  kg_ios_lock_timeout_die "[ios_build]" build "$DESTINATION" "$TIMEOUT"
fi
trap cleanup EXIT
LOCK_WAIT_MS=$(( $(ios_build_now_ms) - LOCK_WAIT_START_MS ))

# A Catalyst compile does not consume the simulator/device products.  Drop the
# sibling shared cache while the build lock is held; otherwise one gate retains a
# multi-GB iOS tree while the next gate allocates a second multi-GB Catalyst tree.
# ios_test.sh owns its own keyed cache and is unaffected by this cleanup.
if [[ "$CATALYST" == "1" ]]; then
  IOS_DERIVED_DATA_ROOT="$(kg_ios_shared_derived_data_root "$PROJECT_ROOT")"
  if [[ "$IOS_DERIVED_DATA_ROOT" != "$PROJECT_ROOT" && -d "$IOS_DERIVED_DATA_ROOT" ]]; then
    rm -rf "$IOS_DERIVED_DATA_ROOT" 2>/dev/null ||
      echo "[ios_build] warning: sibling iOS cache cleanup failed root=$IOS_DERIVED_DATA_ROOT" >&2
  fi
fi

preflight_rc=0
kg_ios_disk_budget_preflight "$PROJECT_ROOT" "build" || preflight_rc=$?
if (( preflight_rc != 0 )); then
  kg_ios_disk_budget_blocked_hint "[ios_build]" "$preflight_rc"
  # Same evidence as the early block: the in-lock re-read can also be 75/77.
  if (( preflight_rc == KG_IOS_DISK_STRUCTURAL_EXIT )); then
    write_early_failure_verdict "disk-guard-structural-block" "$preflight_rc"
  else
    write_early_failure_verdict "disk-budget-blocked" "$preflight_rc"
  fi
  exit "$preflight_rc"
fi

echo "[ios_build] lock acquired by $CALLER (pid=$$) lockWaitMs=$LOCK_WAIT_MS — building..."
echo "[ios_build] derivedDataRoot=$DERIVED_DATA_ROOT"
START=$(date +%s)
START_MS="$(ios_build_now_ms)"
BOOT_MS=0
XCODEBUILD_MS=0
TMPOUT="$(mktemp "${TMPDIR:-/tmp}/kg_ios_build.XXXXXX").log"
RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kg_ios_build_result.XXXXXX")"
RESULT_BUNDLE="$RESULT_DIR/Build.xcresult"

if destination_is_simulator; then
  SIMULATOR_BOOT_SELECTOR="$(destination_simulator_name)"
  if [[ -n "$SIMULATOR_BOOT_SELECTOR" ]]; then
    BOOT_START_MS="$(ios_build_now_ms)"
    echo "[ios_build] simulator ensure-booted — device=\"$SIMULATOR_BOOT_SELECTOR\" (up to ~30s if cold-starting from scratch)..."
    "$IOS_OPS" simulator ensure-booted --device "$SIMULATOR_BOOT_SELECTOR"
    BOOT_END_MS="$(ios_build_now_ms)"
    BOOT_MS=$(( BOOT_END_MS - BOOT_START_MS ))
  fi
fi

set +e
XCODEBUILD_START_MS="$(ios_build_now_ms)"
BUILD_START_S=$(date +%s)
# -quiet is intentionally omitted: without it xcodebuild emits one line per
# compiled file (SwiftCompile/CompileC), which the progress monitor counts to
# show %. All output still goes to $TMPOUT — stdout stays clean.
MONITOR_PID=$(start_build_monitor "$TMPOUT" "$BUILD_PROGRESS_BASELINE" "[ios_build]" "$BUILD_START_S")
# Consume the same argv `--dry-run` prints. Do not inline the flags here: a
# hand-written list is exactly what made the plan and the run divergible.
XCARGV=()
while IFS= read -r _argv_item; do XCARGV+=("$_argv_item"); done < <(xcodebuild_argv "$RESULT_BUNDLE")
xcodebuild "${XCARGV[@]}" >"$TMPOUT" 2>&1
EXIT_CODE=$?
kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=""
XCODEBUILD_END_MS="$(ios_build_now_ms)"
XCODEBUILD_MS=$(( XCODEBUILD_END_MS - XCODEBUILD_START_MS ))
COMPILE_EVENT_COUNT=$(count_compile_events "$TMPOUT")
set -e

ELAPSED=$(( $(date +%s) - START ))
END_MS="$(ios_build_now_ms)"
TOTAL_MS=$(( END_MS - START_MS ))
DIAGNOSTICS="$SCRIPT_DIR/ios_diagnostics.py"
if [[ -x "$DIAGNOSTICS" ]]; then
  diag_result="fail"; [[ $EXIT_CODE -eq 0 ]] && diag_result="pass"
  "$DIAGNOSTICS" --xcresult "$RESULT_BUNDLE" --log "$TMPOUT" --result "$diag_result" --limit 40 || true
else
  echo "[ios_build] diagnostics unavailable: $DIAGNOSTICS" >&2
fi

if [[ $EXIT_CODE -eq 0 ]]; then
  if ! kg_ios_write_install_provenance "$PROJECT_ROOT" "$DERIVED_DATA_ROOT" "$CONFIGURATION" "$DESTINATION"; then
    EXIT_CODE=1
  fi
fi

# Machine-readable verdict file — survives even when stdout/stderr is piped
# (e.g. `ios_build.sh | tail`, where the pipeline's exit code is tail's 0, not
# the build's). Read this instead of trusting a piped `$?`.
#
# Per-invocation UNIQUE path (multi-session race guard): VERDICT_FILE is
# `kg_ios_build_verdict.<epochTs>-<pid>` (or KG_IOS_VERDICT_FILE when a wrapper
# pins it); the historical fixed path stays as a last-writer-wins LATEST
# pointer for `ios_ops runs`. See ops/lib/ios_run_verdict.sh.
write_json_verdict() {
  local result="$1" exit_code="$2"
  jq -nc \
    --arg schema "kg.ios.run-verdict.v1" \
    --arg kind "build" \
    --arg result "$result" \
    --arg exit "$exit_code" \
    --arg caller "$CALLER" \
    --arg cwd "$PROJECT_ROOT" \
    --arg verdictFile "$VERDICT_FILE" \
    --argjson ts "$(date +%s)" \
    --argjson pid "$$" \
    --arg elapsed "${ELAPSED}s" \
    --arg log "$TMPOUT" \
    --arg xcresult "$RESULT_BUNDLE" \
    --argjson lockWaitMs "$LOCK_WAIT_MS" \
    --argjson bootMs "$BOOT_MS" \
    --argjson xcodebuildMs "$XCODEBUILD_MS" \
    --argjson totalMs "$TOTAL_MS" \
    '{
      schema:$schema,
      kind:$kind,
      status:$result,
      result:$result,
      exit:$exit,
      reason:null,
      caller:$caller,
      invocation:{ts:$ts,pid:$pid,cwd:$cwd,verdictFile:$verdictFile},
      elapsed:$elapsed,
      executed:null,
      timings:{
        lockWaitMs:$lockWaitMs,
        bootMs:$bootMs,
        xcodebuildMs:$xcodebuildMs,
        totalMs:$totalMs
      },
      artifacts:{log:$log,xcresult:$xcresult}
    }' >"$VERDICT_JSON_FILE" || true
  type append_run_metric >/dev/null 2>&1 && append_run_metric "$VERDICT_JSON_FILE"
  kg_ios_verdict_publish
}
if [[ $EXIT_CODE -eq 0 ]]; then
  # Persist compile-event count as the baseline for future % estimates.
  # Written only on success so a failed partial build never poisons the baseline.
  if [[ "$COMPILE_EVENT_COUNT" -gt 0 ]]; then
    mkdir -p "$DERIVED_DATA_ROOT"
    echo "$COMPILE_EVENT_COUNT" > "$BUILD_PROGRESS_BASELINE"
  fi
  echo "RESULT=ok EXIT=0 caller=$CALLER elapsed=${ELAPSED}s log=$TMPOUT xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  write_json_verdict "ok" "0"
  echo "[ios_build] timings lockWaitMs=$LOCK_WAIT_MS bootMs=$BOOT_MS xcodebuildMs=$XCODEBUILD_MS totalMs=$TOTAL_MS"
  echo "[ios_build] ✓ build succeeded (${ELAPSED}s, ${COMPILE_EVENT_COUNT} compile events) — $CALLER  log=$TMPOUT  xcresult=$RESULT_BUNDLE  verdict=$VERDICT_FILE"
else
  echo "RESULT=fail EXIT=$EXIT_CODE caller=$CALLER elapsed=${ELAPSED}s log=$TMPOUT xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  write_json_verdict "fail" "$EXIT_CODE"
  echo "[ios_build] timings lockWaitMs=$LOCK_WAIT_MS bootMs=$BOOT_MS xcodebuildMs=$XCODEBUILD_MS totalMs=$TOTAL_MS"
  echo "[ios_build] ✗ build failed (exit $EXIT_CODE, ${ELAPSED}s) — $CALLER  log=$TMPOUT  xcresult=$RESULT_BUNDLE  verdict=$VERDICT_FILE" >&2
fi

exit $EXIT_CODE
