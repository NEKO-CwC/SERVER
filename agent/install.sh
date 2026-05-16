#!/usr/bin/env bash
set -euo pipefail

# Linux Claude Code Agent 一键安装脚本
# 安装 cc-switch + WebDAV 配置 + Claude Code + cc launcher

# ============================================================
# 常量
# ============================================================

PROXY_URL="http://la-new.284072.xyz:20081"
WEBDAV_BASE_URL="https://openlist.neko-dashboard.com:8443/dav"
WEBDAV_REMOTE_ROOT="cc-switch-sync"
WEBDAV_PROFILE="default"
WEBDAV_USERNAME="dav"
WEBDAV_PASSWORD="${CC_SWITCH_WEBDAV_PASSWORD:-ercvddDwdFcNaFyCbtX9wt7ARUTQzjLC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 已创建的文件列表，用于回滚
CREATED_FILES=()
BACKED_UP_FILES=()

# ============================================================
# 日志
# ============================================================

log_step() {
  printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"
}

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
}

log_ok() {
  printf '\033[1;32m[OK] %s\033[0m\n' "$*"
}

# ============================================================
# 回滚
# ============================================================

register_created() {
  CREATED_FILES+=("$1")
}

register_backup() {
  BACKED_UP_FILES+=("$1:$2")  # original:backup
}

run_rollbacks() {
  log_warn "执行回滚..."

  # 删除本脚本创建的文件
  for f in "${CREATED_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      log_info "已删除: $f"
    fi
  done

  # 恢复备份文件
  for entry in "${BACKED_UP_FILES[@]}"; do
    local original="${entry%:*}"
    local backup="${entry##*:}"
    if [[ -f "$backup" ]]; then
      mv "$backup" "$original"
      log_info "已恢复: $original"
    fi
  done
}

on_error() {
  local lineno="$1"
  log_error "安装脚本在第 ${lineno} 行出错"
  run_rollbacks
  exit 1
}

# ============================================================
# 安全写文件（备份已有、登记回滚）
# ============================================================

# 写入 /etc/profile.d/ 下的文件
# 如果文件已存在且非本脚本创建，先备份
write_profile_d() {
  local filepath="$1"
  local content="$2"
  local desc="$3"

  if [[ -f "$filepath" ]]; then
    local backup="${filepath}.bak.$(date +%s)"
    cp "$filepath" "$backup"
    register_backup "$filepath" "$backup"
    log_warn "已备份已有文件: $filepath -> $backup"
  fi

  printf '%s\n' "$content" > "$filepath"
  register_created "$filepath"
  log_ok "$desc 已写入 $filepath"
}

# ============================================================
# 前置检查
# ============================================================

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
  for cmd in curl bash chmod install; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "缺少必要命令: ${missing[*]}"
    exit 1
  fi
}

# ============================================================
# Phase 1: 骨架、日志、平台检测
# ============================================================

phase_1_checks() {
  log_step "Phase 1: 前置检查"
  check_root
  check_linux
  check_commands
  log_ok "前置检查通过"
}

# ============================================================
# Phase 2: 代理环境变量 + PATH 持久化
# ============================================================

phase_2_proxy_path() {
  log_step "Phase 2: 代理环境变量与 PATH 持久化"

  local proxy_content
  proxy_content="# Added by cc-agent install.sh
export http_proxy=\"${PROXY_URL}\"
export https_proxy=\"${PROXY_URL}\"
export HTTP_PROXY=\"${PROXY_URL}\"
export HTTPS_PROXY=\"${PROXY_URL}\""

  write_profile_d "/etc/profile.d/cc-agent-proxy.sh" "$proxy_content" "代理环境变量"

  # 立即生效
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"

  local path_content
  path_content="# Added by cc-agent install.sh
export PATH=\"/root/.local/bin:\$PATH\""

  write_profile_d "/etc/profile.d/cc-switch-path.sh" "$path_content" "PATH 持久化"

  # 立即生效
  export PATH="/root/.local/bin:$PATH"

  log_ok "代理和 PATH 配置完成"
}

# ============================================================
# Phase 3: 安装 cc-switch
# ============================================================

