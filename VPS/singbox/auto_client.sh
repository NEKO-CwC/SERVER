#!/bin/bash

# Sing-box 客户端部署脚本 (Linux/macOS)
# 所有文件和配置都在当前目录下，不修改系统文件

# set -e

DOMAIN="284072.xyz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="${SCRIPT_DIR}/singbox_client"
BIN_DIR="${CLIENT_DIR}/bin"
CONFIG_DIR="${CLIENT_DIR}/configs"
LOG_DIR="${CLIENT_DIR}/logs"
CACHE_DIR="${CLIENT_DIR}/cache"

# 检测操作系统
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
    ARCH=$(uname -m)
    case $ARCH in
        "x86_64") ARCH="amd64" ;;
        "arm64") ARCH="arm64" ;;
        *) ARCH="amd64" ;;
    esac
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
    ARCH=$(uname -m)
    case $ARCH in
        "x86_64") ARCH="amd64" ;;
        "aarch64") ARCH="arm64" ;;
        "armv7l") ARCH="armv7" ;;
        *) ARCH="amd64" ;;
    esac
else
    echo "不支持的操作系统: $OSTYPE"
    
fi

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
║           Sing-box 客户端自动部署                ║
║        支持 macOS/Linux 跨平台部署               ║
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

create_directory_structure() {
    log_step "创建目录结构..."
    
    mkdir -p ${BIN_DIR}
    mkdir -p ${CONFIG_DIR}
    mkdir -p ${LOG_DIR}
    mkdir -p ${CACHE_DIR}
    mkdir -p ${CLIENT_DIR}/scripts
    mkdir -p ${CLIENT_DIR}/test
    
    log_info "客户端目录: ${CLIENT_DIR}"
}

download_singbox() {
    log_step "下载 Sing-box 客户端..."
    
    local download_url="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-${OS}-${ARCH}.tar.gz"
    local temp_file="${CLIENT_DIR}/sing-box.tar.gz"
    
    log_info "下载地址: ${download_url}"
    
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "${temp_file}" "${download_url}"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${temp_file}" "${download_url}"
    else
        log_error "需要 curl 或 wget 来下载文件"
        
    fi
    
    # 解压
    cd ${CLIENT_DIR}
    tar -xzf sing-box.tar.gz
    
    # 查找可执行文件
    local binary=$(find . -name "sing-box" -type f -executable | head -1)
    if [[ -n "$binary" ]]; then
        mv "$binary" ${BIN_DIR}/sing-box
        chmod +x ${BIN_DIR}/sing-box
        rm -rf sing-box-${OS}-${ARCH}* sing-box.tar.gz
        log_success "Sing-box 下载完成"
    else
        log_error "未找到 sing-box 可执行文件"
        
    fi
}

