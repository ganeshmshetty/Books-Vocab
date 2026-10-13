#!/usr/bin/env bash
# ios_ops.sh — unified iOS ops entrypoint for agents and humans.
#
# Usage:
#   ./ops/ios_ops.sh status
#   ./ops/ios_ops.sh guard [--refresh]                      # shared disk guard verdict (exit 75 = temporary block, 77 = structural block / retryable=no; names the worktrees); --refresh re-evaluates now
#   ./ops/ios_ops.sh build [ios_build.sh args...]          # app + test-target compile; e.g. --swift6
#   ./ops/ios_ops.sh test [ios_test.sh args...]
#   ./ops/ios_ops.sh test --launch-benchmark [--ui-launch-profile <standard|ui-smoke>]
#   ./ops/ios_ops.sh test --cache-status [--unit|--ui|--all-targets] [--json]
#   ./ops/ios_ops.sh test --prepare-cache [--unit|--ui|--all-targets] [--json]
#   ./ops/ios_ops.sh test --unit|--ui --xctestrun <path> [--device <udid>] [--json]   # test-without-building from prebuilt products (#3331)
#   ./ops/ios_ops.sh test --clean-cache [--unit|--ui|--all-targets] [--json]
#   ./ops/ios_ops.sh archive [--upload] [ios_release.sh args...] [--json]
#   ./ops/ios_ops.sh archives [list|latest|inspect ...]
#   ./ops/ios_ops.sh issues --log <xcodebuild.log> [--json]
#   ./ops/ios_ops.sh logs [--since 5m | --follow] [--predicate <predicate>] [--limit 200] [--json]
#   ./ops/ios_ops.sh sentry [--json]
#   ./ops/ios_ops.sh doctor [--json]
#   ./ops/ios_ops.sh workflow release [--json]
#   ./ops/ios_ops.sh gate release [--json]
#   ./ops/ios_ops.sh xcode [--json]
#   ./ops/ios_ops.sh simulator status [--json]
#   ./ops/ios_ops.sh simulator ensure-booted [--device <udid|name>] [--json]
#   ./ops/ios_ops.sh simulator lease [--json]                         # claim a pool simulator, print UDID
#   ./ops/ios_ops.sh simulator release [--device <udid|name>] [--shutdown] [--owner-token <token>] [--json]
#   ./ops/ios_ops.sh simulator launch [--json] [-- app args...]
#   ./ops/ios_ops.sh simulator terminate [--json]
#   ./ops/ios_ops.sh simulator screenshot [--out <png>] [--device booted] [--json]
#   ./ops/ios_ops.sh runs [--json]
#   ./ops/ios_ops.sh snapshot [--json] [--skip-xcode] [--skip-simulator] [--include-logs] [--log-since 5m] [--log-limit 200]
#   ./ops/ios_ops.sh catalog list --dataset <name>|--dataset-file <path> [--json]
#   ./ops/ios_ops.sh catalog open --dataset <name>|--dataset-file <path> [--scenario <category/title>] [--json]
#   ./ops/ios_ops.sh catalog capture --session <id> --out <png> [--json]
#   ./ops/ios_ops.sh catalog close --session <id> [--json]
#   ./ops/ios_ops.sh quality list [--json] | impact --files <path...> [--json] | impact --since <ref> [--json] | validate
#   ./ops/ios_ops.sh review-probe --simulator|--device <udid> --dataset <name>|--dataset-file <path> [--flips N] [--release] [--instruments] ...  # review-flip 量測 rig（詳 ./ops/review_flip_probe.sh --help）
#   ./ops/ios_ops.sh commands [--json]
#
# Side-effect model:
# - status/archives/issues/logs/sentry/doctor/workflow/gate/xcode/simulator status/runs/snapshot/dashboard/quality/commands are read-only.
# - build/test/archive/simulator screenshot/catalog are local machine side effects.
# - archive only uploads when --upload is passed through explicitly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_BUILD_DELEGATE="${KG_IOS_BUILD_DELEGATE:-$SCRIPT_DIR/ios_build.sh}"
IOS_TEST_DELEGATE="${KG_IOS_TEST_DELEGATE:-$SCRIPT_DIR/ios_test.sh}"
IOS_RELEASE_DELEGATE="${KG_IOS_RELEASE_DELEGATE:-$SCRIPT_DIR/ios_release.sh}"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

