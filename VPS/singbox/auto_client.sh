#!/bin/bash

# Sing-box 客户端一键部署脚本
# 支持 macOS 和 Linux 系统
# 专用于客户端部署，包含配置生成、服务启动、协议切换

# 服务器配置信息
SERVER_DOMAIN="284072.xyz"
SERVER_PASSWORD="PXFZLFsaa338x99I+2lplolbLPef17A0"

# 项目配置
PROJECT_DIR="./singbox-client"
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
║           Sing-box 客户端自动部署                ║
║     支持多协议代理客户端一键安装配置             ║
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

detect_os() {
    log_step "检测操作系统..."
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        log_info "检测到 macOS 系统"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
        log_info "检测到 Linux 系统"
    else
        log_error "不支持的操作系统: $OSTYPE"
        return 1
    fi
    
    # 检查架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) log_warn "可能不支持的架构: $ARCH" ;;
    esac
    
    log_info "系统架构: $ARCH"
}

check_root_privileges() {
    log_step "检查系统权限..."
    
    if [[ $EUID -eq 0 ]]; then
        log_warn "检测到 root 权限，将自动处理权限相关操作"
        SUDO_CMD=""
    else
        # 检查是否可以使用 sudo
        if command -v sudo >/dev/null 2>&1; then
            SUDO_CMD="sudo"
            log_info "将使用 sudo 执行特权操作"
        else
            log_error "需要 sudo 权限进行系统级安装，请安装 sudo 或使用 root 用户运行"
            return 1
        fi
    fi
}

install_dependencies() {
    log_step "安装必要依赖..."
    
    # 检查并安装 Docker
    if ! command -v docker >/dev/null 2>&1; then
        log_info "安装 Docker..."
        
        if [[ "$OS" == "macos" ]]; then
            # macOS 使用 Homebrew 安装 Docker
            if ! command -v brew >/dev/null 2>&1; then
                log_info "安装 Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            brew install --cask docker
        elif [[ "$OS" == "linux" ]]; then
            # Linux 安装 Docker
            if command -v apt-get >/dev/null 2>&1; then
                $SUDO_CMD apt-get update
                $SUDO_CMD apt-get install -y ca-certificates curl gnupg lsb-release
                $SUDO_CMD mkdir -p /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO_CMD gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | $SUDO_CMD tee /etc/apt/sources.list.d/docker.list > /dev/null
                $SUDO_CMD apt-get update
                $SUDO_CMD apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            elif command -v yum >/dev/null 2>&1; then
                $SUDO_CMD yum install -y yum-utils
                $SUDO_CMD yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                $SUDO_CMD yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            elif command -v dnf >/dev/null 2>&1; then
                $SUDO_CMD dnf install -y dnf-plugins-core
                $SUDO_CMD dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
                $SUDO_CMD dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            else
                log_error "不支持的 Linux 发行版"
                return 1
            fi
            
            # 启动 Docker 服务
            $SUDO_CMD systemctl enable docker
            $SUDO_CMD systemctl start docker
            
            # 添加当前用户到 docker 组
            if [[ -n "$SUDO_CMD" ]]; then
                $SUDO_CMD usermod -aG docker $USER
                log_warn "用户已添加到 docker 组，请重新登录或运行 'newgrp docker'"
            fi
        fi
    else
        log_info "Docker 已安装"
    fi
    
    # 检查并安装 Docker Compose
    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        log_info "安装 Docker Compose..."
        
        if [[ "$OS" == "macos" ]]; then
            brew install docker-compose
        elif [[ "$OS" == "linux" ]]; then
            COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d'"' -f4)
            $SUDO_CMD curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            $SUDO_CMD chmod +x /usr/local/bin/docker-compose
        fi
    else
        log_info "Docker Compose 已安装"
    fi
    
    # 安装其他必要工具
    local tools=("curl" "jq")
    for tool in "${tools[@]}"; do
        if ! command -v $tool >/dev/null 2>&1; then
            log_info "安装 $tool..."
            
            if [[ "$OS" == "macos" ]]; then
                brew install $tool
            elif [[ "$OS" == "linux" ]]; then
                if command -v apt-get >/dev/null 2>&1; then
                    $SUDO_CMD apt-get install -y $tool
                elif command -v yum >/dev/null 2>&1; then
                    $SUDO_CMD yum install -y $tool
                elif command -v dnf >/dev/null 2>&1; then
                    $SUDO_CMD dnf install -y $tool
                fi
            fi
        fi
    done
    
    # 验证安装
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker 安装失败"
        return 1
    fi
    
    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose 安装失败"
        return 1
    fi
    
    log_success "依赖安装完成"
}

