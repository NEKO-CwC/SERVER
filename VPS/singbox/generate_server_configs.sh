#!/bin/bash

# Sing-box 服务端配置生成器
# 生成不同协议的服务端配置文件

set -e

DOMAIN="284072.xyz"
CERT_PATH="/opt/ssl/${DOMAIN}/fullchain.pem"
KEY_PATH="/opt/ssl/${DOMAIN}/private.key"
PASSWORD="$(openssl rand -base64 24)"
CONFIG_DIR="./config"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# 创建配置目录
mkdir -p ${CONFIG_DIR}

# 生成通用密码文件
echo "${PASSWORD}" > ${CONFIG_DIR}/password.txt
log_info "生成的密码: ${PASSWORD}"

# 1. Hysteria2 配置
create_hysteria2_config() {
    log_info "生成 Hysteria2 服务端配置..."
    
    cat > ${CONFIG_DIR}/hysteria2.json << EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": 36712,
      "up_mbps": 1000,
      "down_mbps": 1000,
      "users": [
        {
          "name": "user",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "key_path": "${KEY_PATH}",
        "certificate_path": "${CERT_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 2. VLESS配置
create_vless_config() {
    log_info "生成 VLESS 服务端配置..."
    
    local uuid=$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    
    cat > ${CONFIG_DIR}/vless.json << EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "name": "user",
          "uuid": "${uuid}"
        }
      ],
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
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    
    echo "${uuid}" > ${CONFIG_DIR}/vless_uuid.txt
    log_info "VLESS UUID: ${uuid}"
}

# 3. VMess配置
create_vmess_config() {
    log_info "生成 VMess 服务端配置..."
    
    local uuid=$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    
    cat > ${CONFIG_DIR}/vmess.json << EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "name": "user",
          "uuid": "${uuid}",
          "alterId": 0
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "key_path": "${KEY_PATH}",
        "certificate_path": "${CERT_PATH}"
      },
      "transport": {
        "type": "ws",
        "path": "/vmess"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    
    echo "${uuid}" > ${CONFIG_DIR}/vmess_uuid.txt
    log_info "VMess UUID: ${uuid}"
}

# 4. Shadowsocks配置
create_shadowsocks_config() {
    log_info "生成 Shadowsocks 服务端配置..."
    
    cat > ${CONFIG_DIR}/shadowsocks.json << EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": 8388,
      "method": "chacha20-ietf-poly1305",
      "password": "${PASSWORD}",
      "multiplex": {
        "enabled": true,
        "padding": true
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 5. TUIC配置
create_tuic_config() {
    log_info "生成 TUIC 服务端配置..."
    
    local uuid=$(uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    
    cat > ${CONFIG_DIR}/tuic.json << EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "name": "user",
          "uuid": "${uuid}",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "key_path": "${KEY_PATH}",
        "certificate_path": "${CERT_PATH}"
      },
      "congestion_control": "bbr"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    
    echo "${uuid}" > ${CONFIG_DIR}/tuic_uuid.txt
    log_info "TUIC UUID: ${uuid}"
}

# 6. Trojan配置
create_trojan_config() {
    log_info "生成 Trojan 服务端配置..."
    
    cat > ${CONFIG_DIR}/trojan.json << EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "trojan",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "name": "user",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "key_path": "${KEY_PATH}",
        "certificate_path": "${CERT_PATH}"
      },
      "fallback": {
        "server": "127.0.0.1",
        "server_port": 80
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 7. Naive Proxy配置
create_naive_config() {
    log_info "生成 Naive 服务端配置..."
    
    cat > ${CONFIG_DIR}/naive.json << EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "naive",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "username": "user",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "key_path": "${KEY_PATH}",
        "certificate_path": "${CERT_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# 生成docker-compose文件
create_docker_compose() {
    log_info "生成 docker-compose 配置文件..."
    
    cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: sing-box
    restart: always
    volumes:
      - ./config/config.json:/etc/sing-box/config.json
      - /opt/ssl:/opt/ssl:ro
    command: -D /var/lib/sing-box -C /etc/sing-box/ run
    network_mode: host
    
  # 可选：添加监控
  # monitoring:
  #   image: prom/node-exporter
  #   container_name: node-exporter
  #   restart: always
  #   ports:
  #     - "9100:9100"
EOF
}

# 生成启动脚本
create_start_script() {
    log_info "生成服务启动脚本..."
    
    cat > start_proxy.sh << 'EOF'
#!/bin/bash

# Sing-box 服务启动脚本

CONFIG_FILE="${1:-hysteria2.json}"
CONFIG_DIR="./config"

if [ ! -f "${CONFIG_DIR}/${CONFIG_FILE}" ]; then
    echo "错误: 配置文件 ${CONFIG_DIR}/${CONFIG_FILE} 不存在"
    echo "可用配置:"
    ls ${CONFIG_DIR}/*.json 2>/dev/null | xargs -n1 basename
    exit 1
fi

echo "启动 sing-box 服务，使用配置: ${CONFIG_FILE}"

# 停止现有容器
docker-compose down 2>/dev/null || true

# 复制指定配置为config.json
cp "${CONFIG_DIR}/${CONFIG_FILE}" "${CONFIG_DIR}/config.json"

# 启动服务
docker-compose up -d

# 显示日志
echo "服务启动完成，查看日志:"
echo "docker-compose logs -f sing-box"

# 显示连接信息
echo ""
echo "连接信息:"
if [ -f "${CONFIG_DIR}/password.txt" ]; then
    echo "密码: $(cat ${CONFIG_DIR}/password.txt)"
fi

case ${CONFIG_FILE} in
    "vless.json")
        if [ -f "${CONFIG_DIR}/vless_uuid.txt" ]; then
            echo "UUID: $(cat ${CONFIG_DIR}/vless_uuid.txt)"
        fi
        echo "端口: 443"
        echo "传输: WebSocket"
        echo "路径: /vless"
        ;;
    "vmess.json")
        if [ -f "${CONFIG_DIR}/vmess_uuid.txt" ]; then
            echo "UUID: $(cat ${CONFIG_DIR}/vmess_uuid.txt)"
        fi
        echo "端口: 443"
        echo "传输: WebSocket"
        echo "路径: /vmess"
        ;;
    "hysteria2.json")
        echo "端口: 36712"
        echo "协议: Hysteria2"
        ;;
    "tuic.json")
        if [ -f "${CONFIG_DIR}/tuic_uuid.txt" ]; then
            echo "UUID: $(cat ${CONFIG_DIR}/tuic_uuid.txt)"
        fi
        echo "端口: 443"
        echo "协议: TUIC"
        ;;
    "shadowsocks.json")
        echo "端口: 8388"
        echo "加密: chacha20-ietf-poly1305"
        ;;
    "trojan.json")
        echo "端口: 443"
        echo "协议: Trojan"
        ;;
    "naive.json")
        echo "端口: 443"
        echo "协议: Naive"
        echo "用户名: user"
        ;;
esac
EOF
    
    chmod +x start_proxy.sh
}

# 生成配置切换脚本
create_switch_script() {
    log_info "生成配置切换脚本..."
    
    cat > switch_config.sh << 'EOF'
#!/bin/bash

# 配置切换脚本

CONFIG_DIR="./config"

echo "可用配置:"
configs=($(ls ${CONFIG_DIR}/*.json 2>/dev/null | xargs -n1 basename | grep -v config.json))

if [ ${#configs[@]} -eq 0 ]; then
    echo "没有找到配置文件"
    exit 1
fi

for i in "${!configs[@]}"; do
    echo "$((i+1)). ${configs[$i]}"
done

echo -n "请选择配置 (1-${#configs[@]}): "
read choice

if [ "$choice" -gt 0 ] && [ "$choice" -le "${#configs[@]}" ]; then
    selected_config="${configs[$((choice-1))]}"
    echo "切换到配置: ${selected_config}"
    ./start_proxy.sh "${selected_config}"
else
    echo "无效选择"
    exit 1
fi
EOF
    
    chmod +x switch_config.sh
}

# 创建配置信息文件
create_config_info() {
    log_info "生成配置信息文件..."
    
    cat > ${CONFIG_DIR}/server_info.json << EOF
{
  "domain": "${DOMAIN}",
  "cert_path": "${CERT_PATH}",
  "key_path": "${KEY_PATH}",
  "password": "${PASSWORD}",
  "configs": {
    "hysteria2": {
      "port": 36712,
      "protocol": "hysteria2"
    },
    "vless": {
      "port": 443,
      "protocol": "vless",
      "transport": "ws",
      "path": "/vless",
      "uuid": "$(cat ${CONFIG_DIR}/vless_uuid.txt 2>/dev/null || echo 'N/A')"
    },
    "vmess": {
      "port": 443,
      "protocol": "vmess",
      "transport": "ws", 
      "path": "/vmess",
      "uuid": "$(cat ${CONFIG_DIR}/vmess_uuid.txt 2>/dev/null || echo 'N/A')"
    },
    "shadowsocks": {
      "port": 8388,
      "protocol": "shadowsocks",
      "method": "chacha20-ietf-poly1305"
    },
    "tuic": {
      "port": 443,
      "protocol": "tuic",
      "uuid": "$(cat ${CONFIG_DIR}/tuic_uuid.txt 2>/dev/null || echo 'N/A')"
    },
    "trojan": {
      "port": 443,
      "protocol": "trojan"
    },
    "naive": {
      "port": 443,
      "protocol": "naive",
      "username": "user"
    }
  },
  "generated_at": "$(date -Iseconds)"
}
EOF
}

# 主函数
main() {
    log_info "开始生成 Sing-box 服务端配置..."
    
    # 检查证书文件
    if [ ! -f "${CERT_PATH}" ] || [ ! -f "${KEY_PATH}" ]; then
        log_warn "证书文件不存在，请先运行证书申请脚本"
        log_warn "证书路径: ${CERT_PATH}"
        log_warn "私钥路径: ${KEY_PATH}"
    fi
    
    # 生成所有配置
    create_hysteria2_config
    create_vless_config
    create_vmess_config
    create_shadowsocks_config
    create_tuic_config
    create_trojan_config
    create_naive_config
    
    # 生成管理脚本
    create_docker_compose
    create_start_script
    create_switch_script
    create_config_info
    
    log_info "所有配置文件生成完成！"
    echo ""
    echo "使用方法:"
    echo "1. 启动指定协议: ./start_proxy.sh hysteria2.json"
    echo "2. 交互式切换: ./switch_config.sh"
    echo "3. 查看日志: docker-compose logs -f"
    echo "4. 停止服务: docker-compose down"
    echo ""
    echo "配置文件位置: ${CONFIG_DIR}/"
    echo "服务器信息: ${CONFIG_DIR}/server_info.json"
}

# 执行主函数
main