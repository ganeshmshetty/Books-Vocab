#!/usr/bin/env bash
# test_devops.sh — devops 腳本結構與行為驗證
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
KG="$WORKSPACE/devops.sh"

# ── Hermetic by construction (P0 2026-10-09) ────────────────────────────────
# This file once ran a "must be blocked" negative control against the *real*
# base devops.sh; the guard had a hole, the command was forwarded over ssh to
# production felix and deleted the live data dir.  Two independent seals now:
#   1. harness: KG_OPS_TEST=1 + PATH shim (ssh/scp/sftp/rsync/aws → exit 97) +
#      deny-stub transport seams.  Standalone runs get it from here; under
#      ops/test_ops.sh it is already set (init is idempotent).
#   2. base: KG_DEVOPS_BASE defaults to a *recording* stub.  Every wrapper
#      invocation below that does not name its own base ends here, so "blocked"
#      is provable as "never reached base" (see expect_blocked_before_base).
# Tests that need the real devops.sh logic pass KG_DEVOPS_BASE="$KG" explicitly
# together with a fake KG_SSH_CMD transport.
# shellcheck source=lib/hermetic_ops_test.sh
source "$WORKSPACE/ops/lib/hermetic_ops_test.sh"
hermetic_ops_test_init "$WORKSPACE"
HERMETIC_TMP="$(mktemp -d)"
trap 'rm -rf "$HERMETIC_TMP"' EXIT
BASE_TRACE="$HERMETIC_TMP/base.trace"
export KG_BASE_TRACE="$BASE_TRACE"
cat > "$HERMETIC_TMP/recording_base.sh" <<'RECORDER'
#!/usr/bin/env bash
# Stub base: append argv to the trace file, never execute anything.
printf '%s\n' "$*" >> "$KG_BASE_TRACE"
exit 0
RECORDER
chmod +x "$HERMETIC_TMP/recording_base.sh"
export KG_DEVOPS_BASE="$HERMETIC_TMP/recording_base.sh"
: > "$BASE_TRACE"

pass=0; fail=0

ok()      { echo "  ✓ $*"; pass=$((pass+1)); }
fail_t()  { echo "  ✗ $*"; fail=$((fail+1)); }

section() { echo ""; echo "── $* ──"; }

# ── 1. Syntax ──────────────────────────────────────────────────────────────
section "Syntax"
bash -n "$KG"    && ok "KG syntax"    || fail_t "KG syntax"

# ── 2. SSH array 結構 ──────────────────────────────────────────────────────
section "SSH array (no string concatenation)"
grep -q 'SSH_OPTS=(' "$KG"    && ok "KG SSH_OPTS array"    || fail_t "KG SSH_OPTS array"
grep -q 'SSH_CMD=('  "$KG"    && ok "KG SSH_CMD array"     || fail_t "KG SSH_CMD array"
grep -q 'SCP_CMD=('  "$KG"    && ok "KG SCP_CMD array"     || fail_t "KG SCP_CMD array"
grep -q 'KG_SCP_CMD' "$KG"    && ok "KG SCP test seam"     || fail_t "KG SCP test seam missing"
! grep -qE '^SSH_CMD="' "$KG"    && ok "KG no bare SSH_CMD string"    || fail_t "KG bare SSH_CMD string found"

# ── 3. 函式名稱一致 ────────────────────────────────────────────────────────
section "Function naming consistency"
grep -q 'run_remote()' "$KG"             && ok "KG run_remote()"             || fail_t "KG run_remote() missing"
grep -q 'preflight()'  "$KG"             && ok "KG preflight()"              || fail_t "KG preflight() missing"
grep -q 'require_local_files()' "$KG"    && ok "KG require_local_files()"    || fail_t "KG require_local_files() missing"
! grep -q 'rssh'            "$KG" && ok "KG no legacy rssh"            || fail_t "KG legacy rssh found"
! grep -q 'preflight_check' "$KG" && ok "KG no legacy preflight_check" || fail_t "KG legacy preflight_check found"

# ── 4. Deploy pipeline 結構 ────────────────────────────────────────────────
section "Deploy pipeline"
# 2026-06-15 遷 standby 起 deploy 不再自動備份（備份走 launchd com.kg.backup 自己的
# 排程，見 docs/sop/deploy.md §標準部署流程）。這裡原本斷言「deploy calls cmd_backup」，
# 而它是被 devops.sh:594 的**函式定義**滿足的——全檔 grep 分不出定義與呼叫，所以語意
# 整個反轉之後它照樣是綠的。改成對 cmd_deploy 函式範圍的斷言，兩個方向才都測得到。
awk '/^cmd_deploy\(\)/,/^}$/' "$KG" | grep -q 'cmd_backup' \
  && fail_t "KG deploy runs a backup inline — that moved to the com.kg.backup schedule" \
  || ok "KG deploy does not back up inline (scheduled separately)"
grep -q 'for i in $(seq 1' "$KG"    && ok "KG health retry loop"    || fail_t "KG health retry loop missing"
grep -q 'local http_code'  "$KG"    && ok "KG http_code variable"    || fail_t "KG http_code variable missing"
grep -q -- "--exclude='_ops_backups/'" "$KG" \
  && grep -q -- "--exclude='_ops_world_backups/'" "$KG" \
  && ok "KG backup excludes nested ops backup trees" \
  || fail_t "KG backup should exclude nested ops backup trees"
# 這裡原本是對 "$KG" 的**全檔** grep --info=progress2 / --human-readable。加了 rsync
# flavor 分流之後那兩個字面值仍然出現在 devops.sh（在 rsync_progress_flags 的 printf
# 那行），所以舊斷言不會轉紅——它會靜靜變成空話，不再證明備份呼叫點會顯示進度。失敗
# 模式同 :37-43 的註解。改成「注入 version 字串 → 純函式輸出」的行為斷言 + 對
# cmd_backup 函式範圍的呼叫點斷言。
# devops.sh 以 DEVOPS_SOURCE_ONLY=1 提供受支援的 source-only 邊界；測試直接載入
# 生產函式，不再以 awk 擷取文字片段（那會把函式依賴與行為拆斷）。
rsync_flags() {
  DEVOPS_SOURCE_ONLY=1 KG_SSH_CMD=/usr/bin/true bash -c \
    'source "$1"; rsync_progress_flags "$2"' _ "$KG" "$1"
}
[[ "$(rsync_flags 'openrsync: protocol version 29')" == '--progress' ]] \
  && ok "KG backup picks --progress on openrsync" \
  || fail_t "KG backup picks --progress on openrsync"
[[ "$(rsync_flags 'rsync  version 3.3.0  protocol version 31' | tr '\n' '|')" == '--info=progress2|--human-readable|' ]] \
  && ok "KG backup picks --info=progress2 --human-readable on GNU rsync" \
  || fail_t "KG backup picks --info=progress2 --human-readable on GNU rsync"
_backup_body=$(awk '/^cmd_backup\(\)/,/^}$/' "$KG")
# grep -c 零命中時 exit 1，而本檔 :3 是 set -euo pipefail → 兩處 || true 不可省。
# 兩半缺一不可：只驗「不含 --info=progress2」會在 cmd_backup 被改名或刪掉時假綠，
# progress_flags[@] 那半是正控，證明看的是真的新呼叫點。
if [[ "$(printf '%s' "$_backup_body" | grep -c -- 'progress_flags\[@\]' || true)" == 1 \
   && "$(printf '%s' "$_backup_body" | grep -c -- '--info=progress2' || true)" == 0 ]]; then
  ok "KG backup call site no longer hardcodes rsync progress flags"
else
  fail_t "KG backup call site no longer hardcodes rsync progress flags"
fi
# IMP-20260806-02bf8d：rsync 失敗過去只留下 rsync 自己印的 usage，前兩行 preflight 與
# 「▶ 本地冷快照」看起來像開始工作了，很容易被讀成「跑完了」。備份指令不得用「印出
# usage」當失敗訊號 → 呼叫點必須守住 rsync 的非零退出，並具名指向 standby 的每日 S3
# 備份（launchd com.kg.backup）。正控 = 守衛存在；指向性 = 訊息點名那條替代路徑。
# 指向性檢查必須**限縮在守衛區塊內**：cmd_backup 開頭本來就有一句提到 com.kg.backup
# 的註解，對整個函式範圍 grep 會被那句既有註解滿足——守衛留著但把訊息全刪掉照樣綠。
# 那正是本檔上方剛換掉的空話斷言換個位置復發。
# 再往下濾一層到「真的印給人看的行」（去註解 + 必須有 >&2），原因有二：
#   a) 註解同樣能滿足 grep（守衛裡新寫一句提到 com.kg.backup 的註解就假綠）；
#   b) $dest 若對整個守衛範圍 grep 會是**恆真式**——awk 範圍必然含 rsync 的目的地引數
#      那行 `"$SERVER:$REMOTE_DATA_DIR/" "$dest/"; then`，它已被第一個 conjunct 蘊含，
#      discriminating power 為零。濾掉不含 >&2 的行才真的在鎖「訊息點出了殘留目錄」。
_guard=$(printf '%s\n' "$_backup_body" | awk '/if ! rsync -az/,/^  fi$/')
_guard_msg=$(printf '%s\n' "$_guard" | grep -v '^[[:space:]]*#' | grep -F -- '>&2' || true)
if [[ "$(printf '%s' "$_backup_body" | grep -c -- 'if ! rsync -az' || true)" == 1 \
   && "$(printf '%s' "$_guard_msg" | grep -c -- 'com\.kg\.backup' || true)" -ge 1 \
   && "$(printf '%s' "$_guard_msg" | grep -cE -- '\$\{?dest\}?' || true)" -ge 1 ]]; then
  ok "KG backup names its own failure and points at the S3 daily backup"
else
  fail_t "KG backup names its own failure and points at the S3 daily backup"
fi
# 上面三條都是「注入 version 字串 → mapper 輸出」，沒有一條走**無參數**路徑，而那是
# 生產唯一的呼叫方式（cmd_backup 不帶參數呼叫 helper）。這條蓋住 probe 本身：無論本機
# 是哪種 flavor，都必須吐出非空旗標，否則 cmd_backup 會拿到空陣列。
[[ -n "$(rsync_flags '')" ]] \
  && ok "KG backup rsync flavor probe yields flags on this host" \
  || fail_t "KG backup rsync flavor probe yields flags on this host"
# 無參數 probe 曾是 `rsync --version | head -1`：devops.sh 是 pipefail，head 讀完首行就
# 關管，rsync 若還在寫就吃 SIGPIPE（141）→ 整支 source 被 set -e 殺掉，flags 變空。
# 真 rsync 的 --version 只有幾百位元組，所以只偶發；這裡用超過 pipe buffer 的 stub
# 輸出把那個時序釘成必然，證明 probe 不再經過會斷的管線。
_probe_bin=$(mktemp -d)
cat > "$_probe_bin/rsync" <<'STUB'
#!/bin/bash
echo "rsync  version 3.3.0  protocol version 31"
for _ in $(seq 1 20000); do echo "padding line that outgrows the pipe buffer"; done
STUB
chmod +x "$_probe_bin/rsync"
_probe_rc=0
_probe_out=$(PATH="$_probe_bin:$PATH" rsync_flags '' 2>&1) || _probe_rc=$?
[[ "$_probe_rc" -eq 0 && "$(printf '%s' "$_probe_out" | tr '\n' '|')" == '--info=progress2|--human-readable' ]] \
  && ok "KG backup rsync probe survives a --version longer than the pipe buffer" \
  || fail_t "KG backup rsync probe survives a --version longer than the pipe buffer (rc=$_probe_rc out=$_probe_out)"
