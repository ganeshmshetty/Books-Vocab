#!/bin/bash
# =============================================================================
# devops.sh — BooksAndVocab KG API DevOps 操作腳本
# 供 Claude Code 代理呼叫。不需理解底層 SSH/Docker 細節，直接執行子指令。
#
# Agent 用法：
#   DEVOPS_YES=1 ./devops.sh delete-user <id>   # 跳過互動確認
#   ./devops.sh run "docker ps"                  # 執行任意遠端指令
# =============================================================================

set -euo pipefail

DEVOPS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DEVOPS_SCRIPT_DIR/ops/lib/devops_command_registry.sh"
source "$DEVOPS_SCRIPT_DIR/ops/lib/devops_commands.sh"
# 與 ops/devops_kg_safe.sh 共用同一個破壞性命令 predicate：safe wrapper 不是唯一防線
# （直接呼叫 base `devops.sh run ...` 也會被擋）。
source "$DEVOPS_SCRIPT_DIR/ops/lib/devops_run_guard.sh"
devops_command_registry_validate || {
  echo "✗ devops command registry is inconsistent" >&2
  exit 70
}

# ── 設定 ──────────────────────────────────────────────────────────────────────
# 正式站 2026-06-15 起 = 家用常駐機 felix（standby），經 Cloudflare Tunnel 對外。
# transport 走 Tailscale + 原生 sshd 公鑰（免密碼，default key，不再用 lightsail .pem）。
# 拓撲正本：~/butler/docs/kg-backend-deployment.md；host/port 正本：docs/reference/host_topology.md。
SERVER="${KG_SERVER:-chenliangyu@100.118.39.104}"
# 生產 checkout = 專用 clone ~/kg-prod（追 origin/prod），與 reconciler 同一棵樹。
# ⚠ 絕不指 ~/project/kg/backend（dev/resume-only）——同 compose project name `backend` 會
# 讓手動 deploy 用 main tree 劫持生產容器。三平面拓樸見 docs/sop/release.md。
REMOTE_DIR="${KG_REMOTE_DIR:-~/kg-prod/backend}"
CONTAINER="knowledge-graph-api"
# standby: 用戶資料在 ~/kg-data（搬出 git worktree），container 內 mount 為 /app/data。
REMOTE_DATA_DIR="${KG_REMOTE_DATA_DIR:-~/kg-data}"
PUBLIC_WEB_BASE_URL="https://wordnexus.lol"
LOCAL_DIR="$(cd "$DEVOPS_SCRIPT_DIR/backend" && pwd)"
BACKUP_DIR="$DEVOPS_SCRIPT_DIR/backups"
# Source-only signal semantics shared with the reconciler and backup verifier.
# shellcheck source=ops/lib/signal_traps.sh
source "$DEVOPS_SCRIPT_DIR/ops/lib/signal_traps.sh"

# default key + 已知 host（standby 用內建 ssh config / known_hosts，免帶 -i）
SSH_OPTS=( -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes )
# KG_SSH_CMD is a test seam: point it at a stub (e.g. one that echoes the remote
# command string) to assert transport-layer quoting without a real SSH hop.
if [[ -n "${KG_SSH_CMD:-}" ]]; then
  read -r -a SSH_CMD <<< "$KG_SSH_CMD"
else
  SSH_CMD=( ssh "${SSH_OPTS[@]}" "$SERVER" )
fi
if [[ -n "${KG_SCP_CMD:-}" ]]; then
  read -r -a SCP_CMD <<< "$KG_SCP_CMD"
else
  SCP_CMD=( scp -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes )
fi

# 必要環境變數清單（deploy 前自動檢查）
REQUIRED_ENV_KEYS=(
  "JWT_SECRET"
  "GEMINI_API_KEY"
  "GOOGLE_CLIENT_ID"
  "APPLE_BUNDLE_ID"
  "ADMIN_TOKEN"
  "APP_STORE_ROOT_CA_PATH"
  "APP_STORE_CONNECT_ISSUER_ID"
  "APP_STORE_CONNECT_KEY_ID"
  "APP_STORE_CONNECT_PRIVATE_KEY_PATH"
)

# 允許本地/遠端路徑不同，但要求指向同名檔案並符合各自主機上的預期目錄
HOST_SPECIFIC_ENV_KEYS=(
  "APP_STORE_ROOT_CA_PATH"
  "APP_STORE_CONNECT_PRIVATE_KEY_PATH"
)

# ── 工具函式 ──────────────────────────────────────────────────────────────────
# info/progress 走 stderr，stdout 只留命令 payload（讓 ops-cli --json 可機讀 parse）。
info()    { echo "▶ $*" >&2; }
ok()      { echo "✓ $*"; }
err()     { echo "✗ $*" >&2; exit 1; }
section() { echo ""; echo "── $* ──"; }

require_local_files() {
  [[ -f "$LOCAL_DIR/Dockerfile" ]]         || err "Dockerfile not found in $LOCAL_DIR"
  [[ -f "$LOCAL_DIR/docker-compose.yml" ]] || err "docker-compose.yml not found in $LOCAL_DIR"
}

# 確認函式：DEVOPS_YES=1 時自動跳過（agent 模式）
preflight() {
  require_local_files
}

confirm() {
  if [[ "${DEVOPS_YES:-0}" == "1" ]]; then
    echo "⚠️  $1 [已透過 DEVOPS_YES=1 自動確認]"
    return 0
  fi
  echo ""
  echo "⚠️  $1"
  read -r -p "   輸入 yes 確認: " ans
  [[ "$ans" == "yes" ]] || { echo "已取消。"; exit 0; }
}

# ── 測試隔離 tripwire（P0 2026-10-09）──────────────────────────────────────────
# ops 測試曾在沒有 stub transport 的情況下跑到真 devops.sh，經 ssh 刪掉 felix 上的
# 正式資料目錄（docs/runbook/incidents/2026-10-09-kg-data-deleted-by-test.md）。
# ops/test_ops.sh 與 ops/test_devops.sh 一律 export KG_OPS_TEST=1；一旦它為 1，任何
# 「真的」遠端 transport（KG_SSH_CMD／KG_SCP_CMD 未設，或指到真的 ssh／scp／rsync／
# curl 二進位）一律 exit 97，不連線。測試自備的 stub（任何 `#!` 腳本，或 /usr/bin/true
# 這類非 transport 二進位）不受影響；KG_OPS_TEST 未設時（營運者正常使用）此函式是 no-op。
#   $1 label（ssh|scp|rsync|curl）  $2 設定的 transport 命令字串，未設為空字串
# 分類看的是「實際會被執行的第一個字」：`env [opts] ssh`、`nohup ssh`、`sh -c ssh` 這類
# wrapper 先剝掉再分類（#2922），否則 `KG_SSH_CMD="env ssh host"` 會繞過 tripwire。
_devops_tripwire_effective_word() {  # $1 seam string → 印出實際被執行的第一個字
  local -a w=()
  local i=0 n t base
  read -r -a w <<< "$1"
  n=${#w[@]}
  while (( i < n )); do
    t="${w[i]#[\'\"]}"
    base="${t##*/}"
    case "$base" in
      env|nohup|command|exec|time|nice)
        i=$((i+1))
        while (( i < n )); do
          case "${w[i]}" in
            -u|-C|-P|-S|-n) i=$((i+2)) ;;
            -*|*=*) i=$((i+1)) ;;
            *) break ;;
          esac
        done ;;
      sh|bash|zsh|dash|ksh)
        i=$((i+1))
        while (( i < n )) && [[ "${w[i]}" != -*c* ]]; do i=$((i+1)); done
        [[ $i -lt $n ]] || { printf '%s' "$t"; return 0; }   # 沒有 -c：是腳本啟動，不剝
        i=$((i+1)) ;;
      *) printf '%s' "$t"; return 0 ;;
    esac
  done
  printf '%s' "${t:-}"
}