phase_3_cc_switch() {
  log_step "Phase 3: 安装 cc-switch"

  export CC_SWITCH_FORCE=1

  log_info "正在下载并安装 cc-switch..."
  if ! curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash; then
    log_error "cc-switch 安装失败"
    return 1
  fi

  # 验证安装
  if ! command -v cc-switch &>/dev/null; then
    log_error "cc-switch 安装后无法找到命令"
    return 1
  fi

  local version
  version="$(cc-switch --version 2>&1)" || true
  log_ok "cc-switch 安装成功: $version"
}

# ============================================================
# Phase 4: WebDAV 配置
# ============================================================

phase_4_webdav() {
  log_step "Phase 4: WebDAV 配置"

  log_info "配置 WebDAV 连接..."
  log_info "  Base URL: $WEBDAV_BASE_URL"
  log_info "  Remote Root: $WEBDAV_REMOTE_ROOT"
  log_info "  Profile: $WEBDAV_PROFILE"
  log_info "  Username: $WEBDAV_USERNAME"

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

  log_info "检查 WebDAV 连接..."
  if ! cc-switch config webdav check-connection; then
    log_error "WebDAV 连接检查失败"
    return 1
  fi

  log_info "下载远端配置..."
  if ! cc-switch config webdav download; then
    log_error "WebDAV 下载配置失败"
    return 1
  fi

  log_ok "WebDAV 配置完成并已下载远端配置"
}

# ============================================================
# Phase 5: 安装 Claude Code
# ============================================================

phase_5_claude() {
  log_step "Phase 5: 安装 Claude Code"

  log_info "正在下载并安装 Claude Code..."
  if ! curl -fsSL https://claude.ai/install.sh | bash; then
    log_error "Claude Code 安装失败"
    return 1
  fi

  # 确保 claude 在 PATH 中
  if ! command -v claude &>/dev/null; then
    local candidates=(
      "/root/.local/bin/claude"
      "/usr/local/bin/claude"
      "/usr/bin/claude"
    )
    local found=""
    for candidate in "${candidates[@]}"; do
      if [[ -x "$candidate" ]]; then
        found="$candidate"
        break
      fi
    done

    if [[ -z "$found" ]]; then
      log_error "Claude Code 安装后找不到可执行文件"
      return 1
    fi

    # 如果在 /root/.local/bin/，创建 symlink 到 /usr/local/bin/
    if [[ "$found" == "/root/.local/bin/claude" && ! -x "/usr/local/bin/claude" ]]; then
      ln -sf "$found" /usr/local/bin/claude
      log_info "已创建 symlink: /usr/local/bin/claude -> $found"
    fi
  fi

  local version
  version="$(claude --version 2>&1)" || true
  log_ok "Claude Code 安装成功: $version"
}

# ============================================================
# Phase 6: 创建 /usr/local/bin/cc 和 cc alias
# ============================================================

phase_6_cc_launcher() {
  log_step "Phase 6: 创建 cc 启动器"

  # 6a. cc alias
  local alias_content
  alias_content="# Added by cc-agent install.sh
alias cc='IS_SANDBOX=true claude --dangerously-skip-permissions'"

  write_profile_d "/etc/profile.d/cc-alias.sh" "$alias_content" "cc alias"

  # 6b. /usr/local/bin/cc
  local cc_target="/usr/local/bin/cc"
  if [[ -f "$cc_target" ]]; then
    local backup="${cc_target}.bak.$(date +%s)"
    cp "$cc_target" "$backup"
    register_backup "$cc_target" "$backup"
    log_warn "已备份已有文件: $cc_target -> $backup"
  fi

  if [[ ! -f "$SCRIPT_DIR/cc.sh" ]]; then
    log_error "找不到 cc.sh 模板文件: $SCRIPT_DIR/cc.sh"
    return 1
  fi

  install -m 0755 "$SCRIPT_DIR/cc.sh" "$cc_target"
  register_created "$cc_target"
  log_ok "cc 启动器已安装到 $cc_target"
}

# ============================================================
# 主流程
# ============================================================

main() {
  trap 'on_error $LINENO' ERR

  log_step "Claude Code Agent 一键安装"
  log_info "安装目录: $SCRIPT_DIR"

  phase_1_checks
  phase_2_proxy_path
  phase_3_cc_switch
  phase_4_webdav
  phase_5_claude
  phase_6_cc_launcher

  log_step "安装完成"
  log_ok "所有组件安装成功"
  log_info "请运行 'source /etc/profile.d/cc-agent-proxy.sh' 或重新登录以使环境变量生效"
  log_info "使用 'cc' 命令启动 Claude Code"
}

main "$@"
