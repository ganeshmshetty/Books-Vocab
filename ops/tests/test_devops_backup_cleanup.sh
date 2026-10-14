#!/usr/bin/env bash
# cleanup_old_backups：保留最新 10 份 data_<date>/ 快照目錄（連同其 .tar.gz／.sha256），
# 且清掉沒有對應目錄的孤兒 tar.gz／sha256。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/hermetic_ops_test.sh
source "$ROOT/ops/lib/hermetic_ops_test.sh"
hermetic_ops_test_init "$ROOT"
pass() { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 在子 shell 載入 devops.sh（source-only seam），對指定 BACKUP_DIR 跑 cleanup。
run_cleanup() {
  ROOT="$ROOT" TARGET="$1" DEVOPS_SOURCE_ONLY=1 KG_SSH_CMD=/usr/bin/true bash -c '
    source "$ROOT/devops.sh"
    BACKUP_DIR="$TARGET"
    cleanup_old_backups
  ' >/dev/null
}

make_runs() { # dir count
  local dir="$1" n="$2" i d
  for ((i = 1; i <= n; i++)); do
    d="data_202601$(printf "%02d" "$i")_000000"
    mkdir -p "$dir/$d"
    : >"$dir/$d/f"
    : >"$dir/$d.tar.gz"
    : >"$dir/$d.tar.gz.sha256"
  done
}

# 12 份 → 剩最新 10 份，各自完整
B1="$TMP/b1"; mkdir -p "$B1"; make_runs "$B1" 12
run_cleanup "$B1"
dirs=$(ls -1d "$B1"/data_*/ | wc -l | tr -d ' ')
[[ "$dirs" == 10 ]] || fail "expected 10 dirs, got $dirs"
for i in 01 02; do
  [[ ! -e "$B1/data_202601${i}_000000" && ! -e "$B1/data_202601${i}_000000.tar.gz" && ! -e "$B1/data_202601${i}_000000.tar.gz.sha256" ]] \
    || fail "oldest run $i not fully removed"
done
for i in 03 04 05 06 07 08 09 10 11 12; do
  p="$B1/data_202601${i}_000000"
  [[ -d "$p" && -f "$p.tar.gz" && -f "$p.tar.gz.sha256" ]] || fail "run $i lost a component"
done
pass "12 runs prune to newest 10 with tar.gz and sha256 intact"

# 10 份 → 不刪
B2="$TMP/b2"; mkdir -p "$B2"; make_runs "$B2" 10
run_cleanup "$B2"
[[ "$(ls -1 "$B2" | wc -l | tr -d ' ')" == 30 ]] || fail "10 runs must not be deleted"
pass "10 runs delete nothing"

# 既有孤兒 → 清掉，完整 run 不動
B3="$TMP/b3"; mkdir -p "$B3"; make_runs "$B3" 3
: >"$B3/data_20250101_000000.tar.gz"
: >"$B3/data_20250101_000000.tar.gz.sha256"
: >"$B3/data_20250102_000000.tar.gz.sha256"
run_cleanup "$B3"
ls "$B3" | grep -q '^data_2025' && fail "orphans remain"
[[ "$(ls -1 "$B3" | wc -l | tr -d ' ')" == 9 ]] || fail "complete runs were disturbed"
pass "orphan tar.gz and sha256 are swept"

# .INCOMPLETE 目錄不占 keep 額度（否則殘缺快照會把好備份擠掉），且一併清掉
B4="$TMP/b4"; mkdir -p "$B4"; make_runs "$B4" 10
mkdir -p "$B4/data_20260199_000000"; : >"$B4/data_20260199_000000/.INCOMPLETE"
run_cleanup "$B4"
for i in 01 02 03 04 05 06 07 08 09 10; do
  [[ -d "$B4/data_202601${i}_000000" ]] || fail "complete run $i evicted by an INCOMPLETE dir"
done
[[ ! -e "$B4/data_20260199_000000" ]] || fail "INCOMPLETE dir not swept"
pass "INCOMPLETE dirs neither evict good runs nor linger"

# #3688：cmd_backup 成功路徑必須清掉 .INCOMPLETE 標記，cleanup_old_backups 才不會刪掉剛驗證過的好備份；
# 同分鐘重試遇到上次殘留標記時亦然。全程以替身 rsync／遠端（無 ssh、無 felix），只在 scratch BACKUP_DIR 寫入。
D=data_20260101_0000
RSYNC_STUB_DIR="$TMP/rsync-stub"; mkdir -p "$RSYNC_STUB_DIR"
# #! 腳本 rsync 替身（過得了 devops tripwire）：--version 回 openrsync；其餘模擬成功拉回，行為由 RSYNC_BODY 注入。
cat >"$RSYNC_STUB_DIR/rsync" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo "openrsync: protocol version 29"; exit 0; fi
dst="${*: -1}"; mkdir -p "$dst"; : >"$dst/users.json"
eval "$RSYNC_BODY"
STUB
chmod 755 "$RSYNC_STUB_DIR/rsync"

run_backup() { # <backup_dir> <rsync_body>：凍結分鐘為 20260101_0000
  ROOT="$ROOT" TARGET="$1" RSYNC_BODY="$2" RSYNC_STUB_DIR="$RSYNC_STUB_DIR" TMP_STAGE_ROOT="$TMP" \
    DEVOPS_SOURCE_ONLY=1 KG_SSH_CMD=/usr/bin/true PATH="$RSYNC_STUB_DIR:$PATH" bash -c '
    source "$ROOT/devops.sh"
    BACKUP_DIR="$TARGET"
    date() { if [[ "${1:-}" == +%Y%m%d_%H%M ]]; then echo 20260101_0000; else command date "$@"; fi; }
    run_remote() {
      case "$1" in
        mktemp*) mktemp -d "$TMP_STAGE_ROOT/kg-db-snapshot.XXXXXX" ;;
        "tar -C "*) eval "$1" ;;
        "bash -s"*) cat >/dev/null ;;
        *) : ;;
      esac
    }
    cmd_backup
  ' >/dev/null 2>&1
}