rm -rf "$_probe_bin"
# 以上全是 grep-on-source，擋不住「訊息一字不動、只把結尾的 err 換成 echo」——那之後
# cmd_backup 會對空目錄繼續跑 integrity check + tar 然後 exit 0，正是 IMP-20260806-
# 02bf8d 的病本身（拿印訊息當失敗訊號）換皮。這條用 stub rsync 實跑一次失敗路徑，
# 斷 exit code 與磁碟產物，不看原始碼長相。全程本機離線，不碰生產。
_bk_sandbox=$(mktemp -d)
mkdir -p "$_bk_sandbox/bin" "$_bk_sandbox/backups"
cat > "$_bk_sandbox/bin/rsync" <<'STUB'
#!/bin/bash
[[ "${1:-}" == "--version" ]] && { echo "openrsync: protocol version 29"; exit 0; }
echo "rsync: unrecognized option --info=progress2" >&2
exit 1
STUB
chmod +x "$_bk_sandbox/bin/rsync"
{
  echo 'set -euo pipefail'
  printf 'DEVOPS_SOURCE_ONLY=1 KG_SSH_CMD=/usr/bin/true source %q\n' "$KG"
  echo "BACKUP_DIR='$_bk_sandbox/backups'; SERVER=stub-host; REMOTE_DATA_DIR=/stub"
  echo 'cmd_backup'
} > "$_bk_sandbox/run.sh"
_bk_rc=0
PATH="$_bk_sandbox/bin:$PATH" bash "$_bk_sandbox/run.sh" > "$_bk_sandbox/out" 2>&1 || _bk_rc=$?
if [[ "$_bk_rc" -ne 0 ]] \
   && grep -qF 'com.kg.backup' "$_bk_sandbox/out" \
   && [[ -z "$(find "$_bk_sandbox/backups" -name '*.tar.gz' 2>/dev/null)" ]] \
   && [[ -n "$(find "$_bk_sandbox/backups" -name '.INCOMPLETE' 2>/dev/null)" ]]; then
  ok "KG backup really exits non-zero on rsync failure, leaving no fake artifact"
else
  fail_t "KG backup really exits non-zero on rsync failure, leaving no fake artifact (rc=$_bk_rc)"
fi
rm -rf "$_bk_sandbox"

# #2757：rsync 成功但 sqlite integrity_check 失敗 → 不得產出 tar/sha256（會被當成
# 可信備份），目錄標 .INCOMPLETE、exit 非零；下一次增量基準也不可選到它。
_bk_sandbox=$(mktemp -d)
mkdir -p "$_bk_sandbox/bin" "$_bk_sandbox/backups"
cat > "$_bk_sandbox/bin/rsync" <<'STUB'
#!/bin/bash
[[ "${1:-}" == "--version" ]] && { echo "rsync  version 3.3.0  protocol version 31"; exit 0; }
for last; do :; done
[[ -n "${RSYNC_LOG:-}" ]] && echo "$*" > "$RSYNC_LOG"
: > "${last}x.db"
exit 0
STUB
cat > "$_bk_sandbox/bin/sqlite3" <<'STUB'
#!/bin/bash
echo "*** in database main *** Page 2: btree corrupt"
STUB
chmod +x "$_bk_sandbox/bin/rsync" "$_bk_sandbox/bin/sqlite3"
{
  echo 'set -euo pipefail'
  printf 'DEVOPS_SOURCE_ONLY=1 KG_SSH_CMD=/usr/bin/true source %q\n' "$KG"
  echo "BACKUP_DIR='$_bk_sandbox/backups'; SERVER=stub-host; REMOTE_DATA_DIR=/stub"
  echo 'cmd_backup'
} > "$_bk_sandbox/run.sh"
_bk_rc=0
PATH="$_bk_sandbox/bin:$PATH" bash "$_bk_sandbox/run.sh" > "$_bk_sandbox/out" 2>&1 || _bk_rc=$?
if [[ "$_bk_rc" -ne 0 ]] \
   && [[ -z "$(find "$_bk_sandbox/backups" \( -name '*.tar.gz' -o -name '*.sha256' \) 2>/dev/null)" ]] \
   && [[ -n "$(find "$_bk_sandbox/backups" -name '.INCOMPLETE' 2>/dev/null)" ]]; then
  ok "KG backup marks .INCOMPLETE and emits no tar/sha256 when integrity_check fails"
else
  fail_t "KG backup marks .INCOMPLETE and emits no tar/sha256 when integrity_check fails (rc=$_bk_rc)"
fi
# 同一 sandbox：殘缺目錄（較新）不可當下次的 --link-dest 基準，應退回較舊的完整備份。
mkdir -p "$_bk_sandbox/backups/data_20200101_0000" "$_bk_sandbox/backups/data_20200102_0000"
touch -t 202001010000 "$_bk_sandbox/backups/data_20200101_0000"
touch "$_bk_sandbox/backups/data_20200102_0000/.INCOMPLETE"
RSYNC_LOG="$_bk_sandbox/rsync.args" PATH="$_bk_sandbox/bin:$PATH" bash "$_bk_sandbox/run.sh" > "$_bk_sandbox/out2" 2>&1 || true
if grep -qF 'link-dest=' "$_bk_sandbox/rsync.args" \
   && grep -qF 'data_20200101_0000' "$_bk_sandbox/rsync.args" \
   && ! grep -qF 'data_20200102_0000' "$_bk_sandbox/rsync.args"; then
  ok "KG backup never picks an .INCOMPLETE dir as the --link-dest base"
else
  fail_t "KG backup never picks an .INCOMPLETE dir as the --link-dest base ($(cat "$_bk_sandbox/rsync.args" 2>/dev/null))"
fi
rm -rf "$_bk_sandbox"

# ── 5. Blocklist 行為 ──────────────────────────────────────────────────────
section "Blocklist (dangerous commands blocked — and provably never reach base)"
SAFE_WRAPPER="$WORKSPACE/ops/devops_kg_safe.sh"

# 「被擋」的唯一定義 = wrapper 非零退出 + 輸出含 `✗ blocked` + **base 的 trace 完全沒有條目**。
# 只 grep "blocked" 是舊寫法：它在 guard 漏放時會把命令轉給真 base（2026-10-09 事故，
# 見 docs/runbook/incidents/2026-10-09-kg-data-deleted-by-test.md）。這裡 base 一律是上方
# 的 recording stub，所以「漏放」只會讓 trace 非空而變紅，不會碰到任何主機。
# `✗ blocked` 而非裸 "blocked"：safe_usage 的說明文字也含 "blocked by default"，
# 打錯子命令會印 usage，裸 grep 會把它誤判成「被擋」。
expect_blocked_before_base() {  # <label> <wrapper args...>
  local label="$1" out rc=0
  shift
  : > "$BASE_TRACE"
  out=$(bash "$SAFE_WRAPPER" "$@" 2>&1) || rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q '✗ blocked' <<<"$out" && [[ ! -s "$BASE_TRACE" ]]; then
    ok "blocks (never reached base): $label"
  else
    fail_t "NOT BLOCKED BEFORE BASE: $label (rc=$rc base_trace=$(tr '\n' '|' < "$BASE_TRACE"))"
  fi
}
# 正控：放行的命令必須**真的抵達 base**（trace 出現該命令）。否則「沒被擋」可能只是
# wrapper 在更前面就死了，而不是 guard 判斷它安全。
expect_reaches_base() {  # <label> <needle> <wrapper args...>
  local label="$1" needle="$2" out rc=0
  shift 2
  : > "$BASE_TRACE"
  out=$(bash "$SAFE_WRAPPER" "$@" 2>&1) || rc=$?
  if [[ "$rc" -eq 0 ]] && ! grep -q '✗ blocked' <<<"$out" && grep -qF -- "$needle" "$BASE_TRACE"; then
    ok "allows and forwards to base: $label"
  else
    fail_t "FALSE POSITIVE or not forwarded: $label (rc=$rc out=$(tr '\n' ' ' <<<"$out"))"
  fi
}

expect_blocked_before_base "docker system prune" run "docker system prune -af"
expect_blocked_before_base "setup (blocked subcommand)" setup

# Flag/case variants that the original literal-byte regex let slip through.
expect_blocked_before_base "'compose down -v'" run "docker compose down -v"
expect_blocked_before_base "'down --volumes' long form" run "docker compose down --volumes"
expect_blocked_before_base "'rm -fr' swapped flags" run "rm -fr /home/ubuntu"
expect_blocked_before_base "'rm -r -f /' split flags" run "rm -r -f /"
expect_blocked_before_base "'rm --recursive --force ~' long form" run "rm --recursive --force ~"
expect_blocked_before_base "upper-case 'RM -RF'" run "RM -RF /home/ubuntu"

