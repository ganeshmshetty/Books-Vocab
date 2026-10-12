#!/usr/bin/env bash
# ios_release.sh — App Store / TestFlight 發版（archive → export → 選擇性上傳）
#
# 用 App Store Connect API key 自動管理 distribution 簽章（-allowProvisioningUpdates），
# 無需在本機 keychain 手動匯入 Apple Distribution 憑證。
# 與 ios_build.sh 共用同一把 build lock（多 worktree / 並行安全）。
#
# Usage:
#   ./ops/ios_release.sh                    # archive + export 出 .ipa（無對外副作用，預設）
#   ./ops/ios_release.sh --upload           # 額外上傳到 App Store Connect（→ TestFlight）
#   ./ops/ios_release.sh --key 6Y7DC88RUY   # 指定 API key（預設 TCXVHFRXMS / App Manager）
#   ./ops/ios_release.sh --timeout 900      # 自訂 lock 等待秒數（預設 600）
#
# 前置：~/.secrets/apple/AuthKey_<KEY_ID>.p8 存在（金鑰清單見該目錄 README.md）。
# 上傳前會擋「build number 已存在於 TestFlight」——需先 bump CURRENT_PROJECT_VERSION。
# --upload 時另把 archive 的 dSYMs 上傳 Sentry（best-effort，ops/sentry_release.sh；
# 缺 ~/.secrets/sentry.env 設定 → 大聲 SKIP，失敗/逾時只警告，永不讓 release 失敗）。

set -euo pipefail

# ---- config ----
SCHEME="BooksAndVocab"
CONFIGURATION="Release"
TEAM_ID="XNSH5U9FNV"
ISSUER_ID="d7f86188-7c56-46f7-bc99-f889421025fa"
APP_ID="6759816274"                 # com.Max0228.BooksBrowser
KEY_ID="TCXVHFRXMS"                 # App Manager（可送審）；只上 TestFlight 可改 6Y7DC88RUY（Developer）
DO_UPLOAD=0
TIMEOUT=600
POLL_INTERVAL=3
LOCK_FILE="/tmp/kg-ios-build.lock"  # 與 ios_build.sh 共用
# VERDICT_FILE / VERDICT_JSON_FILE：per-invocation 唯一路徑（多 session 競態防護），
# 固定路徑 kg_ios_archive_verdict(.json) 只是 latest pointer。由
# lib/ios_run_verdict.sh 的 kg_ios_verdict_init 設定（見下方 source）。
LOCK_WAIT_MS=0
ARCHIVE_MS=0
EXPORT_MS=0
UPLOAD_MS=0
TOTAL_MS=0
SENTRY_DSYMS_STATUS="not-requested"  # not-requested | ok | skipped | fail（不影響頂層 status）

# 只印開頭連續註解區（停在第一個非 # 行）作為 help。
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }
# 取值型選項守衛：$2 缺失/為空/是另一個 flag 時給友善訊息，而非 set -u 的 unbound variable。
need_val() { [[ -n "${2:-}" && "${2:-}" != -* ]] || { echo "✗ $1 需要一個值（不可為空或接另一個選項）" >&2; exit 1; }; }
now_ms() { perl -MTime::HiRes=time -e 'printf("%.0f\n", time()*1000)'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upload)   DO_UPLOAD=1; shift ;;
    --key)      need_val --key "${2:-}";     KEY_ID="$2"; shift 2 ;;
    --timeout)  need_val --timeout "${2:-}"; TIMEOUT="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "✗ 未知選項: $1（-h 看用法）" >&2; exit 1 ;;
  esac
done

