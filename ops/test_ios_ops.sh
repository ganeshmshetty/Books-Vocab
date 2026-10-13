#!/usr/bin/env bash
# test_ios_ops.sh — structure tests for unified iOS ops entrypoint.
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
WORKSPACE="${KG_TEST_IOS_OPS_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export KG_IOS_XCTESTRUN_CACHE_LIB="$WORKSPACE/ops/lib/ios_xctestrun_cache.sh"
IOS_OPS="$WORKSPACE/ops/ios_ops.sh"
IOS_OPS_XCODE_LIB="$WORKSPACE/ops/lib/ios_ops_xcode.sh"
IOS_OPS_LOGS_LIB="$WORKSPACE/ops/lib/ios_ops_logs.sh"
IOS_OPS_RUNS_LIB="$WORKSPACE/ops/lib/ios_ops_runs.sh"
IOS_OPS_SNAPSHOT_LIB="$WORKSPACE/ops/lib/ios_ops_snapshot.sh"
IOS_OPS_SIMULATOR_LIB="$WORKSPACE/ops/lib/ios_ops_simulator.sh"
IOS_OPS_CATALOG_LIB="$WORKSPACE/ops/lib/ios_ops_catalog.sh"
IOS_OPS_RELEASE_LIB="$WORKSPACE/ops/lib/ios_ops_release.sh"
IOS_OPS_COMMANDS_LIB="$WORKSPACE/ops/lib/ios_ops_commands.sh"
IOS_OPS_CORE_LIB="$WORKSPACE/ops/lib/ios_ops_core.sh"
IOS_LOCK_WAIT_LIB="$WORKSPACE/ops/lib/ios_lock_wait.sh"
IOS_ARCHIVE="$WORKSPACE/ops/ios_archive.sh"
IOS_DIAG="$WORKSPACE/ops/ios_diagnostics.py"

pass=0; fail=0
ok() { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section() { echo ""; echo "── $* ──"; }

sentry_gate_fixture() {
  KG_IOS_OPS_FIXTURE=1 \
  KG_IOS_OPS_SENTRY_BUILD_CAN_IMPORT_FIXTURE=true \
  KG_IOS_OPS_SENTRY_API_AUTHENTICATED_FIXTURE=true \
  KG_IOS_OPS_SENTRY_PROJECT_REACHABLE_FIXTURE=true \
  KG_IOS_OPS_SENTRY_RUNTIME_EVENT_FIXTURE=true \
  KG_IOS_OPS_SENTRY_SYMBOLICATION_FIXTURE=true \
  SENTRY_API_URL=https://sentry.example.test \
  SENTRY_AUTH_TOKEN=fixture-token \
  SENTRY_ORG=kg-org \
  SENTRY_PROJECT_IOS=ios \
  bash "$IOS_OPS" "$@"
}

usage() {
  cat <<'EOF'
Usage: ops/test_ios_ops.sh [--list | --section <name>]

Run the complete iOS ops structure suite, list its named sections, or run one
independent section. Section mode is intended for focused local feedback; the
full suite remains the release evidence.
EOF
}

section_names() {
  awk '/^section "/ { line=$0; sub(/^section "/, "", line); sub(/"$/, "", line); print line }' "$SCRIPT_PATH"
}

run_section() {
  local selected="$1" tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/kg-test-ios-ops.XXXXXX")"
  {
    awk '/^section "/ { exit } { print }' "$SCRIPT_PATH"
    awk -v wanted="$selected" '
      /^section "/ {
        title=$0
        sub(/^section "/, "", title)
        sub(/"$/, "", title)
        if (inside) exit
        if (title == wanted) { inside=1; print; next }
      }
      inside { print }
    ' "$SCRIPT_PATH"
    cat <<'EOF'

echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
EOF
  } >"$tmp"
  export KG_TEST_IOS_OPS_WORKSPACE="$WORKSPACE"
  if bash "$tmp"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$tmp"
  return "$rc"
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --list)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    section_names
    exit 0
    ;;
  --section)
    [[ $# -eq 2 && -n "${2:-}" ]] || { usage >&2; exit 2; }
    if ! section_names | grep -Fxq -- "$2"; then
      echo "unknown section: $2" >&2
      echo "available sections:" >&2
      section_names >&2
      exit 1
    fi
    run_section "$2"
    exit $?
    ;;
  "")
    ;;
  *)
    echo "unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

section "Syntax and executable bits"
for f in "$IOS_OPS" "$IOS_OPS_CORE_LIB" "$IOS_OPS_XCODE_LIB" "$IOS_OPS_LOGS_LIB" "$IOS_OPS_RUNS_LIB" "$IOS_OPS_SNAPSHOT_LIB" "$IOS_OPS_SIMULATOR_LIB" "$IOS_OPS_CATALOG_LIB" "$IOS_OPS_RELEASE_LIB" "$IOS_OPS_COMMANDS_LIB" "$IOS_LOCK_WAIT_LIB" "$IOS_ARCHIVE" "$IOS_DIAG"; do
  [[ -f "$f" ]] && ok "$(basename "$f") exists" || fail_t "$(basename "$f") missing"
done
bash -n "$IOS_OPS" && ok "ios_ops.sh syntax" || fail_t "ios_ops.sh syntax"
bash -n "$IOS_OPS_CORE_LIB" && ok "ios_ops_core.sh syntax" || fail_t "ios_ops_core.sh syntax"
bash -n "$IOS_OPS_XCODE_LIB" && ok "ios_ops_xcode.sh syntax" || fail_t "ios_ops_xcode.sh syntax"
bash -n "$IOS_OPS_LOGS_LIB" && ok "ios_ops_logs.sh syntax" || fail_t "ios_ops_logs.sh syntax"
bash -n "$IOS_OPS_RUNS_LIB" && ok "ios_ops_runs.sh syntax" || fail_t "ios_ops_runs.sh syntax"
bash -n "$IOS_OPS_SNAPSHOT_LIB" && ok "ios_ops_snapshot.sh syntax" || fail_t "ios_ops_snapshot.sh syntax"
bash -n "$IOS_OPS_SIMULATOR_LIB" && ok "ios_ops_simulator.sh syntax" || fail_t "ios_ops_simulator.sh syntax"
bash -n "$IOS_OPS_CATALOG_LIB" && ok "ios_ops_catalog.sh syntax" || fail_t "ios_ops_catalog.sh syntax"
bash -n "$IOS_OPS_RELEASE_LIB" && ok "ios_ops_release.sh syntax" || fail_t "ios_ops_release.sh syntax"
bash -n "$IOS_OPS_COMMANDS_LIB" && ok "ios_ops_commands.sh syntax" || fail_t "ios_ops_commands.sh syntax"
bash -n "$IOS_LOCK_WAIT_LIB" && ok "ios_lock_wait.sh syntax" || fail_t "ios_lock_wait.sh syntax"
bash -n "$IOS_ARCHIVE" && ok "ios_archive.sh syntax" || fail_t "ios_archive.sh syntax"
grep -q 'source "$SCRIPT_DIR/lib/ios_ops_core.sh"' "$IOS_OPS" \
  && ok "ios_ops sources core lib" || fail_t "ios_ops does not source core lib"
grep -q 'source "$SCRIPT_DIR/lib/ios_ops_commands.sh"' "$IOS_OPS" \
  && ok "ios_ops sources commands lib" || fail_t "ios_ops does not source commands lib"
grep -q 'source "$SCRIPT_DIR/lib/ios_ops_xcode.sh"' "$IOS_OPS" \
  && ok "ios_ops sources xcode lib" || fail_t "ios_ops does not source xcode lib"
grep -q 'source "$SCRIPT_DIR/lib/ios_ops_logs.sh"' "$IOS_OPS" \
  && ok "ios_ops sources logs lib" || fail_t "ios_ops does not source logs lib"
grep -q 'source "$SCRIPT_DIR/lib/ios_ops_runs.sh"' "$IOS_OPS" \
  && ok "ios_ops sources runs lib" || fail_t "ios_ops does not source runs lib"
grep -q 'source "$SCRIPT_DIR/lib/ios_ops_snapshot.sh"' "$IOS_OPS" \
  && ok "ios_ops sources snapshot lib" || fail_t "ios_ops does not source snapshot lib"
grep -q 'source "$SCRIPT_DIR/lib/ios_ops_simulator.sh"' "$IOS_OPS" \
  && ok "ios_ops sources simulator lib" || fail_t "ios_ops does not source simulator lib"
grep -q 'source "$SCRIPT_DIR/lib/ios_ops_catalog.sh"' "$IOS_OPS" \
  && ok "ios_ops sources catalog lib" || fail_t "ios_ops does not source catalog lib"
grep -q 'source "$SCRIPT_DIR/lib/ios_ops_release.sh"' "$IOS_OPS" \
  && ok "ios_ops sources release lib" || fail_t "ios_ops does not source release lib"
prev_source_line=0
for lib in ios_ops_core.sh ios_ops_commands.sh ios_ops_logs.sh ios_ops_release.sh ios_ops_xcode.sh ios_ops_simulator.sh ios_ops_runs.sh ios_ops_snapshot.sh ios_ops_catalog.sh; do
  source_line="$(grep -n "source \"\\\$SCRIPT_DIR/lib/$lib\"" "$IOS_OPS" | head -1 | cut -d: -f1)"
  if [[ -n "$source_line" && "$source_line" -gt "$prev_source_line" ]]; then
    ok "source order: $lib"
    prev_source_line="$source_line"
  else
    fail_t "source order drift: $lib"
  fi
done

section "Core provider boundary"
for fn in read_project_settings read_organizer_latest read_testflight_latest_build read_asc_version_state read_xcode_version_text read_xcode_project_list_json read_xcode_destinations_text read_simctl_devices_json read_app_container_path read_app_process_pid read_app_launch_output read_app_terminate_output write_simulator_screenshot capture_source_text capture_source_json cleanup_tmp verdict_file_for verdict_json_file_for verdict_field path_exists_json_bool; do
  grep -qE "^${fn}\\(\\)" "$IOS_OPS_CORE_LIB" \
    && ok "core defines $fn" || fail_t "core missing $fn"
  grep -qE "^${fn}\\(\\)" "$IOS_OPS" \
    && fail_t "ios_ops should not redefine core function $fn" || ok "ios_ops keeps $fn out of façade"
done

section "Unified entrypoint help is safe"
help_out="$(bash "$IOS_OPS" --help 2>&1)"
echo "$help_out" | grep -q 'Usage:' && ok "ios_ops help prints Usage" || fail_t "ios_ops help missing Usage"
echo "$help_out" | grep -qE 'xcodebuild archive|xcodebuild test|xcodebuild .*build' \
  && fail_t "ios_ops help appears to run xcodebuild" || ok "ios_ops help is side-effect free"

section "Dispatch surface"
for sub in status build test archive archives issues logs sentry doctor workflow gate xcode simulator runs snapshot catalog quality commands; do
  if [[ "$sub" == "workflow" ]]; then
    grep -qE '^[[:space:]]*workflow\|flow\)' "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  elif [[ "$sub" == "gate" ]]; then
    grep -qE '^[[:space:]]*gate\|verdict\)' "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  elif [[ "$sub" == "runs" ]]; then
    grep -qE '^[[:space:]]*runs\|reports\)' "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  elif [[ "$sub" == "xcode" ]]; then
    grep -qE '^[[:space:]]*xcode\|environment\)' "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  elif [[ "$sub" == "simulator" ]]; then
    grep -qE '^[[:space:]]*simulator\|sim\)' "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  elif [[ "$sub" == "snapshot" ]]; then
    grep -qE '^[[:space:]]*snapshot\|dashboard\)' "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  elif [[ "$sub" == "catalog" ]]; then
    grep -qE '^[[:space:]]*catalog\)' "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  elif [[ "$sub" == "quality" ]]; then
    grep -qE '^[[:space:]]*quality\)' "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  elif [[ "$sub" == "commands" ]]; then
    grep -qE '^[[:space:]]*commands\|capabilities\)' "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  else
    grep -qE "^[[:space:]]*$sub\\)" "$IOS_OPS" \
      && ok "dispatch: $sub" || fail_t "dispatch missing: $sub"
  fi
done

section "Command catalog surface"
grep -q 'cmd_commands_json' "$IOS_OPS_COMMANDS_LIB" && grep -q 'kg.ios.commands.v1' "$IOS_OPS_COMMANDS_LIB" \
  && ok "commands catalog implementation lives in commands lib" || fail_t "commands catalog missing from commands lib"
grep -qE '^cmd_commands(_json)?\(\)' "$IOS_OPS" \
  && fail_t "ios_ops should not redefine commands catalog functions" || ok "ios_ops keeps commands catalog out of façade"
commands_json="$(bash "$IOS_OPS" commands --json)"
echo "$commands_json" | jq -e '.schema=="kg.ios.commands.v1" and (.commands|length >= 18) and all(.commands[]; has("delegate")) and any(.commands[]; .key=="status" and (.jsonSchemas|index("kg.ios.status.v1")) and (.command|test("--json"))) and any(.commands[]; .key=="build" and (.jsonSchemas|index("kg.ios.run.v1")) and (.jsonSchemas|index("kg.ios.diagnostics.v1")) and (.command|test("--json"))) and any(.commands[]; .key=="snapshot" and (.jsonSchemas|index("kg.ios.snapshot.v1")) and (.jsonSchemas|index("kg.ios.workflow.v1")) and (.jsonSchemas|index("kg.ios.gate.v1")) and (.jsonSchemas|index("kg.ios.sentry.v1")) and (.jsonSchemas|index("kg.ios.xcode.v1")) and (.jsonSchemas|index("kg.ios.simulator.v1")) and (.jsonSchemas|index("kg.ios.runs.v1")) and (.jsonSchemas|index("kg.ios.diagnostics.v1")) and (.jsonSchemas|index("kg.ios.logs.v1"))) and any(.commands[]; .key=="catalog" and (.jsonSchemas|index("kg.ios.catalog-agent.v1")) and (.command|test("catalog list")) and (.command|test("catalog open")) and (.command|test("catalog capture")) and (.command|test("catalog close")) and (.command|test("--dataset <name>")) and (.command|test("--dataset-file <path>")) and (.sideEffect|test("local-build")) and (.sideEffect|test("simulator lease"))) and any(.commands[]; .key=="quality" and .delegate=="./ops/ui_quality_plane.py" and .sideEffect=="read-only" and (.command|test("quality list")) and (.command|test("quality impact --files")) and (.command|test("quality validate"))) and any(.commands[]; .key=="test" and (.jsonSchemas|index("kg.ios.run.v1")) and (.jsonSchemas|index("kg.ios.test-cache.v1")) and (.jsonSchemas|index("kg.ios.diagnostics.v1")) and (.jsonSchemas|index("kg.ios.coverage.v1")) and (.command|test("--launch-benchmark")) and (.command|test("--cache-status")) and (.command|test("--prepare-cache")) and (.command|test("--clean-cache")) and (.command|test("--coverage")) and (.command|test("--coverage-fail-under <percent>")) and (.command|test("--json"))) and any(.commands[]; .key=="logs" and .sideEffect=="read-only" and (.jsonSchemas|index("kg.ios.logs.v1"))) and any(.commands[]; .key=="sentry" and .sideEffect=="read-only" and (.jsonSchemas|index("kg.ios.sentry.v1")) and (.command|test("--json"))) and any(.commands[]; .key=="doctor" and (.jsonSchemas|index("kg.ios.doctor.v1")) and (.jsonSchemas|index("kg.ios.sentry.v1")) and .sideEffect=="read-only") and any(.commands[]; .key=="issues" and .delegate=="./ops/ios_diagnostics.py" and (.jsonSchemas|index("kg.ios.diagnostics.v1"))) and any(.commands[]; .key=="gate" and (.aliases|index("verdict")) and (.jsonSchemas|index("kg.ios.gate.v1")) and .sideEffect=="read-only") and any(.commands[]; .key=="xcode" and (.aliases|index("environment")) and (.jsonSchemas|index("kg.ios.xcode.v1")) and .sideEffect=="read-only") and any(.commands[]; .key=="simulator" and (.aliases|index("sim")) and (.jsonSchemas|index("kg.ios.simulator.v1")) and (.sideEffect|test("local-artifact screenshot")) and (.sideEffect|test("local-simulator-lifecycle")) and (.command|test("launch")) and (.command|test("terminate")) and (.command|test("ensure-booted"))) and any(.commands[]; .key=="runs" and (.jsonSchemas|index("kg.ios.runs.v1")) and (.jsonSchemas|index("kg.ios.diagnostics.v1")) and .sideEffect=="read-only") and any(.commands[]; .key=="archive" and (.aliases|index("release")) and (.jsonSchemas|index("kg.ios.archive.v1")) and (.jsonSchemas|index("kg.ios.diagnostics.v1")) and (.command|test("--json")) and (.sideEffect|test("external-upload only with --upload"))) and any(.commands[]; .key=="commands" and (.aliases|index("capabilities")))' >/dev/null \
  && ok "commands --json exposes machine-readable command catalog" || fail_t "commands --json invalid: $commands_json"
capabilities_json="$(bash "$IOS_OPS" capabilities --json)"
echo "$capabilities_json" | jq -e '.schema=="kg.ios.commands.v1" and any(.commands[]; .key=="commands")' >/dev/null \
  && ok "capabilities alias exposes command catalog" || fail_t "capabilities --json invalid: $capabilities_json"
commands_text="$(bash "$IOS_OPS" commands)"
echo "$commands_text" | grep -q 'key=snapshot' \
  && ok "commands text lists snapshot" || fail_t "commands text missing snapshot: $commands_text"
echo "$commands_text" | grep -q 'key=catalog' \
  && ok "commands text lists catalog" || fail_t "commands text missing catalog: $commands_text"
echo "$commands_text" | grep -q 'key=quality' \
  && ok "commands text lists quality" || fail_t "commands text missing quality: $commands_text"
echo "$commands_text" | grep -q 'kg.ios.commands.v1' \
  && ok "commands text lists catalog schema" || fail_t "commands text missing schema: $commands_text"
catalog_help="$(bash "$IOS_OPS" catalog --help)"
echo "$catalog_help" | grep -q -- '--dataset <name>|--dataset-file <path>' \
  && ok "catalog help requires explicit UI World dataset" || fail_t "catalog help missing dataset requirement: $catalog_help"

section "Xcode environment surface"
status_json="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" status --json)"
echo "$status_json" | jq -e '.schema=="kg.ios.status.v1" and .project.version=="1.6" and .project.build=="4" and .organizer.latest.version=="1.6" and .organizer.latest.build=="4" and (.organizer.latest.archive|contains("BooksAndVocab.xcarchive")) and .testflight.latestBuild=="3"' >/dev/null \
  && ok "status --json exposes project, Organizer, and TestFlight summary" || fail_t "status --json invalid: $status_json"
status_text="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" status)"
echo "$status_text" | grep -q 'project_version=1.6 project_build=4' && echo "$status_text" | grep -q 'organizer_latest=1.6(4)' && echo "$status_text" | grep -q 'testflight_latest_build=3' \
  && ok "status text reports normalized summary lines" || fail_t "status text invalid: $status_text"
xcode_json="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" xcode --json)"
echo "$xcode_json" | jq -e '.schema=="kg.ios.xcode.v1" and (.errors|length)==0 and .xcode.version=="16.4" and .project.scheme=="BooksAndVocab" and (.project.list.schemes|index("BooksAndVocab")) and any(.destinations.available[]; .id=="fixture-iphone-17-pro-max" and .platform=="iOS Simulator" and .name=="iPhone 17 Pro Max") and any(.destinations.ineligible[]; .id=="fixture-ineligible" and (.error|contains("OS mismatch, please download runtime"))) and all(.destinations.available[]; .id!="fixture-ineligible") and .simulators.summary.booted==1' >/dev/null \
  && ok "xcode --json exposes project destinations and simulators" || fail_t "xcode --json invalid: $xcode_json"
xcode_text="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" environment)"
echo "$xcode_text" | grep -q 'schema=kg.ios.xcode.v1' && echo "$xcode_text" | grep -q 'destination id=fixture-iphone-17-pro-max' \
  && ok "environment text lists xcode schema and destination" || fail_t "environment text invalid: $xcode_text"
xcode_fail_json="$(KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_XCODE_FAIL_FIXTURE=1 bash "$IOS_OPS" xcode --json)"
echo "$xcode_fail_json" | jq -e '.schema=="kg.ios.xcode.v1" and (.errors|length)==4 and all(.sources[]; .status=="error") and (.destinations.available|length)==0 and .simulators.summary.total==0' >/dev/null \
  && ok "xcode --json reports source failures without breaking schema" || fail_t "xcode failure schema invalid: $xcode_fail_json"
xcode_bad_developer_json="$(DEVELOPER_DIR=/tmp/kg-missing-xcode bash "$IOS_OPS" xcode --json)"
echo "$xcode_bad_developer_json" | jq -e '.schema=="kg.ios.xcode.v1" and (.errors|length >= 1) and .sources.xcode_version.status=="error" and any(.sources[]; .status=="error")' >/dev/null \
  && ok "xcode --json reports real Xcode source failures" || fail_t "xcode bad DEVELOPER_DIR schema invalid: $xcode_bad_developer_json"

section "Simulator interaction surface"
sim_json="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" simulator status --json)"
echo "$sim_json" | jq -e '.schema=="kg.ios.simulator.v1" and .action=="status" and .status=="ok" and .device.udid=="fixture-iphone-17-pro-max" and .device.state=="Booted" and .app.bundleID=="com.Max0228.BooksBrowser" and .app.container.data=="/tmp/kg-sim-fixture/container" and .app.container.status=="ok" and .app.process.status=="running" and .app.process.pid=="74736" and .sources.app_process.status=="ok" and (.timings.totalMs|type)=="number" and (.timings.simctlDevicesMs|type)=="number" and (.timings.appContainerMs|type)=="number" and (.timings.appProcessMs|type)=="number"' >/dev/null \
  && ok "simulator status --json exposes booted device, app container, and process" || fail_t "simulator status --json invalid: $sim_json"
sim_text="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" sim status)"
echo "$sim_text" | grep -q 'schema=kg.ios.simulator.v1' && echo "$sim_text" | grep -q 'udid=fixture-iphone-17-pro-max' && echo "$sim_text" | grep -q 'app_process status=running pid=74736' && echo "$sim_text" | grep -q 'timings totalMs=' \
  && ok "sim alias text lists booted simulator" || fail_t "sim text invalid: $sim_text"
sim_stopped_json="$(KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_SIM_APP_STOPPED_FIXTURE=1 bash "$IOS_OPS" simulator status --json)"
echo "$sim_stopped_json" | jq -e '.schema=="kg.ios.simulator.v1" and .status=="ok" and .app.process.status=="stopped" and .app.process.pid==null and .sources.app_process.exitCode==1 and (.errors|length)==0' >/dev/null \
  && ok "simulator status --json reports stopped app process without failing" || fail_t "simulator stopped app invalid: $sim_stopped_json"
sim_launch_json="$(KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_SIM_APP_STOPPED_FIXTURE=1 bash "$IOS_OPS" simulator launch --json)"
echo "$sim_launch_json" | jq -e '.schema=="kg.ios.simulator.v1" and .action=="launch" and .status=="ok" and .device.udid=="fixture-iphone-17-pro-max" and .app.bundleID=="com.Max0228.BooksBrowser" and .app.lifecycle.exitCode==0 and .app.lifecycle.output=="74736" and .app.process.status=="running" and .app.process.pid=="74736" and (.timings.totalMs|type)=="number" and (.timings.statusMs|type)=="number" and (.timings.lifecycleMs|type)=="number" and (.timings.appProcessMs|type)=="number"' >/dev/null \
  && ok "simulator launch --json starts installed app and refreshes process state" || fail_t "simulator launch invalid: $sim_launch_json"