# Adversarial bypass variants (negative controls — must stay BLOCKED so a future
# regex regression can't silently reopen them).  Format: command@label.
declare -a BYPASS=(
  'rm -rf "/home/ubuntu"@quoted path'
  "rm -rf '/'@quoted root"
  'rm -rf /home/ubuntu;@trailing semicolon'
  'rm -rf /Users/chenliangyu/kg-data@macOS home path (the 2026-10-09 incident command)'
  'rm -rf /Users/x@macOS user home'
  'rm -rf /*@root glob wipe'
  'rm -rf /.@root dot wipe'
  'find /* -delete@find root glob'
  'echo x > /*@redirect root glob'
  'echo x | tee /app/data/db@tee clobber'
  'rm -rf /home//ubuntu@double slash'
  'rm -rf ${HOME}@brace HOME'
  '/bin/rm -rf /home/ubuntu@absolute rm path'
  'find / -delete@find -delete root'
  'find /home/ubuntu -delete@find -delete home'
  'cat foo > /home/ubuntu/data.db@redirect clobber'
  'truncate -s0 /home/ubuntu/x@truncate clobber'
  'docker volume rm knowledge-graph-api_data@docker volume rm'
  'docker volume prune -f@docker volume prune'
  'docker compose -f x.yml down -v@compose -f down -v'
  # ── 2026-10-09 gaps: protected NAMES, not path spellings ───────────────────
  'find /Users/chenliangyu/kg-data -delete@gap: find -delete on kg-data (absolute)'
  'rm -rf ~chenliangyu/kg-data@gap: ~user form'
  'rm -rf /Users/chenliangyu/kg-prod/backend@gap: prod code root, absolute'
  'rm -rf ~/kg-data@~ form'
  'rm -rf $HOME/kg-data@$HOME form'
  'rm -rf "/Users//chenliangyu//kg-data"@quoted double slashes'
  'RM -RF ~/KG-DATA@upper-case name'
  'rm -rf ~/kg-d*@glob matching kg-data'
  'rm -rf ~/k?-data@glob ? matching kg-data'
  'rm -rf ~/*@glob matching every home entry'
  'rm -rf /Users/chenliangyu/*@glob under absolute home'
  'rm -rf ~/{kg-data,x}@brace expansion'
  'rm -rf ../kg-data@relative parent'
  'rm -rf kg-prod@relative name'
  'cd ~ && rm -rf kg-data@relative after cd ~'
  'cd ~/kg-data && rm -rf users@relative after cd into kg-data'
  'cd ~/kg-data && rm -rf *@glob after cd into kg-data'
  'cd /Users/chenliangyu/kg-prod; rm -rf backend@relative after cd (semicolon)'
  'rm -rf *@cwd glob wipe (cwd = home)'
  'rm -rf .@cwd dot wipe (cwd = home)'
  'rm -rf $DATA_DIR@unresolvable variable target'
  'rm ~/kg-data/users.json@non-recursive rm of a kg-data file'
  'rmdir ~/kg-data/users@rmdir'
  'unlink ~/kg-data/users.json@unlink'
  'mv ~/kg-data ~/kg-data.old@mv away (source)'
  'mv /tmp/x /Users/chenliangyu/kg-prod@mv onto (destination)'
  'find ~/kg-data -exec rm {} +@find -exec rm'
  'find /Users/chenliangyu/kg-prod -type f -delete@find -delete on kg-prod'
  'ls ~/kg-data | xargs rm -rf@pipe into xargs rm'
  'truncate -s0 ~/kg-data/users.json@truncate on kg-data'
  'shred -u ~/kg-data/users.json@shred'
  'echo x > ~/kg-data/users.json@redirect into kg-data'
  'echo x >> kg-data/log@append redirect into relative kg-data'
  'echo x | tee -a ~/kg-data/log@tee into kg-data'
  'dd if=/dev/zero of=~/kg-data/x@dd of= on kg-data'
  'rsync -a --delete /tmp/empty/ ~/kg-data/@rsync --delete'
  'rsync -a /tmp/x/ /Users/chenliangyu/kg-data/@rsync overwrite into kg-data'
  'cp /dev/null ~/kg-data/users.json@cp overwrite'
  'tar xzf /tmp/b.tgz -C ~/kg-data@tar extract into kg-data'
  'chmod -R 000 ~/kg-data@chmod -R'
  'chown -R nobody ~/kg-prod@chown -R'
  'cd ~/kg-prod && git clean -xfd@git clean in kg-prod'
  'python3 -c import shutil; shutil.rmtree("/Users/chenliangyu/kg-data")@python rmtree'
  'docker exec knowledge-graph-api rm -rf data@docker exec relative data (cwd /app)'
  'docker exec -w /app knowledge-graph-api rm -rf data@docker exec -w /app'
  'rm -rf ${HOME:?}/kg-data@parameter-expansion HOME form'
  'rm -rf /Users/chenliangyu/kg-da[t]a@bracket glob matching kg-data'
  'rm -rf ~/$SUBDIR@variable inside a home path'
  'sed -i s/a/b/ ~/kg-data/users.json@sed -i on kg-data'
  'sqlite3 ~/kg-data/u/x.db delete from card@sqlite3 write on kg-data'
  'ln -sf /dev/null ~/kg-data/users.json@ln -sf over a kg-data file'
  'find ~ -name kg-data -prune -o -delete@find ~ -delete'
)
# container-run executes inside the container: cwd is /app (WORKDIR), so
# relative paths are the app tree and /app/data is the production volume.
declare -a BYPASS_CONTAINER=(
  'rm -rf /app@gap: /app itself'
  'cd /app && rm -rf data@gap: relative after cd /app'
  'rm -rf /app/data@/app/data'
  'rm -rf /app/data/users@under /app/data'
  'rm -rf /app/*@glob under /app'
  'rm -rf /ap?@glob matching /app'
  'rm -rf data@relative data (cwd /app)'
  'rm -rf ./data@relative ./data'
  'rm -rf data/*@relative data glob'
  'rm -rf .@cwd dot wipe (cwd /app)'
  'rm -rf *@cwd glob wipe (cwd /app)'
  'find . -delete@find -delete in cwd /app'
  'find /app -delete@find -delete /app'
  'find /app/data -exec rm {} +@find -exec rm /app/data'
  'mv /app/data /tmp/data@mv /app/data away'
  'mv data data.old@mv relative data'
  'cd /app/data && rm -rf *@glob after cd /app/data'
  'cd data && rm -rf users@relative after cd data'
  'sh -c cd /app; rm -rf data@sh -c with cd'
  'truncate -s0 /app/data/users.json@truncate'
  'echo x > /app/data/users.json@redirect'
  'python3 -c import shutil; shutil.rmtree("/app/data")@python rmtree'
  'python3 -c import os; os.remove("/app/data/users.json")@python os.remove'
)
for entry in "${BYPASS[@]}"; do
  cmd="${entry%%@*}"; label="${entry##*@}"
  expect_blocked_before_base "bypass: $label" run "$cmd"
done
for entry in "${BYPASS_CONTAINER[@]}"; do
  cmd="${entry%%@*}"; label="${entry##*@}"
  expect_blocked_before_base "container-run bypass: $label" container-run "$cmd"
done
# migrate-run forwards an arbitrary container command too (plus a backup first):
# the guard must fire before either happens.
expect_blocked_before_base "migrate-run: rm -rf /app/data" migrate-run "rm -rf /app/data"
expect_blocked_before_base "migrate-run: cd /app && rm -rf data" migrate-run "cd /app && rm -rf data"

# False-positive controls — legitimate commands must pass the guard AND reach
# the (stub) base, so the silence of the checks above is not a broken wrapper.
declare -a SAFE=(
  'rm -rf ./build@relative build dir'
  'rm -rf /tmp/foo@tmp path'
  'ls -la /Users/chenliangyu/kg-data@listing macOS home'
  'rm -f /Users/chenliangyu/single.log@non-recursive macOS file'
  'rm -rf node_modules@relative no-slash'
  'rm -f /home/ubuntu/single.log@non-recursive single file'
  'ls -la /home/ubuntu@listing prod dir'
  'tar czf x.tgz /home/ubuntu@backup read of prod dir'
  'grep -r foo /home/ubuntu@recursive grep read'
  # ── reads of the protected names stay legal ──
  'ls -la ~/kg-data@ls kg-data'
  'du -sh ~/kg-data@du kg-data'
  'du -sm $HOME/kg-data@du with $HOME'
  'tar czf /tmp/kg-data.tgz ~/kg-data@tar create from kg-data'
  'tar czf /tmp/kg-prod.tgz -C ~ kg-prod@tar create from kg-prod'
  'sqlite3 ~/kg-data/users/u/x.db select count(*) from card@sqlite3 read'
  'find ~/kg-data -name *.db@find without -delete'
  'grep -r foo ~/kg-data@recursive grep on kg-data'
  'cat ~/kg-prod/backend/VERSION@cat kg-prod file'
  'cd ~/kg-prod/backend && git log -1 --oneline@git read in kg-prod'
  'cd ~/kg-prod/backend && ../ops/backup_status.sh@backup_status helper'
  'git -C ~/kg-prod rev-parse HEAD@git -C read'
  'cat ~/kg-data/x > /tmp/out@redirect target outside'
  'tail -40 ~/Library/Logs/kg_reconcile.err.log@log tail'
  'docker logs knowledge-graph-api --since 10m@docker logs window'
  # ── destructive verbs on unprotected paths ──
  'rm -rf /tmp/kg-data-copy@name is only a prefix of the protected one'
  'rm -rf /tmp/*@glob under /tmp'
  'cd /tmp/work && rm -rf *@cwd wipe after cd into a scratch dir'
  'rm -f /tmp/x.log@single file'
  'mv /tmp/a /tmp/b@mv outside'
  'sed -n 1,3p ~/kg-data/notes.txt@sed without -i on kg-data'
  'cd /tmp && rm -rf work@cd to a scratch dir, then rm'
  'cd ~/kg-prod/backend && git pull --ff-only@deploy-style git pull in kg-prod'
  'rmdir /tmp/kg-deploy.lock@deploy lock dir'
)
for entry in "${SAFE[@]}"; do
  cmd="${entry%%@*}"; label="${entry##*@}"
  expect_reaches_base "$label" "$cmd" run "$cmd"
done
declare -a SAFE_CONTAINER=(
  'ls /app/data/users@listing /app/data'
  'du -sh /app/data@du /app/data'
  'cat /app/data/notes.txt@cat a data file'
  'python3 /app/migrate.py@migration script'
  'rm -f /tmp/x.json@rm outside the app tree'
  'rm -f cache.tmp@single relative file in /app'
  'sqlite3 /app/data/users/u/x.db select count(*) from card@sqlite3 read'
  'tar czf /tmp/data.tgz /app/data@tar create from /app/data'
  'cd /tmp; rm -rf data@relative data after cd out of /app'
)
for entry in "${SAFE_CONTAINER[@]}"; do
  cmd="${entry%%@*}"; label="${entry##*@}"
  expect_reaches_base "container-run: $label" "$cmd" container-run "$cmd"
done


# ── 5b. base devops.sh enforces the same guard ──────────────────────────────
# The wrapper is no longer the only line of defense: `devops.sh run …` called directly
# (or a wrapper pointed at another base) hits the same predicate
# (ops/lib/devops_run_guard.sh).  Transport is a recording fake ssh; KG_SERVER is .invalid.
section "base devops.sh enforces the same guard"
BASEFIX="$HERMETIC_TMP/basefix"; mkdir -p "$BASEFIX"
BASE_SSH_TRACE="$BASEFIX/ssh.trace"
cat > "$BASEFIX/ssh_stub.sh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\${@: -1}" >> "$BASE_SSH_TRACE"
[[ "\${@: -1}" == *"docker inspect"* ]] && echo true
exit 0
STUBEOF
chmod +x "$BASEFIX/ssh_stub.sh"
grep -q 'ops/lib/devops_run_guard.sh' "$KG" && grep -q 'ops/lib/devops_run_guard.sh' "$WORKSPACE/ops/devops_kg_safe.sh" \
  && ok "wrapper and base source the same guard lib" \
  || fail_t "wrapper and base do not share ops/lib/devops_run_guard.sh"