KEY_PATH="$HOME/.secrets/apple/AuthKey_${KEY_ID}.p8"
[[ -f "$KEY_PATH" ]] || { echo "✗ API key not found: ${KEY_PATH}（見 ~/.secrets/apple/README.md）" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Optional run-metrics logging — additive, must never break the release.
METRICS_LIB="$SCRIPT_DIR/lib/ios_run_metrics.sh"
[[ -f "$METRICS_LIB" ]] && source "$METRICS_LIB"
# shellcheck source=lib/ios_build_progress.sh
source "$SCRIPT_DIR/lib/ios_build_progress.sh"
# shellcheck source=lib/ios_lock_wait.sh
source "$SCRIPT_DIR/lib/ios_lock_wait.sh"
# shellcheck source=lib/ios_run_verdict.sh
source "$SCRIPT_DIR/lib/ios_run_verdict.sh"
# shellcheck source=lib/ios_disk_budget.sh
source "$SCRIPT_DIR/lib/ios_disk_budget.sh"
kg_ios_verdict_init archive "$ROOT"
echo "[release] verdict=$VERDICT_FILE (latest pointer: $VERDICT_LATEST_FILE)"
XCODEPROJ="$ROOT/ios/BooksAndVocab.xcodeproj"
EXPORT_OPTS="$ROOT/ios/ExportOptions.plist"
# Pin archive DerivedData to one shared cache anchored at the main repo (see
# docs/reference/ios_deriveddata_policy.md). Without -derivedDataPath, archive
# intermediates leak to ~/Library/.../DerivedData/BooksAndVocab-<pathHash>, one
# orphan per worktree. Separate from the Debug build cache so Release and Debug
# configurations don't invalidate each other's incremental state.
if [[ -n "${KG_IOS_RELEASE_DERIVED_DATA_ROOT:-}" ]]; then
  DERIVED_DATA_ROOT="$KG_IOS_RELEASE_DERIVED_DATA_ROOT"
else
  GIT_COMMON_DIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$GIT_COMMON_DIR" && -d "$GIT_COMMON_DIR" ]]; then
    DERIVED_DATA_ROOT="$(dirname "$GIT_COMMON_DIR")/.cache/ios-release-derived-data"
  else
    DERIVED_DATA_ROOT="$ROOT/.cache/ios-release-derived-data"
  fi
fi
BUILD_DIR="$ROOT/ios/build"
ARCHIVE="$BUILD_DIR/BooksAndVocab.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

[[ -d "$XCODEPROJ" ]] || { echo "✗ not found: $XCODEPROJ" >&2; exit 1; }
[[ -f "$EXPORT_OPTS" ]] || { echo "✗ not found: $EXPORT_OPTS" >&2; exit 1; }

auth=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER_ID")

# asc() 錯誤透出通道（對齊 asc.sh）：呼叫端以 2>/dev/null 壓 codemagic 進度噪音時，
# API 層錯誤（如 403 agreement 未簽）不得被同一個重導吞成「無輸出 exit 1」。
exec 3>&2

asc() {  # codemagic CLI wrapper（uvx，免 fastlane/ruby）
  # stderr 全量捕捉：成功時丟棄（進度噪音），失敗時去 ANSI 後透出 fd3 並保留非零 exit。
  local _asc_err rc=0
  _asc_err="$(mktemp)"
  uvx --from codemagic-cli-tools app-store-connect "$@" \
    --issuer-id "$ISSUER_ID" --key-id "$KEY_ID" \
    2>"$_asc_err" || rc=$?
  if (( rc != 0 )); then
    {
      echo "✗ ASC API 失敗（app-store-connect ${1:-?}，exit ${rc}）："
      sed $'s/\x1b\\[[0-9;]*m//g' "$_asc_err" | grep . | tail -n 5 | sed 's/^/  /' || true
      if grep -qi 'required agreement is missing or has expired' "$_asc_err"; then
        echo "  → 403 協議未簽/已過期：以 Account Holder 登入 App Store Connect GUI"
        echo "    （首頁橫幅或 Business → Agreements）簽署最新協議後重試。"
      fi
    } >&3
  fi
  rm -f "$_asc_err"
  return "$rc"
}

# Truthful top-level verdict: the label must be DERIVED from the stage evidence,
# never asserted next to it. Until 2026-08-03 the export- and upload-failure
# paths passed a literal "ok"/"0" while the process exited non-zero, so an agent
# reading only the JSON saw a green release. Same shape as ios_test.sh's
# `prepared` label before febc68ebb.
ios_release_verdict_status() {
  local archive="$1" export="$2" upload="$3"
  case "fail" in
    "$archive"|"$export"|"$upload") printf 'fail\n'; return 0 ;;
  esac
  printf 'ok\n'
}

