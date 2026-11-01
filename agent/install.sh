#!/usr/bin/env bash
set -euo pipefail

# Linux agent installer: Magpie + encrypted config + Claude Code + Codex.

USE_ENV=0
ENV_FILE=""
CONFIG_SOURCE="dav"
BACKUP_FILE=""
CLI_BACKUP_FILE=""
FORCE=0
REFRESH_CONFIG=0
SKIP_CONFIG=0
START_GATEWAY=0
VERIFY_AGENTS=0
WEBDAV_BASE_URL=""
WEBDAV_USERNAME=""
WEBDAV_PASSWORD=""
BACKUP_PASSPHRASE=""
STATE_DIR=""
MAGPIE_CONFIG_DIR=""
BASHRC_FILE=""
CONFIG_FINGERPRINT=""
AGENT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AGENT_SCRIPT_DIR}/../lib/proxy.sh"

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
Usage: install.sh [--env [FILE]] [--backup-file FILE | --skip-config]
                  [--refresh-config] [--force] [--start-gateway] [--verify]

Without --env, interactively choose a proxy and Magpie source (default: DAV).
Passwords are read without echo. A terminal is required for interactive mode.

Options:
  --env [FILE]    Non-interactive: use environment variables, optionally loading FILE.
  --backup-file FILE  Restore a local encrypted Magpie backup instead of WebDAV.
  --skip-config    Install tools without importing/syncing configuration.
  --refresh-config  Sync/import again even if the same source already succeeded.
  --force         Reinstall tools. Configuration still needs --refresh-config.
  --start-gateway  Install/start the local-only user service; enable user linger.
  --verify        Also start the gateway and send one real request per agent.
  -h, --help       Show this help message.

Proxy environment:
  Environment variables below are only read with --env.
  INSTALL_PROXY_MODE=none  Download directly without a proxy.
  INSTALL_PROXY_MODE=env  Use INSTALL_PROXY_URL or inherited proxy variables (default).
  INSTALL_PROXY_MODE=ssh  Start an SSH SOCKS tunnel on the first network operation.
  SSH mode requires INSTALL_SSH_HOST, INSTALL_SSH_USER, INSTALL_SSH_PASSWORD.
  Optional: INSTALL_SSH_PORT=22, INSTALL_SSH_SOCKS_PORT=1080,
            INSTALL_SSH_HOST_KEY_CHECKING=no|accept-new|yes (default: no),
            INSTALL_SSH_KNOWN_HOSTS_FILE (used only with accept-new or yes).

  Legacy AGENT_PROXY_* / AGENT_SSH_* names remain supported.

Magpie environment:
  MAGPIE_CONFIG_SOURCE=dav     Sync WebDAV configuration (default).
  MAGPIE_WEBDAV_BASE_URL       Parent of Magpie's own "magpie" folder.
  MAGPIE_WEBDAV_USERNAME       WebDAV login name.
  MAGPIE_WEBDAV_PASSWORD       WebDAV login password.
  MAGPIE_PASSPHRASE            Separate encryption passphrase (both sources).
  MAGPIE_CONFIG_SOURCE=backup  Restore MAGPIE_BACKUP_FILE from a local file.
  XDG_CONFIG_HOME              Standard config parent; Magpie uses its magpie/.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        USE_ENV=1
        shift
        if [[ $# -gt 0 && "$1" != -* ]]; then ENV_FILE="$1"; shift; fi
        ;;
      --force) FORCE=1; shift ;;
      --refresh-config) REFRESH_CONFIG=1; shift ;;
      --skip-config) SKIP_CONFIG=1; shift ;;
      --start-gateway) START_GATEWAY=1; shift ;;
      --verify) VERIFY_AGENTS=1; START_GATEWAY=1; shift ;;
      --backup-file)
        if [[ $# -lt 2 || -z "$2" ]]; then
          log_error "--backup-file 需要指定 Magpie 加密备份文件"
          return 2
        fi
        CLI_BACKUP_FILE="$2"
        shift 2
        ;;
      --sql-file)
        log_error "Magpie 不接受 CC Switch SQL；已有客户端请用 agent/migrate-ccs-to-magpie.sh 接入 Magpie DAV，或先导出 Magpie 备份再使用 --backup-file"
        return 2 ;;
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

  if ((SKIP_CONFIG)) && { [[ -n "$CLI_BACKUP_FILE" ]] || ((REFRESH_CONFIG)); }; then
    log_error "--skip-config 不能与 --backup-file 或 --refresh-config 一起使用"
    return 2
  fi
  if ((SKIP_CONFIG && VERIFY_AGENTS)); then
    log_error "--verify 需要配置来源，不能与 --skip-config 一起使用"
    return 2
  fi

}