setup_project_structure() {
    log_step "创建项目目录结构..."
    
    mkdir -p ${PROJECT_DIR}/{config,logs,scripts}
    cd ${PROJECT_DIR}
    
    log_info "项目目录: $(pwd)"
}

generate_base_config_template() {
    # 生成基础配置模板
    cat > ./config/base_template.json << 'EOF'
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
                "proxy"
            ],
            "interrupt_exist_connections": true
        },
        "__PROXY_CONFIG__",
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

generate_client_configs() {
    log_step "生成客户端配置文件..."
    
    generate_base_config_template
    
    # 1. Hysteria2 配置
    cat > ./config/hysteria2.json << EOF
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
                "proxy"
            ],
            "interrupt_exist_connections": true
        },
        {
            "type": "hysteria2",
            "tag": "proxy",
            "server": "${SERVER_DOMAIN}",
            "server_port": 36712,
            "up_mbps": 1000,
            "down_mbps": 1000,
            "password": "${SERVER_PASSWORD}",
            "tls": {
                "enabled": true,
                "server_name": "${SERVER_DOMAIN}"
            }
        },
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

    # 2. VLESS 配置
    cat > ./config/vless.json << EOF
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
                "proxy"
            ],
            "interrupt_exist_connections": true
        },
        {
            "type": "vless",
            "tag": "proxy",
            "server": "${SERVER_DOMAIN}",
            "server_port": 8443,
            "uuid": "3025aff0-c888-05cd-d826-b55ef6d0e234",
            "tls": {
                "enabled": true,
                "server_name": "${SERVER_DOMAIN}"
            },
            "transport": {
                "type": "ws",
                "path": "/vless",
                "early_data_header_name": "Sec-WebSocket-Protocol"
            }
        },
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

    # 3. VMess 配置
    cat > ./config/vmess.json << EOF
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
                "proxy"
            ],
            "interrupt_exist_connections": true
        },
        {
            "type": "vmess",
            "tag": "proxy",
            "server": "${SERVER_DOMAIN}",
            "server_port": 8444,
            "uuid": "2c938318-238e-9c58-8b2a-e5f603fd0631",
            "security": "auto",
            "alter_id": 0,
            "tls": {
                "enabled": true,
                "server_name": "${SERVER_DOMAIN}"
            },
            "transport": {
                "type": "ws",
                "path": "/vmess"
            }
        },
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

    # 4. Shadowsocks 配置
    cat > ./config/shadowsocks.json << EOF
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
                "proxy"
            ],
            "interrupt_exist_connections": true
        },
        {
            "type": "shadowsocks",
            "tag": "proxy",
            "server": "${SERVER_DOMAIN}",
            "server_port": 8388,
            "method": "chacha20-ietf-poly1305",
            "password": "${SERVER_PASSWORD}",
            "multiplex": {
                "enabled": true,
                "padding": true
            }
        },
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

    # 5. TUIC 配置
    cat > ./config/tuic.json << EOF
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
                "proxy"
            ],
            "interrupt_exist_connections": true
        },
        {
            "type": "tuic",
            "tag": "proxy",
            "server": "${SERVER_DOMAIN}",
            "server_port": 8445,
            "uuid": "b225a557-4547-2d15-3a27-0940072b24c3",
            "password": "${SERVER_PASSWORD}",
            "congestion_control": "bbr",
            "tls": {
                "enabled": true,
                "server_name": "${SERVER_DOMAIN}"
            }
        },
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

    # 6. Trojan 配置
    cat > ./config/trojan.json << EOF
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
                "proxy"
            ],
            "interrupt_exist_connections": true
        },
        {
            "type": "trojan",
            "tag": "proxy",
            "server": "${SERVER_DOMAIN}",
            "server_port": 8446,
            "password": "${SERVER_PASSWORD}",
            "tls": {
                "enabled": true,
                "server_name": "${SERVER_DOMAIN}"
            }
        },
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

    # 保存客户端信息
    cat > ./config/client_info.json << EOF
{
    "server_domain": "${SERVER_DOMAIN}",
    "server_password": "${SERVER_PASSWORD}",
    "supported_protocols": [
        "hysteria2",
        "vless",
        "vmess",
        "shadowsocks",
        "tuic",
        "trojan"
    ],
    "clash_api": "http://127.0.0.1:9090",
    "generated_at": "$(date -Iseconds)"
}
EOF

    log_success "客户端配置生成完成"
}

