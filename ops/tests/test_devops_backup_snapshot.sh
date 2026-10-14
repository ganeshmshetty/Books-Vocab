#!/usr/bin/env bash
# #3442：cmd_backup 必須以 SQLite 一致快照（online backup API）取得 *.db，不得 raw rsync
# live WAL-mode DB（checkpoint 交錯時會漏掉已 commit 的 frame）；快照失敗時 migrate-run
# 必須中止，不得進入 migration。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/hermetic_ops_test.sh
source "$ROOT/ops/lib/hermetic_ops_test.sh"
hermetic_ops_test_init "$ROOT"
pass() { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required for the snapshot fixture"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
SSH_LOG="$TMP/ssh.log"
RSYNC_LOG="$TMP/rsync.log"
: >"$SSH_LOG"
: >"$RSYNC_LOG"

# ssh 替身：把「遠端」shell 字串在本機執行（stdin 原樣轉給 bash），並記下每次呼叫。
# 只放行指向本測試 fixture（SNAP_TEST_FIXTURE_ROOT）或 devops.sh 遠端 mktemp -d 產生的
# 一致快照暫存目錄（kg-db-snapshot.XXXXXX）的字串；其餘（例如預設 ~/kg-data）一律拒絕、exit 97、
# 留 tripwire 痕跡，確保 seam 永遠不會在本機對非 fixture 路徑執行任何指令。
# 對 tar 串流前的暫存目錄記下權限（#3464：必須 0700，不可 world-readable）。
# 可攜：GNU stat（ubuntu-latest CI）用 -c %a；BSD stat（macOS）用 -f %Lp。GNU 的 -f 是
# 檔案系統資訊、不是權限，不可當作第一順位，否則 CI 上會讀成非 700 而誤紅。
SSH_STUB="$TMP/bin/local-exec-ssh-stub"
cat >"$SSH_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SNAP_TEST_SSH_LOG:?}"
case "$*" in
  *"${SNAP_TEST_FIXTURE_ROOT:?}"*|*/kg-db-snapshot.*)
    case "$*" in
      "tar -C "*) read -r _t _c stage _r <<<"$*"; { stat -c '%a' "$stage" 2>/dev/null || stat -f '%Lp' "$stage"; } >>"${SNAP_TEST_MODE_LOG:?}" ;;
    esac
    exec bash -c "$*" ;;
esac
printf 'FORBIDDEN: snapshot test refuses non-fixture remote command: %s\n' "$*" >&2
[ -n "${KG_OPS_TEST_TRIPWIRE_LOG:-}" ] && printf 'snapshot-stub deny: %s\n' "$*" >>"$KG_OPS_TEST_TRIPWIRE_LOG"
exit 97
STUB
chmod 755 "$SSH_STUB"

# rsync 替身（放在 PATH 最前，hermetic shim 之前；tripwire 只認 #! 腳本，這是文件化的測試做法）。
# 模擬 #3442 的失效模式：先拷 main DB 檔，遠端 checkpoint 之後才拷 -wal（checkpoint 已把
# WAL frame 併進 main 並重置 WAL）。最後兩個參數為 來源 與 目的地。
RSYNC_BIN="$TMP/rsync-bin"
mkdir -p "$RSYNC_BIN"
RSYNC_STUB="$RSYNC_BIN/rsync"
cat >"$RSYNC_STUB" <<'STUB'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == --version ]]; then
  echo "openrsync: protocol version 29"
  exit 0
fi
printf '%s\n' "$*" >>"${SNAP_TEST_RSYNC_LOG:?}"
src=""; dst=""
for a; do src="$dst"; dst="$a"; done
src="${src#*:}"; src="${src%/}"
mkdir -p "$dst/users/u1"
cp "$src/users/u1/cards.db" "$dst/users/u1/cards.db"
sqlite3 "$src/users/u1/cards.db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
if [[ -f "$src/users/u1/cards.db-wal" ]]; then
  cp "$src/users/u1/cards.db-wal" "$dst/users/u1/cards.db-wal"
fi
exit 0
STUB
chmod 755 "$RSYNC_STUB"