sim_launch_text="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" sim launch)"
echo "$sim_launch_text" | grep -q 'action=launch status=ok' && echo "$sim_launch_text" | grep -q 'app_process status=running pid=74736' && echo "$sim_launch_text" | grep -q 'timings totalMs=' \
  && ok "simulator launch text reports process state" || fail_t "simulator launch text invalid: $sim_launch_text"
sim_terminate_json="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" simulator terminate --json)"
echo "$sim_terminate_json" | jq -e '.schema=="kg.ios.simulator.v1" and .action=="terminate" and .status=="ok" and .device.udid=="fixture-iphone-17-pro-max" and .app.bundleID=="com.Max0228.BooksBrowser" and .app.lifecycle.exitCode==0 and .app.process.status=="stopped" and .app.process.pid==null and (.timings.totalMs|type)=="number" and (.timings.statusMs|type)=="number" and (.timings.lifecycleMs|type)=="number" and (.timings.appProcessMs|type)=="number"' >/dev/null \
  && ok "simulator terminate --json stops installed app and refreshes process state" || fail_t "simulator terminate invalid: $sim_terminate_json"
sim_ensure_booted_json="$(KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_SIM_NO_BOOTED_FIXTURE=1 bash "$IOS_OPS" simulator ensure-booted --json)"
echo "$sim_ensure_booted_json" | jq -e '.schema=="kg.ios.simulator.v1" and .action=="ensure-booted" and .status=="ok" and .device.udid=="fixture-iphone-17-pro-max" and .device.state=="Booted" and .boot.status=="ok" and .boot.exitCode==0 and .boot.wasAlreadyBooted==false and .boot.waitedForBootstatus==true and (.timings.totalMs|type)=="number" and (.timings.resolveMs|type)=="number" and (.timings.bootMs|type)=="number" and (.timings.bootstatusMs|type)=="number"' >/dev/null \
  && ok "simulator ensure-booted --json boots the default simulator when none are booted" || fail_t "simulator ensure-booted invalid: $sim_ensure_booted_json"
sim_ensure_booted_text="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" simulator ensure-booted)"
echo "$sim_ensure_booted_text" | grep -q 'action=ensure-booted status=ok' && echo "$sim_ensure_booted_text" | grep -q 'wasAlreadyBooted=true' && echo "$sim_ensure_booted_text" | grep -q 'timings totalMs=' \
  && ok "simulator ensure-booted text reports warm-boot reuse" || fail_t "simulator ensure-booted text invalid: $sim_ensure_booted_text"
sim_shot_tmp="$(mktemp -d)"
sim_shot="$sim_shot_tmp/screenshot with spaces.png"
sim_shot_json="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" simulator screenshot --out "$sim_shot" --json)"
echo "$sim_shot_json" | jq -e --arg path "$sim_shot" '.schema=="kg.ios.simulator.v1" and .action=="screenshot" and .status=="ok" and .artifact.path==$path and .artifact.exists==true and .artifact.bytes > 0 and .device.udid=="fixture-iphone-17-pro-max"' >/dev/null \
  && [[ -s "$sim_shot" ]] \
  && ok "simulator screenshot --json creates local artifact" || fail_t "simulator screenshot invalid: $sim_shot_json"
echo "$sim_shot_json" | jq -e '(.timings.totalMs|type)=="number" and (.timings.statusMs|type)=="number" and (.timings.screenshotMs|type)=="number"' >/dev/null \
  && ok "simulator screenshot --json exposes timing breakdown" || fail_t "simulator screenshot timings invalid: $sim_shot_json"
sim_shot_text="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" simulator screenshot --out "$sim_shot_tmp/text.png")"
echo "$sim_shot_text" | grep -q 'artifact=' && echo "$sim_shot_text" | grep -q 'text.png' && echo "$sim_shot_text" | grep -q 'timings totalMs=' \
  && ok "simulator screenshot text reports artifact path" || fail_t "simulator screenshot text invalid: $sim_shot_text"
if KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" simulator screenshot --out /dev/null/kg-shot.png --json >"$sim_shot_tmp/bad_parent.json" 2>"$sim_shot_tmp/bad_parent.err"; then
  fail_t "simulator screenshot reports unwritable parent as JSON error"
else
  rc=$?
  jq -e '.schema=="kg.ios.simulator.v1" and .action=="screenshot" and .status=="error" and .artifact.path=="/dev/null/kg-shot.png" and .artifact.exists==false and any(.errors[]; .key=="screenshot")' "$sim_shot_tmp/bad_parent.json" >/dev/null \
    && [[ "$rc" -ne 0 ]] \
    && ok "simulator screenshot reports unwritable parent as JSON error" || fail_t "simulator screenshot bad-parent invalid: $(cat "$sim_shot_tmp/bad_parent.json") stderr=$(cat "$sim_shot_tmp/bad_parent.err") rc=$rc"
fi
if KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_SIM_NO_BOOTED_FIXTURE=1 bash "$IOS_OPS" simulator status --json >"$sim_shot_tmp/no_booted.json" 2>"$sim_shot_tmp/no_booted.err"; then
  fail_t "simulator status reports missing booted device"
else
  rc=$?
  jq -e '.schema=="kg.ios.simulator.v1" and .action=="status" and .status=="error" and .device==null and any(.errors[]; .key=="booted-device")' "$sim_shot_tmp/no_booted.json" >/dev/null \
    && [[ "$rc" -eq 1 ]] \
    && ok "simulator status reports missing booted device" || fail_t "simulator missing-booted invalid: $(cat "$sim_shot_tmp/no_booted.json") stderr=$(cat "$sim_shot_tmp/no_booted.err") rc=$rc"
fi
sim_lease_tmp="$(mktemp -d)"
live_owner_pid=""
sleep 30 &
live_owner_pid=$!
lease_dir="$sim_lease_tmp/kg-pool-1"
mkdir -p "$lease_dir"
printf '%s\n' "$(( $(date +%s) - 120 ))" > "$lease_dir/created_at"
printf '%s\n' "$live_owner_pid" > "$lease_dir/owner_pid"
printf '%s\n' "fixture-udid" > "$lease_dir/udid"
printf '%s\n' "fixture-token" > "$lease_dir/owner_token"
lease_stale_status="$(
  ROOT="$WORKSPACE" KG_IOS_SIM_LEASE_ROOT="$sim_lease_tmp" KG_IOS_SIM_LEASE_TTL=1 \
    bash -lc 'source "'"$IOS_OPS_SIMULATOR_LIB"'"; if simulator_lease_is_stale "'"$lease_dir"'"; then echo stale; else echo live; fi'
)"
[[ "$lease_stale_status" == "live" ]] \
  && ok "simulator lease keeps live owner pid from stale reclaim" || fail_t "simulator lease stale-check ignored live owner pid: $lease_stale_status"
release_token_mismatch_json="$(
  ROOT="$WORKSPACE" KG_IOS_SIM_LEASE_ROOT="$sim_lease_tmp" \
    bash -lc 'source "'"$IOS_OPS_SIMULATOR_LIB"'"; cmd_simulator_release --device fixture-udid --owner-token wrong-token --json'
)"
echo "$release_token_mismatch_json" | jq -e '.schema=="kg.ios.sim-release.v1" and .status=="noop" and .error=="owner-token-mismatch:fixture-udid"' >/dev/null \
  && [[ -d "$lease_dir" ]] \
  && ok "simulator release refuses mismatched owner token" || fail_t "simulator release token mismatch invalid: $release_token_mismatch_json"
release_token_match_json="$(
  ROOT="$WORKSPACE" KG_IOS_SIM_LEASE_ROOT="$sim_lease_tmp" \
    bash -lc 'source "'"$IOS_OPS_SIMULATOR_LIB"'"; cmd_simulator_release --device fixture-udid --owner-token fixture-token --json'
)"
echo "$release_token_match_json" | jq -e '.schema=="kg.ios.sim-release.v1" and .status=="ok" and .udid=="fixture-udid"' >/dev/null \
  && [[ ! -d "$lease_dir" ]] \
  && ok "simulator release deletes lease only for matching owner token" || fail_t "simulator release token match invalid: $release_token_match_json"
kill "$live_owner_pid" 2>/dev/null || true
wait "$live_owner_pid" 2>/dev/null || true
rm -rf "$sim_lease_tmp"
rm -rf "$sim_shot_tmp"

section "Catalog agent tool surface"
catalog_help="$(bash "$IOS_OPS" catalog --help)"
# Match in-shell, not `echo | grep -q`: under pipefail an early-exit grep -q EPIPEs the
# producer on a multi-chunk help body and fails a passing contract (main-red #3381).
catalog_help_lines=$'\n'"$catalog_help"$'\n'
[[ "$catalog_help" == *'catalog list'* && "$catalog_help" == *'catalog open'* \
  && "$catalog_help" == *'catalog capture'* && "$catalog_help" == *'catalog close'* \
  && "$catalog_help_lines" != *$'\n  ./ops/ios_ops.sh catalog snapshots'* ]] \
  && ok "catalog help exposes only agent list/open/capture/close actions" || fail_t "catalog help contract invalid: $catalog_help"
if bash "$IOS_OPS" catalog snapshots >"/tmp/kg-catalog-legacy.out.$$" 2>"/tmp/kg-catalog-legacy.err.$$"; then
  fail_t "removed catalog snapshots action still succeeds"
else
  grep -q "was removed" "/tmp/kg-catalog-legacy.err.$$" \
    && ok "removed catalog snapshots action fails loudly" || fail_t "catalog snapshots removal message missing"
fi
rm -f "/tmp/kg-catalog-legacy.out.$$" "/tmp/kg-catalog-legacy.err.$$"
if bash "$IOS_OPS" catalog open --appearance light >"/tmp/kg-catalog-world.out.$$" 2>"/tmp/kg-catalog-world.err.$$"; then
  fail_t "catalog open accepts an implicit UI World"
else
  grep -q "requires an explicit UI World" "/tmp/kg-catalog-world.err.$$" \
    && ok "catalog open requires explicit UI World" || fail_t "catalog explicit UI World guard missing"
fi
rm -f "/tmp/kg-catalog-world.out.$$" "/tmp/kg-catalog-world.err.$$"
section "ios_test verdict records source tree state"
grep -q 'status --porcelain' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test.sh inspects the working tree before stamping sourceCommit" \
  || fail_t "ios_test.sh stamps sourceCommit without checking the working tree"
grep -q 'sourceTreeDirty:\$sourceTreeDirty' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test.sh verdict carries sourceTreeDirty" \
  || fail_t "ios_test.sh verdict does not carry sourceTreeDirty"
# The greps above only prove the strings exist; flipping `-n` to `-z` would read
# a dirty tree as clean and still satisfy both. write_json_verdict cannot be
# sourced (ios_test.sh runs on load) and a real run needs a simulator, so lift
# the actual lines out of the actual file and execute them. Extraction failure
# must be red, not silently green — hence the shape assertions before the runs.
verdict_dirty_snippet="$(awk '/^  if source_tree_status=/,/^  fi$/' "$WORKSPACE/ops/ios_test.sh")"
verdict_dirty_lines="$(printf '%s\n' "$verdict_dirty_snippet" | wc -l | tr -d ' ')"
verdict_dirty_last="$(printf '%s\n' "$verdict_dirty_snippet" | tail -n 1)"
# The guard needs an UPPER bound, not just a lower one: an awk range whose end
# pattern stops matching over-captures instead of under-capturing, and an
# over-captured region satisfies every "contains X" check by construction. That
# is not hypothetical — losing the `  fi` anchor pulls in ~189 lines of
# write_json_verdict, including statements that write files, and this test would
# then execute them.
if [[ -z "$verdict_dirty_snippet" ]] \
  || ! grep -q 'status --porcelain' <<<"$verdict_dirty_snippet" \
  || ! grep -q 'source_tree_dirty=' <<<"$verdict_dirty_snippet" \
  || [[ "$verdict_dirty_lines" -gt 12 ]] \
  || [[ "$verdict_dirty_last" != "  fi" ]]; then
  fail_t "could not lift the sourceTreeDirty block out of ios_test.sh (extraction is stale: lines=$verdict_dirty_lines last='$verdict_dirty_last')"
else
  ok "sourceTreeDirty block lifted from ios_test.sh for execution"
  run_verdict_dirty_snippet() {
    PROJECT_ROOT="$1" bash -c "set -euo pipefail
$verdict_dirty_snippet
printf '%s\\n' \"\$source_tree_dirty\""
  }
  dirty_probe="$(mktemp -d)"
  git -C "$dirty_probe" -c init.defaultBranch=main init -q
  printf 'pinned\n' >"$dirty_probe/tracked.txt"
  git -C "$dirty_probe" add -A >/dev/null
  git -C "$dirty_probe" -c user.name=t -c user.email=t@example.invalid commit -qm pin
  [[ "$(run_verdict_dirty_snippet "$dirty_probe")" == "false" ]] \
    && ok "sourceTreeDirty is false on a clean tree" \
    || fail_t "sourceTreeDirty was not false on a clean tree"
  printf 'edited\n' >>"$dirty_probe/tracked.txt"
  [[ "$(run_verdict_dirty_snippet "$dirty_probe")" == "true" ]] \
    && ok "sourceTreeDirty is true on a dirty tree" \
    || fail_t "sourceTreeDirty read a dirty tree as clean"
  git -C "$dirty_probe" checkout -q -- tracked.txt
  : >"$dirty_probe/untracked.swift"
  # An uncommitted new source file is the commonest shape of "built something
  # that is in no commit", and it is exactly the shape `--porcelain -uno` would
  # stop seeing while every modified-file probe above stayed green.
  [[ "$(run_verdict_dirty_snippet "$dirty_probe")" == "true" ]] \
    && ok "sourceTreeDirty counts an untracked file as dirty" \
    || fail_t "sourceTreeDirty ignored an untracked file"
  no_repo_probe="$(mktemp -d)"
  [[ "$(run_verdict_dirty_snippet "$no_repo_probe")" == "true" ]] \
    && ok "sourceTreeDirty fails closed when git cannot answer" \
    || fail_t "sourceTreeDirty read an unanswerable tree as clean"
  rm -rf "$dirty_probe" "$no_repo_probe"
fi
# The lifted block is a COPY running in another process, so it cannot see edits
# to its surroundings: binding the jq arg to a literal, or reassigning
# source_tree_dirty on the next line, leaves every probe above green. These two
# static assertions cover that blind spot — the second one is a "no other
# writer" invariant, so a legitimate refactor is expected to update the count.
grep -qF -- '--argjson sourceTreeDirty "$source_tree_dirty"' "$WORKSPACE/ops/ios_test.sh" \
  && ok "verdict binds sourceTreeDirty to the computed variable, not a literal" \
  || fail_t "ios_test.sh no longer passes \$source_tree_dirty into the verdict"
verdict_dirty_writes="$(grep -o 'source_tree_dirty=' "$WORKSPACE/ops/ios_test.sh" | wc -l | tr -d ' ')"
[[ "$verdict_dirty_writes" == "3" ]] \
  && ok "source_tree_dirty is assigned only inside the lifted block" \
  || fail_t "source_tree_dirty assigned $verdict_dirty_writes times (expected 3); a writer outside the audited block can override it"

section "UITest video archive surface"
IOS_TEST_VIDEO_ARCHIVE_LIB="$WORKSPACE/ops/lib/ios_test_video_archive.sh"
[[ -f "$IOS_TEST_VIDEO_ARCHIVE_LIB" ]] && ok "ios_test_video_archive.sh exists" || fail_t "ios_test_video_archive.sh missing"
bash -n "$IOS_TEST_VIDEO_ARCHIVE_LIB" 2>/dev/null && ok "ios_test_video_archive.sh syntax" || fail_t "ios_test_video_archive.sh syntax"
grep -q 'source "$SCRIPT_DIR/lib/ios_test_video_archive.sh"' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test sources video archive lib" || fail_t "ios_test does not source video archive lib"
# Archive must run after the recording is finalized (post contact sheet) and
# before a verdict branch. UIreview is built inside write_json_verdict so every
# terminal branch gets exactly one collision-checked review root.
awk '/^build_ui_step_contact_sheet$/{cs=NR} /^archive_ui_test_recording$/{ar=NR} /write_json_verdict "/{if (!v) v=NR} END{exit (cs && ar && v && cs<ar && ar<v) ? 0 : 1}' "$WORKSPACE/ops/ios_test.sh" \
  && sed -n '/^write_json_verdict()/,/^}/p' "$WORKSPACE/ops/ios_test.sh" | awk '/build_ui_test_review_page/{rv=NR} /jq -nc/{if (!j) j=NR} END{exit (rv && j && rv<j) ? 0 : 1}' \
  && ok "ios_test archives recording before verdict and builds UIreview inside verdict" || fail_t "UIreview/archive calls missing or misordered"
va_tmp="$(mktemp -d)"
va_dest="$va_tmp/uitest-videos"
printf 'fake-mp4-bytes' >"$va_tmp/run_recording.mp4"
va_path="$(bash -lc 'source "'"$IOS_TEST_VIDEO_ARCHIVE_LIB"'"; uitest_video_archive "'"$va_tmp"'/run_recording.mp4" "'"$va_dest"'" ui test-caller 20260611-120000')"
[[ "$va_path" == "$va_dest/20260611-120000-ui.mp4" && -s "$va_path" && ! -e "$va_tmp/run_recording.mp4" ]] \
  && ok "archive moves recording to timestamped dest and echoes path" || fail_t "archive basic move wrong: path=$va_path"
jq -e '.schema=="kg.ios.uitest-videos.v1" and (.videos|length)==1 and .videos[0].file=="20260611-120000-ui.mp4" and .videos[0].scope=="ui" and .videos[0].caller=="test-caller" and .videos[0].sizeBytes>0' "$va_dest/index.json" >/dev/null \
  && ok "archive writes index.json entry with metadata" || fail_t "archive index wrong: $(cat "$va_dest/index.json" 2>/dev/null)"
printf 'fake-mp4-bytes-2' >"$va_tmp/run_recording.mp4"
va_path2="$(bash -lc 'source "'"$IOS_TEST_VIDEO_ARCHIVE_LIB"'"; uitest_video_archive "'"$va_tmp"'/run_recording.mp4" "'"$va_dest"'" ui test-caller 20260611-120000')"
[[ "$va_path2" == "$va_dest/20260611-120000-ui-2.mp4" && -s "$va_path2" ]] \
  && ok "archive disambiguates same-timestamp collisions" || fail_t "archive collision handling wrong: $va_path2"
jq -e '(.videos|length)==2 and .videos[0].file=="20260611-120000-ui-2.mp4"' "$va_dest/index.json" >/dev/null \
  && ok "archive index keeps newest-first ordering" || fail_t "archive index ordering wrong: $(cat "$va_dest/index.json")"
printf 'fake-mp4-bytes-3' >"$va_tmp/run_recording.mp4"
va_path3="$(bash -lc 'source "'"$IOS_TEST_VIDEO_ARCHIVE_LIB"'"; KG_UITEST_VIDEO_KEEP=2 uitest_video_archive "'"$va_tmp"'/run_recording.mp4" "'"$va_dest"'" all test-caller 20260611-130000')"
[[ -s "$va_path3" && ! -e "$va_dest/20260611-120000-ui.mp4" ]] \
  && ok "archive prunes oldest beyond KG_UITEST_VIDEO_KEEP" || fail_t "archive prune wrong: kept=$(ls "$va_dest")"
jq -e '(.videos|length)==2 and .videos[0].file=="20260611-130000-all.mp4" and .videos[1].file=="20260611-120000-ui-2.mp4"' "$va_dest/index.json" >/dev/null \
  && ok "archive prune drops pruned entries from index" || fail_t "archive prune index wrong: $(cat "$va_dest/index.json")"
va_noop="$(bash -lc 'source "'"$IOS_TEST_VIDEO_ARCHIVE_LIB"'"; uitest_video_archive "'"$va_tmp"'/missing.mp4" "'"$va_tmp"'/never-created" ui test-caller 20260611-140000')" || fail_t "archive no-op should return 0"
[[ -z "$va_noop" && ! -e "$va_tmp/never-created" ]] \
  && ok "archive is a no-op for missing/empty recordings" || fail_t "archive no-op created artifacts: '$va_noop'"

# Same-second runs are normal under parallel UI verification. All workers start
# behind one barrier so this exercises the candidate-name reservation itself,
# not merely 24 sequential calls that happen to share a timestamp.
va_race="$va_tmp/race"
va_race_dest="$va_race/uitest-videos"
mkdir -p "$va_race/sources" "$va_race/results"
for worker in $(seq 1 24); do
  printf 'video-%02d' "$worker" >"$va_race/sources/$worker.mp4"
  (
    while [[ ! -e "$va_race/go" ]]; do sleep 0.01; done
    KG_UITEST_VIDEO_KEEP=24 bash -lc \
      'source "'"$IOS_TEST_VIDEO_ARCHIVE_LIB"'"; uitest_video_archive "$1" "$2" ui race-caller 20260611-150000' \
      _ "$va_race/sources/$worker.mp4" "$va_race_dest" \
      >"$va_race/results/$worker.out" 2>"$va_race/results/$worker.err"
    printf '%s\n' "$?" >"$va_race/results/$worker.rc"
  ) &
done
: >"$va_race/go"
wait
va_race_files="$(find "$va_race_dest" -maxdepth 1 -type f -name '*.mp4' | wc -l | tr -d ' ')"
va_race_unique="$(find "$va_race_dest" -maxdepth 1 -type f -name '*.mp4' -exec basename {} \; | sort -u | wc -l | tr -d ' ')"
va_race_sources="$(find "$va_race/sources" -maxdepth 1 -type f -name '*.mp4' | wc -l | tr -d ' ')"
va_race_failures="$(awk '$0 != 0 { count += 1 } END { print count + 0 }' "$va_race"/results/*.rc)"
if [[ "$va_race_files" == 24 && "$va_race_unique" == 24 && "$va_race_sources" == 0 && "$va_race_failures" == 0 ]] \
  && jq -e '(.videos | length) == 24 and ([.videos[].file] | unique | length) == 24' "$va_race_dest/index.json" >/dev/null; then
  ok "24-way same-timestamp archive keeps 24 unique videos and index identities"
else
  fail_t "24-way archive race lost/clobbered evidence: files=$va_race_files unique=$va_race_unique sources=$va_race_sources failures=$va_race_failures"
fi

# A failed exclusive reservation must not consume the source or replace an
# existing archive. The mkdir shim fails only reservation-directory creation.
va_blocked="$va_tmp/blocked"
mkdir -p "$va_blocked/dest"
printf 'existing-video' >"$va_blocked/dest/20260611-160000-ui.mp4"
printf 'unmoved-source' >"$va_blocked/source.mp4"
set +e
bash -lc '
  mkdir() {
    if [[ "${*: -1}" == *.reserve ]]; then return 1; fi
    command mkdir "$@"
  }
  source "'"$IOS_TEST_VIDEO_ARCHIVE_LIB"'"
  uitest_video_archive "$1" "$2" ui blocked-caller 20260611-160000
' \
  _ "$va_blocked/source.mp4" "$va_blocked/dest" >/dev/null 2>&1
