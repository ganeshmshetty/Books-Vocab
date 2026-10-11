#!/usr/bin/env bash
# Contract tests for the bounded iOS development disk budget.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/ops/lib/ios_disk_budget.sh"
TMP="$(mktemp -d -t kg_ios_disk_budget_test_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export KG_IOS_DISK_GUARD_STATE="$TMP/guard-state.json"

PASS=0
FAIL=0
SKIP=0
ok() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  - SKIP: $*"; SKIP=$((SKIP + 1)); }

[[ -f "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }

cache_root="$TMP/cache"
mkdir -p "$cache_root/ios-build-derived-data" "$cache_root/ios-test-derived-data"
mkdir -p "$cache_root/ios/build"

echo "── under budget and free-space floor ──"
if KG_IOS_DISK_CACHE_ROOTS="$cache_root/ios-build-derived-data:$cache_root/ios-test-derived-data:$cache_root/ios/build" \
  KG_IOS_DISK_CACHE_BUDGET_GIB=1 KG_IOS_DISK_CACHE_HEADROOM_GIB=0 \
  KG_IOS_DISK_MIN_FREE_GIB=20 KG_IOS_DISK_FREE_BYTES=$((40 * 1073741824)) \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" \
  >/dev/null 2>&1; then
  ok "under-budget preflight passes"
else
  bad "under-budget preflight unexpectedly failed"
fi

echo "── over budget blocks before a writer starts ──"
dd if=/dev/zero of="$cache_root/ios-build-derived-data/payload" bs=1m count=2 >/dev/null 2>&1
over_output=""
over_rc=0
over_output="$(KG_IOS_DISK_CACHE_ROOTS="$cache_root/ios-build-derived-data:$cache_root/ios-test-derived-data:$cache_root/ios/build" \
  KG_IOS_DISK_CACHE_BUDGET_GIB=0 KG_IOS_DISK_CACHE_HEADROOM_GIB=0 \
  KG_IOS_DISK_MIN_FREE_GIB=20 KG_IOS_DISK_FREE_BYTES=$((40 * 1073741824)) \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" 2>&1)" || over_rc=$?
[[ "$over_rc" -eq 75 ]] && ok "over-budget exits 75" || bad "over-budget exit=$over_rc"
grep -q 'reason=cache-budget-exceeded' <<<"$over_output" \
  && ok "over-budget reason is structured" \
  || bad "over-budget reason missing: $over_output"

echo "── low free space blocks even with a small cache ──"
low_rc=0
KG_IOS_DISK_CACHE_ROOTS="$cache_root/ios-build-derived-data:$cache_root/ios-test-derived-data:$cache_root/ios/build" \
  KG_IOS_DISK_CACHE_BUDGET_GIB=1 KG_IOS_DISK_CACHE_HEADROOM_GIB=0 \
  KG_IOS_DISK_MIN_FREE_GIB=20 KG_IOS_DISK_FREE_BYTES=$((19 * 1073741824)) \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" \
  >/dev/null 2>&1 || low_rc=$?
[[ "$low_rc" -eq 75 ]] && ok "low free space exits 75" || bad "low free-space exit=$low_rc"

echo "── unknown free-space observation fails closed ──"
unknown_rc=0
KG_IOS_DISK_CACHE_ROOTS="$cache_root/ios-build-derived-data:$cache_root/ios-test-derived-data:$cache_root/ios/build" \
  KG_IOS_DISK_CACHE_BUDGET_GIB=1 KG_IOS_DISK_CACHE_HEADROOM_GIB=0 \
  KG_IOS_DISK_MIN_FREE_GIB=20 KG_IOS_DISK_FREE_BYTES=unknown \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" \
  >/dev/null 2>&1 || unknown_rc=$?
[[ "$unknown_rc" -eq 75 ]] && ok "unknown free-space exits 75" || bad "unknown free-space exit=$unknown_rc"

echo "── disk guard shared XCTestDevices block stops a new writer ──"
guard_state="$TMP/guard-xctest-block.json"
cat > "$guard_state" <<'EOF'
{"schema":"kg.disk.guard.v1","verdict":"block","xctest_devices_verdict":"block","xctest_devices_reclaim_status":"not-requested","xctest_devices_manual_review":1,"at":"2099-01-01T00:00:00Z"}
EOF
guard_output=""
guard_rc=0
guard_output="$(KG_IOS_DISK_CACHE_ROOTS="$cache_root/ios-build-derived-data:$cache_root/ios-test-derived-data:$cache_root/ios/build" \
  KG_IOS_DISK_GUARD_STATE="$guard_state" KG_IOS_DISK_GUARD_ENFORCE_XCTEST=1 \
  KG_IOS_DISK_CACHE_BUDGET_GIB=1 KG_IOS_DISK_CACHE_HEADROOM_GIB=0 \
  KG_IOS_DISK_MIN_FREE_GIB=20 KG_IOS_DISK_FREE_BYTES=$((40 * 1073741824)) \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" 2>&1)" || guard_rc=$?
[[ "$guard_rc" -eq 77 ]] && ok "XCTestDevices manual-review block exits 77 (not retryable)" || bad "shared XCTestDevices block exit=$guard_rc"
grep -q 'reason=xctest-devices-manual-review-required' <<<"$guard_output" \
  && ok "shared XCTestDevices blocker is structured" \
  || bad "shared XCTestDevices blocker missing: $guard_output"

echo "── stale disk guard state fails closed when enforcement is enabled ──"
stale_state="$TMP/guard-stale.json"
cat > "$stale_state" <<'EOF'
{"schema":"kg.disk.guard.v1","verdict":"ok","xctest_devices_verdict":"pass","at":"2000-01-01T00:00:00Z"}
EOF
stale_rc=0
stale_output="$(KG_IOS_DISK_CACHE_ROOTS="$cache_root/ios-build-derived-data:$cache_root/ios-test-derived-data:$cache_root/ios/build" \
  KG_IOS_DISK_GUARD_STATE="$stale_state" KG_IOS_DISK_GUARD_ENFORCE_XCTEST=1 \
  KG_IOS_DISK_GUARD_MAX_AGE_SECONDS=900 KG_IOS_DISK_CACHE_BUDGET_GIB=1 \
  KG_IOS_DISK_CACHE_HEADROOM_GIB=0 KG_IOS_DISK_MIN_FREE_GIB=20 \
  KG_IOS_DISK_FREE_BYTES=$((40 * 1073741824)) \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" 2>&1)" || stale_rc=$?
[[ "$stale_rc" -eq 75 ]] && ok "stale disk guard state exits 75" || bad "stale disk guard state exit=$stale_rc"
grep -q 'reason=disk-guard-state-stale' <<<"$stale_output" \
  && ok "stale disk guard reason is structured" \
  || bad "stale disk guard reason missing: $stale_output"

echo "── fresh healthy disk guard state permits a writer ──"
fresh_state="$TMP/guard-fresh.json"
cat > "$fresh_state" <<EOF
{"schema":"kg.disk.guard.v1","verdict":"ok","xctest_devices_verdict":"pass","at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}
EOF
fresh_rc=0
fresh_output="$(KG_IOS_DISK_CACHE_ROOTS="$cache_root/ios-build-derived-data:$cache_root/ios-test-derived-data:$cache_root/ios/build" \
  KG_IOS_DISK_GUARD_STATE="$fresh_state" KG_IOS_DISK_GUARD_ENFORCE_XCTEST=1 \
  KG_IOS_DISK_GUARD_MAX_AGE_SECONDS=900 KG_IOS_DISK_CACHE_BUDGET_GIB=1 \
  KG_IOS_DISK_CACHE_HEADROOM_GIB=0 KG_IOS_DISK_MIN_FREE_GIB=20 \
  KG_IOS_DISK_FREE_BYTES=$((40 * 1073741824)) \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" 2>&1)" || fresh_rc=$?
