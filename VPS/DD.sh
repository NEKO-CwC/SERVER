#!/bin/bash

readonly ROOT_PASSWORD="Zrc_20050905"
readonly SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICiBMtlUZ4+l0NqxpJ/FvNqP5CaQNN3mZeWzoB0PGGFH"

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1" >&2
}

error_exit() {
    log_error "$1"
    exit 1
}


# 获取reinstall.sh下载链接
get_reinstall_url() {
    if detect_china_network; then
        log_info "检测到中国网络环境，使用国内源"
        # 使用GitHub加速服务作为备选
        echo "https://ghproxy.com/https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
    else
        log_info "检测到国外网络环境，使用官方源"
        echo "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
    fi
}

# 下载reinstall.sh
download_reinstall_script() {
    local url
    url=$(get_reinstall_url)
    
    log_step "下载 reinstall.sh 脚本..."
    log_info "下载地址: $url"
    
    if ! curl -fsSL "$url" -o /tmp/reinstall.sh; then
        error_exit "下载 reinstall.sh 失败"
    fi
    
    chmod +x /tmp/reinstall.sh
    log_info "reinstall.sh 下载完成"
}

# 执行系统安装
install_debian_system() {
    log_step "开始安装 Debian 系统..."
    
    log_info "调用 reinstall.sh 安装 Debian..."
    log_warn "安装过程中系统将重启，请耐心等待..."
    
    /tmp/reinstall.sh debian \
        --password="$ROOT_PASSWORD" \
        --ssh-key="$SSH_PUBLIC_KEY" || error_exit "Debian 安装失败"
}



main() {
    download_reinstall_script

    # 安装系统
    install_debian_system
    
    log_info "Debian 系统前置条件配置完毕，在 5 秒后将进行重启..."
    log_info "请在重启后执行一键初始化脚本"
    log_info "国外：curl https://raw.githubusercontent.com/NEKO-CwC/SERVER/refs/heads/main/VPS/ONE_STEP_INIT.sh -o ONE_STEP_INIT.sh && bash ONE_STEP_INIT.sh && rm -f ONE_STEP_INIT.sh"
    log_info "国内：curl https://ghproxy.com/https://raw.githubusercontent.com/NEKO-CwC/SERVER/refs/heads/main/VPS/ONE_STEP_INIT.sh -o ONE_STEP_INIT.sh && bash ONE_STEP_INIT.sh && rm -f ONE_STEP_INIT.sh"
    sleep 5
    reboot
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi