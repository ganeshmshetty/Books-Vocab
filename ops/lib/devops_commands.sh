#!/usr/bin/env bash
# Source-only dispatch helpers.  This file deliberately does not execute a
# command when sourced; callers own configuration, transport, and side effects.

if [[ -n "${_KG_DEVOPS_COMMANDS_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_KG_DEVOPS_COMMANDS_LOADED=1

devops_handler_for_command() {
  case "$1" in
    setup) echo cmd_setup ;;
    push-env) echo cmd_push_env ;;
    deploy) echo cmd_deploy ;;
    restart) echo cmd_restart ;;
    env-check) echo cmd_env_check ;;
    env-drift) echo cmd_env_drift ;;
    migrate) echo cmd_migrate ;;
    status) echo cmd_status ;;
    logs) echo cmd_logs ;;
    backup) echo cmd_backup ;;
    users) echo cmd_users ;;
    user-info) echo cmd_user_info ;;
    delete-user) echo cmd_delete_user ;;
    run) echo cmd_run ;;
    container-run) echo cmd_container_run ;;
    migrate-run) echo cmd_migrate_run ;;
    ops-cli) echo cmd_ops_cli ;;
    ops-edit) echo cmd_ops_edit ;;
    ops-edit-batch) echo cmd_ops_edit_batch ;;
    container-script) echo cmd_container_script ;;
    ssh) echo cmd_ssh ;;
    help|--help|-h|"") echo cmd_help ;;
    *) return 1 ;;
  esac
}

devops_dispatch_command() {
  local command="${1:-help}" handler
  shift || true
  handler="$(devops_handler_for_command "$command")" || {
    cmd_help
    return 0
  }
  declare -F "$handler" >/dev/null || {
    printf '✗ registered command has no handler: %s (%s)\n' "$command" "$handler" >&2
    return 70
  }
  "$handler" "$@"
}