va_blocked_rc=$?
set -e
[[ "$va_blocked_rc" -ne 0 && -s "$va_blocked/source.mp4" && "$(cat "$va_blocked/dest/20260611-160000-ui.mp4")" == existing-video ]] \
  && ok "archive reservation failure preserves source and existing video" \
  || fail_t "archive reservation failure consumed source or clobbered destination (rc=$va_blocked_rc)"

# The standalone review root must use one stable run identity even when a video
# exists, and the directory creation itself must be the exclusive operation.
review_body="$(sed -n '/^build_ui_test_review_page()/,/^}/p' "$WORKSPACE/ops/ios_test.sh")"
grep -qF 'stem="$UI_TEST_RUN_ID"' <<<"$review_body" \
  && ok "video-backed review root uses stable run identity" \
  || fail_t "video-backed review root still derives identity from video basename"
grep -qF 'if ! mkdir "$UI_TEST_REVIEW_ROOT"' <<<"$review_body" \
  && ! grep -qF '[[ -e "$UI_TEST_REVIEW_ROOT" ]]' <<<"$review_body" \
  && ok "review root uses exclusive mkdir collision refusal" \
  || fail_t "review root creation still has check-then-mkdir collision window"
rm -rf "$va_tmp"

section "Doctor release readiness surface"
doctor_body="$(awk '/^doctor_readiness\(\)/,/^}/' "$IOS_OPS_RELEASE_LIB")"
for key in project organizer testflight asc_version signing storekit sentry; do
  grep -q "\"$key\"" <<<"$doctor_body" \
    && ok "doctor checks $key readiness" || fail_t "doctor missing $key readiness"
done
grep -q 'cmd_doctor_json' "$IOS_OPS_RELEASE_LIB" && grep -q 'kg.ios.doctor.v1' "$IOS_OPS_RELEASE_LIB" \
  && ok "doctor exposes machine-readable JSON schema" || fail_t "doctor missing JSON schema"
grep -q 'doctor_readiness emit_readiness_json' "$IOS_OPS_RELEASE_LIB" \
  && ok "doctor JSON reuses readiness checks" || fail_t "doctor JSON does not reuse readiness checks"
grep -q 'read_asc_version_state' <<<"$doctor_body" \
  && grep -q 'KG_IOS_OPS_CAPTURE_TIMEOUT_SECONDS="${KG_IOS_OPS_ASC_TIMEOUT_SECONDS:-12}"' "$IOS_OPS_CORE_LIB" \
  && grep -q 'ios_ops_stream_capture workflow-asc-versions' "$IOS_OPS_CORE_LIB" \
  && ok "doctor bounds ASC version-state lookup" || fail_t "doctor missing bounded ASC version lookup"
grep -q 'ExportOptions.plist' <<<"$doctor_body" \
  && ok "doctor checks export signing options" || fail_t "doctor missing ExportOptions check"
grep -q 'Products\\.storekit' <<<"$doctor_body" \
  && ok "doctor checks StoreKit scheme/file" || fail_t "doctor missing StoreKit check"
grep -qE 'xcodebuild (archive|build|test)|altool --upload-app|--upload' <<<"$doctor_body" \
  && fail_t "doctor contains side-effecting build/archive/upload path" \
  || ok "doctor stays read-only"

section "Release workflow surface"
for key in preflight tests build archive upload asc-review metadata submit; do
  grep -q "\"$key\"" "$IOS_OPS_RELEASE_LIB" \
    && ok "workflow includes $key step" || fail_t "workflow missing $key step"
done
grep -q 'cmd_workflow_release_json' "$IOS_OPS_RELEASE_LIB" && grep -q 'kg.ios.workflow.v1' "$IOS_OPS_RELEASE_LIB" \
  && ok "workflow exposes machine-readable JSON schema" || fail_t "workflow missing JSON schema"
grep -q 'emit_workflow_step_json' "$IOS_OPS_RELEASE_LIB" \
  && ok "workflow JSON emits structured steps" || fail_t "workflow JSON missing structured step emitter"
grep -q 'write_workflow_release_steps_json' "$IOS_OPS_RELEASE_LIB" \
  && ok "workflow step generation is centralized" || fail_t "workflow missing shared step generator"
grep -q './ops/ios_ops.sh test --all-targets --dataset marketing_demo --timeout 1200' "$IOS_OPS_RELEASE_LIB" \
  && ok "workflow includes all-targets test gate" || fail_t "workflow missing all-targets test command"
grep -q './ops/asc_text_bundle.py dump -o asc.json' "$IOS_OPS_RELEASE_LIB" \
  && ok "workflow includes ASC text bundle review" || fail_t "workflow missing asc_text_bundle dump"
grep -q 'ASC GUI' "$IOS_OPS_RELEASE_LIB" \
  && ok "workflow marks submit as GUI/manual" || fail_t "workflow missing GUI submit boundary"
grep -qE 'xcodebuild (archive|build|test)|altool --upload-app' "$IOS_OPS_RELEASE_LIB" \
  && fail_t "workflow contains direct Xcode side-effect path" \
  || ok "workflow stays orchestration/read-only"

section "Release gate surface"
# A non-pass gate exits 2/3 by design, so a bare `x="$(gate ...)"` would end this
# whole script silently under `set -e` (CI saw only "rc=3" with no payload).
# Capture the exit code and fail with the verdict payload instead.
gate_pass_rc=0
gate_pass_json="$(sentry_gate_fixture gate release --json)" || gate_pass_rc=$?
echo "$gate_pass_json" | jq -e '.schema=="kg.ios.gate.v1" and .name=="release" and .verdict=="pass" and .exitCode==0 and .summary.blocks==0 and (.todos|length >= 1) and (.manual|length == 1)' >/dev/null \
  && [[ "$gate_pass_rc" -eq 0 ]] \
  && ok "gate release --json emits pass verdict" || fail_t "gate release pass invalid rc=$gate_pass_rc: $gate_pass_json"
# The hosted macOS runner image ships jq and grep but neither ripgrep nor uv. A
# readiness probe that needs rg demotes to warn there (gate exit 3), so the
# release gate must stay pass with no working `rg` on PATH.
gate_norg_tmp="$(mktemp -d)"
printf '#!/bin/sh\nexit 127\n' >"$gate_norg_tmp/rg"
chmod +x "$gate_norg_tmp/rg"
gate_norg_rc=0
PATH="$gate_norg_tmp:$PATH" sentry_gate_fixture gate release --json >"$gate_norg_tmp/out" 2>"$gate_norg_tmp/err" || gate_norg_rc=$?
jq -e '.verdict=="pass" and .exitCode==0 and .summary.warnings==0' "$gate_norg_tmp/out" >/dev/null \
  && [[ "$gate_norg_rc" -eq 0 ]] \
  && ok "gate release passes without ripgrep on PATH" \
  || fail_t "gate release depends on ripgrep rc=$gate_norg_rc: $(jq -c '[.warnings[]? | {key,detail}]' "$gate_norg_tmp/out" 2>/dev/null || cat "$gate_norg_tmp/out") stderr=$(cat "$gate_norg_tmp/err")"
rm -rf "$gate_norg_tmp"
sentry_fixture_json="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" sentry --json)"
echo "$sentry_fixture_json" | jq -e '.readiness.build_can_import == true and .build_evidence.source == "fixture"' >/dev/null \
  && ok "fixture Sentry readiness supplies deterministic build evidence" \
  || fail_t "fixture Sentry readiness lacks deterministic build evidence: $sentry_fixture_json"
gate_text_rc=0
gate_text="$(sentry_gate_fixture gate release)" || gate_text_rc=$?
echo "$gate_text" | grep -q 'verdict=pass' \
  && ok "gate release text emits verdict" || fail_t "gate release text missing verdict rc=$gate_text_rc: $gate_text"
gate_warn_tmp="$(mktemp -d)"
if KG_IOS_OPS_FIXTURE_TF_LATEST=unknown sentry_gate_fixture gate release --json >"$gate_warn_tmp/out" 2>"$gate_warn_tmp/err"; then
  fail_t "gate release warns on unknown TestFlight build"
else
  rc=$?
  jq -e '.schema=="kg.ios.gate.v1" and .verdict=="warn" and .exitCode==3 and .summary.warnings >= 1 and any(.warnings[]; .key=="testflight")' "$gate_warn_tmp/out" >/dev/null \
    && [[ "$rc" -eq 3 ]] \
    && ok "gate release warns on unknown TestFlight build" || fail_t "gate release warn invalid: $(cat "$gate_warn_tmp/out") stderr=$(cat "$gate_warn_tmp/err") rc=$rc"
fi
rm -rf "$gate_warn_tmp"
gate_block_tmp="$(mktemp -d)"
if KG_IOS_OPS_FIXTURE_TF_LATEST=4 sentry_gate_fixture gate release --json >"$gate_block_tmp/out" 2>"$gate_block_tmp/err"; then
  fail_t "gate release blocks duplicate TestFlight build"
else
  rc=$?
  jq -e '.schema=="kg.ios.gate.v1" and .verdict=="block" and .exitCode==2 and .summary.blocks >= 1 and any(.blocks[]; .key=="testflight")' "$gate_block_tmp/out" >/dev/null \
    && [[ "$rc" -eq 2 ]] \
    && ok "gate release blocks duplicate TestFlight build" || fail_t "gate release block invalid: $(cat "$gate_block_tmp/out") stderr=$(cat "$gate_block_tmp/err") rc=$rc"
fi
rm -rf "$gate_block_tmp"

section "Sentry wiring surface"
sentry_json="$(bash "$IOS_OPS" sentry --json)"
echo "$sentry_json" | jq -e '.schema=="kg.ios.sentry.v1" and .source.path=="'"$WORKSPACE"'/ios/BooksAndVocab/Services/AppCrashReporting.swift" and .source.exists==true and (.wiring.canImportGuard|type)=="boolean" and (.wiring.dsnKeyReference|type)=="boolean" and .debug.requiresEnv=="SENTRY_ENABLED_IN_DEBUG=1" and .debug.testArgument=="-sentryTest" and .release.name=="bundleId@MARKETING_VERSION+CURRENT_PROJECT_VERSION" and .release.dist=="CURRENT_PROJECT_VERSION"' >/dev/null \
  && ok "sentry --json exposes machine-readable wiring summary" || fail_t "sentry --json invalid: $sentry_json"
sentry_text="$(bash "$IOS_OPS" sentry)"
echo "$sentry_text" | grep -q '\[ios\]\[sentry\] source=' && echo "$sentry_text" | grep -q 'can_import_guard=' && echo "$sentry_text" | grep -q 'debug_requires_env=' && echo "$sentry_text" | grep -q 'release_name=' \
  && ok "sentry text reports wiring summary" || fail_t "sentry text invalid: $sentry_text"
sentry_warn_json="$(KG_IOS_OPS_SENTRY_SOURCE_FIXTURE=/tmp/kg-missing-sentry.swift KG_IOS_OPS_SENTRY_SOURCE_EXISTS_FIXTURE=0 KG_IOS_OPS_SENTRY_CAN_IMPORT_FIXTURE=0 KG_IOS_OPS_SENTRY_DSN_FIXTURE=0 bash "$IOS_OPS" sentry --json)"
echo "$sentry_warn_json" | jq -e '.schema=="kg.ios.sentry.v1" and .source.path=="/tmp/kg-missing-sentry.swift" and .source.exists==false and .wiring.canImportGuard==false and .wiring.dsnKeyReference==false' >/dev/null \
  && ok "sentry --json supports fixture-driven warning surface" || fail_t "sentry warning fixture invalid: $sentry_warn_json"
echo "$sentry_warn_json" | jq -e '(.issues|type)=="array" and (.issues|length)==3 and (.issues|map(.key)|sort)==["canImportGuard","dsnKeyReference","source"] and all(.issues[]; (.message|length)>0 and (.command|test("sentry --json")))' >/dev/null \
  && ok "sentry --json issues[] is single source of wiring failures" || fail_t "sentry issues invalid: $sentry_warn_json"
echo "$sentry_json" | jq -e '(.issues|type)=="array" and (.issues|length)==0' >/dev/null \
  && ok "sentry --json issues[] empty when wiring healthy" || fail_t "sentry healthy issues invalid: $sentry_json"

section "Runtime log surface"
logs_json="$(KG_IOS_OPS_LOG_FIXTURE=1 bash "$IOS_OPS" logs --json --since 1m --limit 1)"
echo "$logs_json" | jq -e '.schema=="kg.ios.logs.v1" and .since=="1m" and .limit==1 and .summary.rawCount==3 and .summary.filteredCount==1 and .summary.emittedCount==1 and .summary.byEventType.logEvent==1 and (.entries|length)==1 and .entries[0].message=="sync completed"' >/dev/null \
  && ok "logs --json emits filtered runtime log schema" || fail_t "logs --json invalid: $logs_json"
logs_sim_json="$(KG_IOS_OPS_LOG_FIXTURE=1 bash "$IOS_OPS" logs --json --simulator --device TEST-UDID --debug --since 1m --limit 1)"
echo "$logs_sim_json" | jq -e '.schema=="kg.ios.logs.v1" and (.source|contains("xcrun simctl spawn TEST-UDID log show --debug --info --style ndjson")) and .summary.emittedCount==1' >/dev/null \
  && ok "logs --json exposes simulator debug source" || fail_t "logs --json simulator debug source invalid: $logs_sim_json"
logs_leading_zero_json="$(KG_IOS_OPS_LOG_FIXTURE=1 bash "$IOS_OPS" logs --json --limit 001)"
echo "$logs_leading_zero_json" | jq -e '.limit==1 and .summary.emittedCount==1' >/dev/null \
  && ok "logs --json normalizes numeric limit" || fail_t "logs --json leading-zero limit invalid: $logs_leading_zero_json"
logs_text="$(KG_IOS_OPS_LOG_FIXTURE=1 bash "$IOS_OPS" logs --since 1m --limit 5 2>/dev/null)"
echo "$logs_text" | grep -q 'sync completed' \
  && ok "logs text emits app log entries" || fail_t "logs text missing app entry: $logs_text"
echo "$logs_text" | grep -q 'RBSServiceErrorDomain' \
  && fail_t "logs text failed to filter framework noise: $logs_text" || ok "logs text filters framework noise"
bad_logs_tmp="$(mktemp -d)"
if KG_IOS_OPS_LOG_FIXTURE=1 bash "$IOS_OPS" logs --limit nope >"$bad_logs_tmp/out" 2>"$bad_logs_tmp/err"; then
  fail_t "logs rejects non-numeric limit"
else
  grep -q -- '--limit must be' "$bad_logs_tmp/err" \
    && ok "logs rejects non-numeric limit" || fail_t "logs bad-limit message missing"
fi
rm -rf "$bad_logs_tmp"
fail_logs_tmp="$(mktemp -d)"
if KG_IOS_OPS_LOG_FAIL_FIXTURE=1 bash "$IOS_OPS" logs --since 1m >"$fail_logs_tmp/out" 2>"$fail_logs_tmp/err"; then
  fail_t "logs text propagates log show failure"
else
  grep -q 'fixture log failure' "$fail_logs_tmp/err" \
    && ok "logs text propagates log show failure" || fail_t "logs text failure stderr missing"
fi
if KG_IOS_OPS_LOG_FAIL_FIXTURE=1 bash "$IOS_OPS" logs --json --since 1m >"$fail_logs_tmp/json_out" 2>"$fail_logs_tmp/json_err"; then
  fail_t "logs --json propagates log show failure"
else
  rc=$?
  grep -q 'fixture log failure' "$fail_logs_tmp/json_err" && [[ "$rc" -eq 42 ]] \
    && ok "logs --json propagates log show failure" || fail_t "logs --json failure stderr missing"
fi
rm -rf "$fail_logs_tmp"

# logs --follow (live stream) fixtures
follow_text="$(KG_IOS_OPS_LOG_FIXTURE=1 bash "$IOS_OPS" logs --follow 2>/dev/null)"
echo "$follow_text" | grep -q 'sync completed' && echo "$follow_text" | grep -q 'reader opened' \
  && ok "logs --follow streams app entries" || fail_t "logs --follow missing app entries: $follow_text"
echo "$follow_text" | grep -q 'RBSServiceErrorDomain' \
  && fail_t "logs --follow failed to filter framework noise: $follow_text" || ok "logs --follow filters framework noise"
follow_limit_text="$(KG_IOS_OPS_LOG_FIXTURE=1 bash "$IOS_OPS" logs --follow --limit 1 2>/dev/null)"
[[ "$(echo "$follow_limit_text" | grep -c .)" -eq 1 ]] && echo "$follow_limit_text" | grep -q 'sync completed' \
  && ok "logs --follow honors --limit" || fail_t "logs --follow limit invalid: $follow_limit_text"
follow_json="$(KG_IOS_OPS_LOG_FIXTURE=1 bash "$IOS_OPS" logs --follow --json --limit 1 2>/dev/null)"
echo "$follow_json" | jq -e '.schema=="kg.ios.log-stream.v1" and .message=="sync completed" and .category=="sync"' >/dev/null \
  && ok "logs --follow --json emits ndjson entries" || fail_t "logs --follow --json invalid: $follow_json"
follow_fail_tmp="$(mktemp -d)"
if KG_IOS_OPS_LOG_FAIL_FIXTURE=1 bash "$IOS_OPS" logs --follow >"$follow_fail_tmp/out" 2>"$follow_fail_tmp/err"; then
  fail_t "logs --follow propagates stream failure"
else
  grep -q 'fixture log failure' "$follow_fail_tmp/err" \
    && ok "logs --follow propagates stream failure" || fail_t "logs --follow failure stderr missing"
fi
rm -rf "$follow_fail_tmp"
# real SIGPIPE(141) path: unbounded producer + --limit stop gate must exit 0 with N lines
stream_text="$(KG_IOS_OPS_LOG_STREAM_FIXTURE=1 bash "$IOS_OPS" logs --follow --limit 1 2>/dev/null)"; stream_rc=$?
[[ "$stream_rc" -eq 0 && "$(echo "$stream_text" | grep -c .)" -eq 1 ]] && echo "$stream_text" | grep -q 'sync completed' \
  && ok "logs --follow handles producer SIGPIPE at limit (text)" || fail_t "logs --follow SIGPIPE text rc=$stream_rc out=$stream_text"
stream_json="$(KG_IOS_OPS_LOG_STREAM_FIXTURE=1 bash "$IOS_OPS" logs --follow --json --limit 1 2>/dev/null)"; stream_json_rc=$?
[[ "$stream_json_rc" -eq 0 ]] && echo "$stream_json" | jq -e '.schema=="kg.ios.log-stream.v1" and .message=="sync completed"' >/dev/null \
  && ok "logs --follow handles producer SIGPIPE at limit (json)" || fail_t "logs --follow SIGPIPE json rc=$stream_json_rc out=$stream_json"
# pipefail must not leak out of the sourceable follow helpers
leak_check="$(set -o pipefail; source "$IOS_OPS_LOGS_LIB"; KG_IOS_OPS_LOG_STREAM_FIXTURE=1 cmd_logs_follow_text 'p' 1 >/dev/null 2>&1; if set -o | grep -q 'pipefail.*on'; then echo intact; else echo leaked; fi)"
[[ "$leak_check" == "intact" ]] \
  && ok "logs --follow does not leak pipefail to caller" || fail_t "logs --follow leaked pipefail: $leak_check"
# GitHub Actions runner steps start children with SIGPIPE ignored (the .NET runner ignores it and
# exec preserves SIG_IGN), so no SIGPIPE ever ends `producer | grep | head -n N`: BSD grep and jq
# swallow EPIPE and keep draining the producer, and the macOS job hung here until its 30 min cap.
# Reproduce that condition on any host; the process group is killed at the deadline so a
# regression fails (rc 142) instead of hanging the suite or leaking a spinning producer.
run_sigpipe_ignored() {
  perl -e '
    $SIG{PIPE} = "IGNORE";
    my $pid = fork();
    if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$pid; exit 142 };
    alarm 20;
    waitpid($pid, 0);
    exit($? >> 8 || ($? & 127 ? 128 + ($? & 127) : 0));
  ' "$@"
}
ignored_rc=0
ignored_text="$(run_sigpipe_ignored env KG_IOS_OPS_LOG_STREAM_FIXTURE=1 bash "$IOS_OPS" logs --follow --limit 1 2>/dev/null)" || ignored_rc=$?
[[ "$ignored_rc" -eq 0 && "$(echo "$ignored_text" | grep -c .)" -eq 1 ]] && echo "$ignored_text" | grep -q 'sync completed' \
  && ok "logs --follow stops at limit with SIGPIPE ignored (text)" || fail_t "logs --follow SIGPIPE-ignored text rc=$ignored_rc out=$ignored_text"
ignored_rc=0
ignored_json="$(run_sigpipe_ignored env KG_IOS_OPS_LOG_STREAM_FIXTURE=1 bash "$IOS_OPS" logs --follow --json --limit 1 2>/dev/null)" || ignored_rc=$?
[[ "$ignored_rc" -eq 0 && "$(echo "$ignored_json" | grep -c .)" -eq 1 ]] && echo "$ignored_json" | jq -e '.schema=="kg.ios.log-stream.v1" and .message=="sync completed"' >/dev/null \
  && ok "logs --follow stops at limit with SIGPIPE ignored (json)" || fail_t "logs --follow SIGPIPE-ignored json rc=$ignored_rc out=$ignored_json"

section "JSON smoke fixtures"
delegate_tmp="$(mktemp -d)"
cat > "$delegate_tmp/build_stub.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Per-invocation verdict contract: honor the wrapper's pinned path, keep the
# historical fixed path as a latest pointer (last-writer-wins).
latest="${TMPDIR:-/tmp}/kg_ios_build_verdict"
verdict="${KG_IOS_VERDICT_FILE:-$latest.$(date +%s)-$$}"
json="$verdict.json"
printf 'RESULT=ok EXIT=0 caller=stub-build elapsed=1s log=%s/build.log xcresult=%s/Build.xcresult\n' "${TMPDIR:-/tmp}" "${TMPDIR:-/tmp}" >"$verdict"
mkdir -p "${TMPDIR:-/tmp}/Build.xcresult"
: > "${TMPDIR:-/tmp}/build.log"
jq -nc --arg log "${TMPDIR:-/tmp}/build.log" --arg xcresult "${TMPDIR:-/tmp}/Build.xcresult" '{schema:"kg.ios.run-verdict.v1",kind:"build",status:"ok",result:"ok",exit:"0",reason:null,caller:"stub-build",elapsed:"1s",executed:null,timings:{bootMs:11,xcodebuildMs:22,totalMs:33},artifacts:{log:$log,xcresult:$xcresult}}' >"$json"
cp -f "$verdict" "$latest"
cp -f "$json" "$latest.json"
# RACE FIXTURE: a concurrent session finishes right after us and wins the
# latest pointer. The wrapper MUST still report OUR run (caller=stub-build),
# never the foreign one — this is the multi-session verdict race regression.
printf 'RESULT=fail EXIT=1 caller=foreign-session elapsed=9s log=/dev/null xcresult=/dev/null\n' >"$latest"
jq -nc '{schema:"kg.ios.run-verdict.v1",kind:"build",status:"fail",result:"fail",exit:"1",reason:null,caller:"foreign-session",elapsed:"9s",executed:null,timings:{},artifacts:{log:"/dev/null",xcresult:"/dev/null"}}' >"$latest.json"
echo "build stub stdout"
SH
cat > "$delegate_tmp/test_stub.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if printf '%s\n' "$@" | grep -qx -- '--cache-status'; then
  jq -nc '{schema:"kg.ios.test-cache.v1",scope:"unit",status:"ok",cache:{status:"hit"}}'
  exit 0
