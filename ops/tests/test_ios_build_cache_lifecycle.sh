#!/usr/bin/env bash
set -euo pipefail

WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$WORKTREE/.." && pwd)"
BUILD="$WORKTREE/ios_build.sh"
TEST="$WORKTREE/ios_test.sh"
SWIFTPM_LIB="$WORKTREE/lib/ios_swiftpm_cache.sh"
LOCKFILE="$ROOT/ios/BooksAndVocab.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SWIFTPM_LIB_REL="ops/lib/ios_swiftpm_cache.sh"
LOCKFILE_REL="ios/BooksAndVocab.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$BUILD" || fail "ios_build.sh syntax"
plan="$(KG_IOS_BUILD_DERIVED_DATA_ROOT="$WORKTREE/.cache/test-ios-build-root" \
  "$BUILD" --catalyst --dry-run 2>&1)" || fail "catalyst dry-run"
grep -F '/.cache/test-ios-build-root/catalyst' <<<"$plan" \
  || fail "catalyst uses a dedicated derived-data root"
grep -F -- '-derivedDataPath' <<<"$plan" \
  || fail "dry-run exposes derived-data path"
grep -F 'IOS_DERIVED_DATA_ROOT=' "$BUILD" \
  || fail "catalyst cleans the sibling iOS cache under the build lock"
grep -F 'KG_IOS_CATALYST_KEEP_DERIVED_DATA' "$BUILD" \
  || fail "catalyst cleanup has an explicit diagnostic retention escape hatch"

[[ -f "$SWIFTPM_LIB" ]] || fail "SwiftPM cache helper is missing"
[[ -f "$LOCKFILE" ]] || fail "SwiftPM dependency lockfile is missing"
git -C "$ROOT" ls-files --error-unmatch -- "$SWIFTPM_LIB_REL" >/dev/null 2>&1 \
  || fail "SwiftPM cache helper is not tracked by Git"
git -C "$ROOT" ls-files --error-unmatch -- "$LOCKFILE_REL" >/dev/null 2>&1 \
  || fail "SwiftPM dependency lockfile is not tracked by Git"
if git -C "$ROOT" check-ignore -q -- "$LOCKFILE"; then
  fail "SwiftPM dependency lockfile is ignored instead of versioned"
fi

bash -n "$SWIFTPM_LIB" "$BUILD" "$TEST" || fail "SwiftPM cache scripts have invalid shell syntax"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/kg-ios-swiftpm-cache.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fixture_root="$tmp/project"
fixture_lock="$fixture_root/ios/BooksAndVocab.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
mkdir -p "$(dirname "$fixture_lock")"
printf '{"version": 3, "pins": []}\n' > "$fixture_lock"

# shellcheck source=../lib/ios_swiftpm_cache.sh
source "$SWIFTPM_LIB"

unset KG_IOS_SWIFTPM_CACHE_DIR
kg_ios_swiftpm_configure "$fixture_root"
[[ "${#KG_IOS_SWIFTPM_XCODEBUILD_ARGS[@]}" -eq 0 ]] \
  || fail "local runs unexpectedly receive a hosted SwiftPM cache"

if KG_IOS_SWIFTPM_CACHE_DIR='relative-cache' kg_ios_swiftpm_configure "$fixture_root" >"$tmp/relative.out" 2>"$tmp/relative.err"; then
  fail "relative SwiftPM cache root was accepted"
fi
grep -F 'absolute path' "$tmp/relative.err" >/dev/null \
  || fail "relative cache rejection is not actionable"

if KG_IOS_SWIFTPM_CACHE_DIR="$fixture_root/cache" kg_ios_swiftpm_configure "$fixture_root" >"$tmp/project.out" 2>"$tmp/project.err"; then
  fail "project-local SwiftPM cache root was accepted"
fi
grep -F 'outside the project root' "$tmp/project.err" >/dev/null \
  || fail "project-local cache rejection is not actionable"

missing_root="$tmp/missing-project"
mkdir -p "$missing_root"
if KG_IOS_SWIFTPM_CACHE_DIR="$tmp/hosted-cache" kg_ios_swiftpm_configure "$missing_root" >"$tmp/missing.out" 2>"$tmp/missing.err"; then
  fail "cache setup accepted a project without Package.resolved"
fi
grep -F 'Package.resolved' "$tmp/missing.err" >/dev/null \
  || fail "missing-lock rejection is not actionable"

hosted_cache_root="$(cd "$tmp" && pwd -P)/hosted-cache"
KG_IOS_SWIFTPM_CACHE_DIR="$hosted_cache_root" kg_ios_swiftpm_configure "$fixture_root"
expected_args=(
  -clonedSourcePackagesDirPath "$hosted_cache_root"
  -packageCachePath "$hosted_cache_root/package-cache"
  -onlyUsePackageVersionsFromResolvedFile
)
[[ "${KG_IOS_SWIFTPM_XCODEBUILD_ARGS[*]}" == "${expected_args[*]}" ]] \
  || fail "SwiftPM xcodebuild arguments differ from the safe cache contract"

