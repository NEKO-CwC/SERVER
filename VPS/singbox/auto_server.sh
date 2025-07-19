#!/bin/bash

# Sing-box 服务端一键部署脚本
# 专用于服务器端部署，包含证书申请、配置生成、服务启动

# set -e

DOMAIN="284072.xyz"
PROJECT_DIR="/root/singbox-proxy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_success() { echo -e "${PURPLE}[SUCCESS]${NC} $1"; }

show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════╗
║           Sing-box 服务端自动部署                ║
║     支持多协议代理服务器一键安装配置             ║
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_environment() {
    log_step "检查服务器环境..."
    
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        
    fi
    
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法识别的操作系统"
        
    fi
    
    source /etc/os-release
    log_info "操作系统: $PRETTY_NAME"
    
    # 检查网络连接
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        log_warn "网络连接可能存在问题"
    fi
    
    # 检查域名解析
    if ! nslookup ${DOMAIN} >/dev/null 2>&1; then
        log_warn "域名 ${DOMAIN} 解析可能存在问题"
        echo -n "是否继续部署? (y/N): "
        read continue_deploy
        if [[ "$continue_deploy" != "y" ]] && [[ "$continue_deploy" != "Y" ]]; then
            log_info "部署已取消"
            
        fi
    fi
}

install_dependencies() {
    log_step "安装必要依赖..."
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y curl socat cron docker.io docker-compose openssl uuidgen net-tools
        systemctl enable docker
        systemctl start docker
    elif command -v yum >/dev/null 2>&1; then
        yum update -y
        yum install -y curl socat cronie docker docker-compose openssl util-linux net-tools
        systemctl enable docker
        systemctl start docker
        systemctl enable crond
        systemctl start crond
    elif command -v dnf >/dev/null 2>&1; then
        dnf update -y
        dnf install -y curl socat cronie docker docker-compose openssl util-linux net-tools
        systemctl enable docker
        systemctl start docker
    else
        log_error "不支持的操作系统包管理器"
        
    fi
    
    # 验证Docker安装
    if ! docker --version >/dev/null 2>&1; then
        log_error "Docker 安装失败"
        
    fi
    
    log_success "依赖安装完成"
}

setup_project_structure() {
    log_step "创建项目目录结构..."
    
    mkdir -p ${PROJECT_DIR}/{config,logs,backup,scripts}
    cd ${PROJECT_DIR}
    
    log_info "项目目录: ${PROJECT_DIR}"
}

