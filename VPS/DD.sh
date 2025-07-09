#!/bin/bash

# =============================================================================
# Debian 自动安装配置脚本
# 功能：自动检测环境、安装最新Debian、配置SSH、安装必要工具
# 作者：基于 bin456789/reinstall 二次封装
# =============================================================================

# set -euo pipefail

# 配置常量
readonly SCRIPT_NAME="${0##*/}"
readonly ROOT_PASSWORD="Zrc_20050905"
SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICiBMtlUZ4+l0NqxpJ/FvNqP5CaQNN3mZeWzoB0PGGFH"
readonly TARGET_REPO="https://github.com/NEKO-CwC/SERVER"
readonly OH_MY_BASH_THEME="developer"

# ANSI 颜色代码
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# =============================================================================
# 工具函数
# =============================================================================

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

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本需要root权限运行，请使用 sudo $0"
    fi
}

# 检查必要命令
check_dependencies() {
    local missing_deps=()
    
    for cmd in curl wget bash; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error_exit "缺少必要依赖: ${missing_deps[*]}"
    fi
}

# =============================================================================
# 网络环境检测
# =============================================================================

# 检测是否在中国网络环境
detect_china_network() {
    log_step "检测网络环境..."
    
    # 方法1: 检测中国特有的CDN服务
    if curl -m 3 --connect-timeout 3 -s "http://www.qualcomm.cn/cdn-cgi/trace" | grep -q "loc=CN" 2>/dev/null; then
        return 0
    fi
    
    # 方法2: 检测百度
    if curl -m 3 --connect-timeout 3 -s "https://www.baidu.com" >/dev/null 2>&1; then
        # 进一步验证延迟
        local baidu_time github_time
        baidu_time=$(curl -o /dev/null -s -w "%{time_total}" -m 3 "https://www.baidu.com" 2>/dev/null || echo "999")
        github_time=$(curl -o /dev/null -s -w "%{time_total}" -m 3 "https://github.com" 2>/dev/null || echo "999")
        
        # 如果百度访问明显更快，认为在中国
        if (( $(echo "$baidu_time < $github_time" | bc -l 2>/dev/null || echo "0") )); then
            return 0
        fi
    fi
    
    return 1
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

# =============================================================================
# 脚本生成器
# =============================================================================

# 生成系统配置脚本
generate_post_install_script() {
    cat << 'EOF'
#!/bin/bash
# =============================================================================
# Debian 系统后配置脚本 (自动生成)
# 此脚本将在新系统首次启动时执行
# =============================================================================

set -euo pipefail

readonly LOG_FILE="/var/log/post-install.log"
readonly LOCK_FILE="/var/lock/post-install.lock"

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$LOG_FILE"
}

# 检查是否已经执行过
if [[ -f "$LOCK_FILE" ]]; then
    log_info "配置已完成，跳过执行"
    exit 0
fi

log_info "开始执行 Debian 系统后配置..."

# 更新系统
log_info "更新软件包列表..."
apt-get update

# 安装基础软件
log_info "安装必要软件包..."
apt-get install -y git curl wget vim htop

# 安装 oh-my-bash
log_info "安装 oh-my-bash..."
if [[ ! -d "/root/.oh-my-bash" ]]; then
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended
    
    # 设置主题
    if [[ -f "/root/.bashrc" ]]; then
        sed -i 's/OSH_THEME=".*"/OSH_THEME="'${OH_MY_BASH_THEME}'"/' /root/.bashrc
        log_info "oh-my-bash 主题设置为: ${OH_MY_BASH_THEME}"
    fi
fi

# 克隆目标仓库
log_info "克隆目标仓库..."
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

████████████████████████████████████████████████████████████████████████████████
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

# 创建完成标记
log_info "创建完成标记..."
touch "$LOCK_FILE"
echo "$(date)" > "$LOCK_FILE"

# 清理自启动脚本
log_info "清理自启动配置..."
systemctl disable post-install-config.service 2>/dev/null || true
rm -f /etc/systemd/system/post-install-config.service
rm -f /usr/local/bin/post-install-config.sh

log_info "系统配置完成！"
EOF
}

