#!/bin/bash

# Ensure util.sh is available
if [ ! -f "util.sh" ]; then
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://raw.githubusercontent.com/NEKO-CwC/SERVER/main/VPS/util.sh -o util.sh
    elif command -v wget >/dev/null 2>&1; then
        wget -q https://raw.githubusercontent.com/NEKO-CwC/SERVER/main/VPS/util.sh -O util.sh
    fi
fi

# Source util.sh
if [ -f "util.sh" ]; then
    source ./util.sh
elif [ -f "$(dirname "$0")/util.sh" ]; then
    source "$(dirname "$0")/util.sh"
else
    echo "Error: util.sh not found and could not be downloaded." >&2
    exit 1
fi

main() {
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
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

