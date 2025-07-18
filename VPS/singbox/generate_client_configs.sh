#!/bin/bash

# Sing-box 客户端配置生成器 (macOS)
# 根据服务端配置生成对应的客户端配置



DOMAIN="284072.xyz"
CONFIG_DIR="./client_configs"
SERVER_INFO_FILE="../config/server_info.json"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_note() {
    echo -e "${BLUE}[NOTE]${NC} $1"
}

# 创建客户端配置目录
mkdir -p ${CONFIG_DIR}

# 读取服务端信息
read_server_info() {
    if [ -f "${SERVER_INFO_FILE}" ]; then
        PASSWORD=$(grep '"password"' ${SERVER_INFO_FILE} | cut -d'"' -f4)
        VLESS_UUID=$(grep -A 10 '"vless"' ${SERVER_INFO_FILE} | grep '"uuid"' | cut -d'"' -f4)
        VMESS_UUID=$(grep -A 10 '"vmess"' ${SERVER_INFO_FILE} | grep '"uuid"' | cut -d'"' -f4)
        TUIC_UUID=$(grep -A 10 '"tuic"' ${SERVER_INFO_FILE} | grep '"uuid"' | cut -d'"' -f4)
        
        log_info "从服务端配置读取到认证信息"
    else
        log_warn "服务端配置文件不存在，请手动设置认证信息"
        PASSWORD="your_password_here"
        VLESS_UUID="your_vless_uuid_here"
        VMESS_UUID="your_vmess_uuid_here"
        TUIC_UUID="your_tuic_uuid_here"
    fi
}

# 生成基础客户端配置模板
create_base_config() {
    cat << 'EOF'
{
	"log": {
		"disabled": false,
		"level": "warn",
		"timestamp": true
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
			},
			{
				"type": "fakeip",
				"tag": "fakeip",
				"inet4_range": "198.18.0.0/15",
				"inet6_range": "fc00::/18"
			}
		],
		"rules": [
			{
				"type": "logical",
				"mode": "and",
				"rules": [
					{
						"rule_set": "geosite-geolocation-!cn",
						"invert": true
					},
					{
						"rule_set": "geoip-cn"
					}
				],
				"server": "local"
			},
			{
				"query_type": [
					"A",
					"AAAA"
				],
				"server": "fakeip"
			}
		],
		"independent_cache": true
	},
	"inbounds": [
		{
			"type": "tun",
			"tag": "tun-in",
			"address": [
				"172.18.0.1/30",
				"fdfe:dcba:9876::1/126"
			],
			"mtu": 9000,
			"auto_route": true,
			"strict_route": true
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
				"action": "sniff"
			},
			{
				"protocol": "dns",
				"action": "hijack-dns"
			},
			{
				"ip_is_private": true,
				"outbound": "direct"
			},
			{
				"domain_suffix": [
					"u3.ucweb.com"
				],
				"action": "reject"
			},
			{
				"rule_set": "geoip-cn",
				"outbound": "direct"
			},
			{
				"protocol": "quic",
				"action": "reject"
			}
		],
		"rule_set": [
			{
				"type": "remote",
				"tag": "geosite-geolocation-cn",
				"format": "binary",
				"url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs"
			},
			{
				"type": "remote",
				"tag": "geosite-geolocation-!cn",
				"format": "binary",
				"url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs"
			},
			{
				"type": "remote",
				"tag": "geoip-cn",
				"format": "binary",
				"url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
			}
		],
		"auto_detect_interface": true,
		"default_domain_resolver": "local"
	},
	"experimental": {
		"cache_file": {
			"enabled": true,
			"store_fakeip": true,
			"store_rdrc": true
		},
		"clash_api": {
			"external_controller": "127.0.0.1:9090"
		}
	}
}
EOF
}

# 1. Hysteria2 客户端配置
create_hysteria2_client() {
    log_info "生成 Hysteria2 客户端配置..."
    
    local proxy_config=$(cat << EOF
		{
			"type": "hysteria2",
			"tag": "proxy-main",
			"server": "${DOMAIN}",
			"server_port": 36712,
			"password": "${PASSWORD}",
			"tls": {
				"enabled": true,
				"server_name": "${DOMAIN}",
				"insecure": false
			}
		}
EOF
)
    
    create_base_config | sed "s/PROXY_CONFIG_PLACEHOLDER/${proxy_config}/g" > ${CONFIG_DIR}/hysteria2_client.json
}

# 2. VLESS 客户端配置
create_vless_client() {
    log_info "生成 VLESS 客户端配置..."
    
    local proxy_config=$(cat << EOF
		{
			"type": "vless",
			"tag": "proxy-main",
			"server": "${DOMAIN}",
			"server_port": 443,
			"uuid": "${VLESS_UUID}",
			"tls": {
				"enabled": true,
				"server_name": "${DOMAIN}",
				"insecure": false
			},
			"transport": {
				"type": "ws",
				"path": "/vless",
				"early_data_header_name": "Sec-WebSocket-Protocol"
			}
		}
EOF
)
    
    create_base_config | sed "s/PROXY_CONFIG_PLACEHOLDER/${proxy_config}/g" > ${CONFIG_DIR}/vless_client.json
}

# 3. VMess 客户端配置
create_vmess_client() {
    log_info "生成 VMess 客户端配置..."
    
    local proxy_config=$(cat << EOF
		{
			"type": "vmess",
			"tag": "proxy-main",
			"server": "${DOMAIN}",
			"server_port": 443,
			"uuid": "${VMESS_UUID}",
			"security": "auto",
			"alter_id": 0,
			"tls": {
				"enabled": true,
				"server_name": "${DOMAIN}",
				"insecure": false
			},
			"transport": {
				"type": "ws",
				"path": "/vmess"
			}
		}
EOF
)
    
    create_base_config | sed "s/PROXY_CONFIG_PLACEHOLDER/${proxy_config}/g" > ${CONFIG_DIR}/vmess_client.json
}

# 4. Shadowsocks 客户端配置
create_shadowsocks_client() {
    log_info "生成 Shadowsocks 客户端配置..."
    
    local proxy_config=$(cat << EOF
		{
			"type": "shadowsocks",
			"tag": "proxy-main",
			"server": "${DOMAIN}",
			"server_port": 8388,
			"method": "chacha20-ietf-poly1305",
			"password": "${PASSWORD}",
			"multiplex": {
				"enabled": true,
				"padding": true
			}
		}
EOF
)
    
    create_base_config | sed "s/PROXY_CONFIG_PLACEHOLDER/${proxy_config}/g" > ${CONFIG_DIR}/shadowsocks_client.json
}

# 5. TUIC 客户端配置
create_tuic_client() {
    log_info "生成 TUIC 客户端配置..."
    
    local proxy_config=$(cat << EOF
		{
			"type": "tuic",
			"tag": "proxy-main",
			"server": "${DOMAIN}",
			"server_port": 443,
			"uuid": "${TUIC_UUID}",
			"password": "${PASSWORD}",
			"tls": {
				"enabled": true,
				"server_name": "${DOMAIN}",
				"insecure": false
			},
			"congestion_control": "bbr"
		}
EOF
)
    
    create_base_config | sed "s/PROXY_CONFIG_PLACEHOLDER/${proxy_config}/g" > ${CONFIG_DIR}/tuic_client.json
}

# 6. Trojan 客户端配置
create_trojan_client() {
    log_info "生成 Trojan 客户端配置..."
    
    local proxy_config=$(cat << EOF
		{
			"type": "trojan",
			"tag": "proxy-main",
			"server": "${DOMAIN}",
			"server_port": 443,
			"password": "${PASSWORD}",
			"tls": {
				"enabled": true,
				"server_name": "${DOMAIN}",
				"insecure": false
			}
		}
EOF
)
    
    create_base_config | sed "s/PROXY_CONFIG_PLACEHOLDER/${proxy_config}/g" > ${CONFIG_DIR}/trojan_client.json
}

# 7. Naive 客户端配置
create_naive_client() {
    log_info "生成 Naive 客户端配置..."
    
    local proxy_config=$(cat << EOF
		{
			"type": "naive",
			"tag": "proxy-main",
			"server": "${DOMAIN}",
			"server_port": 443,
			"username": "user",
			"password": "${PASSWORD}",
			"tls": {
				"enabled": true,
				"server_name": "${DOMAIN}",
				"insecure": false
			}
		}
EOF
)
    
    create_base_config | sed "s/PROXY_CONFIG_PLACEHOLDER/${proxy_config}/g" > ${CONFIG_DIR}/naive_client.json
}