# $1 label（ssh|scp|rsync|curl）  $2 設定的 transport 命令字串，未設為空字串
devops_ops_test_tripwire() {
  [[ "${KG_OPS_TEST:-}" == "1" ]] || return 0
  local label="$1" seam="${2-}" word resolved magic="" real=0
  if [[ -z "$seam" ]]; then
    real=1
  else
    word="$(_devops_tripwire_effective_word "$seam")"
    case "${word##*/}" in
      ssh|scp|sftp|rsync|aws|curl)
        resolved="$(command -v -- "$word" 2>/dev/null || true)"
        if [[ -n "$resolved" && -f "$resolved" ]]; then
          magic="$(head -c 2 "$resolved" 2>/dev/null || true)"
        fi
        [[ "$magic" == '#!' ]] || real=1 ;;
    esac
  fi
  [[ "$real" -eq 1 ]] || return 0
  {
    echo "✗ FORBIDDEN (exit 97): KG_OPS_TEST=1 and the real $label transport was about to run (${SERVER:-?})."
    echo "  An ops test must never reach production. Give the test a stub script (starts with #!) and point"
    echo "  KG_SSH_CMD / KG_SCP_CMD at it. A fake $label on PATH is not enough: with the seam unset this"
    echo "  tripwire always fires. See docs/runbook/incidents/2026-10-09-kg-data-deleted-by-test.md"
  } >&2
  if [[ -n "${KG_OPS_TEST_TRIPWIRE_LOG:-}" ]]; then
    printf 'tripwire %s seam=%s\n' "$label" "${seam:-<unset>}" >> "$KG_OPS_TEST_TRIPWIRE_LOG" 2>/dev/null || true
  fi
  exit 97
}

run_remote() { devops_ops_test_tripwire ssh "${KG_SSH_CMD:-}"; "${SSH_CMD[@]}" "$@"; }  # 在遠端執行指令（非互動式）

make_remote_tmp_path() {
  local stem="$1"
  local ext="$2"
  printf '/tmp/%s__%s__%s%s' "$stem" "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$ext"
}

copy_local_to_container() {
  local src="$1"
  local remote_tmp="$2"
  [[ -f "$src" ]] || err "檔案不存在: $src"
  devops_ops_test_tripwire scp "${KG_SCP_CMD:-}"
  "${SCP_CMD[@]}" "$src" "$SERVER:$remote_tmp"
  run_remote "docker cp $remote_tmp $CONTAINER:$remote_tmp"
}

cleanup_remote_tmp() {
  local remote_tmp
  for remote_tmp in "$@"; do
    [[ -n "$remote_tmp" ]] || continue
    run_remote "docker exec $CONTAINER rm -f $remote_tmp" >/dev/null 2>&1 || true
    run_remote "rm -f $remote_tmp" >/dev/null 2>&1 || true
  done
}

# ── 部署後 smoke verify（從本地打公網，外部視角全鏈路驗證）─────────────────
# 可注入：CURL_BIN（測試用 mock curl）、KG_SKIP_SMOKE=1 完全跳過、
#         SENTRY_VERIFY=1 加做 sentry endpoint 探測、
#         SMOKE_BASE_URL（預設 ${PUBLIC_WEB_BASE_URL}）
verify_post_deploy() {
  local deploy_sha="$1"
  local base_url="${SMOKE_BASE_URL:-${PUBLIC_WEB_BASE_URL:-https://wordnexus.lol}}"
  local curl_bin="${CURL_BIN:-curl}"
  local rc=0

  if [[ "${KG_SKIP_SMOKE:-0}" == "1" ]]; then
    info "KG_SKIP_SMOKE=1，跳過部署後 smoke verify"
    return 0
  fi
  devops_ops_test_tripwire curl "$curl_bin"

  section "部署後 smoke verify"

  # 1) /api/system/info — 公開 endpoint，必須 200，body 含 version 且等於 deploy_sha
  local info_body info_http
  info_body=$("$curl_bin" -sS -o - -w $'\n%{http_code}' --max-time 10 "$base_url/api/system/info" 2>/dev/null || true)
  info_http=$(printf '%s\n' "$info_body" | tail -n1)
  info_body=$(printf '%s\n' "$info_body" | sed '$d')

  if [[ "$info_http" != "200" ]]; then
    echo "✗ /api/system/info HTTP=$info_http (expect 200)"
    rc=1
  else
    local remote_version
    remote_version=$(printf '%s' "$info_body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [[ -z "$remote_version" ]]; then
      echo "✗ /api/system/info 缺少 version 欄位 (body=$info_body)"
      rc=1
    elif [[ "$remote_version" != "$deploy_sha" ]]; then
      echo "✗ /api/system/info version=$remote_version 不等於 deploy_sha=$deploy_sha"
      rc=1
    else
      ok "/api/system/info 200，version=$remote_version 對齊"
    fi
  fi

  # 2) /api/health — 需要 auth，unauth 預期 401（代表 route 存在 + auth wire 正常）
  #    404/000 視為 endpoint 消失或網路斷，記紅；500 視為 app 起火，記紅
  local health_http
  health_http=$("$curl_bin" -sS -o /dev/null -w '%{http_code}' --max-time 10 "$base_url/api/health" 2>/dev/null || true)
  health_http="${health_http:-000}"
  case "$health_http" in
    401|403)
      ok "/api/health 受 auth 保護 (HTTP ${health_http}), endpoint 正常"
      ;;
    200)
      ok "/api/health HTTP 200 (auth 跳過或測試環境)"
      ;;
    404)
      info "/api/health 不存在 (HTTP 404), 跳過此項 (非失敗)"
      ;;
    000)
      echo "✗ /api/health 無回應 (網路斷或 TLS 失敗)"
      rc=1
      ;;
    *)
      echo "✗ /api/health 異常 HTTP=${health_http}"
      rc=1
      ;;
  esac

  # 3) Sentry verify（opt-in via SENTRY_VERIFY=1）
  if [[ "${SENTRY_VERIFY:-0}" == "1" ]]; then
    local sentry_http
    sentry_http=$("$curl_bin" -sS -o /dev/null -w '%{http_code}' --max-time 10 "$base_url/api/system/sentry-test" 2>/dev/null || true)
    sentry_http="${sentry_http:-000}"
    case "$sentry_http" in
      401|403)
        ok "/api/system/sentry-test 存在且 admin 保護 (HTTP ${sentry_http})"
        ;;
      500|502)
        ok "/api/system/sentry-test 觸發例外 (HTTP ${sentry_http}), 請於 Sentry UI 確認事件抵達"
        ;;
      404)
        # endpoint 缺席 → fallback: 透過 system/info 確認 SENTRY_DSN 已被讀取
        info "/api/system/sentry-test 不存在, fallback 檢查 /api/system/info"
        if printf '%s' "$info_body" | grep -q '"sentry"'; then
          ok "/api/system/info 含 sentry 狀態欄位 (DSN 已讀取)"
        else
          info "(/api/system/info 未暴露 sentry 狀態, 僅供參考, 非失敗)"
        fi
        ;;
      000)
        echo "✗ /api/system/sentry-test 無回應"
        rc=1
        ;;
      *)
        info "/api/system/sentry-test HTTP=${sentry_http} (非預期但不視為失敗)"
        ;;
    esac
  fi

  if [[ "$rc" -ne 0 ]]; then
    echo ""
    echo "── 容器最近 30 行 log (smoke 失敗診斷) ──"
    run_remote "cd $REMOTE_DIR && docker compose logs --tail=30" || true
    err "部署後 smoke verify 失敗 (deploy_sha=${deploy_sha}), 詳見上方"
  fi
  ok "部署後 smoke verify 通過"
  return 0
}