generate_client_configs() {
    log_step "生成客户端配置文件..."
    
    # 从服务端信息读取配置（如果存在）
    local PASSWORD="your_password_here"
    local VLESS_UUID="your_vless_uuid_here"
    local VMESS_UUID="your_vmess_uuid_here"
    local TUIC_UUID="your_tuic_uuid_here"
    
    if [[ -f "server_info.json" ]]; then
        PASSWORD=$(grep '"password"' server_info.json | cut -d'"' -f4 2>/dev/null || echo "$PASSWORD")
        VLESS_UUID=$(grep -A 10 '"vless"' server_info.json | grep '"uuid"' | cut -d'"' -f4 2>/dev/null || echo "$VLESS_UUID")
        VMESS_UUID=$(grep -A 10 '"vmess"' server_info.json | grep '"uuid"' | cut -d'"' -f4 2>/dev/null || echo "$VMESS_UUID")
        TUIC_UUID=$(grep -A 10 '"tuic"' server_info.json | grep '"uuid"' | cut -d'"' -f4 2>/dev/null || echo "$TUIC_UUID")
        log_info "从 server_info.json 读取服务器配置"
    fi
    
    # 创建基础配置模板
    local base_config='
{
    "log": {
        "disabled": false,
        "level": "info",
        "timestamp": true,
        "output": "'${LOG_DIR}'/singbox.log"
    },
    "dns": {
        "servers": [
            {
                "type": "h3",
                "tag": "cloudflare",
                "server": "1.1.1.1",
                "detour": "select"
            },
            {
                "type": "h3", 
                "tag": "google",
                "server": "8.8.8.8",
                "detour": "select"
            },
            {
                "type": "quic",
                "tag": "local",
                "server": "223.5.5.5"
            }
        ],
        "rules": [
            {
                "rule_set": "geoip-cn",
                "server": "local"
            }
        ],
        "independent_cache": true
    },
    "inbounds": [
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": 1080
        },
        {
            "type": "http",
            "tag": "http-in", 
            "listen": "127.0.0.1",
            "listen_port": 1081
        }
    ],
    "outbounds": [
        {
            "type": "selector",
            "tag": "select",
            "outbounds": [
                "proxy-main",
                "direct"
            ],
            "interrupt_exist_connections": true
        },
        PROXY_CONFIG_PLACEHOLDER,
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "route": {
        "rules": [
            {
                "ip_is_private": true,
                "outbound": "direct"
            },
            {
                "rule_set": "geoip-cn",
                "outbound": "direct"
            }
        ],
        "rule_set": [
            {
                "type": "remote",
                "tag": "geoip-cn",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
                "download_detour": "select"
            }
        ],
        "auto_detect_interface": true
    },
    "experimental": {
        "cache_file": {
            "enabled": true,
            "path": "'${CACHE_DIR}'/cache.db",
            "store_fakeip": true
        }
    }
}'
    
    # 1. Hysteria2 客户端配置
    local hysteria2_proxy='
        {
            "type": "hysteria2",
            "tag": "proxy-main",
            "server": "'${DOMAIN}'",
            "server_port": 36712,
            "password": "'${PASSWORD}'",
            "tls": {
                "enabled": true,
                "server_name": "'${DOMAIN}'",
                "insecure": false
            }
        }'
    
    echo "$base_config" | sed "s|PROXY_CONFIG_PLACEHOLDER|${hysteria2_proxy}|g" > ${CONFIG_DIR}/hysteria2.json
    
    # 2. VLESS 客户端配置
    local vless_proxy='
        {
            "type": "vless",
            "tag": "proxy-main",
            "server": "'${DOMAIN}'",
            "server_port": 8443,
            "uuid": "'${VLESS_UUID}'",
            "tls": {
                "enabled": true,
                "server_name": "'${DOMAIN}'",
                "insecure": false
            },
            "transport": {
                "type": "ws",
                "path": "/vless",
                "early_data_header_name": "Sec-WebSocket-Protocol"
            }
        }'
    
    echo "$base_config" | sed "s|PROXY_CONFIG_PLACEHOLDER|${vless_proxy}|g" > ${CONFIG_DIR}/vless.json
    
    # 3. VMess 客户端配置
    local vmess_proxy='
        {
            "type": "vmess",
            "tag": "proxy-main",
            "server": "'${DOMAIN}'",
            "server_port": 8444,
            "uuid": "'${VMESS_UUID}'",
            "security": "auto",
            "alter_id": 0,
            "tls": {
                "enabled": true,
                "server_name": "'${DOMAIN}'",
                "insecure": false
            },
            "transport": {
                "type": "ws",
                "path": "/vmess"
            }
        }'
    
    echo "$base_config" | sed "s|PROXY_CONFIG_PLACEHOLDER|${vmess_proxy}|g" > ${CONFIG_DIR}/vmess.json
    
    # 4. Shadowsocks 客户端配置
    local shadowsocks_proxy='
        {
            "type": "shadowsocks",
            "tag": "proxy-main",
            "server": "'${DOMAIN}'",
            "server_port": 8388,
            "method": "chacha20-ietf-poly1305",
            "password": "'${PASSWORD}'",
            "multiplex": {
                "enabled": true,
                "padding": true
            }
        }'
    
    echo "$base_config" | sed "s|PROXY_CONFIG_PLACEHOLDER|${shadowsocks_proxy}|g" > ${CONFIG_DIR}/shadowsocks.json
    
    # 5. TUIC 客户端配置
    local tuic_proxy='
        {
            "type": "tuic",
            "tag": "proxy-main",
            "server": "'${DOMAIN}'",
            "server_port": 8445,
            "uuid": "'${TUIC_UUID}'",
            "password": "'${PASSWORD}'",
            "tls": {
                "enabled": true,
                "server_name": "'${DOMAIN}'",
                "insecure": false
            },
            "congestion_control": "bbr"
        }'
    
    echo "$base_config" | sed "s|PROXY_CONFIG_PLACEHOLDER|${tuic_proxy}|g" > ${CONFIG_DIR}/tuic.json
    
    # 6. Trojan 客户端配置
    local trojan_proxy='
        {
            "type": "trojan",
            "tag": "proxy-main",
            "server": "'${DOMAIN}'",
            "server_port": 8446,
            "password": "'${PASSWORD}'",
            "tls": {
                "enabled": true,
                "server_name": "'${DOMAIN}'",
                "insecure": false
            }
        }'
    
    echo "$base_config" | sed "s|PROXY_CONFIG_PLACEHOLDER|${trojan_proxy}|g" > ${CONFIG_DIR}/trojan.json
    
    # 保存配置信息
    cat > ${CONFIG_DIR}/client_info.json << EOF
{
    "server": "${DOMAIN}",
    "password": "${PASSWORD}",
    "vless_uuid": "${VLESS_UUID}",
    "vmess_uuid": "${VMESS_UUID}",
    "tuic_uuid": "${TUIC_UUID}",
    "proxy_ports": {
        "mixed": 1080,
        "http": 1081
    },
    "protocols": {
        "hysteria2": "hysteria2.json",
        "vless": "vless.json", 
        "vmess": "vmess.json",
        "shadowsocks": "shadowsocks.json",
        "tuic": "tuic.json",
        "trojan": "trojan.json"
    },
    "generated_at": "$(date -Iseconds)"
}
EOF
    
    log_success "客户端配置生成完成"
}