plan="$(KG_IOS_BUILD_DERIVED_DATA_ROOT="$tmp/derived-data" \
  KG_IOS_SWIFTPM_CACHE_DIR="$hosted_cache_root" \
  "$BUILD" --dry-run 2>&1)" || fail "ios_build SwiftPM cache dry-run"
grep -F "argv=-clonedSourcePackagesDirPath" <<<"$plan" >/dev/null \
  || fail "ios_build does not pass the shared SwiftPM checkout root"
grep -F "argv=$hosted_cache_root" <<<"$plan" >/dev/null \
  || fail "ios_build does not use the requested SwiftPM cache root"
grep -F 'argv=-onlyUsePackageVersionsFromResolvedFile' <<<"$plan" >/dev/null \
  || fail "ios_build does not lock dependency resolution"

grep -F 'source "$SCRIPT_DIR/lib/ios_swiftpm_cache.sh"' "$TEST" >/dev/null \
  || fail "ios_test does not load the SwiftPM cache contract"
grep -F 'kg_ios_swiftpm_configure "$PROJECT_ROOT"' "$TEST" >/dev/null \
  || fail "ios_test does not configure the SwiftPM cache contract"
grep -F '"${KG_IOS_SWIFTPM_XCODEBUILD_ARGS[@]}"' "$TEST" >/dev/null \
  || fail "ios_test build-for-testing does not pass SwiftPM cache arguments"

echo "── ios_test writer disk-budget gate ──"
rebuild_start="$(awk '/^rebuild_test_cache\(\) \{/ { print NR; exit }' "$TEST")"
rebuild_end="$(awk 'NR > start && /^ensure_xctestrun_ready_or_fail\(\) \{/ { print NR; exit }' start="$rebuild_start" "$TEST")"
[[ -n "$rebuild_start" && -n "$rebuild_end" ]] \
  || fail "ios_test rebuild_test_cache function boundaries are not discoverable"
rebuild_body="$(sed -n "${rebuild_start},$((rebuild_end - 1))p" "$TEST")"
lock_line="$(awk '/^[[:space:]]*acquire_build_lock$/ { print NR; exit }' <<<"$rebuild_body")"
eviction_line="$(awk '/^[[:space:]]*kg_ios_cache_evict / { print NR; exit }' <<<"$rebuild_body")"
preflight_line="$(awk '/^[[:space:]]*kg_ios_disk_budget_preflight .*preflight_rc=\$\?/ { print NR; exit }' <<<"$rebuild_body")"
xcodebuild_line="$(awk '/^[[:space:]]*xcodebuild build-for-testing/ { print NR; exit }' <<<"$rebuild_body")"
[[ -n "$lock_line" && -n "$eviction_line" && -n "$preflight_line" && -n "$xcodebuild_line" ]] \
  || fail "ios_test build writer is missing lock, eviction, disk preflight, or xcodebuild"
(( lock_line < eviction_line && eviction_line < preflight_line && preflight_line < xcodebuild_line )) \
  || fail "ios_test disk preflight is not after eviction and before xcodebuild"
grep -F 'disk_budget_project_root="$(dirname "$(dirname "$TEST_CACHE_ROOT")")"' <<<"$rebuild_body" >/dev/null \
  || fail "ios_test disk preflight does not resolve the shared cache project root"
grep -F 'kg_ios_disk_budget_preflight "$disk_budget_project_root" "test"' <<<"$rebuild_body" >/dev/null \
  || fail "ios_test disk preflight does not identify the test writer"
grep -F 'release_build_lock' <<<"$rebuild_body" >/dev/null \
  || fail "ios_test disk-budget block does not release the shared build lock"
grep -F 'return "$preflight_rc"' <<<"$rebuild_body" >/dev/null \
  || fail "ios_test disk-budget block does not propagate the preflight exit (75 temporary / 77 structural)"

# ── --clean-cache must honour the build lock and active-consumer liveness (#2819) ──
# Linux runners do not provide macOS's shlock. --clean-cache is fail-closed without
# it (lock wait times out, exit 75 infrastructure=unavailable), which is correct for
# production; this fixture must still reach the refusal contract, so give it the same
# deterministic primitive test_kg_disk_guard.sh uses. Real shlock stays authoritative
# wherever it exists.
if ! command -v shlock >/dev/null 2>&1; then
  fake_bin="$tmp/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/shlock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
lock_file=""
owner_pid=""
while (($#)); do
  case "$1" in
    -f) lock_file="$2"; shift 2 ;;
    -p) owner_pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$lock_file" && -n "$owner_pid" ]]