# shellcheck source=lib/ios_ops_core.sh
source "$SCRIPT_DIR/lib/ios_ops_core.sh"

# shellcheck source=lib/ios_ops_commands.sh
source "$SCRIPT_DIR/lib/ios_ops_commands.sh"

cmd_status_json() {
  local version build archive_line archive_created archive_name archive_bundle archive_version archive_build archive_path testflight_latest generated_at
  read_project_settings version build
  archive_line="$(read_organizer_latest)"
  if [[ -n "$archive_line" ]]; then
    IFS=$'\t' read -r archive_created archive_name archive_bundle archive_version archive_build archive_path <<<"$archive_line"
  fi
  testflight_latest="$(read_testflight_latest_build)"
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq -n \
    --arg schema "kg.ios.status.v1" \
    --arg generated_at "$generated_at" \
    --arg version "${version:-}" \
    --arg build "${build:-}" \
    --arg archiveCreated "${archive_created:-}" \
    --arg archiveName "${archive_name:-}" \
    --arg archiveBundle "${archive_bundle:-}" \
    --arg archiveVersion "${archive_version:-}" \
    --arg archiveBuild "${archive_build:-}" \
    --arg archivePath "${archive_path:-}" \
    --arg testflightLatest "${testflight_latest:-}" \
    '{
      schema:$schema,
      generated_at:$generated_at,
      project:{
        version:(if $version == "" then null else $version end),
        build:(if $build == "" then null else $build end)
      },
      organizer:{
        latest:(
          if $archivePath == "" then null else {
            createdAt:(if $archiveCreated == "" then null else $archiveCreated end),
            name:(if $archiveName == "" then null else $archiveName end),
            bundleId:(if $archiveBundle == "" then null else $archiveBundle end),
            version:(if $archiveVersion == "" then null else $archiveVersion end),
            build:(if $archiveBuild == "" then null else $archiveBuild end),
            archive:(if $archivePath == "" then null else $archivePath end)
          } end
        )
      },
      testflight:{
        latestBuild:(if $testflightLatest == "" then null else $testflightLatest end)
      }
    }'
}

cmd_status() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help|help)
        echo "Usage: ./ops/ios_ops.sh status [--json]"
        return 0
        ;;
      *)
        echo "✗ unknown status option: $1" >&2
        return 1
        ;;
    esac
  done

  local payload
  payload="$(cmd_status_json)"
  if (( json )); then
    printf '%s\n' "$payload"
    return 0
  fi

  jq -r '
    "[ios][status] project_version=\(.project.version // "unknown") project_build=\(.project.build // "unknown")",
    (if .organizer.latest == null then
      "[ios][status] organizer_latest=unknown"
    else
      "[ios][status] organizer_latest=\(.organizer.latest.version // "unknown")(\(.organizer.latest.build // "unknown")) archive=\(.organizer.latest.archive // "")"
    end),
    "[ios][status] testflight_latest_build=\(.testflight.latestBuild // "unknown")"
  ' <<<"$payload"
}

delegate_supports_native_json() {
  local kind="$1"
  shift || true
  if [[ "$kind" == "test" ]]; then
    local arg
    for arg in "$@"; do
      case "$arg" in
        --cache-status|--prepare-cache|--clean-cache)
          return 0
          ;;
      esac
    done
  fi
  return 1
}

