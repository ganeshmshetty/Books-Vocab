#!/usr/bin/env bash
# Offline contract tests for ios_xctestrun_cache.sh.
# No xcodebuild, simulator, or project build is allowed here.

set -u -o pipefail

WORKTREE="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$WORKTREE/ops/lib/ios_xctestrun_cache.sh"
TMPROOT="$(mktemp -d -t kg_xctestrun_cache_test_XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
ok() { echo "  ✓ $*"; pass=$((pass + 1)); }
bad() { echo "  ✗ $*"; fail=$((fail + 1)); }
section() { echo ""; echo "── $* ──"; }

[[ -f "$LIB" ]] || { echo "✗ missing $LIB" >&2; exit 1; }
# shellcheck source=../lib/ios_xctestrun_cache.sh
source "$LIB"

section "cache key is explicit and content keyed"
key_root="$TMPROOT/key-root"
mkdir -p "$key_root/ios"
printf 'alpha\n' >"$key_root/ios/one.swift"
printf 'beta\n' >"$key_root/ios/two.swift"
inputs=$'ios/one.swift\nios/two.swift\nios/missing.swift\n'
key_a="$(printf '%s' "$inputs" | ios_xctestrun_cache_build_key "$key_root" iphonesimulator arm64 unit BooksAndVocabUnitTests Debug 0 unsigned Xcode-26.4)"
key_b="$(printf '%s' "$inputs" | ios_xctestrun_cache_build_key "$key_root" iphonesimulator arm64 unit BooksAndVocabUnitTests Debug 0 unsigned Xcode-26.4)"
key_c="$(printf '%s' "$inputs" | ios_xctestrun_cache_build_key "$key_root" iphonesimulator arm64 ui BooksAndVocabUITests Debug 0 unsigned Xcode-26.4)"
printf 'changed\n' >"$key_root/ios/two.swift"
key_d="$(printf '%s' "$inputs" | ios_xctestrun_cache_build_key "$key_root" iphonesimulator arm64 unit BooksAndVocabUnitTests Debug 0 unsigned Xcode-26.4)"
[[ "$key_a" =~ ^[0-9a-f]{64}$ && "$key_a" == "$key_b" ]] \
  && ok "same explicit inputs produce stable sha256" || bad "cache key is not stable"
[[ "$key_a" != "$key_c" ]] \
  && ok "scope participates in cache key" || bad "scope does not partition cache key"
[[ "$key_a" != "$key_d" ]] \
  && ok "file content participates in cache key" || bad "file content does not partition cache key"

section "xctestrun discovery excludes scoped overlays"
derived="$TMPROOT/derived"
mkdir -p "$derived/Build/Products"
printf 'base' >"$derived/Build/Products/base.xctestrun"
printf 'scoped' >"$derived/Build/Products/base.scoped.xctestrun"
printf 'nested' >"$derived/Build/Products/nested.xctestrun"
found="$(ios_xctestrun_cache_find "$derived")"
all_artifacts="$(ios_xctestrun_cache_list "$derived" | paste -sd '|' -)"
[[ "$found" == "$derived/Build/Products/base.xctestrun" ]] \
  && ok "find returns sorted non-scoped artifact" || bad "find returned '$found'"
[[ "$all_artifacts" == *"base.xctestrun"* && "$all_artifacts" == *"nested.xctestrun"* \
   && "$all_artifacts" != *"scoped"* ]] \
  && ok "list excludes scoped overlays" || bad "list leaked scoped artifact: $all_artifacts"

section "products readiness is scope-aware"
products="$derived/Build/Products"
mkdir -p "$products/Debug-iphonesimulator/BooksAndVocab.app/PlugIns/BooksAndVocabTests.xctest"
mkdir -p "$products/Debug-iphonesimulator/BooksAndVocabUITests-Runner.app"
for scope in unit ui all catalog; do
  if ios_xctestrun_cache_products_ready \
      "$derived/Build/Products/base.xctestrun" Debug iphonesimulator "$scope"; then
    ok "$scope products ready"
  else
    bad "$scope products unexpectedly incomplete"
  fi
