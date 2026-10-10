#!/usr/bin/env bash
# Source-only command metadata.  Keep this file free of transport, filesystem,
# and production side effects so both entrypoints and offline tests can source it.

if [[ -n "${_KG_DEVOPS_COMMAND_REGISTRY_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_KG_DEVOPS_COMMAND_REGISTRY_LOADED=1

# The base entrypoint owns these handlers.  The safe wrapper may expose a
# read-only alias in addition to a base command (for example `health`).
DEVOPS_BASE_COMMANDS=(
  setup push-env deploy restart env-check env-drift migrate status logs backup
  users user-info delete-user run container-run migrate-run ops-cli ops-edit
  ops-edit-batch container-script ssh
)

DEVOPS_SAFE_COMMANDS=(
  preflight deploy restart status health logs caddy-status caddyfile docker-ps
  docker-logs disk-usage memory-usage docker-stats backup backup-s3-test
  env-check env-drift migrate users user-info run container-run migrate-run
  ops-cli ops-edit ops-edit-batch container-script
)

DEVOPS_BLOCKED_COMMANDS=(setup push-env delete-user ssh)

# Help is generated from this list rather than duplicated in the two shells.
DEVOPS_COMMAND_HELP=(
  'setup [env_file]|push-env + deploy 一條龍（初始化或 secret 變動時）'
  'push-env [file]|推送本地 .env 到遠端（預設 backend/.env）'
  'deploy|standby git pull + build + health + smoke（需先 git push）'
  'restart|重啟容器（不重新 build）'
  'migrate|手動 fallback：對用戶 DB 補欄位'
  'env-check|檢查遠端 .env 必要環境變數'
  'env-drift|檢查本地/遠端 .env 一致性（path key 正規化）'
  'status|Docker / CF Tunnel / 磁碟 / 用戶數概覽'
  'logs [n]|最新 n 行日誌（預設 50）'
  'backup|備份 data/ 到本地 backups/'
  'users|用戶數 + 每人一行 uid provider last_login（不含 email／訂閱）'
  'user-info <id>|查看特定用戶單字統計'
  'delete-user <id> [--yes]|刪除用戶資料（需明示確認）'
  'run "<cmd>"|在遠端 host 執行任意指令'
  'container-run "<cmd>"|在 Docker 容器內執行指令'
  'migrate-run "<cmd>"|container-run + 自動重啟'
  'ops-cli <sub> [args]|在容器內執行 ops_cli.py'
  'ops-edit <sub> [args]|在容器內執行 ops_edit.py'
  'ops-edit-batch <plan.json> [args]|執行 ops_edit batch plan'
  'container-script <script> [args]|上傳並執行容器腳本'
  'ssh|開啟互動式 SSH（agent 應改用 run）'
)

# Safe-only aliases have no base handler, so their short descriptions live here;
# descriptions for commands shared with the base entrypoint are reused from
# DEVOPS_COMMAND_HELP below rather than copied into the wrapper.
DEVOPS_SAFE_ALIAS_HELP=(
  'preflight|顯示安全執行前檢查（不執行遠端命令）'
  'health [--json]|host / container / tunnel 健康聚合'
  'caddy-status --json|探測 cloudflared tunnel 狀態（固定 label/pid_count/status，secret-safe）'
  'caddyfile|說明 Cloudflare Tunnel ingress 正本（不發遠端命令）'
  'docker-ps|固定唯讀 docker ps'
  'docker-logs [n]|固定唯讀容器日誌（預設 100 行）'
  'disk-usage|固定唯讀 df -h'
  'memory-usage --json|固定唯讀 macOS 記憶體與 swap 數值（secret-safe）'
  'docker-stats|固定唯讀 docker stats'
  'backup-s3-test|驗證 standby launchd→S3 備份工作'
)

_devops_registry_has() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

_devops_registry_unique() {
  local -a values=("$@")
  local i j
  for ((i = 0; i < ${#values[@]}; i++)); do
    for ((j = i + 1; j < ${#values[@]}; j++)); do
      [[ "${values[$i]}" == "${values[$j]}" ]] && return 1
    done
  done
}

devops_command_registered() {
  _devops_registry_has "$1" "${DEVOPS_BASE_COMMANDS[@]}"
}

devops_safe_command_registered() {
  _devops_registry_has "$1" "${DEVOPS_SAFE_COMMANDS[@]}"
}

devops_command_blocked() {
  _devops_registry_has "$1" "${DEVOPS_BLOCKED_COMMANDS[@]}"
}

devops_command_help_lines() {
  local row command description
  for row in "${DEVOPS_COMMAND_HELP[@]}"; do
    command="${row%%|*}"
    description="${row#*|}"
    printf '  %-28s %s\n' "$command" "$description"
  done
}

devops_command_help_row() {
  local needle="$1" row display
  for row in "${DEVOPS_COMMAND_HELP[@]}" "${DEVOPS_SAFE_ALIAS_HELP[@]}"; do
    display="${row%%|*}"
    [[ "$display" == "$needle" || "$display" == "$needle "* ]] && {
      printf '%s\n' "$row"
      return 0
    }
  done
  return 1
}

devops_safe_command_help_lines() {
  local prefix="$1" command row display description
  for command in "${DEVOPS_SAFE_COMMANDS[@]}"; do
    row="$(devops_command_help_row "$command")" || return 1
    display="${row%%|*}"
    description="${row#*|}"
    printf '  %s %-28s %s\n' "$prefix" "$display" "$description"
  done
}

devops_command_registry_validate() {
  local -a all=("${DEVOPS_BASE_COMMANDS[@]}" "${DEVOPS_SAFE_COMMANDS[@]}")
  local item row command
  _devops_registry_unique "${DEVOPS_BASE_COMMANDS[@]}" || return 1
  _devops_registry_unique "${DEVOPS_SAFE_COMMANDS[@]}" || return 1
  _devops_registry_unique "${DEVOPS_BLOCKED_COMMANDS[@]}" || return 1
  for item in "${DEVOPS_BASE_COMMANDS[@]}"; do
    _devops_registry_has "$item" "${all[@]}" || return 1
  done
  for item in "${DEVOPS_BLOCKED_COMMANDS[@]}"; do
    devops_command_registered "$item" || return 1
  done
  for row in "${DEVOPS_COMMAND_HELP[@]}"; do
    command="${row%%|*}"
    command="${command%% *}"
    devops_command_registered "$command" || return 1
  done
  for item in "${DEVOPS_SAFE_COMMANDS[@]}"; do
    devops_command_help_row "$item" >/dev/null || return 1
  done
  return 0
}