# ── 安全函式 ──────────────────────────────────────────────────────────────────
# uid 必須是英數字、底線、連字號、點號，1-64 字元；
# shell metachar / path traversal（.. / / / 前導 .）一律拒絕，對齊後端 _safe_user_dir。
validate_uid() {
  local uid="$1"
  if [[ -z "$uid" ]]; then
    err "user_id 不可為空"
  fi
  if [[ -n "${uid//[A-Za-z0-9_.-]/}" ]] ||\
     [[ "$uid" =~ ^\. ]] ||\
     [[ "$uid" =~ \.\. ]] ||\
     [[ "$uid" =~ / ]]; then
    err "非法 user_id：'$uid'（僅允許英數字、底線、連字號、點號，長度 1-64；禁止 '..'、'/'、前導 '.')"
  fi
  if [[ "${#uid}" -gt 64 ]]; then
    err "非法 user_id：'$uid'（長度超過 64）"
  fi
}

# Production 互斥鎖：deploy/restart/migrate 並發保護
# Mac 預設無 flock(1)，改用 mkdir 原子鎖。鎖放在 deploy host（felix）上、經 SSH 取放，
# 與 felix 上的 kg_reconcile.sh（本機 mkdir 同一路徑）才是同一把；DEPLOY_LOCK_DIR 是遠端路徑。
DEPLOY_LOCK_DIR="${KG_DEPLOY_LOCK_DIR:-/tmp/kg-deploy.lock}"
DEPLOY_LOCK_HELD=0
release_deploy_lock() { run_remote "rmdir $DEPLOY_LOCK_DIR" 2>/dev/null || true; }
acquire_deploy_lock() {
  # 同 process 內已持有則略過（cmd_deploy → cmd_migrate 遞迴呼叫場景）
  [[ "$DEPLOY_LOCK_HELD" == "1" ]] && return 0
  if ! run_remote "mkdir $DEPLOY_LOCK_DIR" 2>/dev/null; then
    err "另一個 deploy/restart/migrate 正在進行中（deploy host 上 $DEPLOY_LOCK_DIR 已存在）。若確認無進行中操作，請在 deploy host 手動 rmdir $DEPLOY_LOCK_DIR"
  fi
  DEPLOY_LOCK_HELD=1
  kg_install_signal_traps release_deploy_lock devops
}

# ── 指令：env-check ───────────────────────────────────────────────────────────
cmd_env_check() {
  section "檢查遠端 .env 環境變數"
  local env_text
  env_text=$(run_remote "cat -- $REMOTE_DIR/.env") || err "無法讀取遠端 .env：$REMOTE_DIR/.env"
  # 判定邏輯（缺值／unsafe 旗標，與 backend settings._env_truthy 對齊）在 ops/env_drift.py。
  # stdout 維持 `✓ KEY` / `✗ KEY (…)`，release_train.evaluate_env 依此解析。
  printf '%s\n' "$env_text" | "$DEVOPS_SCRIPT_DIR/ops/env_drift.py" env-check "${REQUIRED_ENV_KEYS[@]}" || exit 1
}

cmd_env_drift() {
  section "檢查本地/遠端 .env 一致性"

  local remote_real_dir
  remote_real_dir=$(run_remote "cd $REMOTE_DIR >/dev/null 2>&1 && pwd")
  "$DEVOPS_SCRIPT_DIR/ops/env_drift.py" \
    "$LOCAL_DIR/.env" "$remote_real_dir/.env" "$LOCAL_DIR" "$remote_real_dir" "$SERVER"
}

