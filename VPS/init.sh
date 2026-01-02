#!/bin/bash

readonly TARGET_REPO="https://github.com/NEKO-CwC/SERVER"
readonly OH_MY_BASH_THEME="developer"

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

# 设置 oh-my-bash 主题
if [[ -f "/root/.bashrc" ]]; then
    sed -i 's/OSH_THEME=".*"/OSH_THEME="'${OH_MY_BASH_THEME}'"/' /root/.bashrc
    log_info "oh-my-bash 主题设置为: ${OH_MY_BASH_THEME}"
fi

# 克隆目标仓库
log_info "克隆仓库..."
cd /root
if [[ ! -d "SERVER" ]]; then
    git clone "${TARGET_REPO}" || log_error "仓库克隆失败"
else
    log_info "仓库已存在，更新..."
    cd SERVER && git pull || log_error "仓库更新失败"
fi

# 设置自定义 MOTD
log_info "配置 MOTD (Message of the Day)..."
cat > /etc/motd << 'MOTD_EOF'

███████████████████████████████████████████████████████████████████████████████
██                                                                           ██
██                              ...:::..                                     ██
██                       ....       . ..                                     ██
██                    ..    .        ..                                      ██
██                  ...            .                                         ██
██                  . ..   .   ...                                           ██
██                   ..........                                              ██
██                          . . ...                                          ██
██                       .....      .:..                                     ██
██                    ...    :     :.:-:..                                   ██
██                  ..      ..   ..     :-:       ..                         ██
██                .             ..       .--    =-:-=.                       ██
██              ..             ..          :- .+     ..                      ██
██           .::..  .         .             :-+        :                     ██
██       ....    .  .        . .....::::-:   ::         :                    ██
██     ..        : .         ..          .:--::          :                   ██
██  ..           .                          =--.         ..                  ██
██ ..............                           +.            :                  ██
██  -.. ..     :-.                          +             .:                 ██
██  .: .     .-.                            +              -                 ██
██   ...     =   .                          =.             -                 ██
██    ..    -.  .                           --             -                 ██
██     ..   -                               .*             -                 ██
██      .. :.                                -=            :                 ██
██        .:.                                 +:           :                 ██
██         ..                                 .=:          -                 ██
██          ..                                 .=:        :.                 ██
██          ..                          -.      .--.     ..                  ██
██          .:.                       :=:         :==.   :                   ██
██           .:                  .==--:             -*+==.                   ██
██            .:    :---.                             :#.                    ██
██             ..                                   ..=.                     ██
██               .                                 ..=-=.                    ██
██                                                :-:   =.                   ██
██                  .                    .     .-:.      =++++++=-::..       ██
██                   ::..          .   ..... :--.      .. :                  ██
██                .--.   .... .......:--::.--.      .:     .                 ██
██              .--.::------::::::::..     ==-    .        .                 ██
██             .=.  .    ..:..    .:      :.=::   .       .-.                ██
██             -  .-:.. ::::.: :..=:.:    -.=.:.         :...                ██
██            :.  :-:-  ..:.  :: :. -     -.-..-.       -. .                 ██
██            -   .::   ::::  .::=..     .: -.. -     .-                     ██
██           -   ...:.. .-.     =.       -  :....=   .-                      ██
██          ::           ...    .        -  .:. .-- ..                       ██
██          -..........            :-:  .:   ::-::-.                         ██
██                 .::-------====-------:::.:==-::                           ██
██             ...:::-::::::::::::--==+++=====--:                            ██
██                ......:::::------==+====----=-                             ██
██                        ....::----:...:::-=+=.                             ██
██                                     .......                               ██
███████████████████████████████████████████████████████████████████████████████

MOTD_EOF

# Docker 启动 singbox substore 镜像
log_info "启动 singbox 镜像..."

cd /root
mkdir -p /root/.singbox
cd /root/.singbox
touch docker-compose.yml
cat >> docker-compose.yml << EOF
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: sing-box
    restart: always
    volumes:
      - ./config:/etc/sing-box
    command: -D /var/lib/sing-box -C /etc/sing-box/ run
    network_mode: host
EOF
docker-compose up 

log_info "启动 substore 容器..."
cd /root
mkdir -p /root/.substore
cd .substore
docker run -it -d --restart=always -e "SUB_STORE_CRON=0 0 * * *" -e SUB_STORE_FRONTEND_BACKEND_PATH=/sub -p 3001:3001 -v /root/.substore:/opt/app/data --name sub-store xream/sub-store