fi
latest="${TMPDIR:-/tmp}/kg_ios_test_verdict"
verdict="${KG_IOS_VERDICT_FILE:-$latest.$(date +%s)-$$}"
json="$verdict.json"
printf 'RESULT=ok EXIT=0 caller=stub-test elapsed=2s executed=7 log=%s/test.log xcresult=%s/Test.xcresult\n' "${TMPDIR:-/tmp}" "${TMPDIR:-/tmp}" >"$verdict"
mkdir -p "${TMPDIR:-/tmp}/Test.xcresult"
: > "${TMPDIR:-/tmp}/test.log"
mkdir -p "${TMPDIR:-/tmp}/ui-steps"
: > "${TMPDIR:-/tmp}/ui-steps/contact_sheet.png"
: > "${TMPDIR:-/tmp}/ui-steps/quick4_contact_sheet.png"
: > "${TMPDIR:-/tmp}/ui-steps/review_manifest.json"
: > "${TMPDIR:-/tmp}/ui-steps/run_recording.mp4"
mkdir -p "${TMPDIR:-/tmp}/ui-review"
: > "${TMPDIR:-/tmp}/ui-review/UIreview.html"
jq -nc --arg log "${TMPDIR:-/tmp}/test.log" --arg xcresult "${TMPDIR:-/tmp}/Test.xcresult" --arg sheet "${TMPDIR:-/tmp}/ui-steps/contact_sheet.png" --arg quick4 "${TMPDIR:-/tmp}/ui-steps/quick4_contact_sheet.png" --arg manifest "${TMPDIR:-/tmp}/ui-steps/review_manifest.json" --arg screenshotDir "${TMPDIR:-/tmp}/ui-steps" --arg video "${TMPDIR:-/tmp}/ui-steps/run_recording.mp4" --arg reviewRoot "${TMPDIR:-/tmp}/ui-review" --arg reviewHtml "${TMPDIR:-/tmp}/ui-review/UIreview.html" --arg device "STUB-UDID-1234" '{schema:"kg.ios.run-verdict.v1",kind:"test",status:"ok",result:"ok",exit:"0",reason:null,caller:"stub-test",elapsed:"2s",executed:"7",device:$device,options:{uiLaunchProfile:"standard"},cache:{status:"hit"},timings:{bootMs:44,buildForTestingMs:0,testInvocationMs:55,testBodyMs:21,xcresultSessionMs:34,xcresultHarnessOverheadMs:13,appLaunchAverageMs:8,appLaunchSamples:5,invocationOverheadMs:21,xcodebuildMs:55,totalMs:99},artifacts:{log:$log,xcresult:$xcresult,uiContactSheet:$sheet,uiQuick4Sheet:$quick4,uiVisualReviewManifest:$manifest,uiScreenshotDir:$screenshotDir,uiVideo:$video,uiVideoIdentity:{runID:"stub-run-123",file:"run_recording.mp4",sha256:"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},uiReviewRoot:$reviewRoot,uiReviewHtml:$reviewHtml}}' >"$json"
cp -f "$verdict" "$latest"
cp -f "$json" "$latest.json"
# RACE FIXTURE: concurrent session clobbers the latest pointer after our run.
printf 'RESULT=fail EXIT=1 caller=foreign-session elapsed=9s log=/dev/null xcresult=/dev/null\n' >"$latest"
jq -nc '{schema:"kg.ios.run-verdict.v1",kind:"test",status:"fail",result:"fail",exit:"1",reason:null,caller:"foreign-session",elapsed:"9s",executed:null,timings:{},artifacts:{log:"/dev/null",xcresult:"/dev/null"}}' >"$latest.json"
echo "test stub stdout"
SH
cat > "$delegate_tmp/archive_stub.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
latest="${TMPDIR:-/tmp}/kg_ios_archive_verdict"
verdict="${KG_IOS_VERDICT_FILE:-$latest.$(date +%s)-$$}"
json="$verdict.json"
mkdir -p "${TMPDIR:-/tmp}/Archive.xcresult" "${TMPDIR:-/tmp}/export"
: > "${TMPDIR:-/tmp}/archive.log"
: > "${TMPDIR:-/tmp}/export/BooksAndVocab.ipa"
printf 'RESULT=ok EXIT=0 caller=stub-archive archive=%s/BooksAndVocab.xcarchive log=%s/archive.log xcresult=%s/Archive.xcresult\n' "${TMPDIR:-/tmp}" "${TMPDIR:-/tmp}" "${TMPDIR:-/tmp}" >"$verdict"
jq -nc --arg archive "${TMPDIR:-/tmp}/BooksAndVocab.xcarchive" --arg log "${TMPDIR:-/tmp}/archive.log" --arg xcresult "${TMPDIR:-/tmp}/Archive.xcresult" --arg exportDir "${TMPDIR:-/tmp}/export" --arg ipa "${TMPDIR:-/tmp}/export/BooksAndVocab.ipa" '{schema:"kg.ios.archive.v1",status:"ok",exit:"0",caller:"stub-archive",options:{keyId:"TCXVHFRXMS",uploadRequested:false},archive:{status:"ok",elapsed:"12s",path:$archive,log:$log,xcresult:$xcresult},export:{status:"ok",directory:$exportDir,ipa:$ipa},upload:{status:"skipped",requested:false,completed:false}}' >"$json"
cp -f "$verdict" "$latest"
cp -f "$json" "$latest.json"
# RACE FIXTURE: concurrent session clobbers the latest pointer after our run.
printf 'RESULT=fail EXIT=1 caller=foreign-session archive=/dev/null log=/dev/null xcresult=/dev/null\n' >"$latest"
jq -nc '{schema:"kg.ios.archive.v1",status:"fail",exit:"1",caller:"foreign-session",options:{keyId:null,uploadRequested:false},archive:{status:"fail",elapsed:null,path:null,log:null,xcresult:null},export:{status:"skipped",directory:null,ipa:null},upload:{status:"skipped",requested:false,completed:false}}' >"$latest.json"
echo "archive stub stdout"
SH
chmod +x "$delegate_tmp/build_stub.sh" "$delegate_tmp/test_stub.sh" "$delegate_tmp/archive_stub.sh"
build_direct_json="$(TMPDIR="$delegate_tmp" KG_IOS_BUILD_DELEGATE="$delegate_tmp/build_stub.sh" bash "$IOS_OPS" build --json 2>"$delegate_tmp/build_stderr")"
echo "$build_direct_json" | jq -e '.schema=="kg.ios.run.v1" and .kind=="build" and .result=="ok" and .caller=="stub-build" and .timings.totalMs==33 and .uiVisualReview==null and .diagnostics.schema=="kg.ios.diagnostics.v1"' >/dev/null \
  && ok "build --json emits machine-readable run report" || fail_t "build --json invalid: $build_direct_json"
grep -q 'build stub stdout' "$delegate_tmp/build_stderr" \
  && ok "build --json redirects delegate stdout to stderr" || fail_t "build --json missing delegate output forwarding"
test_direct_json="$(TMPDIR="$delegate_tmp" KG_IOS_TEST_DELEGATE="$delegate_tmp/test_stub.sh" bash "$IOS_OPS" test --json 2>"$delegate_tmp/test_stderr")"
echo "$test_direct_json" | jq -e '.schema=="kg.ios.run.v1" and .kind=="test" and .result=="ok" and .executed=="7" and .cache.status=="hit" and .timings.appLaunchAverageMs==8 and .artifacts.uiContactSheetExists==true and .artifacts.uiQuick4SheetExists==true and .artifacts.uiVisualReviewManifestExists==true and .artifacts.uiVideoExists==true and .artifacts.uiReviewRootExists==true and .artifacts.uiReviewHtmlExists==true and .device=="STUB-UDID-1234" and .diagnostics.schema=="kg.ios.diagnostics.v1"' >/dev/null \
  && ok "test --json emits machine-readable run report" || fail_t "test --json invalid: $test_direct_json"
echo "$test_direct_json" | jq -e '.uiVisualReview.contactSheet==.artifacts.uiContactSheet and .uiVisualReview.contactSheetExists==true and .uiVisualReview.quick4Sheet==.artifacts.uiQuick4Sheet and .uiVisualReview.quick4SheetExists==true and .uiVisualReview.visualReviewManifest==.artifacts.uiVisualReviewManifest and .uiVisualReview.visualReviewManifestExists==true and .uiVisualReview.screenshotDir==.artifacts.uiScreenshotDir and .uiVisualReview.video==.artifacts.uiVideo and .uiVisualReview.videoExists==true and .uiVisualReview.reviewRoot==.artifacts.uiReviewRoot and .uiVisualReview.reviewRootExists==true and .uiVisualReview.reviewHtml==.artifacts.uiReviewHtml and .uiVisualReview.reviewHtmlExists==true' >/dev/null \
  && ok "test --json exposes uiVisualReview block" || fail_t "test --json missing uiVisualReview block: $test_direct_json"
echo "$test_direct_json" | jq -e '.artifacts.uiVideoIdentity=={runID:"stub-run-123",file:"run_recording.mp4",sha256:"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"} and .uiVisualReview.videoIdentity==.artifacts.uiVideoIdentity' >/dev/null \
  && ok "test --json preserves stable video identity" || fail_t "test --json dropped or rewrote video identity: $test_direct_json"
grep -q 'test stub stdout' "$delegate_tmp/test_stderr" \
  && ok "test --json redirects delegate stdout to stderr" || fail_t "test --json missing delegate output forwarding"
test_cache_json="$(TMPDIR="$delegate_tmp" KG_IOS_TEST_DELEGATE="$delegate_tmp/test_stub.sh" bash "$IOS_OPS" test --cache-status --json)"
echo "$test_cache_json" | jq -e '.schema=="kg.ios.test-cache.v1" and .cache.status=="hit"' >/dev/null \
  && ok "test --cache-status --json keeps native cache schema" || fail_t "test cache native json invalid: $test_cache_json"
archive_direct_json="$(TMPDIR="$delegate_tmp" KG_IOS_RELEASE_DELEGATE="$delegate_tmp/archive_stub.sh" bash "$IOS_OPS" archive --json 2>"$delegate_tmp/archive_stderr")"
echo "$archive_direct_json" | jq -e '.schema=="kg.ios.archive.v1" and .status=="ok" and .caller=="stub-archive" and .archive.status=="ok" and .archive.elapsed=="12s" and .export.status=="ok" and .upload.status=="skipped"' >/dev/null \
  && ok "archive --json emits machine-readable archive report" || fail_t "archive --json invalid: $archive_direct_json"
grep -q 'archive stub stdout' "$delegate_tmp/archive_stderr" \
  && ok "archive --json redirects delegate stdout to stderr" || fail_t "archive --json missing delegate output forwarding"
rm -rf "$delegate_tmp"

runs_parent="$(mktemp -d)"
runs_tmp="$runs_parent/with spaces"
mkdir -p "$runs_tmp"
mkdir -p "$runs_tmp/Build.xcresult" "$runs_tmp/Test.xcresult" "$runs_tmp/Archive.xcresult"
cat > "$runs_tmp/build.log" <<'LOG'
warning: StoreKit Configuration file for scheme "BooksAndVocab" can't be found at path "/tmp/missing.storekit"
** BUILD SUCCEEDED **
LOG
cat > "$runs_tmp/test.log" <<'LOG'
** TEST SUCCEEDED **
LOG
cat > "$runs_tmp/archive.log" <<'LOG'
warning: StoreKit Configuration file for scheme "BooksAndVocab" can't be found at path "/tmp/archive-missing.storekit"
** BUILD SUCCEEDED **
LOG
echo "RESULT=legacy" > "$runs_tmp/kg_ios_build_verdict"
jq -nc --arg log "$runs_tmp/build.log" --arg xcresult "$runs_tmp/Build.xcresult" \
  '{schema:"kg.ios.run-verdict.v1",kind:"build",status:"ok",result:"ok",exit:"0",reason:null,caller:"fixture with spaces",elapsed:"3s",executed:null,timings:{lockWaitMs:90,bootMs:120,xcodebuildMs:3000,totalMs:3120,probeMs:777},artifacts:{log:$log,xcresult:$xcresult}}' \
  > "$runs_tmp/kg_ios_build_verdict.json"
jq -nc --arg log "$runs_tmp/test.log" --arg xcresult "$runs_tmp/Test.xcresult" \
  '{schema:"kg.ios.run-verdict.v1",kind:"test",status:"ok",result:"ok",exit:"0",reason:null,caller:"fixture with spaces",elapsed:"5s",executed:"12",options:{uiLaunchProfile:"standard"},cache:{status:"hit"},timings:{lockWaitMs:140,bootMs:250,buildForTestingMs:0,testInvocationMs:6000,testBodyMs:2000,xcresultSessionMs:3500,xcresultHarnessOverheadMs:1500,appLaunchAverageMs:1450,appLaunchSamples:5,invocationOverheadMs:2500,xcodebuildMs:6000,totalMs:6500},artifacts:{log:$log,xcresult:$xcresult}}' \
  > "$runs_tmp/kg_ios_test_verdict.json"
jq -nc --arg log "$runs_tmp/archive.log" --arg xcresult "$runs_tmp/Archive.xcresult" --arg archive "$runs_tmp/BooksAndVocab.xcarchive" --arg exportDir "$runs_tmp/export" --arg ipa "$runs_tmp/export/BooksAndVocab.ipa" \
  '{schema:"kg.ios.archive.v1",status:"ok",exit:"0",caller:"fixture with spaces",options:{keyId:"TCXVHFRXMS",uploadRequested:false},archive:{status:"ok",elapsed:"14s",path:$archive,log:$log,xcresult:$xcresult},export:{status:"ok",directory:$exportDir,ipa:$ipa},upload:{status:"skipped",requested:false,completed:false},timings:{lockWaitMs:10,archiveMs:12000,exportMs:1500,uploadMs:0,totalMs:13510},artifacts:{log:$log,xcresult:$xcresult,archive:$archive,exportDirectory:$exportDir,ipa:$ipa}}' \
  > "$runs_tmp/kg_ios_archive_verdict.json"
runs_json="$(TMPDIR="$runs_tmp" bash "$IOS_OPS" runs --json)"
echo "$runs_json" | jq -e '.schema=="kg.ios.runs.v1" and .summary.verdict=="warn" and .summary.counts.errors==0 and .summary.counts.warnings==2 and .summary.counts.failedTests==0 and .summary.counts.missing==0 and .summary.counts.malformed==0 and .summary.counts.failing==0 and .build.result=="ok" and .build.caller=="fixture with spaces" and .test.executed=="12" and .archive.result=="ok" and .archive.timings.totalMs==13510 and .archive.timings.archiveMs==12000 and .archive.artifacts.logExists==true and .archive.artifacts.xcresultExists==true and .build.artifacts.logExists==true and .test.artifacts.xcresultExists==true and .build.diagnostics.schema=="kg.ios.diagnostics.v1" and .archive.diagnostics.schema=="kg.ios.diagnostics.v1" and .build.diagnostics.counts.warnings==1 and .archive.diagnostics.counts.warnings==1 and .build.timings.totalMs==3120 and .build.timings.lockWaitMs==90 and .test.timings.lockWaitMs==140 and .test.cache.status=="hit" and .test.options.uiLaunchProfile=="standard" and .test.timings.appLaunchAverageMs==1450 and .test.timings.appLaunchSamples==5' >/dev/null \
  && ok "runs --json parses latest build/test/archive verdicts (incl lockWaitMs passthrough)" || fail_t "runs --json invalid: $runs_json"
echo "$runs_json" | jq -e 'all([.build,.test,.archive][]; has("kind") and has("status") and has("result") and has("exit") and has("reason") and has("caller") and has("elapsed") and has("executed") and has("device") and has("options") and has("cache") and has("timings") and has("verdictFile") and has("jsonVerdictFile") and has("artifacts") and has("uiVisualReview") and has("diagnostics"))' >/dev/null \
  && ok "runs --json uses stable verdict object keys" || fail_t "runs --json missing stable keys: $runs_json"
runs_text="$(TMPDIR="$runs_tmp" bash "$IOS_OPS" runs)"
printf '%s\n' "$runs_text" | grep -q '^\[ios\]\[runs\] summary verdict=warn errors=0 warnings=2 failedTests=0 missing=0 malformed=0 failing=0' \
  && ok "runs text reports aggregate summary" || fail_t "runs text missing summary: $runs_text"
missing_runs_tmp="$(mktemp -d)"
missing_runs_json="$(TMPDIR="$missing_runs_tmp" bash "$IOS_OPS" runs --json)"
echo "$missing_runs_json" | jq -e '.schema=="kg.ios.runs.v1" and .summary.verdict=="unknown" and .summary.counts.missing==3 and .summary.counts.malformed==0 and .summary.counts.failing==0 and .build.status=="missing" and .build.artifacts.log==null and .build.artifacts.logExists==false and .test.result=="missing" and .archive.result=="missing"' >/dev/null \
  && ok "runs --json has stable missing-verdict schema" || fail_t "runs missing-verdict schema invalid: $missing_runs_json"
rm -rf "$missing_runs_tmp"
malformed_runs_tmp="$(mktemp -d)"
echo "RESULT=ok caller=legacy elapsed=1s log=$malformed_runs_tmp/build.log xcresult=$malformed_runs_tmp/Build.xcresult" > "$malformed_runs_tmp/kg_ios_build_verdict"
echo '{bad json' > "$malformed_runs_tmp/kg_ios_build_verdict.json"
echo '{bad json' > "$malformed_runs_tmp/kg_ios_test_verdict.json"
echo '{bad json' > "$malformed_runs_tmp/kg_ios_archive_verdict.json"
malformed_runs_json="$(TMPDIR="$malformed_runs_tmp" bash "$IOS_OPS" runs --json 2>"$malformed_runs_tmp/stderr")"
echo "$malformed_runs_json" | jq -e '.schema=="kg.ios.runs.v1" and .summary.verdict=="block" and .summary.counts.malformed==2 and .summary.counts.failing==2 and .build.result=="ok" and .test.status=="malformed" and .test.reason=="malformed-json-verdict" and .archive.status=="malformed" and .archive.reason=="malformed-json-verdict"' >/dev/null \
  && ok "runs --json falls back or reports malformed JSON verdicts" || fail_t "runs malformed-verdict schema invalid: $malformed_runs_json"
echo "$malformed_runs_json" | jq -e 'all([.build,.test,.archive][]; has("jsonVerdictFile") and has("artifacts"))' >/dev/null \
  && ok "runs malformed/legacy fallback keeps stable keys" || fail_t "runs malformed/legacy fallback missing stable keys: $malformed_runs_json"
[[ ! -s "$malformed_runs_tmp/stderr" ]] \
  && ok "runs --json suppresses malformed verdict parser noise" || fail_t "runs malformed-verdict stderr not clean: $(cat "$malformed_runs_tmp/stderr")"
malformed_runs_text="$(TMPDIR="$malformed_runs_tmp" bash "$IOS_OPS" runs 2>"$malformed_runs_tmp/text_stderr")"
echo "$malformed_runs_text" | grep -q 'kind=build status=ok' \
  && ok "runs text uses normalized verdict fallback" || fail_t "runs text malformed fallback invalid: $malformed_runs_text"
[[ ! -s "$malformed_runs_tmp/text_stderr" ]] \
  && ok "runs text suppresses malformed verdict parser noise" || fail_t "runs text malformed-verdict stderr not clean: $(cat "$malformed_runs_tmp/text_stderr")"
rm -rf "$malformed_runs_tmp"
doctor_json="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" doctor --json)"
echo "$doctor_json" | jq -e '.schema=="kg.ios.doctor.v1" and (.readiness|length >= 7) and any(.readiness[]; .key=="testflight") and (.summary.verdict|inside("passwarnblock")) and .summary.counts.ok >= 1 and .summary.counts.block==0 and .summary.counts.total == (.readiness|length) and (.summary.counts.ok + .summary.counts.warn + .summary.counts.block == .summary.counts.total) and .sentry.schema=="kg.ios.sentry.v1" and .sentry.source.exists==true and (.sentry.wiring.canImportGuard|type)=="boolean" and (.sentry.wiring.dsnKeyReference|type)=="boolean"' >/dev/null \
  && ok "doctor --json parses with readiness array summary and embedded sentry summary" || fail_t "doctor --json invalid: $doctor_json"
doctor_sentry_warn_json="$(KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_SENTRY_SOURCE_FIXTURE=/tmp/kg-missing-sentry.swift KG_IOS_OPS_SENTRY_SOURCE_EXISTS_FIXTURE=0 KG_IOS_OPS_SENTRY_CAN_IMPORT_FIXTURE=0 KG_IOS_OPS_SENTRY_DSN_FIXTURE=0 bash "$IOS_OPS" doctor --json)"
echo "$doctor_sentry_warn_json" | jq -e '.summary.verdict=="warn" and .summary.counts.warn >= 1 and .sentry.source.path=="/tmp/kg-missing-sentry.swift" and .sentry.source.exists==false and .sentry.wiring.canImportGuard==false and .sentry.wiring.dsnKeyReference==false and any(.readiness[]; .key=="sentry" and .status=="warn" and (.detail|contains("source_exists=false")) and (.detail|contains("can_import_guard=false")) and (.detail|contains("dsn_key_reference=false")))' >/dev/null \
  && ok "doctor --json reuses sentry fixture-driven warning surface" || fail_t "doctor sentry warning invalid: $doctor_sentry_warn_json"
doctor_text="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" doctor)"
echo "$doctor_text" | grep -Eq '^\[ios\]\[doctor\] summary verdict=(pass|warn|block) ok=' \
  && ok "doctor text reports readiness summary" || fail_t "doctor text missing summary: $doctor_text"
workflow_json="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" workflow release --json)"
echo "$workflow_json" | jq -e '.schema=="kg.ios.workflow.v1" and .appReviewGate.verdict.status=="pass" and (.summary.verdict|inside("passwarnblock")) and .summary.counts.ready >= 1 and .summary.counts.todo >= 1 and .summary.counts.manual == 1 and (.summary.counts.ready + .summary.counts.todo + .summary.counts.block + .summary.counts.warn + .summary.counts.manual == .summary.counts.total) and .summary.counts.total == (.steps|length) and (.steps|length == 8) and any(.steps[]; .key=="upload")' >/dev/null \
  && ok "workflow release --json parses with steps array" || fail_t "workflow release --json invalid: $workflow_json"
workflow_review_block_json="$(KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_APP_REVIEW_GATE_FIXTURE=block bash "$IOS_OPS" workflow release --json)"
echo "$workflow_review_block_json" | jq -e --arg spec "$WORKSPACE/ops/app_review/2.0.0.json" '.appReviewGate.verdict.status=="block" and .summary.verdict=="block" and .summary.counts.manual==0 and .summary.counts.block >= 1 and ([.steps[] | select(.key=="submit" and .status=="block" and .command==("./ops/app_review_evidence.py status --spec " + $spec))] | length)==1 and ([.steps[] | select(.key=="submit" and .status=="manual")] | length)==0' >/dev/null \
  && ok "workflow App Review BLOCK replaces manual-ready submit with one producer-status command" || fail_t "workflow bypassed App Review gate: $workflow_review_block_json"
workflow_review_missing_json="$(KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_APP_REVIEW_GATE_FIXTURE=missing bash "$IOS_OPS" workflow release --json)"
echo "$workflow_review_missing_json" | jq -e '.summary.verdict=="block" and .appReviewGate.blocks[0].code=="gate.spec.missing" and any(.steps[]; .key=="submit" and .status=="block")' >/dev/null \
  && ok "workflow missing App Review spec blocks submit" || fail_t "workflow ignored missing App Review gate: $workflow_review_missing_json"
