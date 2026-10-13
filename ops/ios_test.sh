#!/usr/bin/env bash
# ios_test.sh — run iOS unit tests with clean pass/fail output
#
# Usage:
#   ./ops/ios_test.sh                             # run ALL tests in BooksAndVocabTests
#   ./ops/ios_test.sh testName1 testName2 ...     # run specific tests. A BARE method name is
#                                                 # reverse-looked-up to its OWN class/@Suite
#                                                 # container by scanning the current scope's
#                                                 # test dir (Swift Testing ids keep their
#                                                 # signature); zero matches exit 1 at PARSE
#                                                 # time instead of wasting a build+test round.
#                                                 # A zero match also re-scans the OTHER scope:
#                                                 # if the name really lives in the other target
#                                                 # (a missing --ui / --unit) the error names
#                                                 # that target/container and prints the exact
#                                                 # command to rerun. It still exits 1 — the
#                                                 # runner never silently switches scope.
#                                                 # The scan is non-recursive — tests in a
#                                                 # SUBDIRECTORY are not found; pass the
#                                                 # `Class/method` form, which is always a
#                                                 # pass-through, unchecked escape hatch.
#   ./ops/ios_test.sh -g "notebook"               # grep: run tests whose METHOD name OR
#                                                 # suite/container name (@Suite struct / class)
#                                                 # matches — `-g FooTests` runs the whole suite.
#                                                 # File names are NOT matched; repeat -g to OR
#                                                 # patterns together.
#   ./ops/ios_test.sh --file FooTests             # .swift suffix optional; bare type name also works
#   ./ops/ios_test.sh --ui testLaunchShowsAllTabs
#   ./ops/ios_test.sh --list                       # resolve selectors without lock/xcodebuild
#   ./ops/ios_test.sh --launch-benchmark
#   ./ops/ios_test.sh --ui --ui-launch-profile ui-smoke testLaunchShowsAllTabs
#   ./ops/ios_test.sh --ui --dataset <name>       # inject ops/fixtures/ui_worlds/<name>.json into the app (KG_FIXTURE_DATASET_DEFLATE_B64)
#   ./ops/ios_test.sh --ui --dataset-file <path>  # same, arbitrary dataset path
#   ./ops/ios_test.sh --all-targets               # run scheme test action, including UI tests
#   ./ops/ios_test.sh --coverage [--coverage-fail-under <percent>]
#   ./ops/ios_test.sh --device <name|UDID>        # target a specific simulator (parallel agents)
#   ./ops/ios_test.sh --destination '<xcodebuild destination>'   # full -destination override
#   ./ops/ios_test.sh --configuration Release  # Release-equivalent build/test provenance
#   ./ops/ios_test.sh --unit --xctestrun <path>   # test-without-building from products built by --prepare-cache (CI build-once, #3331); never compiles
#   ./ops/ios_test.sh --unit --lease              # auto-claim a pool simulator for this run (parallel agents)
#   KG_IOS_TEST_ALLOW_SHARED_SIM=1 ./ops/ios_test.sh ...         # explicit opt-out for single-machine debugging
#   KG_IOS_TEST_MAX_EXECUTION_TIME_ALLOWANCE=<seconds> ./ops/ios_test.sh --ui ... # bounded per-test timeout
#   KG_IOS_TEST_MAX_EXECUTION_TIME_ALLOWANCE=420 ./ops/ios_test.sh ... # raise XCTest max
#   ./ops/ios_test.sh --ui --visual ...                         # opt in to screenshots/video/UIreview
#
# Examples:
#   ./ops/ios_test.sh resolveNotebookId_emptyCandidate_returnsDefault
#   ./ops/ios_test.sh -g "sanitizeOutbox"
#   ./ops/ios_test.sh -g "triggerPipelines"
#
# Shares the same shlock + DerivedData as ios_build.sh for incremental builds.

set -euo pipefail

LOCK_FILE="${KG_IOS_BUILD_LOCK_FILE:-/tmp/kg-ios-build.lock}"   # override only for hermetic tests
# Shares the build lock with `ios_build.sh`, so it shares the same override:
# `--timeout` per call, `KG_IOS_BUILD_LOCK_TIMEOUT` for callers that cannot pass
# flags (see the note in ios_build.sh).
# NOTE (#2668): `--timeout` bounds ONLY lock waits (build / device / ui-video lock).
# It does NOT cap xcodebuild execution time; per-test limits come from XCTest's
# -test-timeouts-enabled allowance (KG_IOS_TEST_MAX_EXECUTION_TIME_ALLOWANCE) and the
# outer job/command timeout. A long --all-targets run can therefore exceed --timeout.
TIMEOUT="${KG_IOS_BUILD_LOCK_TIMEOUT:-600}"
POLL_INTERVAL=3
DEFAULT_SIMULATOR='iPhone 17 Pro Max'
DESTINATION=''            # resolved after arg parsing (see device resolution below)
DESTINATION_OVERRIDE=''   # set by --destination (full xcodebuild destination string)
DEVICE_OVERRIDE="${KG_IOS_TEST_DEVICE:-}"  # set by --device (name or UDID); enables per-agent simulators
AUTO_LEASE="${KG_IOS_TEST_AUTOLEASE:-0}"   # --lease: claim a pool simulator for this run, release on exit
# UI evidence runs include real Readium/WebKit startup and deliberate
# counterexample transitions. The old 120s cap overrode XCTest case allowances
# of 300–360s and classified valid flows as timeouts. Keep the ceiling bounded,
# while allowing the case-level allowance to express the actual flow budget.
MAX_TEST_EXECUTION_TIME_ALLOWANCE="${KG_IOS_TEST_MAX_EXECUTION_TIME_ALLOWANCE:-420}"
if [[ ! "$MAX_TEST_EXECUTION_TIME_ALLOWANCE" =~ ^[0-9]+$ || "$MAX_TEST_EXECUTION_TIME_ALLOWANCE" -lt 60 ]]; then
  echo "[ios_test] error: KG_IOS_TEST_MAX_EXECUTION_TIME_ALLOWANCE must be an integer >= 60" >&2
  exit 64
fi
LEASED_DEVICE=''                            # udid of an auto-leased simulator, released in cleanup
RESOLVED_DEVICE_UDID=''                     # exact UDID returned by simulator ensure-booted
LEASE_OWNER_TOKEN="kg-ios-test-$$-$(date +%s)-${RANDOM:-0}"
SIMULATOR_BOOT_SELECTOR=''
GREP_PATTERN=""
TEST_FILE=""
TEST_SCOPE="unit"
SPECIFIC_TESTS=()
LIST_ONLY=0
TEST_SCHEME="BooksAndVocab"
TEST_CACHE_ACTION=""
XCTESTRUN_OVERRIDE=""   # --xctestrun <path>: test-without-building from products another job built (#3331)
JSON_MODE=0
UI_LAUNCH_PROFILE="${KG_IOS_TEST_UI_LAUNCH_PROFILE:-}"
VISUAL_CAPTURE_ENABLED="${KG_IOS_VISUAL_CAPTURE:-0}"
LAUNCH_BENCHMARK=0
COVERAGE_ENABLED=0
COVERAGE_FAIL_UNDER=""
COVERAGE_TARGET="${KG_IOS_TEST_COVERAGE_TARGET:-BooksAndVocab}"
UI_FIXTURE_DATASET_NAME=""
UI_FIXTURE_DATASET_FILE=""
UI_FIXTURE_DATASET_DEFLATE_B64=""
STAGED_DATASET_XCTESTRUN=""
UI_TEST_REVIEW_ROOT=""
UI_TEST_REVIEW_HTML=""
CONFIGURATION="Debug"
EVIDENCE_FIXED_CLOCK=""
EVIDENCE_DATASET_ID=""
EVIDENCE_DATASET_SHA256=""
EVIDENCE_LOCALE=""
EVIDENCE_TIMEZONE=""
EVIDENCE_APPEARANCE=""
EVIDENCE_KIND="release-equivalent-simulator"
P9_REVIEW_CALENDAR_SELECTOR="FixtureDatasetUITests/testReviewCalendarRequiredEvidenceUsesStableSelectors"
P9_PROOF_RETRIEVAL_STATUS=0
LIVE_DEMO=0
DEMO_ACCOUNT_IDENTITY_SHA256=""
INCONCLUSIVE_REASON=""

build_ui_test_variant_id() {
  local parts=()
  if [[ -n "$UI_FIXTURE_DATASET_NAME" ]]; then
    parts+=("dataset:$UI_FIXTURE_DATASET_NAME")
  elif [[ -n "$UI_FIXTURE_DATASET_FILE" ]]; then
    parts+=("dataset-file:$(basename "$UI_FIXTURE_DATASET_FILE")")
  fi
  if [[ -n "$UI_LAUNCH_PROFILE" ]]; then
    parts+=("profile:$UI_LAUNCH_PROFILE")
  fi
  if [[ ${#parts[@]} -eq 0 ]]; then
    printf 'default'
    return
  fi
  local joined="${parts[0]}"
  local part
  for part in "${parts[@]:1}"; do
    joined+="+$part"
  done
  printf '%s' "$joined"
}
UI_TEST_FLOW_ID=""
UI_TEST_VARIANT_ID=""

# `generic/platform=iOS` is used by the live-only compile gate as a compile
# target, never as an install/run destination. Compilability is independent of
# a developer signing identity, so that one path builds unsigned. Exact-device
# runs keep normal signing because their products must be installable.
ios_test_signing_mode() {
  local destination="$1"
  if [[ "$destination" == "generic/platform=iOS" ]]; then
    printf 'unsigned-generic-device\n'
  elif [[ "$destination" == *"platform=iOS"* && "$destination" == *"Simulator"* ]]; then
    printf 'simulator\n'
  elif [[ "$destination" == *"platform=iOS"* ]]; then
    printf 'signed-device\n'
  else
    printf 'default\n'
  fi
}

ios_test_signing_args() {
  if [[ "$(ios_test_signing_mode "$1")" == "unsigned-generic-device" ]]; then
    printf '%s\n' "CODE_SIGNING_ALLOWED=NO" "CODE_SIGNING_REQUIRED=NO"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      # 印整段 header comment（到第一個非 # 行為止），不再硬編行號（曾因
      # header 增行而把尾段 usage 默默截掉）。
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0
      ;;
    -g|--grep)
      # 重複 -g 累積成 OR regex（歷史 footgun：後者無聲覆蓋前者 → 以為跑了
      # 兩個測試實際只跑一個）。pattern 是 awk ERE，頂層 | 即聯集。
      # 空 pattern 直接拒絕：累積後的空 alternative 會匹配一切（silent broadening）。
      if [[ -z "$2" ]]; then
        echo "[ios_test] error: -g/--grep 不接受空 pattern" >&2
        exit 2
      fi
      if [[ -n "$GREP_PATTERN" ]]; then
        GREP_PATTERN="$GREP_PATTERN|$2"
      else
        GREP_PATTERN="$2"
      fi
      shift 2 ;;
    --file)
      # 重複 --file 只會保留最後一個、靜默丟棄其餘 → 曾誘發 false-green（以為跑了多檔，
      # 其實只跑最後一檔）。檔名不是 regex、沒有聯集載體，故報錯而非像 -g 那樣累積。
      if [[ -n "$TEST_FILE" ]]; then
        echo "[ios_test] error: --file 只能指定一次（重複會靜默覆蓋）。多檔請改用重複 -g <方法名>（自動 OR）或 --grep '<A>|<B>'，或分多次執行。" >&2
        exit 2
      fi
      TEST_FILE="$2"; shift 2 ;;
    --unit) TEST_SCOPE="unit"; shift ;;
    --ui) TEST_SCOPE="ui"; shift ;;
    --all-targets|--scheme) TEST_SCOPE="all"; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --device) DEVICE_OVERRIDE="$2"; shift 2 ;;        # name or UDID; pick a specific simulator
    --destination) DESTINATION_OVERRIDE="$2"; shift 2 ;;  # full xcodebuild -destination override
    --lease) AUTO_LEASE=1; shift ;;                   # claim a pool simulator for this run (parallel agents)
    --list) LIST_ONLY=1; shift ;;   # dry-run: print resolved -only-testing flags, no xcodebuild
    --prepare-cache) TEST_CACHE_ACTION="prepare"; shift ;;
    --xctestrun) XCTESTRUN_OVERRIDE="${2:?--xctestrun needs a path to a built .xctestrun}"; shift 2 ;;
    --cache-status) TEST_CACHE_ACTION="status"; shift ;;
    --clean-cache) TEST_CACHE_ACTION="clean"; shift ;;
    --json) JSON_MODE=1; shift ;;
    --visual|--visual-capture) VISUAL_CAPTURE_ENABLED=1; shift ;;
    --ui-launch-profile) UI_LAUNCH_PROFILE="$2"; shift 2 ;;
    --launch-benchmark) LAUNCH_BENCHMARK=1; shift ;;
    --coverage) COVERAGE_ENABLED=1; shift ;;
    --coverage-fail-under) COVERAGE_ENABLED=1; COVERAGE_FAIL_UNDER="$2"; shift 2 ;;
    --dataset) UI_FIXTURE_DATASET_NAME="${2:?--dataset needs value}"; shift 2 ;;
    --dataset-file) UI_FIXTURE_DATASET_FILE="${2:?--dataset-file needs value}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:?--configuration needs Debug or Release}"; shift 2 ;;
    --fixed-clock) EVIDENCE_FIXED_CLOCK="${2:?--fixed-clock needs RFC3339 value}"; shift 2 ;;
    --evidence-locale) EVIDENCE_LOCALE="${2:?--evidence-locale needs value}"; shift 2 ;;
    --evidence-timezone) EVIDENCE_TIMEZONE="${2:?--evidence-timezone needs value}"; shift 2 ;;
    --evidence-appearance) EVIDENCE_APPEARANCE="${2:?--evidence-appearance needs light or dark}"; shift 2 ;;
    --evidence-kind) EVIDENCE_KIND="${2:?--evidence-kind needs value}"; shift 2 ;;
    --live-demo) LIVE_DEMO=1; shift ;;
    --live-demo-account-identity-sha256) DEMO_ACCOUNT_IDENTITY_SHA256="${2:?--live-demo-account-identity-sha256 needs SHA256}"; shift 2 ;;
    *) SPECIFIC_TESTS+=("$1"); shift ;;
  esac
done

if [[ "$CONFIGURATION" != "Debug" && "$CONFIGURATION" != "Release" ]]; then
  echo "[ios_test] error: --configuration must be Debug or Release" >&2
  exit 2
fi
if [[ "$EVIDENCE_KIND" == "exact-device" && ( "$DESTINATION_OVERRIDE" != *"platform=iOS,"* || "$DESTINATION_OVERRIDE" == *"Simulator"* ) ]]; then
  echo "[ios_test] error: --evidence-kind exact-device requires --destination platform=iOS,id=<physical-UDID>" >&2
  exit 2