# 生成客户端启动脚本
create_client_start_script() {
    log_info "生成客户端启动脚本..."
    
    cat > start_client.sh << 'EOF'
#!/bin/bash

# Sing-box 客户端启动脚本 (macOS)

CONFIG_FILE="${1:-hysteria2_client.json}"
CONFIG_DIR="./client_configs"

if [ ! -f "${CONFIG_DIR}/${CONFIG_FILE}" ]; then
    echo "错误: 配置文件 ${CONFIG_DIR}/${CONFIG_FILE} 不存在"
    echo "可用配置:"
    ls ${CONFIG_DIR}/*_client.json 2>/dev/null | xargs -n1 basename
    exit 1
fi

echo "启动 Sing-box 客户端，使用配置: ${CONFIG_FILE}"

# 检查是否已有客户端运行
if pgrep -f "sing-box.*run" > /dev/null; then
    echo "检测到已运行的 sing-box 进程，正在停止..."
    pkill -f "sing-box.*run"
    sleep 2
fi

# 检查sing-box是否安装
if ! command -v sing-box >/dev/null 2>&1; then
    echo "错误: sing-box 未安装"
    echo "请访问 https://github.com/SagerNet/sing-box/releases 下载安装"
    echo "或使用 Homebrew: brew install sagernet/sing-box/sing-box"
    exit 1
fi

# 检查权限（macOS TUN需要sudo）
if [ "$EUID" -ne 0 ]; then
    echo "macOS TUN模式需要管理员权限，请使用 sudo 运行"
    echo "sudo ./start_client.sh ${CONFIG_FILE}"
    exit 1
fi

# 启动客户端
echo "启动 sing-box 客户端..."
sing-box run -c "${CONFIG_DIR}/${CONFIG_FILE}" &

CLIENT_PID=$!
echo "客户端已启动，PID: ${CLIENT_PID}"
echo "Clash API: http://127.0.0.1:9090"
echo "按 Ctrl+C 停止客户端"

# 等待信号
trap "echo '正在停止客户端...'; kill ${CLIENT_PID}; exit" INT TERM

wait ${CLIENT_PID}
EOF
    
    chmod +x start_client.sh
}

# 生成客户端切换脚本
create_client_switch_script() {
    log_info "生成客户端配置切换脚本..."
    
    cat > switch_client.sh << 'EOF'
#!/bin/bash

# 客户端配置切换脚本

CONFIG_DIR="./client_configs"

echo "可用客户端配置:"
configs=($(ls ${CONFIG_DIR}/*_client.json 2>/dev/null | xargs -n1 basename))

if [ ${#configs[@]} -eq 0 ]; then
    echo "没有找到客户端配置文件"
    exit 1
fi

for i in "${!configs[@]}"; do
    protocol=$(echo "${configs[$i]}" | cut -d'_' -f1)
    echo "$((i+1)). ${protocol} (${configs[$i]})"
done

echo -n "请选择配置 (1-${#configs[@]}): "
read choice

if [ "$choice" -gt 0 ] && [ "$choice" -le "${#configs[@]}" ]; then
    selected_config="${configs[$((choice-1))]}"
    protocol=$(echo "${selected_config}" | cut -d'_' -f1)
    echo "切换到协议: ${protocol}"
    echo "配置文件: ${selected_config}"
    echo ""
    echo "启动命令: sudo ./start_client.sh ${selected_config}"
    echo ""
    echo -n "是否立即启动? (y/N): "
    read start_now
    
    if [ "$start_now" = "y" ] || [ "$start_now" = "Y" ]; then
        if [ "$EUID" -ne 0 ]; then
            echo "需要管理员权限，请输入密码:"
            sudo ./start_client.sh "${selected_config}"
        else
            ./start_client.sh "${selected_config}"
        fi
    fi
else
    echo "无效选择"
    exit 1
fi
EOF
    
    chmod +x switch_client.sh
}

# 生成连接测试脚本
create_test_script() {
    log_info "生成连接测试脚本..."
    
    cat > test_connection.sh << 'EOF'
#!/bin/bash

# 连接测试脚本

echo "正在测试代理连接..."

# 测试网站列表
test_sites=(
    "https://www.google.com"
    "https://www.youtube.com"
    "https://github.com"
    "https://httpbin.org/ip"
)

# 检查是否有代理在运行
if ! pgrep -f "sing-box.*run" > /dev/null; then
    echo "错误: 没有检测到运行中的 sing-box 客户端"
    echo "请先启动客户端: sudo ./start_client.sh <config>"
    exit 1
fi

echo "检测到 sing-box 客户端正在运行"
echo ""

# 测试直连和代理连接
echo "=== 连接测试 ==="

for site in "${test_sites[@]}"; do
    echo -n "测试 ${site} ... "
    
    # 使用系统代理测试
    response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "${site}" 2>/dev/null)
    
    if [ "$response" = "200" ]; then
        echo "✓ 成功 (${response})"
    else
        echo "✗ 失败 (${response})"
    fi
done

echo ""
echo "=== IP 地址检查 ==="

# 检查当前IP
echo -n "当前 IP 地址: "
current_ip=$(curl -s --connect-timeout 10 https://httpbin.org/ip 2>/dev/null | grep -o '"origin": "[^"]*' | cut -d'"' -f4)

if [ -n "$current_ip" ]; then
    echo "$current_ip"
    
    # 简单的地理位置检查
    echo -n "IP 地理位置: "
    location=$(curl -s --connect-timeout 10 "http://ip-api.com/json/${current_ip}" 2>/dev/null | grep -o '"country": "[^"]*' | cut -d'"' -f4)
    
    if [ -n "$location" ]; then
        echo "$location"
    else
        echo "无法获取"
    fi
else
    echo "无法获取 IP 地址"
fi

echo ""
echo "=== Clash API 状态 ==="

# 检查Clash API
if curl -s http://127.0.0.1:9090/version >/dev/null 2>&1; then
    echo "✓ Clash API 可用: http://127.0.0.1:9090"
    echo "  可使用 Clash 控制面板进行管理"
else
    echo "✗ Clash API 不可用"
fi

echo ""
echo "测试完成"
EOF
    
    chmod +x test_connection.sh
}

# 生成安装指南
create_install_guide() {
    log_info "生成 macOS 安装指南..."
    
    cat > INSTALL_GUIDE.md << 'EOF'
# Sing-box macOS 客户端安装指南

## 1. 安装 Sing-box

### 方法一：使用 Homebrew（推荐）
```bash
# 添加 tap
brew tap sagernet/sing-box

# 安装 sing-box
brew install sing-box
```

### 方法二：手动下载
1. 访问 [Sing-box Releases](https://github.com/SagerNet/sing-box/releases)
2. 下载适合 macOS 的版本
3. 解压并移动到 `/usr/local/bin/`

## 2. 验证安装
```bash
sing-box version
```

## 3. 使用客户端

### 启动客户端
```bash
# 选择配置启动
sudo ./start_client.sh hysteria2_client.json

# 或使用交互式选择
./switch_client.sh
```

### 测试连接
```bash
./test_connection.sh
```

## 4. 重要说明

### TUN 模式权限
- macOS 的 TUN 模式需要管理员权限
- 首次使用会弹出权限请求对话框
- 建议允许 sing-box 的网络访问权限

### 系统代理设置
- TUN 模式会自动配置系统代理
- 无需手动设置浏览器代理
- 停止客户端后系统代理会自动恢复

### 防火墙设置
- 如遇到连接问题，检查 macOS 防火墙设置
- 允许 sing-box 的入站连接

## 5. 管理界面

### Clash API
- 地址: http://127.0.0.1:9090
- 可使用第三方 Clash 控制面板
- 推荐: [Clash Dashboard](https://clash.razord.top/)

## 6. 故障排除

### 常见问题
1. **权限被拒绝**: 使用 `sudo` 运行启动脚本
2. **端口占用**: 检查是否有其他代理软件运行
3. **连接失败**: 检查服务端配置和网络连接

### 日志查看
```bash
# 查看详细日志
sudo sing-box run -c client_configs/config.json --log-level debug
```

### 重置配置
```bash
# 停止所有 sing-box 进程
sudo pkill -f sing-box

# 清理缓存
rm -rf ~/.cache/sing-box
```

## 7. 配置文件说明

- `hysteria2_client.json`: Hysteria2 协议
- `vless_client.json`: VLESS + WebSocket + TLS
- `vmess_client.json`: VMess + WebSocket + TLS  
- `shadowsocks_client.json`: Shadowsocks
- `tuic_client.json`: TUIC 协议
- `trojan_client.json`: Trojan 协议
- `naive_client.json`: Naive Proxy

选择最适合您网络环境的协议配置。
EOF
}

# 主函数
main() {
    log_info "开始生成 Sing-box 客户端配置..."
    
    # 读取服务端信息
    read_server_info
    
    # 生成所有客户端配置
    create_hysteria2_client
    create_vless_client
    create_vmess_client
    create_shadowsocks_client
    create_tuic_client
    create_trojan_client
    create_naive_client
    
    # 生成管理脚本
    create_client_start_script
    create_client_switch_script
    create_test_script
    create_install_guide
    
    log_info "所有客户端配置生成完成！"
    echo ""
    log_note "配置文件位置: ${CONFIG_DIR}/"
    log_note "使用方法:"
    echo "  1. 安装 sing-box: brew tap sagernet/sing-box && brew install sing-box"
    echo "  2. 启动客户端: sudo ./start_client.sh hysteria2_client.json"
    echo "  3. 交互选择: ./switch_client.sh" 
    echo "  4. 测试连接: ./test_connection.sh"
    echo "  5. 查看指南: cat INSTALL_GUIDE.md"
    echo ""
    log_note "认证信息:"
    echo "  域名: ${DOMAIN}"
    echo "  密码: ${PASSWORD}"
    if [ "${VLESS_UUID}" != "your_vless_uuid_here" ]; then
        echo "  VLESS UUID: ${VLESS_UUID}"
    fi
    if [ "${VMESS_UUID}" != "your_vmess_uuid_here" ]; then
        echo "  VMess UUID: ${VMESS_UUID}"
    fi
    if [ "${TUIC_UUID}" != "your_tuic_uuid_here" ]; then
        echo "  TUIC UUID: ${TUIC_UUID}"
    fi
}

# 执行主函数
main