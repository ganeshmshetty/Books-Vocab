#!/usr/bin/env bash
# devops_restore_remote.sh — `devops.sh restore <YYYY-MM-DD>` 在遠端 standby 執行的固定腳本（#2923）。
#
# 唯一被授權覆寫 kg-data 的路徑。devops.sh cmd_restore 以
#   bash -s -- <date> <bucket> <data> <compose> <confirm> <lock>
# 經 ssh 的 stdin 餵入本檔；<confirm> 必須是 "restore <date> <bucket>"（本次操作的確認字串）；
# <lock> 是遠端 deploy 鎖目錄（與 deploy／restart／migrate／kg_reconcile.sh 同一把）。
#
# 鎖由本程序自持：第一個讀寫動作之前 mkdir 取得；正常結束、或容器尚未停止前的任何失敗才 rmdir。
# 容器已停（或狀態未知）之後的任何失敗都保留鎖，deploy／restart／migrate 因此拒絕，直到人工確認後 rmdir。
# 本機 devops.sh 不取鎖、不釋放鎖，ssh 中斷或本機 INT／TERM 都不會替仍在 swap 的遠端程序放行。
#
# ops/test_devops.sh §15 直接以本地 bash 執行同一檔（HOME 指向 fixture、aws／docker 為 stub），不經任何 transport。
# 任何一道驗證失敗都在動到現況之前中止；swap 失敗且已還原並起回容器才釋放鎖。
# 本檔不做 TTY 檢查（ssh stdin 不是 TTY）；TTY 與 DEVOPS_YES 閘門在本機 devops.sh，是防誤觸，不是遠端授權控制。
set -euo pipefail

DATE="$1"; BUCKET="$2"; DATA="${3/#\~/$HOME}"; COMPOSE_DIR="${4/#\~/$HOME}"; TOKEN="${5:-}"; LOCK="${6:-}"
LOG="$HOME/Library/Logs/kg_backup.log"
STAGE=""
LOCK_OWNED=0   # 只有本程序 mkdir 成功才為 1；他人持有的鎖絕不 rmdir
KEEP_LOCK=0    # 1 = 容器可能已停或狀態未知，EXIT 時保留鎖
die() { echo "✗ $*" >&2; exit 1; }
start_back() { (cd "$COMPOSE_DIR" && docker compose up -d) || { echo "✗ 容器啟動失敗" >&2; return 1; }; }
on_exit() {
  [[ -z "$STAGE" ]] || rm -rf "$STAGE"
  if [[ "$LOCK_OWNED" == 1 && "$KEEP_LOCK" != 1 ]]; then rmdir "$LOCK" 2>/dev/null || true; fi
  return 0
}
trap on_exit EXIT

# 0. 確認字串必須與本次日期與 bucket 綁定：遠端再驗一次，確認不能拿去套用到其他日期或 bucket
[[ "$TOKEN" == "restore ${DATE} ${BUCKET}" ]] || die "確認字串不符（需 restore <date> <bucket>），拒絕 restore"
[[ -n "$LOCK" ]] || die "缺少 deploy 鎖路徑，拒絕 restore"

# 0b. 互斥：與 deploy／restart／migrate／kg_reconcile 共用同一把鎖。被他人持有即拒絕，且不動他人的鎖
mkdir "$LOCK" 2>/dev/null || die "另一個 deploy/restart/migrate 正在進行中（${LOCK} 已存在）。若確認無進行中操作，請在 deploy host 手動 rmdir ${LOCK}"
LOCK_OWNED=1

# 1. 來源可信：backup log 必須有該日成功紀錄，且 sha256 與 S3 物件一致
REC=$(grep -F "key=data/${DATE}.tar.gz" "$LOG" 2>/dev/null | grep ' exit=0 ' | tail -1 || true)
[[ -n "$REC" ]] || die "backup log 無 ${DATE} 成功紀錄（${LOG}），拒絕 restore"
WANT=$(sed -n 's/.* sha256=\([0-9a-f]\{64\}\).*/\1/p' <<< "$REC")
[[ -n "$WANT" ]] || die "backup log 紀錄缺 sha256，拒絕 restore"

STAGE=$(mktemp -d "$HOME/kg-restore-stage.XXXXXX")
aws s3 cp "s3://${BUCKET}/data/${DATE}.tar.gz" "$STAGE/archive.tar.gz" --only-show-errors || die "S3 下載失敗"
GOT=$(shasum -a 256 "$STAGE/archive.tar.gz" | awk '{print $1}')
[[ "$GOT" == "$WANT" ]] || die "sha256 不符（log=${WANT} object=${GOT}），拒絕 restore"