fi
if [[ "$LIVE_DEMO" -eq 1 ]]; then
  if [[ "$TEST_SCOPE" != "ui" || "$CONFIGURATION" != "Release" || "$EVIDENCE_KIND" != "exact-device" || ! "$DEMO_ACCOUNT_IDENTITY_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "[ios_test] error: --live-demo requires UI scope, Release exact-device, and normalized account identity SHA256" >&2
    exit 2
  fi
  if [[ -n "$UI_FIXTURE_DATASET_NAME" || -n "$UI_FIXTURE_DATASET_FILE" ]]; then
    echo "[ios_test] error: --live-demo cannot use fixture dataset" >&2
    exit 2
  fi
  if [[ "${#SPECIFIC_TESTS[@]}" -ne 1 || "${SPECIFIC_TESTS[0]:-}" != "testLiveDemoAccountHasProEntitlement" ]]; then
    echo "[ios_test] error: --live-demo runs only testLiveDemoAccountHasProEntitlement" >&2
    exit 2
  fi
fi

if [[ -n "$COVERAGE_FAIL_UNDER" && ! "$COVERAGE_FAIL_UNDER" =~ ^([0-9]+)(\.[0-9]+)?$ ]]; then
  echo "[ios_test] error: --coverage-fail-under must be numeric percent (0..100)" >&2
  exit 2
fi
if [[ -n "$COVERAGE_FAIL_UNDER" ]]; then
  awk -v value="$COVERAGE_FAIL_UNDER" 'BEGIN { exit !(value >= 0 && value <= 100) }' || {
    echo "[ios_test] error: --coverage-fail-under must be between 0 and 100" >&2
    exit 2
  }
fi

COVERAGE_XCODEBUILD_ARGS=()
if [[ "$COVERAGE_ENABLED" -eq 1 ]]; then
  COVERAGE_XCODEBUILD_ARGS=(-enableCodeCoverage YES)
fi

# Resolve the simulator destination. Precedence: --destination (full override)
# > --device (name|UDID) > default. A UDID-shaped value targets `id=`, anything
# else `name=`. SIMULATOR_BOOT_SELECTOR feeds `simulator ensure-booted` and
# accepts a name or UDID directly. This makes the script target-agnostic so
# parallel agents can each run on their own leased simulator.
if [[ -n "$DESTINATION_OVERRIDE" ]]; then
  DESTINATION="$DESTINATION_OVERRIDE"
  SIMULATOR_BOOT_SELECTOR="${DEVICE_OVERRIDE:-$DEFAULT_SIMULATOR}"
elif [[ -n "$DEVICE_OVERRIDE" ]]; then
  SIMULATOR_BOOT_SELECTOR="$DEVICE_OVERRIDE"
  if [[ "$DEVICE_OVERRIDE" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    DESTINATION="platform=iOS Simulator,id=$DEVICE_OVERRIDE"
  else
    DESTINATION="platform=iOS Simulator,name=$DEVICE_OVERRIDE"
  fi
else
  DESTINATION="platform=iOS Simulator,name=$DEFAULT_SIMULATOR"
  SIMULATOR_BOOT_SELECTOR="$DEFAULT_SIMULATOR"
fi

IOS_TEST_SIGNING_ARGS=()
while IFS= read -r signing_arg; do
  [[ -n "$signing_arg" ]] && IOS_TEST_SIGNING_ARGS+=("$signing_arg")
done < <(ios_test_signing_args "$DESTINATION")

if [[ "$DESTINATION" == *"Mac Catalyst"* || "$DESTINATION" == *"platform=macOS"* ]]; then
  echo "[ios_test] error: Mac Catalyst / macOS destinations are not supported by ios_test.sh" >&2
  echo "[ios_test]   ios_test.sh is iOS-only: its cache and product resolver do not understand the Catalyst bundle layout" >&2
  echo "[ios_test]   use ops/ios_build.sh --catalyst for the Catalyst compile gate; it supplies the required no-signing settings" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCODEPROJ="$PROJECT_ROOT/ios/BooksAndVocab.xcodeproj"
IOS_OPS="$SCRIPT_DIR/ios_ops.sh"
# Evidence wrappers may pin every per-run log/result/snapshot below one unique
# staging root. New visual runs use a short-lived temp root; the in-repo path is
# reserved for an explicit retained report. UI evidence runs always receive a
# short-lived screenshot directory for app-written proof; --visual (or
# KG_IOS_VISUAL_CAPTURE=1) additionally opts into video and visual review pages.
IOS_ARTIFACT_ROOT=""
if [[ -n "${KG_IOS_ARTIFACT_ROOT:-}" ]]; then
  artifact_root_candidate="$KG_IOS_ARTIFACT_ROOT"
  if [[ "$artifact_root_candidate" != /* ]]; then
    artifact_root_candidate="$PROJECT_ROOT/$artifact_root_candidate"
  fi
  mkdir -p "$artifact_root_candidate"
  IOS_ARTIFACT_ROOT="$(cd "$artifact_root_candidate" && pwd -P)"
  tmp_root_real="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  ephemeral_root_real=""
  if [[ -n "${KG_IOS_EPHEMERAL_ROOT:-}" ]]; then
    mkdir -p "$KG_IOS_EPHEMERAL_ROOT"
    ephemeral_root_real="$(cd "$KG_IOS_EPHEMERAL_ROOT" && pwd -P)"
  fi
  artifact_root_allowed=0
  case "$IOS_ARTIFACT_ROOT" in
    "$PROJECT_ROOT"/build/ios-report/retained|"$PROJECT_ROOT"/build/ios-report/retained/*) artifact_root_allowed=1 ;;
    "$tmp_root_real"/kg-ios-*/*) artifact_root_allowed=1 ;; # ephemeral run-owned staging
  esac
  if [[ -n "$ephemeral_root_real" ]]; then
    case "$IOS_ARTIFACT_ROOT" in
      "$ephemeral_root_real"|"$ephemeral_root_real"/*) artifact_root_allowed=1 ;;
    esac
  fi
  if [[ "$artifact_root_allowed" -ne 1 ]]; then
    echo "[ios_test] error: KG_IOS_ARTIFACT_ROOT must be an explicit retained report root or an ephemeral /tmp run root: $IOS_ARTIFACT_ROOT" >&2
    exit 65
  fi
fi
artifact_temp_file() {
  local stem="${1:-ios-test-artifact}"
  if [[ -n "$IOS_ARTIFACT_ROOT" ]]; then
    mkdir -p "$IOS_ARTIFACT_ROOT/tmp"
    mktemp "$IOS_ARTIFACT_ROOT/tmp/${stem}.XXXXXX"
  else
    mktemp
  fi
}
artifact_temp_dir() {
  local stem="${1:-ios-test-artifact}"
  if [[ -n "$IOS_ARTIFACT_ROOT" ]]; then
    mkdir -p "$IOS_ARTIFACT_ROOT/tmp"
    mktemp -d "$IOS_ARTIFACT_ROOT/tmp/${stem}.XXXXXX"
  else
    mktemp -d "${TMPDIR:-/tmp}/${stem}.XXXXXX"
  fi
}
# shellcheck source=lib/ios_test_cache_root.sh
source "$SCRIPT_DIR/lib/ios_test_cache_root.sh"
# Keep content-keyed test products at the git-common anchor so linked
# worktrees share one bounded cache instead of retaining gigabytes each.
TEST_CACHE_ROOT="$(kg_ios_test_cache_root "$PROJECT_ROOT")"
UV_BIN="${UV_BIN:-}"
if [[ -z "$UV_BIN" ]]; then
  if [[ -x "$HOME/.local/bin/uv" ]]; then
    UV_BIN="$HOME/.local/bin/uv"
  else
    UV_BIN="uv"
  fi
fi

# shellcheck source=lib/ios_test_discovery.sh
source "$SCRIPT_DIR/lib/ios_test_discovery.sh"
# shellcheck source=lib/ios_build_progress.sh
source "$SCRIPT_DIR/lib/ios_build_progress.sh"
# shellcheck source=lib/ios_lock_wait.sh
source "$SCRIPT_DIR/lib/ios_lock_wait.sh"
# shellcheck source=lib/ios_test_failure_verdict.sh
source "$SCRIPT_DIR/lib/ios_test_failure_verdict.sh"
# shellcheck source=lib/ios_cache_evict.sh
source "$SCRIPT_DIR/lib/ios_cache_evict.sh"
# shellcheck source=lib/ios_disk_budget.sh
source "$SCRIPT_DIR/lib/ios_disk_budget.sh"
# shellcheck source=lib/ios_test_video_archive.sh
source "$SCRIPT_DIR/lib/ios_test_video_archive.sh"
# shellcheck source=lib/ios_run_verdict.sh
source "$SCRIPT_DIR/lib/ios_run_verdict.sh"
# shellcheck source=lib/signal_traps.sh
source "$SCRIPT_DIR/lib/signal_traps.sh"
# shellcheck source=lib/project_python.sh
source "$SCRIPT_DIR/lib/project_python.sh"
# shellcheck source=lib/fixture_dataset_env.sh
source "$SCRIPT_DIR/lib/fixture_dataset_env.sh"
# shellcheck source=lib/ios_xctestrun_cache.sh
source "$SCRIPT_DIR/lib/ios_xctestrun_cache.sh"
# shellcheck source=lib/ios_swiftpm_cache.sh
source "$SCRIPT_DIR/lib/ios_swiftpm_cache.sh"
# Optional run-metrics logging — additive, must never break the test run.
METRICS_LIB="$SCRIPT_DIR/lib/ios_run_metrics.sh"
[[ -f "$METRICS_LIB" ]] && source "$METRICS_LIB"

[[ -d "$XCODEPROJ" ]] || { echo "error: $XCODEPROJ not found" >&2; exit 1; }
kg_ios_swiftpm_configure "$PROJECT_ROOT"

CALLER="${WORKTREE_BRANCH:-$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo 'unknown')}"

ios_test_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

ios_test_build_input_paths() {
  {
    printf '%s\n' \
      "ios/BooksAndVocab.xcodeproj/project.pbxproj" \
      "ios/BooksAndVocab.xcodeproj/xcshareddata/xcschemes/BooksAndVocab.xcscheme" \
      "ios/BooksAndVocab.xcodeproj/xcshareddata/xcschemes/BooksAndVocabUnitTests.xcscheme" \
      "ios/BooksAndVocab.xcodeproj/xcshareddata/xcschemes/BooksAndVocabUITests.xcscheme" \
      "ios/BooksAndVocab.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    find ios/BooksAndVocab ios/BooksAndVocabTests ios/BooksAndVocabUITests \
      -type f \( -name '*.swift' -o -name '*.plist' \) -print
  } | sort -u
}

ios_test_build_cache_key() {
  local xcode_version
  xcode_version="$(xcodebuild -version 2>/dev/null || true)"
  # Key on platform+arch, NOT the specific device name/UDID. build-for-testing
  # products are per (platform, arch, configuration) and identical across
  # simulators of the same platform, so a pool of leased devices shares ONE warm
  # cache instead of each device fragmenting its own. A genuinely different
  # platform (e.g. platform=iOS vs platform=iOS Simulator) still gets a distinct
  # key; Mac Catalyst is rejected before this cache path is reached.
  local platform_token
  platform_token="$(printf '%s' "$DESTINATION" | sed -n 's/.*platform=\([^,]*\).*/\1/p' | tr '[:upper:] ' '[:lower:]-')"
  [[ -n "$platform_token" ]] || platform_token="unknown"
  ios_xctestrun_cache_build_key \
    "$PROJECT_ROOT" \
    "$platform_token" \
    "$(uname -m)" \
    "$TEST_SCOPE" \
    "$TEST_SCHEME" \
    "$CONFIGURATION" \
    "$COVERAGE_ENABLED" \
    "$(ios_test_signing_mode "$DESTINATION")" \
    "$xcode_version" \
    < <(ios_test_build_input_paths)
}

ios_test_derived_data_root() {
  local cache_key
  cache_key="$(ios_test_build_cache_key)"
  mkdir -p "$TEST_CACHE_ROOT"
  printf '%s/%s\n' "$TEST_CACHE_ROOT" "$cache_key"
}

ios_test_find_xctestrun() {
  if ! declare -F ios_xctestrun_cache_find >/dev/null 2>&1; then
    source "${KG_IOS_XCTESTRUN_CACHE_LIB:?ios xctestrun cache library is not loaded}"
  fi
  ios_xctestrun_cache_find "$1"
}

ios_test_list_xctestrun_artifacts() {
  if ! declare -F ios_xctestrun_cache_list >/dev/null 2>&1; then
    source "${KG_IOS_XCTESTRUN_CACHE_LIB:?ios xctestrun cache library is not loaded}"
  fi
  ios_xctestrun_cache_list "$1"
}

# Device vs simulator is decided by the destination's PLATFORM, not by its
# punctuation. The old predicate required a literal `platform=iOS,` — with the
# trailing comma — so `generic/platform=iOS` (no comma; used by the live-only
# Release compile gate and by ios_release.sh) silently fell through to the
# simulator SDK. That was a two-way error: a complete Release-iphoneos cache
# read as not-ready, AND Release-iphonesimulator products would have counted as
# proof of a device build. Match `platform=iOS` anywhere and exclude Simulator,
# which covers `generic/platform=iOS`, `platform=iOS,id=<udid>` and bare
# `platform=iOS`, while `platform=iOS Simulator...` stays on the simulator SDK.
ios_test_sdk_suffix() {
  if [[ "$DESTINATION" == *"platform=iOS"* && "$DESTINATION" != *"Simulator"* ]]; then
    printf 'iphoneos\n'
  else
    printf 'iphonesimulator\n'
  fi
}

ios_test_cached_products_ready() {
  if ! declare -F ios_xctestrun_cache_products_ready >/dev/null 2>&1; then
    source "${KG_IOS_XCTESTRUN_CACHE_LIB:?ios xctestrun cache library is not loaded}"
  fi
  ios_xctestrun_cache_products_ready \
    "$1" \
    "$CONFIGURATION" \
    "$(ios_test_sdk_suffix)" \
    "$TEST_SCOPE"
}

# A build-for-testing that is interrupted (INT/TERM) or fails mid-write leaves
# the product bundle DIRECTORIES in place but their contents incomplete, which
# the -d checks above cannot distinguish from a good build. The sentinel below is
# written (under the build lock) ONLY after a build verifiably completes, so hit
# detection and the rebuild double-check require it — a poisoned/partial cache is
# never treated as ready and is rebuilt instead of served to parallel agents.
IOS_TEST_CACHE_SENTINEL=".kg-test-cache-complete"
ios_test_cache_is_complete() {
  if ! declare -F ios_xctestrun_cache_is_complete >/dev/null 2>&1; then
    source "${KG_IOS_XCTESTRUN_CACHE_LIB:?ios xctestrun cache library is not loaded}"
  fi
  # The SwiftPM clone dir is the only package-source root outside the worktree
  # and the keyed DerivedData root (see ios_xctestrun_cache_source_path_valid).
  ios_xctestrun_cache_is_complete \
    "$DERIVED_DATA_ROOT/$IOS_TEST_CACHE_SENTINEL" \
    "$1" \
    "$CONFIGURATION" \
    "$(ios_test_sdk_suffix)" \
    "$TEST_SCOPE" \
    "${KG_IOS_SWIFTPM_CACHE_DIR:-}"
}

# --- Build -only-testing flags ---
ONLY_FLAGS=()
TEST_TARGET="BooksAndVocabTests"
TEST_DIR="$PROJECT_ROOT/ios/BooksAndVocabTests"

case "$TEST_SCOPE" in
  unit)
    TEST_TARGET="BooksAndVocabTests"
    TEST_DIR="$PROJECT_ROOT/ios/BooksAndVocabTests"
    TEST_SCHEME="BooksAndVocabUnitTests"
    ;;
  ui)
    TEST_TARGET="BooksAndVocabUITests"
    TEST_DIR="$PROJECT_ROOT/ios/BooksAndVocabUITests"
    TEST_SCHEME="BooksAndVocabUITests"
    ;;
  all)
    TEST_TARGET=""
    TEST_SCHEME="BooksAndVocab"
    ;;
  *)
    echo "[ios_test] internal error: unknown test scope '$TEST_SCOPE'" >&2
    exit 2
    ;;
esac

if [[ -n "$GREP_PATTERN" && -n "$TEST_FILE" ]]; then
  echo "[ios_test] error: --file and --grep cannot be combined" >&2
  exit 1
fi