create_docker_compose() {
    log_step "创建Docker Compose配置..."
    
    cat > ./docker-compose.yml << 'EOF'
version: '3.8'

services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: sing-box
    restart: always
    volumes:
      - ./config/config.json:/etc/sing-box/config.json
    command: -D /var/lib/sing-box -C /etc/sing-box/ run
    network_mode: host
    privileged: true
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    log_success "Docker Compose 配置创建完成"
}

create_management_scripts() {
    log_step "创建管理脚本..."
    
    # 启动脚本
    cat > ./scripts/start_client.sh << 'EOF'
#!/bin/bash

CONFIG_FILE="${1:-hysteria2.json}"
CONFIG_DIR="./config"

cd "$(dirname "$0")/.."

if [ ! -f "${CONFIG_DIR}/${CONFIG_FILE}" ]; then
    echo "错误: 配置文件 ${CONFIG_DIR}/${CONFIG_FILE} 不存在"
    echo "可用配置:"
    ls ${CONFIG_DIR}/*.json 2>/dev/null | grep -v base_template.json | grep -v client_info.json | xargs -n1 basename
    return 1
fi

echo "启动客户端，使用配置: ${CONFIG_FILE}"

# 停止现有容器
if command -v docker-compose >/dev/null 2>&1; then
    docker-compose down 2>/dev/null || true
else
    docker compose down 2>/dev/null || true
fi

# 复制指定配置
cp "${CONFIG_DIR}/${CONFIG_FILE}" "${CONFIG_DIR}/config.json"

# 启动服务
if command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d
else
    docker compose up -d
fi

echo "客户端启动完成"
echo "查看日志: ./scripts/manage_client.sh logs"
echo "Clash API: http://127.0.0.1:9090"

# 显示协议信息
protocol=$(echo ${CONFIG_FILE} | cut -d'.' -f1)
echo "当前协议: ${protocol}"
EOF

    # 管理脚本
    cat > ./scripts/manage_client.sh << 'EOF'
#!/bin/bash

cd "$(dirname "$0")/.."

case "${1:-}" in
    "start")
        shift
        bash ./scripts/start_client.sh $@
        ;;
    "stop")
        if command -v docker-compose >/dev/null 2>&1; then
            docker-compose down
        else
            docker compose down
        fi
        echo "客户端已停止"
        ;;
    "restart")
        if command -v docker-compose >/dev/null 2>&1; then
            docker-compose restart
        else
            docker compose restart
        fi
        echo "客户端已重启"
        ;;
    "status")
        if command -v docker-compose >/dev/null 2>&1; then
            docker-compose ps
        else
            docker compose ps
        fi
        echo ""
        echo "TUN 接口状态:"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            ifconfig | grep -A 3 "tun"
        else
            ip addr show | grep -A 3 "tun"
        fi
        ;;
    "logs")
        if command -v docker-compose >/dev/null 2>&1; then
            docker-compose logs -f --tail=100
        else
            docker compose logs -f --tail=100
        fi
        ;;
    "switch")
        echo "可用协议配置:"
        configs=($(ls config/*.json | grep -v base_template.json | grep -v client_info.json | xargs -n1 basename))
        for i in "${!configs[@]}"; do
            protocol=$(echo "${configs[$i]}" | cut -d'.' -f1)
            echo "$((i+1)). ${protocol}"
        done
        echo -n "选择协议 (1-${#configs[@]}): "
        read choice
        if [ "$choice" -gt 0 ] && [ "$choice" -le "${#configs[@]}" ]; then
            bash ./scripts/start_client.sh "${configs[$((choice-1))]}"
        fi
        ;;
    "info")
        if [ -f "config/client_info.json" ]; then
            echo "客户端信息:"
            if command -v jq >/dev/null 2>&1; then
                cat config/client_info.json | jq '.'
            else
                cat config/client_info.json
            fi
        fi
        echo ""
        echo "Clash Dashboard: http://127.0.0.1:9090/ui"
        ;;
    "test")
        echo "测试网络连接..."
        echo "检测 IP 地址:"
        curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null || echo "连接失败"
        echo ""
        echo "检测 Google 连通性:"
        curl -s --max-time 5 -o /dev/null -w "%{http_code}" https://www.google.com || echo "连接失败"
        echo ""
        ;;
    *)
        echo "Sing-box 客户端管理"
        echo "用法: $0 {start [protocol]|stop|restart|status|logs|switch|info|test}"
        echo ""
        echo "示例:"
        echo "  $0 start hysteria2.json  # 启动指定协议"
        echo "  $0 switch                # 交互式切换协议"
        echo "  $0 test                  # 测试网络连接"
        echo "  $0 status                # 查看运行状态"
        echo ""
        echo "可用协议:"
        ls config/*.json 2>/dev/null | grep -v base_template.json | grep -v client_info.json | xargs -n1 basename | sed 's/.json//' | sort
        return 0
        ;;
esac
EOF

    chmod +x ./scripts/start_client.sh
    chmod +x ./scripts/manage_client.sh
    
    log_success "管理脚本创建完成"
}

deploy_client() {
    log_step "选择并启动客户端协议..."
    
    echo "可用协议配置:"
    configs=($(ls config/*.json | grep -v base_template.json | grep -v client_info.json | xargs -n1 basename))
    
    for i in "${!configs[@]}"; do
        protocol=$(echo "${configs[$i]}" | cut -d'.' -f1)
        echo "$((i+1)). $protocol"
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
        bash ./scripts/start_client.sh "$selected_config"
        
        # 等待服务启动
        sleep 3
        
        # 检查服务状态
        if command -v docker-compose >/dev/null 2>&1; then
            container_status=$(docker-compose ps 2>/dev/null)
        else
            container_status=$(docker compose ps 2>/dev/null)
        fi
        
        if echo "$container_status" | grep -q "Up"; then
            log_success "协议 $protocol 启动成功"
            
            echo ""
            echo "=== 连接信息 ==="
            echo "服务器: ${SERVER_DOMAIN}"
            echo "协议: ${protocol}"
            echo "Clash API: http://127.0.0.1:9090"
            echo ""
            echo "管理命令:"
            echo "  查看状态: ./scripts/manage_client.sh status"
            echo "  切换协议: ./scripts/manage_client.sh switch"
            echo "  查看日志: ./scripts/manage_client.sh logs"
            echo "  测试连接: ./scripts/manage_client.sh test"
            
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

show_deployment_result() {
    echo -e "${GREEN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════╗
║               客户端部署完成！                   ║
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    echo "项目目录: $(pwd)"
    echo "管理脚本: ./scripts/manage_client.sh"
    echo ""
    echo "快速操作:"
    echo "  启动客户端: ./scripts/manage_client.sh start [protocol]"
    echo "  切换协议: ./scripts/manage_client.sh switch"
    echo "  查看状态: ./scripts/manage_client.sh status"
    echo "  测试连接: ./scripts/manage_client.sh test"
    echo "  查看日志: ./scripts/manage_client.sh logs"
    echo ""
    echo "Clash Dashboard: http://127.0.0.1:9090"
    echo ""
    echo "支持的协议: hysteria2, vless, vmess, shadowsocks, tuic, trojan"
    
    if [[ "$OS" == "macos" ]]; then
        echo ""
        echo "macOS 特别提示:"
        echo "1. 首次运行可能需要授权网络权限"
        echo "2. 如遇权限问题，请在系统偏好设置中允许"
        echo "3. TUN 模式需要管理员权限"
    elif [[ "$OS" == "linux" ]]; then
        echo ""
        echo "Linux 特别提示:"
        echo "1. TUN 模式需要 root 权限或 CAP_NET_ADMIN 能力"
        echo "2. 确保内核支持 TUN/TAP 设备"
        echo "3. 如遇权限问题，请使用 sudo 运行"
    fi
}

delete_all() {
    log_step "删除所有文件..."
    
    # 停止服务
    cd ${PROJECT_DIR} 2>/dev/null || true
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose down 2>/dev/null || true
    else
        docker compose down 2>/dev/null || true
    fi
    
    # 删除容器和镜像
    docker stop sing-box 2>/dev/null || true
    docker rm sing-box 2>/dev/null || true
    
    # 返回上级目录并删除项目目录
    cd ..
    rm -rf ${PROJECT_DIR}
    
    log_success "所有文件已删除"
}

main() {
    show_banner
    
    log_info "开始部署 Sing-box 客户端"
    log_info "服务器: ${SERVER_DOMAIN}"
    
    echo -n "确认开始部署? (y/N): "
    read confirm
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        log_info "部署已取消"
        return 0
    fi
    
    if ! detect_os; then
        return 1
    fi
    
    if ! check_root_privileges; then
        return 1
    fi
    
    if ! install_dependencies; then
        return 1
    fi
    
    setup_project_structure
    generate_client_configs
    create_docker_compose
    create_management_scripts
    
    if deploy_client; then
        show_deployment_result
        log_success "客户端部署完成！"
    else
        log_error "客户端部署失败"
        return 1
    fi
}

# 主程序入口
case "${1:-}" in
    "")
        main
        ;;
    "delete")
        delete_all
        ;;
    "switch")
        if [[ -d "${PROJECT_DIR}" ]]; then
            cd ${PROJECT_DIR}
            bash ./scripts/manage_client.sh switch
        else
            log_error "客户端未安装"
        fi
        ;;
    "status")
        if [[ -d "${PROJECT_DIR}" ]]; then
            cd ${PROJECT_DIR}
            bash ./scripts/manage_client.sh status
        else
            log_error "客户端未安装"
        fi
        ;;
    "test")
        if [[ -d "${PROJECT_DIR}" ]]; then
            cd ${PROJECT_DIR}
            bash ./scripts/manage_client.sh test
        else
            log_error "客户端未安装"
        fi
        ;;
    *)
        echo "Sing-box 客户端一键部署脚本"
        echo "用法: $0 [delete|switch|status|test]"
        echo ""
        echo "  无参数   - 执行完整部署"
        echo "  delete   - 删除所有文件"
        echo "  switch   - 切换协议"
        echo "  status   - 查看状态"
        echo "  test     - 测试连接"
        return 0
        ;;
esac