set_default_paths() {
  STATE_DIR="${HOME:-/root}/.local/state/neko-agent-install"
  MAGPIE_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/magpie"
  BASHRC_FILE="${HOME:-/root}/.bashrc"
}

load_environment_config() {
  load_env_file
  proxy_load_environment
  CONFIG_SOURCE="${MAGPIE_CONFIG_SOURCE:-dav}"
  BACKUP_FILE="${MAGPIE_BACKUP_FILE:-}"
  WEBDAV_BASE_URL="${MAGPIE_WEBDAV_BASE_URL:-}"
  WEBDAV_USERNAME="${MAGPIE_WEBDAV_USERNAME:-}"
  WEBDAV_PASSWORD="${MAGPIE_WEBDAV_PASSWORD:-}"
  BACKUP_PASSPHRASE="${MAGPIE_PASSPHRASE:-}"
  STATE_DIR="${AGENT_INSTALL_STATE_DIR:-$STATE_DIR}"
  MAGPIE_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/magpie"
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then export XDG_CONFIG_HOME; fi
  BASHRC_FILE="${AGENT_BASHRC:-$BASHRC_FILE}"
}

prompt_configuration() {
  local choice
  if [[ ! -t 0 ]]; then
    log_error "默认交互模式需要终端；自动运行请使用 --env 或 --env FILE"
    return 2
  fi
  prompt_proxy
  if ((SKIP_CONFIG)); then return; fi
  if [[ -n "$CLI_BACKUP_FILE" ]]; then
    prompt_value BACKUP_PASSPHRASE "Magpie 加密口令" "" 1 1
    return
  fi
  while true; do
    prompt_value choice "Magpie 配置来源：1) WebDAV  2) 本地加密备份" 1
    case "$choice" in
      1)
        CONFIG_SOURCE=dav
        prompt_value WEBDAV_BASE_URL "WebDAV Base URL"
        prompt_value WEBDAV_USERNAME "WebDAV 用户名"
        prompt_value WEBDAV_PASSWORD "WebDAV 密码" "" 1 1
        prompt_value BACKUP_PASSPHRASE "Magpie 加密口令" "" 1 1
        break ;;
      2)
        CONFIG_SOURCE=backup
        while true; do
          prompt_value BACKUP_FILE "本地 Magpie 备份文件路径"
          if [[ -f "$BACKUP_FILE" && -r "$BACKUP_FILE" ]]; then break; fi
          log_error "备份文件不存在或不可读，请重新输入"
        done
        prompt_value BACKUP_PASSPHRASE "Magpie 加密口令" "" 1 1
        break ;;
      *) log_error "请选择 1 或 2" ;;
    esac
  done
}

collect_configuration() {
  set_default_paths
  if ((USE_ENV)); then load_environment_config; else prompt_configuration; fi
  # Keep SSH credentials out of installer subprocesses in either input mode.
  proxy_hide_password
  # Only Magpie receives secrets, on stdin; installers never inherit them.
  unset MAGPIE_WEBDAV_PASSWORD MAGPIE_PASSPHRASE
  export -n WEBDAV_PASSWORD BACKUP_PASSPHRASE
  if [[ -n "$CLI_BACKUP_FILE" ]]; then CONFIG_SOURCE=backup; BACKUP_FILE="$CLI_BACKUP_FILE"; fi
  if ((SKIP_CONFIG == 0)); then
    case "$CONFIG_SOURCE" in
      dav|webdav) CONFIG_SOURCE=dav; BACKUP_FILE="" ;;
      backup)
        if [[ ! -f "$BACKUP_FILE" || ! -r "$BACKUP_FILE" ]]; then
          log_error "备份来源需要可读的 MAGPIE_BACKUP_FILE，或使用 --backup-file FILE"
          return 2
        fi ;;
      *) log_error "MAGPIE_CONFIG_SOURCE 仅支持 dav 或 backup"; return 2 ;;
    esac
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
  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"
  proxy_prepare_env
}