expect_base_blocked() {  # <label> <sub> <cmd>
  local label="$1" sub="$2" cmd="$3" out rc=0
  : > "$BASE_SSH_TRACE"
  out=$(KG_SSH_CMD="$BASEFIX/ssh_stub.sh" KG_SERVER=kg-test@invalid.invalid bash "$KG" "$sub" "$cmd" 2>&1) || rc=$?
  if [[ "$rc" -ne 0 ]] && grep -q '✗ blocked' <<<"$out" && [[ ! -s "$BASE_SSH_TRACE" ]]; then
    ok "base devops.sh blocks (no transport call): $label"
  else
    fail_t "BASE DID NOT BLOCK: $label (rc=$rc ssh_trace=$(tr '\n' '|' < "$BASE_SSH_TRACE") out=$(tr '\n' ' ' <<<"$out"))"
  fi
}
expect_base_blocked "the 2026-10-09 incident command" run 'rm -rf /Users/chenliangyu/kg-data'
expect_base_blocked "find -delete on kg-data" run 'find /Users/chenliangyu/kg-data -delete'
expect_base_blocked "~user form" run 'rm -rf ~chenliangyu/kg-data'
expect_base_blocked "kg-prod code root" run 'rm -rf /Users/chenliangyu/kg-prod/backend'
expect_base_blocked "relative after cd into kg-data" run 'cd ~/kg-data && rm -rf users'
expect_base_blocked "docker system prune" run 'docker system prune -af'
expect_base_blocked "container-run rm -rf /app" container-run 'rm -rf /app'
expect_base_blocked "container-run relative after cd /app" container-run 'cd /app && rm -rf data'
expect_base_blocked "migrate-run (guard fires before cmd_backup)" migrate-run 'rm -rf /app/data'
# 正控：唯讀命令照常抵達 transport，上面的「沒有 transport 呼叫」才有意義。
: > "$BASE_SSH_TRACE"
out=$(KG_SSH_CMD="$BASEFIX/ssh_stub.sh" KG_SERVER=kg-test@invalid.invalid bash "$KG" run 'ls -la ~/kg-data' 2>&1) || true
grep -qx 'ls -la ~/kg-data' "$BASE_SSH_TRACE" \
  && ok "base devops.sh forwards a read of kg-data to the transport (positive control)" \
  || fail_t "base devops.sh did not forward a harmless read (trace=$(cat "$BASE_SSH_TRACE"))"
: > "$BASE_SSH_TRACE"
out=$(KG_SSH_CMD="$BASEFIX/ssh_stub.sh" KG_SERVER=kg-test@invalid.invalid bash "$KG" container-run 'ls /app/data/users' 2>&1) || true
grep -qx 'docker exec knowledge-graph-api ls /app/data/users' "$BASE_SSH_TRACE" \
  && ok "base devops.sh forwards a container read of /app/data (positive control)" \
  || fail_t "base devops.sh did not forward a harmless container read (trace=$(cat "$BASE_SSH_TRACE"))"

# 正控（誤殺防護）：infra_health 真實送出的三個 bundle（health／memory／caddy）會經 `$BASE run`
# 走到 base 的 guard。它們引用 kg-data／kg-prod（`du -sm`、`git -C`、`sed -n`），但沒有破壞性動詞，
# 必須照常通過——否則 guard 一上線 `devops_kg_safe.sh health` 就壞。stub base 以真 predicate 判定。
BUNDLE_LOG="$HERMETIC_TMP/bundles.log"; : > "$BUNDLE_LOG"
cat > "$BASEFIX/bundle_base.sh" <<'STUBEOF'
#!/usr/bin/env bash
source "$GUARD_LIB"
if devops_run_is_blocked "$1" "$2"; then echo "BLOCKED $1" >> "$BUNDLE_LOG"; else echo "ALLOWED $1" >> "$BUNDLE_LOG"; fi
exit 0
STUBEOF
chmod +x "$BASEFIX/bundle_base.sh"
for bundle_mode in "--json" "--memory-usage --json" "--caddy-status --json"; do
  # shellcheck disable=SC2086  # word-splitting of the mode flags is intended
  GUARD_LIB="$WORKSPACE/ops/lib/devops_run_guard.sh" BUNDLE_LOG="$BUNDLE_LOG" KG_BASE="$BASEFIX/bundle_base.sh" \
    KG_HEALTH_HTTP_CODE=200 KG_HEALTH_CERT_ENDDATE="Dec  1 00:00:00 2030 GMT" \
    bash "$WORKSPACE/ops/infra_health.sh" $bundle_mode >/dev/null 2>&1 || true
done
if [[ "$(grep -c '^ALLOWED run$' "$BUNDLE_LOG")" -ge 3 ]] && ! grep -q '^BLOCKED' "$BUNDLE_LOG"; then
  ok "the real infra_health health/memory/caddy bundles pass the base guard (3 probes)"
else
  fail_t "infra_health bundles vs the base guard: $(tr '\n' ' ' < "$BUNDLE_LOG")"
fi

# ── 6. Preflight 檔案驗證（靜態） ─────────────────────────────────────────
section "Preflight file validation (static)"
awk '/^preflight\(\)/,/^}/' "$KG" | grep -q 'require_local_files' \
  && ok "KG preflight() calls require_local_files" \
  || fail_t "KG preflight() does not call require_local_files"
awk '/^require_local_files\(\)/,/^}/' "$KG" | grep -q 'Dockerfile' \
  && ok "KG require_local_files checks Dockerfile" \
  || fail_t "KG require_local_files missing Dockerfile check"
awk '/^require_local_files\(\)/,/^}/' "$KG" | grep -q 'docker-compose.yml' \
  && ok "KG require_local_files checks docker-compose.yml" \
  || fail_t "KG require_local_files missing docker-compose.yml check"

# ── 7. 部署版本追蹤 ──────────────────────────────────────────────────────
section "Deploy version tracking"
# 完整 sha（#2078）：VERSION 是 SDK 自報 Sentry release（kg-backend@<VERSION>）的唯一來源，
# 與 deploy 後記錄的 release 名必須逐字相同；短 sha 長度隨 repo 成長漂移。函式範圍 + 剝註解。
deploy_body="$(awk '/^cmd_deploy\(\)/,/^}$/' "$KG" | grep -v '^[[:space:]]*#')"
grep -q 'git rev-parse HEAD > VERSION' <<<"$deploy_body" \
  && ok "KG deploy stamps the full git SHA into VERSION" \
  || fail_t "KG deploy must write the full sha (git rev-parse HEAD > VERSION)"
grep -q 'rev-parse --short HEAD > VERSION' <<<"$deploy_body" \
  && fail_t "KG deploy still writes a short sha to VERSION" \
  || ok "KG deploy no longer writes a short sha to VERSION"
grep -q 'deploy_sha=$(run_remote "cd $REMOTE_DIR && git rev-parse HEAD"' <<<"$deploy_body" \
  && ok "KG deploy compares against the full sha" \
  || fail_t "KG deploy_sha is not the full sha"

# Sentry release 紀錄：只在 smoke verify 通過後、best-effort（#2078）。
verify_line="$(grep -n '^  verify_post_deploy "\$deploy_sha"' "$KG" | head -1 | cut -d: -f1 || true)"
record_line="$(grep -n '^  record_sentry_release "\$deploy_sha"' "$KG" | head -1 | cut -d: -f1 || true)"
[[ -n "$record_line" && -n "$verify_line" && "$record_line" -gt "$verify_line" ]] \
  && ok "KG deploy records the Sentry release after a healthy smoke verify" \
  || fail_t "KG deploy Sentry recording missing or before smoke verify (verify=$verify_line record=$record_line)"
grep -q '"sentry"' <<<"$deploy_body" \
  && ok "KG deploy reads the sentry flag from /api/system/info" \
  || fail_t "KG deploy ignores the sentry flag"
rs_tmp="$(mktemp -d)"
cat >"$rs_tmp/helper.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RS_LOG"
exit "${RS_EXIT:-0}"
FAKE
chmod +x "$rs_tmp/helper.sh"
_rs() {  # RS_EXIT → output + rc of the real record_sentry_release body
  RS_LOG="$rs_tmp/log" RS_EXIT="$1" bash -c 'set -euo pipefail
    ok() { echo "OK $*"; }; info() { echo "INFO $*"; }
    eval "$(awk "/^record_sentry_release\(\)/,/^}$/" "$1")"
    KG_SENTRY_RELEASE="$2" record_sentry_release 0123456789abcdef0123456789abcdef01234567
    echo "RC=0"' _ "$KG" "$rs_tmp/helper.sh" 2>&1
}
out="$(_rs 0 || true)"
grep -q 'RC=0' <<<"$out" && grep -q 'record-backend --sha 0123456789abcdef0123456789abcdef01234567 --environment production --name devops.sh' "$rs_tmp/log" \
  && ok "record_sentry_release passes full sha/production/devops.sh" || fail_t "record_sentry_release ok path: $out / $(cat "$rs_tmp/log" 2>/dev/null)"
out="$(_rs 1 || true)"; grep -q 'RC=0' <<<"$out" && ok "record_sentry_release failure never fails deploy" || fail_t "failure propagated: $out"
out="$(_rs 3 || true)"; grep -q 'RC=0' <<<"$out" && grep -q 'SKIP' <<<"$out" && ok "record_sentry_release SKIP is loud and non-fatal" || fail_t "skip path: $out"
rm -rf "$rs_tmp"
grep -q 'VERSION' "$KG" \
  && ok "KG writes VERSION file" \
  || fail_t "KG missing VERSION file write"
# 函式範圍 + 剝註解，兩者缺一不可。全檔 grep 會被兩種東西滿足：把正確命令寫進**註解**
# （devops.sh:418-427 現在就有一整段在談這條命令），以及旗標搬到 cmd_restart 之類的
# **別的函式**。回補旗標的那個 commit 順手加了註解，若沿用全檔 grep，等於一邊修回歸
# 一邊為下一次同樣的回歸鋪好綠燈。
awk '/^cmd_deploy\(\)/,/^}$/' "$KG" | grep -v '^[[:space:]]*#' \
  | grep -q -- 'docker compose up -d --build --force-recreate' \
  && ok "KG deploy force-recreates container so VERSION is re-read" \
  || fail_t "KG deploy should force-recreate container after stamping VERSION"
grep -q 'deploy.log' "$KG" \
  && ok "KG appends deploy log" \
  || fail_t "KG missing deploy log"
awk '/^cmd_status\(\)/,/^}/' "$KG" | grep -q 'VERSION' \
  && ok "KG status shows deployed version" \
  || fail_t "KG status missing version display"

# ── 7b. deploy 失敗語意（#2278）：build 失敗／版本不符必須非 0，且不記 deploy.log / Sentry ──
section "Deploy failure semantics (build failure, version mismatch)"
DF_FIX="$(mktemp -d)"
mkdir -p "$DF_FIX/bin" "$DF_FIX/local" "$DF_FIX/remote" "$DF_FIX/backups"
git -C "$DF_FIX/local" init -q && git -C "$DF_FIX/local" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat > "$DF_FIX/bin/docker" <<'DEOF'
#!/usr/bin/env bash
echo "compose-out-line"
exit "${DF_COMPOSE_RC:-0}"
DEOF
chmod +x "$DF_FIX/bin/docker"
cat > "$DF_FIX/ssh_stub.sh" <<'SEOF'
#!/usr/bin/env bash
cmd="${@: -1}"
case "$cmd" in
  *"docker compose up"*) cd "$DF_FIX/remote" && PATH="$DF_FIX/bin:$PATH" exec bash -c "$cmd" ;;
  *"curl -o /dev/null"*) printf '200' ;;
  *"curl -s"*) printf '{"version":"%s","sentry":true}' "$DF_REPORTED" ;;
  *"git rev-parse HEAD"*"VERSION"*) ;;
  *"git rev-parse HEAD"*) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