# ── 指令：deploy ──────────────────────────────────────────────────────────────
# standby 流程（2026-06-15 起，正本見 ~/butler/docs/kg-backend-deployment.md §4.2）：
#   遠端 git pull → 寫 VERSION → docker compose up -d --build → health → smoke verify。
#   程式碼靠 git 同步（非 rsync push）；data/ 是 ~/kg-data volume mount，build 不碰。
#   migration 由 app 啟動自動跑（migration_version 在 /api/system/info），不再本地 SQL loop。
cmd_deploy() {
  acquire_deploy_lock
  preflight

  # ── 本地 working tree 必須乾淨且已 push（standby 靠 git pull 取碼）──
  local dirty
  dirty=$(cd "$LOCAL_DIR" && git diff --name-only HEAD -- . 2>/dev/null || true)
  if [[ -n "$dirty" ]]; then
    echo "✗ 拒絕在 dirty 工作區部署。以下檔案未 commit：" >&2
    echo "$dirty" | head -20 >&2
    err "請先 commit + push 後再部署（standby 由 git pull 取碼，未 push 的改動不會生效）"
  fi

  local local_sha
  local_sha=$(cd "$LOCAL_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  info "本地 HEAD = ${local_sha}（請先確認已 git push，否則 standby pull 不到）"

  local deploy_log="$BACKUP_DIR/deploy.log"

  # ── Step 1: standby git pull + 寫 VERSION ──
  section "standby git pull + 更新 VERSION"
  # 完整 sha（#2078）：VERSION 是 SDK 自報 Sentry release（kg-backend@<VERSION>）的唯一來源，
  # 必須與下方記錄的 release 名逐字相同；短 sha 的長度隨 repo 成長漂移。
  run_remote "cd $REMOTE_DIR && git pull --ff-only && git rev-parse HEAD > VERSION && cat VERSION"

  local deploy_sha
  deploy_sha=$(run_remote "cd $REMOTE_DIR && git rev-parse HEAD" 2>/dev/null || echo "unknown")

  # ── Step 2: 重建並啟動容器 ──
  # src/ COPY 進 image（非 volume），改碼必 rebuild 才生效。data/ = ~/kg-data volume，不動。
  #
  # --force-recreate 不可省（2026-06-19 retarget 時掉過一次，紅了 6.5 週，見 IMP-0052）：
  # VERSION 是 bind-mount（`./VERSION:/app/VERSION:ro`）而 routers/system.py 於 import
  # 時就把它讀進 _VERSION 快取，所以自報版本只隨**行程重啟**改變（recreate 或 restart）。
  # 檔案內容本身是即時的——但那**取決於沒人換掉 inode**：單檔 bind mount 綁的是 inode，
  # Step 1 與 reconciler 都用 `> VERSION` 就地截斷；哪天改成 atomic write（mktemp && mv），
  # 容器會永遠看著舊 inode，連 restart 都救不回來。
  #
  # Step 1 無條件寫 VERSION，但 `up -d --build` 只在 image 或解析後的 compose config
  # hash 變了才 recreate——部署一個兩者都沒動的 commit（docs / ops / ios），就留下
  # VERSION 宣稱 new、容器仍自報 old 的游標分岔。強制 recreate 換掉的是幾秒停機與前一顆容器的
  # json-file log（`docker-logs` 查得到的範圍）；游標對齊餵著 smoke gate 與 Sentry release，
  # 值這個價。ops/kg_reconcile.sh 的同一條命令另有取捨與一個已知缺口，見 IMP-0056。
  section "重新編譯並啟動容器"
  # 不可寫成 `... 2>&1 | tail -20`：遠端 shell 無 pipefail，退出碼會變成 tail 的 0，build 失敗被吞、
  # 舊容器照常 200（#2278）。先捕獲輸出與 rc，印尾 20 行，再以 compose 的 rc 退出。
  run_remote "cd $REMOTE_DIR && { out=\$(docker compose up -d --build --force-recreate 2>&1); rc=\$?; printf '%s\\n' \"\$out\" | tail -20; exit \$rc; }" \
    || err "docker compose up --build 失敗（舊容器可能仍在服務），中止部署；未記錄 deploy.log／Sentry release"

  # ── Step 3: 健康驗證（直連 standby localhost）──
  section "健康驗證"
  local max_attempts=5
  local delay=3
  local url="http://localhost:8000/api/system/info"
  local http_code=""
  for i in $(seq 1 $max_attempts); do
    http_code=$(run_remote "curl -o /dev/null -s -w '%{http_code}' $url" || echo "000")
    if [[ "$http_code" == "200" ]]; then
      ok "健康檢查通過 (attempt $i)"
      break
    fi
    info "attempt $i: HTTP ${http_code}，等待 ${delay} 秒..."
    sleep $delay
  done
  if [[ "$http_code" != "200" ]]; then
    run_remote "cd $REMOTE_DIR && docker compose logs --tail=30"
    err "部署後健康檢查失敗 (HTTP $http_code)，請確認日誌"
  fi

  # ── Sentry release 對齊驗證 ──
  section "Sentry release 驗證"
  local info_json reported_version sentry_on
  info_json=$(run_remote "curl -s $url" 2>/dev/null || true)
  reported_version=$(printf '%s' "$info_json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  sentry_on=$(printf '%s' "$info_json" | sed -nE 's/.*"sentry"[[:space:]]*:[[:space:]]*(true|false).*/\1/p' | head -1)
  if [[ "$reported_version" == "$deploy_sha" ]]; then
    ok "Sentry release = kg-backend@${deploy_sha} (api/system/info 對齊)"
  else
    # 致命（含 KG_SKIP_SMOKE=1）：版本不符＝舊容器仍在服務，不可記成已部署（#2278）。
    err "/api/system/info 回報 version=${reported_version:-unknown} 但部署 sha=${deploy_sha}：容器未換成新版，中止（不記 deploy.log／Sentry）"
  fi
  if [[ "$sentry_on" != "true" ]]; then
    echo "⚠⚠ 生產 backend Sentry 未啟用（sentry=${sentry_on:-unknown}）：backend crash 不會被看到。" >&2
    echo "   修法：felix ~/kg-prod/backend/.env 加 SENTRY_DSN=<backend project DSN>，再 docker compose up -d --build --force-recreate（docs/sop/deploy.md §Sentry）" >&2
  fi

  # ── 部署後 smoke verify（外部視角，確認 CF→tunnel→standby 全鏈路 + 版本對齊）──
  verify_post_deploy "$deploy_sha"

  # ── 記錄部署日誌（驗證通過後才記，#2278）──
  mkdir -p "$BACKUP_DIR"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sha=$deploy_sha user=$(whoami)" >> "$deploy_log"
  info "部署記錄已追加至 $deploy_log"

  # ── Sentry release + deploy 紀錄（best-effort；smoke 通過才走到這裡）──
  section "Sentry release 紀錄"
  record_sentry_release "$deploy_sha"

  ok "部署完成 (version: $deploy_sha)。"
}

# 在本機（操作者機器，讀 ~/.secrets/sentry.env）記 kg-backend@<sha> release + production deploy。
# 永遠 return 0：Sentry 缺設定/掛掉不得讓已健康落地的部署被報成失敗。時間上限由 helper 的
# 每呼叫 curl timeout 與「首次失敗即停」保證（最壞約 3×10s）。
record_sentry_release() {
  local sha="$1" helper="${KG_SENTRY_RELEASE:-$DEVOPS_SCRIPT_DIR/ops/sentry_release.sh}" rc=0
  if [[ ! -x "$helper" ]]; then
    echo "⚠ SKIP Sentry release 紀錄：找不到 $helper" >&2
    return 0
  fi
  "$helper" record-backend --sha "$sha" --environment production --name devops.sh </dev/null || rc=$?
  case "$rc" in
    0) ok "Sentry release kg-backend@${sha} 已記錄（production deploy）" ;;
    3) echo "⚠ SKIP Sentry release 紀錄（原因見上方 [sentry-release] 行；部署不受影響）" >&2 ;;
    *) echo "⚠ Sentry release 紀錄失敗 (exit ${rc})，部署不受影響" >&2 ;;
  esac
  return 0
}

