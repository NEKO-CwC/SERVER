#!/usr/bin/env bash
set -euo pipefail

# Migrate clients installed by the former cc-switch installer to prepared
# Magpie configuration. This is not a cc-switch database converter.
MIGRATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${MIGRATION_SCRIPT_DIR}/install.sh"
MIGRATION_BACKUP_DIR=""
LEGACY_BINARIES=()

print_usage() {
  cat <<'EOF'
Usage: migrate-ccs-to-magpie.sh [--env [FILE]] [--backup-file FILE]
                               [--refresh-config] [--force]

Linux/root only, for the HOME of the client being migrated.
Uses the same proxy and MAGPIE_* settings as install.sh (details below).
Before running, close Claude/Codex and stop CC Switch and Magpie services.
Backs up local agent/config directories, restores prepared Magpie config,
then moves every cc-switch executable on PATH into the backup directory.
Legacy ~/.cc-switch data stays in place so existing skill links still work.
Does not convert CC Switch SQL or reuse its DAV Remote Root/Profile.
--skip-config is rejected: migration requires a Magpie configuration source.
--env [FILE]     Read environment variables, optionally loading a trusted file.
--backup-file    Use a local encrypted Magpie backup instead of DAV.
--force          Reinstall tools, including tools already available.
--refresh-config Accepted for compatibility; migration always refreshes config.
Run bash agent/install.sh --help for proxy and MAGPIE_* environment variables.
EOF
}

require_clients_stopped() {
  local process service scope
  for process in cc-switch magpie claude codex; do
    if pgrep -x "$process" >/dev/null 2>&1; then
      log_error "请先关闭 $process，再运行迁移（包括后台网关/同步进程）"
      return 1
    fi
  done
  if command -v systemctl >/dev/null 2>&1; then
    for scope in system user; do
      for service in cc-switch.service ccs.service magpie.service; do
        if systemctl "--$scope" is-active --quiet "$service" 2>/dev/null; then
          log_error "请先停止 $scope 服务 $service，再运行迁移"
          return 1
        fi
      done
    done
  fi
}

find_legacy_binaries() {
  local directory candidate existing duplicate
  local -a directories
  IFS=: read -r -a directories <<< "$PATH"
  for directory in "${directories[@]}"; do
    # /bin and /usr/bin can be the same directory. Resolve the parent only:
    # resolving the executable itself would move a symlink's shared target.
    directory="$(realpath -m -- "${directory:-.}")"
    candidate="${directory}/cc-switch"
    if [[ ! -x "$candidate" || -d "$candidate" ]]; then continue; fi
    duplicate=0
    for existing in "${LEGACY_BINARIES[@]}"; do
      if [[ "$candidate" == "$existing" ]]; then duplicate=1; break; fi
    done
    if ((duplicate == 0)); then LEGACY_BINARIES+=("$candidate"); fi
  done
}

backup_client() {
  local path resolved relative existing duplicate
  local -a paths=() candidates=(
    "${HOME:-/root}/.cc-switch"
    "${CC_SWITCH_CONFIG_DIR:-${HOME:-/root}/.cc-switch}"
    "${HOME:-/root}/.claude" "${CLAUDE_CONFIG_DIR:-${HOME:-/root}/.claude}"
    "${HOME:-/root}/.claude.json"
    "${HOME:-/root}/.codex" "${CODEX_HOME:-${HOME:-/root}/.codex}"
    "${HOME:-/root}/.agents" "$MAGPIE_CONFIG_DIR" "$BASHRC_FILE"
    "${STATE_DIR}/config-success"
  )
  # Native config roots may themselves be links (or have linked parents).
  # Save both the link and the data Magpie can change through it.
  for path in "${candidates[@]}"; do
    if [[ -e "$path" ]]; then
      resolved="$(realpath -e -- "$path")"
      if [[ "$resolved" != "$(realpath -sm -- "$path")" ]]; then
        candidates+=("$resolved")
      fi
    fi
  done
  MIGRATION_BACKUP_DIR="$(mktemp -d "${STATE_DIR}/ccs-migration.XXXXXX")"
  for path in "${candidates[@]}"; do
    path="$(realpath -sm -- "$path")"
    if [[ ! -e "$path" && ! -L "$path" ]]; then continue; fi
    # The archive must never contain itself through a custom parent path.
    if [[ "$MIGRATION_BACKUP_DIR/" == "$path/"* ]]; then
      log_error "备份目标包含迁移状态目录；请将 AGENT_INSTALL_STATE_DIR 设到配置目录之外"
      return 2
    fi
    relative="${path#/}"
    duplicate=0
    for existing in "${paths[@]}"; do
      if [[ "$relative" == "$existing" ]]; then duplicate=1; break; fi
    done
    if ((duplicate == 0)); then paths+=("$relative"); fi
  done
  # Do not dereference symlinks: old skill links and binary links must survive.
  if ((${#paths[@]})); then
    tar -C / -cpf "${MIGRATION_BACKUP_DIR}/client.tar" -- "${paths[@]}"
  else
    tar -cpf "${MIGRATION_BACKUP_DIR}/client.tar" --files-from /dev/null
  fi
  printf '%s\n' "${paths[@]}" >"${MIGRATION_BACKUP_DIR}/paths.txt"
  log_info "本地完整备份：${MIGRATION_BACKUP_DIR}/client.tar（含凭据，请妥善保管）"
}

retire_cc_switch() {
  local binary index=0
  install -d -m 0700 "${MIGRATION_BACKUP_DIR}/bin"
  for binary in "${LEGACY_BINARIES[@]}"; do
    index=$((index + 1))
    printf '%s\t%s\n' "bin/cc-switch.$index" "$binary" >>"${MIGRATION_BACKUP_DIR}/binaries.tsv"
    mv -- "$binary" "${MIGRATION_BACKUP_DIR}/bin/cc-switch.$index"
  done
  hash -r
}

migration_exit() {
  local result=$?
  cleanup_proxy
  if ((result != 0)) && [[ -n "$MIGRATION_BACKUP_DIR" ]]; then
    log_error "迁移未完成；本地备份位于 $MIGRATION_BACKUP_DIR。请核对原生配置后重试。"
  fi
}

main() {
  parse_args "$@"
  if ((SKIP_CONFIG)); then log_error "迁移不能使用 --skip-config"; return 2; fi
  check_root
  check_linux
  check_commands
  for command in tar realpath pgrep; do
    command -v "$command" >/dev/null || { log_error "迁移需要 $command"; return 2; }
  done
  umask 077
  collect_configuration
  unset CC_SWITCH_WEBDAV_PASSWORD
  prepare_process_env
  prepare_config
  STATE_DIR="$(realpath -m -- "$STATE_DIR")"
  install -d -m 0700 "$STATE_DIR"
  exec 9>"${STATE_DIR}/install.lock"
  flock -n 9 || { log_error "另一个 Agent 安装/迁移正在运行"; return 1; }
  trap migration_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  require_clients_stopped
  find_legacy_binaries
  backup_client
  install_magpie
  install_claude
  install_codex
  # Migration always applies the selected source, even after a previous install.
  REFRESH_CONFIG=1
  sync_config
  write_bash_aliases
  retire_cc_switch
  printf '%s\n' complete >"${MIGRATION_BACKUP_DIR}/complete"
  log_info "迁移完成；CC Switch 命令已移入备份，旧数据/DAV 远端保留。"
  log_info "重新登录以加载 cc/cx；代理模型需要运行 magpie serve 或配置 magpie daemon install。"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