cmd_delegate_with_optional_json() {
  local kind="$1" delegate="$2"
  shift 2 || true
  if delegate_supports_native_json "$kind" "$@"; then
    "$delegate" "$@"
    return
  fi

  local json=0
  local -a forwarded=()
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--json" ]]; then
      json=1
    else
      forwarded+=("$arg")
    fi
  done

  if (( json == 0 )); then
    if ((${#forwarded[@]})); then
      "$delegate" "${forwarded[@]}"
    else
      "$delegate"
    fi
    return
  fi

  # Pin a per-invocation verdict path and read back exactly that file: the
  # fixed path is a machine-wide LATEST pointer that a concurrent session can
  # overwrite between our delegate's write and our read (multi-session race).
  local rc=0 payload pinned_verdict
  pinned_verdict="${KG_IOS_VERDICT_FILE:-$(verdict_file_for "$kind").$(date +%s)-$$}"
  if ((${#forwarded[@]})); then
    if KG_IOS_VERDICT_FILE="$pinned_verdict" "$delegate" "${forwarded[@]}" >&2; then
      rc=0
    else
      rc=$?
    fi
  elif KG_IOS_VERDICT_FILE="$pinned_verdict" "$delegate" >&2; then
    rc=0
  else
    rc=$?
  fi
  payload="$(emit_single_run_json "$kind" "$pinned_verdict")"
  printf '%s\n' "$payload"
  return "$rc"
}

emit_archive_json() {
  local file json_file
  file="${1:-$(verdict_file_for archive)}"
  json_file="$file.json"

  if [[ -f "$json_file" ]] && jq -e . "$json_file" >/dev/null 2>&1; then
    cat "$json_file"
    return 0
  fi

  jq -nc \
    --arg schema "kg.ios.archive.v1" \
    --arg status "$(verdict_field "$file" RESULT)" \
    --arg exit_code "$(verdict_field "$file" EXIT)" \
    --arg caller "$(verdict_field "$file" caller)" \
    --arg archive_path "$(verdict_field "$file" archive)" \
    --arg archive_log "$(verdict_field "$file" log)" \
    --arg archive_xcresult "$(verdict_field "$file" xcresult)" \
    '{
      schema:$schema,
      status:(if $status == "" then "missing" else $status end),
      exit:(if $exit_code == "" then null else $exit_code end),
      caller:(if $caller == "" then null else $caller end),
      options:{keyId:null,uploadRequested:false},
      archive:{
        status:(if $status == "" then "missing" else $status end),
        elapsed:null,
        path:(if $archive_path == "" then null else $archive_path end),
        log:(if $archive_log == "" then null else $archive_log end),
        xcresult:(if $archive_xcresult == "" then null else $archive_xcresult end)
      },
      export:{status:"unknown",directory:null,ipa:null},
      upload:{status:"unknown",requested:false,completed:false}
    }'
}

cmd_archive_with_optional_json() {
  local delegate="$1"
  shift || true

  local json=0
  local -a forwarded=()
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--json" ]]; then
      json=1
    else
      forwarded+=("$arg")
    fi
  done

  if (( json == 0 )); then
    if ((${#forwarded[@]})); then
      "$delegate" "${forwarded[@]}"
    else
      "$delegate"
    fi
    return
  fi

  # Same per-invocation pinning as cmd_delegate_with_optional_json — never
  # read a latest pointer another session may have overwritten.
  local rc=0 payload pinned_verdict
  pinned_verdict="${KG_IOS_VERDICT_FILE:-$(verdict_file_for archive).$(date +%s)-$$}"
  if ((${#forwarded[@]})); then
    if KG_IOS_VERDICT_FILE="$pinned_verdict" "$delegate" "${forwarded[@]}" >&2; then
      rc=0
    else
      rc=$?
    fi
  elif KG_IOS_VERDICT_FILE="$pinned_verdict" "$delegate" >&2; then
    rc=0
  else
    rc=$?
  fi
  payload="$(emit_archive_json "$pinned_verdict")"
  printf '%s\n' "$payload"
  return "$rc"
}

# shellcheck source=lib/ios_ops_logs.sh
source "$SCRIPT_DIR/lib/ios_ops_logs.sh"

# shellcheck source=lib/ios_ops_release.sh
source "$SCRIPT_DIR/lib/ios_ops_release.sh"

# shellcheck source=lib/ios_ops_xcode.sh
source "$SCRIPT_DIR/lib/ios_ops_xcode.sh"

# shellcheck source=lib/ios_ops_simulator.sh
source "$SCRIPT_DIR/lib/ios_ops_simulator.sh"

# shellcheck source=lib/ios_ops_runs.sh
source "$SCRIPT_DIR/lib/ios_ops_runs.sh"

# shellcheck source=lib/ios_ops_snapshot.sh
source "$SCRIPT_DIR/lib/ios_ops_snapshot.sh"

# shellcheck source=lib/ios_ops_catalog.sh
source "$SCRIPT_DIR/lib/ios_ops_catalog.sh"

# shellcheck source=lib/ios_disk_budget.sh
source "$SCRIPT_DIR/lib/ios_disk_budget.sh"

# guard [--refresh]: show the shared disk guard verdict that gates build/test
# (exit 75 = temporary block, 77 = structural block / retryable=no), naming the blocking worktrees; --refresh re-evaluates now.
cmd_guard() {
  local refresh=0 arg state rc=0
  for arg in "$@"; do
    case "$arg" in
      --refresh) refresh=1 ;;
      *) echo "guard: unknown option $arg" >&2; return 64 ;;
    esac
  done
  state="${KG_IOS_DISK_GUARD_STATE:-$KG_IOS_DISK_GUARD_STATE_DEFAULT}"
  if (( refresh == 1 )); then
    kg_ios_disk_guard_refresh "$state" 0 || { echo "guard: refresh failed (tick unavailable or errored)" >&2; return 1; }
  fi
  [[ -f "$state" ]] || { echo "schema=kg.ios.guard.v1 verdict=unknown reason=disk-guard-state-missing state=$state"; return 0; }
  KG_IOS_DISK_GUARD_AUTO_REFRESH=0 kg_ios_disk_budget_guard_state guard || rc=$?
  echo "schema=kg.ios.guard.v1 verdict=$(kg_ios_disk_guard_json_string "$state" verdict) reason=$(kg_ios_disk_guard_json_string "$state" reason) action=$(kg_ios_disk_guard_json_string "$state" action) at=$(kg_ios_disk_guard_json_string "$state" at) refreshed=$refresh"
  return "$rc"
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 0; }
shift || true

case "$cmd" in
  status) cmd_status "$@" ;;
  guard) cmd_guard "$@" ;;
  build) cmd_delegate_with_optional_json build "$IOS_BUILD_DELEGATE" "$@" ;;
  test) cmd_delegate_with_optional_json test "$IOS_TEST_DELEGATE" "$@" ;;
  archive) cmd_archive_with_optional_json "$IOS_RELEASE_DELEGATE" "$@" ;;
  release) cmd_archive_with_optional_json "$IOS_RELEASE_DELEGATE" "$@" ;;
  archives) "$SCRIPT_DIR/ios_archive.sh" "${@:-list}" ;;
  issues) "$SCRIPT_DIR/ios_diagnostics.py" "$@" ;;
  logs) cmd_logs "$@" ;;
  sentry) cmd_sentry "$@" ;;
  doctor) cmd_doctor "$@" ;;
  workflow|flow) cmd_workflow "$@" ;;
  gate|verdict) cmd_gate "$@" ;;
  xcode|environment) cmd_xcode "$@" ;;
  simulator|sim) cmd_simulator "$@" ;;
  runs|reports) cmd_runs "$@" ;;
  snapshot|dashboard) cmd_snapshot "$@" ;;
  catalog) cmd_catalog "$@" ;;
  quality) "$SCRIPT_DIR/ui_quality_plane.py" "$@" ;;
  review-probe) "$SCRIPT_DIR/review_flip_probe.sh" "$@" ;;
  commands|capabilities) cmd_commands "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "✗ unknown subcommand: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