invalid_review_gate_fixture="$(mktemp)"
printf '{not-json\n' >"$invalid_review_gate_fixture"
workflow_review_invalid_json="$(KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_APP_REVIEW_GATE_FIXTURE="$invalid_review_gate_fixture" bash "$IOS_OPS" workflow release --json)"
rm -f "$invalid_review_gate_fixture"
echo "$workflow_review_invalid_json" | jq -e '.summary.verdict=="block" and .appReviewGate.blocks[0].code=="gate.report.invalid" and any(.steps[]; .key=="submit" and .status=="block")' >/dev/null \
  && ok "workflow malformed App Review report fails closed as structured BLOCK" || fail_t "workflow malformed gate report escaped fail-closed handling: $workflow_review_invalid_json"
workflow_text="$(KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" workflow release)"
echo "$workflow_text" | grep -Eq '^\[ios\]\[workflow\] summary verdict=(pass|warn|block) ready=' \
  && ok "workflow text reports aggregate summary" || fail_t "workflow text missing summary: $workflow_text"
snapshot_json="$(TMPDIR="$runs_tmp" sentry_gate_fixture snapshot --json)"
echo "$snapshot_json" | jq -e '.schema=="kg.ios.snapshot.v1" and (.readiness|length >= 7) and (.workflow.steps|length == 8) and .gate.schema=="kg.ios.gate.v1" and .gate.verdict=="pass" and .gate.exitCode==0 and .summary.verdict=="warn" and .summary.counts.readinessOk==([.readiness[] | select(.status=="ok")] | length) and .summary.counts.readinessWarns==([.readiness[] | select(.status=="warn")] | length) and .summary.counts.readinessBlocks==([.readiness[] | select(.status=="block")] | length) and .summary.counts.workflowReady==.workflow.summary.counts.ready and .summary.counts.workflowTodos==.workflow.summary.counts.todo and .summary.counts.workflowWarns==.workflow.summary.counts.warn and .summary.counts.workflowBlocks==.workflow.summary.counts.block and .summary.counts.workflowManual==.workflow.summary.counts.manual and .summary.counts.buildWarnings==1 and .summary.counts.archiveWarnings==1 and .summary.counts.sentryWarnings==0 and .summary.timings.build.totalMs==3120 and .summary.timings.build.lockWaitMs==90 and .summary.timings.build.probeMs==777 and .summary.timings.test.lockWaitMs==140 and .summary.timings.test.cacheStatus=="hit" and .summary.timings.test.appLaunchAverageMs==1450 and .summary.timings.test.appLaunchSamples==5 and .summary.timings.archive.totalMs==13510 and .summary.timings.archive.archiveMs==12000 and (.summary.timings.simulator.totalMs|type)=="number" and (.summary.timings.simulator.simctlDevicesMs|type)=="number" and (.summary.timings.simulator.appContainerMs|type)=="number" and (.summary.timings.simulator.appProcessMs|type)=="number" and any(.summary.nextActions[]; .source=="runs.build.diagnostics" and .severity=="warn" and .category=="storekit" and (.message|contains("StoreKit Configuration"))) and any(.summary.nextActions[]; .source=="runs.archive.diagnostics" and .severity=="warn" and .category=="storekit" and (.message|contains("StoreKit Configuration"))) and any(.summary.nextActions[]; .source=="gate" and .severity=="manual" and .key=="submit") and .sentry.schema=="kg.ios.sentry.v1" and .sentry.source.exists==true and .sentry.wiring.canImportGuard==true and .sentry.wiring.dsnKeyReference==true and .xcode.schema=="kg.ios.xcode.v1" and .xcode.simulators.summary.booted==1 and .simulator.schema=="kg.ios.simulator.v1" and .simulator.app.process.status=="running" and .project.version=="1.6" and .runs.test.executed=="12" and .runs.archive.result=="ok" and .runs.archive.diagnostics.counts.warnings==1 and .logs==null' >/dev/null \
  && ok "snapshot --json combines readiness and workflow" || fail_t "snapshot --json invalid: $snapshot_json"

# Verdict three-tier consistency contract. The "blocks>0 -> block; elif warns>0
# -> warn; else pass" rule is deliberately NOT extracted into a shared helper
# (doctor/workflow/gate/snapshot inputs are heterogeneous; runs adds a justified
# 'unknown' branch — extracting would force a fragile cross-file jq def for a
# 3-line rule). Instead this contract locks the 3 count-based surfaces against a
# single canonical rule so any drift (e.g. swapping warn/block precedence) fails.
verdict_rule='def rule($b;$w): if $b>0 then "block" elif $w>0 then "warn" else "pass" end;'
echo "$doctor_json" | jq -e "$verdict_rule"' .summary.verdict == rule(.summary.counts.block; .summary.counts.warn)' >/dev/null \
  && ok "doctor verdict follows canonical three-tier rule" || fail_t "doctor verdict drifted: $doctor_json"
echo "$workflow_json" | jq -e "$verdict_rule"' .summary.verdict == rule(.summary.counts.block; .summary.counts.warn)' >/dev/null \
  && ok "workflow verdict follows canonical three-tier rule" || fail_t "workflow verdict drifted: $workflow_json"
echo "$snapshot_json" | jq -e "$verdict_rule"' .gate.verdict == rule(.gate.summary.blocks; .gate.summary.warnings)' >/dev/null \
  && ok "gate verdict follows canonical three-tier rule" || fail_t "gate verdict drifted: $snapshot_json"
snapshot_skip_xcode_json="$(TMPDIR="$runs_tmp" sentry_gate_fixture snapshot --json --skip-xcode)"
echo "$snapshot_skip_xcode_json" | jq -e '.schema=="kg.ios.snapshot.v1" and .summary.verdict=="warn" and .sentry.schema=="kg.ios.sentry.v1" and .xcode==null and .simulator.schema=="kg.ios.simulator.v1" and .runs.test.executed=="12"' >/dev/null \
  && ok "snapshot --json can skip xcode inventory" || fail_t "snapshot --json --skip-xcode invalid: $snapshot_skip_xcode_json"
snapshot_skip_simulator_json="$(TMPDIR="$runs_tmp" sentry_gate_fixture snapshot --json --skip-simulator)"
echo "$snapshot_skip_simulator_json" | jq -e '.schema=="kg.ios.snapshot.v1" and .summary.verdict=="warn" and .sentry.schema=="kg.ios.sentry.v1" and .xcode.schema=="kg.ios.xcode.v1" and .simulator==null and .runs.test.executed=="12"' >/dev/null \
  && ok "snapshot --json can skip simulator status" || fail_t "snapshot --json --skip-simulator invalid: $snapshot_skip_simulator_json"
snapshot_no_booted_json="$(TMPDIR="$runs_tmp" KG_IOS_OPS_SIM_NO_BOOTED_FIXTURE=1 sentry_gate_fixture snapshot --json)"
echo "$snapshot_no_booted_json" | jq -e '.schema=="kg.ios.snapshot.v1" and .summary.verdict=="warn" and .sentry.schema=="kg.ios.sentry.v1" and any(.summary.nextActions[]; .source=="simulator" and .severity=="warn" and .key=="booted-device") and .simulator.schema=="kg.ios.simulator.v1" and .simulator.status=="error" and any(.simulator.errors[]; .key=="booted-device") and .runs.test.executed=="12"' >/dev/null \
  && ok "snapshot --json embeds simulator error without failing" || fail_t "snapshot no-booted simulator invalid: $snapshot_no_booted_json"
snapshot_sentry_warn_json="$(TMPDIR="$runs_tmp" KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_SENTRY_SOURCE_FIXTURE=/tmp/kg-missing-sentry.swift KG_IOS_OPS_SENTRY_SOURCE_EXISTS_FIXTURE=0 KG_IOS_OPS_SENTRY_CAN_IMPORT_FIXTURE=0 KG_IOS_OPS_SENTRY_DSN_FIXTURE=0 bash "$IOS_OPS" snapshot --json --skip-xcode --skip-simulator)"
echo "$snapshot_sentry_warn_json" | jq -e '.schema=="kg.ios.snapshot.v1" and .summary.verdict=="warn" and .summary.counts.sentryWarnings==3 and .summary.counts.sentryWarnings==(.sentry.issues|length) and (.sentry.issues|map(.key)|sort)==["canImportGuard","dsnKeyReference","source"] and any(.summary.nextActions[]; .source=="sentry" and .key=="source" and .severity=="warn") and any(.summary.nextActions[]; .source=="sentry" and .key=="canImportGuard" and .severity=="warn") and any(.summary.nextActions[]; .source=="sentry" and .key=="dsnKeyReference" and .severity=="warn") and .sentry.source.exists==false and .sentry.wiring.canImportGuard==false and .sentry.wiring.dsnKeyReference==false' >/dev/null \
  && ok "snapshot --json surfaces sentry wiring drift as warnings" || fail_t "snapshot sentry warning invalid: $snapshot_sentry_warn_json"
snapshot_logs_json="$(TMPDIR="$runs_tmp" KG_IOS_OPS_LOG_FIXTURE=1 sentry_gate_fixture snapshot --json --include-logs --log-since 1m --log-limit 1)"
echo "$snapshot_logs_json" | jq -e '.schema=="kg.ios.snapshot.v1" and .summary.counts.runtimeLogs==1 and .sentry.schema=="kg.ios.sentry.v1" and .simulator.schema=="kg.ios.simulator.v1" and .logs.schema=="kg.ios.logs.v1" and .logs.since=="1m" and .logs.limit==1 and .logs.summary.filteredCount==1 and (.logs.entries|length)==1' >/dev/null \
  && ok "snapshot --json can include runtime logs" || fail_t "snapshot --json logs invalid: $snapshot_logs_json"
snapshot_text="$(TMPDIR="$runs_tmp" sentry_gate_fixture snapshot --skip-xcode --skip-simulator)"
printf '%s\n' "$snapshot_text" | sed -n '1p' | grep -q '^\[ios\]\[summary\].*verdict=warn.*readinessWarns=.*workflowManual=1.*buildWarnings=1.*sentryWarnings=0' \
  && ok "snapshot text starts with summary verdict" || fail_t "snapshot text first line missing summary: $snapshot_text"
printf '%s\n' "$snapshot_text" | sed -n '2p' | grep -q '^\[ios\]\[timing\] build cacheStatus=n/a totalMs=3120 bootMs=120 xcodebuildMs=3000' \
  && ok "snapshot text prints build timing line" || fail_t "snapshot text missing build timing line: $snapshot_text"
printf '%s\n' "$snapshot_text" | sed -n '3p' | grep -q '^\[ios\]\[timing\] test cacheStatus=hit totalMs=6500 bootMs=250 buildForTestingMs=0 testInvocationMs=6000 testBodyMs=2000 xcresultSessionMs=3500 appLaunchAverageMs=1450 appLaunchSamples=5 invocationOverheadMs=2500' \
  && ok "snapshot text prints test timing line" || fail_t "snapshot text missing test timing line: $snapshot_text"
printf '%s\n' "$snapshot_text" | sed -n '4p' | grep -q '^\[ios\]\[timing\] archive totalMs=13510 lockWaitMs=10 archiveMs=12000 exportMs=1500 uploadMs=0' \
  && ok "snapshot text prints archive timing line" || fail_t "snapshot text missing archive timing line: $snapshot_text"
printf '%s\n' "$snapshot_text" | sed -n '5p' | grep -q '^\[ios\]\[timing\] simulator totalMs=n/a simctlDevicesMs=n/a appContainerMs=n/a appProcessMs=n/a' \
  && ok "snapshot text prints simulator timing line when simulator is skipped" || fail_t "snapshot text missing simulator timing line: $snapshot_text"
echo "$snapshot_text" | grep -q '\[ios\]\[next\].*source=runs.build.diagnostics.*severity=warn.*category=storekit' \
  && ok "snapshot text lists next actions" || fail_t "snapshot text missing next action: $snapshot_text"
echo "$snapshot_text" | grep -q '\[ios\]\[next\].*source=gate.*severity=manual.*key=submit' \
  && ok "snapshot text surfaces manual workflow action" || fail_t "snapshot text missing manual action: $snapshot_text"
echo "$snapshot_text" | grep -q '\[ios\]\[snapshot\] sentry sourceExists=true canImportGuard=true dsnKeyReference=true' \
  && ok "snapshot text reports sentry wiring summary" || fail_t "snapshot text missing sentry summary: $snapshot_text"
echo "$snapshot_text" | grep -q 'phase=doctor' \
  && fail_t "snapshot text should not start with phase dump: $snapshot_text" || ok "snapshot text avoids phase dump"
rm -rf "$runs_parent"
bad_args_tmp="$(mktemp -d)"
if KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" doctor --json garbage >"$bad_args_tmp/out" 2>"$bad_args_tmp/err"; then
  fail_t "doctor --json rejects unknown trailing args"
else
  grep -q 'unknown doctor option' "$bad_args_tmp/err" \
    && ok "doctor --json rejects unknown trailing args" || fail_t "doctor --json bad-arg message missing"
fi
rm -rf "$bad_args_tmp"
bad_snapshot_tmp="$(mktemp -d)"
if KG_IOS_OPS_FIXTURE=1 bash "$IOS_OPS" snapshot --json --log-limit nope >"$bad_snapshot_tmp/out" 2>"$bad_snapshot_tmp/err"; then
  fail_t "snapshot rejects non-numeric log limit"
else
  grep -q -- '--log-limit must be' "$bad_snapshot_tmp/err" \
    && ok "snapshot rejects non-numeric log limit" || fail_t "snapshot bad-log-limit message missing"
fi
if KG_IOS_OPS_FIXTURE=1 KG_IOS_OPS_LOG_FAIL_FIXTURE=1 bash "$IOS_OPS" snapshot --json --include-logs --log-since 1m >"$bad_snapshot_tmp/log_out" 2>"$bad_snapshot_tmp/log_err"; then
  fail_t "snapshot --include-logs propagates log failure"
else
  rc=$?
  grep -q 'fixture log failure' "$bad_snapshot_tmp/log_err" && [[ "$rc" -eq 42 ]] \
    && ok "snapshot --include-logs propagates log failure" || fail_t "snapshot include-logs failure stderr missing"
fi
rm -rf "$bad_snapshot_tmp"

section "Archive fixture"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/2026-06-07/BooksAndVocab 2026-6-7, 1.00 PM.xcarchive"
mkdir -p "$archive"
cat > "$archive/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Name</key><string>BooksAndVocab</string>
  <key>CreationDate</key><date>2026-06-07T05:00:00Z</date>
  <key>ApplicationProperties</key>
  <dict>
    <key>CFBundleIdentifier</key><string>com.Max0228.BooksBrowser</string>
    <key>CFBundleShortVersionString</key><string>1.6</string>
    <key>CFBundleVersion</key><string>4</string>
  </dict>
</dict>
</plist>
PLIST
list_out="$(bash "$IOS_ARCHIVE" list --root "$tmp")"
echo "$list_out" | grep -q $'1.6\t4' && ok "archive list includes version/build" || fail_t "archive list missing version/build: $list_out"
json_out="$(bash "$IOS_ARCHIVE" latest --root "$tmp" --json)"
echo "$json_out" | grep -q '"version":"1.6"' && ok "archive latest --json includes version" || fail_t "archive json missing version"
echo "$json_out" | grep -q '"build":"4"' && ok "archive latest --json includes build" || fail_t "archive json missing build"

section "ios_build emits diagnostics"
lock_heartbeat_probe="$(
  bash -c '
    set -euo pipefail
    source "'"$IOS_LOCK_WAIT_LIB"'"
    previous=0
    for elapsed in 3 6 9 12 15 18 21 24 27 30 33; do
      kg_ios_lock_wait_heartbeat "[probe]" build "$elapsed" "$previous" "$$"
      previous="$elapsed"
    done
  '
)"
[[ "$(printf '%s\n' "$lock_heartbeat_probe" | wc -l | tr -d ' ')" == "2" ]] \
  && [[ "$(sed -n '1p' <<<"$lock_heartbeat_probe")" =~ ^\[probe\]\ phase=lock-wait\ kind=build\ elapsed=15s\ pid=[0-9]+\ alive=true\ holderPid=[0-9]+\ holderAlive=true$ ]] \
  && [[ "$(sed -n '2p' <<<"$lock_heartbeat_probe")" =~ ^\[probe\]\ phase=lock-wait\ kind=build\ elapsed=30s\ pid=[0-9]+\ alive=true\ holderPid=[0-9]+\ holderAlive=true$ ]] \
  && ok "iOS lock wait heartbeat emits only at 15s cadence inside the 20s ceiling" \
  || fail_t "iOS lock wait heartbeat boundary/provenance wrong: $lock_heartbeat_probe"
lock_wait_fixture="$(
  bash -c '
    set -euo pipefail
    source "'"$IOS_LOCK_WAIT_LIB"'"
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    sleep() { :; }
    for spec in "[ios_build]|build" "[ios_test]|build" "[ios_test]|device" "[release]|archive"; do
      prefix="${spec%%|*}"; kind="${spec#*|}"; attempts=0; lock="$tmp/$kind-${RANDOM}.lock"
      shlock() {
        attempts=$((attempts + 1))
        if (( attempts <= 11 )); then printf "%s\n" "$$" >"$lock"; return 1; fi
        printf "%s\n" "$4" >"$lock"; return 0
      }
      kg_ios_wait_for_shlock "$prefix" "$kind" "$lock" "$$" 60 3
      printf "ACQUIRED kind=%s attempts=%s waited=%s\n" "$kind" "$attempts" "$KG_IOS_LOCK_WAIT_SECONDS"
    done
  '
)"
for fixture_kind in build device archive; do
  grep -qE "phase=lock-wait kind=${fixture_kind} elapsed=15s .*holderAlive=true" <<<"$lock_wait_fixture" \
    && grep -qE "phase=lock-wait kind=${fixture_kind} elapsed=30s .*holderAlive=true" <<<"$lock_wait_fixture" \
    && ok "held ${fixture_kind} lock emits 15s/30s heartbeats" \
    || fail_t "held ${fixture_kind} lock heartbeat missing: $lock_wait_fixture"
done
[[ "$(grep -c '^ACQUIRED ' <<<"$lock_wait_fixture")" -eq 4 ]] \
  && [[ "$(grep -c 'elapsed=33s' <<<"$lock_wait_fixture")" -eq 0 ]] \
  && ok "all four wait paths acquire after heartbeats and stop emitting" \
  || fail_t "held-lock fixture acquire/stop contract wrong: $lock_wait_fixture"
lock_holder_edge_probe="$(
  bash -c '
    set -euo pipefail
    source "'"$IOS_LOCK_WAIT_LIB"'"
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    sleep() { :; }
    for holder in 999999999 invalid-pid; do
      attempts=0; lock="$tmp/$holder.lock"
      shlock() {
        attempts=$((attempts + 1))
        if (( attempts == 1 )); then printf "%s\n" "$holder" >"$lock"; return 1; fi
        printf "%s\n" "$4" >"$lock"; return 0
      }
      kg_ios_wait_for_shlock "[edge]" build "$lock" "$$" 6 3
      printf "EDGE holder=%s attempts=%s owner=%s\n" "$holder" "$attempts" "$(cat "$lock")"
    done
  '
)"
[[ "$(grep -c 'stale lock kind=build .*alive=false; stealing' <<<"$lock_holder_edge_probe")" -eq 2 ]] \
  && [[ "$(grep -c '^EDGE .* attempts=2 owner=[0-9]' <<<"$lock_holder_edge_probe")" -eq 2 ]] \
  && ok "dead and invalid holder locks are stolen, then acquired by the waiter" \
  || fail_t "dead/invalid holder behavior regressed: $lock_holder_edge_probe"
lock_timeout_probe="$(
  bash -c '
    set -euo pipefail
    source "'"$IOS_LOCK_WAIT_LIB"'"
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    sleep() { :; }
    for mode in pre-sleep post-sleep; do
      attempts=0; lock="$tmp/$mode.lock"
      shlock() {
        attempts=$((attempts + 1))
        if (( attempts < 3 )); then printf "%s\n" "$$" >"$lock"; return 1; fi
        printf "%s\n" "$4" >"$lock"; return 0
      }
      rc=0
      kg_ios_wait_for_shlock "[timeout]" build "$lock" "$$" 6 3 "$mode" || rc=$?
      printf "TIMEOUT mode=%s rc=%s attempts=%s\n" "$mode" "$rc" "$attempts"
    done
  '
)"
grep -q '^TIMEOUT mode=pre-sleep rc=0 attempts=3$' <<<"$lock_timeout_probe" \
  && grep -q '^TIMEOUT mode=post-sleep rc=1 attempts=2$' <<<"$lock_timeout_probe" \
  && ok "build/release and test preserve their original timeout boundary semantics" \
  || fail_t "lock timeout boundary semantics drifted: $lock_timeout_probe"
grep -Fq 'kg_ios_wait_for_shlock "[ios_build]" build "$LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL"' "$WORKSPACE/ops/ios_build.sh" \
  && grep -Fq 'POLL_INTERVAL=3' "$WORKSPACE/ops/ios_build.sh" \
  && ! grep -Fq 'kg_ios_wait_for_shlock "[ios_build]" build "$LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL" post-sleep' "$WORKSPACE/ops/ios_build.sh" \
  && grep -Fq 'kg_ios_wait_for_shlock "[ios_test]" build "$LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL" post-sleep' "$WORKSPACE/ops/ios_test.sh" \
  && grep -Fq 'kg_ios_wait_for_shlock "[ios_test]" device "$TEST_DEVICE_LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL" post-sleep' "$WORKSPACE/ops/ios_test.sh" \
  && grep -Fq 'POLL_INTERVAL=3' "$WORKSPACE/ops/ios_test.sh" \
  && grep -Fq 'kg_ios_wait_for_shlock "[release]" archive "$LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL"' "$WORKSPACE/ops/ios_release.sh" \
  && grep -Fq 'POLL_INTERVAL=3' "$WORKSPACE/ops/ios_release.sh" \
  && ! grep -Fq 'kg_ios_wait_for_shlock "[release]" archive "$LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL" post-sleep' "$WORKSPACE/ops/ios_release.sh" \
  && ok "all four lock callers pin owner, timeout, 3s poll, and timeout mode" \
  || fail_t "iOS lock caller signature drifted (build/archive pre-sleep; test build/device post-sleep)"
grep -q 'ios_diagnostics.py' "$WORKSPACE/ops/ios_build.sh" \
  && ok "ios_build calls diagnostics parser" || fail_t "ios_build missing diagnostics parser"
grep -q 'kg_ios_build.*log' "$WORKSPACE/ops/ios_build.sh" \
  && ok "ios_build preserves raw log path" || fail_t "ios_build does not preserve log path"
grep -q 'VERDICT_JSON_FILE' "$WORKSPACE/ops/ios_build.sh" \
  && ok "ios_build writes JSON verdict" || fail_t "ios_build missing JSON verdict"
grep -q -- '-resultBundlePath' "$WORKSPACE/ops/ios_build.sh" \
  && ok "ios_build emits xcresult bundle" || fail_t "ios_build missing -resultBundlePath"
grep -q -- '--xcresult' "$WORKSPACE/ops/ios_build.sh" \
  && ok "ios_build feeds xcresult to diagnostics" || fail_t "ios_build does not feed xcresult to diagnostics"
grep -q 'simulator ensure-booted' "$WORKSPACE/ops/ios_build.sh" \
  && ok "ios_build warms simulator before xcodebuild when targeting simulator" || fail_t "ios_build missing simulator preboot"