write_json_verdict() {
  local exit_code="$1" archive_status="$2" export_status="$3" upload_status="$4"
  local status
  status="$(ios_release_verdict_status "$archive_status" "$export_status" "$upload_status")"
  # Exit code and verdict are two views of one fact; disagreement means a caller
  # got it wrong, so fail closed rather than emit a self-contradicting document.
  if [[ "$status" == "ok" && "$exit_code" != "0" ]]; then
    status="fail"
  fi
  jq -nc \
    --arg schema "kg.ios.archive.v1" \
    --arg status "$status" \
    --arg exit "$exit_code" \
    --arg caller "$CALLER" \
    --arg cwd "$ROOT" \
    --arg verdictFile "$VERDICT_FILE" \
    --argjson ts "$(date +%s)" \
    --argjson pid "$$" \
    --arg keyId "$KEY_ID" \
    --arg archivePath "$ARCHIVE" \
    --arg archiveLog "$ARCHIVE_LOG" \
    --arg archiveXcresult "$RESULT_BUNDLE" \
    --arg archiveStatus "$archive_status" \
    --arg archiveElapsed "${ARCHIVE_ELAPSED:-}" \
    --arg exportDir "$EXPORT_DIR" \
    --arg ipa "${IPA:-}" \
    --arg exportStatus "$export_status" \
    --arg uploadStatus "$upload_status" \
    --arg sentryDsyms "$SENTRY_DSYMS_STATUS" \
    --argjson uploadRequested "$DO_UPLOAD" \
    --argjson lockWaitMs "$LOCK_WAIT_MS" \
    --argjson archiveMs "$ARCHIVE_MS" \
    --argjson exportMs "$EXPORT_MS" \
    --argjson uploadMs "$UPLOAD_MS" \
    --argjson totalMs "$TOTAL_MS" \
    '{
      schema:$schema,
      status:$status,
      exit:$exit,
      caller:$caller,
      invocation:{ts:$ts,pid:$pid,cwd:$cwd,verdictFile:$verdictFile},
      options:{
        keyId:$keyId,
        uploadRequested:($uploadRequested == 1)
      },
      archive:{
        status:$archiveStatus,
        elapsed:(if $archiveElapsed == "" then null else ($archiveElapsed + "s") end),
        path:(if $archivePath == "" then null else $archivePath end),
        log:(if $archiveLog == "" then null else $archiveLog end),
        xcresult:(if $archiveXcresult == "" then null else $archiveXcresult end)
      },
      export:{
        status:$exportStatus,
        directory:(if $exportDir == "" then null else $exportDir end),
        ipa:(if $ipa == "" then null else $ipa end)
      },
      upload:{
        status:$uploadStatus,
        requested:($uploadRequested == 1),
        completed:($uploadStatus == "ok")
      },
      sentry:{dsyms:$sentryDsyms},
      timings:{
        lockWaitMs:$lockWaitMs,
        archiveMs:$archiveMs,
        exportMs:$exportMs,
        uploadMs:$uploadMs,
        totalMs:$totalMs
      },
      artifacts:{
        log:(if $archiveLog == "" then null else $archiveLog end),
        xcresult:(if $archiveXcresult == "" then null else $archiveXcresult end),
        archive:(if $archivePath == "" then null else $archivePath end),
        exportDirectory:(if $exportDir == "" then null else $exportDir end),
        ipa:(if $ipa == "" then null else $ipa end)
      }
    }' >"$VERDICT_JSON_FILE" || true
  type append_run_metric >/dev/null 2>&1 && append_run_metric "$VERDICT_JSON_FILE"
  kg_ios_verdict_publish
}