done
rm -rf "$products/Debug-iphonesimulator/BooksAndVocabUITests-Runner.app"
if ! ios_xctestrun_cache_products_ready \
    "$derived/Build/Products/base.xctestrun" Debug iphonesimulator ui; then
  ok "missing UI runner blocks ui scope"
else
  bad "missing UI runner did not block ui scope"
fi

section "scoped environment overlay and cleanup"
base="$TMPROOT/base.xctestrun"
staged="$TMPROOT/base.scoped.xctestrun"
cat >"$base" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>TestConfigurations</key><array><dict><key>TestTargets</key><array>
<dict><key>TestingEnvironmentVariables</key><dict><key>KG_FIXTURE_DATASET_B64</key><string>legacy-1</string></dict></dict>
<dict><key>BlueprintName</key><string>SecondTarget</string></dict>
</array></dict></array></dict></plist>
PLIST
if ios_xctestrun_cache_stage_env \
    "$base" "$staged" KG_FIXTURE_DATASET_DEFLATE_B64 compressed KG_FIXTURE_DATASET_B64; then
  staged_value_0="$(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_FIXTURE_DATASET_DEFLATE_B64' "$staged")"
  staged_value_1="$(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables:KG_FIXTURE_DATASET_DEFLATE_B64' "$staged")"
  if [[ "$staged_value_0" == compressed && "$staged_value_1" == compressed ]] \
      && ! /usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_FIXTURE_DATASET_B64' "$staged" >/dev/null 2>&1 \
      && ! /usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables:KG_FIXTURE_DATASET_B64' "$staged" >/dev/null 2>&1; then
    ok "overlay updates every target and removes legacy key"
  else
    bad "overlay keys were not sanitized"
  fi
else
  bad "overlay failed"
fi
if ios_xctestrun_cache_upsert_env_all_targets "$staged" KG_FIXTURE_ASSET_ROOT "$WORKTREE"; then
  asset_root_0="$(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_FIXTURE_ASSET_ROOT' "$staged")"
  asset_root_1="$(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables:KG_FIXTURE_ASSET_ROOT' "$staged")"
  kept_dataset_0="$(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_FIXTURE_DATASET_DEFLATE_B64' "$staged")"
  kept_dataset_1="$(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables:KG_FIXTURE_DATASET_DEFLATE_B64' "$staged")"
  [[ "$asset_root_0" == "$WORKTREE" && "$asset_root_1" == "$WORKTREE" \
     && "$kept_dataset_0" == compressed && "$kept_dataset_1" == compressed ]] \
    && ok "upsert adds evidence env without deleting dataset env" \
    || bad "upsert did not preserve existing dataset env"
else
  bad "upsert failed"
fi
[[ -f "$base" ]] && ok "base xctestrun remains untouched" || bad "base xctestrun was modified"
ios_xctestrun_cache_cleanup_scoped "$staged"
[[ ! -e "$staged" ]] && ok "scoped cleanup removes only staged artifact" || bad "scoped cleanup left staged artifact"

section "cache completion rejects stale worktree identity"
cache_lifecycle_root="$TMPROOT/cache-lifecycle"
mkdir -p "$cache_lifecycle_root/Debug-iphonesimulator/BooksAndVocab.app/PlugIns/BooksAndVocabTests.xctest"

write_cache_xctestrun() {
  local path="$1" asset_root="$2"
  cat >"$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>TestConfigurations</key><array><dict><key>TestTargets</key><array>
<dict><key>TestingEnvironmentVariables</key><dict><key>KG_FIXTURE_ASSET_ROOT</key><string>$asset_root</string></dict></dict>
</array></dict></array></dict></plist>
PLIST
}