grep -q 'lockWaitMs:' "$WORKSPACE/ops/ios_build.sh" \
  && grep -q 'bootMs:' "$WORKSPACE/ops/ios_build.sh" \
  && grep -q 'xcodebuildMs:' "$WORKSPACE/ops/ios_build.sh" \
  && grep -q 'totalMs:' "$WORKSPACE/ops/ios_build.sh" \
  && ok "ios_build verdict records timing breakdown (incl lock wait)" || fail_t "ios_build verdict missing timing fields"
grep -qE 'lockWaitMs=\$LOCK_WAIT_MS' "$WORKSPACE/ops/ios_build.sh" \
  && ok "ios_build surfaces lock wait time on stdout" || fail_t "ios_build does not surface lock wait on stdout"
monitor_probe="$(
  perl -e 'alarm 5; exec @ARGV' bash -lc '
    source "'"$WORKSPACE"'/ops/lib/ios_build_progress.sh"
    log="$(mktemp "${TMPDIR:-/tmp}/kg_ios_monitor_probe.XXXXXX.log")"
    baseline="$(mktemp "${TMPDIR:-/tmp}/kg_ios_monitor_probe.XXXXXX.baseline")"
    pid="$(start_build_monitor "$log" "$baseline" "[probe]" "$(date +%s)")"
    printf "pid=%s\n" "$pid"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  ' 2>/dev/null
)"
echo "$monitor_probe" | grep -qE '^pid=[0-9]+$' \
  && ok "ios_build progress monitor returns PID from command substitution" || fail_t "ios_build progress monitor command substitution hung/failed: $monitor_probe"

section "ios_test emits xcresult-first diagnostics"
grep -q -- '--configuration) CONFIGURATION=' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q -- '-configuration "$CONFIGURATION"' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q -- '--arg evidenceProducer "ops/ios_test.sh"' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'evidenceProducer:\$evidenceProducer' "$WORKSPACE/ops/ios_test.sh" \
  && grep -qE '^ios_test_sdk_suffix\(\)' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'os_name="iOS"' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'testLiveDemoAccountHasProEntitlement' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test owns Release configuration and App Review provenance" || fail_t "ios_test lacks producer-owned Release provenance"
grep -q -- '-resultBundlePath' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test emits xcresult bundle" || fail_t "ios_test missing -resultBundlePath"
grep -q 'simulator ensure-booted' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test warms simulator before xcodebuild" || fail_t "ios_test missing simulator preboot"
grep -q -- '--kind test' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test reads xcresult test-results" || fail_t "ios_test missing --kind test diagnostics"
grep -q 'count_executed_tests_xcresult' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test counts executed tests from xcresult first" || fail_t "ios_test missing xcresult executed-count path"
grep -q 'effectiveTests' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test treats skipped-only xcresult summaries as non-executed" || fail_t "ios_test still counts skipped-only summaries as executed"
grep -q "head -20 || true" "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test failure summary cannot abort verdict writing" || fail_t "ios_test failure summary can abort before verdict"
grep -q 'emit_ui_runner_lifecycle' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q '\[ios_test\]\[ui-lifecycle\]' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'screenshot=' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test emits UI runner lifecycle diagnostics on abnormal UI outcomes" || fail_t "ios_test missing UI runner lifecycle diagnostics"
grep -q 'KG_UI_TEST_SCREENSHOT_DIR' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'uitest_contact_sheet.py' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test captures UI step screenshots into a contact sheet" || fail_t "ios_test missing UI step contact sheet capture"
grep -q '^stage_ui_runner_process_environment()' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'EnvironmentVariables' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'KG_UI_TEST_SCREENSHOT_DIR' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test stages P9 screenshot context into the runner process environment" \
  || fail_t "ios_test does not stage P9 screenshot context into the runner process environment"
[[ "$(grep -c '^stage_ui_evidence_runner_environment()' "$WORKSPACE/ops/ios_test.sh")" -eq 1 ]] \
  && grep -q 'verdict_file="\${KG_IOS_VERDICT_FILE:-\${VERDICT_FILE:-}}"' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'KG_IOS_VERDICT_FILE "\$verdict_file"' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test injects the pinned verdict path into UI test runners" \
  || fail_t "ios_test UI evidence runner cannot bind its pre-run verdict context"
grep -q 'xcresulttool' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'export attachments' "$WORKSPACE/ops/ios_test.sh" \
  && grep -Fq 'Step ([0-9]{2}-' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test falls back to xcresult step attachments" || fail_t "ios_test missing xcresult step attachment fallback"
prepare_def_line="$(grep -n '^prepare_ui_step_screenshot_dir()' "$WORKSPACE/ops/ios_test.sh" | cut -d: -f1 | head -1)"
prepare_call_line="$(grep -n '^[[:space:]]*prepare_ui_step_screenshot_dir$' "$WORKSPACE/ops/ios_test.sh" | cut -d: -f1 | head -1)"
[[ -n "$prepare_def_line" && -n "$prepare_call_line" && "$prepare_def_line" -lt "$prepare_call_line" ]] \
  && ok "ios_test defines UI step helper before first use" || fail_t "ios_test UI step helper order invalid"
grep -q 'test-without-building' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'build-for-testing' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test supports cache-first xctestrun reuse path" || fail_t "ios_test missing reuse-build path"
grep -q 'ensure_xctestrun_ready_or_fail' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test guards missing xctestrun artifacts before test-without-building" || fail_t "ios_test missing xctestrun readiness guard"
# App-written P9/Reader evidence needs a run-scoped screenshot directory even
# when the caller did not request visual review artifacts.  Keep this executable
# regression fixture so the runner contract cannot regress to visual-only setup.
nonvisual_evidence_tmp="$(mktemp -d)"
if bash -c '
  set -euo pipefail
  SCRIPT_DIR="'"$WORKSPACE"'/ops"
  TEST_SCOPE="ui"
  VISUAL_CAPTURE_ENABLED=0
  UI_TEST_SCREENSHOT_DIR=""
  UI_TEST_CONTACT_SHEET=""
  UI_TEST_QUICK4_SHEET=""
  UI_TEST_SCREENSHOT_MANIFEST=""
  UI_TEST_VIDEO=""
  UI_TEST_VIDEO_FILE=""
  UI_TEST_VIDEO_SHA256=""
  artifact_temp_dir() {
    mkdir -p "'"$nonvisual_evidence_tmp"'/artifact"
    printf "%s\n" "'"$nonvisual_evidence_tmp"'/artifact"
  }
  eval "$(sed -n "/^prepare_ui_step_screenshot_dir()/,/^}/p" "$SCRIPT_DIR/ios_test.sh")"
  prepare_ui_step_screenshot_dir
  [[ -n "$UI_TEST_SCREENSHOT_DIR" && -d "$UI_TEST_SCREENSHOT_DIR" ]]
'; then
  ok "ios_test allocates UI evidence directory without visual capture"
else
  fail_t "ios_test does not allocate UI evidence directory for nonvisual UI runs"
fi

nonvisual_stage_log="$nonvisual_evidence_tmp/stage.log"
if bash -c '
  set -euo pipefail
  SCRIPT_DIR="'"$WORKSPACE"'/ops"
  PROJECT_ROOT="'"$nonvisual_evidence_tmp"'/project"
  TEST_SCOPE="ui"
  VISUAL_CAPTURE_ENABLED=0
  UI_TEST_SCREENSHOT_DIR="'"$nonvisual_evidence_tmp"'/artifact"
  KG_IOS_VERDICT_FILE="'"$nonvisual_evidence_tmp"'/verdict.json"
  VERDICT_FILE="$KG_IOS_VERDICT_FILE"
  EVIDENCE_DATASET_ID="fixture-dataset"
  EVIDENCE_DATASET_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  mkdir -p "$PROJECT_ROOT" "$UI_TEST_SCREENSHOT_DIR"
  : > "'"$nonvisual_evidence_tmp"'/staged.xctestrun"
  git() { printf "%s\n" "fixture-source-commit"; }
  resolve_run_device_udid() { printf "%s\n" "fixture-device-udid"; }
  ios_xctestrun_cache_upsert_env_all_targets() {
    printf "%s=%s\n" "$2" "$3" >> "'"$nonvisual_stage_log"'"
  }
  stage_ui_runner_process_environment() { :; }
  eval "$(sed -n "/^stage_ui_evidence_runner_environment()/,/^}/p" "$SCRIPT_DIR/ios_test.sh")"
  stage_ui_evidence_runner_environment "'"$nonvisual_evidence_tmp"'/staged.xctestrun"
  grep -q '^KG_UI_TEST_SCREENSHOT_DIR=' "'"$nonvisual_stage_log"'"
'; then
  ok "ios_test stages nonvisual UI screenshot context into xctestrun"
else
  fail_t "ios_test does not stage nonvisual UI screenshot context"
fi
nonvisual_review_tmp="$nonvisual_evidence_tmp/review"
mkdir -p "$nonvisual_review_tmp"
printf 'fixture' >"$nonvisual_review_tmp/01-step.png"
if bash -c '
  set -euo pipefail
  SCRIPT_DIR="'"$WORKSPACE"'/ops"
  TEST_SCOPE="ui"
  VISUAL_CAPTURE_ENABLED=0
  UI_TEST_SCREENSHOT_DIR="'"$nonvisual_review_tmp"'"
  UI_TEST_CONTACT_SHEET=""
  UI_TEST_QUICK4_SHEET=""
  UI_TEST_SCREENSHOT_MANIFEST=""
  eval "$(sed -n "/^build_ui_step_contact_sheet()/,/^}/p" "$SCRIPT_DIR/ios_test.sh")"
  build_ui_step_contact_sheet
  [[ ! -e "'"$nonvisual_review_tmp"'/contact_sheet.png" ]]
'; then
  ok "ios_test keeps contact-sheet generation visual-only"
else
  fail_t "ios_test generated visual review output for a nonvisual UI run"
fi
rm -rf "$nonvisual_evidence_tmp"
# Functional regression: fake UI step screenshots must yield the full visual
# review trio — full contact sheet + quick4 sheet + selection manifest — and
# generated sheets must never re-enter the manifest as fake steps.
ui_steps_tmp="$(mktemp -d)"
ui_step_png_b64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
for ui_step_name in 01-launch 02-bookshelf 03-series-detail 04-episode-list 05-player-open 06-play-tapped 07-playback-started 08-playback-sustained; do
  printf '%s' "$ui_step_png_b64" | base64 -d >"$ui_steps_tmp/$ui_step_name.png"
done
bash -c '
  set -euo pipefail
  SCRIPT_DIR="'"$WORKSPACE"'/ops"
  PROJECT_ROOT="'"$ui_steps_tmp"'/project"
  TEST_SCOPE="ui"
  UI_TEST_SCREENSHOT_DIR="'"$ui_steps_tmp"'"
  UI_TEST_CONTACT_SHEET=""
  UI_TEST_QUICK4_SHEET=""
  UI_TEST_SCREENSHOT_MANIFEST=""
  UI_TEST_VIDEO=""
  UI_TEST_REVIEW_ROOT=""
  UI_TEST_REVIEW_HTML=""
  VISUAL_CAPTURE_ENABLED=1
  KG_IOS_VISUAL_ROOT="'"$ui_steps_tmp"'/project/run-bundles"
  UI_TEST_RUN_ID="fixture-run-$$"
  EVIDENCE_DATASET_ID="fixture-dataset"
  EVIDENCE_DATASET_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  UI_TEST_FLOW_ID="PodcastPlaybackPerfUITests"
  UI_TEST_VARIANT_ID="profile:ui-smoke"
  FILE_PATH="ios/BooksAndVocabUITests/PodcastPlaybackPerfUITests.swift"
  TMPOUT="'"$ui_steps_tmp"'/test.log"
  : > "$TMPOUT"
  export_ui_step_attachments_from_xcresult() { :; }
  eval "$(sed -n "/^build_ui_step_contact_sheet()/,/^}/p" "$SCRIPT_DIR/ios_test.sh")"
  eval "$(sed -n "/^build_ui_test_review_page()/,/^}/p" "$SCRIPT_DIR/ios_test.sh")"
  resolve_run_device_udid() { printf "STUB-UDID-1234"; }
  build_ui_step_contact_sheet
  build_ui_test_review_page
' >"$ui_steps_tmp/snippet.log" 2>&1 || true
ui_steps_review_html=""
if [[ -d "$ui_steps_tmp/project/run-bundles/review" ]]; then
  ui_steps_review_html="$(find "$ui_steps_tmp/project/run-bundles/review" -name UIreview.html -type f | head -1)"
fi
if [[ -s "$ui_steps_tmp/contact_sheet.png" && -s "$ui_steps_tmp/quick4_contact_sheet.png" && -s "$ui_steps_tmp/review_manifest.json" ]] \
  && [[ -n "$ui_steps_review_html" && -s "$ui_steps_review_html" ]] \
  && jq -e '.schema=="kg.visual-review.sheet.v1" and (.items|length)==8 and all(.items[]; (.relPath|test("contact_sheet"))|not)' "$ui_steps_tmp/review_manifest.json" >/dev/null \
  && [[ ! -e "$ui_steps_tmp/project/run-bundles/review/index.json" && ! -e "$ui_steps_tmp/project/run-bundles/review/UIreview.html" ]]; then
  ok "ios_test builds full + quick4 contact sheets, manifest, and one run-scoped UIreview"
  rm -rf "$ui_steps_tmp"
else
  # keep $ui_steps_tmp as the debug artifact — the failure message points at it
  fail_t "ios_test ui-step visual review artifacts missing in $ui_steps_tmp: $(tail -3 "$ui_steps_tmp/snippet.log" 2>/dev/null | tr '\n' ' ')"
fi
ui_empty_tmp="$(mktemp -d)"
bash -c '
  set -euo pipefail
  SCRIPT_DIR="'"$WORKSPACE"'/ops"
  PROJECT_ROOT="'"$ui_empty_tmp"'/project"
  TEST_SCOPE="ui"
  UI_TEST_SCREENSHOT_DIR=""
  UI_TEST_CONTACT_SHEET=""
  UI_TEST_QUICK4_SHEET=""
  UI_TEST_SCREENSHOT_MANIFEST=""
  UI_TEST_VIDEO=""
  UI_TEST_REVIEW_ROOT=""
  UI_TEST_REVIEW_HTML=""
  VISUAL_CAPTURE_ENABLED=1
  KG_IOS_VISUAL_ROOT="'"$ui_empty_tmp"'/project/run-bundles"
  UI_TEST_RUN_ID="empty-fixture-run-$$"
  UI_TEST_FLOW_ID="BooksAndVocabUITests"
  UI_TEST_VARIANT_ID="profile:ui-smoke"
  FILE_PATH="ios/BooksAndVocabUITests/BooksAndVocabUITests.swift"
  TMPOUT="'"$ui_empty_tmp"'/test.log"
  mkdir -p "$PROJECT_ROOT"
  : > "$TMPOUT"
  eval "$(sed -n "/^build_ui_test_review_page()/,/^}/p" "$SCRIPT_DIR/ios_test.sh")"
  artifact_temp_dir() { mktemp -d "${TMPDIR:-/tmp}/kg-ios-test-artifact.XXXXXX"; }
  resolve_run_device_udid() { printf "STUB-UDID-EMPTY"; }
  build_ui_test_review_page ok
' >"$ui_empty_tmp/snippet.log" 2>&1 || true
ui_empty_runs_root="$ui_empty_tmp/project/run-bundles/review"
if grep -qF '[ios_test][ui-review] warning: failed to build standalone UIreview' "$ui_empty_tmp/snippet.log" \
  && ! compgen -G "$ui_empty_runs_root/empty-fixture-run-*" >/dev/null \
  && [[ ! -e "$ui_empty_runs_root/index.json" && ! -e "$ui_empty_runs_root/UIreview.html" ]]; then
  ok "ios_test rejects empty visual review without publishing a ghost run"
  rm -rf "$ui_empty_tmp"
else
  fail_t "ios_test empty visual review did not fail closed in $ui_empty_tmp: $(tail -5 "$ui_empty_tmp/snippet.log" 2>/dev/null | tr '\n' ' ')"
fi
ios_test_xctestrun_tmp="$(mktemp -d)"
mkdir -p "$ios_test_xctestrun_tmp/Build/Products"
touch "$ios_test_xctestrun_tmp/Build/Products/BooksAndVocabUnitTests_BooksAndVocabUnitTests_iphonesimulator26.4-arm64.xctestrun"
touch "$ios_test_xctestrun_tmp/Build/Products/BooksAndVocabUnitTests_BooksAndVocabUnitTests_iphonesimulator26.4-arm64.scoped.xctestrun"
ios_test_xctestrun_path="$(
  bash -lc '
    eval "$(sed -n '"'"'/^ios_test_find_xctestrun()/,/^}/p'"'"' "'"$WORKSPACE/ops/ios_test.sh"'")"
    ios_test_find_xctestrun "'"$ios_test_xctestrun_tmp"'"
  '
)"
[[ "$ios_test_xctestrun_path" == *.xctestrun && "$ios_test_xctestrun_path" != *.scoped.xctestrun ]] \
  && ok "ios_test xctestrun lookup prefers base artifact over scoped copy" || fail_t "ios_test xctestrun lookup selected wrong artifact: $ios_test_xctestrun_path"
rm -rf "$ios_test_xctestrun_tmp"
grep -q 'BooksAndVocabUnitTests' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test uses unit-only scheme for default scope" || fail_t "ios_test missing unit-only scheme"
grep -q 'lockWaitMs:' "$WORKSPACE/ops/ios_test.sh" \
  && grep -qE 'lockWaitMs=\$LOCK_WAIT_MS' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test verdict records lock wait time and surfaces it on stdout" || fail_t "ios_test missing lock wait timing"
grep -q 'BooksAndVocabUITests' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test uses dedicated UI scheme for UI scope" || fail_t "ios_test missing UI-only scheme"
grep -q 'deviceRunLockWaitMs:' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'acquire_test_device_lock' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test records per-device execution lock timing" || fail_t "ios_test missing per-device execution lock timing"
grep -q 'UI_TEST_VIDEO_LOCK_FILE="/tmp/kg-ios-ui-video.lock"' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q "kg_ios_wait_for_shlock \"\[ios_test\]\" \"ui-video\"" "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test serializes the host-level Simulator video recorder" \
  || fail_t "ios_test missing host-level video recorder lock"
grep -q "grep -q 'Recording started'" "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'recording started udid=' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test fail-closes before UI execution unless video recording starts" \
  || fail_t "ios_test does not verify video recorder startup"
grep -q 'stop_ui_test_recording || true' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test cleanup finalizes and releases video recording" \
  || fail_t "ios_test cleanup does not finalize video recording"
ios_test_isolation_required="$(
  PROJECT_ROOT="/tmp/.codex/worktrees/91de/kg" \
  DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro Max" \
  DEVICE_OVERRIDE="" \
  DESTINATION_OVERRIDE="" \
  AUTO_LEASE=0 \
  LIST_ONLY=0 \
  TEST_CACHE_ACTION="" \
  KG_IOS_TEST_ALLOW_SHARED_SIM=0 \
  CI="" \
  WORKTREE_BRANCH="" \
    bash -lc '
      eval "$(sed -n "/^destination_requires_device_lock()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      eval "$(sed -n "/^env_flag_enabled()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      eval "$(sed -n "/^running_in_isolation_enforced_context()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      eval "$(sed -n "/^should_require_isolated_simulator()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      if should_require_isolated_simulator; then echo require; else echo allow; fi
    '
)"
[[ "$ios_test_isolation_required" == "require" ]] \
  && ok "ios_test requires --lease/--device in agent worktree context" || fail_t "ios_test did not require isolated simulator in agent context: $ios_test_isolation_required"
ios_test_isolation_autolease="$(
  PROJECT_ROOT="/tmp/.codex/worktrees/91de/kg" \
  DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro Max" \
  DEVICE_OVERRIDE="" \
  DESTINATION_OVERRIDE="" \
  AUTO_LEASE=1 \
  LIST_ONLY=0 \
  TEST_CACHE_ACTION="" \
  KG_IOS_TEST_ALLOW_SHARED_SIM=0 \
  CI="" \
  WORKTREE_BRANCH="" \
    bash -lc '
      eval "$(sed -n "/^destination_requires_device_lock()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      eval "$(sed -n "/^env_flag_enabled()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      eval "$(sed -n "/^running_in_isolation_enforced_context()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      eval "$(sed -n "/^should_require_isolated_simulator()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      if should_require_isolated_simulator; then echo require; else echo allow; fi
    '
)"
[[ "$ios_test_isolation_autolease" == "allow" ]] \
  && ok "ios_test skips isolation guard when auto-lease is enabled" || fail_t "ios_test isolation guard ignored auto-lease: $ios_test_isolation_autolease"
ios_test_isolation_override="$(
  PROJECT_ROOT="/tmp/.codex/worktrees/91de/kg" \
  DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro Max" \
  DEVICE_OVERRIDE="" \
  DESTINATION_OVERRIDE="" \
  AUTO_LEASE=0 \
  LIST_ONLY=0 \
  TEST_CACHE_ACTION="" \
  KG_IOS_TEST_ALLOW_SHARED_SIM=1 \
  CI="" \
  WORKTREE_BRANCH="" \
    bash -lc '
      eval "$(sed -n "/^destination_requires_device_lock()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      eval "$(sed -n "/^env_flag_enabled()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      eval "$(sed -n "/^running_in_isolation_enforced_context()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      eval "$(sed -n "/^should_require_isolated_simulator()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      if should_require_isolated_simulator; then echo require; else echo allow; fi
    '
)"
[[ "$ios_test_isolation_override" == "allow" ]] \
  && ok "ios_test allows explicit shared-simulator override" || fail_t "ios_test isolation guard ignored override: $ios_test_isolation_override"
grep -q -- '--ui-launch-profile' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q -- '--launch-benchmark' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'KG_UI_TEST_APP_ARGS_JSON' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test can inject UI app launch profiles into XCUIApplication" || fail_t "ios_test missing UI launch-profile injection"
variant_combo="$(
  bash -c '
    set -euo pipefail
    eval "$(sed -n "/^build_ui_test_variant_id()/,/^}/p" "$1")"
    UI_FIXTURE_DATASET_NAME="marketing_demo"
    UI_FIXTURE_DATASET_FILE=""
    UI_LAUNCH_PROFILE="standard"
    build_ui_test_variant_id
  ' _ "$WORKSPACE/ops/ios_test.sh"
)"
[[ "$variant_combo" == "dataset:marketing_demo+profile:standard" ]] \
  && ok "ios_test variant id combines dataset and launch profile" \
  || fail_t "ios_test combined variant id wrong: $variant_combo"
variant_profile="$(
  bash -c '
    set -euo pipefail
    eval "$(sed -n "/^build_ui_test_variant_id()/,/^}/p" "$1")"
    UI_FIXTURE_DATASET_NAME=""
    UI_FIXTURE_DATASET_FILE=""
    UI_LAUNCH_PROFILE="ui-smoke"
    build_ui_test_variant_id
  ' _ "$WORKSPACE/ops/ios_test.sh"
)"
[[ "$variant_profile" == "profile:ui-smoke" ]] \
  && ok "ios_test variant id records launch profile state" \
  || fail_t "ios_test profile variant id wrong: $variant_profile"

