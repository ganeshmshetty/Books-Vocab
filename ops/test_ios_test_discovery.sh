#!/usr/bin/env bash
# test_ios_test_discovery.sh — behavioral verification for the -g (grep) test
# discovery logic used by ops/ios_test.sh.
#
# The discovery logic is extracted into ops/lib/ios_test_discovery.sh as a
# sourceable function `discover_only_flags <test_dir> <grep_pattern>` so it can
# be driven against an isolated fixture tree (no Xcode / no PTY needed).
#
# Regression guards:
#   1. Every test func is attributed to its OWN enclosing top-level container,
#      not the file's first struct (the historical `head -1` bug).
#   2. `@Suite struct X` (same-line) and `@Suite(.serialized)\nstruct X`
#      (split-line) containers are discovered, not silently skipped.
#   3. `final class X: XCTestCase` / `class X` containers are discovered.
#   4. Nested helper structs declared INSIDE a func body (indented) are NOT
#      treated as containers and never appear in a -only-testing path.
#   5. Files with no test container are skipped without emitting bogus flags.
#   6. Top-level `extension ExistingSuite` files (including `Foo+Domain.swift`)
#      resolve to the existing suite instead of silently producing zero tests.
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$WORKSPACE/ops/lib/ios_test_discovery.sh"