# ── 指令：migrate ─────────────────────────────────────────────────────────────
# standby 現況：schema migration 由 app 啟動自動跑（migration_version 在
# /api/system/info），deploy 已不再呼叫本指令。此指令保留為手動 idempotent
# fallback（對所有用戶 cards.db 補欄位，在容器內執行），需要時手動觸發。
cmd_migrate() {
  acquire_deploy_lock
  section "DB Migration（手動 fallback；standby 正常情況由 app 啟動自動跑）"
  run_remote "docker exec knowledge-graph-api python3 -c \"
import sqlite3, glob, os

MIGRATIONS = [
    ('root_form',   'ALTER TABLE card ADD COLUMN root_form TEXT'),
    ('inflections', \\\"ALTER TABLE card ADD COLUMN inflections TEXT DEFAULT '[]'\\\"),
]

dbs = sorted(glob.glob('/app/data/users/*/cards.db'))
if not dbs:
    print('(no databases found)')
for db in dbs:
    uid = db.split('/')[-2]
    conn = sqlite3.connect(db)
    existing = {r[1] for r in conn.execute('PRAGMA table_info(card)').fetchall()}
    changed = []
    for col, sql in MIGRATIONS:
        if col not in existing:
            conn.execute(sql)
            changed.append(col)
    conn.commit()
    conn.close()
    if changed:
        print(f'✓ {uid}: added {changed}')
    else:
        print(f'- {uid}: up to date')
\""
}

# ── 指令：restart ─────────────────────────────────────────────────────────────
cmd_restart() {
  acquire_deploy_lock
  info "重啟容器（不重新 build）"
  run_remote "cd $REMOTE_DIR && docker compose restart"
  sleep 3
  local http_code
  http_code=$(run_remote "curl -o /dev/null -s -w '%{http_code}' http://localhost:8000/api/system/info" || echo "000")
  if [[ "$http_code" == "200" ]]; then
    ok "容器已重啟，API 回應正常"
  else
    err "重啟後健康檢查失敗 (HTTP $http_code)"
  fi
}

# ── 指令：status ──────────────────────────────────────────────────────────────
cmd_status() {
  section "部署版本"
  run_remote "cat $REMOTE_DIR/VERSION 2>/dev/null && echo '' || echo 'unknown (no VERSION file)'"

  section "Docker 容器"
  run_remote "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

  section "對外入口（Cloudflare Tunnel）"
  # standby 無 Caddy（macOS）。對外走 CF Tunnel：cloudflared 由 launchd 常駐。
  run_remote "pgrep -lf 'cloudflared.*tunnel' >/dev/null 2>&1 && echo 'cloudflared tunnel: 運行中（CF Tunnel）' || echo 'cloudflared tunnel: 未偵測到（檢查 launchd com.cloudflare.cloudflared）'"

  section "磁碟使用"
  run_remote "df -h / | awk 'NR==2{print \"根目錄: \" \$3 \" used / \" \$2 \" total (\"\$5\" used)\"}'"
  run_remote "du -sh ~/kg-data 2>/dev/null && echo '(以上為 ~/kg-data 資料目錄，container /app/data volume)' || echo '~/kg-data 不存在'"

  section "用戶數量"
  run_remote "ls ~/kg-data/users/ 2>/dev/null | wc -l | xargs echo '用戶目錄數:'" || echo "(無用戶資料)"

  section "最近部署記錄"
  local deploy_log="$BACKUP_DIR/deploy.log"
  if [[ -f "$deploy_log" ]]; then
    tail -5 "$deploy_log"
  else
    echo "(無部署記錄)"
  fi
}

# ── 指令：logs ────────────────────────────────────────────────────────────────
cmd_logs() {
  local n="${1:-50}"
  local tz="${KG_LOG_TZ:-}"
  info "顯示最新 $n 行日誌"
  if [[ -n "$tz" ]]; then
    # 透過 perl 即時轉換 ISO 8601 timestamp 到指定時區
    run_remote "docker logs knowledge-graph-api -n $n --timestamps 2>&1" \
      | perl -MPOSIX -MTime::Piece -pe '
          if (/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/) {
            my $utc = $1;
            $ENV{TZ} = "'"$tz"'";
            POSIX::tzset();
            if (my $t = eval { Time::Piece->strptime($utc, "%Y-%m-%dT%H:%M:%S") }) {
              my $local = localtime($t->epoch);
              my $s = $local->strftime("%Y-%m-%d %H:%M:%S %Z");
              s/\Q$utc\E/$s/;
            }
          }
        '
  else
    run_remote "docker logs knowledge-graph-api -n $n --timestamps 2>&1"
  fi
}

# ── 指令：backup ──────────────────────────────────────────────────────────────
cleanup_old_backups() {
  local backup_dir="$BACKUP_DIR"
  local keep=10
  local count dir f
  # 一份備份 = data_<date>/ 目錄 + 同名 .tar.gz + .tar.gz.sha256；
  # 只以目錄計數，否則 tarball／sha256 會讓 keep 實際只剩約 3 份快照。
  # 帶 .INCOMPLETE 標記的殘缺目錄不占 keep 額度（否則會擠掉好備份），一律清掉。
  for dir in "$backup_dir"/data_*/; do
    [ -e "${dir}.INCOMPLETE" ] || continue
    dir="${dir%/}"
    echo "  刪除殘缺: $(basename "$dir")"
    rm -rf "$dir" "$dir.tar.gz" "$dir.tar.gz.sha256"
  done
  count=$(ls -1d "$backup_dir"/data_*/ 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -gt "$keep" ]; then
    local to_delete=$(( count - keep ))
    echo "清理舊備份：刪除最舊的 $to_delete 份..."
    ls -1d "$backup_dir"/data_*/ | head -n "$to_delete" | while read -r dir; do
      dir="${dir%/}"
      echo "  刪除: $(basename "$dir")"
      rm -rf "$dir" "$dir.tar.gz" "$dir.tar.gz.sha256"
    done
  fi
  # 孤兒：沒有對應 data_<date>/ 目錄的 tarball／sha256（舊版安裝遺留）
  for f in "$backup_dir"/data_*.tar.gz "$backup_dir"/data_*.tar.gz.sha256; do
    [ -e "$f" ] || continue
    dir="${f%.sha256}"
    dir="${dir%.tar.gz}"
    if [ ! -d "$dir" ]; then
      echo "  刪除孤兒: $(basename "$f")"
      rm -f "$f"
    fi
  done
}

# rsync flavor 分流：macOS 內建 /usr/bin/rsync 是 openrsync（--version 首行
# `openrsync: protocol version 29`，次行才自稱 `rsync version 2.6.9 compatible`），
# 不認 GNU 的 --info=progress2——實測 `rsync -n -a --info=progress2` 直接回
# `unrecognized option`，整個 cmd_backup 當場中止。可攜性範式同 ops/release.sh:264 的
# `mode="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")"`。
# 2026-08-08 實測：cmd_backup 用到的其餘旗標（-a -z --delete --exclude= --link-dest=
# --progress --human-readable）openrsync 全部吃得下，故只有 --info=progress2 需要分流。
# $1 = 選填的 version 首行（給測試注入用）；空則實跑 `rsync --version` 取首行。
# 用 `rsync` 而非 `/usr/bin/rsync`：要與下面 cmd_backup 實際呼叫的那顆二進位一致
#（裝了 Homebrew rsync 的機器 PATH 會先命中 GNU 版）。
rsync_progress_flags() {
  local version_line="${1:-}"
  # 必須用 if，不可縮寫成 `[[ -z … ]] && version_line=$(…)`：本檔 :11 是 set -euo
  # pipefail，帶參數呼叫時該 && 複合命令回 1，會當場殺掉整支腳本。
  if [[ -z "$version_line" ]]; then
    # 不經 `| head -1`：pipefail 下 head 提早關管會讓 rsync 吃 SIGPIPE（141），
    # 整支腳本被 set -e 殺掉。整段讀進來再取首行，沒有會斷的管線。
    version_line=$(rsync --version 2>&1) || true
    version_line="${version_line%%$'\n'*}"
  fi
  if [[ "$version_line" == openrsync* ]]; then
    printf '%s\n' '--progress'
  else
    printf '%s\n' '--info=progress2' '--human-readable'
  fi
}

cmd_backup() {
  # 注意：standby 的**權威排程/異地**備份 = standby launchd `com.kg.backup` → S3
  #（見 ~/butler/docs/kg-backend-deployment.md §4.5 / §7 G5）。本指令是 oscar 端
  # 的「臨時冷快照」：把 standby ~/kg-data **拉**回本地 backups/ 並做完整性驗證，
  # 不對 prod 寫入、不取代排程備份。
  devops_ops_test_tripwire rsync "rsync"
  local date_str; date_str=$(date +%Y%m%d_%H%M)
  local dest="$BACKUP_DIR/data_$date_str"
  mkdir -p "$BACKUP_DIR"

  info "本地冷快照（pull from standby）：$SERVER:$REMOTE_DATA_DIR → ${dest}（排除 _ops_backups / _ops_world_backups）"

  # 找最近一份備份目錄當增量基準（未變的 db 走硬連結，只傳當日有寫入的）
  local prev
  # 帶 .INCOMPLETE 標記的目錄不可當增量基準（硬連結會把殘缺／損毀的 db 傳染進新備份）。
  local cand
  prev=""
  while IFS= read -r cand; do
    [[ -e "${cand}.INCOMPLETE" ]] && continue
    prev="$cand"
    break
  done < <(ls -1dt "$BACKUP_DIR"/data_*/ 2>/dev/null | grep -vF "/data_${date_str}/" || true)  # grep 無匹配 exit 1，避免 set -e 在首次（無既有備份）誤殺
  mkdir -p "$dest"
  # 空輸出的防呆帶。下面的陣列若是空的，bash 3.2 對 ${a[*]} 在 set -u 下會直接噴
  # `progress_flags[*]: unbound variable`——又一次拿難懂訊號當失敗訊號。
  # 注意實測結果（2026-08-08，別憑推理改掉這段）：rsync **不在 PATH** 時走不到這裡，
  # 因為 helper 的 `rsync --version 2>&1` 把 shell 自己的 "command not found" 收進
  # version_line，非空且不以 openrsync 開頭 → 照樣吐 GNU 旗標；那條路徑最後是由下面
  # 的 rsync 失敗守衛接住（具名拒絕 + 指向 S3，exit 1，已實測）。所以這是給「helper
  # 未來被改成可能無輸出」留的便宜保險，不是當前可重現路徑。
  # `|| true` 同理是保險：helper 非零退出不該讓整支腳本無聲中止，要走到下面那句 err。
  local progress_raw=""
  progress_raw=$(rsync_progress_flags) || true
  if [[ -z "$progress_raw" ]]; then
    err "偵測不到可用的 rsync（PATH 中找不到，或 rsync --version 失敗）。本地冷快照無法進行；災難復原請改用 standby 每日 S3 備份（launchd com.kg.backup → ops/kg_backup.sh）。"
  fi
  # mapfile 不可用：本檔 shebang 是 #!/bin/bash，macOS 的 /bin/bash = 3.2.57，沒有它。
  local -a progress_flags=()
  while IFS= read -r flag; do
    progress_flags+=("$flag")
  done <<< "$progress_raw"
  info "rsync progress enabled: ${progress_flags[*]}"
  # 守住 rsync 的非零退出。沒有這道守衛時，rsync 失敗只會留下它自己印的 usage／錯誤，
  # 而上方剛印過 preflight 與「▶ 本地冷快照」，整段輸出讀起來像「跑完了」（IMP-
  # 20260806-02bf8d 就是這樣被誤讀的）。備份指令不該用「印出 usage」當失敗訊號。
  if ! rsync -az --delete "${progress_flags[@]}" \
    --exclude='_ops_backups/' \
    --exclude='_ops_world_backups/' \
    ${prev:+--link-dest="$prev"} \
    -e "ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
    "$SERVER:$REMOTE_DATA_DIR/" "$dest/"; then
    # 留下機器可辨識的殘缺標記：錯誤訊息一旦捲出 scrollback，這個空目錄在 ls 裡與
    # 正常備份長得一模一樣（且會佔用 cleanup_old_backups 的 keep=10 額度）。不刪它
    # ——鐵律 7 不在 data 路徑附近用 rm -rf；標記它，讓後續判讀有依據。
    touch "$dest/.INCOMPLETE" 2>/dev/null || true
    echo "" >&2
    echo "  本機 rsync：$(rsync --version 2>&1 | head -1)" >&2
    echo "  已建立但**不完整**、不可當備份用的目錄：${dest}（已標記 .INCOMPLETE）" >&2
    echo "  災難復原請改用 standby 的每日 S3 備份（launchd com.kg.backup →" >&2
    echo "  ops/kg_backup.sh，見 docs/sop/deploy.md）；那條路徑與本指令各自獨立。" >&2
    err "本地冷快照失敗：rsync 非零退出（上方為 rsync 自身輸出）。此指令沒有產出可用備份。"
  fi
  [[ -n "$prev" ]] && info "增量基準: $(basename "$prev")（未變檔走硬連結）" \
                   || info "首次全量備份（無基準）"

  # ── 完整性驗證：SQLite integrity_check ──────────────────────────────────
  section "驗證備份完整性"
  local integrity_ok=1
  while IFS= read -r -d '' db; do
    local result
    result=$(sqlite3 "$db" "PRAGMA integrity_check;" 2>&1)
    if [[ "$result" == "ok" ]]; then
      ok "integrity_check: $(basename "$(dirname "$db")")/$(basename "$db")"
    else
      echo "✗ 損毀: $db" >&2
      echo "  $result" >&2
      integrity_ok=0
    fi
  done < <(find "$dest" -name "*.db" -print0)

  # integrity_check 失敗：不產 tar／sha256（否則損毀快照看起來是有 checksum 的可信備份），
  # 以 .INCOMPLETE 標記該目錄（同 rsync 失敗路徑；鐵律 7 不 rm -rf），再非零退出。
  if [[ "$integrity_ok" -eq 0 ]]; then
    touch "$dest/.INCOMPLETE" 2>/dev/null || true
    err "備份完整性驗證失敗（已標記 ${dest}/.INCOMPLETE，未產生 tar／checksum），請檢查上方錯誤訊息"
  fi

  # ── 完整性驗證：sha256 checksum ─────────────────────────────────────────
  local tar_file="$BACKUP_DIR/data_${date_str}.tar.gz"
  info "計算備份 checksum → ${tar_file}.sha256"
  tar -czf "$tar_file" -C "$BACKUP_DIR" "data_$date_str"
  sha256sum "$tar_file" > "${tar_file}.sha256"
  ok "checksum: $(cat "${tar_file}.sha256")"

  ok "備份完成且驗證通過: $dest"
  ls -lh "$BACKUP_DIR" | tail -5
  cleanup_old_backups
}

# ── 指令：users ───────────────────────────────────────────────────────────────
# 隱私契約（#2098）：只輸出用戶目錄數、真實用戶數與每人一行 `uid provider last_login`。
# users.json 同時存放 _email_index、email、subscription、linked_ids 與 config，絕不整檔
# 輸出——縮減在遠端 python 內完成，敏感欄位根本不離開 host。腳本經 stdin（python3 -）
# 傳入，不在 ssh 命令字串裡跳脫引號；`~` 由 expanduser 展開（%q 可能把它轉成字面值）。
cmd_users() {
  section "遠端用戶（count + uid provider last_login；不含 email／訂閱）"
  run_remote "python3 - $(printf '%q' "$REMOTE_DATA_DIR")" <<'PY'
import json, os, sys

base = os.path.expanduser(sys.argv[1])

def field(value, limit):
    text = value if isinstance(value, str) else ""
    return "".join(text.split())[:limit] or "-"

users_dir = os.path.join(base, "users")
try:
    names = os.listdir(users_dir)
    print("user dirs: %d" % sum(os.path.isdir(os.path.join(users_dir, n)) for n in names))
except OSError:
    print("user dirs: (無用戶資料目錄)")
try:
    with open(os.path.join(base, "users.json")) as fh:
        data = json.load(fh)
except (OSError, ValueError):
    data = None
if not isinstance(data, dict):
    print("users: (users.json 不存在或無法解析)")
    sys.exit(0)
# 真實用戶 = backend user_store.is_real_user（非 `_` metadata 且值為 dict），再排除
# auth_service 寫入的 `_linked_to` alias record（provider 連結，不是獨立帳號）。
real = sorted(
    uid for uid, rec in data.items()
    if isinstance(rec, dict) and not uid.startswith("_") and "_linked_to" not in rec
)
print("users: %d" % len(real))
for uid in real:
    rec = data[uid]
    print(field(uid, 80), field(rec.get("provider"), 24), field(rec.get("last_login"), 40))
PY
}

# ── 指令：user-info <user_id> ─────────────────────────────────────────────────
cmd_user_info() {
  local uid="${1:-}"
  [[ -z "$uid" ]] && err "用法: $0 user-info <user_id>"
  validate_uid "$uid"

  section "用戶: $uid"
  run_remote "ls -lah $REMOTE_DATA_DIR/users/$uid/ 2>/dev/null || (echo '用戶不存在'; exit 1)"

  section "單字庫統計"
  # 路徑以 argv 傳入（printf %q）並由 python expanduser：`~` 不能放進遠端雙引號字串，
  # 否則 sqlite3.connect 收到字面 `~/…`（#2758）。讀不到 DB 必須 exit 非 0。
  local db_path
  db_path="$(printf '%q' "$REMOTE_DATA_DIR/users/$uid/cards.db")"
  run_remote "python3 -c \"
import os, sqlite3, sys
try:
    db = os.path.expanduser(sys.argv[1])
    if not os.path.exists(db): raise FileNotFoundError(db)
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    cur.execute('SELECT COUNT(*), SUM(CASE WHEN is_deleted=0 THEN 1 ELSE 0 END), SUM(CASE WHEN is_deleted=1 THEN 1 ELSE 0 END) FROM card')
    total, active, deleted = cur.fetchone()
    print(f'總卡片: {total}  有效: {active}  已刪除: {deleted}')
except Exception as e:
    print(f'(無法讀取 SQLite: {e})')
    sys.exit(1)
\" $db_path"
}

# ── 指令：delete-user <user_id> [--yes] ───────────────────────────────────────
cmd_delete_user() {
  local uid="${1:-}"
  local yes_flag="${2:-}"
  [[ -z "$uid" ]] && err "用法: $0 delete-user <user_id> [--yes]"
  validate_uid "$uid"

  info "即將刪除的資料:"
  run_remote "ls -lah $REMOTE_DATA_DIR/users/$uid/ 2>/dev/null || (echo '用戶不存在'; exit 1)"

  [[ "$yes_flag" == "--yes" ]] && DEVOPS_YES=1
  confirm "永久刪除用戶 '$uid' 的所有資料（SQLite、向量、圖譜、第三方整合映射）。此操作不可逆。"
  run_remote "rm -rf $REMOTE_DATA_DIR/users/$uid"
  ok "用戶 $uid 的資料已刪除。"
}

# ── 指令：push-env [file] ─────────────────────────────────────────────────────
cmd_push_env() {
  local src="${1:-$LOCAL_DIR/.env}"
  [[ ! -f "$src" ]] && err "本地 .env 不存在：$src"
  info "推送 $src → 遠端 $REMOTE_DIR/.env"
  devops_ops_test_tripwire scp "${KG_SCP_CMD:-}"
  "${SCP_CMD[@]}" "$src" "$SERVER:$REMOTE_DIR/.env"
  ok "已推送 .env"
}

# ── 指令：setup ───────────────────────────────────────────────────────────────
# 初始化或 secret 變動時用：push-env + deploy 一條龍
cmd_setup() {
  cmd_push_env "${1:-}"
  cmd_deploy
}

# ── 指令：run <cmd...> ────────────────────────────────────────────────────────
cmd_run() {
  [[ -z "${1:-}" ]] && err "用法: $0 run \"<remote command>\""
  # base 自己也擋毀滅性命令（與 ops/devops_kg_safe.sh 同一個 predicate），
  # 直接 `devops.sh run ...` 不再繞過 safe wrapper 的 guard。
  devops_run_guard_enforce run "$*"
  run_remote "$*"
}

# ── 指令：container-run <cmd...> ─────────────────────────────────────────────
# 在 Docker container 內執行指令（自動包 docker exec）
cmd_container_run() {
  [[ -z "${1:-}" ]] && err "用法: $0 container-run \"<cmd>\""
  devops_run_guard_enforce container-run "$*"
  run_remote "docker inspect -f '{{.State.Running}}' $CONTAINER 2>/dev/null" \
    | grep -q true || err "容器 $CONTAINER 未在運行"
  info "在容器 $CONTAINER 內執行指令"
  run_remote "docker exec $CONTAINER $*"
}

# ── 指令：migrate-run <cmd...> ───────────────────────────────────────────────
# backup + 在 container 內執行遷移指令 + 自動重啟（清 in-memory cache）
cmd_migrate_run() {
  [[ -z "${1:-}" ]] && err "用法: $0 migrate-run \"<cmd>\""
  # guard 必須在 cmd_backup（rsync 連 prod）之前：被擋的命令不得有任何副作用。
  devops_run_guard_enforce migrate-run "$*"
  cmd_backup
  cmd_container_run "$@"
  info "遷移完成，重啟容器以清除 in-memory cache"
  cmd_restart
}

# ── 在容器內執行 argv（非 shell 字串）──────────────────────────────────────
# 與 cmd_container_run 的差別:後者契約是「遠端 shell 指令字串」(pipe/redirect 生效);
# 本函式契約是「一組 argv」——每個 arg 用 printf %q 轉義,讓遠端 bash 重新解析後
# 還原出完全相同的 argv。SQL 中的引號 / 括號 / % 因此原封不動抵達 ops_cli.py,
# 不再被 shell 二次解析破壞（這正是 container-script 早已採用的安全序列化手法）。
container_exec_argv() {
  run_remote "docker inspect -f '{{.State.Running}}' $CONTAINER 2>/dev/null" \
    | grep -q true || err "容器 $CONTAINER 未在運行"
  info "在容器 $CONTAINER 內執行 argv"
  local quoted; quoted=$(printf ' %q' "$@")
  run_remote "docker exec $CONTAINER$quoted"
}

# ── 指令：ops-cli <subcommand> [args] ───────────────────────────────────
cmd_ops_cli() {
  [[ -z "${1:-}" ]] && err "用法: $0 ops-cli <subcommand> [args...]"
  container_exec_argv python3 /app/ops_cli.py "$@"
}

# ── 指令：ops-edit <subcommand> [args] ──────────────────────────────────
# ops_cli.py 的**寫入**對應面。dry-run 預設(不傳 --commit 只印 plan)、寫前自動
# 備份 user_dir、寫後讀回 verify、audit。安全模型在工具內(EditContext),故與
# ops-cli 同級 argv pass-through —— is_blocked_run 的 shell-string 過濾不適用
# (argv 不走 remote shell 解析,破壞性已由 --commit gate + 自動備份守護)。
cmd_ops_edit() {
  [[ -z "${1:-}" ]] && err "用法: $0 ops-edit <subcommand> [args...]"
  container_exec_argv python3 /app/ops_edit.py "$@"
}

# ── 指令：ops-edit-batch <local-plan.json> [runner args] ───────────────────
cmd_ops_edit_batch() {
  local plan="${1:-}"
  [[ -z "$plan" ]] && err "用法: $0 ops-edit-batch <local-plan.json> [runner args...]"
  [[ ! -f "$plan" ]] && err "檔案不存在: $plan"
  local runner; runner="$(cd "$(dirname "$0")" && pwd)/ops/ops_edit_batch.py"
  [[ -f "$runner" ]] || err "batch runner 不存在: $runner"

  local remote_runner remote_plan
  remote_runner="$(make_remote_tmp_path "ops_edit_batch" ".py")"
  remote_plan="$(make_remote_tmp_path "ops_edit_batch_plan" ".json")"

  info "上傳 batch runner + plan → container"
  copy_local_to_container "$runner" "$remote_runner"
  copy_local_to_container "$plan" "$remote_plan"

  shift
  local quoted_args=""
  if [[ $# -gt 0 ]]; then
    quoted_args=$(printf ' %q' "$@")
  fi

  local rc=0
  set +e
  run_remote "docker exec $CONTAINER python3 $remote_runner $remote_plan$quoted_args"
  rc=$?
  set -e
  cleanup_remote_tmp "$remote_runner" "$remote_plan"
  return "$rc"
}

# ── 指令：container-script <local-script> [args] ────────────────────────
cmd_container_script() {
  local script="${1:-}"
  [[ -z "$script" ]] && err "用法: $0 container-script <local-script.py> [args...]"
  [[ ! -f "$script" ]] && err "檔案不存在: $script"
  local ext="${script##*.}"
  [[ "$ext" == "py" || "$ext" == "sh" ]] || err "只允許 .py 和 .sh: $script"
  local base; base=$(basename "$script")
  local remote_tmp="/tmp/$base"
  info "上傳 $script → container"
  copy_local_to_container "$script" "$remote_tmp"
  shift
  local interp
  [[ "$ext" == "py" ]] && interp="python3" || interp="bash"
  # $@ 透過 SSH 會被 remote shell 重新解析，必須用 printf %q 安全序列化
  local quoted_args=""
  if [[ $# -gt 0 ]]; then
    quoted_args=$(printf ' %q' "$@")
  fi
  run_remote "docker exec $CONTAINER $interp $remote_tmp$quoted_args"
  cleanup_remote_tmp "$remote_tmp"
}

cmd_help() {
  cat <<'HELP'

devops.sh — BooksAndVocab KG API DevOps

用法: ./devops.sh <command> [args]

指令:
HELP
  devops_command_help_lines
  cat <<'HELP'

Agent 環境變數:
  DEVOPS_YES=1            自動確認所有危險操作
HELP
}

# ── 指令：ssh ─────────────────────────────────────────────────────────────────
# 注意：此指令為互動式，agent 應使用 ./devops.sh run "<cmd>" 代替
cmd_ssh() {
  info "開啟互動式 SSH 連線（agent 請改用 'run' 指令）"
  devops_ops_test_tripwire ssh ""
  ssh "${SSH_OPTS[@]}" "$SERVER"
}

# ── 主程式 ────────────────────────────────────────────────────────────────────
if [[ "${DEVOPS_SOURCE_ONLY:-0}" != "1" ]]; then
  devops_dispatch_command "${1:-help}" "${@:2}"
fi