generate_server_configs() {
    log_step "生成服务端配置文件..."
    
    local PASSWORD="$(openssl rand -base64 24)"
    local CERT_PATH="/opt/ssl/${DOMAIN}/fullchain.pem"
    local KEY_PATH="/opt/ssl/${DOMAIN}/private.key"
    
    echo "${PASSWORD}" > ${PROJECT_DIR}/config/password.txt
    
    # 1. Hysteria2 配置
    local HYSTERIA2_UUID=$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    cat > ${PROJECT_DIR}/config/hysteria2.json << EOF
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "inbounds": [{
    "type": "hysteria2",
    "listen": "::",
    "listen_port": 36712,
    "up_mbps": 1000,
    "down_mbps": 1000,
    "users": [{"name": "user", "password": "${PASSWORD}"}],
    "tls": {
      "enabled": true,
      "server_name": "${DOMAIN}",
      "key_path": "${KEY_PATH}",
      "certificate_path": "${CERT_PATH}"
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
    
    # 2. VLESS 配置
    local VLESS_UUID=$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    cat > ${PROJECT_DIR}/config/vless.json << EOF
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": 8443,
    "users": [{"name": "user", "uuid": "${VLESS_UUID}"}],
    "tls": {
      "enabled": true,
      "server_name": "${DOMAIN}",
      "key_path": "${KEY_PATH}",
      "certificate_path": "${CERT_PATH}"
    },
    "transport": {
      "type": "ws",
      "path": "/vless",
      "early_data_header_name": "Sec-WebSocket-Protocol"
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
    
    # 3. VMess 配置
    local VMESS_UUID=$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    cat > ${PROJECT_DIR}/config/vmess.json << EOF
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "inbounds": [{
    "type": "vmess",
    "listen": "::",
    "listen_port": 8444,
    "users": [{"name": "user", "uuid": "${VMESS_UUID}", "alterId": 0}],
    "tls": {
      "enabled": true,
      "server_name": "${DOMAIN}",
      "key_path": "${KEY_PATH}",
      "certificate_path": "${CERT_PATH}"
    },
    "transport": {"type": "ws", "path": "/vmess"}
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
    
    # 4. Shadowsocks 配置
    cat > ${PROJECT_DIR}/config/shadowsocks.json << EOF
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "inbounds": [{
    "type": "shadowsocks",
    "listen": "::",
    "listen_port": 8388,
    "method": "chacha20-ietf-poly1305",
    "password": "${PASSWORD}",
    "multiplex": {"enabled": true, "padding": true}
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
    
    # 5. TUIC 配置
    local TUIC_UUID=$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    cat > ${PROJECT_DIR}/config/tuic.json << EOF
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "inbounds": [{
    "type": "tuic",
    "listen": "::",
    "listen_port": 8445,
    "users": [{"name": "user", "uuid": "${TUIC_UUID}", "password": "${PASSWORD}"}],
    "tls": {
      "enabled": true,
      "server_name": "${DOMAIN}",
      "key_path": "${KEY_PATH}",
      "certificate_path": "${CERT_PATH}"
    },
    "congestion_control": "bbr"
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
    
    # 6. Trojan 配置
    cat > ${PROJECT_DIR}/config/trojan.json << EOF
{
  "log": {"disabled": false, "level": "warn", "timestamp": true},
  "inbounds": [{
    "type": "trojan",
    "listen": "::",
    "listen_port": 8446,
    "users": [{"name": "user", "password": "${PASSWORD}"}],
    "tls": {
      "enabled": true,
      "server_name": "${DOMAIN}",
      "key_path": "${KEY_PATH}",
      "certificate_path": "${CERT_PATH}"
    },
    "fallback": {"server": "127.0.0.1", "server_port": 80}
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
    
    # 保存配置信息
    cat > ${PROJECT_DIR}/config/server_info.json << EOF
{
  "domain": "${DOMAIN}",
  "cert_path": "${CERT_PATH}",
  "key_path": "${KEY_PATH}",
  "password": "${PASSWORD}",
  "configs": {
    "hysteria2": {"port": 36712, "protocol": "hysteria2"},
    "vless": {"port": 8443, "protocol": "vless", "transport": "ws", "path": "/vless", "uuid": "${VLESS_UUID}"},
    "vmess": {"port": 8444, "protocol": "vmess", "transport": "ws", "path": "/vmess", "uuid": "${VMESS_UUID}"},
    "shadowsocks": {"port": 8388, "protocol": "shadowsocks", "method": "chacha20-ietf-poly1305"},
    "tuic": {"port": 8445, "protocol": "tuic", "uuid": "${TUIC_UUID}"},
    "trojan": {"port": 8446, "protocol": "trojan"}
  },
  "generated_at": "$(date -Iseconds)"
}
EOF
    
    log_success "服务端配置生成完成"
    log_info "密码: ${PASSWORD}"
    log_info "VLESS UUID: ${VLESS_UUID}"
    log_info "VMess UUID: ${VMESS_UUID}"
    log_info "TUIC UUID: ${TUIC_UUID}"
}

create_docker_compose() {
    log_step "创建Docker Compose配置..."
    
    cat > ${PROJECT_DIR}/docker-compose.yml << 'EOF'
version: '3.8'

services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: sing-box-server
    restart: always
    volumes:
      - ./config/config.json:/etc/sing-box/config.json
      - /opt/ssl:/opt/ssl:ro
    command: -D /var/lib/sing-box -C /etc/sing-box/ run
    network_mode: host
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

create_management_scripts() {
    log_step "创建服务管理脚本..."
    
    # 启动脚本
    cat > ${PROJECT_DIR}/start_server.sh << 'EOF'
#!/bin/bash

CONFIG_FILE="${1:-hysteria2.json}"
CONFIG_DIR="./config"
PROJECT_DIR="/opt/singbox-proxy"

cd ${PROJECT_DIR}

if [ ! -f "${CONFIG_DIR}/${CONFIG_FILE}" ]; then
    echo "错误: 配置文件 ${CONFIG_DIR}/${CONFIG_FILE} 不存在"
    echo "可用配置:"
    ls ${CONFIG_DIR}/*.json 2>/dev/null | grep -v server_info.json | xargs -n1 basename
    
fi

echo "启动服务端，使用配置: ${CONFIG_FILE}"

# 停止现有容器
docker-compose down 2>/dev/null || true

# 复制指定配置
cp "${CONFIG_DIR}/${CONFIG_FILE}" "${CONFIG_DIR}/config.json"

# 启动服务
docker-compose up -d

echo "服务启动完成"
echo "查看日志: docker-compose logs -f"

# 显示端口信息
protocol=$(echo ${CONFIG_FILE} | cut -d'.' -f1)
case ${protocol} in
    "hysteria2") echo "监听端口: 36712 (UDP)" ;;
    "vless") echo "监听端口: 8443 (TCP)" ;;
    "vmess") echo "监听端口: 8444 (TCP)" ;;
    "shadowsocks") echo "监听端口: 8388 (TCP)" ;;
    "tuic") echo "监听端口: 8445 (UDP)" ;;
    "trojan") echo "监听端口: 8446 (TCP)" ;;
esac
EOF
    
    # 管理脚本
    cat > ${PROJECT_DIR}/manage_server.sh << 'EOF'
#!/bin/bash

PROJECT_DIR="/opt/singbox-proxy"
cd ${PROJECT_DIR}

case "${1:-}" in
    "start")
        shift
        bash ./start_server.sh $@
        ;;
    "stop")
        docker-compose down
        echo "服务已停止"
        ;;
    "restart")
        docker-compose restart
        echo "服务已重启"
        ;;
    "status")
        docker-compose ps
        echo ""
        echo "端口监听状态:"
        netstat -tulnp | grep -E "(36712|8443|8444|8388|8445|8446)"
        ;;
    "logs")
        docker-compose logs -f --tail=100
        ;;
    "switch")
        echo "可用配置:"
        configs=($(ls config/*.json | grep -v server_info.json | xargs -n1 basename))
        for i in "${!configs[@]}"; do
            echo "$((i+1)). ${configs[$i]}"
        done
        echo -n "选择配置 (1-${#configs[@]}): "
        read choice
        if [ "$choice" -gt 0 ] && [ "$choice" -le "${#configs[@]}" ]; then
            bash ./start_server.sh "${configs[$((choice-1))]}"
        fi
        ;;
    "info")
        if [ -f "config/server_info.json" ]; then
            echo "服务器信息:"
            cat config/server_info.json | jq '.' 2>/dev/null || cat config/server_info.json
        fi
        ;;
    "backup")
        backup_file="backup/server-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf "$backup_file" config/
        echo "配置已备份到: $backup_file"
        ;;
    *)
        echo "Sing-box 服务端管理"
        echo "用法: $0 {start [config]|stop|restart|status|logs|switch|info|backup}"
        echo ""
        echo "示例:"
        echo "  $0 start hysteria2.json  # 启动指定协议"
        echo "  $0 switch                # 交互式切换协议"
        echo "  $0 status                # 查看运行状态"
        
        ;;
esac
EOF
    
    chmod +x ${PROJECT_DIR}/start_server.sh
    chmod +x ${PROJECT_DIR}/manage_server.sh
    
#     # 创建系统服务
#     cat > /etc/systemd/system/singbox-server.service << EOF
# [Unit]
# Description=Sing-box Server Service
# After=docker.service nginx-ssl.service
# Requires=docker.service

# [Service]
# Type=oneshot
# RemainAfterExit=yes
# WorkingDirectory=${PROJECT_DIR}
# ExecStart=/usr/bin/docker-compose up -d
# ExecStop=/usr/bin/docker-compose down
# TimeoutStartSec=30

# [Install]
# WantedBy=multi-user.target
# EOF
    
#     systemctl daemon-reload
#     systemctl enable singbox-server.service
}

deploy_server() {
    log_step "选择并启动协议服务..."
    
    cd ${PROJECT_DIR}
    
    echo "可用协议配置:"
    configs=($(ls config/*.json | grep -v server_info.json | xargs -n1 basename))
    
    for i in "${!configs[@]}"; do
        protocol=$(echo "${configs[$i]}" | cut -d'.' -f1)
        echo "$((i+1)). $protocol (${configs[$i]})"
    done
    
    echo -n "请选择要启动的协议 (1-${#configs[@]}) [默认: 1]: "
    read choice
    
    if [[ -z "$choice" ]]; then
        choice=1
    fi
    
    if [[ "$choice" -gt 0 ]] && [[ "$choice" -le "${#configs[@]}" ]]; then
        selected_config="${configs[$((choice-1))]}"
        protocol=$(echo "$selected_config" | cut -d'.' -f1)
        
        log_info "启动协议: $protocol"
        bash ./start_server.sh "$selected_config"
        
        # 等待服务启动
        sleep 3
        
        # 检查服务状态
        if docker-compose ps | grep -q "Up"; then
            log_success "协议 $protocol 启动成功"
            
            # 显示连接信息
            echo ""
            echo "=== 连接信息 ==="
            echo "服务器: ${DOMAIN}"
            
            if [ -f "config/server_info.json" ]; then
                password=$(grep '"password"' config/server_info.json | cut -d'"' -f4)
                echo "密码: ${password}"
                
                case $protocol in
                    "hysteria2")
                        echo "端口: 36712 (UDP)"
                        echo "协议: Hysteria2"
                        ;;
                    "vless")
                        uuid=$(grep -A 10 '"vless"' config/server_info.json | grep '"uuid"' | cut -d'"' -f4)
                        echo "端口: 8443 (TCP)"
                        echo "UUID: ${uuid}"
                        echo "传输: WebSocket"
                        echo "路径: /vless"
                        ;;
                    "vmess")
                        uuid=$(grep -A 10 '"vmess"' config/server_info.json | grep '"uuid"' | cut -d'"' -f4)
                        echo "端口: 8444 (TCP)"
                        echo "UUID: ${uuid}"
                        echo "传输: WebSocket"
                        echo "路径: /vmess"
                        ;;
                    "shadowsocks")
                        echo "端口: 8388 (TCP)"
                        echo "加密: chacha20-ietf-poly1305"
                        ;;
                    "tuic")
                        uuid=$(grep -A 10 '"tuic"' config/server_info.json | grep '"uuid"' | cut -d'"' -f4)
                        echo "端口: 8445 (UDP)"
                        echo "UUID: ${uuid}"
                        ;;
                    "trojan")
                        echo "端口: 8446 (TCP)"
                        echo "协议: Trojan"
                        ;;
                esac
            fi
            
            return 0
        else
            log_error "协议 $protocol 启动失败"
            return 1
        fi
    else
        log_error "无效选择"
        return 1
    fi
}

generate_client_download() {
    log_step "生成客户端下载包..."
    
    local client_dir="${PROJECT_DIR}/client_download"
    mkdir -p ${client_dir}
    
    # 读取服务器信息
    if [ -f "${PROJECT_DIR}/config/server_info.json" ]; then
        cp ${PROJECT_DIR}/config/server_info.json ${client_dir}/
        
        # 创建客户端信息文件
        cat > ${client_dir}/connection_info.txt << EOF
=== Sing-box 客户端连接信息 ===

服务器: ${DOMAIN}
部署时间: $(date)

请下载对应平台的客户端部署脚本:
- Linux/macOS: client_deployment_unix.sh
- Windows: client_deployment_windows.bat

认证信息已包含在脚本中，运行脚本即可自动配置。

使用方法:
1. 下载对应平台脚本
2. 赋予执行权限 (Linux/macOS): chmod +x client_deployment_unix.sh
3. 运行脚本进行自动配置
4. 选择合适的协议配置

推荐协议:
- Hysteria2: 高速度，适合高带宽需求
- VLESS: 平衡性能和兼容性  
- Shadowsocks: 简单稳定，兼容性好

更多详细信息请查看 server_info.json 文件。
EOF
    fi
    
    log_success "客户端下载包准备完成: ${client_dir}/"
}

show_deployment_result() {
    echo -e "${GREEN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════╗
║               服务端部署完成！                   ║
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    echo "项目目录: ${PROJECT_DIR}"
    echo "管理命令: ${PROJECT_DIR}/manage_server.sh"
    echo ""
    echo "常用操作:"
    echo "  查看状态: ${PROJECT_DIR}/manage_server.sh status"
    echo "  查看日志: ${PROJECT_DIR}/manage_server.sh logs"
    echo "  切换协议: ${PROJECT_DIR}/manage_server.sh switch"
    echo "  服务信息: ${PROJECT_DIR}/manage_server.sh info"
    echo "  备份配置: ${PROJECT_DIR}/manage_server.sh backup"
    echo ""
    echo "客户端信息: ${PROJECT_DIR}/client_download/"
    
    # 防火墙提示
    echo ""
    echo "重要提示:"
    echo "请确保防火墙开放以下端口:"
    echo "  80/tcp   - HTTP (证书验证)"
    echo "  443/tcp  - HTTPS (nginx)"
    echo "  36712/udp - Hysteria2"
    echo "  8443/tcp  - VLESS"
    echo "  8444/tcp  - VMess"
    echo "  8388/tcp  - Shadowsocks"
    echo "  8445/udp  - TUIC"
    echo "  8446/tcp  - Trojan"
    
    echo ""
    echo "如使用云服务器，请在安全组中开放对应端口"
}

main() {
    show_banner
    
    log_info "开始部署 Sing-box 服务端"
    log_info "域名: ${DOMAIN}"
    
    echo -n "确认开始部署? (y/N): "
    read confirm
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        log_info "部署已取消"
        
    fi
    
    check_environment
    install_dependencies
    setup_project_structure
    
    generate_server_configs
    create_docker_compose
    create_management_scripts
    
    if deploy_server; then
        generate_client_download
        show_deployment_result
        log_success "服务端部署完成！"
    else
        log_error "服务部署失败"
        
    fi
}

case "${1:-}" in
    "")
        main
        ;;
    "uninstall")
        log_info "卸载服务端..."
        systemctl stop singbox-server 2>/dev/null || true
        systemctl disable singbox-server 2>/dev/null || true
        docker-compose -f ${PROJECT_DIR}/docker-compose.yml down 2>/dev/null || true
        docker stop nginx-ssl 2>/dev/null || true
        docker rm nginx-ssl 2>/dev/null || true
        rm -rf ${PROJECT_DIR}
        rm -f /etc/systemd/system/singbox-server.service
        systemctl daemon-reload
        log_success "卸载完成"
        ;;
    "status")
        if [[ -d "${PROJECT_DIR}" ]]; then
            cd ${PROJECT_DIR}
            bash ./manage_server.sh status
        else
            log_error "服务端未安装"
        fi
        ;;
    *)
        echo "用法: $0 [uninstall|status]"
        
        ;;
esac