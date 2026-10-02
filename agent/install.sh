#!/usr/bin/env bash
set -euo pipefail

# Linux agent installer: cc-switch + WebDAV/SQL config + Claude Code + Codex.

PROXY_URL="${AGENT_PROXY_URL:-}"
SQL_FILE=""
FORCE=0
REFRESH_CONFIG=0
SKIP_CONFIG=0
WEBDAV_BASE_URL="${CC_SWITCH_WEBDAV_BASE_URL:-}"
WEBDAV_REMOTE_ROOT="${CC_SWITCH_WEBDAV_REMOTE_ROOT:-cc-switch-sync}"
WEBDAV_PROFILE="${CC_SWITCH_WEBDAV_PROFILE:-default}"
WEBDAV_USERNAME="${CC_SWITCH_WEBDAV_USERNAME:-}"
WEBDAV_PASSWORD="${CC_SWITCH_WEBDAV_PASSWORD:-}"
STATE_DIR="${AGENT_INSTALL_STATE_DIR:-${HOME:-/root}/.local/state/neko-agent-install}"
CC_CONFIG_DIR="${CC_SWITCH_CONFIG_DIR:-${HOME:-/root}/.cc-switch}"
CONFIG_FINGERPRINT=""

log_step() {
  printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"
}

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_error() {
  printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
}

print_usage() {
  cat <<'EOF'
Usage: install.sh [--sql-file FILE | --skip-config] [--refresh-config] [--force]

Options:
  --sql-file FILE  Import cc-switch config from a local SQL file and skip WebDAV.
  --skip-config    Install tools without importing/syncing configuration.
  --refresh-config  Sync/import again even if the same source already succeeded.
  --force         Reinstall tools. Configuration still needs --refresh-config.
  -h, --help       Show this help message.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) FORCE=1; shift ;;
      --refresh-config) REFRESH_CONFIG=1; shift ;;
      --skip-config) SKIP_CONFIG=1; shift ;;
      --sql-file)
        if [[ $# -lt 2 || -z "$2" ]]; then
          log_error "--sql-file 需要指定 SQL 文件"
          return 2
        fi
        SQL_FILE="$2"
        shift 2
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        log_error "未知参数: $1"
        print_usage >&2
        return 2
        ;;
    esac
  done

  if ((SKIP_CONFIG)) && { [[ -n "$SQL_FILE" ]] || ((REFRESH_CONFIG)); }; then
    log_error "--skip-config 不能与 --sql-file 或 --refresh-config 一起使用"
    return 2
  fi

  if [[ -n "$SQL_FILE" ]]; then
    if [[ ! -f "$SQL_FILE" ]]; then
      log_error "SQL 文件不存在: $SQL_FILE"
      return 2
    fi
    if [[ ! -r "$SQL_FILE" ]]; then
      log_error "SQL 文件不可读: $SQL_FILE"
      return 2
    fi
  fi
}

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log_error "此脚本必须以 root 权限运行"
    exit 1
  fi
}

check_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    log_error "此脚本仅支持 Linux 系统"
    exit 1
  fi
}

check_commands() {
  local missing=()
  for cmd in curl bash sh sed touch sha256sum cut install mktemp mv rm flock cat; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "缺少必要命令: ${missing[*]}"
    exit 1
  fi
}

prepare_process_env() {
  log_step "配置当前安装进程环境"

  if [[ -n "$PROXY_URL" ]]; then
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
  fi
  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"

  log_info "代理仅在当前安装进程中生效"
}

install_cc_switch() {
  log_step "安装 cc-switch"

  if tool_ready cc-switch; then return; fi

  if ! CC_SWITCH_FORCE=1 run_installer https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh bash; then
    log_error "cc-switch 安装失败"
    return 1
  fi

  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"
  if ! cc-switch --version >/dev/null 2>&1; then
    log_error "cc-switch 安装后无法找到命令"
    return 1
  fi

  log_info "cc-switch: $(cc-switch --version 2>&1)"
}

configure_webdav() {
  log_step "配置 cc-switch WebDAV"

  if ! config_command cc-switch config webdav set \
    --base-url "$WEBDAV_BASE_URL" \
    --remote-root "$WEBDAV_REMOTE_ROOT" \
    --profile "$WEBDAV_PROFILE" \
    --username "$WEBDAV_USERNAME" \
    --password "$WEBDAV_PASSWORD" \
    --enable \
    --no-auto-sync; then
    log_error "WebDAV 配置失败"
    return 1
  fi

  if ! config_command cc-switch config webdav check-connection; then
    log_error "WebDAV 连接检查失败"
    return 1
  fi

  if ! config_command cc-switch config webdav download; then
    log_error "WebDAV 下载配置失败"
    return 1
  fi
}

import_sql_config() {
  log_step "从 SQL 文件导入 cc-switch 配置"
  if ! config_command cc-switch config import "$SQL_FILE"; then
    log_error "SQL 配置导入失败"
    return 1
  fi
}

install_claude() {
  log_step "安装 Claude Code"

  if tool_ready claude; then return; fi

  if ! run_installer https://claude.ai/install.sh bash; then
    log_error "Claude Code 安装失败"
    return 1
  fi

  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"
  if ! claude --version >/dev/null 2>&1; then
    log_error "Claude Code 安装后无法找到 claude 命令"
    return 1
  fi

  log_info "claude: $(claude --version 2>&1)"
}