# 殘留標記 + 同分鐘重試成功 → 好備份存活、標記已清
B5="$TMP/b5"; mkdir -p "$B5/$D"; : >"$B5/$D/.INCOMPLETE"
run_backup "$B5" ':' || fail "successful backup run exited non-zero"
[[ -d "$B5/$D" && -f "$B5/$D.tar.gz" && -f "$B5/$D.tar.gz.sha256" ]] \
  || fail "successful retry was deleted by cleanup_old_backups"
[[ ! -e "$B5/$D/.INCOMPLETE" ]] || fail "successful run left a stale .INCOMPLETE marker"
if tar -tzf "$B5/$D.tar.gz" | grep -q 'INCOMPLETE'; then fail "INCOMPLETE marker leaked into tarball"; fi
pass "same-minute retry succeeds: backup survives cleanup, marker cleared"

# 訊號中斷（INT 於 rsync 途中）→ 標記必須留下，且不得產生 tarball
B6="$TMP/b6"; mkdir -p "$B6"
run_backup "$B6" 'kill -INT $PPID; sleep 1' || true
[[ -d "$B6/$D" && -e "$B6/$D/.INCOMPLETE" ]] || fail "interrupted run must leave .INCOMPLETE on its dir"
[[ ! -e "$B6/$D.tar.gz" ]] || fail "interrupted run must not produce a tarball"
pass "signal-interrupted run keeps .INCOMPLETE"

# 只剩殘缺目錄、清完後已無任何 data_*/：cleanup_old_backups 不得因空 glob 的 ls 非零而中止（#3688 殘留路徑）
B7="$TMP/b7"; mkdir -p "$B7/data_20260199_000000"; : >"$B7/data_20260199_000000/.INCOMPLETE"
run_cleanup "$B7" || fail "cleanup aborted when no data dirs remain"
[[ ! -e "$B7/data_20260199_000000" ]] || fail "lone INCOMPLETE dir not swept"
pass "cleanup survives an emptied backup dir"