if [[ -f "$lock_file" ]]; then
  held_pid="$(cat "$lock_file" 2>/dev/null || true)"
  if [[ "$held_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$held_pid" 2>/dev/null; then
    rm -f "$lock_file"
  else
    exit 1
  fi
fi
if mkdir "${lock_file}.claim" 2>/dev/null; then
  printf '%s\n' "$owner_pid" >"$lock_file"
  rmdir "${lock_file}.claim"
  exit 0
fi
exit 1
EOF
  chmod +x "$fake_bin/shlock"
  export PATH="$fake_bin:$PATH"
fi
command -v shlock >/dev/null 2>&1 || fail "shlock primitive unavailable for the --clean-cache lock fixture"

clean_root="$tmp/clean-cache"
clean_lock="$tmp/clean.lock"
mkdir -p "$clean_root"
run_clean() {
  KG_IOS_TEST_CACHE_ROOT="$clean_root" KG_IOS_BUILD_LOCK_FILE="$clean_lock" "$TEST" --clean-cache --timeout 2
}
clean_dd="$(KG_IOS_TEST_CACHE_ROOT="$clean_root" KG_IOS_BUILD_LOCK_FILE="$clean_lock" "$TEST" --cache-status --json 2>/dev/null \
  | sed -n 's/.*"derivedDataRoot": "\(.*\)".*/\1/p' | head -1)"
[[ -n "$clean_dd" && "$clean_dd" == "$clean_root"/* ]] || fail "could not resolve hermetic derived-data root for clean-cache test"

# fresh liveness touch (active consumer) -> refuse, directory survives
mkdir -p "$clean_dd/Build"
touch "$clean_dd"
if run_clean >"$tmp/clean-live.out" 2>"$tmp/clean-live.err"; then
  fail "--clean-cache deleted a key with a fresh liveness touch"
fi
[[ -d "$clean_dd/Build" ]] || fail "--clean-cache removed an actively used cache key"
grep -F 'active consumer' "$tmp/clean-live.err" >/dev/null \
  || fail "--clean-cache refusal is not actionable"

# held build lock -> clean waits, times out non-zero, directory survives
if command -v shlock >/dev/null 2>&1; then
  touch -t 200001010000 "$clean_dd"
  sleep 60 &
  lock_holder=$!
  shlock -f "$clean_lock" -p "$lock_holder" || fail "could not take hermetic build lock"
  if run_clean >"$tmp/clean-lock.out" 2>"$tmp/clean-lock.err"; then
    kill "$lock_holder" 2>/dev/null || true
    fail "--clean-cache deleted a key while the build lock was held"
  fi
  kill "$lock_holder" 2>/dev/null || true
  wait "$lock_holder" 2>/dev/null || true
  rm -f "$clean_lock"
  [[ -d "$clean_dd/Build" ]] || fail "--clean-cache removed the cache while the build lock was held"
fi

# #2668: build-then-test 會被 sibling ios-build-derived-data 的預算占用擋下；--clean-cache 必須一併清掉它。
clean_build_dd="$(dirname "$clean_root")/ios-build-derived-data"
mkdir -p "$clean_build_dd/Build/Products"
touch -t 200001010000 "$clean_dd"
run_clean >"$tmp/clean-build-dd.out" 2>&1 || fail "--clean-cache failed with a sibling build DerivedData present"
[[ ! -e "$clean_build_dd" ]] || fail "--clean-cache left ios-build-derived-data behind (#2668)"
[[ ! -e "$clean_dd" ]] || fail "--clean-cache left the test key behind when build DerivedData existed"
# 被 active consumer 擋下時，build DerivedData 也不可被動到
mkdir -p "$clean_dd/Build" "$clean_build_dd/Build"
touch "$clean_dd"
run_clean >/dev/null 2>&1 && fail "--clean-cache ignored the active-consumer guard"
[[ -d "$clean_build_dd/Build" ]] || fail "--clean-cache removed build DerivedData despite refusing for an active consumer"
rm -rf "$clean_dd" "$clean_build_dd"
mkdir -p "$clean_dd/Build"
# idle key (stale touch, no lock) -> clean succeeds; fresh touch + force -> also succeeds
touch -t 200001010000 "$clean_dd"
run_clean >"$tmp/clean-idle.out" 2>&1 || fail "--clean-cache refused an idle key"
[[ ! -e "$clean_dd" ]] || fail "--clean-cache left an idle key behind"
mkdir -p "$clean_dd/Build"
touch "$clean_dd"
KG_IOS_CLEAN_CACHE_FORCE=1 run_clean >"$tmp/clean-force.out" 2>&1 || fail "forced --clean-cache failed"
[[ ! -e "$clean_dd" ]] || fail "forced --clean-cache left the key behind"

echo "PASS: ios build cache lifecycle"