[[ "$fresh_rc" -eq 0 ]] && ok "fresh disk guard state permits writer" || bad "fresh disk guard state exit=$fresh_rc"
grep -q 'verdict=pass' <<<"$fresh_output" \
  && ok "fresh disk guard state is accepted" \
  || bad "fresh disk guard state rejected: $fresh_output"

echo "── lane-attribution block names the worktrees and reasons ──"
lane_state="$TMP/lane-block-usage.json"
cat > "$lane_state" <<'EOF'
{
  "policy": {
    "blocking_reasons": [
      "dirty-physical-worktree"
    ],
    "blocking_dirty_physical_worktrees": [
      "/x/dirty-terminal"
    ],
    "unknown_physical_worktrees": [],
    "unregistered_physical_worktrees": [
      "/x/orphan-one",
      "/x/orphan-two"
    ],
    "physical_identity_mismatches": [
      "/x/detached-lane"
    ],
    "physical_identity_repairs": [
      "git -C /x/detached-lane switch debug/lane"
    ]
  }
}
EOF
lane_block_state="$TMP/lane-block-guard.json"
cat > "$lane_block_state" <<EOF
{"schema":"kg.disk.guard.v1","verdict":"block","reason":"lane-usage-report-blocked","action":"manual-review-lane-attribution","lane_usage_verdict":"block","xctest_devices_verdict":"pass","at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}
EOF
lane_rc=0
lane_output="$(KG_IOS_DISK_GUARD_STATE="$lane_block_state" KG_IOS_DISK_LANE_USAGE_STATE="$lane_state" \
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state test" 2>&1)" || lane_rc=$?
[[ "$lane_rc" -eq 77 ]] && ok "lane block exits 77 (structural)" || bad "lane block exit=$lane_rc"
grep -q 'blockingReasons=dirty-physical-worktree' <<<"$lane_output" \
  && ok "diagnostic names blocking reason" || bad "diagnostic reason missing: $lane_output"
grep -q 'unregisteredWorktrees=/x/orphan-one;/x/orphan-two' <<<"$lane_output" \
  && ok "diagnostic names unregistered worktree paths" || bad "diagnostic paths missing: $lane_output"
grep -q 'identityMismatchWorktrees=/x/detached-lane' <<<"$lane_output" \
  && ok "diagnostic names identity-mismatch worktree" || bad "diagnostic identity mismatch missing: $lane_output"
grep -q 'identityRepairs="git -C /x/detached-lane switch debug/lane"' <<<"$lane_output" \
  && ok "diagnostic names the exact repair command" || bad "diagnostic repair missing: $lane_output"
grep -q 'guardReason=lane-usage-report-blocked' <<<"$lane_output" \
  && ok "diagnostic names guard reason" || bad "diagnostic guardReason missing: $lane_output"
grep -q 'guard --refresh' <<<"$lane_output" \
  && ok "diagnostic points at the refresh command" || bad "diagnostic refresh hint missing: $lane_output"

echo "── inline refresh clears a stale lane block ──"
fake_tick="$TMP/fake_tick.sh"
cat > "$fake_tick" <<'EOF'
#!/usr/bin/env bash
printf '{"schema":"kg.disk.guard.v1","verdict":"ok","xctest_devices_verdict":"pass","at":"%s"}\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$KG_DISK_GUARD_STATE"
echo "$KG_DISK_GUARD_BUILD_LOCK_HELD" > "$KG_DISK_GUARD_STATE.lockheld"
EOF
chmod +x "$fake_tick"
fake_tick_ok="$TMP/fake_tick_ok.sh"
cp "$fake_tick" "$fake_tick_ok"
cp "$lane_block_state" "$TMP/lane-refresh-guard.json"
refresh_rc=0
refresh_output="$(KG_IOS_DISK_GUARD_STATE="$TMP/lane-refresh-guard.json" KG_IOS_DISK_GUARD_TICK="$fake_tick" \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state test 1" 2>&1)" || refresh_rc=$?
[[ "$refresh_rc" -eq 0 ]] && ok "stale lane block is cleared by inline refresh" || bad "inline refresh exit=$refresh_rc: $refresh_output"
[[ "$(cat "$TMP/lane-refresh-guard.json.lockheld" 2>/dev/null)" == "1" ]] \
  && ok "in-lock inline refresh tells the tick the build lock is held" || bad "inline refresh lock flag wrong"

echo "── lock-free (early) refresh never claims the build lock ──"
rm -f "$TMP/lane-refresh-guard.json.lockheld"
cp "$lane_block_state" "$TMP/lane-refresh-guard.json"
nolock_rc=0
KG_IOS_DISK_GUARD_STATE="$TMP/lane-refresh-guard.json" KG_IOS_DISK_GUARD_TICK="$fake_tick_ok" \
  /bin/bash -c "source '$LIB'; kg_ios_disk_guard_early_verdict test" >/dev/null 2>&1 || nolock_rc=$?
[[ "$nolock_rc" -eq 0 ]] && ok "early verdict still clears a stale lane block" || bad "early verdict exit=$nolock_rc"
[[ "$(cat "$TMP/lane-refresh-guard.json.lockheld" 2>/dev/null)" == "0" ]] \
  && ok "early refresh runs the tick with BUILD_LOCK_HELD=0" || bad "early refresh lock flag: $(cat "$TMP/lane-refresh-guard.json.lockheld" 2>/dev/null || echo none)"

echo "── refresh that still blocks keeps exit 77 with diagnostics ──"
cat > "$fake_tick" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cp "$lane_block_state" "$TMP/lane-still-guard.json"
still_rc=0
still_output="$(KG_IOS_DISK_GUARD_STATE="$TMP/lane-still-guard.json" KG_IOS_DISK_GUARD_TICK="$fake_tick" \
  KG_IOS_DISK_LANE_USAGE_STATE="$lane_state" \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state test" 2>&1)" || still_rc=$?
[[ "$still_rc" -eq 77 ]] && ok "unresolved block still exits 77 after one refresh" || bad "still-block exit=$still_rc"
grep -q 'unregisteredWorktrees=/x/orphan-one' <<<"$still_output" \
  && ok "unresolved block still names worktrees" || bad "still-block diagnostics missing: $still_output"

echo "── refresh from a linked worktree runs the canonical checkout's tick ──"
# The host-global guard state has one writer identity (the canonical tick, as
# the launchd job runs it).  A lane's own copy must never publish into it.
canon="$TMP/refresh-canonical"; refresh_lane="$TMP/refresh-canonical-lane"; refresh_record="$TMP/refresh-record"
mkdir -p "$canon/ops/lib"
cp "$LIB" "$canon/ops/lib/ios_disk_budget.sh"
cat > "$canon/ops/kg_disk_guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'tick=canonical workspace=%s\n' "${KG_DISK_GUARD_WORKSPACE:-}" > "$KG_TEST_REFRESH_RECORD"
EOF
chmod +x "$canon/ops/kg_disk_guard.sh"
git -C "$canon" init -b main >/dev/null 2>&1
git -C "$canon" config user.email disk-test@example.com
git -C "$canon" config user.name "Disk Test"
git -C "$canon" add ops >/dev/null 2>&1
git -C "$canon" commit -m initial >/dev/null 2>&1
git -C "$canon" worktree add -b refresh-lane "$refresh_lane" HEAD >/dev/null 2>&1
cat > "$refresh_lane/ops/kg_disk_guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'tick=lane workspace=%s\n' "${KG_DISK_GUARD_WORKSPACE:-}" > "$KG_TEST_REFRESH_RECORD"
EOF
canon_real="$(cd "$canon" && pwd -P)"
refresh_rc=0
(
  unset KG_DISK_GUARD_WORKSPACE KG_IOS_DISK_GUARD_TICK
  KG_TEST_REFRESH_RECORD="$refresh_record" \
    /bin/bash -c "source '$refresh_lane/ops/lib/ios_disk_budget.sh'; kg_ios_disk_guard_refresh '$TMP/refresh-canonical-state.json' 0"
) || refresh_rc=$?
recorded="$(cat "$refresh_record" 2>/dev/null || true)"
[[ "$refresh_rc" -eq 0 ]] && ok "lane refresh succeeds" || bad "lane refresh exit=$refresh_rc"
[[ "$recorded" == tick=canonical* ]] \
  && ok "lane refresh runs the canonical tick, not the lane copy" || bad "lane refresh ran: ${recorded:-nothing}"
