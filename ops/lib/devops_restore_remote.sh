#!/usr/bin/env bash
# devops_restore_remote.sh — `devops.sh restore <YYYY-MM-DD>` 在遠端 standby 執行的固定腳本（#2923）。
#
# 唯一被授權覆寫 kg-data 的路徑。devops.sh cmd_restore 以
#   bash -s -- <date> <bucket> <data> <compose>
# 經 ssh 的 stdin 餵入本檔。ops/test_devops.sh §15 直接以本地 bash 執行同一檔（HOME 指向 fixture、
# aws／docker 為 stub），不經任何 transport。任何一道驗證失敗都在動到現況之前中止；swap 失敗會把現況搬回。
set -euo pipefail

DATE="$1"; BUCKET="$2"; DATA="${3/#\~/$HOME}"; COMPOSE_DIR="${4/#\~/$HOME}"
LOG="$HOME/Library/Logs/kg_backup.log"
die() { echo "✗ $*" >&2; exit 1; }
start_back() { (cd "$COMPOSE_DIR" && docker compose up -d) || { echo "✗ 容器啟動失敗" >&2; return 1; }; }

# 1. 來源可信：backup log 必須有該日成功紀錄，且 sha256 與 S3 物件一致
REC=$(grep -F "key=data/${DATE}.tar.gz" "$LOG" 2>/dev/null | grep ' exit=0 ' | tail -1 || true)
[[ -n "$REC" ]] || die "backup log 無 ${DATE} 成功紀錄（$LOG），拒絕 restore"
WANT=$(sed -n 's/.* sha256=\([0-9a-f]\{64\}\).*/\1/p' <<< "$REC")
[[ -n "$WANT" ]] || die "backup log 紀錄缺 sha256，拒絕 restore"

STAGE=$(mktemp -d "$HOME/kg-restore-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
aws s3 cp "s3://$BUCKET/data/$DATE.tar.gz" "$STAGE/archive.tar.gz" --only-show-errors || die "S3 下載失敗"
GOT=$(shasum -a 256 "$STAGE/archive.tar.gz" | awk '{print $1}')
[[ "$GOT" == "$WANT" ]] || die "sha256 不符（log=$WANT object=$GOT），拒絕 restore"

# 2. archive 結構：第一層 == basename(DATA)，無絕對或上層路徑，無第一層以外的條目
tar tzf "$STAGE/archive.tar.gz" > "$STAGE/list" || die "archive 無法列出（損毀或下載不完整），拒絕 restore"
grep -Eq '^/|(^|/)\.\.(/|$)' "$STAGE/list" && die "archive 含絕對或上層路徑，拒絕 restore"
ROOT=$(sed -n 1p "$STAGE/list" | cut -d/ -f1)
[[ "$ROOT" == "$(basename "$DATA")" ]] || die "archive 第一層 '$ROOT' ≠ $(basename "$DATA")，拒絕 restore"
grep -qv "^$ROOT/" "$STAGE/list" && die "archive 含第一層以外的條目，拒絕 restore"

# 3. staging 解壓 + 每個 *.db 須 PRAGMA quick_check=ok
mkdir "$STAGE/x"
tar xzf "$STAGE/archive.tar.gz" -C "$STAGE/x" || die "archive 解壓失敗，現況未動，拒絕 restore"
NEW="$STAGE/x/$ROOT"
[[ -d "$NEW" ]] || die "解壓後找不到 $NEW"
bad=0
while IFS= read -r -d '' db; do
  r=$(sqlite3 "$db" 'PRAGMA quick_check;' 2>&1) || r="sqlite3 error"
  [[ "$r" == "ok" ]] || { echo "✗ quick_check 失敗: $db ($r)" >&2; bad=1; }
done < <(find "$NEW" -name '*.db' -print0)
[[ $bad -eq 0 ]] || die "staging 資料庫完整性檢查未過，現況未動，拒絕 restore"

# 4. swap：停容器 → 現況改名保留（不 rm）→ 新資料就位 → 起容器
echo "▶ 停止容器（swap 期間不得寫入 kg-data）"
(cd "$COMPOSE_DIR" && docker compose stop) || die "停止容器失敗，現況未動，拒絕 restore"
TS=$(date -u +%Y%m%dT%H%M%SZ)
BROKEN=""
if [[ -e "$DATA" ]]; then
  BROKEN="$DATA.broken.$TS"
  mv "$DATA" "$BROKEN" || { start_back || true; die "無法保留現況 $DATA，已中止"; }
fi
if ! mv "$NEW" "$DATA"; then
  if [[ -n "$BROKEN" ]] && ! mv "$BROKEN" "$DATA"; then
    echo "✗ 回滾失敗：現況保留於 $BROKEN，容器未啟動，需人工介入" >&2
    exit 2
  fi
  start_back || { echo "✗ 已還原現況 $DATA 但容器未啟動，需人工介入" >&2; exit 2; }
  die "swap 失敗，已還原現況"
fi
if ! start_back; then
  echo "✗ 資料已還原但容器未啟動：$DATA ← s3://$BUCKET/data/$DATE.tar.gz（現況保留於 ${BROKEN:-（無既有現況）}），需人工介入" >&2
  exit 2
fi
echo "✓ restore 完成：$DATA ← s3://$BUCKET/data/$DATE.tar.gz（現況保留於 ${BROKEN:-（無既有現況）}）"