# 造一個 live 狀態：row 1 已 checkpoint 進主檔，row 2 只存在於 -wal 且已 commit。
# no_ckpt_on_close 讓 CLI 關閉時不 checkpoint，WAL 因而保留（與 backend 持續開著 DB 同態）。
make_wal_fixture() { # <data_dir>
  local db="$1/users/u1/cards.db"
  mkdir -p "$(dirname "$db")"
  sqlite3 -cmd '.dbconfig no_ckpt_on_close on' "$db" \
    "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
     CREATE TABLE card(id INTEGER PRIMARY KEY, body TEXT);
     INSERT INTO card VALUES(1,'checkpointed');
     PRAGMA wal_checkpoint(TRUNCATE);
     INSERT INTO card VALUES(2,'wal-only');" >/dev/null
}

DATA_OK="$TMP/remote-ok"
make_wal_fixture "$DATA_OK"
[[ -s "$DATA_OK/users/u1/cards.db-wal" ]] || fail "fixture: row 2 must sit in the -wal file"
cp "$DATA_OK/users/u1/cards.db" "$TMP/raw-main-only.db"
raw_count="$(sqlite3 "$TMP/raw-main-only.db" 'SELECT COUNT(*) FROM card;')"
[[ "$raw_count" == 1 ]] || fail "fixture: main file alone must lack the WAL-only row (got $raw_count)"

# ── 1. 一致快照：WAL-only 已 commit 的 row 必須出現在備份輸出 ───────────────
# 遠端暫存根目錄（TMPDIR 指到這裡，便於斷言失敗後無殘留 kg-db-snapshot.*）。
REMOTE_TMP="$TMP/remote-tmp"
mkdir -p "$REMOTE_TMP"
MODE_LOG="$TMP/stage-mode.log"
: >"$MODE_LOG"
run_backup() { # <data_dir> <backup_dir> <cmd>
  ROOT="$ROOT" TARGET="$2" DATA="$1" CMD="$3" DEVOPS_SOURCE_ONLY=1 \
    KG_OPS_TEST=1 KG_SERVER=test-host KG_REMOTE_DATA_DIR="$1" \
    KG_SSH_CMD="${SSH_STUB_OVERRIDE:-$SSH_STUB}" PATH="${RSYNC_STUB_DIR:-$RSYNC_BIN}:$PATH" TMPDIR="$REMOTE_TMP" \
    SNAP_TEST_SSH_LOG="$SSH_LOG" SNAP_TEST_RSYNC_LOG="$RSYNC_LOG" SNAP_TEST_FIXTURE_ROOT="$TMP" \
    SNAP_TEST_MODE_LOG="$MODE_LOG" \
    bash -c 'source "$ROOT/devops.sh"; BACKUP_DIR="$TARGET"; eval "$CMD"'
}

OUT_OK="$TMP/backups-ok"; mkdir -p "$OUT_OK"
set +e
run_backup "$DATA_OK" "$OUT_OK" cmd_backup >"$TMP/backup.out" 2>&1
rc=$?
set -e
(( rc == 0 )) || { cat "$TMP/backup.out" >&2; fail "cmd_backup failed on a healthy WAL fixture (rc=$rc)"; }
snap_db="$(find "$OUT_OK" -path '*/users/u1/cards.db' -type f | head -n 1)"
[[ -n "$snap_db" ]] || fail "cmd_backup produced no users/u1/cards.db"
snap_count="$(sqlite3 "$snap_db" 'SELECT COUNT(*) FROM card;')"
[[ "$snap_count" == 2 ]] \
  || fail "backup lost a committed WAL-only row (rows=$snap_count, want 2): raw rsync of live WAL-mode DB"
pass "cmd_backup snapshot keeps the committed WAL-only row"

# 遠端暫存目錄必須是 mktemp -d 建立的 0700（不可為可預測、world-readable 的 /tmp 路徑）
[[ "$(cat "$MODE_LOG")" == 700 ]] \
  || fail "remote snapshot stage must be mktemp -d 0700 (got mode $(cat "$MODE_LOG"))"