# ---- build number guard（僅上傳前；archive 不受限但傳會被 Apple 拒重）----
guard_build_number() {
  local local_build latest_tf
  # 保留 -target（非 -scheme）：版號 2026-08 提升到 project level 後，「-scheme 會混入
  # Tests target 的 1」這個 hazard 已經不存在了，但 -target 仍然是對的選擇——它不依賴
  # scheme 由哪些 target 組成，所以日後有人改 scheme 組成也不會動到這裡的答案。別「簡化」成 -scheme。
  local_build="$(xcodebuild -project "$XCODEPROJ" -target "$SCHEME" \
      -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}' | tr -d '[:space:]')"
  latest_tf="$(asc get-latest-testflight-build-number "$APP_ID" --platform IOS 2>/dev/null | tail -1 | tr -d '[:space:]')"
  echo "[release] local build=$local_build  TestFlight latest=$latest_tf"
  if [[ -n "$local_build" && -n "$latest_tf" && "$local_build" =~ ^[0-9]+$ && "$latest_tf" =~ ^[0-9]+$ ]]; then
    if (( local_build <= latest_tf )); then
      echo "✗ build $local_build 已存在於 TestFlight（latest=${latest_tf}）。先 bump CURRENT_PROJECT_VERSION 再 --upload。" >&2
      exit 1
    fi
  fi
}

# ---- Sentry dSYM upload（best-effort）----
# 只在 --upload：唯有要出貨的 archive 才需要讓 Sentry 能符號化它的 native crash；預設的
# archive+export 維持「無對外副作用」。uploader 選型（pinned sentry-cli via uvx）與時間上限
# 見 ops/sentry_release.sh。這一步**永遠 return 0**：dSYM 缺席的代價是之後的 crash 未符號化，
# 不值得擋住一次 TestFlight 上傳；狀態寫進 JSON verdict 的 sentry.dsyms，不參與頂層 status。
upload_sentry_dsyms() {
  local archive="$1" helper="${KG_SENTRY_RELEASE:-$SCRIPT_DIR/sentry_release.sh}" rc=0
  if [[ ! -x "$helper" ]]; then
    SENTRY_DSYMS_STATUS="skipped"
    echo "[release] ⚠ SKIP Sentry dSYM upload: $helper not found" >&2
    return 0
  fi
  "$helper" upload-dsyms "$archive/dSYMs" || rc=$?
  case "$rc" in
    0) SENTRY_DSYMS_STATUS="ok"; echo "[release] ✓ dSYMs uploaded to Sentry" ;;
    3) SENTRY_DSYMS_STATUS="skipped"
       echo "[release] ⚠⚠ SKIP Sentry dSYM upload — native crashes from this build will arrive UNSYMBOLICATED (reason above; docs/sop/deploy.md §Sentry)" >&2 ;;
    *) SENTRY_DSYMS_STATUS="fail"
       echo "[release] ⚠ Sentry dSYM upload failed (exit $rc); release continues" >&2 ;;
  esac
  return 0
}

# ---- lock acquire（shlock spin-wait，對齊 ios_build.sh）----
CALLER="${WORKTREE_BRANCH:-$(git -C "$ROOT" branch --show-current 2>/dev/null || echo 'unknown')}"
cleanup() { kg_ios_release_shlock_if_owner "$LOCK_FILE" "$$"; }
START_TOTAL_MS="$(now_ms)"
echo "[release] caller=$CALLER waiting for lock..."
if ! kg_ios_wait_for_shlock "[release]" archive "$LOCK_FILE" "$$" "$TIMEOUT" "$POLL_INTERVAL"; then
  kg_ios_lock_timeout_die "[release]" archive "$ROOT" "$TIMEOUT"
fi
trap cleanup EXIT
LOCK_WAIT_MS="$(( $(now_ms) - START_TOTAL_MS ))"
echo "[release] lock acquired by $CALLER (pid=$$)"

# The archive and export paths are replace-on-run artifacts. Remove the prior
# generation before measuring the next writer's budget, matching the cleanup
# that previously happened immediately before each individual stage.
rm -rf "$ARCHIVE" "$EXPORT_DIR"