[[ "$(cd "${recorded##*workspace=}" 2>/dev/null && pwd -P)" == "$canon_real" ]] \
  && ok "lane refresh roots the tick at the canonical checkout" || bad "lane refresh workspace: ${recorded:-nothing}"

echo "── refresh without a resolvable canonical checkout fails closed ──"
loose="$TMP/refresh-no-git"; loose_record="$TMP/refresh-no-git-record"
mkdir -p "$loose/ops/lib"
cp "$LIB" "$loose/ops/lib/ios_disk_budget.sh"
cat > "$loose/ops/kg_disk_guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ran\n' > "$KG_TEST_REFRESH_RECORD"
EOF
chmod +x "$loose/ops/kg_disk_guard.sh"
loose_rc=0
(
  unset KG_DISK_GUARD_WORKSPACE KG_IOS_DISK_GUARD_TICK
  GIT_CEILING_DIRECTORIES="$TMP" KG_TEST_REFRESH_RECORD="$loose_record" \
    /bin/bash -c "source '$loose/ops/lib/ios_disk_budget.sh'; kg_ios_disk_guard_refresh '$TMP/refresh-no-git-state.json' 0"
) || loose_rc=$?
[[ "$loose_rc" -ne 0 ]] && ok "unresolvable canonical refresh fails" || bad "unresolvable canonical refresh exited 0"
[[ ! -e "$loose_record" ]] \
  && ok "no tick publishes from a script-relative fallback root" || bad "a tick ran without a canonical root"

echo "── structural guard block is a distinct non-retryable exit 77 ──"
struct_rc=0
struct_output="$(KG_IOS_DISK_GUARD_STATE="$lane_block_state" KG_IOS_DISK_LANE_USAGE_STATE="$lane_state" \
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state test" 2>&1)" || struct_rc=$?
[[ "$struct_rc" -eq 77 ]] && ok "a dirty-worktree attribution block exits 77" || bad "structural block exit=$struct_rc"
grep -q 'retryable=no' <<<"$struct_output" \
  && ok "structural block says retryable=no" || bad "retryable=no missing: $struct_output"
grep -q 'guardAction=manual-review-lane-attribution' <<<"$struct_output" \
  && ok "structural block prints the guard's own action" || bad "guard action missing: $struct_output"

xctest_budget_state="$TMP/guard-xctest-budget.json"
cat > "$xctest_budget_state" <<'EOF2'
{"schema":"kg.disk.guard.v1","verdict":"block","xctest_devices_verdict":"block","xctest_devices_manual_review":0,"at":"2099-01-01T00:00:00Z"}
EOF2
xctest_rc=0
KG_IOS_DISK_GUARD_STATE="$xctest_budget_state" KG_IOS_DISK_GUARD_ENFORCE_XCTEST=1 \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state test" >/dev/null 2>&1 || xctest_rc=$?
[[ "$xctest_rc" -eq 75 ]] && ok "XCTestDevices budget block keeps 75" || bad "xctest block exit=$xctest_rc"

xctest_slow_state="$TMP/guard-xctest-slow.json"
cat > "$xctest_slow_state" <<'EOF2'
{"schema":"kg.disk.guard.v1","verdict":"block","reason":"xctest-devices-measurement-incomplete","action":"retry-next-tick","xctest_devices_verdict":"block","xctest_devices_manual_review":0,"at":"2099-01-01T00:00:00Z"}
EOF2
xctest_slow_rc=0
xctest_slow_out="$(KG_IOS_DISK_GUARD_STATE="$xctest_slow_state" KG_IOS_DISK_GUARD_ENFORCE_XCTEST=1 \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state test" 2>&1)" || xctest_slow_rc=$?
[[ "$xctest_slow_rc" -eq 75 ]] && ok "a time-limited XCTestDevices walk is temporary (75)" || bad "xctest slow-walk exit=$xctest_slow_rc: $xctest_slow_out"
grep -q 'reason=xctest-devices-measurement-incomplete' <<<"$xctest_slow_out" && grep -q 'retryable=yes' <<<"$xctest_slow_out" \
  && ok "a time-limited walk is named as such and retryable" || bad "slow-walk message: $xctest_slow_out"
grep -q 'budget-exceeded' <<<"$xctest_slow_out" && bad "a time-limited walk is reported as a budget overrun" || ok "a time-limited walk is not reported as a budget overrun"

echo "── issue #2905: a time-limited walk inside a 75-exit lane report keeps its reason ──"
# The lane report exits 75 for any block, so the guard reason reads
# lane-usage-report-blocked.  The in-lock preflight must still name the walk.
xctest_timed_state="$TMP/guard-xctest-timed.json"
cat > "$xctest_timed_state" <<'EOF2'
{"schema":"kg.disk.guard.v1","verdict":"block","reason":"lane-usage-report-blocked","action":"manual-review-lane-attribution","lane_usage_verdict":"block","lane_usage_rc":75,"xctest_devices_verdict":"block","xctest_devices_manual_review":0,"xctest_devices_time_limited":1,"at":"2099-01-01T00:00:00Z"}
EOF2
xctest_timed_rc=0
xctest_timed_out="$(KG_IOS_DISK_GUARD_STATE="$xctest_timed_state" KG_IOS_DISK_GUARD_ENFORCE_XCTEST=1 \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state build 1" 2>&1)" || xctest_timed_rc=$?
[[ "$xctest_timed_rc" -eq 75 ]] && ok "a time-limited walk in a 75-exit report stays temporary (75)" || bad "timed walk exit=$xctest_timed_rc: $xctest_timed_out"
grep -q 'reason=xctest-devices-measurement-incomplete' <<<"$xctest_timed_out" && grep -q 'retryable=yes' <<<"$xctest_timed_out" \
  && ok "the in-lock preflight names the measurement-incomplete reason and says retryable=yes" || bad "in-lock preflight reason: $xctest_timed_out"
grep -q 'budget-exceeded' <<<"$xctest_timed_out" && bad "the in-lock preflight reports a time-limited walk as a budget overrun" || ok "the in-lock preflight does not report a budget overrun"

echo "── ios_ops.sh test reads the guard before the lease and the build lock ──"
early_lock="$TMP/early-build.lock"
early_leases="$TMP/early-leases"
early_verdict="$TMP/early-verdict"
early_start=$SECONDS
early_rc=0
early_output="$(KG_IOS_DISK_GUARD_STATE="$lane_block_state" KG_IOS_DISK_LANE_USAGE_STATE="$lane_state" \
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 KG_IOS_BUILD_LOCK_FILE="$early_lock" \
  KG_IOS_SIM_LEASE_ROOT="$early_leases" KG_IOS_VERDICT_FILE="$early_verdict" \
  "$ROOT/ops/ios_ops.sh" test --lease 2>&1)" || early_rc=$?