pass "remote snapshot stage is mode 0700"

# ── 2. 快照失敗 → migrate-run 中止，不 pull、不進容器 ─────────────────────────
DATA_BAD="$TMP/remote-bad"
mkdir -p "$DATA_BAD/users/u1"
printf 'not a sqlite database\n' >"$DATA_BAD/users/u1/cards.db"
: >"$SSH_LOG"; : >"$RSYNC_LOG"
OUT_BAD="$TMP/backups-bad"; mkdir -p "$OUT_BAD"
set +e
run_backup "$DATA_BAD" "$OUT_BAD" 'cmd_migrate_run "echo migration-ran"' >"$TMP/migrate.out" 2>&1
mig_rc=$?
set -e
(( mig_rc != 0 )) || fail "migrate-run proceeded although the pre-migration snapshot failed"
if grep -Fq 'migration-ran' "$TMP/migrate.out" || grep -Fq 'docker' "$SSH_LOG"; then
  fail "migrate-run reached the container step after a failed snapshot"
fi
[[ ! -s "$RSYNC_LOG" ]] || fail "migrate-run pulled data after a failed snapshot"
pass "migrate-run aborts before pull and migration when the snapshot fails"

# ── 3. #3479：symlink 的 *.db 不可被靜默漏掉 ───────────────────────────────
# users/u1/cards.db 是指向 data 目錄外真實 DB 的 symlink；真實 DB 的 WAL-only row 必須進備份。
LINK_REAL="$TMP/link-target"
make_wal_fixture "$LINK_REAL"
DATA_LINK="$TMP/remote-link"
mkdir -p "$DATA_LINK/users/u1"
ln -s "$LINK_REAL/users/u1/cards.db" "$DATA_LINK/users/u1/cards.db"
OUT_LINK="$TMP/backups-link"; mkdir -p "$OUT_LINK"
set +e
run_backup "$DATA_LINK" "$OUT_LINK" cmd_backup >"$TMP/link.out" 2>&1
link_rc=$?
set -e
(( link_rc == 0 )) || { cat "$TMP/link.out" >&2; fail "cmd_backup failed on a symlinked *.db fixture (rc=$link_rc)"; }
link_db="$(find "$OUT_LINK" -path '*/users/u1/cards.db' -type f | head -n 1)"
[[ -n "$link_db" ]] || fail "symlinked *.db was silently dropped from the backup"
link_count="$(sqlite3 "$link_db" 'SELECT COUNT(*) FROM card;')"
[[ "$link_count" == 2 ]] \
  || fail "symlinked *.db not snapshotted (rows=$link_count, want 2): find -type f skips symlinks"
pass "symlinked *.db is snapshotted into the backup"

# ── 4. #3464：快照失敗（損毀 DB）時遠端暫存目錄必須被清掉 ────────────────────
DATA_CORRUPT="$TMP/remote-corrupt"
mkdir -p "$DATA_CORRUPT/users/u1"
printf 'not a sqlite database\n' >"$DATA_CORRUPT/users/u1/cards.db"
OUT_CORRUPT="$TMP/backups-corrupt"; mkdir -p "$OUT_CORRUPT"
set +e
run_backup "$DATA_CORRUPT" "$OUT_CORRUPT" cmd_backup >"$TMP/corrupt.out" 2>&1
corrupt_rc=$?
set -e
(( corrupt_rc != 0 )) || fail "cmd_backup must fail on a corrupt DB"
leftover="$(find "$REMOTE_TMP" -mindepth 1 -maxdepth 1 -name 'kg-db-snapshot.*' | head -n 1)"
[[ -z "$leftover" ]] || fail "failed snapshot left a remote stage behind: $leftover"
pass "failed snapshot removes its remote stage"