create_management_scripts() {
    log_step "创建管理脚本..."
    
    # 启动脚本
    cat > ${CLIENT_DIR}/scripts/start_client.sh << EOF
#!/bin/bash

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="\$(dirname "\$SCRIPT_DIR")"
CONFIG_FILE="\${1:-hysteria2.json}"

if [[ ! -f "\${CLIENT_DIR}/configs/\${CONFIG_FILE}" ]]; then
    echo "错误: 配置文件不存在: \${CONFIG_FILE}"
    echo "可用配置:"
    ls "\${CLIENT_DIR}/configs"/*.json 2>/dev/null | xargs -n1 basename
    
fi

echo "启动 Sing-box 客户端..."
echo "配置文件: \${CONFIG_FILE}"
echo "代理端口: 1080 (Mixed), 1081 (HTTP)"

# 检查是否已有进程运行
if pgrep -f "sing-box.*run" > /dev/null; then
    echo "检测到运行中的 sing-box 进程，正在停止..."
    pkill -f "sing-box.*run"
    sleep 2
fi

# 启动客户端
cd "\${CLIENT_DIR}"
nohup ./bin/sing-box run -c "configs/\${CONFIG_FILE}" > "logs/client.log" 2>&1 &

CLIENT_PID=\$!
echo "客户端已启动，PID: \${CLIENT_PID}"
echo "查看日志: tail -f \${CLIENT_DIR}/logs/client.log"
echo "停止客户端: \${CLIENT_DIR}/scripts/stop_client.sh"

# 等待启动
sleep 2

# 检查进程是否正常运行
if ps -p \$CLIENT_PID > /dev/null; then
    echo "✓ 客户端启动成功"
    echo ""
    echo "代理设置:"
    echo "  HTTP:  127.0.0.1:1081"
    echo "  SOCKS: 127.0.0.1:1080"
else
    echo "✗ 客户端启动失败，请检查日志"
fi
EOF
    
    # 停止脚本
    cat > ${CLIENT_DIR}/scripts/stop_client.sh << EOF
#!/bin/bash

echo "正在停止 Sing-box 客户端..."

if pgrep -f "sing-box.*run" > /dev/null; then
    pkill -f "sing-box.*run"
    sleep 2
    
    if pgrep -f "sing-box.*run" > /dev/null; then
        echo "强制停止..."
        pkill -9 -f "sing-box.*run"
    fi
    
    echo "✓ 客户端已停止"
else
    echo "没有运行中的客户端进程"
fi
EOF
    
    # 状态检查脚本
    cat > ${CLIENT_DIR}/scripts/status_client.sh << EOF
#!/bin/bash

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="\$(dirname "\$SCRIPT_DIR")"

echo "=== Sing-box 客户端状态 ==="

if pgrep -f "sing-box.*run" > /dev/null; then
    PID=\$(pgrep -f "sing-box.*run")
    echo "✓ 客户端正在运行 (PID: \$PID)"
    
    echo ""
    echo "代理端口状态:"
    netstat -ln | grep -E "(1080|1081)" | while read line; do
        echo "  \$line"
    done
    
    echo ""
    echo "最近日志:"
    tail -n 10 "\${CLIENT_DIR}/logs/client.log" 2>/dev/null || echo "无日志文件"
else
    echo "✗ 客户端未运行"
fi
EOF
    
    # 配置切换脚本
    cat > ${CLIENT_DIR}/scripts/switch_config.sh << EOF
#!/bin/bash

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="\$(dirname "\$SCRIPT_DIR")"

echo "可用配置:"
configs=(\$(ls "\${CLIENT_DIR}/configs"/*.json 2>/dev/null | xargs -n1 basename))

if [[ \${#configs[@]} -eq 0 ]]; then
    echo "没有找到配置文件"
    
fi

for i in "\${!configs[@]}"; do
    protocol=\$(echo "\${configs[\$i]}" | cut -d'.' -f1)
    echo "\$((i+1)). \$protocol"
done

echo -n "请选择配置 (1-\${#configs[@]}): "
read choice

if [[ "\$choice" -gt 0 ]] && [[ "\$choice" -le "\${#configs[@]}" ]]; then
    selected_config="\${configs[\$((choice-1))]}"
    protocol=\$(echo "\$selected_config" | cut -d'.' -f1)
    
    echo "切换到协议: \$protocol"
    
    # 停止当前客户端
    "\${CLIENT_DIR}/scripts/stop_client.sh"
    sleep 1
    
    # 启动新配置
    "\${CLIENT_DIR}/scripts/start_client.sh" "\$selected_config"
else
    echo "无效选择"
    
fi
EOF
    
    # 设置权限
    chmod +x ${CLIENT_DIR}/scripts/*.sh
    
    log_success "管理脚本创建完成"
}

create_test_scripts() {
    log_step "创建测试脚本..."
    
    # 连接测试脚本
    cat > ${CLIENT_DIR}/test/test_connection.sh << 'EOF'
#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== 代理连接测试 ==="

# 检查客户端是否运行
if ! pgrep -f "sing-box.*run" > /dev/null; then
    echo "✗ Sing-box 客户端未运行"
    echo "请先启动客户端: ${CLIENT_DIR}/scripts/start_client.sh"
    
fi

echo "✓ 检测到运行中的客户端"
echo ""

# 测试网站列表
test_sites=(
    "https://www.google.com"
    "https://www.youtube.com"
    "https://github.com"
    "https://httpbin.org/ip"
)

echo "=== 直连测试 ==="
echo -n "本地IP: "
curl -s --connect-timeout 5 https://httpbin.org/ip 2>/dev/null | grep -o '"origin": "[^"]*' | cut -d'"' -f4 || echo "获取失败"

echo ""
echo "=== 代理连接测试 ==="

for site in "${test_sites[@]}"; do
    echo -n "测试 ${site} ... "
    
    # 使用HTTP代理测试
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --proxy http://127.0.0.1:1081 \
        --connect-timeout 10 \
        --max-time 30 \
        "${site}" 2>/dev/null)
    
    if [[ "$response" == "200" ]]; then
        echo "✓ 成功"
    else
        echo "✗ 失败 (${response})"
    fi
done

echo ""
echo "=== 代理IP检查 ==="
echo -n "代理IP: "
proxy_ip=$(curl -s --proxy http://127.0.0.1:1081 \
    --connect-timeout 10 \
    https://httpbin.org/ip 2>/dev/null | \
    grep -o '"origin": "[^"]*' | cut -d'"' -f4)

if [[ -n "$proxy_ip" ]]; then
    echo "$proxy_ip"
    
    # 检查地理位置
    echo -n "地理位置: "
    location=$(curl -s --connect-timeout 5 \
        "http://ip-api.com/json/${proxy_ip}" 2>/dev/null | \
        grep -o '"country": "[^"]*' | cut -d'"' -f4)
    
    if [[ -n "$location" ]]; then
        echo "$location"
    else
        echo "无法获取"
    fi
else
    echo "无法获取代理IP"
fi

echo ""
echo "=== 延迟测试 ==="

# 测试代理延迟
echo -n "代理延迟: "
start_time=$(date +%s%3N)
curl -s -o /dev/null --proxy http://127.0.0.1:1081 \
    --connect-timeout 10 \
    https://www.google.com >/dev/null 2>&1
end_time=$(date +%s%3N)

if [[ $? -eq 0 ]]; then
    latency=$((end_time - start_time))
    echo "${latency}ms"
else
    echo "测试失败"
fi

echo ""
echo "测试完成"
EOF
    
    # 性能测试脚本
    cat > ${CLIENT_DIR}/test/test_performance.sh << 'EOF'
#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== 代理性能测试 ==="

if ! pgrep -f "sing-box.*run" > /dev/null; then
    echo "✗ Sing-box 客户端未运行"
    
fi

echo "✓ 客户端运行中"
echo ""

# CPU和内存使用率
echo "=== 资源使用情况 ==="
if command -v ps >/dev/null 2>&1; then
    PID=$(pgrep -f "sing-box.*run")
    if [[ -n "$PID" ]]; then
        echo "进程ID: $PID"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            ps -p $PID -o pid,pcpu,pmem,rss,vsz,comm
        else
            # Linux
            ps -p $PID -o pid,pcpu,pmem,rss,vsz,comm
        fi
    fi
fi

echo ""
echo "=== 下载速度测试 ==="

# 下载测试
test_urls=(
    "https://httpbin.org/bytes/1048576"  # 1MB
    "https://httpbin.org/bytes/5242880"  # 5MB
)

for url in "${test_urls[@]}"; do
    size=$(echo $url | grep -o '[0-9]*$')
    size_mb=$((size / 1048576))
    echo -n "下载 ${size_mb}MB 测试文件: "
    
    start_time=$(date +%s%3N)
    curl -s -o /dev/null \
        --proxy http://127.0.0.1:1081 \
        --connect-timeout 10 \
        --max-time 60 \
        "$url"
    
    if [[ $? -eq 0 ]]; then
        end_time=$(date +%s%3N)
        duration=$((end_time - start_time))
        
        if [[ $duration -gt 0 ]]; then
            speed=$((size * 1000 / duration))
            speed_mb=$((speed / 1048576))
            echo "${speed_mb}MB/s"
        else
            echo "速度过快，无法测量"
        fi
    else
        echo "下载失败"
    fi
done

echo ""
echo "=== 并发连接测试 ==="

# 并发连接测试
echo "测试并发连接能力..."
concurrent_count=5
success_count=0

for i in $(seq 1 $concurrent_count); do
    curl -s -o /dev/null \
        --proxy http://127.0.0.1:1081 \
        --connect-timeout 5 \
        --max-time 10 \
        https://httpbin.org/ip &
done

# 等待所有后台任务完成
wait

# 统计成功连接
for job in $(jobs -p); do
    if wait $job; then
        ((success_count++))
    fi
done

echo "并发连接测试: ${success_count}/${concurrent_count} 成功"

echo ""
echo "性能测试完成"
EOF
    
    chmod +x ${CLIENT_DIR}/test/*.sh
    
    log_success "测试脚本创建完成"
}

create_client_manager() {
    log_step "创建客户端管理器..."
    
    cat > ${CLIENT_DIR}/client_manager.sh << 'EOF'
#!/bin/bash

# Sing-box 客户端管理器

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$SCRIPT_DIR"

show_help() {
    echo "Sing-box 客户端管理器"
    echo ""
    echo "用法: $0 {start|stop|restart|status|switch|test|logs|info}"
    echo ""
    echo "命令:"
    echo "  start [config]  - 启动客户端 (默认: hysteria2.json)"
    echo "  stop           - 停止客户端"
    echo "  restart        - 重启客户端"
    echo "  status         - 查看状态"
    echo "  switch         - 切换协议配置"
    echo "  test           - 运行连接测试"
    echo "  perf           - 运行性能测试"
    echo "  logs           - 查看日志"
    echo "  info           - 显示配置信息"
    echo ""
    echo "示例:"
    echo "  $0 start vless.json    # 启动VLESS配置"
    echo "  $0 switch              # 交互式切换协议"
}

case "${1:-}" in
    "start")
        shift
        "${CLIENT_DIR}/scripts/start_client.sh" $@
        ;;
    "stop")
        "${CLIENT_DIR}/scripts/stop_client.sh"
        ;;
    "restart")
        echo "重启客户端..."
        "${CLIENT_DIR}/scripts/stop_client.sh"
        sleep 2
        "${CLIENT_DIR}/scripts/start_client.sh" "${2:-hysteria2.json}"
        ;;
    "status")
        "${CLIENT_DIR}/scripts/status_client.sh"
        ;;
    "switch")
        "${CLIENT_DIR}/scripts/switch_config.sh"
        ;;
    "test")
        "${CLIENT_DIR}/test/test_connection.sh"
        ;;
    "perf")
        "${CLIENT_DIR}/test/test_performance.sh"
        ;;
    "logs")
        if [[ -f "${CLIENT_DIR}/logs/client.log" ]]; then
            tail -f "${CLIENT_DIR}/logs/client.log"
        else
            echo "日志文件不存在"
        fi
        ;;
    "info")
        echo "=== 客户端信息 ==="
        if [[ -f "${CLIENT_DIR}/configs/client_info.json" ]]; then
            cat "${CLIENT_DIR}/configs/client_info.json"
        else
            echo "配置信息文件不存在"
        fi
        echo ""
        echo "=== 可用配置 ==="
        ls "${CLIENT_DIR}/configs"/*.json 2>/dev/null | xargs -n1 basename
        ;;
    *)
        show_help
        
        ;;
esac
EOF
    
    chmod +x ${CLIENT_DIR}/client_manager.sh
    
    log_success "客户端管理器创建完成"
}

create_documentation() {
    log_step "创建使用文档..."
    
    cat > ${CLIENT_DIR}/README.md << EOF
# Sing-box 客户端使用指南

## 概述

这是一个便携式的 Sing-box 客户端，所有文件都在当前目录下，不需要系统级别的安装或配置。

## 目录结构

\`\`\`
singbox_client/
├── bin/                    # Sing-box 可执行文件
├── configs/                # 配置文件
├── scripts/                # 管理脚本
├── test/                   # 测试脚本
├── logs/                   # 日志文件
├── cache/                  # 缓存文件
├── client_manager.sh       # 主管理器
└── README.md              # 使用说明
\`\`\`

## 快速开始

### 1. 启动客户端
\`\`\`bash
./client_manager.sh start
\`\`\`

### 2. 配置代理
启动后，代理地址为：
- HTTP代理: 127.0.0.1:1081
- SOCKS代理: 127.0.0.1:1080

### 3. 测试连接
\`\`\`bash
./client_manager.sh test
\`\`\`

## 详细使用方法

### 管理命令

\`\`\`bash
# 启动指定协议
./client_manager.sh start vless.json

# 交互式切换协议
./client_manager.sh switch

# 查看运行状态
./client_manager.sh status

# 停止客户端
./client_manager.sh stop

# 重启客户端
./client_manager.sh restart

# 查看实时日志
./client_manager.sh logs

# 显示配置信息
./client_manager.sh info
\`\`\`

### 测试工具

\`\`\`bash
# 连接测试
./client_manager.sh test

# 性能测试
./client_manager.sh perf
\`\`\`

## 可用协议配置

| 协议 | 配置文件 | 特点 |
|------|----------|------|
| Hysteria2 | hysteria2.json | 高速度，基于QUIC |
| VLESS | vless.json | 轻量级，WebSocket传输 |
| VMess | vmess.json | 经典协议，兼容性好 |
| Shadowsocks | shadowsocks.json | 简单稳定，广泛支持 |
| TUIC | tuic.json | 基于QUIC，移动友好 |
| Trojan | trojan.json | TLS伪装，隐蔽性好 |

## 浏览器配置

### Chrome/Edge
1. 设置 → 高级 → 代理设置
2. 使用代理服务器: 127.0.0.1:1081

### Firefox  
1. 设置 → 网络设置
2. 手动代理配置
3. HTTP代理: 127.0.0.1:1081

### Safari (macOS)
1. 系统偏好设置 → 网络
2. 高级 → 代理
3. 勾选"网页代理 (HTTP)"
4. 服务器: 127.0.0.1:1081

## 故障排除

### 常见问题

1. **客户端启动失败**
   - 检查端口是否被占用: \`netstat -ln | grep 1080\`
   - 查看错误日志: \`./client_manager.sh logs\`

2. **连接失败**
   - 验证服务器配置是否正确
   - 检查网络连接: \`./client_manager.sh test\`

3. **速度慢**
   - 尝试切换协议: \`./client_manager.sh switch\`
   - 运行性能测试: \`./client_manager.sh perf\`

### 日志查看

\`\`\`bash
# 实时日志
./client_manager.sh logs

# 历史日志
cat logs/client.log

# 详细调试日志
tail -f logs/singbox.log
\`\`\`

## 高级配置

### 修改代理端口
编辑配置文件中的 \`listen_port\` 字段：
\`\`\`json
"inbounds": [
    {
        "type": "mixed",
        "listen_port": 1080  // 修改此端口
    }
]
\`\`\`

### 添加路由规则
在配置文件的 \`route.rules\` 中添加自定义规则。

## 安全注意事项

1. 不要在公共网络上暴露代理端口
2. 定期更新客户端版本
3. 妥善保管服务器配置信息
4. 使用强密码和安全的传输协议

## 更新客户端

重新运行部署脚本即可更新到最新版本：
\`\`\`bash
./client_deployment_unix.sh
\`\`\`

## 卸载

删除整个客户端目录即可：
\`\`\`bash
rm -rf singbox_client/
\`\`\`

---

如有问题，请查看日志文件或联系技术支持。
EOF
    
    log_success "使用文档创建完成"
}

show_deployment_result() {
    echo -e "${GREEN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════╗
║              客户端部署完成！                    ║
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    echo "客户端目录: ${CLIENT_DIR}"
    echo "管理命令: ${CLIENT_DIR}/client_manager.sh"
    echo ""
    echo "快速开始:"
    echo "  启动客户端: ${CLIENT_DIR}/client_manager.sh start"
    echo "  测试连接:   ${CLIENT_DIR}/client_manager.sh test" 
    echo "  切换协议:   ${CLIENT_DIR}/client_manager.sh switch"
    echo "  查看状态:   ${CLIENT_DIR}/client_manager.sh status"
    echo ""
    echo "代理设置:"
    echo "  HTTP代理:  127.0.0.1:1081"
    echo "  SOCKS代理: 127.0.0.1:1080"
    echo ""
    echo "详细说明: ${CLIENT_DIR}/README.md"
    
    # 显示服务器信息
    if [[ -f "${CONFIG_DIR}/client_info.json" ]]; then
        echo ""
        echo "服务器信息:"
        echo "  域名: ${DOMAIN}"
        
        local password=$(grep '"password"' ${CONFIG_DIR}/client_info.json | cut -d'"' -f4)
        if [[ "$password" != "your_password_here" ]]; then
            echo "  密码: ${password}"
        fi
    fi
}

main() {
    show_banner
    
    log_info "开始部署 Sing-box 客户端 (${OS}/${ARCH})"
    
    echo -n "确认开始部署? (y/N): "
    read confirm
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        log_info "部署已取消"
        
    fi
    
    create_directory_structure
    download_singbox
    generate_client_configs
    create_management_scripts
    create_test_scripts
    create_client_manager
    create_documentation
    
    show_deployment_result
    log_success "客户端部署完成！"
}

# 执行主函数
main
EOF