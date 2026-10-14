#!/usr/bin/env bash
# test_ios_release.sh — ios_release.sh 結構/行為驗證（不啟 xcodebuild；對齊 test_asc.sh 慣例）
# dogfood C：補 -h/--help guard + --key/--timeout 取值守衛的回歸鎖。
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
IR="$WORKSPACE/ops/ios_release.sh"
PROGRESS_LIB="$WORKSPACE/ops/lib/ios_build_progress.sh"

pass=0; fail=0
ok()     { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t() { echo "  ✗ $*"; fail=$((fail+1)); }
section(){ echo ""; echo "── $* ──"; }

# ── 1. Syntax ───────────────────────────────────────────────────────────────
section "Syntax"
[[ -f "$IR" ]] && ok "ios_release.sh exists" || fail_t "ios_release.sh missing"
bash -n "$IR"  && ok "ios_release.sh syntax" || fail_t "ios_release.sh syntax error"

# ── 2. -h/--help 存在且不啟 archive（dogfood C：裸跑直接 xcodebuild archive 的 footgun） ──
section "Help guard (no accidental archive)"
grep -qE '\-h\|--help\)' "$IR" \
  && ok "has -h/--help case"               || fail_t "no -h/--help guard"
# 在 set -e 下，substitution 失敗會中止腳本，故 rc 另用 if 捕捉（避免 help_rc=$? 成死碼）
if help_out="$(bash "$IR" --help 2>&1)"; then ok "--help exits 0 (no xcodebuild)"; else fail_t "--help non-zero exit"; fi
grep -q 'Usage' <<< "$help_out" \
  && ok "--help prints Usage"              || fail_t "--help missing Usage text"
grep -qE 'set -euo pipefail|^SCHEME=|^TEAM_ID=' <<< "$help_out" \
  && fail_t "help leaks shell code"        || ok "help is comment-only (no shell code leak)"

# ── 3. 取值型選項守衛（dogfood C：--key/--timeout 後無值不該 set -u unbound） ──
section "Value-taking options guarded"
grep -q 'need_val' "$IR" \
  && ok "has need_val guard"               || fail_t "missing need_val guard"
kv_out="$(bash "$IR" --key 2>&1 || true)"
grep -q '需要一個值' <<< "$kv_out" \
  && ok "--key with no value → friendly error" || fail_t "--key no-value not friendly (got: $kv_out)"
grep -qi 'unbound variable' <<< "$kv_out" \
  && fail_t "--key no-value still hits set -u unbound" \
  || ok "no set -u unbound crash on missing value"

# ── 4. 對外副作用仍 gated（--upload 才上傳；archive 本身無對外副作用） ────────
section "Upload stays opt-in"
grep -q -- '--upload' "$IR" \
  && ok "upload is an explicit opt-in flag" || fail_t "missing --upload flag"
grep -qE 'DO_UPLOAD=0' "$IR" \
  && ok "DO_UPLOAD defaults off"            || fail_t "DO_UPLOAD not defaulting off"

# ── 5. archive diagnostics：保留 log + .xcresult，第一屏列 warning/error ──────
section "Archive diagnostics"
grep -q -- '-resultBundlePath' "$IR" \
  && ok "archive emits xcresult bundle"       || fail_t "archive missing -resultBundlePath"
grep -q 'kg_ios_release_archive.*log' "$IR" \
  && ok "archive preserves raw log path"      || fail_t "archive missing raw log path"
grep -q 'ios_diagnostics.py' "$IR" \
  && ok "archive calls diagnostics parser"    || fail_t "archive missing diagnostics parser"
grep -q -- '--xcresult' "$IR" && grep -q -- '--log' "$IR" \
  && ok "archive feeds xcresult + log to diagnostics" || fail_t "archive diagnostics missing xcresult/log"

# ── 6. upload diagnostics：altool 長時間無輸出時仍有 keep-alive tick ───────
section "Upload diagnostics"
grep -q 'kg_ios_release_upload.*log' "$IR" \
  && ok "upload preserves raw log path"      || fail_t "upload missing raw log path"
grep -q 'start_tick_monitor "$UPLOAD_LOG" "\[release\]\[upload\]"' "$IR" \
  && ok "upload starts keep-alive monitor"   || fail_t "upload missing keep-alive monitor"
grep -q 'UPLOAD_EXIT=\$?' "$IR" && grep -q 'upload failed (exit \$UPLOAD_EXIT)' "$IR" \
  && ok "upload captures and reports altool exit code" || fail_t "upload exit handling missing"
# NB: this used to pin the literal `write_json_verdict "ok" "0" "ok" "ok" "fail"`,
# i.e. it held the false green in place as a contract. Assert the stage evidence
# and the real exit code instead; the top-level label is derived (see below).
grep -q 'write_json_verdict "\$UPLOAD_EXIT" "ok" "ok" "fail"' "$IR" \
  && ok "upload failure writes machine-readable verdict with the real exit code" \
  || fail_t "upload failure verdict missing"
tick_probe="$(
  perl -e 'alarm 5; exec @ARGV' bash -lc '
    source "'"$PROGRESS_LIB"'"
    log="$(mktemp "${TMPDIR:-/tmp}/kg_ios_tick_probe.XXXXXX.log")"
    pid="$(start_tick_monitor "$log" "[probe]" "$(date +%s)")"
    printf "pid=%s\n" "$pid"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  ' 2>/dev/null
)"
grep -qE '^pid=[0-9]+$' <<< "$tick_probe" \
  && ok "upload tick monitor returns PID from command substitution" || fail_t "upload tick monitor command substitution hung/failed: $tick_probe"