if [[ "$TEST_SCOPE" == "all" && ( -n "$GREP_PATTERN" || -n "$TEST_FILE" || ${#SPECIFIC_TESTS[@]} -gt 0 ) ]]; then
  echo "[ios_test] error: --all-targets cannot be combined with --file, --grep, or specific tests" >&2
  exit 1
fi

if [[ "$LAUNCH_BENCHMARK" -eq 1 && ( -n "$GREP_PATTERN" || -n "$TEST_FILE" || ${#SPECIFIC_TESTS[@]} -gt 0 || "$TEST_SCOPE" == "all" ) ]]; then
  echo "[ios_test] error: --launch-benchmark cannot be combined with --all-targets, --file, --grep, or specific tests" >&2
  exit 1
fi

if [[ -n "$UI_LAUNCH_PROFILE" && "$TEST_SCOPE" == "unit" && "$LAUNCH_BENCHMARK" -eq 0 ]]; then
  echo "[ios_test] error: --ui-launch-profile requires --ui or --all-targets" >&2
  exit 1
fi

if [[ -n "$UI_FIXTURE_DATASET_NAME" && -n "$UI_FIXTURE_DATASET_FILE" ]]; then
  echo "[ios_test] error: choose either --dataset or --dataset-file" >&2
  exit 1
fi
if [[ -n "$UI_FIXTURE_DATASET_NAME" ]]; then
  UI_FIXTURE_DATASET_FILE="$PROJECT_ROOT/ops/fixtures/ui_worlds/$UI_FIXTURE_DATASET_NAME.json"
fi
if [[ ( "$TEST_SCOPE" == "ui" || "$TEST_SCOPE" == "all" ) && -z "$UI_FIXTURE_DATASET_FILE" && "$LIVE_DEMO" -eq 0 && "$LIST_ONLY" -eq 0 && -z "$TEST_CACHE_ACTION" ]]; then
  # --all-targets 含 UI target：無 dataset 時 UI 測試對空世界大量失敗（#2668），與 --ui 同守。
  scope_flag="--ui"; [[ "$TEST_SCOPE" == "all" ]] && scope_flag="--all-targets"
  echo "[ios_test] error: $scope_flag requires --dataset <name> or --dataset-file <path> (UI World is the single source of truth)" >&2
  available_worlds="$(cd "$PROJECT_ROOT/ops/fixtures/ui_worlds" 2>/dev/null && ls -- *.json 2>/dev/null | sed 's/\.json$//' | paste -sd ' ' - || true)"
  echo "[ios_test] available datasets (ops/fixtures/ui_worlds/): ${available_worlds:-none}" >&2
  exit 1
fi
if [[ -n "$UI_FIXTURE_DATASET_FILE" ]]; then
  # 限 --ui／--all-targets：UI World env 會被 app 內 FixtureDatasetStore 全程讀取。
  if [[ "$TEST_SCOPE" != "ui" && "$TEST_SCOPE" != "all" ]]; then
    echo "[ios_test] error: --dataset/--dataset-file requires --ui or --all-targets" >&2
    exit 1
  fi
  # --list / cache action 不會執行 staging，silent ignore 會誤導「dataset 已生效」。
  if [[ "$LIST_ONLY" -eq 1 || -n "$TEST_CACHE_ACTION" ]]; then
    echo "[ios_test] error: --dataset/--dataset-file cannot be combined with --list or cache actions (dataset only applies to an actual test run)" >&2
    exit 1
  fi
  if [[ ! -f "$UI_FIXTURE_DATASET_FILE" ]]; then
    echo "[ios_test] error: dataset file not found: $UI_FIXTURE_DATASET_FILE" >&2
    exit 1
  fi
  if ! python_bin="$(kg_project_python_bin "$PROJECT_ROOT")" || \
     ! "$python_bin" "$PROJECT_ROOT/ops/ui_world_manifest.py" validate "$UI_FIXTURE_DATASET_FILE" --label "UITest UI World dataset" >/dev/null; then
    exit 1
  fi
  EVIDENCE_DATASET_ID="$(jq -r '.datasetID // empty' "$UI_FIXTURE_DATASET_FILE")"
  EVIDENCE_DATASET_SHA256="$(shasum -a 256 "$UI_FIXTURE_DATASET_FILE" | awk '{print $1}')"
  # deflate+base64（非 plaintext base64）：>1MB world 會撐爆 spawn env block，
  # app 端會靜默看不到 dataset（見 ops/lib/fixture_dataset_env.sh）。
  if ! UI_FIXTURE_DATASET_DEFLATE_B64="$(kg_fixture_dataset_deflate_b64 "$UI_FIXTURE_DATASET_FILE")" \
     || [[ -z "$UI_FIXTURE_DATASET_DEFLATE_B64" ]]; then
    echo "[ios_test] error: failed to deflate-compress dataset file: $UI_FIXTURE_DATASET_FILE" >&2
    exit 1
  fi
fi

if [[ -n "$TEST_CACHE_ACTION" && ( "$LIST_ONLY" -eq 1 || -n "$GREP_PATTERN" || -n "$TEST_FILE" || ${#SPECIFIC_TESTS[@]} -gt 0 ) ]]; then
  echo "[ios_test] error: cache actions cannot be combined with --list, --file, --grep, or specific tests" >&2
  exit 1
fi

# --xctestrun (CI build-once, #3331): test-without-building from products another job
# built with --prepare-cache. Every refusal happens here, before the simulator, the
# build lock or xcodebuild, and this path never compiles.
validate_xctestrun_override() {
  if [[ "$LIST_ONLY" -eq 1 || -n "$TEST_CACHE_ACTION" || "$LAUNCH_BENCHMARK" -eq 1 ]]; then
    echo "[ios_test] error: --xctestrun cannot be combined with --list, --launch-benchmark, or cache actions" >&2
    exit 1
  fi
  if [[ ! -f "$XCTESTRUN_OVERRIDE" ]]; then
    echo "[ios_test] error: --xctestrun file not found: $XCTESTRUN_OVERRIDE" >&2
    exit 1
  fi
  if ! ios_test_cached_products_ready "$XCTESTRUN_OVERRIDE"; then
    echo "[ios_test] error: --xctestrun products are incomplete for scope=$TEST_SCOPE configuration=$CONFIGURATION sdk=$(ios_test_sdk_suffix): $XCTESTRUN_OVERRIDE" >&2
    exit 1
  fi
}
[[ -z "$XCTESTRUN_OVERRIDE" ]] || validate_xctestrun_override

if [[ -n "$TEST_FILE" ]]; then
  if [[ "$TEST_FILE" = /* ]]; then
    FILE_PATH="$TEST_FILE"
  elif [[ "$TEST_FILE" == */* ]]; then
    FILE_PATH="$PROJECT_ROOT/$TEST_FILE"
  else
    FILE_PATH="$TEST_DIR/$TEST_FILE"
  fi
  # Tolerant resolution: agents routinely pass a type/suite name ("FooTests")
  # instead of the on-disk filename ("FooTests.swift"), since Swift convention
  # makes them identical bar the extension. Fall back to appending .swift, then
  # to a stem search under the test dir, before failing.
  if [[ ! -f "$FILE_PATH" ]]; then
    if [[ "$FILE_PATH" != *.swift && -f "$FILE_PATH.swift" ]]; then
      FILE_PATH="$FILE_PATH.swift"
    else
      stem="$(basename "$TEST_FILE")"; stem="${stem%.swift}"
      stem_matches=()
      while IFS= read -r m; do stem_matches+=("$m"); done < <(find "$TEST_DIR" -type f -name "$stem.swift" 2>/dev/null)
      if [[ "${#stem_matches[@]}" -gt 1 ]]; then
        echo "[ios_test] '$TEST_FILE' is ambiguous — ${#stem_matches[@]} files match '$stem.swift':" >&2
        printf '  %s\n' "${stem_matches[@]}" >&2
        echo "[ios_test] pass a path-qualified --file to disambiguate" >&2
        exit 1
      fi
      [[ "${#stem_matches[@]}" -eq 1 ]] && FILE_PATH="${stem_matches[0]}"
    fi
  fi
  [[ -f "$FILE_PATH" ]] || { echo "[ios_test] test file not found: $TEST_FILE (tried .swift suffix and stem search under $TEST_DIR)" >&2; exit 1; }
  UI_TEST_FLOW_ID="$(basename "$FILE_PATH" .swift)"
  while IFS= read -r flag; do
    [[ -n "$flag" ]] && ONLY_FLAGS+=("$flag")
  done < <(discover_file_only_flags "$FILE_PATH" "" "$TEST_TARGET")
  if [[ ${#ONLY_FLAGS[@]} -eq 0 ]]; then
    echo "[ios_test] no tests discovered in file '$TEST_FILE'" >&2
    exit 1
  fi
  echo "[ios_test] matched ${#ONLY_FLAGS[@]} tests in file '$TEST_FILE' ($TEST_TARGET)"
elif [[ -n "$GREP_PATTERN" ]]; then
  UI_TEST_FLOW_ID="$GREP_PATTERN"
  # Auto-discover test funcs matching the pattern, attributing each func to its
  # OWN enclosing top-level container (struct / @Suite struct / class). See
  # lib/ios_test_discovery.sh for the discovery contract.
  while IFS= read -r flag; do
    [[ -n "$flag" ]] && ONLY_FLAGS+=("$flag")
  done < <(discover_only_flags "$TEST_DIR" "$GREP_PATTERN" "$TEST_TARGET")
  if [[ ${#ONLY_FLAGS[@]} -eq 0 ]]; then
    echo "[ios_test] no tests matching pattern '$GREP_PATTERN'" >&2
    echo "[ios_test] 注意：-g 匹配測試「方法名」（func/@Test）與「suite/容器名」（@Suite struct/class），不匹配檔名。" >&2
    echo "[ios_test] 確認名稱 → --list 搭配更寬的 pattern；單一檔案 → --file <TypeName>（.swift 可省）。" >&2
    exit 1
  fi
  echo "[ios_test] matched ${#ONLY_FLAGS[@]} tests for pattern '$GREP_PATTERN' ($TEST_TARGET)"
elif [[ ${#SPECIFIC_TESTS[@]} -gt 0 ]]; then
  for t in "${SPECIFIC_TESTS[@]}"; do
    if [[ "$t" == */* ]]; then
      # 明確 Class/method 一律直通：呼叫者得以指向 awk discovery 看不到的東西。
      ONLY_FLAGS+=("-only-testing:$TEST_TARGET/$t")
      continue
    fi
    # 裸方法名反查自身容器。硬拼 $TEST_TARGET/$TEST_TARGET/ 會讓所有不住在
    # 「與 target 同名 class」裡的測試 0 匹配，Swift Testing 還會缺簽名——兩者
    # 都要跑完一整輪 build+test 才被尾端 zero-executed guard 抓到。
    resolved=()
    while IFS= read -r flag; do
      [[ -n "$flag" ]] && resolved+=("$flag")
    done < <(discover_only_flags "$TEST_DIR" "^${t}$" "$TEST_TARGET")
    if [[ ${#resolved[@]} -eq 0 ]]; then
      echo "[ios_test] no test method named '$t' under $TEST_DIR ($TEST_TARGET)" >&2
      # 「本 scope 找不到」有兩個成因，對操作者是完全不同的兩件事：名字真的不存在，
      # 或名字存在但住在另一個 target（少給一個 --ui / --unit）。不分辨就等於對後者
      # 說謊——它存在。所以在放棄之前先掃另一個 scope，找到就指名道姓並給出可複製的
      # 命令。這是純 awk 掃檔，只跑在錯誤路徑上，不影響正常解析成本。
      case "$TEST_SCOPE" in
        unit) other_scope_flag="--ui";   other_target="BooksAndVocabUITests"; other_dir="$PROJECT_ROOT/ios/BooksAndVocabUITests" ;;
        ui)   other_scope_flag="--unit"; other_target="BooksAndVocabTests";   other_dir="$PROJECT_ROOT/ios/BooksAndVocabTests" ;;
        *)    other_scope_flag=""; other_target=""; other_dir="" ;;
      esac
      elsewhere=()
      if [[ -n "$other_dir" && -d "$other_dir" ]]; then
        while IFS= read -r flag; do
          [[ -n "$flag" ]] && elsewhere+=("$flag")
        done < <(discover_only_flags "$other_dir" "^${t}$" "$other_target")
      fi
      # 這個 -gt 0 守衛不能拿掉。bash 3.2 + set -u 下，空陣列的兩種展開**行為不同**：
      # `"${a[@]}"` 會 unbound variable 當場死（rc=1），但下面用的 `"${a[@]#pfx}"`
      # 反而展開成「一個空字串引數」、rc=0（已實測）。也就是說少了守衛不會像既有
      # ONLY_FLAGS 那樣大聲炸掉，而是靜靜多印一行空的 `[ios_test]   `。
      if [[ ${#elsewhere[@]} -gt 0 ]]; then
        # 印出 target/容器（去掉 -only-testing: 前綴），讓讀者直接看見它住在哪。
        echo "[ios_test] 但這個名字存在於另一個 target：" >&2
        printf '[ios_test]   %s\n' "${elsewhere[@]#-only-testing:}" >&2
        echo "[ios_test] 本 scope（${TEST_TARGET}）掃不到它。加上 $other_scope_flag 即可：" >&2
        echo "[ios_test]   ./ops/ios_test.sh $other_scope_flag $t" >&2
        exit 1
      fi
      echo "[ios_test] 裸方法名會掃描該 scope 的 test 目錄反查所屬 class/@Suite 容器；跨 scope 請加 --ui/--unit，或直接給 Class/method。" >&2
      exit 1
    fi
    # 名字撞到 class/@Suite 容器名時會整包命中該 suite（與 -g 的語意一致）。
    # bash 3.2 + set -u：空陣列展開會 unbound variable，故下一行必須留在 -eq 0 之後。
    [[ ${#resolved[@]} -gt 1 ]] && echo "[ios_test] note: '$t' 命中 ${#resolved[@]} 個 selector，全部納入" >&2
    ONLY_FLAGS+=("${resolved[@]}")
  done
elif [[ "$TEST_SCOPE" != "all" ]]; then
  ONLY_FLAGS+=("-only-testing:$TEST_TARGET")
fi

if [[ -z "$UI_TEST_FLOW_ID" ]]; then
  UI_TEST_FLOW_ID="$TEST_TARGET"
fi

if [[ "$TEST_SCOPE" == "ui" && -z "$UI_LAUNCH_PROFILE" ]]; then
  UI_LAUNCH_PROFILE="ui-smoke"
fi

if [[ "$LAUNCH_BENCHMARK" -eq 1 ]]; then
  TEST_SCOPE="ui"
  TEST_TARGET="BooksAndVocabUITests"
  TEST_DIR="$PROJECT_ROOT/ios/BooksAndVocabUITests"
  TEST_SCHEME="BooksAndVocabUITests"
  ONLY_FLAGS=("-only-testing:BooksAndVocabUITests/BooksAndVocabUITests/testLaunchPerformance")
  if [[ -z "$UI_LAUNCH_PROFILE" ]]; then
    UI_LAUNCH_PROFILE="standard"
  fi
fi
UI_TEST_VARIANT_ID="$(build_ui_test_variant_id)"

# Dry-run: print resolved flags and exit before touching the lock / xcodebuild.
if [[ "$LIST_ONLY" -eq 1 ]]; then
  if [[ ${#ONLY_FLAGS[@]} -eq 0 ]]; then
    echo "[ios_test] (no -only-testing flags — would run ALL tests)"
  else
    printf '%s\n' "${ONLY_FLAGS[@]}"
  fi
  exit 0
fi

print_cache_payload() {
  local action="$1" status="$2" cache_key="$3" derived_root="$4" xctestrun_path="$5" products_ready="$6" build_ms="${7:-0}" boot_ms="${8:-0}" error_key="${9:-}" error_message="${10:-}" build_log_path="${11:-}" result_bundle_path="${12:-}"
  jq -n \
    --arg schema "kg.ios.test-cache.v1" \
    --arg action "$action" \
    --arg status "$status" \
    --arg scope "$TEST_SCOPE" \
    --arg scheme "$TEST_SCHEME" \
    --arg uiLaunchProfile "$UI_LAUNCH_PROFILE" \
    --arg destination "$DESTINATION" \
    --arg cacheKey "$cache_key" \
    --arg cacheRoot "$TEST_CACHE_ROOT" \
    --arg derivedRoot "$derived_root" \
    --arg xctestrunPath "$xctestrun_path" \
    --argjson productsReady "$products_ready" \
    --argjson buildMs "$build_ms" \
    --argjson bootMs "$boot_ms" \
    --arg errorKey "$error_key" \
    --arg errorMessage "$error_message" \
    --arg buildLogPath "$build_log_path" \
    --arg resultBundlePath "$result_bundle_path" \
    '{
      schema:$schema,
      generated_at:(now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      action:$action,
      status:$status,
      scope:$scope,
      scheme:$scheme,
      uiLaunchProfile:(if $uiLaunchProfile == "" then null else $uiLaunchProfile end),
      destination:$destination,
      cache:{
        key:$cacheKey,
        root:$cacheRoot,
        derivedDataRoot:$derivedRoot,
        xctestrunPath:(if $xctestrunPath == "" then null else $xctestrunPath end),
        productsReady:$productsReady
      },
      timings:{
        bootMs:$bootMs,
        buildForTestingMs:$buildMs
      },
      artifacts:{
        buildLog:(if $buildLogPath == "" then null else $buildLogPath end),
        resultBundle:(if $resultBundlePath == "" then null else $resultBundlePath end)
      },
      errors:(if $errorKey == "" then [] else [{key:$errorKey,status:"error",error:$errorMessage}] end)
    }'
}

# --- Lock acquire (shared with ios_build.sh) ---
TMPOUT=""
PRESERVE_TMPOUT=0
CURRENT_XCODE_PID=""
RESULT_DIR=""
RESULT_BUNDLE=""
UI_TEST_SCREENSHOT_DIR=""
UI_TEST_CONTACT_SHEET=""
UI_TEST_SCREENSHOT_MANIFEST=""
UI_TEST_VIDEO=""
UI_TEST_VIDEO_PID=""
UI_TEST_VIDEO_LOG=""
UI_TEST_VIDEO_STARTED=0
UI_TEST_VIDEO_LOCK_HELD=0
UI_TEST_VIDEO_LOCK_FILE=""
UI_TEST_VIDEO_FILE=""
UI_TEST_VIDEO_SHA256=""
UI_TEST_RUN_ID="${KG_IOS_TEST_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)-${BASHPID:-$$}}"
TEST_DEVICE_LOCK_HELD=0
TEST_DEVICE_LOCK_FILE=""
DEVICE_RUN_LOCK_WAIT_MS=0
test_log_line_count() {
  local log_path="${1:-${TMPOUT:-}}"
  [[ -n "$log_path" && -f "$log_path" ]] || return 1
  wc -l < "$log_path" | tr -d ' '
}
write_missing_test_log_marker() {
  local log_path="${1:-${TMPOUT:-}}"
  [[ -n "$log_path" ]] || return 1
  cat >"$log_path" <<EOF
[ios_test] error: xcodebuild log path disappeared before diagnostics could read it
[ios_test] log=$log_path
EOF
}
cleanup() {
  if [[ -n "${CURRENT_XCODE_PID:-}" ]] && kill -0 "$CURRENT_XCODE_PID" 2>/dev/null; then
    kill "$CURRENT_XCODE_PID" 2>/dev/null || true
  fi
  if [[ -n "${UI_TEST_VIDEO_PID:-}" || "${UI_TEST_VIDEO_LOCK_HELD:-0}" -eq 1 ]]; then
    stop_ui_test_recording || true
  fi
  release_test_device_lock
  release_build_lock   # ownership-guarded; only removes the lock if we still hold it
  if [[ -n "${LEASED_DEVICE:-}" ]]; then
    "$IOS_OPS" simulator release --device "$LEASED_DEVICE" --owner-token "$LEASE_OWNER_TOKEN" >/dev/null 2>&1 || true
    LEASED_DEVICE=''
  fi
  if [[ "$PRESERVE_TMPOUT" -eq 0 ]]; then
    rm -f "${TMPOUT:-}"
  fi
  rm -f "${STAGED_DATASET_XCTESTRUN:-}"
}

# Fine-grained build lock (shared /tmp/kg-ios-build.lock with ios_build.sh).
# Held ONLY around build-for-testing — the sole writer of the shared DerivedData
# — and released before test execution. Parallel agents running
# test-without-building read immutable, content-keyed cache products on their own
# leased simulators, so they no longer queue behind each other's test runs (which
# was measured at 246s/309s lockWait for 3 concurrent runs). See
# docs/reference/ios_deriveddata_policy.md.
LOCK_HELD=0
LOCK_WAIT_MS=0
acquire_build_lock() {
  [[ "$LOCK_HELD" -eq 1 ]] && return 0
  echo "[ios_test] caller=$CALLER waiting for build lock..."
  local lock_wait_start_ms
  lock_wait_start_ms="$(ios_test_now_ms)"
  if ! kg_ios_wait_for_shlock "[ios_test]" build "$LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL" post-sleep; then
    kg_ios_lock_timeout_die "[ios_test]" build "${LOCK_FILE}" "$TIMEOUT"
  fi
  LOCK_HELD=1
  LOCK_WAIT_MS=$(( LOCK_WAIT_MS + ($(ios_test_now_ms) - lock_wait_start_ms) ))
  echo "[ios_test] build lock acquired lockWaitMs=$LOCK_WAIT_MS"
}
release_build_lock() {
  [[ "$LOCK_HELD" -eq 1 ]] || return 0
  # Only remove the lock if we still own it — another agent may have acquired it
  # after we released, and we must never delete someone else's lock.
  kg_ios_release_shlock_if_owner "$LOCK_FILE" "$$"
  LOCK_HELD=0
}

destination_requires_device_lock() {
  [[ "$DESTINATION" == *"platform=iOS Simulator"* ]]
}

env_flag_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

running_in_isolation_enforced_context() {
  env_flag_enabled "${KG_IOS_TEST_REQUIRE_ISOLATED_SIM:-}" && return 0
  env_flag_enabled "${CI:-}" && return 0
  [[ "$PROJECT_ROOT" == *"/.codex/worktrees/"* ]] && return 0
  [[ -n "${WORKTREE_BRANCH:-}" ]] && return 0
  return 1
}

should_require_isolated_simulator() {
  destination_requires_device_lock || return 1
  [[ -n "$DEVICE_OVERRIDE" || -n "$DESTINATION_OVERRIDE" || "$AUTO_LEASE" -eq 1 ]] && return 1
  [[ "$LIST_ONLY" -eq 1 ]] && return 1
  case "${TEST_CACHE_ACTION:-}" in
    status|prepare|clean) return 1 ;;
  esac
  env_flag_enabled "${KG_IOS_TEST_ALLOW_SHARED_SIM:-}" && return 1
  running_in_isolation_enforced_context
}

enforce_isolated_simulator_or_fail() {
  should_require_isolated_simulator || return 0
  cat >&2 <<EOF
[ios_test] error: shared default simulator is disallowed in agent/CI worktree runs
[ios_test] requested destination=$DESTINATION
[ios_test] fix: pass --lease, --device <udid|name>, or --destination '<xcodebuild destination>'
[ios_test] override: KG_IOS_TEST_ALLOW_SHARED_SIM=1
EOF
  exit 1
}

device_lock_key() {
  local raw_selector="${SIMULATOR_BOOT_SELECTOR:-$DESTINATION}"
  printf '%s' "$raw_selector" | shasum -a 256 | awk '{print $1}'
}

acquire_test_device_lock() {
  [[ "$TEST_DEVICE_LOCK_HELD" -eq 1 ]] && return 0
  destination_requires_device_lock || return 0
  local lock_wait_start_ms lock_key selector
  lock_key="$(device_lock_key)"
  TEST_DEVICE_LOCK_FILE="/tmp/kg-ios-test-device-${lock_key}.lock"
  selector="${SIMULATOR_BOOT_SELECTOR:-$DESTINATION}"
  echo "[ios_test] caller=$CALLER waiting for device lock selector=\"$selector\"..."
  lock_wait_start_ms="$(ios_test_now_ms)"
  if ! kg_ios_wait_for_shlock "[ios_test]" device "$TEST_DEVICE_LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL" post-sleep; then
    kg_ios_lock_timeout_die "[ios_test]" device "$selector" "$TIMEOUT"
  fi
  TEST_DEVICE_LOCK_HELD=1
  DEVICE_RUN_LOCK_WAIT_MS=$(( DEVICE_RUN_LOCK_WAIT_MS + ($(ios_test_now_ms) - lock_wait_start_ms) ))
  echo "[ios_test] device lock acquired deviceRunLockWaitMs=$DEVICE_RUN_LOCK_WAIT_MS"
}

release_test_device_lock() {
  [[ "$TEST_DEVICE_LOCK_HELD" -eq 1 ]] || return 0
  kg_ios_release_shlock_if_owner "$TEST_DEVICE_LOCK_FILE" "$$"
  TEST_DEVICE_LOCK_HELD=0
}
# cleanup exactly once, and DIE with 128+N on a signal instead of resuming with
# the shared locks already released. See ops/lib/signal_traps.sh.
kg_install_signal_traps cleanup

# Initialize the per-invocation verdict before any operation that can fail.
# Simulator leasing deliberately happens before xcodebuild, so a refusal must
# still leave evidence for `ios_ops.sh` and the orchestration gate to read.
kg_ios_verdict_init test "$PROJECT_ROOT"

write_early_failure_verdict() {
  local reason="$1" exit_code="${2:-1}" source_commit early_tree_status early_tree_dirty
  source_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
  if early_tree_status="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)"; then
    if [[ -n "$early_tree_status" ]]; then early_tree_dirty=true; else early_tree_dirty=false; fi
  else
    early_tree_dirty=true
  fi
  printf 'RESULT=inconclusive EXIT=%s reason=%s caller=%s elapsed=0s %s %s\n' "$exit_code" "$reason" "$CALLER" "$(kg_ios_verdict_commit_kv "$PROJECT_ROOT")" "$(kg_ios_verdict_identity_kv)" >"$VERDICT_FILE"
  jq -nc \
    --arg schema "kg.ios.run-verdict.v1" \
    --arg kind "test" \
    --arg result "inconclusive" \
    --arg exit "$exit_code" \
    --arg reason "$reason" \
    --arg caller "$CALLER" \
    --arg cwd "$PROJECT_ROOT" \
    --arg verdictFile "$VERDICT_FILE" \
    --argjson ts "$(date +%s)" \
    --argjson pid "$$" \
    --arg sourceCommit "$source_commit" \
    --argjson sourceTreeDirty "$early_tree_dirty" \
    --arg elapsed "0s" \
    ' {
      schema:$schema,
      kind:$kind,
      status:$result,
      result:$result,
      exit:$exit,
      reason:$reason,
      caller:$caller,
      invocation:{ts:$ts,pid:$pid,cwd:$cwd,verdictFile:$verdictFile},
      options:{sourceCommit:$sourceCommit,sourceTreeDirty:$sourceTreeDirty},
      elapsed:$elapsed,
      executed:null,
      artifacts:{log:null,xcresult:null}
    }' >"$VERDICT_JSON_FILE"
  kg_ios_verdict_publish
}

# Read the shared disk guard BEFORE leasing a simulator or taking the build lock.
# A structural block (exit 77, retryable=no) or a temporary one (exit 75) is
# decided here in seconds instead of after a lease and a lock-queue wait; the
# in-lock preflight below keeps measuring real disk space only.
if [[ "$TEST_CACHE_ACTION" != "status" && "$TEST_CACHE_ACTION" != "clean" ]]; then
  early_guard_rc=0
  kg_ios_disk_guard_early_verdict "test" || early_guard_rc=$?
  if (( early_guard_rc != 0 )); then
    if (( early_guard_rc == KG_IOS_DISK_STRUCTURAL_EXIT )); then
      write_early_failure_verdict "disk-guard-structural-block" "$early_guard_rc"
    else
      echo "[ios_test] blocked by the shared disk guard (exit $early_guard_rc, temporary): see the guard reason and action above; './ops/ios_ops.sh guard --refresh' re-evaluates now" >&2
      write_early_failure_verdict "disk-guard-blocked" "$early_guard_rc"
    fi
    exit "$early_guard_rc"
  fi
  # The guard verdict was just read; the in-lock preflight now measures real
  # disk space only (cache budget, free-space floor) and does not re-read it.
  kg_ios_disk_guard_mark_checked
fi

# Auto-lease a pool simulator for this run (parallel agents). Engaged by --lease
# / KG_IOS_TEST_AUTOLEASE only when no explicit device/destination was given —
# explicit targeting always wins. Done after the trap is armed so the lease is
# always released on exit, and after the validation gates so we never lease for
# a run that would have errored out anyway.
if [[ "$AUTO_LEASE" -eq 1 && -z "$DEVICE_OVERRIDE" && -z "$DESTINATION_OVERRIDE" \
      && "$TEST_CACHE_ACTION" != "status" && "$TEST_CACHE_ACTION" != "clean" ]]; then
  lease_json="$(
    KG_IOS_SIM_LEASE_OWNER_PID=$$ \
    KG_IOS_SIM_LEASE_OWNER_TOKEN="$LEASE_OWNER_TOKEN" \
      "$IOS_OPS" simulator lease --json 2>/dev/null || true
  )"
  LEASED_DEVICE="$(jq -r '.udid // empty' <<<"$lease_json" 2>/dev/null || true)"
  if [[ -z "$LEASED_DEVICE" ]]; then
    # `2>/dev/null` above drops the lease command's own diagnostics, so the
    # reason has to travel in the JSON or it is lost. A slot refused for
    # holding a real account is NOT exhaustion, and must not be reported as it.
    lease_error="$(jq -r '.error // empty' <<<"$lease_json" 2>/dev/null || true)"
    lease_refused="$(jq -r '.refusedNonDisposable // 0' <<<"$lease_json" 2>/dev/null || true)"
    lease_blind="$(jq -r '.refusedUnverifiable // 0' <<<"$lease_json" 2>/dev/null || true)"
    [[ "${lease_refused:-0}" =~ ^[0-9]+$ ]] || lease_refused=0
    [[ "${lease_blind:-0}" =~ ^[0-9]+$ ]] || lease_blind=0
    if (( lease_blind > 0 )); then
      # Distinct from the logged-in case on purpose: this one blocks the WHOLE
      # pool, and telling the operator to go log simulators out would send them
      # hunting for accounts that are not there.
      echo "[ios_test] error: --lease 拿不到 slot：$lease_blind 台 pool simulator 無法確認帳號歸屬——是偵測本身壞了（plutil 不見了 / CoreSimulator 路徑變了 / prefs 讀不到），不是有人登入。跑 './ops/ios_ops.sh simulator lease' 看每台的實際原因。" >&2
      lease_reason="simulator-pool-unverifiable"
    elif (( lease_refused > 0 )); then
      echo "[ios_test] error: --lease 拿不到 slot：$lease_refused 台 pool simulator 因登著非拋棄帳號被拒絕出租（UI test fixture 會清空 app 容器）。跑 './ops/ios_ops.sh simulator lease' 看是哪幾台，處理掉再重試；調大 KG_IOS_SIM_POOL_SIZE 無效。" >&2
      lease_reason="simulator-pool-blocked-non-disposable"
    else
      echo "[ios_test] error: --lease requested but simulator pool is exhausted" >&2
      if [[ "$lease_error" == pool-exhausted:* ]]; then
        lease_reason="simulator-pool-exhausted"
      else
        lease_reason="simulator-lease-failed"
      fi
    fi
    write_early_failure_verdict "$lease_reason" 1
    exit 1
  fi
  echo "[ios_test] leased simulator udid=$LEASED_DEVICE"
  DESTINATION="platform=iOS Simulator,id=$LEASED_DEVICE"
  SIMULATOR_BOOT_SELECTOR="$LEASED_DEVICE"
fi

enforce_isolated_simulator_or_fail

# Progress line, not payload: under --json stdout carries exactly one JSON
# document, so route the banner to stderr there (same contract the streaming
# gate runners hold).
printf '[ios_test] caller=%s scope=%s running %d selector(s) (0=scheme all targets)...\n' \
  "$CALLER" "$TEST_SCOPE" "${#ONLY_FLAGS[@]}" >&"$(( JSON_MODE ? 2 : 1 ))"
START=$(date +%s)
START_MS="$(ios_test_now_ms)"
BOOT_MS=0
XCODEBUILD_MS=0
BUILD_FOR_TESTING_MS=0
TEST_INVOCATION_MS=0
CACHE_STATUS="none"
DERIVED_DATA_ROOT=""
XCTESTRUN_PATH=""
TEST_BODY_MS=0
XCRESULT_SESSION_MS=0
XCRESULT_HARNESS_OVERHEAD_MS=0
INVOCATION_OVERHEAD_MS=0
lease_json=""
boot_simulator_if_needed() {
  local boot_start_ms boot_end_ms boot_payload resolved_device
  boot_start_ms="$(ios_test_now_ms)"
  RESOLVED_DEVICE_UDID=''
  if ! boot_payload="$("$IOS_OPS" simulator ensure-booted --device "$SIMULATOR_BOOT_SELECTOR" --json)"; then
    if ! jq -r '
      "[ios][simulator] schema=\(.schema // "unknown") action=\(.action // "ensure-booted") status=\(.status // "error") selector=\(.selector // "") device=\(.device.udid // "")",
      (.errors[]? | "[ios][simulator] error key=\(.key // "") status=\(.status // "") exitCode=\(.exitCode // "") error=\(.error // "")")
    ' <<<"$boot_payload" >&2 2>/dev/null; then
      printf '%s\n' "$boot_payload" >&2
    fi
    return 1
  fi
  if ! resolved_device="$(jq -er '
    select(.status == "ok")
    | .device.udid
    | select(type == "string" and length > 0)
  ' <<<"$boot_payload")"; then
    echo "[ios_test] simulator ensure-booted did not return a usable device UDID" >&2
    return 1
  fi
  RESOLVED_DEVICE_UDID="$resolved_device"
  jq -r '
    "[ios][simulator] schema=\(.schema) action=\(.action) status=\(.status) selector=\(.selector) device=\(.device.udid // "")",
    "[ios][simulator] boot status=\(.boot.status) exitCode=\(.boot.exitCode // "") wasAlreadyBooted=\(.boot.wasAlreadyBooted) waitedForBootstatus=\(.boot.waitedForBootstatus)",
    "[ios][simulator] timings totalMs=\(.timings.totalMs) resolveMs=\(.timings.resolveMs) bootMs=\(.timings.bootMs) bootstatusMs=\(.timings.bootstatusMs)",
    (.errors[]? | "[ios][simulator] error key=\(.key) status=\(.status) exitCode=\(.exitCode // "") error=\(.error // "")")
  ' <<<"$boot_payload" >&"$(( JSON_MODE ? 2 : 1 ))"
  boot_end_ms="$(ios_test_now_ms)"
  BOOT_MS=$(( boot_end_ms - boot_start_ms ))
}

ui_test_launch_args_json() {
  if [[ -n "$UI_LAUNCH_PROFILE" ]]; then
    jq -nc --arg profile "$UI_LAUNCH_PROFILE" '["-appLaunchProfile", $profile]'
  else
    jq -nc '[]'
  fi
}

# Truthful `prepare` verdict: the status label must be derived from whether the
# cache actually holds ready products, never asserted independently of it.
ios_test_prepare_status() {
  if [[ "$1" == true ]]; then printf 'prepared\n'; else printf 'error\n'; fi
}

handle_cache_action() {
  local cache_key derived_root xctestrun_path products_ready payload build_log build_result_dir build_result_bundle build_exit prepare_status prepare_error_key prepare_error_message
  local action="$1"
  cache_key="$(ios_test_build_cache_key)"
  derived_root="$(ios_test_derived_data_root)"
  DERIVED_DATA_ROOT="$derived_root"
  xctestrun_path="$(ios_test_find_xctestrun "$derived_root" || true)"
  products_ready=false
  if ios_test_cache_is_complete "$xctestrun_path"; then
    products_ready=true
  fi

  case "$action" in
    status)
      payload="$(print_cache_payload status ok "$cache_key" "$derived_root" "$xctestrun_path" "$products_ready")"
      ;;
    clean)
      # Deleting the keyed DerivedData races unlocked test-without-building readers
      # (#2819): serialize behind the build lock, then refuse while a consumer touched
      # the key recently (every run touches it at start) unless explicitly forced.
      acquire_build_lock
      if [[ -d "$derived_root" && "${KG_IOS_CLEAN_CACHE_FORCE:-0}" != "1" ]] \
        && [[ -n "$(find "$derived_root" -maxdepth 0 -mmin "-${KG_IOS_CLEAN_CACHE_ACTIVE_MINUTES:-30}" 2>/dev/null)" ]]; then
        release_build_lock
        echo "[ios_test] refusing --clean-cache: $derived_root was used by an active consumer within the last ${KG_IOS_CLEAN_CACHE_ACTIVE_MINUTES:-30} min; retry later or set KG_IOS_CLEAN_CACHE_FORCE=1" >&2
        exit 75
      fi
      rm -rf "$derived_root"
      # ios_ops build 的 DerivedData（TEST_CACHE_ROOT 的 sibling）同計入 disk-budget；
      # 不清它則 build-then-test 會 cache-budget-headroom-exhausted（#2668）。已持 build lock，與 build writer 互斥。
      rm -rf "$(dirname "$TEST_CACHE_ROOT")/ios-build-derived-data"
      release_build_lock
      payload="$(print_cache_payload clean ok "$cache_key" "$derived_root" "" false)"
      ;;
    prepare)
      boot_simulator_if_needed
      if [[ "$products_ready" == true ]]; then
        payload="$(print_cache_payload prepare hit "$cache_key" "$derived_root" "$xctestrun_path" true 0 "$BOOT_MS")"
      else
        build_log="$(artifact_temp_file kg_ios_test_build_log)"
        build_result_dir="$(artifact_temp_dir kg_ios_test_build_result)"
        build_result_bundle="$build_result_dir/BuildForTesting.xcresult"
        # Guard with `|| build_exit=$?`: this runs under `set -e`, so a non-zero
        # return would abort before we can build the error payload below.
        build_exit=0
        rebuild_test_cache "$build_log" "$build_result_bundle" || build_exit=$?
        if [[ "$build_exit" -eq 0 ]]; then
          xctestrun_path="$(ios_test_find_xctestrun "$derived_root" || true)"
          products_ready=false
          if ios_test_cache_is_complete "$xctestrun_path"; then
            products_ready=true
          fi
          # A build that exits 0 but leaves the cache without ready products is
          # NOT "prepared". Hardcoding the label made the JSON self-contradicting
          # (status:"prepared" + productsReady:false) and — because only
          # status=="error" exits non-zero — let the live-only Release compile
          # BLOCK gate go green on a cache that produced nothing.
          prepare_status="$(ios_test_prepare_status "$products_ready")"
          prepare_error_key=""
          prepare_error_message=""
          if [[ "$prepare_status" != prepared ]]; then
            prepare_error_key="cache-products-missing"
            prepare_error_message="build-for-testing exited 0 but the $CONFIGURATION-$(ios_test_sdk_suffix) test products are incomplete"
          fi
          payload="$(print_cache_payload prepare "$prepare_status" "$cache_key" "$derived_root" "$xctestrun_path" "$products_ready" "$BUILD_FOR_TESTING_MS" "$BOOT_MS" "$prepare_error_key" "$prepare_error_message" "$build_log" "$build_result_bundle")"
        else
          payload="$(print_cache_payload prepare error "$cache_key" "$derived_root" "$xctestrun_path" false "$BUILD_FOR_TESTING_MS" "$BOOT_MS" "build-for-testing" "prepare-cache-failed" "$build_log" "$build_result_bundle")"
        fi
        if [[ "$build_exit" -eq 0 ]]; then
          rm -f "$build_log"
          rm -rf "$build_result_dir"
        fi
      fi
      ;;
    *)
      echo "[ios_test] internal error: unknown cache action '$action'" >&2
      exit 2
      ;;
  esac

  if (( JSON_MODE )); then
    printf '%s\n' "$payload" >&9
  else
    jq -r '
      "[ios][test-cache] action=\(.action) status=\(.status) scope=\(.scope) scheme=\(.scheme)",
      "[ios][test-cache] key=\(.cache.key) root=\(.cache.root) derivedDataRoot=\(.cache.derivedDataRoot)",
      "[ios][test-cache] productsReady=\(.cache.productsReady) xctestrun=\(.cache.xctestrunPath // "")",
      "[ios][test-cache] timings bootMs=\(.timings.bootMs) buildForTestingMs=\(.timings.buildForTestingMs)",
      (if .artifacts.buildLog then "[ios][test-cache] buildLog=\(.artifacts.buildLog) resultBundle=\(.artifacts.resultBundle // "")" else empty end),
      (.errors[]? | "[ios][test-cache] error key=\(.key) status=\(.status) error=\(.error)")
    ' <<<"$payload"
  fi

  if [[ "$(jq -r '.status' <<<"$payload")" == "error" ]]; then
    # The in-lock disk preflight inside rebuild_test_cache returns its own rc:
    # 75 (temporary) / 77 (structural, retryable=no). Keep that classification
    # instead of flattening it to a generic tool error; any other build failure
    # (xcodebuild's own rc) stays exit 1.
    if (( ${build_exit:-0} == KG_IOS_DISK_BUDGET_EXIT || ${build_exit:-0} == KG_IOS_DISK_STRUCTURAL_EXIT )); then
      exit "$build_exit"
    fi
    exit 1
  fi
  exit 0
}

is_build_db_lock_failure() {
  grep -qE 'build\.db.*database is locked|unable to attach DB' "$TMPOUT" 2>/dev/null
}

emit_new_test_output() {
  local from_line="$1" to_line="$2"
  [[ "$to_line" -ge "$from_line" ]] || return 0
  sed -n "${from_line},${to_line}p" "$TMPOUT" \
    | grep -E "^(\*\* TEST|Test Suite '.+' (started|passed|failed)|Test Case '.+' (started|passed|failed|skipped)|Test session results|[[:space:]]*[✘✗] Test .+ failed|[✔✘✓✗] Test run with|error:)" \
    || true
}

last_test_event() {
  grep -E "^(Test Suite '.+' (started|passed|failed)|Test Case '.+' (started|passed|failed|skipped)|[[:space:]]*[✘✗] Test .+ failed|[✔✘✓✗] Test run with|Fatal error:)" "$TMPOUT" \
    | tail -1 \
    | sed 's/^[[:space:]]*//'
}

should_rebuild_after_test_without_building_failure() {
  grep -qE '^\*\* TEST( EXECUTE)? FAILED' "$TMPOUT" 2>/dev/null && return 1
  grep -qE 'Failed to read xctestrun file|no \.xctestrun artifact|cached test products are incomplete|failed to load test bundle|failed to create test runner|test runner exited before starting|unable to find.*xctestrun|xctestrun file.*(missing|invalid|not found)' "$TMPOUT" 2>/dev/null
}

# test-without-building 不會把 xcodebuild 行內 env 傳進 test runner process——
# xctestrun 的 TestingEnvironmentVariables 才是 runner env 的注入面（catalog
# pipeline 同法）。複製 base xctestrun 再 upsert，不污染共享 build cache 原檔；
# 副本必須與原檔同目錄（__TESTROOT__ 相對於 xctestrun 所在目錄解析）。
# 不可經 command substitution 呼叫：cleanup trap 靠父 shell 的
# STAGED_DATASET_XCTESTRUN 刪檔，subshell 賦值傳不回來（曾為死碼）。
stage_fixture_dataset_xctestrun() {
  if ! declare -F ios_xctestrun_cache_stage_env >/dev/null 2>&1; then
    source "${KG_IOS_XCTESTRUN_CACHE_LIB:?ios xctestrun cache library is not loaded}"
  fi
  ios_xctestrun_cache_stage_env \
    "$1" \
    "$2" \
    KG_FIXTURE_DATASET_DEFLATE_B64 \
    "$UI_FIXTURE_DATASET_DEFLATE_B64" \
    KG_LIVE_DEMO_RUN,KG_LIVE_DEMO_ACCOUNT_IDENTITY_SHA256,KG_FIXTURE_DATASET_B64,KG_FIXTURE_DATASET_DEFLATE_B64
}

# Some XCTest versions read process-level evidence from the target's
# EnvironmentVariables rather than TestingEnvironmentVariables.  Keep the
# two evidence keys scoped to the copied xctestrun so P9 tests can observe
# their contract without changing the shared cache or the host shell env.
stage_ui_runner_process_environment() {
  local staged_path="$1" verdict_file="$2"
  local roots_file env_root runner_root key value status=0
  [[ -f "$staged_path" && -n "$verdict_file" ]] || return 1
  if ! declare -F ios_xctestrun_cache_env_roots >/dev/null 2>&1; then
    source "${KG_IOS_XCTESTRUN_CACHE_LIB:?ios xctestrun cache library is not loaded}"
  fi
  roots_file="$(mktemp "${TMPDIR:-/tmp}/kg_xctestrun_process_env_roots.XXXXXX")" || return 1
  if ! ios_xctestrun_cache_env_roots "$staged_path" >"$roots_file" || [[ ! -s "$roots_file" ]]; then
    rm -f "$roots_file"
    return 1
  fi
  while IFS= read -r env_root; do
    [[ -n "$env_root" ]] || continue
    runner_root="${env_root%:TestingEnvironmentVariables}"
    /usr/libexec/PlistBuddy -c "Add ${runner_root}:EnvironmentVariables dict" "$staged_path" 2>/dev/null || true
    for key in KG_UI_TEST_SCREENSHOT_DIR KG_IOS_VERDICT_FILE; do
      case "$key" in
        KG_UI_TEST_SCREENSHOT_DIR) value="${UI_TEST_SCREENSHOT_DIR:-}" ;;
        KG_IOS_VERDICT_FILE) value="$verdict_file" ;;
      esac
      [[ -n "$value" ]] || continue
      /usr/libexec/PlistBuddy -c "Delete ${runner_root}:EnvironmentVariables:$key" "$staged_path" 2>/dev/null || true
      if ! /usr/libexec/PlistBuddy -c "Add ${runner_root}:EnvironmentVariables:$key string $value" "$staged_path"; then
        status=1
        break
      fi
    done
    [[ "$status" -eq 0 ]] || break
  done <"$roots_file"
  rm -f "$roots_file"
  return "$status"
}

stage_ui_evidence_runner_environment() {
  local staged_path="$1" source_commit device verdict_file
  if [[ -z "$staged_path" || ! -f "$staged_path" ]]; then
    echo "[ios_test] evidence stage blocked: staged xctestrun is missing path=$staged_path" >&2
    return 1
  fi
  source_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
  device="$(resolve_run_device_udid 2>/dev/null || true)"
  verdict_file="${KG_IOS_VERDICT_FILE:-${VERDICT_FILE:-}}"
  if [[ -z "$source_commit" ]]; then
    echo "[ios_test] evidence stage blocked: source commit could not be resolved" >&2
    return 1
  fi
  if [[ -z "${UI_TEST_SCREENSHOT_DIR:-}" ]]; then
    echo "[ios_test] evidence stage blocked: UI_TEST_SCREENSHOT_DIR is missing for UI evidence" >&2
    return 1
  fi
  if [[ -z "$device" ]]; then
    echo "[ios_test] evidence stage blocked: simulator/device UDID could not be resolved" >&2
    return 1
  fi
  if [[ -z "$verdict_file" ]]; then
    echo "[ios_test] evidence stage blocked: KG_IOS_VERDICT_FILE/VERDICT_FILE is missing; use run_ui_evidence.sh for evidence runs" >&2
    return 1
  fi
  if ! ios_xctestrun_cache_upsert_env_all_targets "$staged_path" KG_UI_TEST_SOURCE_COMMIT "$source_commit"; then
    echo "[ios_test] evidence stage failed: key=KG_UI_TEST_SOURCE_COMMIT xctestrun=$staged_path" >&2
    return 1
  fi
  if ! ios_xctestrun_cache_upsert_env_all_targets "$staged_path" KG_UI_TEST_SCREENSHOT_DIR "$UI_TEST_SCREENSHOT_DIR"; then
    echo "[ios_test] evidence stage failed: key=KG_UI_TEST_SCREENSHOT_DIR xctestrun=$staged_path" >&2
    return 1
  fi
  if ! ios_xctestrun_cache_upsert_env_all_targets "$staged_path" KG_UI_TEST_DATASET_ID "$EVIDENCE_DATASET_ID"; then
    echo "[ios_test] evidence stage failed: key=KG_UI_TEST_DATASET_ID xctestrun=$staged_path" >&2
    return 1
  fi
  if ! ios_xctestrun_cache_upsert_env_all_targets "$staged_path" KG_UI_TEST_DATASET_SHA256 "$EVIDENCE_DATASET_SHA256"; then
    echo "[ios_test] evidence stage failed: key=KG_UI_TEST_DATASET_SHA256 xctestrun=$staged_path" >&2
    return 1
  fi
  if ! ios_xctestrun_cache_upsert_env_all_targets "$staged_path" KG_UI_TEST_DEVICE_UDID "$device"; then
    echo "[ios_test] evidence stage failed: key=KG_UI_TEST_DEVICE_UDID xctestrun=$staged_path" >&2
    return 1
  fi
  if ! ios_xctestrun_cache_upsert_env_all_targets "$staged_path" KG_IOS_VERDICT_FILE "$verdict_file"; then
    echo "[ios_test] evidence stage failed: key=KG_IOS_VERDICT_FILE xctestrun=$staged_path" >&2
    return 1
  fi
  if ! stage_ui_runner_process_environment "$staged_path" "$verdict_file"; then
    echo "[ios_test] evidence stage failed: process environment xctestrun=$staged_path" >&2
    return 1
  fi
}

xctestrun_target_env_roots() {
  if ! declare -F ios_xctestrun_cache_env_roots >/dev/null 2>&1; then
    source "${KG_IOS_XCTESTRUN_CACHE_LIB:?ios xctestrun cache library is not loaded}"
  fi
  ios_xctestrun_cache_env_roots "$1"
}

sanitize_xctestrun_evidence_env_root() {
  if ! declare -F ios_xctestrun_cache_sanitize_env_root >/dev/null 2>&1; then
    source "${KG_IOS_XCTESTRUN_CACHE_LIB:?ios xctestrun cache library is not loaded}"
  fi
  ios_xctestrun_cache_sanitize_env_root \
    "$1" \
    "$2" \
    KG_LIVE_DEMO_RUN,KG_LIVE_DEMO_ACCOUNT_IDENTITY_SHA256,KG_FIXTURE_DATASET_B64,KG_FIXTURE_DATASET_DEFLATE_B64,KG_FIXTURE_ASSET_ROOT
}

# 枚舉與變更必須嚴格分兩段，不可邊枚舉邊改同一份 plist。
# xctestrun_target_env_roots 跑在 process substitution 的子行程裡，與迴圈體同時存活；
# 迴圈體每次 sanitize 都用 PlistBuddy 重寫 $staged_path，枚舉器下一次 Print 可能撞上
# 這個重寫而失敗，於是提早結束枚舉。後果是 fail-closed 反轉成 fail-open：兩個
# BooksAndVocabUITests 只數到 1 個，函式回 0 讓 live-demo 憑證注進未經清洗的 plist。
# 這個競態是時序性的（回報日 2/10 命中，三日後同機 0/10），所以 regression 用假枚舉器
# 釘死而非靠重跑。IMP-20260805-bf0df5。
# 陣列展開用索引而非 "${env_roots[@]}"：本檔 set -u，而 /bin/bash 3.2 對空陣列的
# "${a[@]}" 會 unbound variable 中止，正好打在零 target 的 fail-closed 路徑上。
# 同理不可用 mapfile（3.2 無此內建）。
stage_live_demo_xctestrun() {
  local base_path="$1" staged_path="$2"
  cp "$base_path" "$staged_path" || return 1
  local -a env_roots=()
  local env_root
  while IFS= read -r env_root; do
    [[ -n "$env_root" ]] && env_roots+=("$env_root")
  done < <(xctestrun_target_env_roots "$staged_path")
  local target_root blueprint_name live_env_root="" live_target_count=0 i
  for ((i = 0; i < ${#env_roots[@]}; i++)); do
    env_root="${env_roots[$i]}"
    sanitize_xctestrun_evidence_env_root "$staged_path" "$env_root"
    target_root="${env_root%:TestingEnvironmentVariables}"
    blueprint_name="$(/usr/libexec/PlistBuddy -c "Print $target_root:BlueprintName" "$staged_path" 2>/dev/null || true)"
    if [[ "$blueprint_name" == "BooksAndVocabUITests" ]]; then
      live_target_count=$((live_target_count + 1))
      live_env_root="$env_root"
    fi
  done
  if [[ "$live_target_count" -ne 1 ]]; then
    echo "[ios_test] error: live-demo xctestrun requires exactly one BooksAndVocabUITests target (found $live_target_count)" >&2
    return 1
  fi
  /usr/libexec/PlistBuddy -c "Add $live_env_root dict" "$staged_path" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add $live_env_root:KG_LIVE_DEMO_RUN string 1" "$staged_path" || return 1
  /usr/libexec/PlistBuddy -c "Add $live_env_root:KG_LIVE_DEMO_ACCOUNT_IDENTITY_SHA256 string $DEMO_ACCOUNT_IDENTITY_SHA256" "$staged_path" || return 1
}

xctestrun_has_live_demo_env() {
  local path="$1" env_root
  while IFS= read -r env_root; do
    if /usr/libexec/PlistBuddy -c "Print $env_root:KG_LIVE_DEMO_RUN" "$path" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Print $env_root:KG_LIVE_DEMO_ACCOUNT_IDENTITY_SHA256" "$path" >/dev/null 2>&1; then
      return 0
    fi
  done < <(xctestrun_target_env_roots "$path")
  return 1
}

run_xcodebuild_test_without_building_once() {
  local xctestrun_path="$1"
  local xcode_pid last_line current_line heartbeat_at tick_at emitted_this_loop now elapsed recent_event xcode_start_ms xcode_end_ms log_missing
  if [[ "$LIVE_DEMO" -eq 1 ]]; then
    STAGED_DATASET_XCTESTRUN="${xctestrun_path%.xctestrun}_live_demo_$$.scoped.xctestrun"
    if ! stage_live_demo_xctestrun "$xctestrun_path" "$STAGED_DATASET_XCTESTRUN"; then
      echo "[ios_test] error: failed to stage live-demo identity into xctestrun" >&2
      return 1
    fi
    xctestrun_path="$STAGED_DATASET_XCTESTRUN"
    echo "[ios_test] live-demo runner contract staged: $(basename "$xctestrun_path")"
  elif xctestrun_has_live_demo_env "$xctestrun_path"; then
    echo "[ios_test] error: spoofed live-demo environment found outside --live-demo" >&2
    return 1
  elif [[ -n "$UI_FIXTURE_DATASET_DEFLATE_B64" ]]; then
    # 父 shell 先賦值 STAGED_DATASET_XCTESTRUN 再 cp：即使 staging 半途失敗，
    # cleanup trap 也能刪掉殘檔。.scoped.xctestrun 字尾使 ios_test_find_xctestrun
    # 永不撿到副本（SIGKILL 漏刪也不污染後續 discovery）；同 PID retry 時 cp
    # 覆寫同名檔，不累積。
    STAGED_DATASET_XCTESTRUN="${xctestrun_path%.xctestrun}_dataset_$$.scoped.xctestrun"
    if ! stage_fixture_dataset_xctestrun "$xctestrun_path" "$STAGED_DATASET_XCTESTRUN"; then
      echo "[ios_test] error: failed to stage fixture dataset into xctestrun" >&2
      return 1
    fi
    xctestrun_path="$STAGED_DATASET_XCTESTRUN"
    echo "[ios_test] fixture dataset staged: $(basename "$xctestrun_path") (KG_FIXTURE_DATASET_DEFLATE_B64 ← ${UI_FIXTURE_DATASET_FILE})"
  else
    :
  fi
  acquire_test_device_lock
  start_ui_test_recording
  if [[ "$TEST_SCOPE" == "ui" || "$TEST_SCOPE" == "all" ]]; then
    if [[ -z "${STAGED_DATASET_XCTESTRUN:-}" ]]; then
      STAGED_DATASET_XCTESTRUN="${xctestrun_path%.xctestrun}_ui_$$.scoped.xctestrun"
      if ! cp "$xctestrun_path" "$STAGED_DATASET_XCTESTRUN"; then
        echo "[ios_test] error: failed to stage UI evidence xctestrun" >&2
        return 1
      fi
      xctestrun_path="$STAGED_DATASET_XCTESTRUN"
    fi
    if ! stage_ui_evidence_runner_environment "$xctestrun_path"; then
      echo "[ios_test] error: failed to stage UI evidence runner environment" >&2
      return 1
    fi
  fi
  xcode_start_ms="$(ios_test_now_ms)"
  KG_UI_TEST_APP_ARGS_JSON="$(ui_test_launch_args_json)" \
  KG_UI_TEST_SCREENSHOT_DIR="$UI_TEST_SCREENSHOT_DIR" \
  KG_UI_TEST_SOURCE_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)" \
  KG_UI_TEST_DATASET_ID="$EVIDENCE_DATASET_ID" \
  KG_UI_TEST_DATASET_SHA256="$EVIDENCE_DATASET_SHA256" \
  KG_UI_TEST_DEVICE_UDID="$(resolve_run_device_udid 2>/dev/null || true)" \
  env -u KG_LIVE_DEMO_RUN -u KG_LIVE_DEMO_ACCOUNT_IDENTITY_SHA256 xcodebuild test-without-building \
    -xctestrun "$xctestrun_path" \
    -destination "$DESTINATION" \
    ${COVERAGE_XCODEBUILD_ARGS[@]+"${COVERAGE_XCODEBUILD_ARGS[@]}"} \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance "$MAX_TEST_EXECUTION_TIME_ALLOWANCE" \
    -resultBundlePath "$RESULT_BUNDLE" \
    ${ONLY_FLAGS[@]+"${ONLY_FLAGS[@]}"} \
    >"$TMPOUT" 2>&1 &
  xcode_pid=$!
  CURRENT_XCODE_PID="$xcode_pid"
  echo "[ios_test] xcodebuild pid=$xcode_pid mode=test-without-building uiLaunchProfile=${UI_LAUNCH_PROFILE:-standard} xctestrun=$xctestrun_path log=$TMPOUT xcresult=$RESULT_BUNDLE"

  last_line=0
  log_missing=0
  heartbeat_at=$(date +%s)
  tick_at=$(date +%s)
  while kill -0 "$xcode_pid" 2>/dev/null; do
    if ! current_line="$(test_log_line_count "$TMPOUT")"; then
      log_missing=1
      echo "[ios_test] warning: xcodebuild log path disappeared while test was running: $TMPOUT" >&2
      break
    fi
    emitted_this_loop=0
    if [[ "$current_line" -gt "$last_line" ]]; then
      emit_new_test_output "$((last_line + 1))" "$current_line"
      last_line="$current_line"
      emitted_this_loop=1
    fi

    # A known service-hub failure is terminal before XCTest starts. Stop the
    # child now; the shared classifier below turns its signal exit into typed
    # infrastructure evidence instead of waiting for XCTest's allowance.
    if kg_ios_test_runner_startup_unavailable "$TMPOUT"; then
      echo "[ios_test] test-runner startup unavailable; terminating xcodebuild before XCTest timeout" >&2
      kill "$xcode_pid" 2>/dev/null || true
      break
    fi

    now=$(date +%s)
    if [[ $((now - heartbeat_at)) -ge 30 ]]; then
      # Detail heartbeat every 30s: which test is currently running.
      elapsed=$((now - START))
      recent_event="$(last_test_event)"
      [[ -n "$recent_event" ]] || recent_event="xcodebuild still running"
      echo "[ios_test] … still running (${elapsed}s, pid=$xcode_pid, log=$TMPOUT) — last: $recent_event"
      heartbeat_at="$now"
      tick_at="$now"
    elif [[ "$emitted_this_loop" -eq 0 && $((now - tick_at)) -ge 3 ]]; then
      # Short keep-alive tick every 3s, but only when no test output was printed
      # this loop (a slow/hung single test) — so it never floods a fast run.
      printf '[ios_test] ··· %ds\n' "$((now - START))"
      tick_at="$now"
    fi
    sleep 2
  done

  wait "$xcode_pid"
  local status=$?
  xcode_end_ms="$(ios_test_now_ms)"
  TEST_INVOCATION_MS=$(( xcode_end_ms - xcode_start_ms ))
  XCODEBUILD_MS=$(( BUILD_FOR_TESTING_MS + TEST_INVOCATION_MS ))
  CURRENT_XCODE_PID=""
  stop_ui_test_recording
  release_test_device_lock
  if ! current_line="$(test_log_line_count "$TMPOUT")"; then
    [[ "$log_missing" -eq 1 ]] && write_missing_test_log_marker "$TMPOUT" || true
    current_line="$(test_log_line_count "$TMPOUT" 2>/dev/null || echo 0)"
  fi
  if [[ "$current_line" -gt "$last_line" ]]; then
    emit_new_test_output "$((last_line + 1))" "$current_line"
  fi
  return "$status"
}

rebuild_test_cache() {
  local build_log="$1" build_result_bundle="$2"
  local build_start_ms build_end_ms
  mkdir -p "$DERIVED_DATA_ROOT"
  # Acquire the build lock ONLY for the write to shared DerivedData, and release
  # the moment the build finishes — test execution runs unlocked.
  acquire_build_lock
  # Keyed caches grow unbounded (one full DerivedData per config hash; 94G on
  # 2026-06-10 → exit=73 disk full). Evict under the build lock — unlocked
  # readers are protected by resolve-time touch + the min-age window.
  kg_ios_cache_evict "$TEST_CACHE_ROOT" "$(basename "$DERIVED_DATA_ROOT")"
  # Double-checked locking: another agent may have built this exact (content-keyed)
  # cache while we waited for the lock. If the products are now ready, skip the
  # rebuild — both to avoid redundant work and, critically, to avoid overwriting
  # products another agent may already be reading during its unlocked test run.
  local _xctestrun build_rc disk_budget_project_root
  _xctestrun="$(ios_test_find_xctestrun "$DERIVED_DATA_ROOT" 2>/dev/null || true)"
  if [[ -n "$_xctestrun" ]] && ios_test_cache_is_complete "$_xctestrun"; then
    # Waiter path: another agent built this exact cache while we held/waited for
    # the lock. We skipped the rebuild, so this run is a (lock-serialized) HIT,
    # not a builder — let the caller label cacheStatus truthfully.
    REBUILD_DID_BUILD=0
    release_build_lock
    return 0
  fi
  # TEST_CACHE_ROOT is anchored at the git-common project root for linked
  # worktrees. Pass that same anchor so the aggregate preflight measures the
  # shared test cache instead of reporting the worktree-local .cache as empty.
  disk_budget_project_root="$(dirname "$(dirname "$TEST_CACHE_ROOT")")"
  local preflight_rc=0
  kg_ios_disk_budget_preflight "$disk_budget_project_root" "test" || preflight_rc=$?
  if (( preflight_rc != 0 )); then
    kg_ios_disk_budget_blocked_hint "[ios_test]" "$preflight_rc"
    release_build_lock
    return "$preflight_rc"
  fi
  REBUILD_DID_BUILD=1
  # A previous build may have been interrupted, leaving a partial cache with no
  # sentinel. Clear the stale completion marker before rebuilding so a crash
  # mid-build below can never leave an old sentinel pointing at fresh-but-partial
  # products.
  rm -f "$DERIVED_DATA_ROOT/$IOS_TEST_CACHE_SENTINEL" 2>/dev/null || true
  # Separate baseline from ios_build.sh because build-for-testing also compiles
  # test targets and has a higher event count (~1390 vs ~1100 for a plain build).
  local bft_baseline="$DERIVED_DATA_ROOT/kg_build_for_testing.events_baseline"
  build_start_ms="$(ios_test_now_ms)"
  local bft_start_s bft_monitor_pid
  bft_start_s=$(date +%s)
  bft_monitor_pid=$(start_build_monitor "$build_log" "$bft_baseline" "[ios_test][build-for-testing]" "$bft_start_s")
  xcodebuild build-for-testing \
    -project "$XCODEPROJ" \
    -scheme "$TEST_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    ${IOS_TEST_SIGNING_ARGS[@]+"${IOS_TEST_SIGNING_ARGS[@]}"} \
    ${COVERAGE_XCODEBUILD_ARGS[@]+"${COVERAGE_XCODEBUILD_ARGS[@]}"} \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance "$MAX_TEST_EXECUTION_TIME_ALLOWANCE" \
    -derivedDataPath "$DERIVED_DATA_ROOT" \
    "${KG_IOS_SWIFTPM_XCODEBUILD_ARGS[@]+"${KG_IOS_SWIFTPM_XCODEBUILD_ARGS[@]}"}" \
    -resultBundlePath "$build_result_bundle" \
    >"$build_log" 2>&1
  build_rc=$?
  kill "$bft_monitor_pid" 2>/dev/null || true
  wait "$bft_monitor_pid" 2>/dev/null || true
  build_end_ms="$(ios_test_now_ms)"
  BUILD_FOR_TESTING_MS=$(( build_end_ms - build_start_ms ))
  local bft_compile_count
  bft_compile_count=$(count_compile_events "$build_log")
  echo "[ios_test][build-for-testing] caller=$CALLER finished (${BUILD_FOR_TESTING_MS}ms, ${bft_compile_count} compile events, exit=$build_rc)"
  if [[ "$build_rc" -eq 0 && "$bft_compile_count" -gt 0 ]]; then
    echo "$bft_compile_count" > "$bft_baseline"
  fi
  # Mark the cache complete ONLY when the build exited 0 AND produced ready
  # products — written while still holding the lock so the sentinel is atomic
  # with the build from a concurrent agent's view. An interrupted build never
  # reaches here (cleanup runs instead), so no sentinel is written and the next
  # agent rebuilds.
  if [[ "$build_rc" -eq 0 ]]; then
    _xctestrun="$(ios_test_find_xctestrun "$DERIVED_DATA_ROOT" 2>/dev/null || true)"
    if [[ -n "$_xctestrun" ]] && ios_test_cached_products_ready "$_xctestrun"; then
      : > "$DERIVED_DATA_ROOT/$IOS_TEST_CACHE_SENTINEL"
    fi
  fi
  release_build_lock
  # Propagate the real build-for-testing exit code. A compile failure (build_rc
  # != 0) MUST surface here so callers print the build log (the actual compiler
  # diagnostics) instead of the misleading "no .xctestrun artifact" message —
  # fail loud, no silent fallback.
  return "$build_rc"
}

ensure_xctestrun_ready_or_fail() {
  local xctestrun_path="$1"
  if [[ -z "$xctestrun_path" || ! -f "$xctestrun_path" ]]; then
    local discovered_xctestruns
    discovered_xctestruns="$(ios_test_list_xctestrun_artifacts "$DERIVED_DATA_ROOT" | sed 's#^#[ios_test] discovered=#')"
    cat >"$TMPOUT" <<EOF
[ios_test] error: build-for-testing completed but no .xctestrun artifact was found
[ios_test] derivedDataRoot=$DERIVED_DATA_ROOT
[ios_test] scheme=$TEST_SCHEME
[ios_test] destination=$DESTINATION
EOF
    [[ -n "$discovered_xctestruns" ]] && printf '%s\n' "$discovered_xctestruns" >>"$TMPOUT"
    return 1
  fi
  if ! ios_test_cached_products_ready "$xctestrun_path"; then
    cat >"$TMPOUT" <<EOF
[ios_test] error: .xctestrun exists but cached test products are incomplete
[ios_test] xctestrun=$xctestrun_path
[ios_test] derivedDataRoot=$DERIVED_DATA_ROOT
EOF
    return 1
  fi
}

prepare_ui_step_screenshot_dir() {
  UI_TEST_SCREENSHOT_DIR=""
  UI_TEST_CONTACT_SHEET=""
  UI_TEST_QUICK4_SHEET=""
  UI_TEST_SCREENSHOT_MANIFEST=""
  UI_TEST_VIDEO=""
  UI_TEST_VIDEO_FILE=""
  UI_TEST_VIDEO_SHA256=""
  [[ "$TEST_SCOPE" == "ui" || "$TEST_SCOPE" == "all" ]] || return 0
  UI_TEST_SCREENSHOT_DIR="$(artifact_temp_dir kg_ios_ui_steps)"
}

# Explicit simulator UDID for this run, when one exists: leased pool sim, or a
# --device/--destination that carries `id=`. Name-based default destinations
# return 1 (no recording / no device field) — `simctl io booted` would be
# ambiguous with several pool sims booted.
resolve_run_device_udid() {
  if [[ -n "${LEASED_DEVICE:-}" ]]; then
    printf '%s\n' "$LEASED_DEVICE"
    return 0
  fi
  case "${DESTINATION:-}" in
    *"id="*) printf '%s\n' "${DESTINATION##*id=}"; return 0 ;;
  esac
  if [[ -n "${RESOLVED_DEVICE_UDID:-}" ]]; then
    printf '%s\n' "$RESOLVED_DEVICE_UDID"
    return 0
  fi
  return 1
}

# Screen recording around the UI-scope test invocation. The mp4 lands next to
# the step screenshots so the whole visual-evidence trio+video shares one dir.
start_ui_test_recording() {
  [[ "$VISUAL_CAPTURE_ENABLED" == "1" ]] || return 0
  [[ -n "${UI_TEST_SCREENSHOT_DIR:-}" && -d "${UI_TEST_SCREENSHOT_DIR:-}" ]] || return 0
  local udid
  if ! udid="$(resolve_run_device_udid)"; then
    echo "[ios_test][ui-video] skip: no explicit simulator udid (use --lease or --device <udid>)"
    return 0
  fi
  UI_TEST_VIDEO_LOCK_FILE="/tmp/kg-ios-ui-video.lock"
  if ! kg_ios_wait_for_shlock "[ios_test]" "ui-video" "$UI_TEST_VIDEO_LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL" post-sleep; then
    kg_ios_lock_timeout_die "[ios_test]" "ui-video" "host-recorder" "$TIMEOUT"
  fi
  UI_TEST_VIDEO_LOCK_HELD=1
  UI_TEST_VIDEO="$UI_TEST_SCREENSHOT_DIR/run_recording.mp4"
  UI_TEST_VIDEO_LOG="$UI_TEST_SCREENSHOT_DIR/recording.log"
  UI_TEST_VIDEO_STARTED=0
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$UI_TEST_VIDEO" >"$UI_TEST_VIDEO_LOG" 2>&1 &
  UI_TEST_VIDEO_PID=$!
  local waited=0
  while [[ "$waited" -lt 100 ]]; do
    if grep -q 'Recording started' "$UI_TEST_VIDEO_LOG" 2>/dev/null; then
      UI_TEST_VIDEO_STARTED=1
      break
    fi
    if ! kill -0 "$UI_TEST_VIDEO_PID" 2>/dev/null; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if [[ "$UI_TEST_VIDEO_STARTED" -ne 1 ]]; then
    echo "[ios_test][ui-video] error: recorder did not start udid=$udid pid=$UI_TEST_VIDEO_PID" >&2
    cat "$UI_TEST_VIDEO_LOG" >&2 || true
    stop_ui_test_recording || true
    return 1
  fi
  echo "[ios_test][ui-video] recording started udid=$udid pid=$UI_TEST_VIDEO_PID out=$UI_TEST_VIDEO log=$UI_TEST_VIDEO_LOG"
}

stop_ui_test_recording() {
  if [[ -n "${UI_TEST_VIDEO_PID:-}" ]] && kill -0 "$UI_TEST_VIDEO_PID" 2>/dev/null; then
    # simctl finalizes the mp4 container on SIGINT; give it a bounded window
    # before escalating, else a wedged recorder would hang the verdict path.
    kill -INT "$UI_TEST_VIDEO_PID" 2>/dev/null || true
    local waited=0
    while kill -0 "$UI_TEST_VIDEO_PID" 2>/dev/null && [[ "$waited" -lt 100 ]]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    kill -0 "$UI_TEST_VIDEO_PID" 2>/dev/null && kill -9 "$UI_TEST_VIDEO_PID" 2>/dev/null || true
  fi
  if [[ -n "${UI_TEST_VIDEO_PID:-}" ]]; then
    wait "$UI_TEST_VIDEO_PID" 2>/dev/null || true
  fi
  UI_TEST_VIDEO_PID=""
  if [[ -n "${UI_TEST_VIDEO:-}" && -s "${UI_TEST_VIDEO:-}" ]]; then
    echo "[ios_test][ui-video] saved $UI_TEST_VIDEO"
  else
    if [[ -n "${UI_TEST_VIDEO:-}" ]]; then
      echo "[ios_test][ui-video] warning: recording missing or empty out=$UI_TEST_VIDEO" >&2
    fi
    UI_TEST_VIDEO=""
  fi
  UI_TEST_VIDEO_STARTED=0
  if [[ "${UI_TEST_VIDEO_LOCK_HELD:-0}" -eq 1 ]]; then
    kg_ios_release_shlock_if_owner "$UI_TEST_VIDEO_LOCK_FILE" "$$"
    UI_TEST_VIDEO_LOCK_HELD=0
  fi
}

# Move the finalized recording out of the step temp dir into this run's
# artifact root when a visual run explicitly owns one; direct behavior tests
# never start a recorder. A report helper may later promote the run bundle.
archive_ui_test_recording() {
  [[ "$VISUAL_CAPTURE_ENABLED" == "1" ]] || return 0
  [[ -n "${UI_TEST_VIDEO:-}" && -s "${UI_TEST_VIDEO:-}" ]] || return 0
  local archived
  local archive_root="${KG_IOS_VISUAL_ROOT:-${TMPDIR:-/tmp}/kg-ios-visual-direct/$UI_TEST_RUN_ID}/videos"
  [[ -n "${IOS_ARTIFACT_ROOT:-}" ]] && archive_root="$IOS_ARTIFACT_ROOT/videos"
  if archived="$(uitest_video_archive "$UI_TEST_VIDEO" \
      "$archive_root" \
      "$TEST_SCOPE" "$CALLER" "" "$UI_TEST_RUN_ID")" && [[ -n "$archived" ]]; then
    UI_TEST_VIDEO="$archived"
    echo "[ios_test][ui-video] archived $archived"
  else
    echo "[ios_test][ui-video] warning: archive failed, keeping tmp path $UI_TEST_VIDEO" >&2
  fi
  UI_TEST_VIDEO_FILE="$(basename "$UI_TEST_VIDEO")"
  UI_TEST_VIDEO_SHA256="$(shasum -a 256 "$UI_TEST_VIDEO" | awk '{print $1}')"
}

build_ui_test_review_page() {
  local review_status="${1:-}"
  [[ "$TEST_SCOPE" == "ui" || "$TEST_SCOPE" == "all" ]] || return 0
  [[ "$VISUAL_CAPTURE_ENABLED" == "1" ]] || return 0

  local stem fallback_input_dir=""
  stem="$UI_TEST_RUN_ID"
  local review_parent="${KG_IOS_VISUAL_ROOT:-${TMPDIR:-/tmp}/kg-ios-visual-direct}/review"
  [[ -n "${IOS_ARTIFACT_ROOT:-}" ]] && review_parent="$IOS_ARTIFACT_ROOT/review"
  mkdir -p "$review_parent"
  UI_TEST_REVIEW_ROOT="$review_parent/$stem"
  if ! mkdir "$UI_TEST_REVIEW_ROOT"; then
    echo "[ios_test][ui-review] error: refusing to overwrite existing review root=$UI_TEST_REVIEW_ROOT" >&2
    return 1
  fi

  if [[ -z "${UI_TEST_SCREENSHOT_DIR:-}" || ! -d "$UI_TEST_SCREENSHOT_DIR" ]]; then
    # Reserve the output root exclusively but keep generator inputs elsewhere:
    # uitest_review_page intentionally refuses a non-empty output root.
    fallback_input_dir="$(artifact_temp_dir kg_ios_ui_review_input)"
    UI_TEST_SCREENSHOT_DIR="$fallback_input_dir"
  fi
  if [[ -z "${UI_TEST_SCREENSHOT_MANIFEST:-}" || ! -s "$UI_TEST_SCREENSHOT_MANIFEST" ]]; then
    UI_TEST_SCREENSHOT_MANIFEST="$UI_TEST_SCREENSHOT_DIR/input_review_manifest.json"
    jq -nc --arg flow "$UI_TEST_FLOW_ID" --arg variant "$UI_TEST_VARIANT_ID" \
      '{
        schema:"kg.visual-review.sheet.v1",
        source:"uitest",
        title:$flow,
        variant:$variant,
        items:[]
      }' >"$UI_TEST_SCREENSHOT_MANIFEST"
  fi

  local args=(
    "$SCRIPT_DIR/uitest_review_page.py"
    --screenshot-dir "$UI_TEST_SCREENSHOT_DIR"
    --manifest "$UI_TEST_SCREENSHOT_MANIFEST"
    --out-root "$UI_TEST_REVIEW_ROOT"
    --flow-id "$UI_TEST_FLOW_ID"
    --variant-id "$UI_TEST_VARIANT_ID"
    --test-file "${FILE_PATH:-}"
    --device "$(resolve_run_device_udid 2>/dev/null || true)"
    --log "$TMPOUT"
    --json
  )
  [[ -n "$review_status" ]] && args+=(--status "$review_status")
  [[ -n "${UI_TEST_CONTACT_SHEET:-}" ]] && args+=(--contact-sheet "$UI_TEST_CONTACT_SHEET")
  [[ -n "${UI_TEST_QUICK4_SHEET:-}" ]] && args+=(--quick4-sheet "$UI_TEST_QUICK4_SHEET")
  [[ -n "${UI_TEST_VIDEO:-}" ]] && args+=(--video "$UI_TEST_VIDEO")

  local payload
  if payload="$("${args[@]}" 2>/dev/null)" && [[ -n "$payload" ]]; then
    UI_TEST_REVIEW_HTML="$(printf '%s' "$payload" | jq -r '.html // empty' 2>/dev/null || true)"
    if [[ -n "$fallback_input_dir" ]]; then
      rm -rf "$fallback_input_dir"
      UI_TEST_SCREENSHOT_DIR="$UI_TEST_REVIEW_ROOT"
      UI_TEST_SCREENSHOT_MANIFEST="$UI_TEST_REVIEW_ROOT/review_manifest.json"
    fi
    echo "[ios_test][ui-review] html=$UI_TEST_REVIEW_HTML"
  else
    [[ -n "$fallback_input_dir" ]] && rm -rf "$fallback_input_dir"
    echo "[ios_test][ui-review] warning: failed to build standalone UIreview root=$UI_TEST_REVIEW_ROOT" >&2
    rmdir "$UI_TEST_REVIEW_ROOT" 2>/dev/null || true
    UI_TEST_REVIEW_ROOT=""
    UI_TEST_REVIEW_HTML=""
  fi
}

build_ui_step_contact_sheet() {
  [[ "$VISUAL_CAPTURE_ENABLED" == "1" ]] || return 0
  [[ -n "${UI_TEST_SCREENSHOT_DIR:-}" && -d "$UI_TEST_SCREENSHOT_DIR" ]] || return 0
  if ! compgen -G "$UI_TEST_SCREENSHOT_DIR/*.png" >/dev/null; then
    export_ui_step_attachments_from_xcresult
  fi
  compgen -G "$UI_TEST_SCREENSHOT_DIR/*.png" >/dev/null || return 0

  UI_TEST_SCREENSHOT_MANIFEST="$UI_TEST_SCREENSHOT_DIR/review_manifest.json"
  UI_TEST_CONTACT_SHEET="$UI_TEST_SCREENSHOT_DIR/contact_sheet.png"
  local provenance_args=(
    --source-commit "$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
    --dataset-id "$EVIDENCE_DATASET_ID"
    --dataset-sha256 "$EVIDENCE_DATASET_SHA256"
    --provenance-device "$(resolve_run_device_udid 2>/dev/null || true)"
    --selector "${KG_UI_TEST_EXACT_SELECTOR:-$UI_TEST_FLOW_ID}"
    --variant "$UI_TEST_VARIANT_ID"
  )
  if "$SCRIPT_DIR/uitest_contact_sheet.py" "$UI_TEST_SCREENSHOT_DIR" \
      --source uitest \
      --appearance light \
      --cols 3 \
      --cell-width 260 \
      "${provenance_args[@]}" \
      --out "$UI_TEST_CONTACT_SHEET" \
      --manifest-out "$UI_TEST_SCREENSHOT_MANIFEST" \
      --json >/dev/null 2>&1; then
    echo "[ios_test][ui-steps] screenshots=$UI_TEST_SCREENSHOT_DIR contactSheet=$UI_TEST_CONTACT_SHEET"
  else
    echo "[ios_test][ui-steps] warning: failed to build contact sheet dir=$UI_TEST_SCREENSHOT_DIR" >&2
    UI_TEST_CONTACT_SHEET=""
    UI_TEST_SCREENSHOT_MANIFEST=""
    return 0
  fi

  # Quick visual summary — four evenly-spaced steps in one row, large cells —
  # so agents can eyeball the flow without opening the full sheet.
  UI_TEST_QUICK4_SHEET="$UI_TEST_SCREENSHOT_DIR/quick4_contact_sheet.png"
  if "$SCRIPT_DIR/uitest_contact_sheet.py" "$UI_TEST_SCREENSHOT_DIR" \
      --source uitest \
      --appearance light \
      --take evenly:4 \
      --cols 4 \
      --cell-width 380 \
      "${provenance_args[@]}" \
      --out "$UI_TEST_QUICK4_SHEET" \
      --json >/dev/null 2>&1; then
    echo "[ios_test][ui-steps] quick4=$UI_TEST_QUICK4_SHEET"
  else
    echo "[ios_test][ui-steps] warning: failed to build quick4 sheet dir=$UI_TEST_SCREENSHOT_DIR" >&2
    UI_TEST_QUICK4_SHEET=""
  fi
}

export_ui_step_attachments_from_xcresult() {
  [[ -n "${RESULT_BUNDLE:-}" && -d "$RESULT_BUNDLE" ]] || return 0
  [[ -n "${UI_TEST_SCREENSHOT_DIR:-}" && -d "$UI_TEST_SCREENSHOT_DIR" ]] || return 0

  local attachment_dir
  attachment_dir="$(artifact_temp_dir kg_ios_ui_attachments)"
  if ! xcrun xcresulttool export attachments \
      --path "$RESULT_BUNDLE" \
      --output-path "$attachment_dir" >/dev/null 2>&1; then
    rm -rf "$attachment_dir"
    return 0
  fi

  if ! uv run --python 3.13 python - "$attachment_dir" "$UI_TEST_SCREENSHOT_DIR" <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
manifest = source / "manifest.json"
if not manifest.exists():
    raise SystemExit(0)

seen: set[str] = set()
for test in json.loads(manifest.read_text(encoding="utf-8")):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "")
        # XCTest may append an attachment UUID before a semantic suffix and
        # omit the final `.png` (for example, `Step 02-state_0_UUID.card`).
        # Recover the original capture filename instead of silently dropping
        # that step from the stable review bundle.
        match = re.match(
            r"^Step (?P<step>[0-9]{2}-.+?)(?:_0_[0-9A-F-]{36})(?P<suffix>\.[A-Za-z0-9._-]+)?$",
            name,
        )
        if match:
            step_name = match.group("step") + (match.group("suffix") or "")
        else:
            match = re.match(r"^Step ([0-9]{2}-.+)\.png$", name)
            if not match:
                continue
            step_name = match.group(1)
        if not step_name.endswith(".png"):
            step_name += ".png"
        if step_name in seen:
            continue
        exported = attachment.get("exportedFileName", "")
        source_file = source / exported
        if not source_file.exists():
            continue
        shutil.copyfile(source_file, target / step_name)
        seen.add(step_name)
PY
  then
    echo "[ios_test][ui-steps] warning: failed to export step attachments from xcresult=$RESULT_BUNDLE" >&2
  fi
  rm -rf "$attachment_dir"
}

if [[ -n "$TEST_CACHE_ACTION" ]]; then
  # Under --json, stdout carries exactly one payload document (#3331). Every progress
  # line the cache build emits (build-for-testing, disk budget, locks) goes to stderr,
  # so no helper can corrupt the payload, and the payload is written to fd 9.
  if (( JSON_MODE )); then
    exec 9>&1 1>&2
  fi
  handle_cache_action "$TEST_CACHE_ACTION"
fi

# Run xcodebuild test, capture output to parse results. Xcode can keep the
# shared DerivedData build database locked briefly after the previous simulator
# test process exits, so retry that infrastructure failure before surfacing it.
MAX_BUILD_DB_LOCK_RETRIES=3
ATTEMPT=1
EXIT_CODE=0
boot_simulator_if_needed
DERIVED_DATA_ROOT="$(ios_test_derived_data_root)"
# LRU liveness: mark this key as in-use even on the unlocked cache-hit path,
# so a concurrent builder's eviction never removes products mid-read.
[[ -d "$DERIVED_DATA_ROOT" ]] && touch "$DERIVED_DATA_ROOT" 2>/dev/null || true
XCTESTRUN_PATH="$(ios_test_find_xctestrun "$DERIVED_DATA_ROOT" || true)"
[[ -z "$XCTESTRUN_OVERRIDE" ]] || XCTESTRUN_PATH="$XCTESTRUN_OVERRIDE"
while :; do
  # A retry/rebuild is a new attempt; a timeout reason must not leak into its
  # final verdict if the later attempt fails for another reason.
  INCONCLUSIVE_REASON=""
  [[ -n "$TMPOUT" ]] && rm -f "$TMPOUT"
  TMPOUT="$(artifact_temp_file kg_ios_test_log)"
  [[ -n "$RESULT_DIR" ]] && rm -rf "$RESULT_DIR"
  RESULT_DIR="$(artifact_temp_dir kg_ios_test_result)"
  RESULT_BUNDLE="$RESULT_DIR/Test.xcresult"
  prepare_ui_step_screenshot_dir
  set +e
  BUILD_FOR_TESTING_MS=0
  TEST_INVOCATION_MS=0
  if [[ -n "$XCTESTRUN_OVERRIDE" ]]; then
    # Prebuilt CI products (#3331): test-without-building only. This run has no build
    # inputs to rebuild from, so a failure surfaces as a failure and never compiles.
    CACHE_STATUS="hit"
    run_xcodebuild_test_without_building_once "$XCTESTRUN_PATH"
    EXIT_CODE=$?
  elif ios_test_cache_is_complete "$XCTESTRUN_PATH"; then
    CACHE_STATUS="hit"
    run_xcodebuild_test_without_building_once "$XCTESTRUN_PATH"
    EXIT_CODE=$?
    if [[ "$EXIT_CODE" -ne 0 ]] && should_rebuild_after_test_without_building_failure; then
      CACHE_STATUS="rebuild-after-failure"
      INCONCLUSIVE_REASON=""
      BUILD_LOG="$(artifact_temp_file kg_ios_test_build_log)"
      BUILD_RESULT_DIR="$(artifact_temp_dir kg_ios_test_build_result)"
      BUILD_RESULT_BUNDLE="$BUILD_RESULT_DIR/BuildForTesting.xcresult"
      rebuild_test_cache "$BUILD_LOG" "$BUILD_RESULT_BUNDLE"
      BUILD_EXIT=$?
      if [[ "$BUILD_EXIT" -eq 0 ]]; then
        XCTESTRUN_PATH="$(ios_test_find_xctestrun "$DERIVED_DATA_ROOT" || true)"
        if ensure_xctestrun_ready_or_fail "$XCTESTRUN_PATH"; then
          run_xcodebuild_test_without_building_once "$XCTESTRUN_PATH"
          EXIT_CODE=$?
        else
          EXIT_CODE=1
        fi
      else
        cat "$BUILD_LOG" >"$TMPOUT"
        EXIT_CODE="$BUILD_EXIT"
      fi
      rm -f "$BUILD_LOG"
      rm -rf "$BUILD_RESULT_DIR"
    fi
  else
    CACHE_STATUS="miss"
    BUILD_LOG="$(artifact_temp_file kg_ios_test_build_log)"
    BUILD_RESULT_DIR="$(artifact_temp_dir kg_ios_test_build_result)"
    BUILD_RESULT_BUNDLE="$BUILD_RESULT_DIR/BuildForTesting.xcresult"
    rebuild_test_cache "$BUILD_LOG" "$BUILD_RESULT_BUNDLE"
    BUILD_EXIT=$?
    if [[ "$BUILD_EXIT" -eq 0 ]]; then
      XCTESTRUN_PATH="$(ios_test_find_xctestrun "$DERIVED_DATA_ROOT" || true)"
      if ensure_xctestrun_ready_or_fail "$XCTESTRUN_PATH"; then
        run_xcodebuild_test_without_building_once "$XCTESTRUN_PATH"
        EXIT_CODE=$?
        # Truthful label: "prepared" only if THIS run did the build; a concurrent
        # agent that waited on the lock and skipped the rebuild (double-check hit)
        # is a "hit", not a builder. Discriminated by REBUILD_DID_BUILD, not by
        # buildForTestingMs.
        if [[ "${REBUILD_DID_BUILD:-1}" -eq 1 ]]; then CACHE_STATUS="prepared"; else CACHE_STATUS="hit"; fi
      else
        EXIT_CODE=1
      fi
    else
      cat "$BUILD_LOG" >"$TMPOUT"
      EXIT_CODE="$BUILD_EXIT"
    fi
    rm -f "$BUILD_LOG"
    rm -rf "$BUILD_RESULT_DIR"
  fi
  set -e

  if is_build_db_lock_failure && [[ "$ATTEMPT" -le "$MAX_BUILD_DB_LOCK_RETRIES" ]]; then
    echo "[ios_test] build database locked; retrying xcodebuild attempt $((ATTEMPT + 1))/$((MAX_BUILD_DB_LOCK_RETRIES + 1)) after 10s" >&2
    sleep 10
    ATTEMPT=$((ATTEMPT + 1))
    continue
  fi
  break
done

TEST_EXECUTION_CLASSIFICATION="$(kg_ios_classify_test_execution "$EXIT_CODE" "$TMPOUT")"
IFS='|' read -r TEST_VERDICT TEST_EXIT TEST_REASON <<<"$TEST_EXECUTION_CLASSIFICATION"
case "$TEST_VERDICT" in
  inconclusive)
    EXIT_CODE="$TEST_EXIT"
    INCONCLUSIVE_REASON="$TEST_REASON"
    ;;
  fail)
    EXIT_CODE="$TEST_EXIT"
    ;;
esac

ELAPSED=$(( $(date +%s) - START ))
END_MS="$(ios_test_now_ms)"
TOTAL_MS=$(( END_MS - START_MS ))
DIAGNOSTICS="$SCRIPT_DIR/ios_diagnostics.py"
if [[ -x "$DIAGNOSTICS" ]]; then
  diag_result="fail"; [[ $EXIT_CODE -eq 0 ]] && diag_result="pass"
  "$DIAGNOSTICS" --kind test --xcresult "$RESULT_BUNDLE" --log "$TMPOUT" --result "$diag_result" --limit 40 || true
else
  echo "[ios_test] diagnostics unavailable: $DIAGNOSTICS" >&2
fi

# Count tests xcodebuild actually executed, so a SUCCEEDED with zero tests run
# (bogus -only-testing IDs → "TEST SUCCEEDED" but nothing executed) is caught as
# a false green instead of being reported as a pass. Sums both reporters:
#   XCTest:        "Executed N tests, ..."   (one line per suite)
#   Swift Testing: "✔ Test ... passed" / "✘ Test ... failed" per-test ticks,
#                  Xcode 26 "Test case 'Suite/test()' passed" lines,
#                  and "Test run with N test(s)" summary.
count_executed_tests() {
  local n xc st xc26
  # XCTest: sum the per-suite "Executed N tests" counts.
  xc=$(grep -oE 'Executed [0-9]+ test' "$TMPOUT" 2>/dev/null \
       | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
  xc=${xc:-0}
  # Swift Testing: count per-test pass/fail ticks (grep -c always prints one int).
  st=$(grep -cE '^[[:space:]]*[✔✘✓✗] Test .+ (passed|failed)' "$TMPOUT" 2>/dev/null)
  st=${st:-0}
  # Xcode 26 Swift Testing console output uses XCTest-style per-case rows.
  xc26=$(grep -cE "^Test case '.+' (passed|failed)" "$TMPOUT" 2>/dev/null)
  xc26=${xc26:-0}
  n=$(( xc + st + xc26 ))
  # Fallback: Swift Testing summary line "Test run with N test(s)".
  if [[ "$n" -eq 0 ]]; then
    n=$(grep -oE 'Test run with [0-9]+ test' "$TMPOUT" 2>/dev/null \
        | grep -oE '[0-9]+' | head -1)
    n=${n:-0}
  fi
  echo "$n"
}

count_executed_tests_xcresult() {
  local n
  [[ -n "$RESULT_BUNDLE" && -d "$RESULT_BUNDLE" ]] || return 1
  n="$("$SCRIPT_DIR/ios_diagnostics.py" --kind test --xcresult "$RESULT_BUNDLE" --json 2>/dev/null \
    | jq -r '.counts.effectiveTests // (.counts.passedTests + .counts.failedTests + .counts.expectedFailures) // empty' 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  echo "$n"
}

read_timing_breakdown_xcresult() {
  local diag_json body_ms session_ms app_launch_avg_ms app_launch_samples
  [[ -n "$RESULT_BUNDLE" && -d "$RESULT_BUNDLE" ]] || return 1
  diag_json="$("$SCRIPT_DIR/ios_diagnostics.py" --kind test --xcresult "$RESULT_BUNDLE" --json 2>/dev/null)" || return 1
  body_ms="$(jq -r '.timings.testBodyMs // empty' <<<"$diag_json" 2>/dev/null)" || return 1
  session_ms="$(jq -r '.timings.xcresultSessionMs // empty' <<<"$diag_json" 2>/dev/null)" || return 1
  app_launch_avg_ms="$(jq -r '.performanceMetrics.appLaunch.averageMs // 0' <<<"$diag_json" 2>/dev/null)" || return 1
  app_launch_samples="$(jq -r '.performanceMetrics.appLaunch.samples // 0' <<<"$diag_json" 2>/dev/null)" || return 1
  [[ "$body_ms" =~ ^[0-9]+$ && "$session_ms" =~ ^[0-9]+$ && "$app_launch_avg_ms" =~ ^[0-9]+$ && "$app_launch_samples" =~ ^[0-9]+$ ]] || return 1
  echo "$body_ms $session_ms $app_launch_avg_ms $app_launch_samples"
}

populate_timing_breakdown() {
  local breakdown body_ms session_ms app_launch_avg_ms app_launch_samples
  TEST_BODY_MS=0
  XCRESULT_SESSION_MS=0
  XCRESULT_HARNESS_OVERHEAD_MS=0
  INVOCATION_OVERHEAD_MS=0
  APP_LAUNCH_AVERAGE_MS=0
  APP_LAUNCH_SAMPLES=0
  breakdown="$(read_timing_breakdown_xcresult || true)"
  [[ -n "$breakdown" ]] || return 0
  read -r body_ms session_ms app_launch_avg_ms app_launch_samples <<<"$breakdown"
  [[ "$body_ms" =~ ^[0-9]+$ && "$session_ms" =~ ^[0-9]+$ && "$app_launch_avg_ms" =~ ^[0-9]+$ && "$app_launch_samples" =~ ^[0-9]+$ ]] || return 0
  TEST_BODY_MS="$body_ms"
  XCRESULT_SESSION_MS="$session_ms"
  APP_LAUNCH_AVERAGE_MS="$app_launch_avg_ms"
  APP_LAUNCH_SAMPLES="$app_launch_samples"
  XCRESULT_HARNESS_OVERHEAD_MS=$(( XCRESULT_SESSION_MS - TEST_BODY_MS ))
  if (( XCRESULT_HARNESS_OVERHEAD_MS < 0 )); then
    XCRESULT_HARNESS_OVERHEAD_MS=0
  fi
  INVOCATION_OVERHEAD_MS=$(( TEST_INVOCATION_MS - XCRESULT_SESSION_MS ))
  if (( INVOCATION_OVERHEAD_MS < 0 )); then
    INVOCATION_OVERHEAD_MS=0
  fi
}

print_timing_summary() {
  echo "[ios_test] timings cacheStatus=$CACHE_STATUS uiLaunchProfile=${UI_LAUNCH_PROFILE:-standard} deviceRunLockWaitMs=$DEVICE_RUN_LOCK_WAIT_MS bootMs=$BOOT_MS buildForTestingMs=$BUILD_FOR_TESTING_MS testInvocationMs=$TEST_INVOCATION_MS testBodyMs=$TEST_BODY_MS xcresultSessionMs=$XCRESULT_SESSION_MS xcresultHarnessOverheadMs=$XCRESULT_HARNESS_OVERHEAD_MS appLaunchAverageMs=$APP_LAUNCH_AVERAGE_MS appLaunchSamples=$APP_LAUNCH_SAMPLES invocationOverheadMs=$INVOCATION_OVERHEAD_MS xcodebuildMs=$XCODEBUILD_MS totalMs=$TOTAL_MS"
}

COVERAGE_JSON='null'
COVERAGE_VERDICT="not-requested"
COVERAGE_REASON=""
populate_coverage_summary() {
  [[ "$COVERAGE_ENABLED" -eq 1 ]] || return 0
  local coverage_args=("$SCRIPT_DIR/ios_coverage.py" "--xcresult" "$RESULT_BUNDLE" "--target" "$COVERAGE_TARGET" "--json")
  if [[ -n "$COVERAGE_FAIL_UNDER" ]]; then
    coverage_args+=("--fail-under-lines" "$COVERAGE_FAIL_UNDER")
  fi
  local coverage_out coverage_rc=0
  if coverage_out="$(uv run --python 3.13 python "${coverage_args[@]}" 2>/dev/null)"; then
    coverage_rc=0
  else
    coverage_rc=$?
  fi
  if jq -e . >/dev/null 2>&1 <<<"$coverage_out"; then
    COVERAGE_JSON="$(jq -c . <<<"$coverage_out")"
    COVERAGE_VERDICT="$(jq -r '.verdict // "error"' <<<"$COVERAGE_JSON")"
  else
    COVERAGE_JSON="$(jq -nc --arg schema "kg.ios.coverage.v1" --arg error "coverage parser emitted invalid JSON" '{schema:$schema,verdict:"error",summary:{target:null,lineCoverage:null,coveredLines:null,executableLines:null,fileCount:0,lowestFiles:[]},thresholds:{lineCoverage:{failUnder:null}},targets:[],errors:[{key:"coverage-unavailable",status:"error",error:$error}]}')"
    COVERAGE_VERDICT="error"
  fi
  case "$COVERAGE_VERDICT" in
    pass) COVERAGE_REASON="" ;;
    fail) COVERAGE_REASON="coverage-fail-under" ;;
    *) COVERAGE_REASON="coverage-unavailable" ;;
  esac
  jq -r '"[ios][coverage] verdict=\(.verdict) target=\(.summary.target // "unknown") lineCoverage=\(.summary.lineCoverage // "unknown") coveredLines=\(.summary.coveredLines // "unknown") executableLines=\(.summary.executableLines // "unknown") fileCount=\(.summary.fileCount // 0) failUnder=\(.thresholds.lineCoverage.failUnder // "none")"' <<<"$COVERAGE_JSON"
  jq -r '(.summary.lowestFiles // [])[0:3][] | "[ios][coverage][low] file=\(.path // .name) lineCoverage=\(.lineCoverage // "unknown") coveredLines=\(.coveredLines // "unknown") executableLines=\(.executableLines // "unknown")"' <<<"$COVERAGE_JSON"
  return "$coverage_rc"
}

emit_ui_runner_lifecycle() {
  [[ "$TEST_SCOPE" == "ui" || "$TEST_SCOPE" == "all" ]] || return 0
  local device="${SIMULATOR_BOOT_SELECTOR:-}" safe_device screenshot_path
  [[ -n "$device" ]] || return 0

  echo "[ios_test][ui-lifecycle] destination=$DESTINATION device=$device" >&2
  xcrun simctl list devices available 2>/dev/null \
    | grep -F "$device" \
    | sed 's/^/[ios_test][ui-lifecycle] device-state /' >&2 || true
  xcrun simctl spawn "$device" launchctl print user/501/com.apple.testmanagerd 2>/dev/null \
    | awk '
        /state =|pid =|runs =|last exit code =|active count =/ {
          gsub(/^[[:space:]]+/, "", $0)
          print "[ios_test][ui-lifecycle] testmanagerd " $0
        }
      ' >&2 || echo "[ios_test][ui-lifecycle] testmanagerd unavailable" >&2
  xcrun simctl spawn "$device" /bin/ps -axo pid,ppid,stat,comm,args 2>/dev/null \
    | grep -E 'BooksAndVocab|UITests-Runner|testmanagerd' \
    | sed 's/^/[ios_test][ui-lifecycle] process /' >&2 || echo "[ios_test][ui-lifecycle] process none" >&2
  safe_device="$(printf '%s' "$device" | tr -c '[:alnum:]._- ' '_')"
  if [[ "$VISUAL_CAPTURE_ENABLED" == "1" ]]; then
    screenshot_path="${TMPDIR:-/tmp}/kg_ios_ui_lifecycle_${safe_device}_$$.png"
    if xcrun simctl io "$device" screenshot "$screenshot_path" >/dev/null 2>&1; then
      echo "[ios_test][ui-lifecycle] screenshot=$screenshot_path" >&2
    else
      echo "[ios_test][ui-lifecycle] screenshot unavailable" >&2
    fi
  fi
}

# Machine-readable verdict file — survives even when stdout/stderr is piped
# (e.g. `ios_test.sh | tail`, where the pipeline's exit code is tail's, not the
# script's). Read this instead of trusting a piped `$?`.
#
# Per-invocation UNIQUE path (multi-session race guard): VERDICT_FILE is
# `kg_ios_test_verdict.<epochTs>-<pid>` (or KG_IOS_VERDICT_FILE when a wrapper
# pins it), so a session can never mistake another session's verdict for its
# own AND the run-metrics source has no concurrent writer (the old
# fixed-path-then-private-copy dance is gone). The historical fixed path stays
# as a last-writer-wins LATEST pointer for `ios_ops runs`. See
# ops/lib/ios_run_verdict.sh.
validate_p9_review_calendar_sidecar() {
  local manifest_path="$1" verdict_path="$2"
  [[ -s "$manifest_path" ]] || return 0
  "$UV_BIN" run --python 3.13 python "$PROJECT_ROOT/ops/p9_review_calendar_evidence.py" validate \
    "$manifest_path" \
    --workspace-root "$UI_TEST_SCREENSHOT_DIR" \
    --outer-verdict "$verdict_path" \
    >/dev/null
}

retrieve_p9_installed_fixture_proof() {
  local manifest_path="$UI_TEST_SCREENSHOT_DIR/p9_review_calendar_review_manifest.json"
  [[ -s "$manifest_path" ]] || return 0
  [[ -n "$EVIDENCE_DATASET_ID" ]] || {
    echo "[ios_test] error: P9 sidecar exists without datasetID" >&2
    return 1
  }
  local device
  device="$(resolve_run_device_udid 2>/dev/null || true)"
  [[ -n "$device" ]] || {
    echo "[ios_test] error: cannot resolve device for P9 installed proof retrieval" >&2
    return 1
  }
  local destination="$UI_TEST_SCREENSHOT_DIR/installed-fixtures/$EVIDENCE_DATASET_ID.json"
  mkdir -p "$(dirname "$destination")"
  local pull_args=(pull "Documents/Evidence/$EVIDENCE_DATASET_ID.json" "$destination" --device "$device" --app "com.Max0228.BooksBrowser")
  if [[ "$(ios_test_sdk_suffix)" == "iphonesimulator" ]]; then
    pull_args+=(--simulator)
  fi
  if ! "$PROJECT_ROOT/ops/ios_device_files.sh" "${pull_args[@]}" >/dev/null; then
    echo "[ios_test] error: failed to retrieve app-installed P9 proof" >&2
    return 1
  fi
  [[ -s "$destination" ]] || {
    echo "[ios_test] error: retrieved P9 proof is missing or empty: $destination" >&2
    return 1
  }
  return 0
}

write_json_verdict() {
  local result="$1" exit_code="$2" reason="$3" executed="$4"
  local source_commit source_tree_status source_tree_dirty marketing_version build_number bundle_id started_at finished_at evidence_kind fixture_data_used os_name network_mode p9_manifest p9_record_count
  source_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
  # The verdict names the commit this run came from, but the build tuple below is
  # read from the WORKING TREE's pbxproj. With uncommitted changes those two
  # describe different things, and app_review_evidence.py would still hand the run
  # to a clean SHA. Record the tree state so that attribution can be refused
  # rather than silently made. A `git status` that cannot answer (no repo, no git)
  # counts as dirty: "cannot tell" must never read as "clean".
  if source_tree_status="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)"; then
    if [[ -n "$source_tree_status" ]]; then source_tree_dirty=true; else source_tree_dirty=false; fi
  else
    source_tree_dirty=true
  fi
  marketing_version="$(awk -F' = ' '/MARKETING_VERSION = /{gsub(/[;[:space:]]/, "", $2); print $2; exit}' "$PROJECT_ROOT/ios/BooksAndVocab.xcodeproj/project.pbxproj")"
  build_number="$(awk -F' = ' '/CURRENT_PROJECT_VERSION = /{gsub(/[;[:space:]]/, "", $2); print $2; exit}' "$PROJECT_ROOT/ios/BooksAndVocab.xcodeproj/project.pbxproj")"
  bundle_id="$(awk -F' = ' '/PRODUCT_BUNDLE_IDENTIFIER = com.Max0228.BooksBrowser;/{gsub(/[;[:space:]]/, "", $2); print $2; exit}' "$PROJECT_ROOT/ios/BooksAndVocab.xcodeproj/project.pbxproj")"
  started_at="$(date -u -r "$START" '+%Y-%m-%dT%H:%M:%SZ')"
  finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  evidence_kind="$EVIDENCE_KIND"
  fixture_data_used=false
  [[ -n "$UI_FIXTURE_DATASET_FILE" ]] && fixture_data_used=true
  os_name="iOS Simulator"
  [[ "$(ios_test_sdk_suffix)" == iphoneos ]] && os_name="iOS"
  network_mode="fixture"
  [[ "$LIVE_DEMO" -eq 1 ]] && network_mode="live"
  p9_manifest=""
  p9_record_count=0
  if [[ -n "$UI_TEST_SCREENSHOT_DIR" && -s "$UI_TEST_SCREENSHOT_DIR/p9_review_calendar_review_manifest.json" ]]; then
    p9_manifest="$UI_TEST_SCREENSHOT_DIR/p9_review_calendar_review_manifest.json"
    p9_record_count="$(jq -r '.records | length' "$p9_manifest" 2>/dev/null || printf '0')"
  fi
  build_ui_test_review_page "$result"
  jq -nc \
    --arg schema "kg.ios.run-verdict.v1" \
    --arg kind "test" \
    --arg result "$result" \
    --arg exit "$exit_code" \
    --arg reason "$reason" \
    --arg caller "$CALLER" \
    --arg cwd "$PROJECT_ROOT" \
    --arg verdictFile "$VERDICT_FILE" \
    --argjson ts "$(date +%s)" \
    --argjson pid "$$" \
    --arg uiLaunchProfile "$UI_LAUNCH_PROFILE" \
    --arg configuration "$CONFIGURATION" \
    --arg evidenceProducer "ops/ios_test.sh" \
    --arg sourceCommit "$source_commit" \
    --argjson sourceTreeDirty "$source_tree_dirty" \
    --arg marketingVersion "$marketing_version" \
    --arg buildNumber "$build_number" \
    --arg bundleID "$bundle_id" \
    --arg datasetID "$EVIDENCE_DATASET_ID" \
    --arg datasetSHA256 "$EVIDENCE_DATASET_SHA256" \
    --arg fixedClock "$EVIDENCE_FIXED_CLOCK" \
    --arg startedAt "$started_at" \
    --arg finishedAt "$finished_at" \
    --arg evidenceKind "$evidence_kind" \
    --arg locale "$EVIDENCE_LOCALE" \
    --arg timezone "$EVIDENCE_TIMEZONE" \
    --arg appearance "$EVIDENCE_APPEARANCE" \
    --arg destination "$DESTINATION" \
    --arg osName "$os_name" \
    --arg networkMode "$network_mode" \
    --arg demoAccountIdentitySHA256 "$DEMO_ACCOUNT_IDENTITY_SHA256" \
    --argjson liveDemo "$LIVE_DEMO" \
    --argjson fixtureDataUsed "$fixture_data_used" \
    --arg elapsed "${ELAPSED}s" \
    --arg executed "$executed" \
    --arg log "$TMPOUT" \
    --arg xcresult "$RESULT_BUNDLE" \
    --arg uiContactSheet "$UI_TEST_CONTACT_SHEET" \
    --arg uiQuick4Sheet "$UI_TEST_QUICK4_SHEET" \
    --arg uiVisualReviewManifest "$UI_TEST_SCREENSHOT_MANIFEST" \
    --arg uiScreenshotDir "$UI_TEST_SCREENSHOT_DIR" \
    --arg uiVideo "$UI_TEST_VIDEO" \
    --arg uiVideoRunID "$UI_TEST_RUN_ID" \
    --arg uiVideoFile "$UI_TEST_VIDEO_FILE" \
    --arg uiVideoSHA256 "$UI_TEST_VIDEO_SHA256" \
    --arg uiReviewRoot "$UI_TEST_REVIEW_ROOT" \
    --arg uiReviewHtml "$UI_TEST_REVIEW_HTML" \
    --arg p9Manifest "$p9_manifest" \
    --arg p9Selector "$P9_REVIEW_CALENDAR_SELECTOR" \
    --argjson p9RecordCount "$p9_record_count" \
    --arg device "$(resolve_run_device_udid 2>/dev/null || true)" \
    --argjson lockWaitMs "${LOCK_WAIT_MS:-0}" \
    --argjson deviceRunLockWaitMs "${DEVICE_RUN_LOCK_WAIT_MS:-0}" \
    --argjson bootMs "$BOOT_MS" \
    --argjson xcodebuildMs "$XCODEBUILD_MS" \
    --argjson buildForTestingMs "$BUILD_FOR_TESTING_MS" \
    --argjson testInvocationMs "$TEST_INVOCATION_MS" \
    --argjson testBodyMs "$TEST_BODY_MS" \
    --argjson xcresultSessionMs "$XCRESULT_SESSION_MS" \
    --argjson xcresultHarnessOverheadMs "$XCRESULT_HARNESS_OVERHEAD_MS" \
    --argjson appLaunchAverageMs "$APP_LAUNCH_AVERAGE_MS" \
    --argjson appLaunchSamples "$APP_LAUNCH_SAMPLES" \
    --argjson invocationOverheadMs "$INVOCATION_OVERHEAD_MS" \
    --argjson totalMs "$TOTAL_MS" \
    --arg cacheStatus "$CACHE_STATUS" \
    --argjson coverage "$COVERAGE_JSON" \
    '{
      schema:$schema,
      kind:$kind,
      status:$result,
      result:$result,
      exit:$exit,
      reason:(if $reason == "" then null else $reason end),
      caller:$caller,
      invocation:{ts:$ts,pid:$pid,cwd:$cwd,verdictFile:$verdictFile},
      options:{
        uiLaunchProfile:(if $uiLaunchProfile == "" then null else $uiLaunchProfile end),
        evidenceProducer:$evidenceProducer,
        configuration:$configuration,
        bundleID:$bundleID,
        marketingVersion:$marketingVersion,
        buildNumber:$buildNumber,
        sourceCommit:$sourceCommit,
        sourceTreeDirty:$sourceTreeDirty,
        datasetID:(if $datasetID == "" then null else $datasetID end),
        datasetSHA256:(if $datasetSHA256 == "" then null else $datasetSHA256 end),
        fixedClock:(if $fixedClock == "" then null else $fixedClock end),
        startedAt:$startedAt,
        finishedAt:$finishedAt,
        evidenceKind:$evidenceKind,
        device:$destination,
        os:$osName,
        locale:(if $locale == "" then null else $locale end),
        timezone:(if $timezone == "" then null else $timezone end),
        appearance:(if $appearance == "" then null else $appearance end),
        networkMode:$networkMode,
        fixtureDataUsed:$fixtureDataUsed,
        liveDemoAccountIdentitySHA256:(if $liveDemo == 1 then $demoAccountIdentitySHA256 else null end)
      },
      demoEvidence:(if $liveDemo == 1 then {
        evidenceProducer:"ops/ios_test.sh:live-demo",
        configuration:$configuration,
        bundleID:$bundleID,
        marketingVersion:$marketingVersion,
        buildNumber:$buildNumber,
        sourceCommit:$sourceCommit,
        sourceTreeDirty:$sourceTreeDirty,
        evidenceKind:$evidenceKind,
        device:$destination,
        os:$osName,
        locale:(if $locale == "" then null else $locale end),
        timezone:(if $timezone == "" then null else $timezone end),
        networkMode:$networkMode,
        fixtureDataUsed:$fixtureDataUsed,
        account:{provenance:"live-account",accountRef:null,accountIdentitySHA256:$demoAccountIdentitySHA256,entitlementSource:"live-backend"},
        observedAt:$finishedAt,
        login:(if $result == "ok" then "pass" else "fail" end),
        entitlements:(if $result == "ok" then ["pro"] else [] end)
      } else null end),
      elapsed:$elapsed,
      executed:(if $executed == "" then null else $executed end),
      device:(if $device == "" then null else $device end),
      timings:{
        lockWaitMs:$lockWaitMs,
        deviceRunLockWaitMs:$deviceRunLockWaitMs,
        bootMs:$bootMs,
        xcodebuildMs:$xcodebuildMs,
        buildForTestingMs:$buildForTestingMs,
        testInvocationMs:$testInvocationMs,
        testBodyMs:$testBodyMs,
        xcresultSessionMs:$xcresultSessionMs,
        xcresultHarnessOverheadMs:$xcresultHarnessOverheadMs,
        appLaunchAverageMs:$appLaunchAverageMs,
        appLaunchSamples:$appLaunchSamples,
        invocationOverheadMs:$invocationOverheadMs,
        totalMs:$totalMs
      },
      cache:{status:$cacheStatus},
      coverage:$coverage,
      artifacts:{
        log:$log,
        xcresult:$xcresult,
        uiContactSheet:(if $uiContactSheet == "" then null else $uiContactSheet end),
        uiQuick4Sheet:(if $uiQuick4Sheet == "" then null else $uiQuick4Sheet end),
        uiVisualReviewManifest:(if $uiVisualReviewManifest == "" then null else $uiVisualReviewManifest end),
        uiScreenshotDir:(if $uiScreenshotDir == "" then null else $uiScreenshotDir end),
        uiVideo:(if $uiVideo == "" then null else $uiVideo end),
        uiVideoIdentity:(if $uiVideo == "" then null else {runID:$uiVideoRunID,file:$uiVideoFile,sha256:$uiVideoSHA256} end),
        uiReviewRoot:(if $uiReviewRoot == "" then null else $uiReviewRoot end),
        uiReviewHtml:(if $uiReviewHtml == "" then null else $uiReviewHtml end),
        p9ReviewCalendarEvidence:(if $p9Manifest == "" then null else {
          schema:"kg.p9.review_calendar.review_manifest.v2",
          path:$p9Manifest,
          sourceCommit:$sourceCommit,
          datasetID:$datasetID,
          datasetSHA256:$datasetSHA256,
          device:$device,
          selector:$p9Selector,
          recordCount:$p9RecordCount
        } end)
      }
    }' >"$VERDICT_JSON_FILE" || true
  if [[ -n "$p9_manifest" ]] && ! validate_p9_review_calendar_sidecar "$p9_manifest" "$VERDICT_JSON_FILE"; then
    echo "[ios_test] error: P9 review-calendar sidecar failed the formal outer-verdict contract" >&2
    result="fail"
    exit_code="1"
    reason="p9-review-calendar-evidence-contract"
    jq --arg result "$result" --arg exit "$exit_code" --arg reason "$reason" \
      '.status=$result | .result=$result | .exit=$exit | .reason=$reason' \
      "$VERDICT_JSON_FILE" >"$VERDICT_JSON_FILE.p9" && mv "$VERDICT_JSON_FILE.p9" "$VERDICT_JSON_FILE"
    return 1
  fi
  # The per-invocation JSON has no concurrent writer, so per-run metric
  # attribution is correct even when many agents finish at once.
  type append_run_metric >/dev/null 2>&1 && append_run_metric "$VERDICT_JSON_FILE"
  kg_ios_verdict_publish
}

populate_timing_breakdown
build_ui_step_contact_sheet
archive_ui_test_recording
populate_coverage_summary || true
if ! retrieve_p9_installed_fixture_proof; then
  P9_PROOF_RETRIEVAL_STATUS=1
fi

# Extract summary from xcresult if available
if [[ "$EXIT_CODE" -eq "$KG_IOS_EXIT_INFRA_UNAVAILABLE" ]]; then
  echo ""
  tail -10 "$TMPOUT" || true
  PRESERVE_TMPOUT=1
  [[ -n "$INCONCLUSIVE_REASON" ]] || INCONCLUSIVE_REASON="infrastructure-unavailable"
  echo "RESULT=inconclusive EXIT=$EXIT_CODE reason=$INCONCLUSIVE_REASON caller=$CALLER elapsed=${ELAPSED}s log=$TMPOUT xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  write_json_verdict "inconclusive" "$EXIT_CODE" "$INCONCLUSIVE_REASON" ""
  print_timing_summary
  emit_ui_runner_lifecycle
  echo "[ios_test] ? infrastructure unavailable (exit=$EXIT_CODE, ${ELAPSED}s) — $CALLER  verdict=$VERDICT_FILE" >&2
  echo "[ios_test] full log preserved: $TMPOUT" >&2
  echo "[ios_test] xcresult preserved: $RESULT_BUNDLE" >&2
elif [[ "$P9_PROOF_RETRIEVAL_STATUS" -ne 0 ]]; then
  echo "" >&2
  PRESERVE_TMPOUT=1
  echo "RESULT=fail reason=p9-proof-retrieval caller=$CALLER elapsed=${ELAPSED}s log=$TMPOUT xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  write_json_verdict "fail" "1" "p9-proof-retrieval" ""
  print_timing_summary
  emit_ui_runner_lifecycle
  echo "[ios_test] ✗ app-installed P9 proof retrieval failed — $CALLER  verdict=$VERDICT_FILE" >&2
  echo "[ios_test] full log preserved: $TMPOUT" >&2
  echo "[ios_test] xcresult preserved: $RESULT_BUNDLE" >&2
  EXIT_CODE=1
elif grep -qE '^\*\* TEST( EXECUTE)? SUCCEEDED' "$TMPOUT" 2>/dev/null; then
  EXECUTED="$(count_executed_tests_xcresult || count_executed_tests)"
  if [[ "$EXECUTED" -eq 0 ]]; then
    echo ""
    echo "[ios_test] ✗ FALSE GREEN: xcodebuild reported TEST SUCCEEDED but 0 tests executed" >&2
    echo "[ios_test]   (likely a stale/bogus -only-testing test ID matched nothing) — $CALLER" >&2
    emit_ui_runner_lifecycle
    echo "RESULT=fail reason=false-green-0-executed caller=$CALLER log=$TMPOUT xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
    write_json_verdict "fail" "1" "false-green-0-executed" "0"
    rm -f "$TMPOUT"
    exit 1
  fi
  if [[ "$COVERAGE_ENABLED" -eq 1 && "$COVERAGE_VERDICT" != "pass" ]]; then
    echo ""
    echo "[ios_test] ✗ coverage gate failed: $COVERAGE_REASON" >&2
    PRESERVE_TMPOUT=1
    echo "RESULT=fail reason=$COVERAGE_REASON caller=$CALLER elapsed=${ELAPSED}s log=$TMPOUT xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
    write_json_verdict "fail" "1" "$COVERAGE_REASON" "$EXECUTED"
    print_timing_summary
    echo "[ios_test] ✗ tests passed but coverage failed (${ELAPSED}s) — $CALLER  verdict=$VERDICT_FILE" >&2
    echo "[ios_test] full log preserved: $TMPOUT" >&2
    echo "[ios_test] xcresult preserved: $RESULT_BUNDLE" >&2
    exit 1
  fi
  echo ""
  echo "RESULT=ok executed=$EXECUTED caller=$CALLER elapsed=${ELAPSED}s log=$TMPOUT xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  write_json_verdict "ok" "0" "" "$EXECUTED"
  print_timing_summary
  echo "[ios_test] ✓ all tests passed ($EXECUTED executed, ${ELAPSED}s) — $CALLER  $(kg_ios_verdict_commit_kv "$PROJECT_ROOT")  log=$TMPOUT  xcresult=$RESULT_BUNDLE  verdict=$VERDICT_FILE"
elif kg_ios_test_execution_failed "$TMPOUT"; then
  echo ""
  # Show failing test details
  grep -E 'error:|failed' "$TMPOUT" | grep -v 'xcodebuild\|Linker\|frontend' | head -20 || true
  echo ""
  PRESERVE_TMPOUT=1
  echo "RESULT=fail reason=tests-failed caller=$CALLER elapsed=${ELAPSED}s log=$TMPOUT xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  write_json_verdict "fail" "1" "tests-failed" ""
  print_timing_summary
  emit_ui_runner_lifecycle
  echo "[ios_test] ✗ tests failed (${ELAPSED}s) — $CALLER  verdict=$VERDICT_FILE" >&2
  echo "[ios_test] full log preserved: $TMPOUT" >&2
  echo "[ios_test] xcresult preserved: $RESULT_BUNDLE" >&2
  EXIT_CODE=1
else
  echo ""
  # Show last 10 lines for unexpected output
  tail -10 "$TMPOUT"
  PRESERVE_TMPOUT=1
  # Inconclusive (no TEST SUCCEEDED/FAILED marker — e.g. a compile/build
  # failure). Never report success, but PRESERVE a meaningful upstream non-zero
  # code: xcodebuild's 65 for a build failure flows through here, letting callers
  # distinguish "build broke" (65) from "tests failed" (1). Only coerce a
  # spurious 0 up to 1 so an inconclusive run can never exit green.
  [[ "$EXIT_CODE" -eq 0 ]] && EXIT_CODE=1
  echo "RESULT=inconclusive EXIT=$EXIT_CODE caller=$CALLER elapsed=${ELAPSED}s log=$TMPOUT xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$PROJECT_ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  write_json_verdict "inconclusive" "$EXIT_CODE" "$INCONCLUSIVE_REASON" ""
  print_timing_summary
  emit_ui_runner_lifecycle
  echo "[ios_test] ? inconclusive (exit=$EXIT_CODE, ${ELAPSED}s) — $CALLER  verdict=$VERDICT_FILE" >&2
  echo "[ios_test] full log preserved: $TMPOUT" >&2
  echo "[ios_test] xcresult preserved: $RESULT_BUNDLE" >&2
fi

if [[ "$PRESERVE_TMPOUT" -eq 0 ]]; then
  rm -f "$TMPOUT"
fi
exit $EXIT_CODE