install_magpie() {
  log_step "安装 Magpie"

  if tool_ready magpie; then return; fi

  if ! run_installer https://usemagpie.ai/install.sh sh; then
    log_error "Magpie 安装失败"
    return 1
  fi

  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"
  if ! magpie --version >/dev/null 2>&1; then
    log_error "Magpie 安装后无法找到命令"
    return 1
  fi

  log_info "magpie: $(magpie --version 2>&1)"
}

configure_webdav() {
  log_step "配置 Magpie WebDAV"
  ensure_download_proxy || return $?

  # Explicit empty secret fields always prompt: stdin order is deterministic,
  # including reruns on a machine that already saved one of these secrets.
  if ! printf '%s\n%s\n' "$WEBDAV_PASSWORD" "$BACKUP_PASSPHRASE" |
      config_command magpie webdav on "$WEBDAV_BASE_URL" "user=$WEBDAV_USERNAME" \
        password= passphrase= keys=yes agents=yes library=yes; then
    # A failed first sync still enables Magpie's timer; keep this manual-only.
    magpie webdav auto off >>"${STATE_DIR}/config-last.log" 2>&1 || true
    log_error "WebDAV 配置/同步失败"
    log_info "检查 DAV 网络/代理、登录凭据和加密口令；若日志提示 IPv6 network is unreachable，请配置可访问 DAV 的代理后重试。"
    return 1
  fi
  config_command magpie webdav auto off
}

restore_backup_config() {
  log_step "恢复本地 Magpie 加密备份"
  if ! printf '%s\n' "$BACKUP_PASSPHRASE" | config_command magpie restore "$BACKUP_FILE"; then
    log_error "Magpie 备份恢复失败"
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

  local bashrc="$BASHRC_FILE"
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
  if [[ -z "$BACKUP_PASSPHRASE" || "$BACKUP_PASSPHRASE" == *$'\n'* || "$BACKUP_PASSPHRASE" == *$'\r'* ]]; then
    log_error "需要非空、单行的 Magpie 加密口令；--env 模式请设置 MAGPIE_PASSPHRASE"
    return 2
  fi
  if [[ -n "$BACKUP_FILE" ]]; then
    CONFIG_FINGERPRINT="$(printf '%s\0' magpie-backup-v1 "$MAGPIE_CONFIG_DIR" "$(sha256sum "$BACKUP_FILE" | cut -d ' ' -f1)" "$BACKUP_PASSPHRASE" | sha256sum | cut -d ' ' -f1)"
  else
    if [[ "$WEBDAV_BASE_URL$WEBDAV_USERNAME" == *$'\n'* || "$WEBDAV_BASE_URL$WEBDAV_USERNAME" == *$'\r'* ]]; then
      log_error "WebDAV 地址和用户名不能包含换行符"
      return 2
    fi
    if [[ -z "$WEBDAV_BASE_URL" || -z "$WEBDAV_USERNAME" || -z "$WEBDAV_PASSWORD" ]]; then
      log_error "WebDAV 需要地址、用户名和密码；--env 模式请设置 MAGPIE_WEBDAV_BASE_URL、MAGPIE_WEBDAV_USERNAME、MAGPIE_WEBDAV_PASSWORD"
      return 2
    fi
    case "$WEBDAV_BASE_URL" in
      http://?*|https://?*) ;;
      *) log_error "WebDAV Base URL 必须使用 HTTP 或 HTTPS"; return 2 ;;
    esac
    if [[ "$WEBDAV_PASSWORD" == "$BACKUP_PASSPHRASE" || "$WEBDAV_PASSWORD" == *$'\n'* || "$WEBDAV_PASSWORD" == *$'\r'* ]]; then
      log_error "WebDAV 密码须为单行，且须与加密口令不同（Magpie 要求）"
      return 2
    fi
    CONFIG_FINGERPRINT="$(printf '%s\0' magpie-webdav-v1 "$MAGPIE_CONFIG_DIR" "$WEBDAV_BASE_URL" "$WEBDAV_USERNAME" "$WEBDAV_PASSWORD" "$BACKUP_PASSPHRASE" | sha256sum | cut -d ' ' -f1)"
  fi
}

