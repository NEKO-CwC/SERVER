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
    if [[ $EUID -ne 0 ]]; then
        error_exit "必须使用 root 权限运行"
    fi

    # 安装必要的包
    log_step "安装必要的包..."
    local packages=(
        ca-certificates
        curl
        wget
        git
        python3
        htop
        nano
        iperf3
    )
    apt-get update
    apt-get install -y "${packages[@]}"

    # 安装 Docker
    log_step "安装 Docker..."
    apt-get remove -y docker docker-engine docker.io docker-compose docker-doc podman-docker containerd runc 2>/dev/null || true
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log_info "必要的包安装完成"

    # Docker 启动
    log_step "启动 Docker..."
    systemctl enable --now docker
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