pass=0; fail=0
ok()     { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section() { echo ""; echo "── $* ──"; }

[[ -f "$LIB" ]] || { echo "FATAL: $LIB missing"; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

# ── fixture tree ──────────────────────────────────────────────────────────────
FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

# Multi top-level struct file: each func must attribute to its own struct.
cat > "$FIX/MultiStructTests.swift" <<'SWIFT'
import Testing

struct AlphaTests {
    @Test func alphaOne() {}
    @Test func alphaTwo() {
        struct NestedHelper: Error {}   // indented helper — NOT a container
    }
}

struct BravoTests {
    @Test func bravoOne() {}
}
SWIFT

# @Suite same-line containers.
cat > "$FIX/SuiteSameLineTests.swift" <<'SWIFT'
import Testing

@Suite struct CharlieTests {
    @Test func charlieOne() {}
}

@Suite struct DeltaTests {
    @Test func deltaOne() {}
}
SWIFT

# @Suite split-line + @Test-on-prev-line + a helper func that must NOT emit.
cat > "$FIX/SuiteSplitLineTests.swift" <<'SWIFT'
import Testing

@Suite(.serialized)
struct EchoTests {
    @Test func echoOne() {}
    @Test func echoTwo() {}

    @Test @MainActor
    func echoThree() throws {}

    func makeHelper() -> Int { 0 }   // plain helper — NOT a test
}
SWIFT

# XCTest class container with `func test...` (no @Test attribute).
cat > "$FIX/ClassTests.swift" <<'SWIFT'
import XCTest

final class FoxtrotTests: XCTestCase {
    func testFoxtrotOne() {}
    func testFoxtrotTwo() {}
}
SWIFT

# Parameterized @Test(arguments:) — single-line AND multiline-spanning forms.
# The func name does NOT start with `test`, so it is ONLY discoverable via the
# @Test attribute. The multiline `@Test(arguments: [ \n ... \n ])` must arm the
# next `func` across the intervening argument rows (the historical drop bug).
#
# Signature contract: Swift Testing -only-testing IDs must carry the FULL
# parameter-label signature (`golfSingleLine(_:)`, `golfLabeled(input:)`).
# Emitting `golfSingleLine()` for a parameterized func makes xcodebuild match
# 0 tests → "TEST SUCCEEDED" with nothing run (the 2026-06-11 silent FALSE
# GREEN only caught by the post-run zero-tests guard).
cat > "$FIX/ParamTests.swift" <<'SWIFT'
import Testing

struct GolfTests {
    // Single-line argument form (paren closes same line).
    @Test(arguments: [1, 2, 3])
    func golfSingleLine(_ n: Int) {}

    // Multiline argument form — paren opens here, rows below, closes later.
    @Test(arguments: [
        (1, 2.0),
        (3, 4.0),
    ])
    func golfMultiLine(_ a: Int, _ b: Double) {}

    // Labeled parameter — ID must carry the label, not `_`.
    @Test(arguments: ["a", "b"])
    func golfLabeled(input: String) {}

    // External/internal label pair — ID carries the EXTERNAL label.
    @Test(arguments: [1])
    func golfExtInt(for value: Int) {}

    // Nested commas inside a tuple type must not split the label list.
    @Test(arguments: [((1, "x"), 2)])
    func golfTuple(_ pair: (Int, String), count: Int) {}

    // Param list spans lines — signature unknowable from the func line alone;
    // must degrade to a SUITE-level selector (safe superset), never a bare
    // name / wrong signature (both zero-match).
    @Test(arguments: [1])
    func golfMultiLineParams(
        _ n: Int,
        label other: Int
    ) {}

    // Display-name form on its own line above the func.
    @Test("a display name")
    func golfDisplayName() {}

    // Plain helper between tests — must NOT be armed/emitted.
    func makeFixture() -> Int { 0 }

    // Same-line @Test func still works after the multiline arm was consumed.
    @Test func golfSameLine() {}
}

// A second container right after a multiline @Test arm scenario: ensure the
// arm does not bleed across the container boundary onto Hotel's first func.
struct HotelTests {
    @Test(arguments: [
        "x",
        "y",
    ])
    func hotelMultiLine(_ s: String) {}
}
SWIFT

# No container at all — must be skipped, never emit a bogus flag.
cat > "$FIX/NoContainer.swift" <<'SWIFT'
import Foundation
enum Helpers { static func notATest() {} }
SWIFT

# Top-level extension declarations may carry a declaration modifier or
# attribute.  They still extend the named test suite; the owner is not the
# filename and must remain available to --file discovery.
cat > "$FIX/AttributedExtensionTests+Domain.swift" <<'SWIFT'
import Testing

@MainActor extension IndiaTests {
    @Test func attributedExtensionTest() {}
}

private extension JulietTests {
    func testPrivateExtensionXCTest() {}
}
SWIFT

# helper: does the flag set contain exactly this -only-testing path?
has_flag() { grep -qxF -e "-only-testing:BooksAndVocabTests/$2" <<< "$1"; }

# ── 1. syntax ─────────────────────────────────────────────────────────────────
section "Syntax"
bash -n "$LIB" && ok "lib syntax" || fail_t "lib syntax"

# ── 2. multi-struct attribution (the head -1 bug) ─────────────────────────────
section "Multi-struct attribution"
FLAGS="$(discover_only_flags "$FIX" "")"
has_flag "$FLAGS" "AlphaTests/alphaOne()" && ok "alphaOne → AlphaTests" || fail_t "alphaOne misattributed"
has_flag "$FLAGS" "AlphaTests/alphaTwo()" && ok "alphaTwo → AlphaTests" || fail_t "alphaTwo misattributed"
has_flag "$FLAGS" "BravoTests/bravoOne()" && ok "bravoOne → BravoTests (not AlphaTests)" || fail_t "bravoOne misattributed"
grep -qF "AlphaTests/bravoOne" <<< "$FLAGS" && fail_t "bravoOne WRONGLY under AlphaTests" || ok "bravoOne not under AlphaTests"

# ── 3. nested helper struct is never a container ──────────────────────────────
section "Nested helper exclusion"
grep -qF "NestedHelper" <<< "$FLAGS" && fail_t "NestedHelper leaked as container" || ok "NestedHelper not a container"

# ── 4. @Suite same-line ───────────────────────────────────────────────────────
section "@Suite same-line"
has_flag "$FLAGS" "CharlieTests/charlieOne()" && ok "charlieOne → CharlieTests" || fail_t "@Suite same-line CharlieTests skipped"
has_flag "$FLAGS" "DeltaTests/deltaOne()"     && ok "deltaOne → DeltaTests"     || fail_t "@Suite same-line DeltaTests skipped"

# ── 5. @Suite split-line ──────────────────────────────────────────────────────
section "@Suite split-line"
has_flag "$FLAGS" "EchoTests/echoOne()" && ok "echoOne → EchoTests" || fail_t "@Suite split-line skipped"
has_flag "$FLAGS" "EchoTests/echoTwo()" && ok "echoTwo → EchoTests" || fail_t "@Suite split-line skipped"
has_flag "$FLAGS" "EchoTests/echoThree()" && ok "echoThree (@Test on prev line) → EchoTests" || fail_t "@Test-on-prev-line func skipped"
grep -qF "makeHelper" <<< "$FLAGS" && fail_t "plain helper makeHelper leaked" || ok "plain helper makeHelper excluded"

# ── 6. XCTest class container ─────────────────────────────────────────────────
section "XCTest class container"
has_flag "$FLAGS" "FoxtrotTests/testFoxtrotOne" && ok "testFoxtrotOne → FoxtrotTests" || fail_t "class container skipped"
has_flag "$FLAGS" "FoxtrotTests/testFoxtrotTwo" && ok "testFoxtrotTwo → FoxtrotTests" || fail_t "class container skipped"

# ── 7. no-container file emits nothing ────────────────────────────────────────
section "No-container file"
grep -qF "NoContainer" <<< "$FLAGS" && fail_t "NoContainer leaked" || ok "NoContainer skipped"
grep -qF "Helpers" <<< "$FLAGS" && fail_t "Helpers enum leaked" || ok "Helpers enum not a container"

# ── 7b. attributed/modifier extension declarations keep their suite owner ────
section "Attributed and modifier extension owners"
EXT_FLAGS="$(discover_file_only_flags "$FIX/AttributedExtensionTests+Domain.swift" "")"
has_flag "$EXT_FLAGS" "IndiaTests/attributedExtensionTest()" \
  && ok "@MainActor extension test → IndiaTests" \
  || fail_t "@MainActor extension owner was not discovered: $EXT_FLAGS"
has_flag "$EXT_FLAGS" "JulietTests/testPrivateExtensionXCTest" \
  && ok "private extension XCTest test → JulietTests" \
  || fail_t "private extension owner was not discovered: $EXT_FLAGS"

# ── 8. grep pattern filters by func name ──────────────────────────────────────
section "Grep pattern filter"
ONLY_ALPHA="$(discover_only_flags "$FIX" "alpha")"
has_flag "$ONLY_ALPHA" "AlphaTests/alphaOne()" && ok "pattern 'alpha' keeps alphaOne" || fail_t "pattern dropped alphaOne"
grep -qF "bravoOne" <<< "$ONLY_ALPHA" && fail_t "pattern 'alpha' leaked bravoOne" || ok "pattern 'alpha' excludes bravoOne"
grep -qF "charlieOne" <<< "$ONLY_ALPHA" && fail_t "pattern 'alpha' leaked charlieOne" || ok "pattern 'alpha' excludes charlieOne"

# ── 9. case-insensitive pattern (preserves -i behavior) ───────────────────────
section "Case-insensitive pattern"
ONLY_FOX="$(discover_only_flags "$FIX" "FOXTROT")"
has_flag "$ONLY_FOX" "FoxtrotTests/testFoxtrotOne" && ok "uppercase pattern matches" || fail_t "lost case-insensitivity"

# ── 9b. pattern matches suite/container names too（2026-06-11 摩擦修復：以
#        suite 名跑整個 suite 不該再吐 no-tests-matching 浪費一輪 build+test）──
section "Suite/container-name pattern"
ONLY_BRAVO="$(discover_only_flags "$FIX" "BravoTests")"
has_flag "$ONLY_BRAVO" "BravoTests/bravoOne()" \
  && ok "suite-name pattern 'BravoTests' runs its tests" || fail_t "suite-name pattern dropped bravoOne"
grep -qF "alphaOne" <<< "$ONLY_BRAVO" \
  && fail_t "suite-name pattern 'BravoTests' leaked AlphaTests funcs" || ok "suite-name pattern excludes other suites"
# case-insensitive container match + XCTest class container
ONLY_FOXC="$(discover_only_flags "$FIX" "foxtrottests")"
has_flag "$ONLY_FOXC" "FoxtrotTests/testFoxtrotOne" \
  && ok "lowercase suite-name matches XCTest class container" || fail_t "class-container suite-name match failed"
has_flag "$ONLY_FOXC" "FoxtrotTests/testFoxtrotTwo" \
  && ok "suite-name match covers ALL funcs of the container" || fail_t "suite-name match missed testFoxtrotTwo"
# plain helper funcs must stay excluded even when their container matches
ONLY_ECHO="$(discover_only_flags "$FIX" "EchoTests")"
has_flag "$ONLY_ECHO" "EchoTests/echoThree()" \
  && ok "suite-name match includes @Test-on-prev-line funcs" || fail_t "suite-name match missed echoThree"
grep -qF "makeHelper" <<< "$ONLY_ECHO" \
  && fail_t "suite-name match leaked plain helper makeHelper" || ok "suite-name match still excludes plain helpers"
# 交叉地雷迴歸（兩 reviewer 點名）：suite 名 pattern 必須也覆蓋多行參數列的
# suite-level fallback。fallback 分支若自帶只比對 fn 的行內判斷，
# `-g GolfTests` 會無聲漏掉 golfMultiLineParams（partial silent miss）；
# emit() 與 fallback 共用 match_fn_or_container() 後此處必綠。
ONLY_GOLF="$(discover_only_flags "$FIX" "golftests")"
has_flag "$ONLY_GOLF" "GolfTests" \
  && ok "suite-name pattern reaches multiline-params suite fallback" || fail_t "suite-name pattern dropped multiline-params fallback (fn-only check drift)"
has_flag "$ONLY_GOLF" "GolfTests/golfSingleLine(_:)" \
  && ok "suite-name pattern keeps parameterized signatures" || fail_t "suite-name pattern dropped parameterized signature func"

# ── 10. parameterized @Test(arguments:) single + multiline ───────────────────
section "Parameterized @Test(arguments:) discovery"
has_flag "$FLAGS" "GolfTests/golfSingleLine(_:)" && ok "golfSingleLine → (_:) signature" || fail_t "single-line @Test(arguments:) lacks (_:) signature"
has_flag "$FLAGS" "GolfTests/golfMultiLine(_:_:)" && ok "golfMultiLine → (_:_:) signature" || fail_t "multiline @Test(arguments:) lacks (_:_:) signature"
has_flag "$FLAGS" "GolfTests/golfLabeled(input:)" && ok "golfLabeled → (input:) signature" || fail_t "labeled param lost its label"
has_flag "$FLAGS" "GolfTests/golfExtInt(for:)" && ok "golfExtInt → (for:) external label" || fail_t "external/internal label pair mishandled"
has_flag "$FLAGS" "GolfTests/golfTuple(_:count:)" && ok "golfTuple → (_:count:) (tuple comma not split)" || fail_t "nested tuple comma split the label list"
grep -qF "golfSingleLine()" <<< "$FLAGS" && fail_t "parameterized func WRONGLY emitted bare () (xcodebuild matches 0 tests = false green)" || ok "no bare () emitted for parameterized funcs"
has_flag "$FLAGS" "GolfTests" && ok "golfMultiLineParams (params span lines) → suite-level fallback" || fail_t "multiline-params func did not fall back to suite-level selector"
grep -qF "golfMultiLineParams" <<< "$FLAGS" && fail_t "multiline-params func emitted a guessed (wrong) func selector" || ok "no guessed selector for multiline-params func"
has_flag "$FLAGS" "GolfTests/golfDisplayName()" && ok "golfDisplayName (@Test display name) → GolfTests" || fail_t "@Test(display-name) dropped"
has_flag "$FLAGS" "GolfTests/golfSameLine()" && ok "golfSameLine (@Test func after multiline arm) → GolfTests" || fail_t "same-line @Test regressed after multiline arm"
grep -qF "makeFixture" <<< "$FLAGS" && fail_t "plain helper makeFixture leaked" || ok "plain helper makeFixture excluded"
has_flag "$FLAGS" "HotelTests/hotelMultiLine(_:)" && ok "hotelMultiLine → HotelTests (no cross-container bleed)" || fail_t "multiline arm dropped in HotelTests"
grep -qF "GolfTests/hotelMultiLine" <<< "$FLAGS" && fail_t "hotelMultiLine WRONGLY under GolfTests (arm bled across container)" || ok "no arm bleed across struct boundary"

# ── 11. ios_test.sh -g 旗標 E2E（--list 在碰鎖/xcodebuild 前退出，可安全跑）──
# 多個 -g 必須累積成 OR（歷史 bug：後者無聲覆蓋前者 → 以為跑兩個實際跑一個）。
section "ios_test.sh multi -g accumulation (--list)"
# ios_test.sh 的 TEST_DIR 硬編真實 test 目錄（吃不到本檔的 $FIX fixture），
# 故直接從真實測試自我發現兩個方法名。注意：只認 XCTest 風格 `func testXxx`；
# 若全數遷移到 Swift Testing 命名，這裡會找不到名而 fail（屆時改抓 @Test func）。
IOS_TEST="$WORKSPACE/ops/ios_test.sh"
PAT_A="$(grep -rhoE 'func test[A-Za-z0-9_]+' "$WORKSPACE/ios/BooksAndVocabTests" 2>/dev/null | sed -n '1p' | sed 's/func //')"
PAT_B="$(grep -rhoE 'func test[A-Za-z0-9_]+' "$WORKSPACE/ios/BooksAndVocabTests" 2>/dev/null | tail -1 | sed 's/func //')"
if [[ -n "$PAT_A" && -n "$PAT_B" && "$PAT_A" != "$PAT_B" ]]; then
  LIST_A="$("$IOS_TEST" -g "$PAT_A" --list 2>/dev/null)" || LIST_A=""
  LIST_B="$("$IOS_TEST" -g "$PAT_B" --list 2>/dev/null)" || LIST_B=""
  OUT_AB="$("$IOS_TEST" -g "$PAT_A" -g "$PAT_B" --list 2>/dev/null)" || OUT_AB=""
  # 強斷言：合併輸出必須是兩個單獨輸出的聯集超集（防舊覆蓋 bug 用計數巧合矇混）。
  superset=1
  while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    grep -qF -- "$flag" <<<"$OUT_AB" || { superset=0; break; }
  done < <(printf '%s\n%s\n' "$LIST_A" "$LIST_B" | grep only-testing)
  N_A="$(grep -c only-testing <<<"$LIST_A" || true)"
  N_B="$(grep -c only-testing <<<"$LIST_B" || true)"
  if (( N_A >= 1 && N_B >= 1 && superset == 1 )); then
    ok "multi -g 累積且合併輸出 ⊇ 兩單獨輸出聯集（$PAT_A:$N_A + $PAT_B:${N_B}）"
  else
    fail_t "multi -g 未累積（$PAT_A:$N_A, $PAT_B:$N_B, superset=${superset}）"
  fi
else
  fail_t "找不到兩個可用的真實測試名（PAT_A='$PAT_A' PAT_B='$PAT_B'）"
fi

# ── 11a. build-for-testing progress must identify its caller (IMP-20260808-7bdba0) ──
# Execute the actual \`rebuild_test_cache\` function with a hermetic xcodebuild
# stub. Two different caller values make this a value-sensitive regression:
# checking only for the token \`caller=\` would let a hard-coded or empty value
# pass, and swapping the expected caller must make one assertion fail.
section "ios_test.sh build progress caller identity"
BUILD_FN="$(awk '
  /^rebuild_test_cache\(\) \{/ { capture=1 }
  /^ensure_xctestrun_ready_or_fail\(\) \{/ { exit }
  capture { print }
' "$IOS_TEST")"
if [[ -z "$BUILD_FN" ]]; then
  fail_t "找不到 ios_test.sh 的 rebuild_test_cache fixture"
else
  synthetic_build_output() {
    local caller="$1"
    local runner="$FIX/build-progress-${caller}.sh"
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf '%s\n' 'set -euo pipefail'
      printf 'CALLER=%q\n' "$caller"
      printf 'DERIVED_DATA_ROOT=%q\n' "$FIX/derived-$caller"
      printf 'TEST_CACHE_ROOT=%q\n' "$FIX/cache"
      printf 'XCODE_ARGS_CAPTURE=%q\n' "$FIX/xcodebuild-$caller.args"
      printf '%s\n' \
        'IOS_TEST_CACHE_SENTINEL=.kg-test-cache-complete' \
        'TEST_SCOPE=unit' \
        'TEST_SCHEME=BooksAndVocabUnitTests' \
        'CONFIGURATION=Debug' \
        'DESTINATION="platform=iOS Simulator,name=Fixture"' \
        'XCODEPROJ=/tmp/BooksAndVocab.xcodeproj' \
        'IOS_TEST_SIGNING_ARGS=()' \
        'COVERAGE_XCODEBUILD_ARGS=()' \
        'KG_IOS_SWIFTPM_XCODEBUILD_ARGS=(-clonedSourcePackagesDirPath /tmp/kg-swiftpm -packageCachePath /tmp/kg-swiftpm/package-cache -onlyUsePackageVersionsFromResolvedFile)' \
        'MAX_TEST_EXECUTION_TIME_ALLOWANCE=60' \
        'BUILD_FOR_TESTING_MS=0' \
        'REBUILD_DID_BUILD=0' \
        'BUILD_LOG="$0.log"' \
        'BUILD_RESULT_BUNDLE="$0.xcresult"'
      printf '%s\n' \
        'acquire_build_lock() { :; }' \
        'kg_ios_cache_evict() { :; }' \
        'ios_test_find_xctestrun() { return 1; }' \
        'kg_ios_disk_budget_preflight() { return 0; }' \
        'KG_IOS_DISK_BUDGET_EXIT=0' \
        'ios_test_cache_is_complete() { return 1; }' \
        'ios_test_cached_products_ready() { return 0; }' \
        'ios_test_now_ms() { printf "100\\n"; }' \
        'start_build_monitor() { (sleep 60) >/dev/null 2>&1 & printf "%s\\n" "$!"; }' \
        'count_compile_events() { printf "2\\n"; }' \
        'xcodebuild() { printf "%s\\n" "$@" > "$XCODE_ARGS_CAPTURE"; return 0; }' \
        'release_build_lock() { :; }'
      printf '%s\n' "$BUILD_FN"
      printf '%s\n' 'rebuild_test_cache "$BUILD_LOG" "$BUILD_RESULT_BUNDLE"'
    } > "$runner"
    chmod +x "$runner"
    "$runner" 2>&1
  }

  BUILD_ALPHA="$(synthetic_build_output "caller-alpha")" || BUILD_ALPHA=""
  BUILD_BRAVO="$(synthetic_build_output "caller-bravo")" || BUILD_BRAVO=""
  ALPHA_LINE="$(grep -F '[ios_test][build-for-testing]' <<<"$BUILD_ALPHA" || true)"
  BRAVO_LINE="$(grep -F '[ios_test][build-for-testing]' <<<"$BUILD_BRAVO" || true)"
  ALPHA_ARGS="$(tr '\n' ' ' < "$FIX/xcodebuild-caller-alpha.args" 2>/dev/null || true)"
  BRAVO_ARGS="$(tr '\n' ' ' < "$FIX/xcodebuild-caller-bravo.args" 2>/dev/null || true)"
  [[ "$ALPHA_LINE" == *"caller=caller-alpha"* && "$ALPHA_LINE" != *"caller=caller-bravo"* ]] \
    && ok "build progress keeps caller-alpha" \
    || fail_t "build progress lost/swapped caller-alpha: $ALPHA_LINE"
  [[ "$BRAVO_LINE" == *"caller=caller-bravo"* && "$BRAVO_LINE" != *"caller=caller-alpha"* ]] \
    && ok "build progress keeps caller-bravo" \
    || fail_t "build progress lost/swapped caller-bravo: $BRAVO_LINE"
  for args in "$ALPHA_ARGS" "$BRAVO_ARGS"; do
    [[ "$args" == *"-clonedSourcePackagesDirPath /tmp/kg-swiftpm"* \
      && "$args" == *"-packageCachePath /tmp/kg-swiftpm/package-cache"* \
      && "$args" == *"-onlyUsePackageVersionsFromResolvedFile"* ]] \
      && ok "build-for-testing receives the isolated lockfile-pinned SwiftPM cache" \
      || fail_t "build-for-testing dropped SwiftPM cache arguments: $args"
  done
fi

# ── 11b. 空 -g pattern 必須被拒（空 ERE alternative 匹配一切 = silent broadening）─
section "empty -g pattern rejected"
EMPTY_ERR="$("$IOS_TEST" -g '' --list 2>&1 >/dev/null)" && EMPTY_RC=0 || EMPTY_RC=$?
[[ "$EMPTY_RC" -eq 2 ]] && ok "空 pattern exit 2" || fail_t "空 pattern rc=${EMPTY_RC}（應 2）"
grep -q "空 pattern" <<<"$EMPTY_ERR" && ok "錯誤訊息明示拒絕原因" || fail_t "錯誤訊息缺拒絕原因: $EMPTY_ERR"

# ── 12. 零匹配錯誤訊息必須講清楚匹配語意（方法名＋suite/容器名，不對檔名）────
section "zero-match error message semantics"
ZERO_ERR="$("$IOS_TEST" -g zzz_no_such_test_zzz --list 2>&1 >/dev/null)" && ZERO_RC=0 || ZERO_RC=$?
[[ "$ZERO_RC" -ne 0 ]] && ok "零匹配 exit 非 0" || fail_t "零匹配竟 exit 0"
grep -q "方法名" <<<"$ZERO_ERR" && grep -q "容器名" <<<"$ZERO_ERR" && grep -q "檔名" <<<"$ZERO_ERR" \
  && ok "錯誤訊息說明匹配方法名＋suite/容器名、不匹配檔名" \
  || fail_t "錯誤訊息未說明匹配語意: $ZERO_ERR"

# ── 12b. -g 用 suite 名 E2E（--list；歷史摩擦：suite 名 → no tests matching
#         浪費一輪 ~270s build+test）。從真實測試自我發現一個 @Suite/struct 名。──
section "ios_test.sh -g suite-name (--list)"
SUITE_NAME="$(grep -rhoE '^(@Suite[^A-Za-z]*)?(final )?(struct|class) [A-Za-z0-9_]+' "$WORKSPACE/ios/BooksAndVocabTests" 2>/dev/null | grep -oE '[A-Za-z0-9_]+$' | sed -n '1p')"
if [[ -n "$SUITE_NAME" ]]; then
  SUITE_LIST="$("$IOS_TEST" -g "$SUITE_NAME" --list 2>/dev/null)" || SUITE_LIST=""
  N_SUITE="$(grep -c "only-testing:BooksAndVocabTests/$SUITE_NAME/" <<<"$SUITE_LIST" || true)"
  if (( N_SUITE >= 1 )); then
    ok "-g '$SUITE_NAME'（suite 名）resolve 出 $N_SUITE 個 selector"
  else
    fail_t "-g '$SUITE_NAME'（suite 名）零 selector：$SUITE_LIST"
  fi
else
  fail_t "找不到可用的真實 suite 名"
fi

# ── 12c. split-extension Swift Testing selector must be discoverable ─────────
# FixtureDatasetStoreTests+DomainC.swift is intentionally a split extension;
# treating the filename as the suite (or requiring a same-file struct) makes
# -g and --file report zero before Xcode is ever reached.
section "split-extension test discovery"
SPLIT_METHOD="readerEPUBSourcePathRejectsUnsafeLocatorsAtDecodeBoundary"
SPLIT_G_LIST="$($IOS_TEST --list -g "$SPLIT_METHOD" 2>/dev/null)" || SPLIT_G_LIST=""
grep -qxF -- "-only-testing:BooksAndVocabTests/FixtureDatasetStoreTests/${SPLIT_METHOD}()" <<<"$SPLIT_G_LIST" \
  && ok "-g discovers ${SPLIT_METHOD} from split extension" \
  || fail_t "-g split extension discovery returned zero or wrong suite: $SPLIT_G_LIST"
SPLIT_FILE_LIST="$($IOS_TEST --list --file FixtureDatasetStoreTests+DomainC 2>/dev/null)" || SPLIT_FILE_LIST=""
grep -qxF -- "-only-testing:BooksAndVocabTests/FixtureDatasetStoreTests/${SPLIT_METHOD}()" <<<"$SPLIT_FILE_LIST" \
  && ok "--file discovers tests from FixtureDatasetStoreTests+DomainC.swift" \
  || fail_t "--file split extension discovery returned zero: $SPLIT_FILE_LIST"

# ── 13. --ui 缺 dataset 錯誤必須列出可用 UI World 名單（IMP-0011 迴歸）──────
section "--ui missing dataset lists available worlds"
DS_ERR="$("$IOS_TEST" --ui -g Foo 2>&1 >/dev/null)" && DS_RC=0 || DS_RC=$?
[[ "$DS_RC" -ne 0 ]] && ok "--ui 缺 dataset exit 非 0" || fail_t "--ui 缺 dataset 竟 exit 0"
grep -q "available datasets" <<<"$DS_ERR" && grep -q "marketing_demo" <<<"$DS_ERR" \
  && ok "錯誤列出可用 dataset 名單（含 marketing_demo）" \
  || fail_t "錯誤未列可用 dataset: $DS_ERR"

# ── 14. 裸方法名必須反查自身容器（IMP-0030）──────────────────────────────────
# 舊行為：非 `Class/method` 形式即硬拼 `$TEST_TARGET/$TEST_TARGET/$t`，把每個測試都
# 掛到「與 target 同名的 class」下。凡不住在該 class 的測試 → selector 0 匹配，
# 而 parse 期照樣 exit 0，要跑完一整輪 build+test 才被尾端 zero-executed guard 抓到。
section "bare method name resolves to its own container"
UI_DIR="$WORKSPACE/ios/BooksAndVocabUITests"
# 自我發現一個「容器 != BooksAndVocabUITests」的 UITest 方法（硬編會隨測試樹漂移）。
# 先整包收進變數再 awk：`producer | awk '...exit'` 會給 producer SIGPIPE，
# 在 `set -o pipefail` 下傳出 141 直接殺掉本腳本（IMP-0058 同一類地雷）。
UI_FLAGS="$(discover_only_flags "$UI_DIR" "" "BooksAndVocabUITests")"
FOREIGN="$(awk -F/ 'NF>=3 && $2 != "BooksAndVocabUITests" { print $2 "|" $3; exit }' <<<"$UI_FLAGS")"
FOREIGN_CLASS="${FOREIGN%%|*}"; FOREIGN_ID="${FOREIGN##*|}"; FOREIGN_BARE="${FOREIGN_ID%%(*}"
if [[ -n "$FOREIGN_CLASS" && -n "$FOREIGN_BARE" && "$FOREIGN_CLASS" != "BooksAndVocabUITests" ]]; then
  BARE_OUT="$("$IOS_TEST" --ui --list "$FOREIGN_BARE" 2>/dev/null)" || BARE_OUT=""
  grep -qxF -- "-only-testing:BooksAndVocabUITests/$FOREIGN_CLASS/$FOREIGN_ID" <<<"$BARE_OUT" \
    && ok "裸 $FOREIGN_BARE → ${FOREIGN_CLASS}（非 target 同名 class）" \
    || fail_t "裸方法未解析到自身容器 ${FOREIGN_CLASS}，實得：$BARE_OUT"
  PT_OUT="$("$IOS_TEST" --ui --list "$FOREIGN_CLASS/$FOREIGN_ID" 2>/dev/null)" || PT_OUT=""
  grep -qxF -- "-only-testing:BooksAndVocabUITests/$FOREIGN_CLASS/$FOREIGN_ID" <<<"$PT_OUT" \
    && ok "明確 Class/method 直通不變" || fail_t "Class/method 直通壞了：$PT_OUT"
else
  fail_t "找不到容器非 BooksAndVocabUITests 的 UITest 方法（FOREIGN='$FOREIGN'）"
fi

# ── 15. 不存在的裸方法名必須在 parse 期失敗（不得白跑一輪 build+test）─────────
section "unknown bare method fails at parse time"
BOGUS_ERR="$("$IOS_TEST" --ui --list zzzNoSuchBareMethodZzz 2>&1 >/dev/null)" && BOGUS_RC=0 || BOGUS_RC=$?
[[ "$BOGUS_RC" -ne 0 ]] && ok "不存在的裸方法 exit 非 0" \
  || fail_t "不存在的裸方法竟 exit 0（0 匹配的 selector 會被當成有效輸入送進 xcodebuild）"
# 只讀 stderr（`2>&1 >/dev/null`）：stdout 上任何含斜線的 selector 都不得滿足這條。
grep -q "Class/method" <<<"$BOGUS_ERR" \
  && ok "錯誤訊息指向 bare-method / Class/method 規則" \
  || fail_t "錯誤訊息未指向 bare-method 規則：$BOGUS_ERR"

# ── 16. Swift Testing 裸方法名必須帶簽名（無括號 id → xcodebuild 0 匹配）──────
section "bare Swift Testing method carries its signature"
UNIT_DIR="$WORKSPACE/ios/BooksAndVocabTests"
UNIT_FLAGS="$(discover_only_flags "$UNIT_DIR" "" "BooksAndVocabTests")"
SWIFT_PAIR="$(awk -F/ 'NF>=3 && $3 ~ /\(\)$/ { print $2 "|" $3; exit }' <<<"$UNIT_FLAGS")"
SWIFT_CLASS="${SWIFT_PAIR%%|*}"; SWIFT_FN="${SWIFT_PAIR##*|}"; SWIFT_BARE="${SWIFT_FN%%(*}"
if [[ -n "$SWIFT_CLASS" && -n "$SWIFT_BARE" ]]; then
  SW_OUT="$("$IOS_TEST" --list "$SWIFT_BARE" 2>/dev/null)" || SW_OUT=""
  grep -qxF -- "-only-testing:BooksAndVocabTests/$SWIFT_CLASS/$SWIFT_FN" <<<"$SW_OUT" \
    && ok "裸 $SWIFT_BARE → 帶簽名 $SWIFT_FN" \
    || fail_t "Swift Testing 裸名未帶簽名（xcodebuild 會 0 匹配），實得：$SW_OUT"
else
  fail_t "找不到 Swift Testing (@Test) 方法（SWIFT_PAIR='$SWIFT_PAIR'）"
fi

# ── 17. App Review live-demo 取證的實際命令形狀必須選到真的測試（IMP-0030）────
# 這條守的是 submission gate：ops/app_review_evidence.py 的 build_demo_run_command
# 以「裸方法名」呼叫 runner。期望值兩端都獨立於 ios_test.sh 與 discovery lib：
# 方法名讀自 caller 原始碼，class 名讀自 Swift 原始碼（本地 awk 反查最近的
# column-0 型別宣告），所以這條不可能被 runner 自己的輸出或本檔的 argv 滿足。
section "App Review live-demo command shape selects a real test"
DEMO_METHOD="$(awk -F'"' '/"--json", *"test/ { print $4; exit }' "$WORKSPACE/ops/app_review_evidence.py")"
DEMO_HITS="$(grep -rl "func ${DEMO_METHOD}(" "$UI_DIR" 2>/dev/null || true)"
DEMO_FILE="$(awk 'NR==1 { print; exit }' <<<"$DEMO_HITS")"
DEMO_CLASS=""
[[ -n "$DEMO_METHOD" && -n "$DEMO_FILE" ]] && DEMO_CLASS="$(awk -v fn="$DEMO_METHOD" '
  /^(final[ \t]+)?(public[ \t]+)?(class|struct|actor)[ \t]+[A-Za-z0-9_]+/ {
    name = $0
    sub(/^.*(class|struct|actor)[ \t]+/, "", name)
    sub(/[^A-Za-z0-9_].*$/, "", name)
    c = name
    next
  }
  $0 ~ ("func[ \t]+" fn "[ \t]*\\(") { print c; exit }
' "$DEMO_FILE")"
if [[ -n "$DEMO_METHOD" && -n "$DEMO_CLASS" ]]; then
  DEMO_SHA="$(printf 'd%.0s' {1..64})"
  DEMO_OUT="$("$IOS_TEST" --ui --configuration Release --evidence-kind exact-device \
    --destination 'platform=iOS,id=IMP0030-PLACEHOLDER' --live-demo \
    --live-demo-account-identity-sha256 "$DEMO_SHA" \
    --evidence-locale en_US --evidence-timezone UTC \
    --list "$DEMO_METHOD" 2>/dev/null)" || DEMO_OUT=""
  grep -qxF -- "-only-testing:BooksAndVocabUITests/$DEMO_CLASS/$DEMO_METHOD" <<<"$DEMO_OUT" \
    && ok "取證命令選到 $DEMO_CLASS/$DEMO_METHOD" \
    || fail_t "取證命令未選到 ${DEMO_CLASS}（0 匹配 = 送審證據什麼都沒證明），實得：$DEMO_OUT"
  # 缺陷簽章本身：這條若哪天 class == target 就退化成恆真，故明寫出來。
  [[ "$DEMO_CLASS" != "BooksAndVocabUITests" ]] \
    && ok "取證測試確實不住在 target 同名 class（本條非恆真）" \
    || fail_t "取證測試已搬進 BooksAndVocabUITests，本節失去鑑別力，需改測試樹或改斷言"
else
  fail_t "無法從 caller/Swift 原始碼推導取證身分（method='$DEMO_METHOD' file='$DEMO_FILE' class='$DEMO_CLASS'）"
fi

# ── 18. 跨 scope 的裸名必須被具名指認，而非回報「查無此方法」（IMP-0030 收尾）───
# 第 14 節把容器反查修好之後仍剩一個誤導面：一個**真實存在、只是不在本 scope**
# 的裸方法名，錯誤訊息說的是「no test method named 'X'」——那句話是假的。X 存在，
# 只是住在另一個 target。讀者拿到那句話會去找拼字錯誤，或斷定測試不存在；真正
# 該做的動作（補一個 --ui / --unit）沒有任何地方講。零匹配要說出「它屬於誰」。
section "cross-scope bare method is named, not denied"

# 期望值全部自我發現：挑一個「只住在 UI 樹、不住在 unit 樹」的裸名（反之亦然），
# 硬編會隨測試樹漂移。awk 一律吃 here-string，不接 pipe（`producer | awk exit`
# 會給 producer SIGPIPE，pipefail 下傳出 141 殺掉本腳本 —— IMP-0058 同類地雷）。
bare_names_of() { awk -F/ 'NF>=3 { id = $3; sub(/\(.*$/, "", id); print id }' <<<"$1" | sort -u; }
UNIT_BARES="$(bare_names_of "$UNIT_FLAGS")"
UI_BARES="$(bare_names_of "$UI_FLAGS")"
pick_exclusive() {  # $1=flags；$2=要排除的裸名集合（換行分隔）→ 印 "Class|bare"
  # 排除集不走 argv（`awk -v`）：Linux 單一 argv 字串上限 128 KiB（MAX_ARG_STRLEN），
  # unit 測試數一長就 rc=126（#3260）。改把「排除名單 + 分隔行 + flags」合成同一份
  # here-string 當 stdin 資料餵 awk：先讀名單進 seen、遇分隔行切到 flags 模式。
  # 名單逐行讀，不需 tr 攤平，也不受 BSD awk「-v 不接受換行」限制。here-string 非 pipe，
  # 無 SIGPIPE 風險（見上方 IMP-0058 註記）。分隔行 @@flags@@ 不會是合法 selector 或裸名。
  awk -F/ '
    $0 == "@@flags@@" { flags = 1; next }
    !flags { if ($0 != "") seen[$0] = 1; next }
    NF>=3 { bare = $3; sub(/\(.*$/, "", bare); if (!(bare in seen)) { print $2 "|" bare; exit } }
  ' <<<"$(printf '%s\n' "$2"; printf '%s\n' '@@flags@@'; printf '%s\n' "$1")"
}

# ── 19. 排除集超過單一 argv 字串上限仍可運作（#3260）───────────────────────────
# Linux 把單一 argv 字串限在 128 KiB（MAX_ARG_STRLEN），unit 測試數一長，把名單塞進
# `awk -v` 就 rc=126。macOS 沒有這個上限（已實測 200 KB 的 -v 可過），直接跑不會紅，
# 故以 awk shim 模擬同一上限：任一 argv 字串 ≥128 KiB 即回 126 並印 Linux 的訊息，讓
# 回歸在兩平台都重現同一個失敗。shim 只在本節存活，結束即 unset。
section "exclusion set larger than argv string limit (#3260)"
awk() {
  local a
  for a in "$@"; do
    if [[ "${#a}" -ge 131072 ]]; then
      echo "awk: Argument list too long" >&2
      return 126
    fi
  done
  command awk "$@"
}
# 基線：無排除時第一個會被挑中的 UI 裸名。大集合必須含它，排除是否生效才可觀測。
BIG_BASE="$(pick_exclusive "$UI_FLAGS" "")"
BIG_BASE_BARE="${BIG_BASE##*|}"
[[ -n "$BIG_BASE_BARE" ]] \
  && ok "基線（無排除）挑中 ${BIG_BASE}" \
  || fail_t "基線挑不出任何 UI 裸名（BIG_BASE='$BIG_BASE'），無法驗證排除集生效"
BIG_EXCL="$(printf 'testSynthesizedExclusionNameNumber%05d\n' $(seq 1 4200); printf '%s\n' "$BIG_BASE_BARE")"
[[ "${#BIG_EXCL}" -ge 131072 ]] \
  && ok "合成排除集 ${#BIG_EXCL} bytes，超過 128 KiB argv 上限" \
  || fail_t "合成排除集僅 ${#BIG_EXCL} bytes，未達 128 KiB，本節失去鑑別力"
BIG_OUT="$(pick_exclusive "$UI_FLAGS" "$BIG_EXCL" 2>"$FIX/big.err")" && BIG_RC=0 || BIG_RC=$?
[[ "$BIG_RC" -eq 0 ]] \
  && ok "超大排除集下 pick_exclusive exit 0" \
  || fail_t "超大排除集下 pick_exclusive rc=${BIG_RC}，stderr: $(cat "$FIX/big.err")"
grep -qF 'Argument list too long' "$FIX/big.err" \
  && fail_t "超大排除集下 stderr 出現 Argument list too long" \
  || ok "超大排除集下 stderr 無 Argument list too long"
# 排除集必須真的生效：整段被忽略時挑出值會等於基線，這裡即紅（舊版只斷言含 "|"，無法鑑別）。
[[ "$BIG_OUT" == *"|"* && "${BIG_OUT##*|}" != "$BIG_BASE_BARE" ]] \
  && ok "超大排除集生效：挑出 ${BIG_OUT}，跳過了基線的 ${BIG_BASE_BARE}" \
  || fail_t "超大排除集未生效：挑出 '${BIG_OUT}'，應跳過 '${BIG_BASE_BARE}'"
unset -f awk

XS_PAIR="$(pick_exclusive "$UI_FLAGS" "$UNIT_BARES")"
XS_CLASS="${XS_PAIR%%|*}"; XS_BARE="${XS_PAIR##*|}"
if [[ -n "$XS_CLASS" && -n "$XS_BARE" ]]; then
  # 不給 --ui → unit scope。名字真的存在，只是不在這個 scope。
  XS_ERR="$("$IOS_TEST" --list "$XS_BARE" 2>&1 >/dev/null)" && XS_RC=0 || XS_RC=$?
  [[ "$XS_RC" -ne 0 ]] \
    && ok "跨 scope 裸名仍在 parse 期失敗（不靜默改跑另一個 scope）" \
    || fail_t "跨 scope 裸名 exit 0 —— 0 匹配的 selector 被當成有效輸入"
  # 只讀 stderr（`2>&1 >/dev/null`）：stdout 的 selector 不得滿足這條。
  grep -qF -- "BooksAndVocabUITests/$XS_CLASS" <<<"$XS_ERR" \
    && ok "錯誤指名真正的 target/容器 BooksAndVocabUITests/$XS_CLASS" \
    || fail_t "錯誤未指名 $XS_BARE 真正所屬的 BooksAndVocabUITests/${XS_CLASS}，實得：$XS_ERR"
  grep -qF -- "--ui $XS_BARE" <<<"$XS_ERR" \
    && ok "錯誤給出可直接複製的修正命令（--ui ${XS_BARE}）" \
    || fail_t "錯誤未給出可執行的修正命令，實得：$XS_ERR"
else
  fail_t "找不到只住在 UI 樹的裸方法名（XS_PAIR='$XS_PAIR'）"
fi

XU_PAIR="$(pick_exclusive "$UNIT_FLAGS" "$UI_BARES")"
XU_CLASS="${XU_PAIR%%|*}"; XU_BARE="${XU_PAIR##*|}"
if [[ -n "$XU_CLASS" && -n "$XU_BARE" ]]; then
  # 反向：unit 的名字配 --ui。方向不對稱地寫死一邊會讓另一半無聲失效。
  XU_ERR="$("$IOS_TEST" --ui --list "$XU_BARE" 2>&1 >/dev/null)" && XU_RC=0 || XU_RC=$?
  [[ "$XU_RC" -ne 0 ]] && ok "反向（unit 名 + --ui）同樣在 parse 期失敗" \
    || fail_t "反向跨 scope 裸名 exit 0"
  grep -qF -- "BooksAndVocabTests/$XU_CLASS" <<<"$XU_ERR" \
    && ok "反向錯誤指名 BooksAndVocabTests/$XU_CLASS" \
    || fail_t "反向錯誤未指名真正 target，實得：$XU_ERR"
  grep -qF -- "--unit $XU_BARE" <<<"$XU_ERR" \
    && ok "反向錯誤給出 --unit 修正命令" \
    || fail_t "反向錯誤未給修正命令，實得：$XU_ERR"
else
  fail_t "找不到只住在 unit 樹的裸方法名（XU_PAIR='$XU_PAIR'）"
fi

# 負控：真的哪裡都不存在的名字，不得被硬扯到另一個 target。少了這條，
# 上面四條會被「一律建議去試另一個 scope」的退化實作整組滿足。
NC_ERR="$("$IOS_TEST" --list zzzNoSuchNameInEitherTreeZzz 2>&1 >/dev/null)" || true
grep -qF -- "BooksAndVocabUITests/" <<<"$NC_ERR" \
  && fail_t "不存在的名字被誤指為住在 UI target（負控失敗）：$NC_ERR" \
  || ok "查無此名時不編造 target（負控）"

# ── 20. Mac Catalyst destination 必須被擋（IMP-0043）──────────────────────────
section "Mac Catalyst destination refused"
CAT_ERR="$("$IOS_TEST" --list --destination 'platform=macOS,variant=Mac Catalyst' 2>&1 >/dev/null)" && CAT_RC=0 || CAT_RC=$?
[[ "$CAT_RC" -eq 2 ]] && ok "Catalyst destination exit 2" || fail_t "Catalyst destination rc=${CAT_RC}（應 2）"
grep -q "ios_build.sh --catalyst" <<<"$CAT_ERR" \
  && ok "錯誤訊息指向 ios_build.sh --catalyst" \
  || fail_t "錯誤訊息未指向替代入口: $CAT_ERR"

# ── 21. runner help/list/benchmark surface + tech-index anchors ──────────────
# 這些都是 parse-only 路徑：不得取得 build lock、啟動 xcodebuild，且 help/docs
# 必須同時描述三個 agent 會實際呼叫的入口。Anchor 斷言刻意放在 regression
# group 而非只依賴 acceptance 文字，避免 tech_index 重複/漏字時沒有近端訊號。
section "ios_test help/list/benchmark surface and tech-index anchors"
HELP_OUT="$($IOS_TEST --help 2>&1)" || HELP_OUT=""
grep -qF -- "--list" <<<"$HELP_OUT" \
  && ok "--help 列出 --list" || fail_t "--help 未列出 --list: $HELP_OUT"
grep -qF -- "--launch-benchmark" <<<"$HELP_OUT" \
  && ok "--help 列出 --launch-benchmark" || fail_t "--help 未列出 --launch-benchmark: $HELP_OUT"

UNIT_LIST="$($IOS_TEST --list 2>/dev/null)" || UNIT_LIST=""
grep -qxF -- "-only-testing:BooksAndVocabTests" <<<"$UNIT_LIST" \
  && ok "--list 只讀輸出 unit target selector" \
  || fail_t "--list 未輸出 unit selector: $UNIT_LIST"

BENCH_LIST="$($IOS_TEST --list --launch-benchmark 2>/dev/null)" || BENCH_LIST=""
grep -qxF -- "-only-testing:BooksAndVocabUITests/BooksAndVocabUITests/testLaunchPerformance" <<<"$BENCH_LIST" \
  && ok "--launch-benchmark --list 固定輸出 launch performance selector" \
  || fail_t "--launch-benchmark --list selector 漂移: $BENCH_LIST"

IOS_ROW="$(grep -F '| `ios_test.sh` |' "$WORKSPACE/docs/reference/tech_index.md" || true)"
KEYED_HITS="$(grep -oF 'keyed cache 於 build lock 內自動 LRU eviction' <<<"$IOS_ROW" || true)"
BENCH_HITS="$(grep -oF -- '--list / --launch-benchmark' <<<"$IOS_ROW" || true)"
KEYED_COUNT="$(wc -l <<<"$KEYED_HITS" | tr -d ' ')"
BENCH_COUNT="$(wc -l <<<"$BENCH_HITS" | tr -d ' ')"
[[ "$KEYED_COUNT" -eq 1 ]] \
  && ok "tech_index keyed-cache anchor 唯一" \
  || fail_t "tech_index keyed-cache anchor 出現 ${KEYED_COUNT} 次（應 1）"
[[ "$BENCH_COUNT" -eq 1 ]] \
  && ok "tech_index --list / --launch-benchmark anchor 唯一" \
  || fail_t "tech_index --list / --launch-benchmark anchor 出現 ${BENCH_COUNT} 次（應 1）"

# ── 22. UI evidence provenance + collision refusal wiring ───────────────────
section "UI evidence provenance and collision refusal wiring"
DIAGNOSTICS="$WORKSPACE/ios/BooksAndVocabUITests/Helpers/UITestDiagnostics.swift"
grep -qF 'nameForEvidenceArtifact' "$DIAGNOSTICS" \
  && ok "step screenshot filename 綁 test-case identity" \
  || fail_t "step screenshot 未綁 test-case identity，多 method run 會互相覆寫"
grep -qF '.withoutOverwriting' "$DIAGNOSTICS" \
  && ok "step screenshot collision fail closed" \
  || fail_t "step screenshot 仍可靜默覆寫既有 evidence"

for flag in '--source-commit' '--dataset-id' '--dataset-sha256' '--provenance-device' '--selector' '--variant'; do
  grep -qF -- "$flag" "$IOS_TEST" \
    && ok "contact-sheet provenance 傳遞 $flag" \
    || fail_t "contact-sheet provenance 缺 $flag"
done
grep -qF '${KG_UI_TEST_EXACT_SELECTOR:-$UI_TEST_FLOW_ID}' "$IOS_TEST" \
  && ok "exact selector 優先於 flow fallback" \
  || fail_t "manifest provenance 未接 exact selector"
grep -qF '${BASHPID:-$$}' "$IOS_TEST" \
  && ok "review root stem 含 process identity" \
  || fail_t "review root 仍只有秒級 timestamp，可被平行 run 碰撞"
grep -qF 'refusing to overwrite existing review root=' "$IOS_TEST" \
  && ok "review root collision 明確拒絕" \
  || fail_t "review root collision 仍可覆寫舊 evidence"
if grep -qxF 'build_ui_test_review_page' "$IOS_TEST"; then
  fail_t "UIreview 在 verdict final state 前被額外建立，第二次 publish 會撞自己的 root"
else
  ok "UIreview 只由 write_json_verdict 以 final result 建立"
fi

# ── 23. selector-list contract used by ops/ci_scope_router.sh admission ─────
# The router admits targeted iOS CI only from this exact output shape. If the
# list format drifts, router admission must fail closed instead of mis-parsing.
section "ios_test.sh --ui --list --file selector contract (CI admission)"
ADMIT_FILE="ios/BooksAndVocabUITests/OverviewFlowUITests.swift"
if [[ -f "$WORKSPACE/$ADMIT_FILE" ]]; then
  ADMIT_OUT="$(cd "$WORKSPACE" && "$IOS_TEST" --ui --list --file "$ADMIT_FILE" 2>/dev/null)" && ADMIT_RC=0 || ADMIT_RC=$?
  [[ "$ADMIT_RC" -eq 0 ]] \
    && ok "--ui --list --file 對含測試的 UITests 檔 exit 0" \
    || fail_t "--ui --list --file exit ${ADMIT_RC}（應 0）"

  ADMIT_SEL="$(grep -c '^-only-testing:' <<<"$ADMIT_OUT" || true)"
  ADMIT_BAD="$(grep -vcE '^-only-testing:BooksAndVocabUITests/[A-Za-z0-9_]+/[A-Za-z0-9_]+$|^\[ios_test\] matched [0-9]+ tests? in file ' <<<"$ADMIT_OUT" || true)"
  [[ "$ADMIT_SEL" -ge 1 ]] \
    && ok "輸出至少一個 selector（${ADMIT_SEL}）" \
    || fail_t "輸出沒有任何 -only-testing selector: $ADMIT_OUT"
  [[ "$ADMIT_BAD" -eq 0 ]] \
    && ok "每個 selector 都是 Target/Suite/Method，無 suite-only／雜訊行" \
    || fail_t "輸出含非 Target/Suite/Method 行（admission 必須退回 full）: $ADMIT_OUT"
  ADMIT_HDR="$(sed -nE 's/^\[ios_test\] matched ([0-9]+) tests? in file .*/\1/p' <<<"$ADMIT_OUT")"
  [[ -z "$ADMIT_HDR" || "$ADMIT_HDR" -eq "$ADMIT_SEL" ]] \
    && ok "matched N 標頭與 selector 行數一致" \
    || fail_t "matched 標頭 $ADMIT_HDR 與 selector 行數 $ADMIT_SEL 不一致"

  # Positional Suite/Method (what ios-quality passes) resolves to the very same
  # fully qualified selector, so the workflow runs what the router discovered.
  ADMIT_FIRST="$(grep -m1 '^-only-testing:' <<<"$ADMIT_OUT")"
  ADMIT_SUITE_METHOD="${ADMIT_FIRST#-only-testing:BooksAndVocabUITests/}"
  ADMIT_POS="$(cd "$WORKSPACE" && "$IOS_TEST" --ui --list "$ADMIT_SUITE_METHOD" 2>/dev/null)" || ADMIT_POS=""
  [[ "$ADMIT_POS" == "$ADMIT_FIRST" ]] \
    && ok "positional Suite/Method 解析為相同的 Target/Suite/Method selector" \
    || fail_t "positional $ADMIT_SUITE_METHOD → '$ADMIT_POS'（預期 '$ADMIT_FIRST'）"

  # End to end with the real discovery command (no stub): targeted.
  ADMIT_ROUTE="$(printf '%s\n' "$ADMIT_FILE" | "$WORKSPACE/ops/ci_scope_router.sh" --paths-stdin --format json)" || ADMIT_ROUTE=""
  [[ "$(jq -r '.ios_mode' <<<"$ADMIT_ROUTE" 2>/dev/null)" == targeted \
    && "$(jq -r '.ios_selectors | split(" ") | length' <<<"$ADMIT_ROUTE" 2>/dev/null)" -eq "$ADMIT_SEL" ]] \
    && ok "router 以真實 discovery 對單檔 UITests 選 targeted 且 selector 數相符" \
    || fail_t "router 真實 discovery 結果不符: $ADMIT_ROUTE"
else
  fail_t "$ADMIT_FILE 不存在，無法鎖定 admission selector 契約"
fi

# A file with no tests, a missing file and a helper file must never yield
# selectors: zero output + non-zero exit is what lets the router fall back.
for ADMIT_NEG in \
  "ios/BooksAndVocabUITests/UITestLaunchSupport.swift" \
  "ios/BooksAndVocabUITests/Helpers/UITestDiagnostics.swift" \
  "ios/BooksAndVocabUITests/NoSuchFileUITests.swift"; do
  ADMIT_NEG_OUT="$(cd "$WORKSPACE" && "$IOS_TEST" --ui --list --file "$ADMIT_NEG" 2>/dev/null)" && ADMIT_NEG_RC=0 || ADMIT_NEG_RC=$?
  if [[ "$ADMIT_NEG_RC" -ne 0 ]] && ! grep -q '^-only-testing:' <<<"$ADMIT_NEG_OUT"; then
    ok "無測試／缺檔 ${ADMIT_NEG}：exit ${ADMIT_NEG_RC} 且無 selector"
  else
    fail_t "${ADMIT_NEG} 應非零退出且無 selector（rc=${ADMIT_NEG_RC} out=${ADMIT_NEG_OUT}）"
  fi
done

# ── result ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