config_sync_needed() {
  ((SKIP_CONFIG == 0)) || return 1
  local saved="" marker="${STATE_DIR}/config-success"
  if [[ -f "$marker" ]]; then saved="$(cat "$marker")"; fi
  ((REFRESH_CONFIG)) || [[ "$saved" != "$CONFIG_FINGERPRINT" || ! -s "${MAGPIE_CONFIG_DIR}/providers.json" ]]
}

curl_config_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

preflight_config_source() {
  config_sync_needed || return 0
  [[ "$CONFIG_SOURCE" == dav ]] || return 0
  log_step "检查 Magpie DAV 连通性"
  ensure_download_proxy || return $?
  local status result=0 logfile="${STATE_DIR}/dav-preflight.log"
  # HEAD checks transport/auth without downloading or changing the backup.
  # Credentials stay on stdin, never in argv or installer subprocess env.
  status="$(
    {
      printf 'url = '; curl_config_value "${WEBDAV_BASE_URL%/}/magpie/magpie.magpie-backup"; printf '\n'
      printf 'user = '; curl_config_value "$WEBDAV_USERNAME:$WEBDAV_PASSWORD"; printf '\n'
    } | curl --config - --head --silent --show-error --location \
        --proto '=http,https' --proto-redir '=http,https' \
        --connect-timeout 15 --max-time 30 --output /dev/null \
        --write-out '%{http_code}' 2>"$logfile"
  )" || result=$?
  if ((result)); then
    log_error "DAV 网络预检失败（curl $result）；尚未安装工具或改写 agent 配置。"
    log_info "检查 DNS、代理和 IPv4/IPv6 路由；IPv6 不可达时请选可访问 DAV 的 HTTP/SOCKS 或 SSH 代理。私有日志：$logfile"
    return 1
  fi
  case "$status" in
    2??) rm -f -- "$logfile" ;;
    405|501)
      rm -f -- "$logfile"
      log_info "DAV 不支持 HEAD；网络已接通，登录及备份有效性由 Magpie 同步确认。" ;;
    401|403) log_error "DAV 拒绝访问（HTTP $status）；检查 DAV 用户名、密码和目录权限。"; return 1 ;;
    404) log_error "未找到 Magpie 远端备份（HTTP 404）；确认 URL 是 magpie 文件夹的父目录，并先在源机器同步。"; return 1 ;;
    *) log_error "DAV 预检失败（HTTP $status）；检查服务及反向代理，未继续安装或同步。"; return 1 ;;
  esac
}

check_gateway_environment() {
  ((START_GATEWAY)) || return 0
  local command
  for command in systemctl loginctl; do
    command -v "$command" >/dev/null || { log_error "--start-gateway 需要 $command"; return 2; }
  done
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    log_error "无法连接 systemd 用户服务；请在有用户服务环境的登录会话中运行，或省略 --start-gateway/--verify 后自行运行 magpie serve。"
    return 2
  fi
  if ((VERIFY_AGENTS)); then
    command -v timeout >/dev/null || { log_error "--verify 需要 timeout"; return 2; }
  fi
}

