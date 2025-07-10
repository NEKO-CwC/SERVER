#!/bin/bash

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

# 安装必要的包
log_step "安装必要的包..."
local packages=(
    curl
    wget
    git
    python3
    htop
    nano
    iperf3
    sudo
    docker
    docker-compose
)
apt-get update
apt-get install -y "${packages[@]}"


# 安装 oh-my-bash
log_info "安装 oh-my-bash..."
if [[ ! -d "/root/.oh-my-bash" ]]; then
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended
fi

log_info "必要的包安装完成"

# Docker 启动
log_step "启动 Docker..."
systemctl start docker
systemctl enable docker

