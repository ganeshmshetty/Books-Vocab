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
SSH_STUB="$TMP/bin/local-exec-ssh-stub"
cat >"$SSH_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SNAP_TEST_SSH_LOG:?}"
case "$*" in
  *"${SNAP_TEST_FIXTURE_ROOT:?}"*|*/kg-db-snapshot.*)
    case "$*" in
      "tar -C "*) read -r _t _c stage _r <<<"$*"; stat -f '%Lp' "$stage" >>"${SNAP_TEST_MODE_LOG:?}" ;;
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
    KG_SSH_CMD="$SSH_STUB" PATH="$RSYNC_BIN:$PATH" TMPDIR="$REMOTE_TMP" \
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

printf 'backup snapshot: all checks passed\n'