start_gateway() {
  ((START_GATEWAY)) || return 0
  log_step "启动 Magpie 本机网关"
  config_command magpie daemon install --no-web
  config_command loginctl enable-linger "$(id -un)"
  if ! systemctl --user is-active --quiet magpie.service; then
    log_error "Magpie 用户服务未运行；请检查 systemctl --user status magpie.service"
    return 1
  fi
  local attempt
  for attempt in {1..10}; do
    if curl --noproxy '*' --silent --output /dev/null --connect-timeout 1 \
        --max-time 1 http://127.0.0.1:3425/ >/dev/null 2>&1; then
      log_info "Magpie 用户服务已运行，默认本机端口 3425 已响应；已启用退出登录后继续运行。"
      return 0
    fi
    sleep 0.5
  done
  log_error "网关端口 3425 未响应；若使用自定义网关地址，请检查 Magpie 服务配置。"
  return 1
}

verify_agents() {
  ((VERIFY_AGENTS)) || return 0
  log_step "验证 Claude/Codex 实际调用（各一次）"
  local directory agent response
  # Installation can use a remote proxy; client calls to the local gateway must not.
  local no_proxy="${no_proxy:+${no_proxy},}127.0.0.1,localhost,::1"
  local NO_PROXY="${NO_PROXY:+${NO_PROXY},}127.0.0.1,localhost,::1"
  export no_proxy NO_PROXY
  directory="$(mktemp -d "${STATE_DIR}/verify.XXXXXX")"
  directory="$(cd "$directory" && pwd)"
  for agent in claude codex; do
    if [[ "$agent" == claude ]]; then
      if ! (cd "$directory" && timeout 120 claude -p \
          'Reply exactly MAGPIE_OK. Do not use tools.' --output-format text --max-turns 1 \
          </dev/null >claude.log 2>claude-error.log); then
        log_error "Claude 调用验证失败或超时；私有日志：$directory"
        return 1
      fi
      response="$(cat "${directory}/claude.log")"
    else
      if ! (cd "$directory" && timeout 120 codex exec --skip-git-repo-check --ephemeral \
          --output-last-message "${directory}/codex-reply" \
          'Reply exactly MAGPIE_OK. Do not use tools.' </dev/null >codex.log 2>&1); then
        log_error "Codex 调用验证失败或超时；私有日志：$directory"
        return 1
      fi
      if [[ ! -f "${directory}/codex-reply" ]]; then
        log_error "Codex 完成但未生成验证结果；私有日志：$directory"
        return 1
      fi
      response="$(cat "${directory}/codex-reply")"
    fi
    if [[ "$response" != MAGPIE_OK ]]; then
      log_error "$agent 未返回预期验证结果；私有日志：$directory"
      return 1
    fi
    log_info "$agent 已返回 MAGPIE_OK"
  done
}

sync_config() {
  if ((SKIP_CONFIG)); then
    log_info "按参数跳过配置同步"
    return
  fi
  local marker="${STATE_DIR}/config-success"
  if ! config_sync_needed; then
    log_info "跳过配置同步：相同来源已成功导入且 Magpie 配置存在（更新远端内容请用 --refresh-config）"
    return
  fi
  rm -f -- "$marker"
  if [[ -n "$BACKUP_FILE" ]]; then restore_backup_config; else configure_webdav; fi
  if [[ ! -s "${MAGPIE_CONFIG_DIR}/providers.json" ]]; then
    log_error "配置命令完成，但未找到非空 Magpie providers.json；不记录成功状态"
    return 1
  fi
  config_command magpie library sync
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
  collect_configuration
  prepare_process_env
  prepare_config
  install -d -m 0700 "$STATE_DIR"
  exec 9>"${STATE_DIR}/install.lock"
  flock -n 9 || { log_error "另一个 Agent 安装正在运行"; return 1; }
  trap cleanup_proxy EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  check_gateway_environment
  preflight_config_source
  install_magpie
  # Magpie must detect installed agents before restoring their model settings.
  install_claude
  install_codex
  sync_config
  start_gateway
  verify_agents
  write_bash_aliases

  log_step "安装完成"
  log_info "请运行 'source ~/.bashrc' 或重新登录以加载 cc/cx alias"
  log_info "使用代理模型时保持 Magpie 网关运行：magpie serve；常驻可用 magpie daemon install"
  if ((VERIFY_AGENTS == 0)); then log_info "本次未验证实际模型调用；可加 --verify 启动网关并验证。"; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