# ── Verdict must be derived from stage evidence, never asserted beside it ────
# 2026-08-03: :310 and :345 wrote top-level status:"ok" / exit:"0" on the
# export-failure and upload-failure paths while the process exited non-zero.
# An agent reading only the JSON saw a green release. Same failure shape as
# ios_test.sh's `prepared` label before febc68ebb: a label asserted independently
# of the evidence it claims to summarise.
section "Archive verdict derives status from stage evidence"

grep -qE '^ios_release_verdict_status\(\)' "$IR" \
  && ok "has a status-deriving seam" \
  || fail_t "no ios_release_verdict_status() — status is asserted per call site and can drift from the stages"

# Truth table, exercised against the real function body.
_derive() { bash -c "$(sed -n '/^ios_release_verdict_status()/,/^}/p' "$IR"); ios_release_verdict_status $*"; }
if grep -qE '^ios_release_verdict_status\(\)' "$IR"; then
  [[ "$(_derive ok ok ok)"        == "ok"   ]] && ok "all stages ok → ok"           || fail_t "all-ok did not derive ok"
  [[ "$(_derive ok ok skipped)"   == "ok"   ]] && ok "skipped upload → ok"          || fail_t "skipped upload did not derive ok"
  [[ "$(_derive ok fail skipped)" == "fail" ]] && ok "export fail → fail"           || fail_t "export failure did not derive fail"
  [[ "$(_derive ok ok fail)"      == "fail" ]] && ok "upload fail → fail"           || fail_t "upload failure did not derive fail"
  [[ "$(_derive fail skipped skipped)" == "fail" ]] && ok "archive fail → fail"     || fail_t "archive failure did not derive fail"
fi

# No call site may hand-assert a top-level status alongside a failing stage.
if grep -nE 'write_json_verdict +"(ok|fail)"' "$IR" | grep -q .; then
  fail_t "write_json_verdict still takes a literal top-level status: $(grep -cE 'write_json_verdict +"(ok|fail)"' "$IR") call site(s)"
else
  ok "no call site hand-asserts the top-level status"
fi

# The recorded exit must match the stage verdict, both directions.
if grep -qE 'write_json_verdict +"(ok)" +"0" +"[a-z]+" +"fail"' "$IR" \
   || grep -qE 'write_json_verdict +"(ok)" +"0" +"fail"' "$IR"; then
  fail_t "a call site records exit 0 together with a failing stage"
else
  ok "no call site records exit 0 alongside a failing stage"
fi

# ── Sentry dSYM upload：best-effort，只在 --upload，永不讓 release 失敗（#2078） ──
# 行為測試：抽出真函式 + 真 ops/sentry_release.sh，只把最底層 uploader 換成 fake。
section "Sentry dSYM upload (fake uploader)"
grep -qE '^upload_sentry_dsyms\(\)' "$IR" \
  && ok "has upload_sentry_dsyms()" || fail_t "no upload_sentry_dsyms() seam"