write_cache_xctestrun_with_code_coverage_path() {
  local path="$1" asset_root="$2" source_prefix="$3"
  cat >"$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TestConfigurations</key><array><dict><key>TestTargets</key><array>
<dict><key>TestingEnvironmentVariables</key><dict><key>KG_FIXTURE_ASSET_ROOT</key><string>$asset_root</string></dict></dict>
</array></dict></array>
<key>CodeCoverageBuildableInfos</key><array>
<dict><key>SourceFilesCommonPathPrefix</key><string>$source_prefix</string></dict>
</array>
</dict></plist>
PLIST
}

stale_sentinel="$cache_lifecycle_root/.kg-test-cache-complete-stale"
stale_xctestrun="$cache_lifecycle_root/stale.xctestrun"
write_cache_xctestrun "$stale_xctestrun" "$TMPROOT/old-worktree"
: >"$stale_sentinel"
if ios_xctestrun_cache_is_complete \
    "$stale_sentinel" "$stale_xctestrun" Debug iphonesimulator unit; then
  bad "stale worktree cache was reused"
else
  ok "stale worktree cache is rejected"
fi
[[ ! -e "$stale_sentinel" ]] \
  && ok "stale cache completion marker is invalidated" \
  || bad "stale cache completion marker was retained"

current_root="$(cd "$WORKTREE" && pwd -P)"
current_sentinel="$cache_lifecycle_root/.kg-test-cache-complete-current"
current_xctestrun="$cache_lifecycle_root/current.xctestrun"
write_cache_xctestrun "$current_xctestrun" "$current_root"
: >"$current_sentinel"
if ios_xctestrun_cache_is_complete \
    "$current_sentinel" "$current_xctestrun" Debug iphonesimulator unit; then
  ok "current worktree cache remains reusable"
else
  bad "current worktree cache was rejected"
fi
[[ -f "$current_sentinel" ]] \
  && ok "current cache completion marker remains intact" \
  || bad "current cache completion marker was removed"

plain_sentinel="$cache_lifecycle_root/.kg-test-cache-complete-plain"
plain_xctestrun="$cache_lifecycle_root/plain.xctestrun"
cat >"$plain_xctestrun" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>TestConfigurations</key><array><dict><key>TestTargets</key><array>
<dict><key>BlueprintName</key><string>BooksAndVocabTests</string></dict>
</array></dict></array></dict></plist>
PLIST
: >"$plain_sentinel"
if ios_xctestrun_cache_is_complete \
    "$plain_sentinel" "$plain_xctestrun" Debug iphonesimulator unit; then
  ok "cache without fixture worktree path remains reusable"
else
  bad "cache without fixture worktree path was rejected"
fi
[[ -f "$plain_sentinel" ]] \
  && ok "plain cache completion marker remains intact" \
  || bad "plain cache completion marker was removed"

section "cache completion rejects stale code coverage worktree paths"
coverage_derived_root="$TMPROOT/coverage-derived"
coverage_products="$coverage_derived_root/Build/Products"
mkdir -p "$coverage_products/Debug-iphonesimulator/BooksAndVocab.app/PlugIns/BooksAndVocabTests.xctest"
coverage_stale_source="$TMPROOT/old-code-coverage-worktree/ios/BooksAndVocab"
mkdir -p "$coverage_stale_source"
coverage_stale_sentinel="$coverage_derived_root/.kg-test-cache-complete-coverage-stale"
coverage_stale_xctestrun="$coverage_products/coverage-stale.xctestrun"
write_cache_xctestrun_with_code_coverage_path \
  "$coverage_stale_xctestrun" "$current_root" "$coverage_stale_source"
: >"$coverage_stale_sentinel"
if ios_xctestrun_cache_is_complete \
    "$coverage_stale_sentinel" "$coverage_stale_xctestrun" Debug iphonesimulator unit; then
  bad "stale code coverage worktree cache was reused"
else
  ok "stale code coverage worktree cache is rejected"
fi
[[ ! -e "$coverage_stale_sentinel" ]] \
  && ok "stale code coverage marker is invalidated" \
  || bad "stale code coverage marker was retained"

