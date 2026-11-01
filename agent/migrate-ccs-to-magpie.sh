#!/usr/bin/env bash
set -euo pipefail

# Migrate clients installed by the former cc-switch installer to prepared
# Magpie configuration. This is not a cc-switch database converter.
MIGRATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${MIGRATION_SCRIPT_DIR}/install.sh"
MIGRATION_STATE_DIR=""
LEGACY_BINARIES=()

print_usage() {
  cat <<'EOF'
Usage: migrate-ccs-to-magpie.sh [--env [FILE]] [--backup-file FILE]
                               [--refresh-config] [--force] [--start-gateway] [--verify]

Linux/root only, for the HOME of the client being migrated.
Uses the same proxy and MAGPIE_* settings as install.sh (details below).
Before running, close Claude/Codex and stop CC Switch and Magpie services.
Restores prepared Magpie config, then moves every cc-switch executable on
PATH into the migration state directory. Config rollback is managed by Magpie.
Legacy ~/.cc-switch data stays in place so existing skill links still work.
Does not convert CC Switch SQL or reuse its DAV Remote Root/Profile.
--skip-config is rejected: migration requires a Magpie configuration source.
--env [FILE]     Read environment variables, optionally loading a trusted file.
--backup-file    Use a local encrypted Magpie backup instead of DAV.
--force          Reinstall tools, including tools already available.
--refresh-config Accepted for compatibility; migration always refreshes config.
--start-gateway  Install/start the local-only user service; enable user linger.
--verify         Also start the gateway and send one real request per agent.
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

retire_cc_switch() {
  local binary index=0
  install -d -m 0700 "${MIGRATION_STATE_DIR}/bin"
  for binary in "${LEGACY_BINARIES[@]}"; do
    index=$((index + 1))
    printf '%s\t%s\n' "bin/cc-switch.$index" "$binary" >>"${MIGRATION_STATE_DIR}/binaries.tsv"
    mv -- "$binary" "${MIGRATION_STATE_DIR}/bin/cc-switch.$index"
  done
  hash -r
}

migration_exit() {
  local result=$?
  cleanup_proxy
  if ((result != 0)) && [[ -n "$MIGRATION_STATE_DIR" ]]; then
    log_error "迁移未完成；状态目录：$MIGRATION_STATE_DIR。配置回退请使用 Magpie。"
  fi
}

main() {
  parse_args "$@"
  if ((SKIP_CONFIG)); then log_error "迁移不能使用 --skip-config"; return 2; fi
  check_root
  check_linux
  check_commands
  for command in realpath pgrep; do
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
  MIGRATION_STATE_DIR="$(mktemp -d "${STATE_DIR}/ccs-migration.XXXXXX")"
  REFRESH_CONFIG=1
  check_gateway_environment
  preflight_config_source
  install_magpie
  install_claude
  install_codex
  # Migration always applies the selected source, even after a previous install.
  sync_config
  start_gateway
  verify_agents
  write_bash_aliases
  retire_cc_switch
  printf '%s\n' complete >"${MIGRATION_STATE_DIR}/complete"
  log_info "迁移完成；CC Switch 命令已移至 $MIGRATION_STATE_DIR/bin，旧数据/DAV 远端保留。"
  log_info "重新登录以加载 cc/cx；代理模型需要运行 magpie serve 或配置 magpie daemon install。"
  if ((VERIFY_AGENTS == 0)); then log_info "配置迁移完成，尚未验证模型调用；可用 install.sh --verify 补做验证。"; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