esac
exit 0
SEOF
chmod +x "$DF_FIX/ssh_stub.sh"
_df() {  # $1=compose rc  $2=reported version; prints combined output, returns cmd_deploy rc
  : > "$DF_FIX/marks"; rm -f "$DF_FIX/backups/deploy.log"
  DF_FIX="$DF_FIX" DF_COMPOSE_RC="$1" DF_REPORTED="$2" KG_SSH_CMD="$DF_FIX/ssh_stub.sh" KG_REMOTE_DIR="$DF_FIX/remote" \
    DEVOPS_SOURCE_ONLY=1 KG_SKIP_SMOKE=1 bash -c '
      source "$1"; LOCAL_DIR="$DF_FIX/local"; BACKUP_DIR="$DF_FIX/backups"; REMOTE_DIR="$DF_FIX/remote"
      acquire_deploy_lock() { :; }; preflight() { :; }; sleep() { :; }
      record_sentry_release() { echo sentry >> "$DF_FIX/marks"; }
      cmd_deploy' _ "$KG" 2>&1
}
df_rc=0; df_out=$(_df 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) || df_rc=$?
[[ "$df_rc" != 0 ]] && ok "failed compose build makes deploy exit non-zero" || fail_t "failed compose build was swallowed (rc=0)"
grep -q 'compose-out-line' <<<"$df_out" && ok "compose output tail is still shown on build failure" || fail_t "compose output tail lost on failure"
[[ ! -e "$DF_FIX/backups/deploy.log" && ! -s "$DF_FIX/marks" ]] \
  && ok "failed build writes no deploy.log and records no Sentry release" || fail_t "failed build still recorded deploy/Sentry"
df_rc=0; df_out=$(_df 0 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) || df_rc=$?
[[ "$df_rc" != 0 ]] && ok "version mismatch exits non-zero even with KG_SKIP_SMOKE=1" || fail_t "version mismatch only warned (rc=0)"
[[ ! -e "$DF_FIX/backups/deploy.log" && ! -s "$DF_FIX/marks" ]] \
  && ok "version mismatch writes no deploy.log and records no Sentry release" || fail_t "mismatch still recorded deploy/Sentry"
df_rc=0; df_out=$(_df 0 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) || df_rc=$?
[[ "$df_rc" == 0 ]] && grep -q 'compose-out-line' <<<"$df_out" && grep -q 'sha=aaaaaaaa' "$DF_FIX/backups/deploy.log" && grep -q sentry "$DF_FIX/marks" \
  && ok "success path records deploy.log and Sentry release" || fail_t "success path broken (rc=$df_rc): $df_out"
rm -rf "$DF_FIX"

# env-drift（#2314）：遠端 .env 放 host 路徑，container_root 必須是遠端真實 repo 目錄，不可是字面 "/app"。
awk '/^cmd_env_drift\(\)/,/^}$/' "$KG" | grep -v '^[[:space:]]*#' | grep -q '"/app"' \
  && fail_t "cmd_env_drift still passes the literal /app as container_root" \
  || ok "cmd_env_drift does not pass the literal /app"
awk '/^cmd_env_drift\(\)/,/^}$/' "$KG" | grep -v '^[[:space:]]*#' | grep -q '"\$remote_real_dir" "\$SERVER"' \
  && ok "cmd_env_drift passes the resolved remote dir as container_root" \
  || fail_t "cmd_env_drift must pass \$remote_real_dir as container_root"

# ── 8. ops-cli transport quoting（argv 安全序列化）──────────────────────────
# 根因回歸:ops-cli 的 SQL 過去用 $* 扁平化 + 遠端 bash 二次解析,引號/括號/% 全毀。
# 用 KG_SSH_CMD stub 攔截最終遠端指令字串,確認任意特殊字元的 SQL 原封不動穿越。
section "ops-cli transport quoting"
STUB="$(mktemp)"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# fake ssh: docker-inspect 探活回 true;其餘把遠端指令字串原樣印出
arg="$*"
case "$arg" in
  *"docker inspect"*) echo true ;;
  *) printf '%s\n' "$arg" ;;
esac
STUBEOF
chmod +x "$STUB"

# argv 佈局:docker(0) exec(1) container(2) python3(3) ops_cli.py(4) db-query(5) uid(6) SQL...(7+)
SQL="SELECT id FROM card WHERE content LIKE '%a(b)%' COLLATE NOCASE"
remote_cmd=$(KG_SSH_CMD="$STUB" bash "$KG" ops-cli db-query u1 "$SQL" 2>/dev/null | tail -1)
# 遠端 bash 重新解析該字串後,還原出的 argv 自第 7 元素起應 == 原始 SQL（一字不差）
eval "argv=( $remote_cmd )"
got="${argv[*]:7}"
[[ "$got" == "$SQL" ]] \
  && ok "ops-cli SQL survives transport (quotes/parens/% intact)" \
  || fail_t "ops-cli SQL mangled: got [$got] want [$SQL]"

# REMAINDER 多 token:遠端 bash 解析後須還原出 count(*)，不被當 subshell 破壞
remote_cmd=$(KG_SSH_CMD="$STUB" bash "$KG" ops-cli db-query u1 SELECT count'(*)' FROM card 2>/dev/null | tail -1)
eval "argv=( $remote_cmd )"
[[ "${argv[*]:7}" == "SELECT count(*) FROM card" ]] \
  && ok "ops-cli preserves 'count(*)' across hop" \
  || fail_t "ops-cli lost 'count(*)': [${argv[*]:7}]"
rm -f "$STUB"

# ── 9. ops-edit transport quoting（空白 content / notebook 名原封不動）──────
section "ops-edit transport quoting"
STUB="$(mktemp)"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
arg="$*"
case "$arg" in
  *"docker inspect"*) echo true ;;
  *) printf '%s\n' "$arg" ;;
esac
STUBEOF
chmod +x "$STUB"

remote_cmd=$(KG_SSH_CMD="$STUB" bash "$KG" ops-edit card-move u1 "file in" --to-notebook "Turns of Phrase" --commit --json 2>/dev/null | tail -1)
eval "argv=( $remote_cmd )"
expect=(card-move u1 "file in" --to-notebook "Turns of Phrase" --commit --json)
for i in "${!expect[@]}"; do
  [[ "${argv[$((5 + i))]}" == "${expect[$i]}" ]] \
    && ok "ops-edit arg[$i] preserved: ${expect[$i]}" \
    || fail_t "ops-edit arg[$i] mangled: got [${argv[$((5 + i))]}] want [${expect[$i]}]"
done
rm -f "$STUB"

# ── 10. ops-edit-batch wrapper（單次 upload + docker exec）─────────────────
section "ops-edit-batch wrapper"
SSH_STUB="$(mktemp)"
SCP_STUB="$(mktemp)"
cat > "$SSH_STUB" <<'STUBEOF'
#!/usr/bin/env bash
arg="$*"
case "$arg" in
  *"docker inspect"*) echo true ;;
  *) printf '%s\n' "$arg" ;;
esac
STUBEOF
cat > "$SCP_STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf 'scp:%s\n' "$*"
STUBEOF
chmod +x "$SSH_STUB" "$SCP_STUB"
PLAN="$(mktemp)"
printf '{"schema":"kg.ops_edit_batch.v1","ops":[["world-snapshot","--json"]]}\n' > "$PLAN"
batch_out=$(KG_SSH_CMD="$SSH_STUB" KG_SCP_CMD="$SCP_STUB" bash "$KG" ops-edit-batch "$PLAN" 2>/dev/null || true)
echo "$batch_out" | grep -q 'docker exec knowledge-graph-api python3 /tmp/ops_edit_batch' \
  && ok "ops-edit-batch docker exec runner" \
  || fail_t "ops-edit-batch missing runner docker exec"
echo "$batch_out" | grep -q '/tmp/ops_edit_batch_plan' \
  && ok "ops-edit-batch passes uploaded plan path" \
  || fail_t "ops-edit-batch missing uploaded plan path"
rm -f "$SSH_STUB" "$SCP_STUB" "$PLAN"

# ── 11. validate_uid（Apple uid 含點；traversal 仍須擋）─────────────────────
# 根因:Apple Sign-in user_id 含 '.'（如 000287.<hex>.0228），舊白名單
# [A-Za-z0-9_-] 把真實生產 uid 全擋，導致 user-info/ops-cli 查不了任何 Apple
# 帳號。修法:放行 '.'，但以「禁 '..' / 禁前導 '.'」對齊後端 _safe_user_dir
# (admin_wiring.py) 的 resolve()+commonpath path-traversal 防護語意。
section "validate_uid (Apple uid with dots; traversal still blocked)"
# 透過 devops.sh 的 source-only 邊界直接載入 validate_uid，避免用 sed 擷取函式文字。
vuid() {
  DEVOPS_SOURCE_ONLY=1 KG_SSH_CMD=/usr/bin/true bash -c \
    'source "$1"; validate_uid "$2"' _ "$KG" "$1"
}

vuid '000287.04e254024c2f4341849278a933743257.0228' >/dev/null 2>&1 \
  && ok "accepts Apple uid with dots" \
  || fail_t "rejected legit Apple uid with dots"
vuid 'abc_123-XYZ' >/dev/null 2>&1 \
  && ok "accepts plain alnum/_/-" \
  || fail_t "rejected plain alnum uid"

# 負控:traversal / metachar / 邊界 必須續擋
LONG65=$(printf 'x%.0s' $(seq 1 65))
for bad in '..' '../etc' 'a..b' '.hidden' 'a/b' 'a b' 'a;rm' '' "$LONG65"; do
  _out=$(vuid "$bad" 2>&1) || true
  echo "$_out" | grep -q '非法\|不可' \
    && ok "blocks bad uid: '${bad:0:24}'" \
    || fail_t "did NOT block bad uid: '$bad'"
done

# ── 12. 診斷噪音須走 stderr，讓 --json 的 stdout 可被機器 parse ─────────────
# 根因:dogfooding 發現 preflight banner + info "▶ 執行 argv" 印到 stdout,
# 害每個 ops-cli --json 都 json.loads 失敗。診斷訊息一律 stderr,stdout 只留 payload。
section "Diagnostics to stderr (clean --json stdout)"
# 10a. wrapper preflight banner 不可出現在 stdout
_pf_stdout=$(bash "$WORKSPACE/ops/devops_kg_safe.sh" preflight 2>/dev/null)
[[ -z "$_pf_stdout" ]] \
  && ok "preflight banner not on stdout" \
  || fail_t "preflight banner leaked to stdout: $_pf_stdout"
# 10b. wrapper preflight banner 必須出現在 stderr
_pf_stderr=$(bash "$WORKSPACE/ops/devops_kg_safe.sh" preflight 2>&1 >/dev/null)
echo "$_pf_stderr" | grep -q '\[Preflight\]' \
  && ok "preflight banner on stderr" \
  || fail_t "preflight banner missing from stderr"
# 10c. devops.sh info() 須導向 stderr（progress 非 payload）
grep -qE '^info\(\)[[:space:]]*\{[[:space:]]*echo "▶ \$\*" >&2;' "$KG" \
  && ok "info() routed to stderr" \
  || fail_t "info() not routed to stderr (would pollute --json stdout)"

