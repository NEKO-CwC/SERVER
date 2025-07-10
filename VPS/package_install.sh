#!/bin/bash

# 安装必要的包
install_packages() {
    log_step "安装必要的包..."
    local packages=(
        curl
        wget
        git
        python
        htop
        nano
        iperf3
        sudo
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )
    apt-get update
    apt-get install -y "${packages[@]}"


    # 安装 oh-my-bash
    log_info "安装 oh-my-bash..."
    if [[ ! -d "/root/.oh-my-bash" ]]; then
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended
    fi

    log_info "必要的包安装完成"
}

# Docker 启动
docker_run() {
    log_step "启动 Docker..."
    systemctl start docker
    systemctl enable docker
}