# 2. archive 結構：第一層 == basename(DATA)，無絕對或上層路徑，無第一層以外的條目，只允許一般檔與目錄
#    （symlink、hardlink、裝置檔一律拒絕：解壓後 symlink 可把寫入導向 kg-data 之外）
tar tzf "$STAGE/archive.tar.gz" > "$STAGE/list" || die "archive 無法列出（損毀或下載不完整），拒絕 restore"
tar tvzf "$STAGE/archive.tar.gz" > "$STAGE/vlist" || die "archive 無法列出（損毀或下載不完整），拒絕 restore"
grep -Eq '^/|(^|/)\.\.(/|$)' "$STAGE/list" && die "archive 含絕對或上層路徑，拒絕 restore"
grep -Eqv '^[-d]' "$STAGE/vlist" && die "archive 含非一般檔或目錄的條目（symlink／hardlink／裝置檔），拒絕 restore"
ROOT=$(sed -n 1p "$STAGE/list" | cut -d/ -f1)
[[ "$ROOT" == "$(basename "$DATA")" ]] || die "archive 第一層 '${ROOT}' ≠ $(basename "$DATA")，拒絕 restore"
grep -qv "^$ROOT/" "$STAGE/list" && die "archive 含第一層以外的條目，拒絕 restore"

# 3. staging 解壓 + 每個 *.db 須 PRAGMA quick_check=ok
mkdir "$STAGE/x"
tar xzf "$STAGE/archive.tar.gz" -C "$STAGE/x" || die "archive 解壓失敗，現況未動，拒絕 restore"
NEW="$STAGE/x/$ROOT"
[[ -d "$NEW" ]] || die "解壓後找不到 ${NEW}"
bad=0
while IFS= read -r -d '' db; do
  r=$(sqlite3 "$db" 'PRAGMA quick_check;' 2>&1) || r="sqlite3 error"
  [[ "$r" == "ok" ]] || { echo "✗ quick_check 失敗: $db ($r)" >&2; bad=1; }
done < <(find "$NEW" -name '*.db' -print0)
[[ $bad -eq 0 ]] || die "staging 資料庫完整性檢查未過，現況未動，拒絕 restore"

# 4. swap：停容器 → 現況改名保留（不 rm）→ 新資料就位 → 起容器
#    自此起容器與資料狀態未知；之後的任何失敗都保留鎖，直到容器確認起回且資料位置已知。
KEEP_LOCK=1
echo "▶ 停止容器（swap 期間不得寫入 kg-data）"
(cd "$COMPOSE_DIR" && docker compose stop) || die "停止容器失敗，現況未動；deploy 鎖保留，需人工確認容器狀態後手動 rmdir ${LOCK}"
# 容器已停之後的中斷：不自動啟動。資料目錄狀態未知時起容器，app 可能在空目錄重建資料庫。
trap 'echo "✗ swap 途中中斷：容器保持停止，未自動啟動，deploy 鎖保留，需人工介入（DATA=${DATA}，現況保留於 ${BROKEN:-（尚未改名）}）" >&2; exit 2' INT TERM HUP
TS=$(date -u +%Y%m%dT%H%M%SZ)
BROKEN=""
if [[ -e "$DATA" ]]; then
  BROKEN="${DATA}.broken.${TS}"
  if ! mv "$DATA" "$BROKEN"; then
    if start_back; then KEEP_LOCK=0; fi   # 現況未動且容器已起回：狀態已知
    die "無法保留現況 ${DATA}，已中止"
  fi
fi
# 第二次 mv 前斷言 DATA 不存在：若已被並行寫入者重建，mv 會把新資料巢狀搬入且仍回報成功
if [[ -e "$DATA" ]]; then
  echo "✗ swap 途中 ${DATA} 重新出現，拒絕巢狀搬入；未自動啟動容器，deploy 鎖保留，需人工介入（現況保留於 ${BROKEN:-（無既有現況）}）" >&2
  exit 2
fi
if ! mv "$NEW" "$DATA"; then
  # 跨裝置 mv 可能已部分複製；此時 DATA 已存在，不得把 BROKEN 搬進去（會巢狀）
  if [[ -e "$DATA" ]]; then
    echo "✗ swap 失敗且 ${DATA} 已部分就位，未自動回滾，deploy 鎖保留，需人工介入（現況保留於 ${BROKEN:-（無既有現況）}）" >&2
    exit 2
  fi
  # 原本就沒有 DATA 時無可還原的現況；此時起容器會在空目錄重建資料庫，因此不啟動
  if [[ -z "$BROKEN" ]]; then
    echo "✗ swap 失敗且原本無 ${DATA} 可還原；未啟動容器，deploy 鎖保留，需人工介入" >&2
    exit 2
  fi
  if ! mv "$BROKEN" "$DATA"; then
    echo "✗ 回滾失敗：現況保留於 ${BROKEN}，容器未啟動，deploy 鎖保留，需人工介入" >&2
    exit 2
  fi
  start_back || { echo "✗ 已還原現況 ${DATA} 但容器未啟動，deploy 鎖保留，需人工介入" >&2; exit 2; }
  KEEP_LOCK=0   # 現況已還原且容器已起回
  die "swap 失敗，已還原現況"
fi
trap - INT TERM HUP
if ! start_back; then
  echo "✗ 資料已還原但容器未啟動：${DATA} ← s3://${BUCKET}/data/${DATE}.tar.gz（現況保留於 ${BROKEN:-（無既有現況）}），deploy 鎖保留，需人工介入" >&2
  exit 2
fi
KEEP_LOCK=0
echo "✓ restore 完成：${DATA} ← s3://${BUCKET}/data/${DATE}.tar.gz（現況保留於 ${BROKEN:-（無既有現況）}）"