VIEW_LOGS="$WORKSPACE/backend/view_logs.sh"
bash -n "$VIEW_LOGS" \
  && ok "view_logs syntax" \
  || fail_t "view_logs syntax"
grep -q 'devops_kg_safe.sh' "$VIEW_LOGS" \
  && ok "view_logs calls devops_kg_safe.sh" \
  || fail_t "view_logs does not call safe wrapper"
grep -Eq '(^|[[:space:]])ssh([[:space:]]|$)|docker compose logs' "$VIEW_LOGS" \
  && fail_t "view_logs still has raw ssh/docker logs bypass" \
  || ok "view_logs has no raw ssh/docker logs bypass"

# ── 12. typed read-only debug surfaces（縮 raw run surface）──────────────────
section "Typed read-only debug surfaces"
SAFE_KG="$WORKSPACE/ops/devops_kg_safe.sh"
grep -q 'caddy-status' "$SAFE_KG" && grep -q 'caddyfile' "$SAFE_KG" \
  && grep -q 'docker-ps' "$SAFE_KG" && grep -q 'docker-logs' "$SAFE_KG" \
  && grep -q 'disk-usage' "$SAFE_KG" && grep -q 'memory-usage' "$SAFE_KG" \
  && grep -q 'docker-stats' "$SAFE_KG" \
  && ok "safe wrapper exposes typed debug commands" \
  || fail_t "safe wrapper missing typed debug commands"

STUB_BASE="$(mktemp)"
cat > "$STUB_BASE" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*"
STUBEOF
chmod +x "$STUB_BASE"

# set -o pipefail 下 `$(wrapper ... | tail -1)` 的狀態是 **wrapper** 的狀態——tail 遮不住。
# 某個 arm 一被刪掉，wrapper 就落到 usage 分支非零退出，賦值失敗，set -e 在下面的斷言
# 之前殺掉整支腳本：輸出裡一個 ✗ 都沒有、後面的斷言連跑都沒跑，而那正是最需要診斷的
# 時刻。
#
# 但 rc 不能只是「抓進來然後不看」——那是把大聲難看的偵測換成安靜的漏放（實測：arm 印出
# 正確命令後 exit 3，整組全綠；改版前那個 mutant 反而是紅的）。非零一律回傳 `EXIT-<rc>`，
# 六條 `==` 比較全部判紅，且 exit code 直接出現在診斷字串裡。
#
# 也不 `tail -1`：這六個 arm 的 stdout 恰好一行，比對**完整 stdout** 才釘得住「這個 typed
# 命令只碰得到什麼」——只看最後一行的話，在正確命令之前多送一條 `run cat /etc/shadow`
# 是綠的，而「縮 raw run surface」正是本段存在的理由。
typed_all() {
  local out rc=0
  out=$(KG_DEVOPS_BASE="$STUB_BASE" bash "$SAFE_KG" "$@" 2>/dev/null) || rc=$?
  (( rc == 0 )) || { printf 'EXIT-%d' "$rc"; return 0; }
  printf '%s' "$out"
}

# caddy-status / caddyfile 保留舊名（agent 肌肉記憶 + docs/sop/debug.md 仍這樣寫），
# 但 payload 已改由 infra_health 的 secret-safe caddy probe 統一產生。
grep -q -- '--caddy-status --json' "$SAFE_KG" \
  && ok "caddy-status delegates to the typed infra probe" \
  || fail_t "caddy-status missing typed infra probe delegation"

# caddyfile 是唯一「不打遠端」的 typed 指令：CF ingress 存在 Cloudflare 端，沒有本地
# 檔案可 cat。契約因此是**不得發出任何 remote 命令**，並在 stderr 指向 ingress 正本。
#
# 兩者必須綁成一條，順序不可反：空 stdout 本身是**假證據**——arm 被刪掉、subcommand
# 打錯、腳本提早 exit，stdout 一樣是空的。先用 stderr 的 SoT 指標證明這條 arm 真的跑過，
# 「它沒發出遠端命令」才是關於被測路徑的斷言而非關於「什麼都沒發生」的同義反覆。
# rc 要顯式接住：這是本組唯一不以 `| tail -1` 收尾的捕捉，而管線最後一段的 tail 恆 0，
# 正是其他每一條被 set -e 放過的原因。少了 `|| rc=$?`，arm 一被刪掉 wrapper 就落到
# usage 分支非零退出，`set -e` 在下面的 if 判斷**之前**就殺掉整支腳本——診斷訊息永遠
# 印不出來，後面 8 條斷言連跑都沒跑，而且輸出裡一個 ✗ 都沒有。
caddyfile_err_file="$(mktemp)"
caddyfile_rc=0
caddyfile_out=$(KG_DEVOPS_BASE="$STUB_BASE" bash "$SAFE_KG" caddyfile 2>"$caddyfile_err_file") \
  || caddyfile_rc=$?
caddyfile_err=$(cat "$caddyfile_err_file"); rm -f "$caddyfile_err_file"
if (( caddyfile_rc != 0 )); then
  fail_t "caddyfile exited $caddyfile_rc — the arm is gone or broken: ${caddyfile_err:-(no stderr)}"
elif [[ "$caddyfile_err" != *kg-backend-deployment.md* ]]; then
  fail_t "caddyfile stopped naming the ingress SoT: $caddyfile_err"
elif [[ "$caddyfile_err" == *'[Preflight]'* ]]; then
  # 正面證據勝過「stdout 是空的」：只有 run_fixed_remote 會印 preflight banner，所以
  # 把遠端輸出重導掉也逃不過——空 stdout 本身無法區分「沒打遠端」與「打了但沒回顯」。
  fail_t "caddyfile reached the host — preflight banner present, so a remote command ran"
elif [[ -n "$caddyfile_out" ]]; then
  fail_t "caddyfile stdout must be empty, got: $caddyfile_out"
else
  ok "caddyfile issues no remote command, names the ingress SoT, and never preflights"
fi

typed_out=$(typed_all docker-ps)
[[ "$typed_out" == 'run docker ps' ]] \
  && ok "docker-ps maps to fixed readonly command" \
  || fail_t "docker-ps mapping drifted: $typed_out"

# 餵 7 而不是 25：預設是 100，但「寫死成 25」與「透傳 25」在只測 25 時無法區分——
# 挑一個沒人會寫死的值，再補一條不帶參數的呼叫把預設本身釘住。
typed_out=$(typed_all docker-logs 7)
[[ "$typed_out" == 'run docker logs knowledge-graph-api -n 7' ]] \
  && ok "docker-logs passes the caller's line count through" \
  || fail_t "docker-logs mapping drifted: $typed_out"

typed_out=$(typed_all docker-logs)
[[ "$typed_out" == 'run docker logs knowledge-graph-api -n 100' ]] \
  && ok "docker-logs defaults to 100 lines" \
  || fail_t "docker-logs default drifted: $typed_out"

typed_out=$(typed_all disk-usage)
[[ "$typed_out" == 'run df -h' ]] \
  && ok "disk-usage maps to df -h" \
  || fail_t "disk-usage mapping drifted: $typed_out"

grep -q -- '--memory-usage --json' "$SAFE_KG" \
  && ok "memory-usage delegates to the macOS typed infra probe" \
  || fail_t "memory-usage missing typed infra probe delegation"

# ── 12b. macOS typed probes：固定 JSON、秘密隔離、fixture 必須真的影響值 ───────
# 這不是靜態 grep：fake transport 會依接收到的 remote bundle 回傳不同 fixture，
# 並刻意把 secret marker 分別塞進 stdout/stderr。成功路徑 stderr 必須空，probe 只
# 選取 allowlisted 欄位；因此把 producer 改成固定常數、回顯 raw payload 或污染 stderr
# 都會轉紅。
section "Typed macOS probes (secret-safe JSON contracts)"
PROBE_BASE="$(mktemp)"
cat > "$PROBE_BASE" <<'STUBEOF'
#!/usr/bin/env bash
set -eu
[[ "${1:-}" == run ]] || exit 64
bundle="${2:-}"
[[ -z "${KG_PROBE_SECRET_STDERR:-}" ]] || printf '%s\n' "$KG_PROBE_SECRET_STDERR" >&2
[[ -z "${KG_PROBE_SECRET_STDOUT:-}" ]] || printf '%s\n' "$KG_PROBE_SECRET_STDOUT"
case "${KG_PROBE_MODE:-}" in
  memory)
    [[ "$bundle" == *vm_stat* ]] || exit 65
    printf 'mem_total_mb\t%s\n' "${KG_PROBE_MEM_TOTAL:-16384}"
    printf 'mem_avail_mb\t%s\n' "${KG_PROBE_MEM_AVAILABLE:-8192}"
    printf 'swap_total_mb\t%s\n' "${KG_PROBE_SWAP_TOTAL:-4096}"
    printf 'swap_used_mb\t%s\n' "${KG_PROBE_SWAP_USED:-512}"
    ;;
  caddy)
    [[ "$bundle" == *launchctl* ]] || exit 66
    case "${KG_PROBE_STATE:-active}" in
      active) printf 'status\tactive\nlabel\tcom.cloudflare.cloudflared\npid_count\t2\n' ;;
      inactive) printf 'status\tinactive\nlabel\tcom.cloudflare.cloudflared\npid_count\t0\n' ;;
      unknown) printf 'status\tunknown\nlabel\tcom.cloudflare.cloudflared\npid_count\t0\n' ;;
      *) exit 67 ;;
    esac
    ;;
  fail) exit 68 ;;
  *) exit 69 ;;
esac
STUBEOF
chmod +x "$PROBE_BASE"
PROBE_ERR="$(mktemp)"
probe_call() {
  local mode="$1" command="$2" state="${3:-}" out rc=0
  out=$(KG_DEVOPS_BASE="$PROBE_BASE" KG_PROBE_MODE="$mode" KG_PROBE_STATE="$state" \
    KG_PROBE_SECRET_STDOUT='stdout-secret-marker' KG_PROBE_SECRET_STDERR='stderr-secret-marker' \
    bash "$SAFE_KG" "$command" --json 2>"$PROBE_ERR") || rc=$?
  PROBE_RC="$rc" PROBE_OUT="$out"
}
probe_call memory memory-usage
if (( PROBE_RC == 0 )) \
   && [[ ! -s "$PROBE_ERR" ]] \
   && ! grep -qE 'stdout-secret-marker|stderr-secret-marker' <<<"$PROBE_OUT" \
   && ! grep -qE 'stdout-secret-marker|stderr-secret-marker' "$PROBE_ERR" \
   && jq -e 'keys == ["available_mb","swap_total_mb","swap_used_mb","total_mb"] and (.total_mb > 0) and (.available_mb <= .total_mb) and (.swap_used_mb <= .swap_total_mb)' <<<"$PROBE_OUT" >/dev/null; then
  ok "memory-usage emits exact secret-safe JSON with invariants"
else
  fail_t "memory-usage JSON/secret contract failed (rc=$PROBE_RC out=$PROBE_OUT err=$(cat "$PROBE_ERR"))"
