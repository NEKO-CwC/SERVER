#!/bin/bash

# 域名证书自动申请脚本
# 使用 acme.sh 和 nginx docker 为 284072.xyz 申请证书


# 从 flag 中获取域名
DOMAIN=""
EMAIL="admin@${DOMAIN}"
CERT_DIR="/opt/ssl/${DOMAIN}"
NGINX_WEBROOT="/opt/nginx/html"

while getopts "d:h:" opt; do
    case $opt in
        d)
            DOMAIN=$OPTARG
            ;;
        h)
            echo "Usage: $0 -d <domain>"
            return 0
            ;;
        *)
            echo "Invalid option: -$OPTARG"
            return 1
            ;;
    esac
done

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 安装必要软件
install_dependencies() {
    log_info "安装必要依赖..."
    
    # 更新包管理器
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y curl socat cron docker.io docker-compose
    elif command -v yum >/dev/null 2>&1; then
        yum update -y
        yum install -y curl socat cronie docker docker-compose
        systemctl enable crond
        systemctl start crond
    else
        log_error "不支持的操作系统"
        exit 1
    fi
    
    # 启动docker服务
    systemctl enable docker
    systemctl start docker
}

# 安装 acme.sh
install_acme() {
    log_info "安装 acme.sh..."
    
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email=${EMAIL}
        source ~/.bashrc
    else
        log_info "acme.sh 已经安装"
    fi
}

# 创建必要目录
create_directories() {
    log_info "创建必要目录..."
    
    mkdir -p ${CERT_DIR}
    mkdir -p ${NGINX_WEBROOT}
    mkdir -p /opt/nginx/conf
    mkdir -p ./config  # sing-box配置目录
}

# 创建nginx配置
create_nginx_config() {
    log_info "创建 nginx 配置..."
    
    cat > /opt/nginx/conf/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                   '$status $body_bytes_sent "$http_referer" '
                   '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    server {
        listen 80;
        server_name 284072.xyz;
        
        location /.well-known/acme-challenge/ {
            root /usr/share/nginx/html;
        }
        
        location / {
            return 301 https://$server_name$request_uri;
        }
    }
    
    server {
        listen 443 ssl http2;
        server_name 284072.xyz;
        
        ssl_certificate /etc/ssl/284072.xyz/fullchain.pem;
        ssl_certificate_key /etc/ssl/284072.xyz/private.key;
        
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers off;
        
        location / {
            root /usr/share/nginx/html;
            index index.html;
        }
    }
}
EOF

    # 创建简单的index页面
    cat > ${NGINX_WEBROOT}/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>284072.xyz</title>
</head>
<body>
    <h1>Welcome to 284072.xyz</h1>
    <p>Server is running normally.</p>
</body>
</html>
EOF
}

# 启动nginx容器进行证书验证
start_nginx_for_cert() {
    log_info "启动 nginx 容器进行证书验证..."
    
    # 停止可能存在的nginx容器
    docker stop nginx-cert 2>/dev/null || true
    docker rm nginx-cert 2>/dev/null || true
    
    # 启动nginx容器（仅HTTP，用于证书验证）
    docker run -d \
        --name nginx-cert \
        -p 80:80 \
        -v ${NGINX_WEBROOT}:/usr/share/nginx/html:ro \
        nginx:alpine
    
    # 等待nginx启动
    sleep 5
}

# 申请SSL证书
request_certificate() {
    log_info "申请 SSL 证书..."
    
    # 使用webroot模式申请证书
    ~/.acme.sh/acme.sh --issue \
        -d ${DOMAIN} \
        --webroot ${NGINX_WEBROOT} \
        --force
    
    # 安装证书到指定目录
    ~/.acme.sh/acme.sh --install-cert \
        -d ${DOMAIN} \
        --key-file ${CERT_DIR}/private.key \
        --fullchain-file ${CERT_DIR}/fullchain.pem \
        --reloadcmd "docker restart nginx-ssl 2>/dev/null || true"
    
    # 设置证书文件权限
    chmod 600 ${CERT_DIR}/private.key
    chmod 644 ${CERT_DIR}/fullchain.pem
}