early_elapsed=$((SECONDS - early_start))
[[ "$early_rc" -eq 77 ]] && ok "ios_ops.sh test exits 77 on a structural block" || bad "ios_ops.sh test exit=$early_rc: $early_output"
(( early_elapsed <= 10 )) && ok "verdict arrives within 10s (${early_elapsed}s)" || bad "verdict took ${early_elapsed}s"
[[ ! -e "$early_leases" ]] && ok "no simulator lease was touched" || bad "lease root was created"
[[ -z "$(ls "$TMP" | grep '^early-build.lock')" ]] && ok "build lock was never taken" || bad "build lock artifacts exist"
grep -q 'unregisteredWorktrees=/x/orphan-one;/x/orphan-two' <<<"$early_output" \
  && ok "early verdict names the blocking worktrees" || bad "early verdict lacks worktrees: $early_output"
grep -q 'clean rebuildable cache' <<<"$early_output" \
  && bad "structural block still tells the agent to clean cache" || ok "no misleading clean-cache advice"

echo "── ios_ops.sh build reads the guard before queueing for the build lock ──"
build_rc=0
build_start=$SECONDS
build_output="$(KG_IOS_DISK_GUARD_STATE="$lane_block_state" KG_IOS_DISK_LANE_USAGE_STATE="$lane_state" \
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 KG_IOS_BUILD_LOCK_FILE="$early_lock" \
  "$ROOT/ops/ios_ops.sh" build 2>&1)" || build_rc=$?
[[ "$build_rc" -eq 77 ]] && ok "ios_ops.sh build exits 77 on a structural block" || bad "build exit=$build_rc: $build_output"
(( SECONDS - build_start <= 10 )) && ok "build verdict arrives within 10s" || bad "build verdict was slow"
[[ -z "$(ls "$TMP" | grep '^early-build.lock')" ]] && ok "build never took the lock" || bad "build lock artifacts exist"