preflight_rc=0
kg_ios_disk_budget_preflight "$ROOT" "release" || preflight_rc=$?
if (( preflight_rc != 0 )); then
  kg_ios_disk_budget_blocked_hint "[release]" "$preflight_rc"
  exit "$preflight_rc"
fi

[[ $DO_UPLOAD -eq 1 ]] && guard_build_number

# ---- archive ----
echo "[release] ▶ archive ($CONFIGURATION) — key=$KEY_ID …"
mkdir -p "$BUILD_DIR"
START_ARCHIVE=$(date +%s)
START_ARCHIVE_MS="$(now_ms)"
ARCHIVE_LOG="$(mktemp "${TMPDIR:-/tmp}/kg_ios_release_archive.XXXXXX").log"
RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kg_ios_release_result.XXXXXX")"
RESULT_BUNDLE="$RESULT_DIR/Archive.xcresult"
set +e
# Compile-progress monitor: archive compiles the whole app, so the same
# SwiftCompile-counting monitor used by ios_build.sh applies. Baseline is
# release-specific (Release config differs from Debug build counts).
ARCHIVE_BASELINE="$DERIVED_DATA_ROOT/kg_archive.events_baseline"
ARCHIVE_MONITOR_PID=$(start_build_monitor "$ARCHIVE_LOG" "$ARCHIVE_BASELINE" "[release][archive]" "$START_ARCHIVE")
xcodebuild archive \
  -project "$XCODEPROJ" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED_DATA_ROOT" \
  -resultBundlePath "$RESULT_BUNDLE" \
  "${auth[@]}" \
  >"$ARCHIVE_LOG" 2>&1
ARCHIVE_EXIT=$?
kill "$ARCHIVE_MONITOR_PID" 2>/dev/null || true
wait "$ARCHIVE_MONITOR_PID" 2>/dev/null || true
set -e
if [[ $ARCHIVE_EXIT -eq 0 ]]; then
  _ac=$(count_compile_events "$ARCHIVE_LOG")
  [[ "$_ac" -gt 0 ]] && echo "$_ac" > "$ARCHIVE_BASELINE"
fi
ARCHIVE_ELAPSED=$(( $(date +%s) - START_ARCHIVE ))
ARCHIVE_MS="$(( $(now_ms) - START_ARCHIVE_MS ))"
DIAGNOSTICS="$SCRIPT_DIR/ios_diagnostics.py"
if [[ -x "$DIAGNOSTICS" ]]; then
  diag_result="fail"; [[ $ARCHIVE_EXIT -eq 0 ]] && diag_result="pass"
  "$DIAGNOSTICS" --xcresult "$RESULT_BUNDLE" --log "$ARCHIVE_LOG" --result "$diag_result" --limit 40 || true
else
  echo "[release] diagnostics unavailable: $DIAGNOSTICS" >&2
fi
if [[ $ARCHIVE_EXIT -ne 0 ]]; then
  echo "RESULT=fail EXIT=$ARCHIVE_EXIT caller=$CALLER archive=$ARCHIVE log=$ARCHIVE_LOG xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
  write_json_verdict "$ARCHIVE_EXIT" "fail" "skipped" "skipped"
  echo "[release] ✗ archive failed (exit $ARCHIVE_EXIT, ${ARCHIVE_ELAPSED}s) log=$ARCHIVE_LOG xcresult=$RESULT_BUNDLE" >&2
  exit "$ARCHIVE_EXIT"
fi
echo "RESULT=ok EXIT=0 caller=$CALLER archive=$ARCHIVE log=$ARCHIVE_LOG xcresult=$RESULT_BUNDLE $(kg_ios_verdict_commit_kv "$ROOT") $(kg_ios_verdict_identity_kv)" > "$VERDICT_FILE"
echo "[release] ✓ archive succeeded (${ARCHIVE_ELAPSED}s) log=$ARCHIVE_LOG xcresult=$RESULT_BUNDLE"
if [[ $DO_UPLOAD -eq 1 ]]; then
  upload_sentry_dsyms "$ARCHIVE"