install_codex() {
  log_step "安装 Codex"

  if tool_ready codex; then return; fi

  if ! CODEX_NON_INTERACTIVE=1 run_installer https://chatgpt.com/codex/install.sh sh; then
    log_error "Codex 安装失败"
    return 1
  fi

  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"
  if ! codex --version >/dev/null 2>&1; then
    log_error "Codex 安装后无法找到 codex 命令"
    return 1
  fi

  log_info "codex: $(codex --version 2>&1)"
}

write_bash_aliases() {
  log_step "写入 bash aliases"

  local bashrc="${AGENT_BASHRC:-${HOME:-/root}/.bashrc}"
  touch "$bashrc"

  sed -i -E \
    -e '/^# >>> neko agent aliases >>>$/,/^# <<< neko agent aliases <<<$/d' \
    -e '/^[[:space:]]*alias[[:space:]]+(cc|cx)=/d' \
    "$bashrc"
  {
    printf "%s\n" "# >>> neko agent aliases >>>"
    printf "%s\n" 'case ":$PATH:" in'
    printf "%s\n" '  *":${HOME:-/root}/.local/bin:"*) ;;'
    printf "%s\n" '  *) export PATH="${HOME:-/root}/.local/bin:$PATH" ;;'
    printf "%s\n" 'esac'
    printf "%s\n" "alias cc='IS_SANDBOX=1 claude --dangerously-skip-permissions'"
    printf "%s\n" "alias cx='codex --yolo'"
    printf "%s\n" "# <<< neko agent aliases <<<"
  } >> "$bashrc"

  log_info "已写入 $bashrc，并确保 ~/.local/bin 在 PATH 中"
}

tool_ready() {
  if ((FORCE == 0)) && command -v "$1" >/dev/null 2>&1 && "$1" --version >/dev/null 2>&1; then
    log_info "跳过 $1：已安装且可运行"
    return 0
  fi
  return 1
}

run_installer() {
  local installer_file result=0
  installer_file="$(mktemp "${STATE_DIR}/installer.XXXXXX")" || return 1
  if curl -fsSL --connect-timeout 20 --max-time 180 "$1" -o "$installer_file"; then
    "$2" "$installer_file" || result=$?
  else
    result=$?
  fi
  rm -f -- "$installer_file"
  return "$result"
}

config_command() {
  # Third-party output can contain credentials; keep it out of the terminal.
  if "$@" >"${STATE_DIR}/config-last.log" 2>&1; then
    rm -f -- "${STATE_DIR}/config-last.log"
  else
    log_error "配置命令失败；详情仅保存在 ${STATE_DIR}/config-last.log（可能含凭据）"
    return 1
  fi
}

prepare_config() {
  ((SKIP_CONFIG == 0)) || return 0
  if [[ -n "$SQL_FILE" ]]; then
    CONFIG_FINGERPRINT="$(printf '%s\0' sql-v1 "$CC_CONFIG_DIR" "$(sha256sum "$SQL_FILE" | cut -d ' ' -f1)" | sha256sum | cut -d ' ' -f1)"
  else
    if [[ -z "$WEBDAV_BASE_URL" || -z "$WEBDAV_USERNAME" || -z "$WEBDAV_PASSWORD" ]]; then
      log_error "请设置 CC_SWITCH_WEBDAV_BASE_URL、CC_SWITCH_WEBDAV_USERNAME、CC_SWITCH_WEBDAV_PASSWORD，或使用 --sql-file / --skip-config"
      return 2
    fi
    CONFIG_FINGERPRINT="$(printf '%s\0' webdav-v1 "$CC_CONFIG_DIR" "$WEBDAV_BASE_URL" "$WEBDAV_REMOTE_ROOT" "$WEBDAV_PROFILE" "$WEBDAV_USERNAME" "$WEBDAV_PASSWORD" | sha256sum | cut -d ' ' -f1)"
  fi
}

sync_config() {
  if ((SKIP_CONFIG)); then
    log_info "按参数跳过配置同步"
    return
  fi
  local marker="${STATE_DIR}/config-success" saved=""
  if [[ -f "$marker" ]]; then saved="$(cat "$marker")"; fi
  if ((REFRESH_CONFIG == 0)) && [[ "$saved" == "$CONFIG_FINGERPRINT" && -s "${CC_CONFIG_DIR}/cc-switch.db" ]]; then
    log_info "跳过配置同步：相同来源已成功导入且本地数据库存在（更新远端内容请用 --refresh-config）"
    return
  fi
  rm -f -- "$marker"
  if [[ -n "$SQL_FILE" ]]; then import_sql_config; else configure_webdav; fi
  if [[ ! -s "${CC_CONFIG_DIR}/cc-switch.db" ]]; then
    log_error "配置命令完成，但未找到非空 cc-switch 数据库；不记录成功状态"
    return 1
  fi
  printf '%s\n' "$CONFIG_FINGERPRINT" >"${marker}.tmp"
  mv -f -- "${marker}.tmp" "$marker"
}

main() {
  log_step "Linux Agent 安装"

  parse_args "$@"
  check_root
  check_linux
  check_commands
  umask 077
  install -d -m 0700 "$STATE_DIR"
  exec 9>"${STATE_DIR}/install.lock"
  flock -n 9 || { log_error "另一个 Agent 安装正在运行"; return 1; }
  prepare_process_env
  prepare_config
  install_cc_switch
  sync_config
  install_claude
  install_codex
  write_bash_aliases

  log_step "安装完成"
  log_info "请运行 'source ~/.bashrc' 或重新登录以加载 cc/cx alias"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
