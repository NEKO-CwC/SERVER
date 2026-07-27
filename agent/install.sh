#!/usr/bin/env bash
set -euo pipefail

# Linux agent installer: cc-switch + WebDAV/SQL config + Claude Code + Codex.

PROXY_URL=""
SQL_FILE=""
WEBDAV_BASE_URL="https://openlist.neko-dashboard.com:8443/dav"
WEBDAV_REMOTE_ROOT="cc-switch-sync"
WEBDAV_PROFILE="default"
WEBDAV_USERNAME="dav"
WEBDAV_PASSWORD="${CC_SWITCH_WEBDAV_PASSWORD:-ercvddDwdFcNaFyCbtX9wt7ARUTQzjLC}"

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
Usage: install.sh [--sql-file FILE]

Options:
  --sql-file FILE  Import cc-switch config from a local SQL file and skip WebDAV.
  -h, --help       Show this help message.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
  for cmd in curl bash sh sed touch; do
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

  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"

  log_info "代理仅在当前安装进程中生效"
}

install_cc_switch() {
  log_step "安装 cc-switch"

  export CC_SWITCH_FORCE=1
  if ! curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash; then
    log_error "cc-switch 安装失败"
    return 1
  fi

  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"
  if ! command -v cc-switch &>/dev/null; then
    log_error "cc-switch 安装后无法找到命令"
    return 1
  fi

  log_info "cc-switch: $(cc-switch --version 2>&1)"
}

configure_webdav() {
  log_step "配置 cc-switch WebDAV"

  log_info "Base URL: $WEBDAV_BASE_URL"
  log_info "Remote Root: $WEBDAV_REMOTE_ROOT"
  log_info "Profile: $WEBDAV_PROFILE"
  log_info "Username: $WEBDAV_USERNAME"

  if ! cc-switch config webdav set \
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

  if ! cc-switch config webdav check-connection; then
    log_error "WebDAV 连接检查失败"
    return 1
  fi

  if ! cc-switch config webdav download; then
    log_error "WebDAV 下载配置失败"
    return 1
  fi
}

import_sql_config() {
  log_step "从 SQL 文件导入 cc-switch 配置"
  log_info "SQL file: $SQL_FILE"

  if ! cc-switch config import "$SQL_FILE"; then
    log_error "SQL 配置导入失败"
    return 1
  fi
}

install_claude() {
  log_step "安装 Claude Code"

  if ! curl -fsSL https://claude.ai/install.sh | bash; then
    log_error "Claude Code 安装失败"
    return 1
  fi

  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"
  if ! command -v claude &>/dev/null; then
    log_error "Claude Code 安装后无法找到 claude 命令"
    return 1
  fi

  log_info "claude: $(claude --version 2>&1)"
}

install_codex() {
  log_step "安装 Codex"

  if ! curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh; then
    log_error "Codex 安装失败"
    return 1
  fi

  export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:$PATH"
  if ! command -v codex &>/dev/null; then
    log_error "Codex 安装后无法找到 codex 命令"
    return 1
  fi

  log_info "codex: $(codex --version 2>&1)"
}

write_bash_aliases() {
  log_step "写入 bash aliases"

  local bashrc="${HOME:-/root}/.bashrc"
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

main() {
  log_step "Linux Agent 安装"

  parse_args "$@"
  check_root
  check_linux
  check_commands
  prepare_process_env
  install_cc_switch
  if [[ -n "$SQL_FILE" ]]; then
    import_sql_config
  else
    configure_webdav
  fi
  install_claude
  install_codex
  write_bash_aliases

  log_step "安装完成"
  log_info "请运行 'source ~/.bashrc' 或重新登录以加载 cc/cx alias"
}

main "$@"