fi

# ---- export ipa ----
# manual signing（ExportOptions 指定 Apple Distribution + "KG App Store" profile，均已本機就緒）。
# 不帶 -allowProvisioningUpdates／auth：避免觸發 cloud-signing（現用 App Manager key 權限不足）。
echo "[release] ▶ export ipa …"
START_EXPORT_MS="$(now_ms)"
EXPORT_LOG="$(mktemp "${TMPDIR:-/tmp}/kg_ios_release_export.XXXXXX").log"
set +e
EXPORT_MONITOR_PID=$(start_tick_monitor "$EXPORT_LOG" "[release][export]" "$(date +%s)")
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  >"$EXPORT_LOG" 2>&1
EXPORT_EXIT=$?
kill "$EXPORT_MONITOR_PID" 2>/dev/null || true
wait "$EXPORT_MONITOR_PID" 2>/dev/null || true
set -e
if [[ $EXPORT_EXIT -ne 0 ]]; then
  cat "$EXPORT_LOG" >&2
  TOTAL_MS="$(( $(now_ms) - START_TOTAL_MS ))"
  write_json_verdict "$EXPORT_EXIT" "ok" "fail" "skipped"
  echo "[release] ✗ export failed (exit $EXPORT_EXIT) log=$EXPORT_LOG" >&2
  exit "$EXPORT_EXIT"
fi
shopt -s nullglob; ipas=("$EXPORT_DIR"/*.ipa); shopt -u nullglob
IPA="${ipas[0]:-}"
EXPORT_MS="$(( $(now_ms) - START_EXPORT_MS ))"
if [[ -z "$IPA" ]]; then
  TOTAL_MS="$(( $(now_ms) - START_TOTAL_MS ))"
  write_json_verdict "1" "ok" "fail" "skipped"
  echo "✗ export 未產出 .ipa" >&2
  exit 1
fi
echo "[release] ✓ ipa: $IPA"

# ---- upload（對外副作用，需 --upload 明示）----
if [[ $DO_UPLOAD -eq 1 ]]; then
  echo "[release] ▶ upload → App Store Connect (TestFlight) …"
  START_UPLOAD_MS="$(now_ms)"
  # altool emits nothing until it finishes — keep-alive tick so the upload
  # doesn't look hung. Output is captured to a log and printed when done.
  UPLOAD_LOG="$(mktemp "${TMPDIR:-/tmp}/kg_ios_release_upload.XXXXXX").log"
  set +e
  UPLOAD_MONITOR_PID=$(start_tick_monitor "$UPLOAD_LOG" "[release][upload]" "$(date +%s)")
  xcrun altool --upload-app -f "$IPA" --type ios \
    --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID" \
    >"$UPLOAD_LOG" 2>&1
  UPLOAD_EXIT=$?
  kill "$UPLOAD_MONITOR_PID" 2>/dev/null || true
  wait "$UPLOAD_MONITOR_PID" 2>/dev/null || true
  set -e
  cat "$UPLOAD_LOG"
  UPLOAD_MS="$(( $(now_ms) - START_UPLOAD_MS ))"
  TOTAL_MS="$(( $(now_ms) - START_TOTAL_MS ))"
  if [[ $UPLOAD_EXIT -ne 0 ]]; then
    write_json_verdict "$UPLOAD_EXIT" "ok" "ok" "fail"
    echo "[release] ✗ upload failed (exit $UPLOAD_EXIT) log=$UPLOAD_LOG" >&2
    exit "$UPLOAD_EXIT"
  fi
  write_json_verdict "0" "ok" "ok" "ok"
  echo "[release] ✓ uploaded — 數分鐘後於 TestFlight 顯示，processing 完才可送審"
else
  TOTAL_MS="$(( $(now_ms) - START_TOTAL_MS ))"
  write_json_verdict "0" "ok" "ok" "skipped"
  echo "[release] 完成 archive+export（未上傳）。要上 TestFlight 加 --upload。"
fi