# 启动完整的nginx服务
start_nginx_ssl() {
    log_info "启动支持SSL的nginx服务..."
    
    # 停止临时nginx容器
    docker stop nginx-cert 2>/dev/null || true
    docker rm nginx-cert 2>/dev/null || true
    
    # 停止可能存在的SSL nginx容器
    docker stop nginx-ssl 2>/dev/null || true
    docker rm nginx-ssl 2>/dev/null || true
    
    # 启动支持SSL的nginx容器
    docker run -d \
        --name nginx-ssl \
        --restart always \
        -p 80:80 \
        -p 443:443 \
        -v /opt/nginx/conf/nginx.conf:/etc/nginx/nginx.conf:ro \
        -v ${NGINX_WEBROOT}:/usr/share/nginx/html:ro \
        -v ${CERT_DIR}:/etc/ssl/284072.xyz:ro \
        nginx:alpine
    
    log_info "nginx SSL 服务启动完成"
}

# 设置证书自动续期
setup_auto_renewal() {
    log_info "设置证书自动续期..."
    
    # 创建续期脚本
    cat > /opt/renew_cert.sh << 'EOF'
#!/bin/bash
/root/.acme.sh/acme.sh --cron --home /root/.acme.sh
EOF
    
    chmod +x /opt/renew_cert.sh
    
    # 添加cron任务
    (crontab -l 2>/dev/null; echo "0 2 * * * /opt/renew_cert.sh >> /var/log/acme_renewal.log 2>&1") | crontab -
    
    log_info "证书自动续期设置完成"
}

# 验证证书
verify_certificate() {
    log_info "验证证书安装..."
    
    if [ -f "${CERT_DIR}/fullchain.pem" ] && [ -f "${CERT_DIR}/private.key" ]; then
        log_info "证书文件存在"
        
        # 检查证书有效期
        cert_expiry=$(openssl x509 -in ${CERT_DIR}/fullchain.pem -noout -dates | grep "notAfter" | cut -d= -f2)
        log_info "证书有效期至: ${cert_expiry}"
        
        # 测试HTTPS连接
        if curl -s -o /dev/null -w "%{http_code}" https://${DOMAIN} | grep -q "200\|301\|302"; then
            log_info "HTTPS 连接测试成功"
            return 0
        else
            log_warn "HTTPS 连接测试失败，但证书文件存在"
            return 1
        fi
    else
        log_error "证书文件不存在"
        return 1
    fi
}

# 创建证书信息文件
create_cert_info() {
    log_info "创建证书信息文件..."
    
    cat > ./cert_info.json << EOF
{
    "domain": "${DOMAIN}",
    "cert_path": "${CERT_DIR}/fullchain.pem",
    "key_path": "${CERT_DIR}/private.key",
    "installation_date": "$(date -Iseconds)",
    "auto_renewal": true
}
EOF
    
    log_info "证书信息已保存到 ./cert_info.json"
}

# 主函数
main() {
    log_info "开始为域名 ${DOMAIN} 申请SSL证书..."
    
    check_root
    install_dependencies
    install_acme
    create_directories
    create_nginx_config
    start_nginx_for_cert
    
    # 等待DNS解析生效
    log_info "等待DNS解析生效..."
    sleep 10
    
    request_certificate
    start_nginx_ssl
    setup_auto_renewal
    
    if verify_certificate; then
        create_cert_info
        log_info "证书申请和配置完成！"
        log_info "证书路径: ${CERT_DIR}/fullchain.pem"
        log_info "私钥路径: ${CERT_DIR}/private.key"
        log_info "网站已可通过 https://${DOMAIN} 访问"
    else
        log_error "证书验证失败，请检查配置"
        exit 1
    fi
}

# 脚本参数处理
case "${1:-}" in
    "setup")
        while getopts "d:h:" opt; do
            case $opt in
                d)
                    DOMAIN=$OPTARG
                    main
                    ;;
                h)
                    echo "Usage: $0 setup -d <domain>"
                    return 0
                    ;;
                *)
                    echo "Invalid option: -$OPTARG"
                    return 1
                    ;;
            esac
        done
        ;;
    "renew")
        log_info "手动续期证书..."
        ~/.acme.sh/acme.sh --cron --force
        ;;
    "status")
        verify_certificate
        ;;
    "clean")
        log_info "清理nginx容器..."
        docker stop nginx-ssl nginx-cert 2>/dev/null || true
        docker rm nginx-ssl nginx-cert 2>/dev/null || true
        ;;
    *)
        echo "用法: $0 [renew|status|clean]"
        echo "  无参数: 申请新证书"
        echo "  renew: 手动续期证书"
        echo "  status: 检查证书状态"
        echo "  clean: 清理nginx容器"
        exit 1
        ;;
esac