# ── 5. #3464：快照成功後、拉回前被 INT 中斷，遠端暫存目錄仍須清掉 ───────────────
# rsync 替身：--version 照常回應；真正執行時模擬 Ctrl-C 落在 rsync 途中——父 shell（cmd_backup
# 所在程序）與替身自己都收到 INT，替身因 SIGINT 死亡（非 exit N；bash 只會因子程序被信號殺死才跟著中斷）。
# 修前沒有本地 INT cleanup，父程序直接死掉，stage 殘留在 REMOTE_TMP。
RSYNC_INT_BIN="$TMP/rsync-int-bin"
mkdir -p "$RSYNC_INT_BIN"
RSYNC_INT_STUB="$RSYNC_INT_BIN/rsync"
cat >"$RSYNC_INT_STUB" <<'STUB'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == --version ]]; then
  echo "openrsync: protocol version 29"
  exit 0
fi
kill -INT "$PPID"
kill -INT "$$"
STUB
chmod 755 "$RSYNC_INT_STUB"

DATA_INT="$TMP/remote-int"
make_wal_fixture "$DATA_INT"
OUT_INT="$TMP/backups-int"; mkdir -p "$OUT_INT"
set +e
RSYNC_STUB_DIR="$RSYNC_INT_BIN" run_backup "$DATA_INT" "$OUT_INT" cmd_backup >"$TMP/int.out" 2>&1
int_rc=$?
set -e
(( int_rc != 0 )) || fail "cmd_backup interrupted by SIGINT must not report success"
leftover="$(find "$REMOTE_TMP" -mindepth 1 -maxdepth 1 -name 'kg-db-snapshot.*' | head -n 1)"
[[ -z "$leftover" ]] || fail "interrupted cmd_backup left a remote stage behind: $leftover"
pass "SIGINT during rsync removes the remote stage"

# ── 6. #3464：快照階段中被 INT（bash -s 尚未完成），已建立的遠端 stage 仍須清掉 ──────
# 本機在快照前就持有 stage（遠端 mktemp -d 之後立即接管）。這支 ssh 替身讓 mktemp 正常執行，
# 然後在 `bash -s` 那一步模擬 Ctrl-C：父 shell 與替身都收到 INT，快照本身不跑。
SSH_SNAP_INT_STUB="$TMP/bin/snapshot-int-ssh-stub"
cat >"$SSH_SNAP_INT_STUB" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "bash -s -- "*) kill -INT "$PPID"; kill -INT "$$" ;;
  *) exec "$(dirname "$0")/local-exec-ssh-stub" "$@" ;;
esac
STUB
chmod 755 "$SSH_SNAP_INT_STUB"

DATA_SNAP_INT="$TMP/remote-snap-int"
make_wal_fixture "$DATA_SNAP_INT"
OUT_SNAP_INT="$TMP/backups-snap-int"; mkdir -p "$OUT_SNAP_INT"
set +e
SSH_STUB_OVERRIDE="$SSH_SNAP_INT_STUB" run_backup "$DATA_SNAP_INT" "$OUT_SNAP_INT" cmd_backup >"$TMP/snap-int.out" 2>&1
snap_int_rc=$?
set -e
(( snap_int_rc != 0 )) || fail "cmd_backup interrupted during the snapshot must not report success"
leftover="$(find "$REMOTE_TMP" -mindepth 1 -maxdepth 1 -name 'kg-db-snapshot.*' | head -n 1)"
[[ -z "$leftover" ]] || fail "snapshot-phase interrupt left a remote stage behind: $leftover"
pass "SIGINT during the snapshot removes the pre-created remote stage"

# ── 7. #3561：symlink 目錄下的 *.db 不可被靜默漏掉 ───────────────────────────
# users/u2 是指向 data 目錄外某目錄的 symlink，該目錄內 cards.db 含 WAL-only row。
# 遠端 find 不進入目錄 symlink 時，這顆 DB 不進快照，備份無聲缺失。
# rsync 替身模擬真實 rsync：無 --copy-links 時複製 symlink 本身（tar 不解參照），
# 有 --copy-links 時解參照（tar -h）。若 dest 殘留 symlink，tar 拉回會穿過它寫進外部目錄，
# 因此下方同時斷言拉回的 users/u2 是真目錄、外部來源 DB 未被改寫。
OUTSIDE_ROOT="$TMP/outside-root"
make_wal_fixture "$OUTSIDE_ROOT"
DATA_DIRLINK="$TMP/remote-dirlink"
mkdir -p "$DATA_DIRLINK/users"
ln -s "$OUTSIDE_ROOT/users/u1" "$DATA_DIRLINK/users/u2"
outside_before="$(sqlite3 "$OUTSIDE_ROOT/users/u1/cards.db" 'SELECT COUNT(*) FROM card;')"
RSYNC_MODEL_BIN="$TMP/rsync-model-bin"
mkdir -p "$RSYNC_MODEL_BIN"
cat >"$RSYNC_MODEL_BIN/rsync" <<'STUB'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == --version ]]; then
  echo "openrsync: protocol version 29"
  exit 0