DS_TMP="$(mktemp -d)"
mkdir -p "$DS_TMP/BooksAndVocab.xcarchive/dSYMs/BooksAndVocab.app.dSYM/Contents"
cat >"$DS_TMP/fake_cli.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
[[ "${FAKE_MODE:-ok}" == ok ]]
FAKE
chmod +x "$DS_TMP/fake_cli.sh"
_dsym() {  # $1 = case name, rest = env assignments
  local name="$1"; shift
  env -i HOME="$DS_TMP" PATH="/usr/bin:/bin" SENTRY_ENV_FILE="$DS_TMP/none.env" \
    KG_SENTRY_CLI="$DS_TMP/fake_cli.sh" FAKE_LOG="$DS_TMP/$name.log" "$@" \
    bash -c 'set -euo pipefail
      SCRIPT_DIR="$1"
      eval "$(sed -n "/^upload_sentry_dsyms()/,/^}/p" "$2")"
      upload_sentry_dsyms "$3"
      echo "STATUS=$SENTRY_DSYMS_STATUS"' _ "$WORKSPACE/ops" "$IR" "$DS_TMP/BooksAndVocab.xcarchive" \
    >"$DS_TMP/$name.out" 2>"$DS_TMP/$name.err"
}
CFG=(SENTRY_AUTH_TOKEN=sntrys_fakeTOKEN0123456789 SENTRY_ORG=kg SENTRY_PROJECT_IOS=kg-ios)
if _dsym ok "${CFG[@]}"; then ok "uploaded path returns 0"; else fail_t "uploaded path non-zero"; fi
grep -q 'STATUS=ok' "$DS_TMP/ok.out" && ok "status ok recorded" || fail_t "status: $(cat "$DS_TMP/ok.out")"
grep -q -- "debug-files upload --org kg --project kg-ios --type dsym $DS_TMP/BooksAndVocab.xcarchive/dSYMs" "$DS_TMP/ok.log" \
  && ok "fake uploader received the archive's dSYMs/" || fail_t "uploader argv: $(cat "$DS_TMP/ok.log" 2>/dev/null)"
if _dsym notoken SENTRY_ORG=kg SENTRY_PROJECT_IOS=kg-ios; then ok "missing token does not fail the release"; else fail_t "missing token returned non-zero"; fi
grep -q 'STATUS=skipped' "$DS_TMP/notoken.out" && grep -q 'SKIP' "$DS_TMP/notoken.err" \
  && grep -q 'SENTRY_AUTH_TOKEN' "$DS_TMP/notoken.err" \
  && ok "missing token → loud SKIP naming SENTRY_AUTH_TOKEN" || fail_t "notoken: $(cat "$DS_TMP/notoken.out" "$DS_TMP/notoken.err")"
[[ ! -s "$DS_TMP/notoken.log" ]] && ok "missing token → uploader never runs" || fail_t "uploader ran without a token"
if _dsym fails "${CFG[@]}" FAKE_MODE=fail; then ok "uploader failure does not fail the release"; else fail_t "uploader failure returned non-zero"; fi
grep -q 'STATUS=fail' "$DS_TMP/fails.out" && ok "uploader failure recorded as status fail" || fail_t "fails: $(cat "$DS_TMP/fails.out")"
rm -rf "$DS_TMP"

# 呼叫點：只有 --upload（要出貨的 archive）才上傳，且在 archive 成功之後、export 之前。
archive_ok_line="$(grep -n 'archive succeeded' "$IR" | head -1 | cut -d: -f1 || true)"
call_line="$(grep -nE '^[[:space:]]*upload_sentry_dsyms "\$ARCHIVE"' "$IR" | head -1 | cut -d: -f1 || true)"
export_line="$(grep -n '▶ export ipa' "$IR" | head -1 | cut -d: -f1 || true)"
[[ -n "$call_line" && "$call_line" -gt "$archive_ok_line" && "$call_line" -lt "$export_line" ]] \
  && ok "dSYM upload runs after a successful archive, before export" || fail_t "call site order archive=$archive_ok_line call=$call_line export=$export_line"
sed -n "$((call_line-2)),${call_line}p" "$IR" | grep -q 'DO_UPLOAD' \
  && ok "dSYM upload is gated by --upload" || fail_t "dSYM upload not gated by DO_UPLOAD"
grep -q 'sentry:{dsyms:\$sentryDsyms}' "$IR" \
  && ok "JSON verdict records sentry.dsyms" || fail_t "verdict missing sentry.dsyms"
grep -q 'SENTRY_DSYMS_STATUS="not-requested"' "$IR" \
  && ok "default dSYM status is not-requested" || fail_t "missing not-requested default"

# ── 結果 ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