echo "── disk-space style guard block keeps 75, also before lease and lock ──"
space_state="$TMP/guard-space-block.json"
cat > "$space_state" <<EOF
{"schema":"kg.disk.guard.v1","verdict":"critical","reason":"free-below-critical","action":"evict-old-ios-cache","lane_usage_verdict":"pass","xctest_devices_verdict":"pass","at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}
EOF
space_rc=0
space_output="$(KG_IOS_DISK_GUARD_STATE="$space_state" KG_IOS_DISK_GUARD_AUTO_REFRESH=0 \
  KG_IOS_BUILD_LOCK_FILE="$early_lock" KG_IOS_SIM_LEASE_ROOT="$early_leases" \
  KG_IOS_VERDICT_FILE="$early_verdict" "$ROOT/ops/ios_ops.sh" test --lease 2>&1)" || space_rc=$?
[[ "$space_rc" -eq 75 ]] && ok "disk-space guard block exits 75" || bad "space block exit=$space_rc: $space_output"
[[ ! -e "$early_leases" ]] && ok "space block also stops before the lease" || bad "lease root created on space block"

echo "── ios_ops.sh build --json: an early guard block is a verdict, not a missing run ──"
# The early return happens before the build writes its verdict; without one the
# wrapper reports result=missing/exit=null, indistinguishable from a run that
# never happened. The payload must carry the real exit and the guard reason.
early_build_json_case() {  # $1=label $2=guard state $3=expected exit $4=expected reason
  local label="$1" state="$2" want_rc="$3" want_reason="$4" payload rc=0
  payload="$(TMPDIR="$TMP" KG_IOS_DISK_GUARD_STATE="$state" KG_IOS_DISK_LANE_USAGE_STATE="$lane_state" \
    KG_IOS_DISK_GUARD_AUTO_REFRESH=0 KG_IOS_BUILD_LOCK_FILE="$early_lock" \
    "$ROOT/ops/ios_ops.sh" build --json 2>/dev/null)" || rc=$?
  [[ "$rc" -eq "$want_rc" ]] && ok "build --json $label: wrapper exits $want_rc" || bad "build --json $label exit=$rc"
  [[ "$(jq -r '.kind' <<<"$payload" 2>/dev/null)" == "build" \
    && "$(jq -r '.result' <<<"$payload" 2>/dev/null)" == "inconclusive" ]] \
    && ok "build --json $label: result=inconclusive, not missing" || bad "build --json $label payload: $payload"
  [[ "$(jq -r '.exit' <<<"$payload" 2>/dev/null)" == "$want_rc" ]] \
    && ok "build --json $label: payload carries exit $want_rc" || bad "build --json $label exit field: $payload"
  [[ "$(jq -r '.reason' <<<"$payload" 2>/dev/null)" == "$want_reason" ]] \
    && ok "build --json $label: payload carries reason $want_reason" || bad "build --json $label reason field: $payload"
}
early_build_json_case structural "$lane_block_state" 77 disk-guard-structural-block
early_build_json_case temporary "$space_state" 75 disk-guard-blocked

echo "── ios_ops.sh early path never tells the tick the build lock is held ──"
record_tick="$TMP/record_tick.sh"
cat > "$record_tick" <<'EOF'
#!/usr/bin/env bash
# Records the lock flag it was given; leaves the guard state untouched (still blocked).
echo "LOCKHELD=${KG_DISK_GUARD_BUILD_LOCK_HELD:-unset}" >> "$KG_TEST_TICK_RECORD"
EOF
chmod +x "$record_tick"
for early_cmd in "test --lease" "build"; do
  tick_record="$TMP/tick-record-${early_cmd%% *}"
  rm -f "$tick_record"
  cp "$lane_block_state" "$TMP/early-refresh-guard.json"
  tick_rc=0
  # shellcheck disable=SC2086
  KG_IOS_DISK_GUARD_STATE="$TMP/early-refresh-guard.json" KG_IOS_DISK_LANE_USAGE_STATE="$lane_state" \
    KG_IOS_DISK_GUARD_TICK="$record_tick" KG_TEST_TICK_RECORD="$tick_record" \
    KG_IOS_BUILD_LOCK_FILE="$early_lock" KG_IOS_SIM_LEASE_ROOT="$early_leases" \
    KG_IOS_VERDICT_FILE="$early_verdict" "$ROOT/ops/ios_ops.sh" $early_cmd >/dev/null 2>&1 || tick_rc=$?
  [[ "$tick_rc" -eq 77 ]] && ok "ios_ops.sh $early_cmd still exits 77 after the lock-free refresh" || bad "$early_cmd exit=$tick_rc"
  [[ "$(cat "$tick_record" 2>/dev/null)" == "LOCKHELD=0" ]] \
    && ok "ios_ops.sh $early_cmd refreshes with BUILD_LOCK_HELD=0" || bad "$early_cmd tick saw: $(cat "$tick_record" 2>/dev/null || echo no-tick)"
done

echo "── lane-usage-report-blocked: only structural blocking reasons exit 77 ──"
lane_guard_with_rc() {  # $1=lane_usage_rc (or empty to omit)
  local rc_field=""
  [[ -n "$1" ]] && rc_field="\"lane_usage_rc\":$1,"
  printf '{"schema":"kg.disk.guard.v1","verdict":"block","reason":"lane-usage-report-blocked","action":"manual-review-lane-attribution","lane_usage_verdict":"block",%s"xctest_devices_verdict":"pass","at":"%s"}\n' \
    "$rc_field" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
lane_usage_with_reasons() {  # $@=blocking reasons
  local first=1 r
  printf '{\n  "policy": {\n    "blocking_reasons": ['
  if (( $# > 0 )); then
    printf '\n'
    for r in "$@"; do
      (( first )) || printf ',\n'
      printf '      "%s"' "$r"; first=0
    done
    printf '\n    '
  fi
  printf '],\n    "unregistered_physical_worktrees": []\n  }\n}\n'
}
classify() {  # $1=label $2=expected rc $3=lane_usage_rc-or-empty, then reasons
  local label="$1" want="$2" lrc="$3" got=0 out
  shift 3
  lane_guard_with_rc "$lrc" > "$TMP/classify-guard.json"
  lane_usage_with_reasons "$@" > "$TMP/classify-usage.json"
  out="$(KG_IOS_DISK_GUARD_STATE="$TMP/classify-guard.json" KG_IOS_DISK_LANE_USAGE_STATE="$TMP/classify-usage.json" \
    KG_IOS_DISK_GUARD_AUTO_REFRESH=0 \
    /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state test" 2>&1)" || got=$?
  [[ "$got" -eq "$want" ]] && ok "$label exits $want" || bad "$label exit=$got (want $want): $out"
  if [[ "$want" == 77 ]]; then
    grep -q 'retryable=no' <<<"$out" && ok "$label says retryable=no" || bad "$label lacks retryable=no"
  else
    grep -q 'retryable=no' <<<"$out" && bad "$label wrongly says retryable=no" || ok "$label does not claim retryable=no"
  fi
}
classify "lane-total-budget-exceeded alone" 75 "" lane-total-budget-exceeded
classify "lane-budget-exceeded:<path> alone" 75 "" "lane-budget-exceeded:/x/lane"
classify "measurement-incomplete reasons" 75 "" workspace-measurement-incomplete lane-measurement-incomplete
classify "empty blocking_reasons" 75 ""
# #3001: a killed scan (rc 124) whose current report already names a structural
# blocker is a fact waiting cannot clear, so it is structural; a time-limit-only
# kill stays temporary.
classify "lane scan killed (rc=124) with a current structural reason is structural" 77 124 dirty-physical-worktree
classify "lane scan killed (rc=124) with only a measurement limit is temporary" 75 124 lane-measurement-incomplete
classify "lane scan killed (rc=124) with a quota reason only is temporary" 75 124 lane-total-budget-exceeded
classify "structural reason mixed with a quota reason" 77 75 lane-total-budget-exceeded dirty-physical-worktree
# Issue #2905: an unregistered worktree is a warning under budget, never a blocking reason.
classify "unregistered-physical-worktree is not structural (fresh report rc=75)" 75 75 unregistered-physical-worktree
classify "unknown-physical-worktree" 77 "" unknown-physical-worktree
classify "duplicate-physical-worktree" 77 "" duplicate-physical-worktree
classify "physical-identity-mismatch" 77 "" physical-identity-mismatch
classify "registry-records-invalid" 77 "" registry-records-invalid

echo "── #3001: over-quota unregistered checkout names its remedy, not cache cleanup ──"
# Cleaning the cache cannot clear an unregistered checkout over the lane quota,
# so the 75 epilogue must point at adopt/remove for that exact path.
unreg_usage="$TMP/unreg-usage.json"
unreg_guard="$TMP/unreg-guard.json"
cat > "$unreg_usage" <<'JSON'
{
  "policy": {
    "blocking_reasons": [
      "lane-budget-exceeded:/x/stray checkout"
    ],
    "unregistered_physical_worktrees": [
      "/x/stray checkout"
    ]
  }
}
JSON
lane_guard_with_rc 75 > "$unreg_guard"
unreg_script='source "$1"; rc=0; kg_ios_disk_budget_guard_state test || rc=$?; kg_ios_disk_budget_blocked_hint "[t]" "$rc"'
unreg_out="$(KG_IOS_DISK_GUARD_STATE="$unreg_guard" KG_IOS_DISK_LANE_USAGE_STATE="$unreg_usage" \
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 /bin/bash -c "$unreg_script" _ "$LIB" 2>&1)"
grep -q 'worktree remove' <<<"$unreg_out" && ok "over-quota unregistered 75 prints the remove remedy" || bad "over-quota unregistered 75 lacks the remedy: $unreg_out"
# The adopt remedy must be a runnable command: it carries every flag that
# `adopt --help` marks required (no brackets), here --intent, with a placeholder.
adopt_usage="$("$ROOT/ops/worktree_orchestrate.py" adopt --help 2>&1 | tr -s ' \n' '  ')"
adopt_required_intent=0
grep -q -- '\] --intent INTENT' <<<"$adopt_usage" && adopt_required_intent=1
(( adopt_required_intent )) && ok "adopt --help marks --intent as required" || bad "adopt --help no longer requires --intent: $adopt_usage"
grep -qF -- './ops/worktree_orchestrate.py adopt --worktree /x/stray\ checkout --intent <intent>' <<<"$unreg_out" \
  && ok "adopt remedy is a complete command with --worktree and --intent" \
  || bad "adopt remedy is not a complete runnable command: $unreg_out"
grep -q "/x/stray checkout" <<<"$unreg_out" && ok "remedy names the exact unregistered path" || bad "remedy does not name the path: $unreg_out"
grep -q 'clean rebuildable cache' <<<"$unreg_out" && bad "over-quota unregistered 75 still says only clean the cache" || ok "over-quota unregistered 75 does not say only clean the cache"
# Negative control: a warning-only unregistered path (no lane-budget-exceeded line
# of its own, and a prefix-sharing sibling path) is never named as over quota.
cat > "$unreg_usage" <<'JSON'
{
  "policy": {
    "blocking_reasons": [
      "lane-budget-exceeded:/x/stray"
    ],
    "unregistered_physical_worktrees": [
      "/x/stray checkout",
      "/x/stray"
    ]
  }
}
JSON
prefix_out="$(KG_IOS_DISK_GUARD_STATE="$unreg_guard" KG_IOS_DISK_LANE_USAGE_STATE="$unreg_usage" \
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 /bin/bash -c "$unreg_script" _ "$LIB" 2>&1)"
grep -q 'path="/x/stray checkout"' <<<"$prefix_out" && bad "warning-only unregistered path named as over quota" || ok "warning-only unregistered path is not named as over quota"
grep -q 'path="/x/stray"' <<<"$prefix_out" && ok "exact over-quota path is named" || bad "exact over-quota path not named: $prefix_out"
# A registered lane over its own quota is a cache-cleanable cause, so the same 75
# keeps the clean-cache advice and still names the unregistered remedy separately.
cat > "$unreg_usage" <<'JSON'
{
  "policy": {
    "blocking_reasons": [
      "lane-budget-exceeded:/x/stray checkout",
      "lane-budget-exceeded:/x/registered-lane"
    ],
    "unregistered_physical_worktrees": [
      "/x/stray checkout"
    ]
  }
}
JSON
mixed_out="$(KG_IOS_DISK_GUARD_STATE="$unreg_guard" KG_IOS_DISK_LANE_USAGE_STATE="$unreg_usage" \
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 /bin/bash -c "$unreg_script" _ "$LIB" 2>&1)"
grep -q 'clean rebuildable cache' <<<"$mixed_out" && ok "mixed 75 keeps the clean-cache advice" || bad "mixed 75 dropped the clean-cache advice: $mixed_out"
grep -q 'cache cleanup does not clear it' <<<"$mixed_out" && bad "mixed 75 wrongly says cache cleanup cannot clear it" || ok "mixed 75 does not claim cache cleanup is useless"
grep -qF -- './ops/worktree_orchestrate.py adopt --worktree /x/stray\ checkout --intent <intent>' <<<"$mixed_out" \
  && ok "mixed 75 still lists the unregistered adopt remedy" || bad "mixed 75 lost the unregistered remedy: $mixed_out"
# Over-quota matching is literal (#3001 CR P3): a bracket path must not be glob-expanded
# onto an existing sibling (a1 here), and a star-looking path must not match a longer one.
mkdir -p "$TMP/glob-quota" && : > "$TMP/glob-quota/a1"
glob_path="$TMP/glob-quota/a[1]"
glob_out="$(/bin/bash -c "source '$LIB'; kg_ios_disk_guard_unregistered_over_quota '$glob_path;/x/b*' 'lane-budget-exceeded:$glob_path;lane-budget-exceeded:/x/bee'" 2>&1)"
[[ "$glob_out" == "$glob_path" ]] \
  && ok "over-quota match is literal for bracket and star paths" \
  || bad "over-quota match is not literal: got '$glob_out'"

# Regression (#3001 CR P3): the diagnose reason loop word-split its list with an
# unquoted expansion, so a bracket path in a reason was pathname-expanded against the
# cwd. A cwd entry that the bracket pattern matches must not flip the over-quota verdict.
mkdir -p "$TMP/glob-cwd/lane-budget-exceeded:/x" && : > "$TMP/glob-cwd/lane-budget-exceeded:/x/over1"
glob_usage="$TMP/glob-usage.json"
cat > "$glob_usage" <<'JSON'
{
  "policy": {
    "blocking_reasons": [
      "lane-budget-exceeded:/x/over[1]"
    ],
    "unregistered_physical_worktrees": [
      "/x/over[1]"
    ]
  }
}
JSON
glob_out="$(cd "$TMP/glob-cwd" && KG_IOS_DISK_GUARD_STATE="$unreg_guard" KG_IOS_DISK_LANE_USAGE_STATE="$glob_usage" \
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 /bin/bash -c "$unreg_script" _ "$LIB" 2>&1)"
grep -q 'worktree remove' <<<"$glob_out" && ok "bracket over-quota reason keeps its remove remedy in a matching cwd" || bad "bracket over-quota reason lost its remedy: $glob_out"
grep -q 'clean rebuildable cache' <<<"$glob_out" && bad "bracket over-quota reason was pathname-expanded into cache advice" || ok "bracket over-quota reason is not pathname-expanded"

echo "── lane-usage-report-blocked: a stale report is never structural evidence ──"
# Regression (2026-10-08): the tick's supervisor killed the scan and recorded
# lane_usage_rc=75, which the consumer reads as "a complete report was written".
# It then trusted a report from 80 minutes earlier, named a worktree that no
# longer existed, and answered exit 77 retryable=no.  Only a report written by the
# tick that produced the state may decide a structural block.
set_mtime_ago() {  # $1=file $2=seconds
  local ts=$(( $(date +%s) - $2 ))
  touch -d "@$ts" "$1" 2>/dev/null || touch -t "$(date -r "$ts" '+%Y%m%d%H%M.%S')" "$1"
}
stale_case() {  # $1=label $2=expected rc $3=lane_usage_rc-or-empty $4=report age seconds, then reasons
  local label="$1" want="$2" lrc="$3" age="$4" got=0 out
  shift 4
  lane_guard_with_rc "$lrc" > "$TMP/stale-guard.json"
  if [[ "${1:-}" == "@named" ]]; then
    cp "$lane_state" "$TMP/stale-usage.json"  # lists /x/orphan-one;/x/orphan-two as unregistered
  else
    lane_usage_with_reasons "$@" > "$TMP/stale-usage.json"
  fi
  set_mtime_ago "$TMP/stale-usage.json" "$age"
  STALE_OUT="$(KG_IOS_DISK_GUARD_STATE="$TMP/stale-guard.json" KG_IOS_DISK_LANE_USAGE_STATE="$TMP/stale-usage.json" \
    KG_IOS_DISK_GUARD_AUTO_REFRESH=0 \
    /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state test; rc=\$?; kg_ios_disk_budget_blocked_hint '[t]' \$rc; exit \$rc" 2>&1)" || got=$?
  [[ "$got" -eq "$want" ]] && ok "$label exits $want" || bad "$label exit=$got (want $want): $STALE_OUT"
}
stale_case "report 80 minutes older than the tick that cites it (rc 75, structural reason)" 75 75 4800 @named
grep -q 'retryable=no' <<<"$STALE_OUT" && bad "stale report still claims retryable=no" || ok "stale report does not claim retryable=no"
grep -q 'laneUsageFresh=no' <<<"$STALE_OUT" && ok "stale report is named in the diagnostic" || bad "stale diagnostic missing: $STALE_OUT"
grep -q 'unregisteredWorktrees=/x' <<<"$STALE_OUT" && bad "stale report's worktree names are presented as current" || ok "stale report's worktree names are not presented as current"
grep -q 'guard --refresh' <<<"$STALE_OUT" && ok "stale report points at the refresh command" || bad "stale refresh hint missing: $STALE_OUT"
grep -q 'clean rebuildable cache' <<<"$STALE_OUT" && bad "stale report advises cleaning cache" || ok "stale report does not advise cleaning cache"
stale_case "stale report from an older producer that wrote no lane_usage_rc" 75 "" 4800 dirty-physical-worktree
grep -q 'laneUsageFresh=no' <<<"$STALE_OUT" && ok "stale report without rc is named in the diagnostic" || bad "stale diagnostic missing: $STALE_OUT"
stale_case "report a few seconds older than the tick (normal write order)" 77 75 20 @named
grep -q 'retryable=no' <<<"$STALE_OUT" && ok "a report from the same tick stays structural" || bad "fresh report lost retryable=no: $STALE_OUT"
grep -q 'unregisteredWorktrees=/x/orphan-one;/x/orphan-two' <<<"$STALE_OUT" && ok "positive control: a fresh report names its worktrees" || bad "fresh report lost its worktree names: $STALE_OUT"
stale_case "report just inside the slack window" 77 75 100 dirty-physical-worktree
stale_case "report just outside the slack window" 75 75 160 dirty-physical-worktree
# #3001: a kill is structural only with the same tick's current report; an old one is not.
stale_case "rc=124 kill with a report older than the tick stays temporary" 75 124 4800 dirty-physical-worktree
stale_case "rc=124 kill with a current structural report is structural" 77 124 20 dirty-physical-worktree
lane_guard_with_rc 75 > "$TMP/stale-guard.json"
missing_out="$(KG_IOS_DISK_GUARD_STATE="$TMP/stale-guard.json" KG_IOS_DISK_LANE_USAGE_STATE="$TMP/no-such-lane-report.json" \
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 /bin/bash -c "source '$LIB'; kg_ios_disk_budget_guard_state test" 2>&1)" && missing_rc=0 || missing_rc=$?
[[ "$missing_rc" -eq 75 ]] && ok "missing lane report is temporary, not structural" || bad "missing lane report exit=$missing_rc: $missing_out"

echo "── in-lock preflight skips the guard only for a fresh early verdict ──"
pf_env=(KG_IOS_DISK_CACHE_ROOTS="$cache_root/ios-build-derived-data" KG_IOS_DISK_CACHE_BUDGET_GIB=1
  KG_IOS_DISK_CACHE_HEADROOM_GIB=0 KG_IOS_DISK_MIN_FREE_GIB=20 KG_IOS_DISK_FREE_BYTES=$((40 * 1073741824))
  KG_IOS_DISK_GUARD_STATE="$lane_block_state" KG_IOS_DISK_LANE_USAGE_STATE="$lane_state" KG_IOS_DISK_GUARD_AUTO_REFRESH=0)
pf_rc=0
env "${pf_env[@]}" KG_IOS_DISK_GUARD_ALREADY_CHECKED=1 KG_IOS_DISK_GUARD_CHECKED_AT="$(date +%s)" \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" >/dev/null 2>&1 || pf_rc=$?
[[ "$pf_rc" -eq 0 ]] && ok "fresh early verdict: in-lock preflight measures disk space only" || bad "fresh-check preflight exit=$pf_rc"
pf_rc=0
env "${pf_env[@]}" KG_IOS_DISK_GUARD_ALREADY_CHECKED=1 \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" >/dev/null 2>&1 || pf_rc=$?
[[ "$pf_rc" -eq 77 ]] && ok "caller-preset ALREADY_CHECKED without a timestamp does not bypass the guard" || bad "preset bypass exit=$pf_rc"
pf_rc=0
env "${pf_env[@]}" KG_IOS_DISK_GUARD_ALREADY_CHECKED=1 KG_IOS_DISK_GUARD_CHECKED_AT=$(( $(date +%s) - 3600 )) \
  /bin/bash -c "source '$LIB'; kg_ios_disk_budget_preflight '$cache_root' build" >/dev/null 2>&1 || pf_rc=$?
[[ "$pf_rc" -eq 77 ]] && ok "early verdict older than the state max age is re-read in-lock" || bad "stale early verdict exit=$pf_rc"

echo "── in-lock guard re-read propagates the structural exit (ios_build.sh, real run) ──"
# The early verdict passes, then the state turns blocked while the script waits
# for the build lock; with MAX_AGE=1 the early verdict is stale by the time the
# lock is granted, so the in-lock preflight re-reads the guard.  The script's
# own exit code must be the preflight's (77 structural / 75 temporary), not a
# hardcoded 75 with "clean rebuildable cache" advice.
# The lock is macOS `shlock`, hard-wired in ops/lib/ios_lock_wait.sh, so this
# real run is macOS-only by design: hosts without it (Linux CI) skip explicitly
# instead of faking a lock the production path would not use.
INLOCK_RC=""
INLOCK_OUT=""
# Returns 1 (after recording a failure) when the lock holder cannot be staged,
# in which case INLOCK_RC/INLOCK_OUT must not be asserted on.
run_build_in_lock_case() {  # $1=label $2=state written during the lock wait
  local label="$1" late_state="$2" lock state out holder build_pid waited rc
  INLOCK_RC=""
  INLOCK_OUT=""
  lock="$TMP/inlock-$label.lock"
  state="$TMP/inlock-$label-state.json"
  out="$TMP/inlock-$label.out"
  printf '{"schema":"kg.disk.guard.v1","verdict":"ok","xctest_devices_verdict":"pass","at":"%s"}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$state"
  sleep 120 &
  holder=$!
  if ! shlock -f "$lock" -p "$holder"; then
    bad "$label: could not stage the lock holder (shlock -f $lock -p $holder failed)"
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    return 1
  fi
  INLOCK_VERDICT="$TMP/inlock-$label-verdict"
  TMPDIR="$TMP" KG_IOS_VERDICT_FILE="$INLOCK_VERDICT" \
    KG_IOS_BUILD_LOCK_FILE="$lock" KG_IOS_BUILD_DERIVED_DATA_ROOT="$TMP/inlock-$label-dd" \
    KG_IOS_DISK_GUARD_STATE="$state" KG_IOS_DISK_GUARD_MAX_AGE_SECONDS=1 KG_IOS_DISK_GUARD_AUTO_REFRESH=0 \
    KG_IOS_DISK_CACHE_ROOTS="$cache_root/ios-test-derived-data" KG_IOS_DISK_CACHE_BUDGET_GIB=1 \
    KG_IOS_DISK_CACHE_HEADROOM_GIB=0 KG_IOS_DISK_MIN_FREE_GIB=20 \
    KG_IOS_DISK_FREE_BYTES=$((40 * 1073741824)) \
    "$ROOT/ops/ios_build.sh" --timeout 60 >"$out" 2>&1 &
  build_pid=$!
  waited=0
  until grep -q 'waiting for lock' "$out" 2>/dev/null || (( waited >= 150 )); do sleep 0.2; waited=$((waited + 1)); done
  sleep 2
  printf '%s\n' "$late_state" > "$state"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  rc=0
  wait "$build_pid" || rc=$?
  INLOCK_RC="$rc"
  INLOCK_OUT="$(cat "$out")"
}
late_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if ! command -v shlock >/dev/null 2>&1; then
  skip "ios_build.sh in-lock real run (8 assertions): host has no macOS shlock, the only lock ops/lib/ios_lock_wait.sh implements"
else
  if run_build_in_lock_case structural \
    "{\"schema\":\"kg.disk.guard.v1\",\"verdict\":\"ok\",\"xctest_devices_verdict\":\"block\",\"xctest_devices_manual_review\":1,\"at\":\"$late_at\"}"; then
    [[ "$INLOCK_RC" -eq 77 ]] && ok "ios_build.sh: in-lock structural block exits 77" || bad "ios_build.sh in-lock structural exit=$INLOCK_RC: $INLOCK_OUT"
    grep -q 'retryable=no' <<<"$INLOCK_OUT" \
      && ok "ios_build.sh: in-lock structural block says retryable=no" \
      || bad "ios_build.sh in-lock structural block lacks retryable=no: $INLOCK_OUT"
    [[ "$(jq -r '[.result,.exit,.reason]|join(",")' "$INLOCK_VERDICT.json" 2>/dev/null)" == "inconclusive,77,disk-guard-structural-block" ]] \
      && ok "ios_build.sh: in-lock structural block writes an inconclusive verdict with exit 77" \
      || bad "ios_build.sh in-lock structural verdict: $(cat "$INLOCK_VERDICT.json" 2>/dev/null || echo none)"
    ! grep -q 'clean rebuildable cache before retry' <<<"$INLOCK_OUT" \
      && ok "ios_build.sh: structural block does not advise cleaning cache" \
      || bad "ios_build.sh structural block still advises cleaning cache: $INLOCK_OUT"
  fi
  if run_build_in_lock_case temporary \
    "{\"schema\":\"kg.disk.guard.v1\",\"verdict\":\"ok\",\"xctest_devices_verdict\":\"block\",\"xctest_devices_manual_review\":0,\"at\":\"$late_at\"}"; then
    [[ "$INLOCK_RC" -eq 75 ]] && ok "ios_build.sh: in-lock temporary block still exits 75" || bad "ios_build.sh in-lock temporary exit=$INLOCK_RC: $INLOCK_OUT"
    grep -q 'clean rebuildable cache before retry' <<<"$INLOCK_OUT" \
      && ok "ios_build.sh: temporary block keeps the clean-cache hint" \
      || bad "ios_build.sh temporary block lost the clean-cache hint: $INLOCK_OUT"
    [[ "$(jq -r '[.result,.exit]|join(",")' "$INLOCK_VERDICT.json" 2>/dev/null)" == "inconclusive,75" ]] \
      && ok "ios_build.sh: in-lock temporary block writes an inconclusive verdict with exit 75" \
      || bad "ios_build.sh in-lock temporary verdict: $(cat "$INLOCK_VERDICT.json" 2>/dev/null || echo none)"
  fi
fi

echo "── in-lock preflight rc propagation: ios_test.sh rebuild_test_cache / ios_release.sh ──"
fn_runner="$TMP/test-fn-runner.sh"
build_fn="$(awk '/^rebuild_test_cache\(\) \{/ { c=1 } /^ensure_xctestrun_ready_or_fail\(\) \{/ { exit } c { print }' "$ROOT/ops/ios_test.sh")"
[[ -n "$build_fn" ]] || bad "cannot extract rebuild_test_cache from ios_test.sh"
run_test_fn_case() {  # $1=stub preflight rc
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' "source '$LIB'"
    printf '%s\n' "DERIVED_DATA_ROOT='$TMP/fn-dd'" "TEST_CACHE_ROOT='$TMP/fn-cache/ios-test'" \
      'REBUILD_DID_BUILD=0' 'acquire_build_lock() { :; }' 'kg_ios_cache_evict() { :; }' \
      'ios_test_find_xctestrun() { return 1; }' 'ios_test_cache_is_complete() { return 1; }' \
      'ios_test_cached_products_ready() { return 1; }' \
      'release_build_lock() { echo LOCK_RELEASED; }' \
      "kg_ios_disk_budget_preflight() { return $1; }"
    printf '%s\n' "$build_fn"
    printf '%s\n' 'rc=0; rebuild_test_cache x y || rc=$?' 'echo "FN_RC=$rc"'
  } > "$fn_runner"
  FN_OUT="$(/bin/bash "$fn_runner" 2>&1)"
}
run_test_fn_case 77
grep -q '^FN_RC=77$' <<<"$FN_OUT" && ok "ios_test.sh: in-lock structural preflight returns 77" || bad "ios_test.sh in-lock structural: $FN_OUT"
grep -q 'LOCK_RELEASED' <<<"$FN_OUT" && ok "ios_test.sh: structural block releases the build lock" || bad "ios_test.sh structural block kept the lock: $FN_OUT"
! grep -q 'clean rebuildable cache before retry' <<<"$FN_OUT" \
  && ok "ios_test.sh: structural block does not advise cleaning cache" \
  || bad "ios_test.sh structural block still advises cleaning cache: $FN_OUT"
run_test_fn_case 75
grep -q '^FN_RC=75$' <<<"$FN_OUT" && ok "ios_test.sh: in-lock temporary preflight returns 75" || bad "ios_test.sh in-lock temporary: $FN_OUT"
grep -q 'clean rebuildable cache before retry' <<<"$FN_OUT" \
  && ok "ios_test.sh: temporary block keeps the clean-cache hint" \
  || bad "ios_test.sh temporary block lost the hint: $FN_OUT"

echo "── --prepare-cache propagates the in-lock structural/temporary exit ──"
# handle_cache_action captures rebuild_test_cache's rc as build_exit, but used to
# exit 1 for every error payload, flattening a non-retryable 77 into a plain
# tool error. Real print_cache_payload + handle_cache_action are extracted; only
# the environment-touching helpers are stubbed.
extract_ios_test_fn() {  # $1=function name; prints it up to the closing brace at column 0
  awk -v fn="$1" '$0 == fn "() {" { c=1 } c { print } c && /^}$/ { exit }' "$ROOT/ops/ios_test.sh"
}
cache_fn="$(extract_ios_test_fn print_cache_payload; extract_ios_test_fn ios_test_prepare_status; extract_ios_test_fn handle_cache_action)"
[[ -n "$cache_fn" ]] || bad "cannot extract print_cache_payload/handle_cache_action from ios_test.sh"
run_prepare_cache_case() {  # $1=stub rebuild_test_cache rc
  local runner="$TMP/prepare-cache-runner.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "source '$LIB'"
    printf '%s\n' 'JSON_MODE=1' 'BOOT_MS=0' 'BUILD_FOR_TESTING_MS=0' 'CONFIGURATION=Debug' \
      'TEST_SCOPE=unit' 'TEST_SCHEME=BooksAndVocab' 'UI_LAUNCH_PROFILE=' 'DESTINATION=stub' \
      "TEST_CACHE_ROOT='$TMP/pc-cache'" "IOS_ARTIFACT_ROOT='$TMP/pc-artifacts'" \
      'ios_test_build_cache_key() { echo stub-key; }' \
      "ios_test_derived_data_root() { echo '$TMP/pc-dd'; }" \
      'ios_test_find_xctestrun() { return 1; }' 'ios_test_cache_is_complete() { return 1; }' \
      'boot_simulator_if_needed() { :; }' 'ios_test_sdk_suffix() { echo stub; }' \
      "rebuild_test_cache() { return $1; }"
    printf '%s\n' "$cache_fn"
    printf '%s\n' 'artifact_temp_file() { mktemp "${TMPDIR:-/tmp}/pc-file.XXXXXX"; }' \
      'artifact_temp_dir() { mktemp -d "${TMPDIR:-/tmp}/pc-dir.XXXXXX"; }' \
      'handle_cache_action prepare'
  } > "$runner"
  PC_RC=0
  PC_OUT="$(TMPDIR="$TMP" /bin/bash "$runner" 2>/dev/null)" || PC_RC=$?
}
if [[ -n "$cache_fn" ]]; then
  run_prepare_cache_case 77
  [[ "$PC_RC" -eq 77 ]] && ok "ios_test.sh --prepare-cache: in-lock structural block exits 77" || bad "prepare-cache structural exit=$PC_RC"
  [[ "$(jq -r '.status' <<<"$PC_OUT" 2>/dev/null)" == "error" ]] \
    && ok "ios_test.sh --prepare-cache: error payload still emitted on a structural block" || bad "prepare-cache payload: $PC_OUT"
  run_prepare_cache_case 75
  [[ "$PC_RC" -eq 75 ]] && ok "ios_test.sh --prepare-cache: in-lock temporary block exits 75" || bad "prepare-cache temporary exit=$PC_RC"
  run_prepare_cache_case 65
  [[ "$PC_RC" -eq 1 ]] && ok "ios_test.sh --prepare-cache: ordinary build failure still exits 1" || bad "prepare-cache build failure exit=$PC_RC"