fi
first_memory="$PROBE_OUT"
changed_memory="$(KG_DEVOPS_BASE="$PROBE_BASE" KG_PROBE_MODE=memory KG_PROBE_MEM_TOTAL=32768 KG_PROBE_MEM_AVAILABLE=12345 KG_PROBE_SWAP_TOTAL=8192 KG_PROBE_SWAP_USED=7 \
  bash "$SAFE_KG" memory-usage --json 2>"$PROBE_ERR" || true)"
if [[ "$first_memory" != "$changed_memory" ]] \
   && jq -e '.total_mb == 32768 and .available_mb == 12345 and .swap_total_mb == 8192 and .swap_used_mb == 7' <<<"$changed_memory" >/dev/null; then
  ok "memory fixture changes flow into JSON values"
else
  fail_t "memory fixture change was ignored or malformed (out=$changed_memory)"
fi
for state in active inactive unknown; do
  probe_call caddy caddy-status "$state"
  expected_status="$state"
  if (( PROBE_RC == 0 )) \
     && [[ ! -s "$PROBE_ERR" ]] \
     && ! grep -qE 'stdout-secret-marker|stderr-secret-marker' <<<"$PROBE_OUT" \
     && ! grep -qE 'stdout-secret-marker|stderr-secret-marker' "$PROBE_ERR" \
     && jq -e --arg s "$expected_status" 'keys == ["label","pid_count","status"] and .label == "com.cloudflare.cloudflared" and .status == $s and (.pid_count | type == "number") and (($s != "active") or .pid_count >= 1)' <<<"$PROBE_OUT" >/dev/null; then
    ok "caddy-status fixture $state -> exact JSON"
  else
    fail_t "caddy-status fixture $state contract failed (rc=$PROBE_RC out=$PROBE_OUT err=$(cat "$PROBE_ERR"))"
  fi
done
probe_call fail memory
if (( PROBE_RC != 0 )) \
   && ! grep -qE 'stdout-secret-marker|stderr-secret-marker' <<<"$PROBE_OUT" \
   && ! grep -qE 'stdout-secret-marker|stderr-secret-marker' "$PROBE_ERR"; then
  ok "probe transport failure is non-zero and secret-safe"
else
  fail_t "probe transport failure was swallowed or leaked a secret (rc=$PROBE_RC)"
fi
rm -f "$PROBE_BASE" "$PROBE_ERR"

typed_out=$(typed_all docker-stats)
[[ "$typed_out" == 'run docker stats --no-stream' ]] \
  && ok "docker-stats maps to non-streaming stats" \
  || fail_t "docker-stats mapping drifted: $typed_out"

typed_out=$(bash "$SAFE_KG" run "docker ps" 2>&1 || true)
echo "$typed_out" | grep -q 'use typed command: docker-ps' \
  && ok "raw docker ps redirected to typed command" \
  || fail_t "raw docker ps was not redirected"

typed_out=$(bash "$SAFE_KG" run "sudo systemctl status caddy" 2>&1 || true)
echo "$typed_out" | grep -q 'use typed command: caddy-status --json' \
  && ok "raw caddy status redirected to typed command" \
  || fail_t "raw caddy status was not redirected"
rm -f "$STUB_BASE"

# ── 13. users 隱私契約（#2098）：只准出 count + uid provider last_login ───────
section "users privacy (count + uid/provider/last_login only)"
# KG_SSH_CMD stub 在本機直接執行收到的 remote 命令（最後一個 argv），所以 cmd_users 的
# 過濾邏輯真的被跑到——stub 若只回顯命令，斷言的是字串而不是輸出，證明不了任何事。
USERS_FIX="$(mktemp -d)"
USERS_STUB="$USERS_FIX/ssh_stub.sh"
mkdir -p "$USERS_FIX/data/users/google_alice" "$USERS_FIX/data/users/apple_bob"
cat > "$USERS_FIX/data/users.json" <<'JSONEOF'
{
  "google_alice": {"email": "alice@example.com", "provider": "google", "last_login": "2026-10-01T08:00:00Z",
                   "subscription": {"tier": "pro", "receipt": "RCPT-SECRET"},
                   "linked_ids": ["apple_alias"], "config": {"api_key": "TOKEN-SECRET"}},
  "apple_bob": {"provider": "apple", "last_login": "2026-09-30T01:02:03Z"},
  "apple_alias": {"_linked_to": "google_alice", "provider": "apple", "last_login": "2026-09-01T00:00:00Z"},
  "_email_index": {"alice@example.com": "google_alice"},
  "_revoked_before": {"google_alice": "2026-01-01T00:00:00Z"},
  "_terminated": ["gone_user"]
}
JSONEOF
cat > "$USERS_STUB" <<'STUBEOF'
#!/usr/bin/env bash
exec bash -c "${@: -1}"
STUBEOF
chmod +x "$USERS_STUB"
users_leaks() {
  grep -Eq 'alice@example\.com|subscription|linked_ids|_email_index|_revoked_before|_terminated|TOKEN-SECRET|RCPT-SECRET|api_key|apple_alias|gone_user' <<< "$1"
}
users_rc=0
users_out=$(KG_DEVOPS_BASE="$KG" KG_SSH_CMD="$USERS_STUB" KG_REMOTE_DATA_DIR="$USERS_FIX/data" bash "$SAFE_KG" users 2>&1) || users_rc=$?
[[ "$users_rc" == 0 ]] && ok "users exits 0 against fixture" || fail_t "users exits $users_rc against fixture"
grep -Eq '^users: 2$' <<< "$users_out" \
  && ok "users prints the real-user count (aliases and metadata excluded)" \
  || fail_t "users count line missing or wrong (want 'users: 2')"
grep -Eq '^google_alice google 2026-10-01T08:00:00Z$' <<< "$users_out" \
  && grep -Eq '^apple_bob apple 2026-09-30T01:02:03Z$' <<< "$users_out" \
  && ok "users prints one 'uid provider last_login' line per real user" \
  || fail_t "users uid/provider/last_login lines missing"
users_leaks "$users_out" \
  && fail_t "users output leaks email/subscription/linked_ids/_email_index/tokens/alias" \
  || ok "users output carries no email/subscription/linked_ids/_email_index/tokens/alias records"
# 預設值是 `~/kg-data`：printf %q 在 bash 3.2 保留 `~`、在 bash 5 轉成 `\~`，兩條路都
# 必須落到同一個 home（HOME 指向 fixture，證明展開真的發生而不是讀到字面 `~` 目錄）。
users_out=$(HOME="$USERS_FIX" KG_DEVOPS_BASE="$KG" KG_SSH_CMD="$USERS_STUB" KG_REMOTE_DATA_DIR='~/data' bash "$SAFE_KG" users 2>&1) || true
grep -Eq '^users: 2$' <<< "$users_out" \
  && ok "users expands a ~-relative data dir (default shape ~/kg-data)" \
  || fail_t "users did not expand ~ in KG_REMOTE_DATA_DIR"
# 正控：同一個 leak 偵測器必須對舊行為（raw cat）報警，否則上面那條的沉默沒有證據力。
users_leaks "$(cat "$USERS_FIX/data/users.json")" \
  && ok "positive control: leak detector flags the old raw users.json dump" \
  || fail_t "positive control failed: leak detector is blind to a raw dump"
# 無 raw-dump 路徑：多餘參數一律 exit 64 + usage，且不得到達 remote（base 換成會留痕的 stub）。
USERS_TRACE="$USERS_FIX/base_called"
USERS_BASE="$USERS_FIX/base.sh"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$USERS_TRACE" > "$USERS_BASE"; chmod +x "$USERS_BASE"
users_rc=0
users_out=$(KG_DEVOPS_BASE="$USERS_BASE" bash "$SAFE_KG" users extra 2>&1) || users_rc=$?
[[ "$users_rc" == 64 ]] && grep -q 'usage: .* users' <<< "$users_out" && [[ ! -e "$USERS_TRACE" ]] \
  && ok "users with extra args exits 64 with usage and never reaches the base" \
  || fail_t "users with extra args: rc=$users_rc trace=$([[ -e "$USERS_TRACE" ]] && echo hit || echo none)"
rm -rf "$USERS_FIX"

# ── 13b. user-info 預設 ~/kg-data（#2758）──────────────────────────────────
# 舊行為：`~` 被包在遠端 python -c 的雙引號內，sqlite3.connect 收到字面 `~/…`，永遠
# 開不了 DB 且 except 吞掉錯誤 exit 0。stub 以 bash -c 真的執行遠端字串（HOME=fixture）。
section "user-info expands ~ in the default data dir (#2758)"
UI_FIX="$(mktemp -d)"
mkdir -p "$UI_FIX/kg-data/users/u1"
python3 -c "
import sqlite3
c = sqlite3.connect('$UI_FIX/kg-data/users/u1/cards.db')
c.execute('CREATE TABLE card (is_deleted INTEGER)')
c.executemany('INSERT INTO card VALUES (?)', [(0,), (0,), (1,)])
c.commit()
"
UI_ECHO="$UI_FIX/echo_stub.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${@: -1}"\n' > "$UI_ECHO"; chmod +x "$UI_ECHO"
UI_RUN="$UI_FIX/run_stub.sh"
printf '#!/usr/bin/env bash\nexec bash -c "${@: -1}"\n' > "$UI_RUN"; chmod +x "$UI_RUN"
ui_cmd=$(env -u KG_REMOTE_DATA_DIR KG_SSH_CMD="$UI_ECHO" bash "$KG" user-info u1 2>&1) || true
grep -q "sqlite3.connect('~" <<< "$ui_cmd" \
  && fail_t "user-info still hands a literal ~ path to sqlite3.connect" \
  || ok "user-info never hands a literal ~ path to sqlite3.connect"
grep -q 'sqlite3.connect' <<< "$ui_cmd" \
  && ok "positive control: the echoed remote command contains the sqlite3 section" \
  || fail_t "positive control failed: sqlite3 section missing from echoed command"
ui_rc=0
ui_out=$(env -u KG_REMOTE_DATA_DIR HOME="$UI_FIX" KG_SSH_CMD="$UI_RUN" bash "$KG" user-info u1 2>&1) || ui_rc=$?
grep -q '總卡片: 3  有效: 2  已刪除: 1' <<< "$ui_out" \
  && ok "user-info reads cards.db under the default ~/kg-data" \
  || fail_t "user-info did not read cards.db: $(tr '\n' ' ' <<< "$ui_out")"
rm -f "$UI_FIX/kg-data/users/u1/cards.db"
ui_rc=0
ui_out=$(env -u KG_REMOTE_DATA_DIR HOME="$UI_FIX" KG_SSH_CMD="$UI_RUN" bash "$KG" user-info u1 2>&1) || ui_rc=$?
[[ "$ui_rc" != 0 ]] && grep -q '無法讀取 SQLite' <<< "$ui_out" \
  && ok "user-info exits non-zero when the SQLite DB cannot be read" \
  || fail_t "user-info swallowed an unreadable DB (rc=$ui_rc)"
rm -rf "$UI_FIX"