fi
printf '%s\n' "$*" >>"${SNAP_TEST_RSYNC_LOG:?}"
deref=()
src=""; dst=""
for a; do
  [[ "$a" == --copy-links ]] && deref=(-h)
  src="$dst"; dst="$a"
done
src="${src#*:}"; src="${src%/}"
mkdir -p "$dst"
tar -C "$src" "${deref[@]}" -cf - \
  --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.db-journal' . \
  | tar -C "$dst" -xf -
exit 0
STUB
chmod 755 "$RSYNC_MODEL_BIN/rsync"
# sqlite3 spy（#3578）：記下遠端快照開 DB 的 URI，斷言symlink 目錄下的外部 DB 以 mode=ro 開啟。
REAL_SQLITE3="$(command -v sqlite3)"
SQLITE_LOG="$TMP/sqlite-spy.log"
: >"$SQLITE_LOG"
cat >"$RSYNC_MODEL_BIN/sqlite3" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SNAP_TEST_SQLITE_LOG:?}"
exec "${SNAP_TEST_REAL_SQLITE3:?}" "$@"
STUB
chmod 755 "$RSYNC_MODEL_BIN/sqlite3"
outside_snapshot_copy="$TMP/outside-u1-before.db"
cp "$OUTSIDE_ROOT/users/u1/cards.db" "$outside_snapshot_copy"
OUT_DIRLINK="$TMP/backups-dirlink"; mkdir -p "$OUT_DIRLINK"
set +e
RSYNC_STUB_DIR="$RSYNC_MODEL_BIN" SNAP_TEST_SQLITE_LOG="$SQLITE_LOG" SNAP_TEST_REAL_SQLITE3="$REAL_SQLITE3" \
  run_backup "$DATA_DIRLINK" "$OUT_DIRLINK" cmd_backup >"$TMP/dirlink.out" 2>&1
dirlink_rc=$?
set -e
(( dirlink_rc == 0 )) || { cat "$TMP/dirlink.out" >&2; fail "cmd_backup failed on a symlinked-directory fixture (rc=$dirlink_rc)"; }
grep -Fq 'users/u2/cards.db?mode=ro' "$SQLITE_LOG" \
  || fail "symlink-followed *.db was not opened read-only (mode=ro) by the remote snapshot"
if grep -Fq 'users/u2/cards.db?mode=rw' "$SQLITE_LOG"; then
  fail "symlink-followed *.db was opened read-write (mode=rw) outside the data dir"
fi
cmp -s "$OUTSIDE_ROOT/users/u1/cards.db" "$outside_snapshot_copy" \
  || fail "outside source DB bytes changed during the symlinked-dir snapshot"
pass "symlink-followed *.db is opened read-only and the outside source stays byte-identical"
dirlink_db="$(find "$OUT_DIRLINK" -path '*/users/u2/cards.db' -type f | head -n 1)"
[[ -n "$dirlink_db" ]] || fail "*.db under a symlinked directory was silently dropped from the backup"
[[ ! -L "$(dirname "$dirlink_db")" ]] || fail "restored users/u2 is still a symlink; tar wrote through it"
dirlink_count="$(sqlite3 "$dirlink_db" 'SELECT COUNT(*) FROM card;')"
[[ "$dirlink_count" == 2 ]] \
  || fail "symlinked-dir *.db not snapshotted (rows=$dirlink_count, want 2): remote find did not follow the directory symlink"