section "ios_test carries resolved simulator UDID into evidence"
ios_udid_tmp="$(mktemp -d)"
cat >"$ios_udid_tmp/fake-ios-ops.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"schema":"kg.ios.simulator.v1","action":"ensure-booted","status":"ok","selector":"iPhone 17 Pro Max","device":{"udid":"fixture-iphone-17-pro-max","state":"Booted"},"boot":{"status":"ok","exitCode":0,"wasAlreadyBooted":false,"waitedForBootstatus":true},"timings":{"totalMs":1,"resolveMs":1,"bootMs":0,"bootstatusMs":0},"errors":[]}
JSON
EOF
chmod +x "$ios_udid_tmp/fake-ios-ops.sh"
ios_udid_log="$ios_udid_tmp/snippet.log"
if bash -c '
  set -euo pipefail
  script="$1"
  IOS_OPS="$2"
  SIMULATOR_BOOT_SELECTOR="iPhone 17 Pro Max"
  JSON_MODE=0
  BOOT_MS=0
  RESOLVED_DEVICE_UDID=""
  ios_test_now_ms() { printf "100\n"; }
  eval "$(sed -n "/^boot_simulator_if_needed()/,/^}/p" "$script")"
  eval "$(sed -n "/^resolve_run_device_udid()/,/^}/p" "$script")"
  boot_simulator_if_needed
  [[ "$RESOLVED_DEVICE_UDID" == "fixture-iphone-17-pro-max" ]]
  [[ "$(resolve_run_device_udid)" == "fixture-iphone-17-pro-max" ]]
' _ "$WORKSPACE/ops/ios_test.sh" "$ios_udid_tmp/fake-ios-ops.sh" >"$ios_udid_log" 2>&1; then
  ok "ios_test carries ensure-booted UDID into UI evidence resolution"
else
  fail_t "ios_test lost ensure-booted UDID before evidence stage: $(tail -5 "$ios_udid_log" | tr "\n" " ")"
fi
cat >"$ios_udid_tmp/fake-ios-ops-missing-udid.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"schema":"kg.ios.simulator.v1","action":"ensure-booted","status":"ok","selector":"iPhone 17 Pro Max","device":{"udid":null,"state":"Booted"},"boot":{"status":"ok","exitCode":0,"wasAlreadyBooted":true,"waitedForBootstatus":true},"timings":{"totalMs":1,"resolveMs":1,"bootMs":0,"bootstatusMs":0},"errors":[]}
JSON
EOF
chmod +x "$ios_udid_tmp/fake-ios-ops-missing-udid.sh"
ios_udid_invalid_log="$ios_udid_tmp/invalid-snippet.log"
if bash -c '
  set -euo pipefail
  script="$1"
  IOS_OPS="$2"
  SIMULATOR_BOOT_SELECTOR="iPhone 17 Pro Max"
  JSON_MODE=0
  BOOT_MS=0
  RESOLVED_DEVICE_UDID=""
  ios_test_now_ms() { printf "100\n"; }
  eval "$(sed -n "/^boot_simulator_if_needed()/,/^}/p" "$script")"
  if boot_simulator_if_needed; then
    exit 1
  fi
  [[ -z "$RESOLVED_DEVICE_UDID" ]]
' _ "$WORKSPACE/ops/ios_test.sh" "$ios_udid_tmp/fake-ios-ops-missing-udid.sh" >"$ios_udid_invalid_log" 2>&1; then
  ok "ios_test rejects an ensure-booted payload without a usable UDID"
  rm -rf "$ios_udid_tmp"
else
  fail_t "ios_test accepted an unusable ensure-booted payload: $(tail -5 "$ios_udid_invalid_log" | tr "\n" " ")"
fi

section "ios_test fixture dataset flag (--dataset/--dataset-file)"
ds_out="$("$WORKSPACE/ops/ios_test.sh" --dataset marketing_demo -g Foo 2>&1 || true)"
[[ "$ds_out" == *"requires --ui"* ]] \
  && ok "ios_test rejects --dataset outside --ui scope" || fail_t "ios_test --dataset scope guard: $ds_out"
# #2668: --all-targets 含 UI target，與 --ui 同樣必須帶 UI World dataset（否則 UI 測試對空世界大量失敗）。
ds_out="$("$WORKSPACE/ops/ios_test.sh" --all-targets 2>&1 || true)"
[[ "$ds_out" == *"--all-targets requires --dataset"* ]] \
  && ok "ios_test --all-targets refuses to run without a UI World dataset" || fail_t "ios_test --all-targets dataset-required guard: $ds_out"
ds_out="$("$WORKSPACE/ops/ios_test.sh" --all-targets --dataset definitely-not-a-dataset 2>&1 || true)"
[[ "$ds_out" == *"dataset file not found"* ]] \
  && ok "ios_test --all-targets accepts --dataset (reaches dataset validation)" || fail_t "ios_test --all-targets --dataset scope guard: $ds_out"
ds_out="$("$WORKSPACE/ops/ios_test.sh" --ui --dataset a --dataset-file b 2>&1 || true)"
[[ "$ds_out" == *"either --dataset or --dataset-file"* ]] \
  && ok "ios_test rejects --dataset + --dataset-file together" || fail_t "ios_test dataset exclusivity guard: $ds_out"
ds_out="$("$WORKSPACE/ops/ios_test.sh" --ui --dataset definitely-not-a-dataset 2>&1 || true)"
[[ "$ds_out" == *"dataset file not found"* ]] \
  && ok "ios_test rejects missing named dataset" || fail_t "ios_test missing-dataset guard: $ds_out"
ios_test_bad_dataset="$(mktemp)"
printf '{"schema":"kg.fixture.dataset.v1","datasetID":"bad"}\n' >"$ios_test_bad_dataset"
ds_out="$("$WORKSPACE/ops/ios_test.sh" --ui --dataset-file "$ios_test_bad_dataset" 2>&1 || true)"
rm -f "$ios_test_bad_dataset"
[[ "$ds_out" == *"schema 必須是 kg.fixture.dataset.v2"* ]] \
  && ok "ios_test rejects invalid UI World manifest before staging" || fail_t "ios_test invalid-dataset guard: $ds_out"
ds_out="$("$WORKSPACE/ops/ios_test.sh" --ui --dataset marketing_demo --list 2>&1 || true)"
[[ "$ds_out" == *"cannot be combined with --list"* ]] \
  && ok "ios_test rejects --dataset with --list (no staging would run)" || fail_t "ios_test dataset/--list guard: $ds_out"
ds_out="$("$WORKSPACE/ops/ios_test.sh" --ui --dataset marketing_demo --cache-status 2>&1 || true)"
[[ "$ds_out" == *"cannot be combined with --list or cache actions"* ]] \
  && ok "ios_test rejects --dataset with cache actions (no staging would run)" || fail_t "ios_test dataset/cache-action guard: $ds_out"
# staging function：真 plist roundtrip，含 base64 特殊字元（+/=）經 PlistBuddy 內插
ds_staged_value="$(
  bash -c '
    set -euo pipefail
    eval "$(sed -n "/^xctestrun_target_env_roots()/,/^}/p" "$1")"
    eval "$(sed -n "/^sanitize_xctestrun_evidence_env_root()/,/^}/p" "$1")"
    eval "$(sed -n "/^stage_fixture_dataset_xctestrun()/,/^}/p" "$1")"
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    base="$tmp/base.xctestrun"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations array" "$base" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets array" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables dict" "$base"
    UI_FIXTURE_DATASET_DEFLATE_B64="aGVsbG8+Pz8rLz1aWg=="
    staged="$tmp/base_dataset_test.scoped.xctestrun"
    stage_fixture_dataset_xctestrun "$base" "$staged"
    /usr/libexec/PlistBuddy -c "Print :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_FIXTURE_DATASET_DEFLATE_B64" "$staged"
  ' _ "$WORKSPACE/ops/ios_test.sh" 2>/dev/null
)"
[[ "$ds_staged_value" == "aGVsbG8+Pz8rLz1aWg==" ]] \
  && ok "ios_test dataset staging upserts KG_FIXTURE_DATASET_DEFLATE_B64 into xctestrun copy (base64 +/= safe)" \
  || fail_t "ios_test dataset staging roundtrip: got '$ds_staged_value'"
# fixture staging 有同一個「邊枚舉邊改同一份 plist」的競態，但失效模式更安靜：
# 漏掉的 target 不是回非零，而是少注入 dataset——UI target 對著空世界跑測試的假綠。
# 同一支假枚舉器釘住：兩個 target 都必須拿到 dataset。
ds_racy_targets="$(
  bash -c '
    set -uo pipefail
    eval "$(sed -n "/^sanitize_xctestrun_evidence_env_root()/,/^}/p" "$1")"
    eval "$(sed -n "/^stage_fixture_dataset_xctestrun()/,/^}/p" "$1")"
    xctestrun_target_env_roots() {
      local p="$1" i s0 s
      s0=$(cksum < "$p")
      printf ":TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables\n"
      for i in $(seq 1 40); do
        s=$(cksum < "$p")
        [[ "$s" != "$s0" ]] && return 0
        sleep 0.05
      done
      printf ":TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables\n"
    }
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    base="$tmp/base.xctestrun"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations array" "$base" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets array" "$base"
    for t in 0 1; do
      /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:$t dict" "$base"
      /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:$t:TestingEnvironmentVariables dict" "$base"
      /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:$t:TestingEnvironmentVariables:KG_FIXTURE_DATASET_B64 string stale-plaintext" "$base"
    done
    UI_FIXTURE_DATASET_DEFLATE_B64="ZGV0ZXJtaW5pc3RpYw=="
    staged="$tmp/base_dataset_test.scoped.xctestrun"
    stage_fixture_dataset_xctestrun "$base" "$staged" || { printf "stage-rc-%s" "$?"; exit 0; }
    printf "%s|%s" \
      "$(/usr/libexec/PlistBuddy -c "Print :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_FIXTURE_DATASET_DEFLATE_B64" "$staged" 2>/dev/null)" \
      "$(/usr/libexec/PlistBuddy -c "Print :TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables:KG_FIXTURE_DATASET_DEFLATE_B64" "$staged" 2>/dev/null)"
  ' _ "$WORKSPACE/ops/ios_test.sh" 2>/dev/null
)"
[[ "$ds_racy_targets" == "ZGV0ZXJtaW5pc3RpYw==|ZGV0ZXJtaW5pc3RpYw==" ]] \
  && ok "ios_test dataset staging injects every target even when the plist is rewritten mid-enumeration" \
  || fail_t "ios_test dataset staging missed a target under mid-enumeration rewrite: $ds_racy_targets"
# 零 target：與 live-demo 那例同一個守衛，但守的是 stage_fixture_dataset_xctestrun。
# 兩個函式都用索引展開規避 /bin/bash 3.2 在 set -u 下對空陣列 "${a[@]}" 的中止；
# 少了這例，fixture 側被「簡化」回字面展開時不會有任何 gate 變紅（實測全綠）。
ds_zero_targets="$(
  bash -c '
    set -uo pipefail
    eval "$(sed -n "/^xctestrun_target_env_roots()/,/^}/p" "$1")"
    eval "$(sed -n "/^sanitize_xctestrun_evidence_env_root()/,/^}/p" "$1")"
    eval "$(sed -n "/^stage_fixture_dataset_xctestrun()/,/^}/p" "$1")"
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    base="$tmp/base.xctestrun"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations array" "$base" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets array" "$base"
    UI_FIXTURE_DATASET_DEFLATE_B64="ZGV0ZXJtaW5pc3RpYw=="
    stage_fixture_dataset_xctestrun "$base" "$tmp/zero.scoped.xctestrun" || { printf "stage-rc-%s" "$?"; exit 0; }
    printf "staged-anyway"
  ' _ "$WORKSPACE/ops/ios_test.sh" 2>/dev/null
)"
[[ "$ds_zero_targets" == "stage-rc-1" ]] \
  && ok "ios_test dataset staging fails closed on a zero-target xctestrun (bash 3.2 空陣列展開守衛)" \
  || fail_t "ios_test dataset staging did not fail closed with zero targets: $ds_zero_targets"
live_demo_env="$(
  bash -c '
    set -euo pipefail
    eval "$(sed -n "/^xctestrun_target_env_roots()/,/^}/p" "$1")"
    eval "$(sed -n "/^sanitize_xctestrun_evidence_env_root()/,/^}/p" "$1")"
    eval "$(sed -n "/^stage_live_demo_xctestrun()/,/^}/p" "$1")"
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    base="$tmp/base.xctestrun"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations array" "$base" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets array" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:BlueprintName string BooksAndVocabUITests" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_LIVE_DEMO_RUN string spoof" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_LIVE_DEMO_ACCOUNT_IDENTITY_SHA256 string eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:1 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:1:BlueprintName string BooksAndVocabTests" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables:KG_FIXTURE_DATASET_B64 string hidden-plaintext" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:1 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:1:TestTargets array" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:1:TestTargets:0 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:1:TestTargets:0:BlueprintName string AnotherUITestTarget" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:1:TestTargets:0:TestingEnvironmentVariables dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:1:TestTargets:0:TestingEnvironmentVariables:KG_LIVE_DEMO_RUN string hidden-spoof" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:1:TestTargets:0:TestingEnvironmentVariables:KG_FIXTURE_DATASET_DEFLATE_B64 string hidden-fixture" "$base"
    DEMO_ACCOUNT_IDENTITY_SHA256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    staged="$tmp/live.scoped.xctestrun"
    stage_live_demo_xctestrun "$base" "$staged"
    printf "%s|%s|%s" \
      "$(/usr/libexec/PlistBuddy -c "Print :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_LIVE_DEMO_RUN" "$staged")" \
      "$(/usr/libexec/PlistBuddy -c "Print :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables:KG_LIVE_DEMO_ACCOUNT_IDENTITY_SHA256" "$staged")" \
      "$(plutil -convert json -o - "$staged" | jq -r '\''[.TestConfigurations[].TestTargets[] | if .BlueprintName == "BooksAndVocabUITests" then ((.TestingEnvironmentVariables.KG_LIVE_DEMO_RUN == "1") and (.TestingEnvironmentVariables.KG_LIVE_DEMO_ACCOUNT_IDENTITY_SHA256 == "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd") and (.TestingEnvironmentVariables | has("KG_FIXTURE_DATASET_B64") | not) and (.TestingEnvironmentVariables | has("KG_FIXTURE_DATASET_DEFLATE_B64") | not)) else (.TestingEnvironmentVariables | (has("KG_LIVE_DEMO_RUN") | not) and (has("KG_LIVE_DEMO_ACCOUNT_IDENTITY_SHA256") | not) and (has("KG_FIXTURE_DATASET_B64") | not) and (has("KG_FIXTURE_DATASET_DEFLATE_B64") | not)) end] | all'\'')"
  ' _ "$WORKSPACE/ops/ios_test.sh" 2>/dev/null
)"
[[ "$live_demo_env" == "1|dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd|true" ]] \
  && ok "ios_test live-demo staging sanitizes all targets and injects only the dedicated UI target" \
  || fail_t "ios_test live-demo runner env contract invalid: $live_demo_env"
# 第三例（racy）是這組斷言的重點：前兩例用真枚舉器，命中與否取決於 PlistBuddy
# 寫入與枚舉的時序（IMP-20260805-bf0df5 回報日 2/10 紅，2026-08-08 同機 0/10 紅），
# 時序型探針無法當 gate——它今天全綠不代表 bug 消失。第三例改用一支「枚舉期一
# 偵測到 plist 被改寫就收工」的假枚舉器，把偶發漏數變成必然：只有當
# stage_live_demo_xctestrun 先枚舉完所有 root 再開始變更，第二個 target 才數得到，
# 重複 target 才會 fail-closed。
live_demo_target_cardinality="$(
  bash -c '
    set -uo pipefail
    eval "$(sed -n "/^xctestrun_target_env_roots()/,/^}/p" "$1")"
    eval "$(sed -n "/^sanitize_xctestrun_evidence_env_root()/,/^}/p" "$1")"
    eval "$(sed -n "/^stage_live_demo_xctestrun()/,/^}/p" "$1")"
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    make_plist() {
      local path="$1" target=0 name
      /usr/libexec/PlistBuddy -c "Add :TestConfigurations array" "$path" >/dev/null 2>&1
      /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0 dict" "$path"
      /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets array" "$path"
      shift
      for name in "$@"; do
        /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:$target dict" "$path"
        /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:$target:BlueprintName string $name" "$path"
        /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:$target:TestingEnvironmentVariables dict" "$path"
        /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:$target:TestingEnvironmentVariables:KG_LIVE_DEMO_RUN string spoof" "$path"
        target=$((target + 1))
      done
    }
    DEMO_ACCOUNT_IDENTITY_SHA256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    # 零 target：枚舉結果是空陣列。/bin/bash 3.2 對空陣列展開 "${a[@]}" 在 set -u 下
    # 會 unbound variable 中止，正好打在 fail-closed 路徑上——必須乾淨回 1，不是爆掉。
    make_plist "$tmp/empty.xctestrun"
    stage_live_demo_xctestrun "$tmp/empty.xctestrun" "$tmp/empty.scoped.xctestrun"; empty_rc=$?
    make_plist "$tmp/missing.xctestrun" BooksAndVocabTests
    stage_live_demo_xctestrun "$tmp/missing.xctestrun" "$tmp/missing.scoped.xctestrun"; missing_rc=$?
    make_plist "$tmp/duplicate.xctestrun" BooksAndVocabUITests BooksAndVocabUITests
    stage_live_demo_xctestrun "$tmp/duplicate.xctestrun" "$tmp/duplicate.scoped.xctestrun"; duplicate_rc=$?
    # 真枚舉器的覆蓋到此為止，之後才換成決定性的假枚舉器。
    xctestrun_target_env_roots() {
      local p="$1" i s0 s
      s0=$(cksum < "$p")
      printf ":TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables\n"
      for i in $(seq 1 40); do
        s=$(cksum < "$p")
        [[ "$s" != "$s0" ]] && return 0
        sleep 0.05
      done
      printf ":TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables\n"
    }
    make_plist "$tmp/racy.xctestrun" BooksAndVocabUITests BooksAndVocabUITests
    stage_live_demo_xctestrun "$tmp/racy.xctestrun" "$tmp/racy.scoped.xctestrun"; racy_rc=$?
    printf "%s|%s|%s|%s" "$empty_rc" "$missing_rc" "$duplicate_rc" "$racy_rc"
  ' _ "$WORKSPACE/ops/ios_test.sh" 2>/dev/null
)"
[[ "$live_demo_target_cardinality" == "1|1|1|1" ]] \
  && ok "ios_test live-demo staging rejects zero or multiple dedicated UI targets (含枚舉期被改寫的決定性競態)" \
  || fail_t "ios_test live-demo target cardinality was not fail-closed: $live_demo_target_cardinality"
live_demo_spoof_detected="$(
  bash -c '
    set -euo pipefail
    eval "$(sed -n "/^xctestrun_target_env_roots()/,/^}/p" "$1")"
    eval "$(sed -n "/^xctestrun_has_live_demo_env()/,/^}/p" "$1")"
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    base="$tmp/base.xctestrun"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations array" "$base" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets array" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:TestingEnvironmentVariables dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:1 dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables dict" "$base"
    /usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:1:TestingEnvironmentVariables:KG_LIVE_DEMO_RUN string 1" "$base"
    xctestrun_has_live_demo_env "$base" && printf detected
  ' _ "$WORKSPACE/ops/ios_test.sh" 2>/dev/null
)"
[[ "$live_demo_spoof_detected" == "detected" ]] \
  && ok "ios_test detects spoofed live-demo env outside the authorized runner path" \
  || fail_t "ios_test failed to detect spoofed live-demo xctestrun env"
live_demo_missing_hash="$($WORKSPACE/ops/ios_test.sh --ui --configuration Release --evidence-kind exact-device --destination 'platform=iOS,id=device-1' --live-demo testLiveDemoAccountHasProEntitlement 2>&1 || true)"
[[ "$live_demo_missing_hash" == *"normalized account identity SHA256"* ]] \
  && ok "ios_test rejects missing live-demo identity" || fail_t "ios_test accepted missing live-demo identity: $live_demo_missing_hash"
live_demo_malformed_hash="$($WORKSPACE/ops/ios_test.sh --ui --configuration Release --evidence-kind exact-device --destination 'platform=iOS,id=device-1' --live-demo --live-demo-account-identity-sha256 NOT-A-SHA testLiveDemoAccountHasProEntitlement 2>&1 || true)"
[[ "$live_demo_malformed_hash" == *"normalized account identity SHA256"* ]] \
  && ok "ios_test rejects malformed live-demo identity" || fail_t "ios_test accepted malformed live-demo identity: $live_demo_malformed_hash"
live_demo_unit_reject="$($WORKSPACE/ops/ios_test.sh --unit --configuration Release --evidence-kind exact-device --destination 'platform=iOS,id=device-1' --live-demo --live-demo-account-identity-sha256 "$(printf 'd%.0s' {1..64})" testLiveDemoAccountHasProEntitlement 2>&1 || true)"
[[ "$live_demo_unit_reject" == *"requires UI scope"* ]] \
  && ok "ios_test rejects live-demo env injection outside UI scope" || fail_t "ios_test accepted unit live-demo: $live_demo_unit_reject"
live_demo_extra_test_reject="$($WORKSPACE/ops/ios_test.sh --ui --configuration Release --evidence-kind exact-device --destination 'platform=iOS,id=device-1' --live-demo --live-demo-account-identity-sha256 "$(printf 'd%.0s' {1..64})" testLiveDemoAccountHasProEntitlement testOther 2>&1 || true)"
[[ "$live_demo_extra_test_reject" == *"runs only testLiveDemoAccountHasProEntitlement"* ]] \
  && ok "ios_test prevents live-demo env exposure to extra tests" || fail_t "ios_test exposed live-demo env to extra test: $live_demo_extra_test_reject"
live_demo_simulator_reject="$($WORKSPACE/ops/ios_test.sh --ui --configuration Release --evidence-kind exact-device --destination 'platform=iOS Simulator,id=sim-1' --live-demo --live-demo-account-identity-sha256 "$(printf 'd%.0s' {1..64})" testLiveDemoAccountHasProEntitlement 2>&1 || true)"
[[ "$live_demo_simulator_reject" == *"requires --destination platform=iOS,id=<physical-UDID>"* ]] \
  && ok "ios_test rejects simulator live-demo env injection" || fail_t "ios_test accepted simulator live-demo: $live_demo_simulator_reject"
live_demo_reject="$($WORKSPACE/ops/ios_test.sh --ui --configuration Debug --evidence-kind exact-device --destination 'platform=iOS,id=device-1' --live-demo --live-demo-account-identity-sha256 "$(printf 'd%.0s' {1..64})" testLiveDemoAccountHasProEntitlement 2>&1 || true)"
[[ "$live_demo_reject" == *"requires UI scope, Release exact-device"* ]] \
  && ok "ios_test rejects Debug live-demo env injection" || fail_t "ios_test accepted Debug live-demo: $live_demo_reject"
live_demo_fixture_reject="$($WORKSPACE/ops/ios_test.sh --ui --configuration Release --evidence-kind exact-device --destination 'platform=iOS,id=device-1' --live-demo --live-demo-account-identity-sha256 "$(printf 'd%.0s' {1..64})" --dataset marketing_demo testLiveDemoAccountHasProEntitlement 2>&1 || true)"
[[ "$live_demo_fixture_reject" == *"cannot use fixture"* ]] \
  && ok "ios_test rejects fixture-backed live-demo env injection" || fail_t "ios_test accepted fixture live-demo: $live_demo_fixture_reject"