# ── 14. 敏感檔讀取 deny-list（#2134）：run / container-run / migrate-run / container-script ──
section "sensitive file reads blocked (users.json / .env / ~/.secrets / private keys)"
# 同一支 stub 兼任 ssh/scp transport（KG_SSH_CMD／KG_SCP_CMD，走真 base devops.sh）與
# base（KG_DEVOPS_BASE）：只留痕、不執行。被擋的命令 trace 必須不存在；放行的命令 trace
# 必須真的出現——後者是前者的正控，否則「沒留痕」可能只是 stub 壞了。migrate-run 的真
# base 會先跑 cmd_backup（rsync 直連 $SERVER，不經 KG_SSH_CMD），所以它一律走 base stub；
# KG_SERVER 指向 .invalid 是第二道保險：任何繞過 stub 的路徑只會 DNS 失敗，不會碰到 felix。
SENS_FIX="$(mktemp -d)"
SENS_TRACE="$SENS_FIX/trace.log"
SENS_STUB="$SENS_FIX/stub.sh"
cat > "$SENS_STUB" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SENS_TRACE"
[[ "\$*" == *"docker inspect"* ]] && echo true
exit 0
STUBEOF
chmod +x "$SENS_STUB"
printf 'print("ok")\n' > "$SENS_FIX/benign.py"
printf 'print(open("/app/data/Users.JSON").read())\n' > "$SENS_FIX/dump_users.py"
# sens_call <transport|base> <sub> [args...] → sens_rc／sens_out；每次呼叫前清掉 trace。
sens_call() {
  local mode="$1"; shift
  local -a seam=(KG_DEVOPS_BASE="$KG" KG_SSH_CMD="$SENS_STUB" KG_SCP_CMD="$SENS_STUB")
  [[ "$mode" == base ]] && seam=(KG_DEVOPS_BASE="$SENS_STUB")
  rm -f "$SENS_TRACE"
  sens_rc=0
  sens_out=$(env "${seam[@]}" KG_SERVER=kg-test@invalid.invalid bash "$SAFE_KG" "$@" 2>&1) || sens_rc=$?
}
sens_expect_blocked() {  # <label> <mode> <sub> [args...]
  local label="$1"; shift
  sens_call "$@"
  if [[ "$sens_rc" != 0 ]] && grep -q 'blocked sensitive file read' <<< "$sens_out" && [[ ! -e "$SENS_TRACE" ]]; then
    ok "blocks sensitive read: $label"
  else
    fail_t "SENSITIVE READ NOT BLOCKED: $label (rc=$sens_rc trace=$([[ -e "$SENS_TRACE" ]] && echo hit || echo none))"
  fi
}
sens_expect_allowed() {  # <label> <needle> <mode> <sub> [args...]
  local label="$1" needle="$2"; shift 2
  sens_call "$@"
  if [[ "$sens_rc" == 0 ]] && [[ -e "$SENS_TRACE" ]] && grep -qF -- "$needle" "$SENS_TRACE"; then
    ok "allows and reaches remote: $label"
  else
    fail_t "FALSE POSITIVE or not forwarded: $label (rc=$sens_rc out=$(tr '\n' ' ' <<< "$sens_out"))"
  fi
}
sens_expect_blocked "run cat users.json" transport run "cat ~/kg-data/users.json"
sens_expect_blocked "quoted upper-case USERS.JSON after cd" transport run 'cd ~/kg-data && CAT "USERS.JSON"'
sens_expect_blocked "backslash-split users\\.json" transport run 'cat ~/kg-data/users\.json'
sens_expect_blocked "container-run users.json" transport container-run "cat /app/data/users.json"
sens_expect_blocked "migrate-run python read of users.json" base migrate-run \
  "python3 -c \"print(open('/app/data/users.json').read())\""
sens_expect_blocked "run .env" transport run "cat ~/kg-prod/backend/.env"
sens_expect_blocked "container-run grep .env" transport container-run "grep JWT_SECRET /app/.env"
sens_expect_blocked "operator ~/.secrets dir" transport run "cat ~/.secrets/sentry.env"
sens_expect_blocked "App Store .p8 key" transport run "cat ~/kg-prod/backend/certs/AuthKey_ABC123.p8"
sens_expect_blocked "pem key material" transport container-run "cat /app/certs/server.pem"
sens_expect_blocked "ssh private key" transport run "cat ~/.ssh/id_ed25519"
sens_expect_blocked "container-script content reads users.json" transport \
  container-script "$SENS_FIX/dump_users.py"
sens_expect_blocked "container-script arg names users.json" transport \
  container-script "$SENS_FIX/benign.py" /app/data/users.json
# 誤殺防護：一般唯讀 debug 必須照常抵達 remote。
sens_expect_allowed "list user dirs (no users.json)" "ls -la ~/kg-data/users" transport run "ls -la ~/kg-data/users"
sens_expect_allowed "os.environ is not a .env file" "os.environ" transport run \
  "python3 -c 'import os; print(len(os.environ))'"
sens_expect_allowed "ssh public key" "id_ed25519.pub" transport run "cat ~/.ssh/id_ed25519.pub"
sens_expect_allowed "docker logs window" "docker logs knowledge-graph-api --since 10m" transport run \
  "docker logs knowledge-graph-api --since 10m"
sens_expect_allowed "container-run listing" "docker exec knowledge-graph-api ls /app/data/users" transport \
  container-run "ls /app/data/users"
sens_expect_allowed "migrate-run benign" "migrate-run python3 /app/migrate.py" base migrate-run "python3 /app/migrate.py"
sens_expect_allowed "container-script benign script" "python3 /tmp/benign.py" transport \
  container-script "$SENS_FIX/benign.py" --dry-run
sens_expect_allowed "documented podcast_backfill_disk container-script" "python3 /tmp/podcast_backfill_disk.py --check" \
  transport container-script "$WORKSPACE/ops/podcast_backfill_disk.py" --check
# logs／docker-logs 的行數被拼進 remote shell 字串，`1; cat users.json` 會同時繞過
# is_blocked_run 與上面的 deny-list：只准純數字，否則 exit 64 且不得到達 base。
for sens_sub in logs docker-logs; do
  sens_call base "$sens_sub" '1; cat ~/kg-data/users.json'
  if [[ "$sens_rc" == 64 ]] && grep -q "usage: .* $sens_sub" <<< "$sens_out" && [[ ! -e "$SENS_TRACE" ]]; then
    ok "$sens_sub rejects a non-numeric line count (exit 64) before reaching the base"
  else
    fail_t "$sens_sub LINE-COUNT INJECTION not refused (rc=$sens_rc trace=$([[ -e "$SENS_TRACE" ]] && echo hit || echo none))"
  fi
done
# 正控：純數字與預設值照常透傳，上面的「沒留痕」才不是 stub 壞了。
sens_expect_allowed "logs numeric line count" "logs 7" base logs 7
sens_expect_allowed "logs default line count" "logs 80" base logs
sens_expect_allowed "docker-logs numeric line count" "run docker logs knowledge-graph-api -n 7" base docker-logs 7
rm -rf "$SENS_FIX"

# ── 14. deploy 鎖在 deploy host（felix）上，不在本機（#2266）────────────────
section "deploy lock lives on the deploy host (remote mkdir/rmdir via ssh)"
LOCK_FIX="$(mktemp -d)"
LOCK_STUB="$LOCK_FIX/ssh_stub.sh"
LOCK_LOG="$LOCK_FIX/ssh.log"
LOCK_LOCAL="$LOCK_FIX/local-lock-must-not-exist"
cat > "$LOCK_STUB" <<'STUBEOF'
#!/usr/bin/env bash
# 記下每次遠端指令（最後一個 argv）；STUB_LOCK_HELD=1 時 mkdir 失敗＝遠端鎖已存在。
printf '%s\n' "${@: -1}" >> "$STUB_LOG"
if [[ "${@: -1}" == mkdir\ * && "${STUB_LOCK_HELD:-0}" == "1" ]]; then exit 1; fi
exit 0
STUBEOF
chmod +x "$LOCK_STUB"
for lock_sub in deploy restart migrate; do
  : > "$LOCK_LOG"
  lock_rc=0
  lock_out=$(STUB_LOG="$LOCK_LOG" STUB_LOCK_HELD=1 KG_SSH_CMD="$LOCK_STUB" KG_DEPLOY_LOCK_DIR="$LOCK_LOCAL" bash "$KG" "$lock_sub" 2>&1) || lock_rc=$?
  if [[ "$lock_rc" != 0 ]] && grep -q '另一個 deploy/restart/migrate 正在進行中' <<< "$lock_out"; then
    ok "$lock_sub dies with the lock-held message when the remote lock exists"
  else
    fail_t "$lock_sub did not die with lock-held message (rc=$lock_rc)"
  fi
  grep -q "^mkdir $LOCK_LOCAL\$" "$LOCK_LOG" \
    && ok "$lock_sub attempted the lock through the remote transport" \
    || fail_t "$lock_sub never ran a remote mkdir (lock is local?)"
  [[ "$(wc -l < "$LOCK_LOG" | tr -d ' ')" == 1 ]] \
    && ok "$lock_sub ran nothing else remotely (no compose / VERSION write)" \
    || fail_t "$lock_sub ran remote commands past the held lock: $(tr '\n' '|' < "$LOCK_LOG")"
  [[ ! -e "$LOCK_LOCAL" ]] && ok "$lock_sub left no local lock dir" || fail_t "$lock_sub created a LOCAL lock dir"
done
# acquire / release 都走遠端；HELD 重入不重複 mkdir。
: > "$LOCK_LOG"
lock_rc=0
STUB_LOG="$LOCK_LOG" KG_SSH_CMD="$LOCK_STUB" KG_DEPLOY_LOCK_DIR="$LOCK_LOCAL" DEVOPS_SOURCE_ONLY=1 bash -c \
  'source "$1"; acquire_deploy_lock; acquire_deploy_lock; release_deploy_lock' _ "$KG" >/dev/null 2>&1 || lock_rc=$?
# （EXIT trap 會在 shell 結束時再放一次鎖，故 rmdir 次數不鎖定，只要求每筆都是遠端 rmdir。）
[[ "$lock_rc" == 0 ]] && [[ "$(grep -c '^mkdir ' "$LOCK_LOG")" == 1 ]] \
  && [[ "$(grep -c "^rmdir $LOCK_LOCAL\$" "$LOCK_LOG")" -ge 1 ]] \
  && [[ "$(grep -vc -e '^mkdir ' -e '^rmdir ' "$LOCK_LOG" || true)" == 0 ]] \
  && ok "acquire is re-entrant (one remote mkdir) and release runs remote rmdir" \
  || fail_t "acquire/release remote sequence wrong (rc=$lock_rc): $(tr '\n' '|' < "$LOCK_LOG")"
[[ ! -e "$LOCK_LOCAL" ]] && ok "acquire/release left no local lock dir" || fail_t "acquire created a LOCAL lock dir"
rm -rf "$LOCK_FIX"

# ── 結果 ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════"
echo "  passed: $pass  failed: $fail"
echo "══════════════════════════════"
[[ $fail -eq 0 ]]