[[ "$(sqlite3 "$OUTSIDE_ROOT/users/u1/cards.db" 'SELECT COUNT(*) FROM card;')" == "$outside_before" ]] \
  || fail "backup wrote through the symlink into the source directory"
pass "*.db under a symlinked directory is snapshotted with its WAL rows"

# ── 8. #3474：未變的 *.db 必須硬連結到增量基準，變動的不可連結 ─────────────────
# *.db 不走 rsync --link-dest（改由一致快照 tar 拉回），因此必須在拉回後以位元組比對補硬連結。
# 基準目錄 .INCOMPLETE 者不得成為基準。
DATA_LINKB="$TMP/remote-linkb"
make_wal_fixture "$DATA_LINKB"
U2_SRC="$TMP/linkb-u2"
make_wal_fixture "$U2_SRC"
mkdir -p "$DATA_LINKB/users"
mv "$U2_SRC/users/u1" "$DATA_LINKB/users/u2"
OUT_LINKB="$TMP/backups-linkb"; mkdir -p "$OUT_LINKB"
run_backup "$DATA_LINKB" "$OUT_LINKB" cmd_backup >"$TMP/linkb1.out" 2>&1 \
  || { cat "$TMP/linkb1.out" >&2; fail "cmd_backup baseline run failed"; }
# 同一分鐘內的兩次 run 目錄名相同：把第一份改名成更早的時間戳，使其成為下一次的增量基準。
first_dir="$(find "$OUT_LINKB" -mindepth 1 -maxdepth 1 -type d -name 'data_*' | head -n 1)"
[[ -n "$first_dir" ]] || fail "baseline run produced no data_* directory"
mv "$first_dir" "$OUT_LINKB/data_20200101_0000"
# 第二次 run 前只改 users/u1（變動），users/u2 保持不變（未變）。
sqlite3 "$DATA_LINKB/users/u1/cards.db" "INSERT INTO card VALUES(3,'changed');" </dev/null
run_backup "$DATA_LINKB" "$OUT_LINKB" cmd_backup >"$TMP/linkb2.out" 2>&1 \
  || { cat "$TMP/linkb2.out" >&2; fail "cmd_backup incremental run failed"; }
second_dir="$(find "$OUT_LINKB" -mindepth 1 -maxdepth 1 -type d -name 'data_*' ! -name 'data_20200101_0000' | head -n 1)"
[[ -n "$second_dir" ]] || fail "incremental run produced no data_* directory"
inode_of() { ls -i "$1" | awk '{print $1}'; }
base_u2="$OUT_LINKB/data_20200101_0000/users/u2/cards.db"
new_u2="$second_dir/users/u2/cards.db"
base_u1="$OUT_LINKB/data_20200101_0000/users/u1/cards.db"
new_u1="$second_dir/users/u1/cards.db"
[[ "$(inode_of "$new_u2")" == "$(inode_of "$base_u2")" ]] \
  || fail "unchanged users/u2/cards.db was not hardlinked to the incremental base"
pass "unchanged *.db is hardlinked to the incremental base"
[[ "$(inode_of "$new_u1")" != "$(inode_of "$base_u1")" ]] \
  || fail "changed users/u1/cards.db was hardlinked to the stale base"
[[ "$(sqlite3 "$new_u1" 'SELECT COUNT(*) FROM card;')" == 3 ]] \
  || fail "changed users/u1/cards.db lost the new row"
pass "changed *.db is not linked to the base and keeps its new content"

# 基準帶 .INCOMPLETE：即使它是唯一候選，也不得被用來硬連結。
OUT_INC="$TMP/backups-inc"; mkdir -p "$OUT_INC"
run_backup "$DATA_LINKB" "$OUT_INC" cmd_backup >"$TMP/inc1.out" 2>&1 \
  || { cat "$TMP/inc1.out" >&2; fail "cmd_backup incomplete-base fixture run failed"; }