coverage_current_sentinel="$coverage_derived_root/.kg-test-cache-complete-coverage-current"
coverage_current_xctestrun="$coverage_products/coverage-current.xctestrun"
write_cache_xctestrun_with_code_coverage_path \
  "$coverage_current_xctestrun" "$current_root" "$current_root/ios/BooksAndVocab"
: >"$coverage_current_sentinel"
if ios_xctestrun_cache_is_complete \
    "$coverage_current_sentinel" "$coverage_current_xctestrun" Debug iphonesimulator unit; then
  ok "current code coverage worktree cache remains reusable"
else
  bad "current code coverage worktree cache was rejected"
fi
[[ -f "$coverage_current_sentinel" ]] \
  && ok "current code coverage marker remains intact" \
  || bad "current code coverage marker was removed"

section "cache completion preserves shared DerivedData source paths"
shared_derived="$TMPROOT/shared-derived"
shared_products="$shared_derived/Build/Products"
shared_source="$shared_derived/SourcePackages/checkouts/example/Sources"
mkdir -p \
  "$shared_source" \
  "$shared_products/Debug-iphonesimulator/BooksAndVocab.app/PlugIns/BooksAndVocabTests.xctest"
shared_sentinel="$shared_derived/.kg-test-cache-complete-shared"
shared_xctestrun="$shared_products/shared.xctestrun"
write_cache_xctestrun_with_code_coverage_path \
  "$shared_xctestrun" "$current_root" "$shared_source"
: >"$shared_sentinel"
if ios_xctestrun_cache_is_complete \
    "$shared_sentinel" "$shared_xctestrun" Debug iphonesimulator unit; then
  ok "shared DerivedData source path remains reusable"
else
  bad "shared DerivedData source path was rejected"
fi
[[ -f "$shared_sentinel" ]] \
  && ok "shared DerivedData completion marker remains intact" \
  || bad "shared DerivedData completion marker was removed"

section "cache completion accepts SwiftPM sources in the shared clone dir (#3331 CI)"
# CI passes -clonedSourcePackagesDirPath=$KG_IOS_SWIFTPM_CACHE_DIR, outside both the
# worktree and the keyed DerivedData root. Xcode records those package sources in
# CodeCoverageBuildableInfos, so a fresh --coverage build was rejected after it
# succeeded and the prepare path reported cache-products-missing (exit 1).
pkg_clone="$TMPROOT/kg-ios-swiftpm"
pkg_derived="$TMPROOT/pkg-derived"
pkg_products="$pkg_derived/Build/Products"
pkg_source="$pkg_clone/checkouts/SwiftSoup/Sources/SwiftSoup"
mkdir -p \
  "$pkg_source" \
  "$pkg_products/Debug-iphonesimulator/BooksAndVocab.app/PlugIns/BooksAndVocabTests.xctest"
pkg_sentinel="$pkg_derived/.kg-test-cache-complete-pkg"
pkg_xctestrun="$pkg_products/pkg.xctestrun"
write_cache_xctestrun_with_code_coverage_path \
  "$pkg_xctestrun" "$current_root" "$pkg_source/"
: >"$pkg_sentinel"
if ios_xctestrun_cache_is_complete \
    "$pkg_sentinel" "$pkg_xctestrun" Debug iphonesimulator unit "$pkg_clone"; then
  ok "SwiftPM sources under the shared clone dir remain reusable"
else
  bad "SwiftPM sources under the shared clone dir were rejected"
fi
[[ -f "$pkg_sentinel" ]] \
  && ok "SwiftPM clone dir completion marker remains intact" \
  || bad "SwiftPM clone dir completion marker was removed"

pkg_unlisted_sentinel="$pkg_derived/.kg-test-cache-complete-pkg-unlisted"
: >"$pkg_unlisted_sentinel"
if ios_xctestrun_cache_is_complete \
    "$pkg_unlisted_sentinel" "$pkg_xctestrun" Debug iphonesimulator unit; then
  bad "out-of-tree package source was accepted without a clone root"
else
  ok "out-of-tree package source is rejected when no clone root is given"
fi

echo ""
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
