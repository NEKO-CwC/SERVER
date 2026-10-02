#!/usr/bin/env bash
set -euo pipefail

readonly TARGET_REPO="https://github.com/NEKO-CwC/SERVER"

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

# 克隆目标仓库
log_info "克隆仓库..."
cd /root
if [[ ! -d "SERVER" ]]; then
    git clone "${TARGET_REPO}"
else
    log_info "仓库已存在，更新..."
    cd SERVER
    git pull --ff-only
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


log_info "基础初始化完成。请按需运行 VPS/singbox/client/install.sh 或 VPS/singbox/server/install.sh。"