inc_first="$(find "$OUT_INC" -mindepth 1 -maxdepth 1 -type d -name 'data_*' | head -n 1)"
mv "$inc_first" "$OUT_INC/data_20200101_0000"
touch "$OUT_INC/data_20200101_0000/.INCOMPLETE"
# 殘缺基準會在本次 run 結尾被 cleanup_old_backups 刪除，故先記下其 inode。
inc_base_inode="$(inode_of "$OUT_INC/data_20200101_0000/users/u2/cards.db")"
run_backup "$DATA_LINKB" "$OUT_INC" cmd_backup >"$TMP/inc2.out" 2>&1 \
  || { cat "$TMP/inc2.out" >&2; fail "cmd_backup run with incomplete base failed"; }
inc_second="$(find "$OUT_INC" -mindepth 1 -maxdepth 1 -type d -name 'data_*' ! -name 'data_20200101_0000' | head -n 1)"
[[ -n "$inc_second" && -n "$inc_base_inode" ]] || fail "incomplete-base run produced no comparable backup"
[[ "$(inode_of "$inc_second/users/u2/cards.db")" != "$inc_base_inode" ]] \
  || fail ".INCOMPLETE base was used as the hardlink source"
pass ".INCOMPLETE base is never used for hardlinks"

# ── 9. #3578：懸空的非 DB symlink 不可讓 rsync（--copy-links）整段中止 ─────────
# 真 rsync 對懸空 symlink 在 --copy-links 下回 exit 23（"symlink has no referent"）。替身模擬此行為：
# 未被 --exclude-from 排除的懸空 symlink → exit 23。cmd_backup 必須預先排除並具名警告，仍 exit 0；
# 懸空 *.db symlink 則維持 #3479 的 fail-closed（不在此範圍）。
DATA_DANGLE="$TMP/remote-dangle"
make_wal_fixture "$DATA_DANGLE"
ln -s "$TMP/no-such-target.txt" "$DATA_DANGLE/users/u1/notes.txt"
RSYNC_DANGLE_BIN="$TMP/rsync-dangle-bin"
mkdir -p "$RSYNC_DANGLE_BIN"
cat >"$RSYNC_DANGLE_BIN/rsync" <<'STUB'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == --version ]]; then
  echo "openrsync: protocol version 29"
  exit 0
fi
printf '%s\n' "$*" >>"${SNAP_TEST_RSYNC_LOG:?}"
excl=""; src=""; dst=""
for a; do
  case "$a" in --exclude-from=*) excl="${a#--exclude-from=}" ;; esac
  src="$dst"; dst="$a"
done
src="${src#*:}"; src="${src%/}"
rc=0
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  if [[ -z "$excl" ]] || ! grep -qxF "/${rel#./}" "$excl"; then
    echo "rsync: symlink has no referent: \"$src/${rel#./}\"" >&2
    rc=23
  fi
done < <(cd "$src" && find -L . -type l)
exit "$rc"
STUB
chmod 755 "$RSYNC_DANGLE_BIN/rsync"
OUT_DANGLE="$TMP/backups-dangle"; mkdir -p "$OUT_DANGLE"
set +e
RSYNC_STUB_DIR="$RSYNC_DANGLE_BIN" run_backup "$DATA_DANGLE" "$OUT_DANGLE" cmd_backup >"$TMP/dangle.out" 2>&1
dangle_rc=$?
set -e
(( dangle_rc == 0 )) || { cat "$TMP/dangle.out" >&2; fail "dangling non-DB symlink aborted cmd_backup (rc=$dangle_rc)"; }
grep -Fq 'notes.txt' "$TMP/dangle.out" \
  || fail "skipped dangling symlink was not named in a warning"
dangle_db="$(find "$OUT_DANGLE" -path '*/users/u1/cards.db' -type f | head -n 1)"
[[ -n "$dangle_db" ]] || fail "dangling non-DB symlink suppressed the DB snapshot"
[[ "$(sqlite3 "$dangle_db" 'SELECT COUNT(*) FROM card;')" == 2 ]] \
  || fail "snapshot after dangling-link skip lost the WAL-only row"
pass "dangling non-DB symlink is skipped with a warning and does not abort the backup"

printf 'backup snapshot: all checks passed\n'