grep -q 'source "$SCRIPT_DIR/lib/fixture_dataset_env.sh"' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'kg_fixture_dataset_deflate_b64' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test produces dataset env via shared deflate lib" \
  || fail_t "ios_test does not use fixture_dataset_env.sh deflate producer"
grep -q 'kg_fixture_dataset_deflate_b64' "$WORKSPACE/ops/review_flip_probe.sh" \
  && grep -q 'KG_FIXTURE_DATASET_DEFLATE_B64' "$WORKSPACE/ops/review_flip_probe.sh" \
  && ! grep -q 'KG_FIXTURE_DATASET_B64=' "$WORKSPACE/ops/review_flip_probe.sh" \
  && ok "review_flip_probe injects deflate dataset env on all launch paths" \
  || fail_t "review_flip_probe still injects plaintext KG_FIXTURE_DATASET_B64"
grep -q 'STAGED_DATASET_XCTESTRUN="\${xctestrun_path%' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'rm -f "\${STAGED_DATASET_XCTESTRUN:-}"' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test staged dataset xctestrun is parent-shell tracked + cleaned in trap" \
  || fail_t "ios_test staged dataset cleanup wiring missing (subshell assignment regression?)"
grep -Eq 'TEST \(EXECUTE \)\?SUCCEEDED|TEST\( EXECUTE\)\? SUCCEEDED|TEST\( EXECUTE\)\?SUCCEEDED|TEST \(EXECUTE\)\? FAILED|TEST\( EXECUTE\)\?FAILED' "$WORKSPACE/ops/ios_test.sh" \
  || grep -qE 'TEST\( EXECUTE\)\? SUCCEEDED|TEST \(EXECUTE \)\? SUCCEEDED|TEST \(EXECUTE \)\? FAILED' "$WORKSPACE/ops/ios_test.sh"
if [[ $? -eq 0 ]]; then
  ok "ios_test recognizes test-without-building success banner"
else
  fail_t "ios_test missing TEST EXECUTE SUCCEEDED handling"
fi
grep -q 'xcresult=.*RESULT_BUNDLE' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test verdict records xcresult" || fail_t "ios_test verdict missing xcresult path"
grep -q 'bootMs:' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'testBodyMs:' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'xcresultSessionMs:' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'appLaunchAverageMs:' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'appLaunchSamples:' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'invocationOverheadMs:' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'xcodebuildMs:' "$WORKSPACE/ops/ios_test.sh" \
  && grep -q 'totalMs:' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test verdict records timing breakdown" || fail_t "ios_test verdict missing timing fields"
grep -q 'VERDICT_JSON_FILE' "$WORKSPACE/ops/ios_test.sh" \
  && ok "ios_test writes JSON verdict" || fail_t "ios_test missing JSON verdict"
ios_test_retry_tmp="$(mktemp -d)"
cat > "$ios_test_retry_tmp/test_failed.log" <<'LOG'
Test Suite 'All tests' started
Test Case '-[BooksAndVocabTests PollutedStateTests testPollutedState]' failed (0.123 seconds)
** TEST FAILED **
LOG
cat > "$ios_test_retry_tmp/cache_corrupt.log" <<'LOG'
xcodebuild: error: Failed to read xctestrun file
LOG
retry_should_not_rebuild="$(
  TMPOUT="$ios_test_retry_tmp/test_failed.log" \
    bash -lc '
      eval "$(sed -n "/^should_rebuild_after_test_without_building_failure()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      if should_rebuild_after_test_without_building_failure; then echo rebuild; else echo preserve; fi
    '
)"
[[ "$retry_should_not_rebuild" == "preserve" ]] \
  && ok "ios_test preserves genuine TEST FAILED result without rebuild" || fail_t "ios_test retries genuine test failure: $retry_should_not_rebuild"
retry_should_rebuild="$(
  TMPOUT="$ios_test_retry_tmp/cache_corrupt.log" \
    bash -lc '
      eval "$(sed -n "/^should_rebuild_after_test_without_building_failure()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      if should_rebuild_after_test_without_building_failure; then echo rebuild; else echo preserve; fi
    '
)"
[[ "$retry_should_rebuild" == "rebuild" ]] \
  && ok "ios_test rebuilds only cache/infrastructure failure" || fail_t "ios_test did not rebuild cache corruption failure: $retry_should_rebuild"
missing_log_count="$(
  TMPOUT="$ios_test_retry_tmp/does-not-exist.log" \
    bash -lc '
      eval "$(sed -n "/^test_log_line_count()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      if test_log_line_count; then echo present; else echo missing; fi
    '
)"
[[ "$missing_log_count" == "missing" ]] \
  && ok "ios_test treats missing xcodebuild log as structured infra failure input" || fail_t "ios_test missing-log guard invalid: $missing_log_count"
missing_log_marker="$(
  TMPOUT="$ios_test_retry_tmp/does-not-exist.log" \
    bash -lc '
      eval "$(sed -n "/^write_missing_test_log_marker()/,/^}/p" "'"$WORKSPACE/ops/ios_test.sh"'")"
      write_missing_test_log_marker
      cat "$TMPOUT"
    '
)"
echo "$missing_log_marker" | grep -q 'xcodebuild log path disappeared before diagnostics could read it' \
  && ok "ios_test can synthesize a readable placeholder when the log path disappears" || fail_t "ios_test missing-log marker invalid: $missing_log_marker"
missing_diag_json="$("$IOS_DIAG" --kind test --xcresult "$ios_test_retry_tmp/Missing.xcresult" --log "$ios_test_retry_tmp/never-created.log" --json --result fail)"
echo "$missing_diag_json" | jq -e --arg log "$ios_test_retry_tmp/never-created.log" '.schema=="kg.ios.diagnostics.v1" and .source=="raw-log-missing" and .result=="fail" and .counts.errors==0 and .logError=="log file not found: \($log)" and (.xcresultError|length > 0) and .artifacts.log==$log' >/dev/null \
  && ok "ios_diagnostics reports missing fallback log as machine-readable error" || fail_t "ios_diagnostics missing-log fallback invalid: $missing_diag_json"
rm -rf "$ios_test_retry_tmp"

section "ios_test lease failure is a structured verdict"
# A lease refusal happens before xcodebuild starts, so it must still publish a
# per-invocation verdict.  Without that evidence the outer gate can only report
# a misleading missing-artifacts/unknown result.
lease_failure_tmp="$(mktemp -d "${TMPDIR:-/tmp}/kg-ios-lease-failure.XXXXXX")"
lease_failure_out="$lease_failure_tmp/stdout"
lease_failure_err="$lease_failure_tmp/stderr"
lease_failure_rc=0
KG_IOS_SIM_POOL_SIZE=0 \
KG_IOS_DISK_GUARD_STATE="$lease_failure_tmp/no-guard-state.json" \
KG_IOS_SIM_LEASE_ROOT="$lease_failure_tmp/leases" \
KG_IOS_VERDICT_FILE="$lease_failure_tmp/verdict" \
  "$IOS_OPS" test --unit --lease --json >"$lease_failure_out" 2>"$lease_failure_err" || lease_failure_rc=$?
[[ "$lease_failure_rc" -eq 1 ]] \
  && ok "ios_test returns non-zero for an exhausted simulator pool" \
  || fail_t "ios_test lease refusal exit changed: $lease_failure_rc"
if [[ -s "$lease_failure_tmp/verdict.json" ]] \
  && jq -e '.result == "inconclusive" and .reason == "simulator-pool-exhausted" and .exit == "1"' \
      "$lease_failure_tmp/verdict.json" >/dev/null; then
  ok "ios_test publishes a pool-exhaustion verdict before xcodebuild"
else
  fail_t "ios_test did not publish the expected pool-exhaustion verdict"
fi
# The legacy one-line verdict must carry this run's own identity, the same pid
# and cwd as the JSON verdict: a single-quoted printf format once wrote the
# literal `$(kg_ios_verdict_identity_kv)` text instead (#2207).
lease_legacy="$(cat "$lease_failure_tmp/verdict" 2>/dev/null || true)"
lease_json_pid="$(jq -r '.invocation.pid // empty' "$lease_failure_tmp/verdict.json" 2>/dev/null || true)"
lease_json_cwd="$(jq -r '.invocation.cwd // empty' "$lease_failure_tmp/verdict.json" 2>/dev/null || true)"
lease_identity_re=" ts=[0-9]+ pid=${lease_json_pid} cwd=(.*)\$"
lease_legacy_cwd=""
if [[ "$lease_legacy" =~ $lease_identity_re ]]; then lease_legacy_cwd="${BASH_REMATCH[1]}"; fi
if [[ "$lease_json_pid" =~ ^[0-9]+$ && -n "$lease_json_cwd" \
      && "$lease_legacy" != *'$('* && "$lease_legacy_cwd" == "$lease_json_cwd" ]]; then
  ok "ios_test early-failure legacy verdict expands this run's ts/pid/cwd identity"
else
  fail_t "ios_test early-failure legacy verdict lacks this run's identity (json pid=$lease_json_pid cwd=$lease_json_cwd): $lease_legacy"
fi
grep -q "pool is exhausted" "$lease_failure_err" \
  && ok "ios_test preserves the operator-facing pool exhaustion reason" \
  || fail_t "ios_test lost the operator-facing pool exhaustion reason"
rm -rf "$lease_failure_tmp"

section "ios_test generic device compile is unsigned and cache-isolated"
# The live-only Release gate uses generic/platform=iOS only to prove that the
# UITest target compiles. It must not require an iOS Development identity, and
# its unsigned products must never be reused by an exact-device run that needs
# signed/installable products.
ios_test_signing_mode_fn="$(sed -n '/^ios_test_signing_mode()/,/^}/p' "$WORKSPACE/ops/ios_test.sh")"
ios_test_signing_args_fn="$(sed -n '/^ios_test_signing_args()/,/^}/p' "$WORKSPACE/ops/ios_test.sh")"
if [[ -n "$ios_test_signing_mode_fn" && -n "$ios_test_signing_args_fn" ]]; then
  generic_signing_mode="$(bash -lc "$ios_test_signing_mode_fn"$'\n''ios_test_signing_mode generic/platform=iOS')"
  exact_signing_mode="$(bash -lc "$ios_test_signing_mode_fn"$'\n''ios_test_signing_mode platform=iOS,id=00008140-000000000000001E')"
  simulator_signing_mode="$(bash -lc "$ios_test_signing_mode_fn"$'\n''ios_test_signing_mode platform=iOS\ Simulator,name=iPhone\ 17\ Pro\ Max')"
  generic_signing_args="$(bash -lc "$ios_test_signing_mode_fn"$'\n'"$ios_test_signing_args_fn"$'\n''ios_test_signing_args generic/platform=iOS')"
  exact_signing_args="$(bash -lc "$ios_test_signing_mode_fn"$'\n'"$ios_test_signing_args_fn"$'\n''ios_test_signing_args platform=iOS,id=00008140-000000000000001E')"
  simulator_signing_args="$(bash -lc "$ios_test_signing_mode_fn"$'\n'"$ios_test_signing_args_fn"$'\n''ios_test_signing_args platform=iOS\ Simulator,name=iPhone\ 17\ Pro\ Max')"
  [[ "$generic_signing_mode" == unsigned-generic-device \
      && "$generic_signing_args" == *CODE_SIGNING_ALLOWED=NO* \
      && "$generic_signing_args" == *CODE_SIGNING_REQUIRED=NO* ]] \
    && ok "generic/platform=iOS compile is explicitly unsigned" \
    || fail_t "generic device signing contract invalid: mode=$generic_signing_mode args=$generic_signing_args"
  [[ "$exact_signing_mode" == signed-device && -z "$exact_signing_args" ]] \
    && ok "exact-device tests keep normal signing" \
    || fail_t "exact-device signing was overridden: mode=$exact_signing_mode args=$exact_signing_args"
  [[ "$simulator_signing_mode" == simulator && -z "$simulator_signing_args" ]] \
    && ok "simulator tests keep normal signing behavior" \
    || fail_t "simulator signing was overridden: mode=$simulator_signing_mode args=$simulator_signing_args"
else
  fail_t "ios_test lacks the generic-device signing-mode seam"
fi
grep -q 'IOS_TEST_SIGNING_ARGS\[@\]' "$WORKSPACE/ops/ios_test.sh" \
  && ok "real build-for-testing invocation consumes signing args" \
  || fail_t "signing args are not wired into the real xcodebuild invocation"

section "ios_test destination-aware cache readiness"
# Regression for IMP-0033. `ios_test_cached_products_ready` keyed the SDK suffix
# off a `platform=iOS,` substring — WITH a trailing comma — so the comma-less
# `generic/platform=iOS` destination that the live-only Release compile gate
# uses fell back to iphonesimulator, could never see its own Release-iphoneos
# products, and reported productsReady:false on a complete cache. The sentinel
# is written behind the same predicate, so that cache also stayed permanently
# cold (a full Release rebuild every run). The generic compile is unsigned, so
# its cache key must differ from an exact-device run's signed products.
#
# Hermetic: `--cache-status` never builds, so this fabricates the product layout
# a real unsigned build-for-testing leaves behind for `generic/platform=iOS`.
ios_cache_probe_root="$(mktemp -d "${TMPDIR:-/tmp}/kg_ios_cache_probe.XXXXXX")"
ios_cache_status_json() {
  KG_IOS_TEST_CACHE_ROOT="$ios_cache_probe_root" \
    bash "$WORKSPACE/ops/ios_test.sh" --ui --configuration Release \
      --destination "$1" --cache-status --json 2>/dev/null
}
ios_cache_derived_root="$(ios_cache_status_json 'generic/platform=iOS' \
  | jq -r 'if type=="object" then .cache.derivedDataRoot else empty end' 2>/dev/null || true)"
if [[ -z "$ios_cache_derived_root" ]]; then
  # Stdout is not parseable as JSON at all — recover the root so the readiness
  # assertions below still run, and let the purity assertion report the failure.
  ios_cache_derived_root="$(ios_cache_status_json 'generic/platform=iOS' \
    | sed -n 's/.*"derivedDataRoot": "\([^"]*\)".*/\1/p' | head -1)"
fi
[[ -n "$ios_cache_derived_root" ]] \
  && ok "ios_test cache-status reports a derivedDataRoot" \
  || fail_t "ios_test cache-status reported no derivedDataRoot"

ios_cache_products="$ios_cache_derived_root/Build/Products"
mkdir -p "$ios_cache_products/Release-iphoneos/BooksAndVocab.app/PlugIns/BooksAndVocabTests.xctest" \
         "$ios_cache_products/Release-iphoneos/BooksAndVocabUITests-Runner.app"
: > "$ios_cache_products/BooksAndVocabUITests_iphoneos26.0-arm64.xctestrun"
: > "$ios_cache_derived_root/.kg-test-cache-complete"

ios_cache_generic_raw="$(ios_cache_status_json 'generic/platform=iOS')"
echo "$ios_cache_generic_raw" | jq -e '.schema=="kg.ios.test-cache.v1"' >/dev/null 2>&1 \
  && ok "ios_test --cache-status --json keeps stdout pure JSON" \
  || fail_t "ios_test --cache-status --json pollutes stdout: $(echo "$ios_cache_generic_raw" | head -1)"

ios_cache_ready_for() {
  ios_cache_status_json "$1" | sed -n '/^{/,$p' | jq -r '.cache.productsReady' 2>/dev/null
}
ios_cache_exact_root="$(ios_cache_status_json 'platform=iOS,id=00008140-000000000000001E' | jq -r '.cache.derivedDataRoot')"
[[ "$ios_cache_exact_root" != "$ios_cache_derived_root" ]] \
  && ok "unsigned generic cache is isolated from signed exact-device cache" \
  || fail_t "generic and exact-device destinations still share one cache root"
[[ "$(ios_cache_ready_for 'generic/platform=iOS')" == true ]] \
  && ok "generic/platform=iOS sees its own Release-iphoneos products" \
  || fail_t "generic/platform=iOS reports productsReady=false on a complete iphoneos cache (IMP-0033)"
[[ "$(ios_cache_ready_for 'platform=iOS,id=00008140-000000000000001E')" == false ]] \
  && ok "exact-device destination refuses unsigned generic products" \
  || fail_t "exact-device destination reused unsigned generic products"

# Negative: iphoneos readiness must not be satisfiable by simulator products.
rm -rf "$ios_cache_products/Release-iphoneos"
mkdir -p "$ios_cache_products/Release-iphonesimulator/BooksAndVocab.app/PlugIns/BooksAndVocabTests.xctest" \
         "$ios_cache_products/Release-iphonesimulator/BooksAndVocabUITests-Runner.app"
[[ "$(ios_cache_ready_for 'generic/platform=iOS')" == false ]] \
  && ok "generic/platform=iOS rejects iphonesimulator products" \
  || fail_t "generic/platform=iOS accepted iphonesimulator products as iphoneos-ready"
rm -rf "$ios_cache_probe_root"

# `prepare` must never label a build "prepared" when the cache has no ready
# products: the JSON verdict was self-contradicting AND exit 0, so the
# live-only Release compile block gate (worktree_orchestrate.py) went green on
# a cache that produced nothing.
ios_prepare_status_fn="$(sed -n '/^ios_test_prepare_status()/,/^}/p' "$WORKSPACE/ops/ios_test.sh")"
if [[ -n "$ios_prepare_status_fn" ]]; then
  ios_prepare_ready="$(bash -lc "$ios_prepare_status_fn"$'\n''ios_test_prepare_status true')"
  ios_prepare_unready="$(bash -lc "$ios_prepare_status_fn"$'\n''ios_test_prepare_status false')"
  [[ "$ios_prepare_ready" == prepared ]] \
    && ok "prepare reports 'prepared' when products are ready" \
    || fail_t "prepare status for ready products invalid: $ios_prepare_ready"
  [[ "$ios_prepare_unready" == error ]] \
    && ok "prepare refuses 'prepared' when products are missing" \
    || fail_t "prepare status for missing products invalid: $ios_prepare_unready"
else
  fail_t "ios_test has no ios_test_prepare_status seam — prepare status is still hardcoded (IMP-0033)"
fi
grep -qE 'print_cache_payload prepare "?\$\{?prepare_status' "$WORKSPACE/ops/ios_test.sh" \
  && ok "prepare payload derives its status from products readiness" \
  || fail_t "prepare payload still hardcodes a literal status"

section "Catalyst compile gate does not require a development signing identity"
# `ios-build-catalyst` is a BLOCK CI gate whose stated job is "sim green !=
# Catalyst green" — a COMPILE check. Signability is orthogonal to compilability
# and is proven elsewhere (ops/ios_release.sh archives with Apple Distribution).
# Demanding a "Mac Development" certificate here made the gate unpassable on a
# machine that has none, which is the mirror image of an unfailable gate: it
# gives no signal and trains everyone to route around the red (IMP-0039).
IOS_BUILD="$WORKSPACE/ops/ios_build.sh"
plan_cat="$("$IOS_BUILD" --catalyst --dry-run 2>&1 || true)"
plan_sim="$("$IOS_BUILD" --dry-run 2>&1 || true)"
plan_override="$("$IOS_BUILD" --catalyst --extra-settings CODE_SIGNING_ALLOWED=YES --dry-run 2>&1 || true)"

# `--dry-run` prints the SAME argv the real build consumes (xcodebuild_argv), so
# these assertions bind the plumbing. The first draft of this block had a
# separate printer, and review proved every assertion below stayed green after
# the fix was reverted at the xcodebuild call site — measuring the printer, not
# the pipe. The source pin at the end of this section keeps that shape honest.
[[ "$plan_cat" == *"argv=platform=macOS,variant=Mac Catalyst"* ]] \
  && ok "--catalyst resolves the Mac Catalyst destination" \
  || fail_t "--catalyst --dry-run did not report the Catalyst destination: $plan_cat"
[[ "$plan_cat" == *"argv=CODE_SIGNING_ALLOWED=NO"* ]] \
  && ok "--catalyst compiles unsigned (no Mac Development cert needed)" \
  || fail_t "--catalyst still demands a signing identity — the gate is unpassable without a cert"
# Positive shape on purpose: "no 'lock acquired'" also holds for every error
# path AND for a real build that times out waiting on a busy lock (10 min, then
# exit 1, never printing it). `[ios_build]` is the first thing the real path
# emits — before the lock wait — so its ABSENCE plus a real plan is the
# discriminating pair. Without this the seam could regress into three genuine
# builds fighting over /tmp/kg-ios-build.lock inside a second-scale unit suite.
[[ "$plan_cat" != *"[ios_build]"* && "$plan_cat" == *"argv=build"* ]] \
  && ok "--dry-run reports the plan without entering the build path" \
  || fail_t "--dry-run entered the real build path or produced no plan: $plan_cat"
# Discriminating: if signing-off were applied unconditionally the first two
# assertions would pass while silently changing every simulator build too. The
# `argv=` half keeps this from passing vacuously on an error string.
[[ "$plan_sim" == *"argv=platform=iOS Simulator"* && "$plan_sim" != *"CODE_SIGNING"* ]] \
  && ok "simulator builds are left untouched by the Catalyst signing rule" \
  || fail_t "simulator build plan wrong or had signing settings injected: $plan_sim"
# Caller intent wins: xcodebuild takes the last occurrence of a build setting.
override_count="$(printf '%s\n' "$plan_override" | grep -c 'argv=CODE_SIGNING_ALLOWED=' || true)"
override_tail="$(printf '%s\n' "$plan_override" | grep 'argv=CODE_SIGNING_ALLOWED=' | tail -1 || true)"
[[ "$override_count" -ge 2 && "$override_tail" == "argv=CODE_SIGNING_ALLOWED=YES" ]] \
  && ok "an explicit --extra-settings override outranks the Catalyst default" \
  || fail_t "caller override did not land last (count=$override_count tail=$override_tail)"
# --json pins a verdict path and reads it back; a plan writes none, so the pair
# would report an earlier run as this invocation — exit 0 with no evidence.
dryrun_json_rc=0
KG_IOS_VERDICT_FILE="/tmp/kg-should-never-be-written.json" \
  "$IOS_BUILD" --catalyst --dry-run >/dev/null 2>&1 || dryrun_json_rc=$?
[[ "$dryrun_json_rc" -ne 0 && ! -f /tmp/kg-should-never-be-written.json ]] \
  && ok "--dry-run refuses a pinned verdict path instead of reporting a stale run" \
  || fail_t "--dry-run accepted --json semantics (rc=$dryrun_json_rc)"
# Source pin: the plan is only load-bearing while the real invocation consumes
# it. A hand-written flag list at the call site would restore the drift that
# every assertion above is blind to.
xcodebuild_call="$(grep -n 'xcodebuild "\${XCARGV\[@\]}"' "$WORKSPACE/ops/ios_build.sh" || true)"
[[ -n "$xcodebuild_call" ]] \
  && ok "the real build consumes xcodebuild_argv rather than an inline flag list" \
  || fail_t "ops/ios_build.sh no longer invokes xcodebuild via XCARGV — plan and run can diverge again"
section "ui-smoke launch smoke is hermetic"
smoke_body="$(sed -n '/func testLaunchShowsAllTabs()/,/^    }/p' "$WORKSPACE/ios/BooksAndVocabUITests/BooksAndVocabUITests.swift")"
grep -q 'launchIsolatedApp(' <<<"$smoke_body" && ! grep -q 'launchApp(' <<<"$smoke_body" \
  && ok "testLaunchShowsAllTabs launches through the isolated seam" \
  || fail_t "testLaunchShowsAllTabs uses non-isolated launchApp (non-isolated launch wedged testmanagerd, #3002)"

echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
