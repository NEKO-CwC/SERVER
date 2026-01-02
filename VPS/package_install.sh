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
    )
    apt-get update
    apt-get install -y "${packages[@]}"

    # 安装 Docker
    log_step "安装 Docker..."
    apt remove $(dpkg --get-selections docker.io docker-compose docker-doc podman-docker containerd runc | cut -f1)
    # Add Docker's official GPG key:
    sudo apt update
    sudo apt install ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt update
    sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

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