fi

release_block="$(awk '/^(preflight_rc=0|if ! kg_ios_disk_budget_preflight "\$ROOT" "release")/ { c=1 } c { print } c && /^fi$/ { exit }' "$ROOT/ops/ios_release.sh")"
[[ -n "$release_block" ]] || bad "cannot extract the in-lock preflight block from ios_release.sh"
run_release_block_case() {  # $1=stub preflight rc
  local runner="$TMP/release-block-runner.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "source '$LIB'" "ROOT='$TMP'" \
      "kg_ios_disk_budget_preflight() { return $1; }"
    printf '%s\n' "$release_block" 'echo RELEASE_CONTINUED'
  } > "$runner"
  REL_RC=0
  REL_OUT="$(/bin/bash "$runner" 2>&1)" || REL_RC=$?
}
run_release_block_case 77
[[ "$REL_RC" -eq 77 ]] && ok "ios_release.sh: in-lock structural preflight exits 77" || bad "ios_release.sh in-lock structural exit=$REL_RC: $REL_OUT"
! grep -q 'clean rebuildable cache before retry' <<<"$REL_OUT" \
  && ok "ios_release.sh: structural block does not advise cleaning cache" \
  || bad "ios_release.sh structural block still advises cleaning cache: $REL_OUT"
run_release_block_case 75
[[ "$REL_RC" -eq 75 ]] && ok "ios_release.sh: in-lock temporary preflight exits 75" || bad "ios_release.sh in-lock temporary exit=$REL_RC: $REL_OUT"
grep -q 'clean rebuildable cache before retry' <<<"$REL_OUT" \
  && ok "ios_release.sh: temporary block keeps the clean-cache hint" \
  || bad "ios_release.sh temporary block lost the hint: $REL_OUT"
run_release_block_case 0
[[ "$REL_RC" -eq 0 ]] && grep -q RELEASE_CONTINUED <<<"$REL_OUT" && ok "ios_release.sh: passing preflight continues" || bad "ios_release.sh passing preflight: rc=$REL_RC $REL_OUT"

echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[[ "$FAIL" -eq 0 ]]
