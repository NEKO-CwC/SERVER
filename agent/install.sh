#!/usr/bin/env bash
set -euo pipefail

# Linux agent installer: cc-switch + WebDAV/SQL config + Claude Code + Codex.

PROXY_URL="${AGENT_PROXY_URL:-}"
PROXY_MODE="${AGENT_PROXY_MODE:-env}"
SSH_PROXY_PASSWORD="${AGENT_SSH_PASSWORD:-}"
# Only the SSH process/askpass helper receives this secret, never installers.
unset AGENT_SSH_PASSWORD
export -n SSH_PROXY_PASSWORD
SSH_PROXY_PID=""
SSH_PROXY_DIR=""
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

Proxy environment:
  AGENT_PROXY_MODE=env  Use AGENT_PROXY_URL or inherited proxy variables (default).
  AGENT_PROXY_MODE=ssh  Start an SSH SOCKS tunnel on the first network operation.
  SSH mode requires AGENT_SSH_HOST, AGENT_SSH_USER, AGENT_SSH_PASSWORD.
  Optional: AGENT_SSH_PORT=22, AGENT_SSH_SOCKS_PORT=1080,
            AGENT_SSH_KNOWN_HOSTS_FILE (defaults to OpenSSH known_hosts).
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
  for cmd in curl bash sh sed touch sha256sum cut install mktemp mv rm flock cat chmod sleep; do
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

  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"
  case "$PROXY_MODE" in
    env)
      if [[ -n "$PROXY_URL" ]]; then export_proxy "$PROXY_URL"; fi
      log_info "使用当前进程的代理环境变量"
      ;;
    ssh) log_info "SSH SOCKS 模式：需要联网时建立临时隧道" ;;
    *) log_error "AGENT_PROXY_MODE 仅支持 env 或 ssh"; return 2 ;;
  esac
}

export_proxy() {
  export http_proxy="$1" https_proxy="$1" all_proxy="$1"
  export HTTP_PROXY="$1" HTTPS_PROXY="$1" ALL_PROXY="$1"
}

ssh_proxy_control() {
  ssh -F /dev/null -S "${SSH_PROXY_DIR}/control" -O check \
    -p "${AGENT_SSH_PORT:-22}" -l "$AGENT_SSH_USER" "$AGENT_SSH_HOST" \
    >/dev/null 2>&1
}

ensure_download_proxy() {
  [[ "$PROXY_MODE" == ssh ]] || return 0
  if [[ -n "$SSH_PROXY_PID" ]]; then
    if kill -0 "$SSH_PROXY_PID" 2>/dev/null && ssh_proxy_control; then return 0; fi
    log_error "SSH SOCKS 隧道已断开；停止安装，请修复连接后重试"
    return 1
  fi

  local ssh_port="${AGENT_SSH_PORT:-22}" socks_port="${AGENT_SSH_SOCKS_PORT:-1080}"
  local value deadline
  if [[ -z "${AGENT_SSH_HOST:-}" || -z "${AGENT_SSH_USER:-}" || -z "$SSH_PROXY_PASSWORD" ]]; then
    log_error "SSH 模式需要 AGENT_SSH_HOST、AGENT_SSH_USER、AGENT_SSH_PASSWORD"
    return 2
  fi
  if [[ "$AGENT_SSH_HOST" == -* || "$AGENT_SSH_HOST" == *[!a-zA-Z0-9.:-]* ||
        "$AGENT_SSH_USER" == -* || "$AGENT_SSH_USER" == *[!a-zA-Z0-9_.-]* ]]; then
    log_error "SSH 主机或用户名格式无效"
    return 2
  fi
  for value in "$ssh_port" "$socks_port"; do
    if [[ ! "$value" =~ ^[0-9]{1,5}$ ]] || ((10#$value < 1 || 10#$value > 65535)); then
      log_error "SSH 端口和 SOCKS 端口必须在 1–65535 之间"
      return 2
    fi
  done
  if [[ "$SSH_PROXY_PASSWORD" == *$'\n'* || "$SSH_PROXY_PASSWORD" == *$'\r'* ]]; then
    log_error "SSH 密码不能包含换行符"
    return 2
  fi
  command -v ssh >/dev/null 2>&1 || { log_error "SSH 模式需要 OpenSSH 客户端"; return 1; }
  SSH_PROXY_DIR="$(mktemp -d /tmp/neko-agent-ssh.XXXXXX)" || return 1
  cat >"${SSH_PROXY_DIR}/askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' "$AGENT_SSH_PASSWORD"
ASKPASS
  chmod 0700 "${SSH_PROXY_DIR}/askpass" || return 1

  local options=(
    -F /dev/null -N -T -n -M -S "${SSH_PROXY_DIR}/control"
    -D "127.0.0.1:${socks_port}" -p "$ssh_port" -l "$AGENT_SSH_USER"
    -o ExitOnForwardFailure=yes -o ControlPersist=no
    -o ConnectTimeout=15 -o ConnectionAttempts=1
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2
    -o PreferredAuthentications=password -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=1
    -o StrictHostKeyChecking=yes -o UpdateHostKeys=no
  )
  if [[ -n "${AGENT_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
    [[ -r "$AGENT_SSH_KNOWN_HOSTS_FILE" ]] || { log_error "SSH known_hosts 文件不可读"; return 2; }
    options+=(-o "UserKnownHostsFile=\"${AGENT_SSH_KNOWN_HOSTS_FILE}\"")
  fi
  log_info "建立临时 SSH SOCKS 隧道（仅监听 127.0.0.1:${socks_port}）"
  AGENT_SSH_PASSWORD="$SSH_PROXY_PASSWORD" \
    SSH_ASKPASS="${SSH_PROXY_DIR}/askpass" SSH_ASKPASS_REQUIRE=force \
    ssh "${options[@]}" "$AGENT_SSH_HOST" \
    </dev/null 9>&- >"${STATE_DIR}/ssh-proxy.log" 2>&1 &
  SSH_PROXY_PID=$!
  deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    if ! kill -0 "$SSH_PROXY_PID" 2>/dev/null; then
      log_error "SSH 隧道启动失败；检查认证、主机密钥和端口。详情：${STATE_DIR}/ssh-proxy.log"
      return 1
    fi
    if [[ -S "${SSH_PROXY_DIR}/control" ]] && ssh_proxy_control; then
      export_proxy "socks5h://127.0.0.1:${socks_port}"
      log_info "SSH SOCKS 隧道已就绪，下载使用远程 DNS 解析"
      return 0
    fi
    sleep 0.1
  done
  log_error "等待 SSH 隧道启动超时；详情：${STATE_DIR}/ssh-proxy.log"
  return 1
}

cleanup_proxy() {
  local ssh_result=0
  if [[ -n "$SSH_PROXY_PID" ]]; then
    if kill -0 "$SSH_PROXY_PID" 2>/dev/null; then
      if ! kill "$SSH_PROXY_PID" 2>/dev/null; then log_error "未能发送 SSH 停止信号"; fi
    fi
    wait "$SSH_PROXY_PID" || ssh_result=$?
    log_info "本次安装的 SSH 隧道已结束（退出码 ${ssh_result}）"
    SSH_PROXY_PID=""
  fi
  if [[ -n "$SSH_PROXY_DIR" ]]; then
    rm -rf -- "$SSH_PROXY_DIR"
    SSH_PROXY_DIR=""
  fi
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
  ensure_download_proxy || return $?

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
  ensure_download_proxy || return $?
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
  trap cleanup_proxy EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
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