# 生成systemd服务文件
generate_systemd_service() {
    cat << 'EOF'
[Unit]
Description=Post Installation Configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/post-install-config.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# =============================================================================
# 主要安装流程
# =============================================================================

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

# 准备配置脚本
prepare_config_scripts() {
    log_step "准备系统配置脚本..."
    
    # 生成配置脚本
    generate_post_install_script > /tmp/post-install-config.sh
    # 替换变量
    sed -i "s/\${OH_MY_BASH_THEME}/$OH_MY_BASH_THEME/g" /tmp/post-install-config.sh
    sed -i "s|\${TARGET_REPO}|$TARGET_REPO|g" /tmp/post-install-config.sh
    
    # 生成systemd服务
    generate_systemd_service > /tmp/post-install-config.service
    
    chmod +x /tmp/post-install-config.sh
    log_info "配置脚本准备完成"
}

# 执行系统安装
install_debian_system() {
    log_step "开始安装 Debian 系统..."
    
    log_info "调用 reinstall.sh 安装 Debian..."
    log_warn "安装过程中系统将重启，请耐心等待..."
    
    # 尝试自动化配置方案
    if attempt_automated_config; then
        log_info "使用自动化配置方案"
        /tmp/reinstall.sh debian \
            --password="$ROOT_PASSWORD" \
            --ssh-key="$SSH_PUBLIC_KEY" || error_exit "Debian 安装失败"
    else
        log_info "使用标准安装，稍后需要手动配置"
        /tmp/reinstall.sh debian \
            --password="$ROOT_PASSWORD" \
            --ssh-key="$SSH_PUBLIC_KEY" || error_exit "Debian 安装失败"
    fi
}

# 尝试自动化配置方案
attempt_automated_config() {
    log_step "检查自动化配置可行性..."
    
    # 创建配置脚本的压缩版本
    local config_url
    if config_url=$(upload_config_script); then
        log_info "配置脚本已上传，URL: $config_url"
        
        # 创建包含自动配置命令的SSH密钥
        local auto_ssh_key
        auto_ssh_key="command=\"bash -c 'wget -qO- $config_url | bash || curl -fsSL $config_url | bash; exec \\\$SSH_ORIGINAL_COMMAND'\" $SSH_PUBLIC_KEY"
        
        # 临时替换SSH密钥变量
        SSH_PUBLIC_KEY="$auto_ssh_key"
        return 0
    else
        log_warn "无法上传配置脚本，将使用手动配置方案"
        return 1
    fi
}

# 上传配置脚本到在线服务
upload_config_script() {
    log_info "尝试上传配置脚本到在线服务..."
    
    # 方法1: 使用 transfer.sh (24小时有效)
    if command -v curl >/dev/null 2>&1; then
        local upload_url
        if upload_url=$(curl --upload-file /tmp/post-install-config.sh https://transfer.sh/post-install-config.sh 2>/dev/null); then
            echo "$upload_url"
            return 0
        fi
    fi
    
    # 方法2: 使用 0x0.st (永久有效，但可能被删除)
    if upload_url=$(curl -F'file=@/tmp/post-install-config.sh' https://0x0.st 2>/dev/null); then
        echo "$upload_url"
        return 0
    fi
    
    # 方法3: 使用 catbox.moe (永久有效)
    if upload_url=$(curl -F'reqtype=fileupload' -F'fileToUpload=@/tmp/post-install-config.sh' https://catbox.moe/user/api.php 2>/dev/null); then
        echo "https://files.catbox.moe/$upload_url"
        return 0
    fi
    
    return 1
}

# 创建在线配置脚本服务
create_online_config_service() {
    log_step "创建在线配置脚本..."
    
    # 将配置脚本编码为base64以便传输
    local config_script_b64
    config_script_b64=$(base64 -w 0 /tmp/post-install-config.sh)
    
    # 创建一个简单的获取脚本，将在新系统中执行
    local fetch_script=$(cat << 'FETCH_EOF'
#!/bin/bash
# 自动配置获取和执行脚本

set -euo pipefail

CONFIG_URL="https://transfer.sh/get/CONFIG_ID/post-install.sh"
CONFIG_B64="CONFIG_SCRIPT_B64"
SCRIPT_PATH="/usr/local/bin/post-install-config.sh"

echo "[$(date)] 开始自动配置..."

# 方法1: 从base64直接解码（最可靠）
if echo "$CONFIG_B64" | base64 -d > "$SCRIPT_PATH" 2>/dev/null; then
    echo "[$(date)] 配置脚本已从内嵌数据加载"
    chmod +x "$SCRIPT_PATH"
    "$SCRIPT_PATH" 2>&1 | tee -a /var/log/auto-config.log
    rm -f "$SCRIPT_PATH"
    echo "[$(date)] 自动配置完成"
else
    echo "[$(date)] 配置脚本加载失败，请手动运行配置"
fi

# 清理自身
rm -f /etc/systemd/system/auto-config.service
rm -f "$0"
FETCH_EOF
    )
    
    # 替换占位符
    fetch_script=${fetch_script//CONFIG_SCRIPT_B64/$config_script_b64}
    
    echo "$fetch_script" > /tmp/fetch-config.sh
    chmod +x /tmp/fetch-config.sh
    
    log_info "在线配置脚本已准备完成"
}

# 注入自动配置机制
inject_auto_config() {
    log_step "配置自动化配置机制..."
    
    # 创建一个修改后的SSH密钥，包含自动配置命令
    local modified_ssh_key
    modified_ssh_key="command=\"bash -c 'if [ ! -f /var/lib/auto-configured ]; then curl -fsSL https://bit.ly/debian-auto-config | bash; touch /var/lib/auto-configured; fi; exec \\\$SSH_ORIGINAL_COMMAND'\" $SSH_PUBLIC_KEY"
    
    # 将获取脚本编码，准备注入
    local fetch_script_b64
    fetch_script_b64=$(base64 -w 0 /tmp/fetch-config.sh)
    
    # 创建 cloud-init 用户数据（如果支持）
    cat > /tmp/user-data.yaml << EOF
#cloud-config
runcmd:
  - echo '$fetch_script_b64' | base64 -d > /tmp/auto-config.sh
  - chmod +x /tmp/auto-config.sh
  - /tmp/auto-config.sh
  - rm -f /tmp/auto-config.sh
EOF
    
    log_info "自动配置机制已准备完成"
    log_warn "由于 reinstall.sh 的限制，将使用简化的自动配置方案"
}

# 显示完成信息
show_completion_info() {
    log_step "安装配置完成！"
    
    # 检查是否使用了自动化配置
    if [[ "$SSH_PUBLIC_KEY" =~ ^command= ]]; then
        cat << EOF

${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${GREEN}                        🚀 自动化安装完成 🚀                              ${NC}
${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

📋 ${BLUE}系统信息${NC}
   • 操作系统: Debian 12 (最新版)
   • Root密码: $ROOT_PASSWORD
   • SSH公钥: 已配置 (含自动配置功能)

🤖 ${BLUE}自动化配置${NC}
   • ✅ 自动配置已启用
   • 🔄 首次SSH登录时将自动执行配置
   • 📦 将自动安装: Git, Oh-My-Bash, 目标仓库
   • 🎨 将自动配置: MOTD, Bash主题 (developer)

⚡ ${BLUE}使用说明${NC}
   1. 等待系统完成重启
   2. 使用SSH密钥连接服务器
   3. 系统将自动开始配置过程
   4. 配置完成后重新登录查看效果

📝 ${BLUE}注意事项${NC}
   • 首次登录可能需要等待几分钟完成配置
   • 配置过程中请勿中断连接
   • 配置完成后会看到自定义的MOTD界面

${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

EOF
    else
        # 手动配置方案
        local config_b64
        config_b64=$(base64 -w 0 /tmp/post-install-config.sh)
        
        cat << EOF

${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${GREEN}                        📋 手动配置方案 📋                                ${NC}
${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

📋 ${BLUE}系统信息${NC}
   • 操作系统: Debian 12 (最新版)
   • Root密码: $ROOT_PASSWORD
   • SSH公钥: 已配置

🔧 ${BLUE}完成配置的方法${NC}
   ${YELLOW}方法1: 一键配置命令${NC}
   登录新系统后执行：
   ${BLUE}echo '$config_b64' | base64 -d | bash${NC}

   ${YELLOW}方法2: 分步手动配置${NC}
   1. 更新系统: apt update && apt upgrade -y
   2. 安装基础软件: apt install -y git curl vim htop
   3. 安装 Oh-My-Bash: curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh | bash
   4. 克隆仓库: git clone $TARGET_REPO
   5. 设置主题: 编辑 ~/.bashrc 设置 OSH_THEME="$OH_MY_BASH_THEME"
   6. 配置MOTD: 编辑 /etc/motd 添加自定义欢迎界面

📝 ${BLUE}注意事项${NC}
   • 推荐使用方法1，最简单可靠
   • 配置完成后重新登录查看效果
   • 所有配置都会保存在 /var/log/post-install.log

${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

EOF
    fi
}

# =============================================================================
# 主函数
# =============================================================================

main() {
  
    log_info "开始执行 Debian 自动安装配置脚本"
    
    # 前置检查
    check_root
    check_dependencies
    
    # 执行安装流程
    download_reinstall_script
    prepare_config_scripts
    
    # 安装系统
    install_debian_system
    
    # 显示完成信息
    show_completion_info
    
    log_info "主脚本执行完成，系统正在重启..."
    log_info "请等待系统重启完成后使用SSH连接"
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi