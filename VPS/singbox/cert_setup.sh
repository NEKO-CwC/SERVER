#!/bin/bash

# 域名证书自动申请脚本 v2.1
# 使用 acme.sh 和 nginx docker 为指定域名申请证书
# 
# 新增功能：
# - 环境重置功能，解决多次运行造成的环境污染
# - 改进的错误处理和用户交互
# - 现代化的nginx配置（支持HTTP/2）
# - 详细的调试模式和日志记录
# - 灵活的日志文件配置
#
# 使用方法：
#   ./script.sh setup -d example.com                        # 申请证书
#   ./script.sh setup -d example.com --force-reset          # 强制重置后申请证书
#   ./script.sh setup -d example.com --debug                # 启用调试模式
#   ./script.sh setup -d example.com --debug --log-file /tmp/ssl.log  # 自定义日志文件
#   ./script.sh reset                                       # 完全重置环境
#   ./script.sh status                                      # 检查证书状态
#
# 作者: Claude AI
# 更新时间: 2025-07-23

# 脚本版本
VERSION="2.1"

# 默认值
DOMAIN=""
DEBUG_MODE=false
LOG_FILE=""
SCRIPT_LOG="/var/log/ssl_setup.log"

# 显示版本信息
show_version() {
    echo "SSL证书申请脚本 v${VERSION}"
    echo "支持调试模式和环境重置功能"
}

# 显示帮助信息
show_help() {
    show_version
    echo
    echo "用法: $0 <command> [options]"
    echo
    echo "命令:"
    echo "  setup -d <domain>  申请新证书 (必须指定域名)"
    echo "  renew             手动续期证书"
    echo "  status            检查证书状态"
    echo "  clean             清理nginx容器"
    echo "  reset             完全重置环境 (慎用！)"
    echo
    echo "选项:"
    echo "  -d <domain>       指定域名 (仅用于 setup 命令)"
    echo "  -h               显示此帮助信息"
    echo "  -v, --version    显示版本信息"
    echo "  --force-reset     在setup时强制重置环境"
    echo "  --debug          启用详细调试模式"
    echo "  --log-file <file> 指定日志文件路径"
    echo
    echo "示例:"
    echo "  $0 setup -d example.com"
    echo "  $0 setup -d example.com --force-reset"
    echo "  $0 setup -d example.com --debug"
    echo "  $0 setup -d example.com --debug --log-file /tmp/ssl.log"
    echo "  $0 reset"
    echo
    echo "日志位置:"
    echo "  默认脚本日志: /var/log/ssl_setup.log"
    echo "  ACME日志: /var/log/acme_<domain>.log"
    echo "  自定义日志: 通过 --log-file 指定"
}

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    local msg="[INFO] $1"
    echo -e "${GREEN}${msg}${NC}"
    
    # 写入日志文件
    if [ -n "$LOG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$LOG_FILE"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$SCRIPT_LOG"
}

log_warn() {
    local msg="[WARN] $1"
    echo -e "${YELLOW}${msg}${NC}"
    
    # 写入日志文件
    if [ -n "$LOG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$LOG_FILE"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$SCRIPT_LOG"
}

log_error() {
    local msg="[ERROR] $1"
    echo -e "${RED}${msg}${NC}"
    
    # 写入日志文件
    if [ -n "$LOG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$LOG_FILE"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$SCRIPT_LOG"
}

log_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        local msg="[DEBUG] $1"
        echo -e "\033[0;36m${msg}${NC}"
        
        # 写入日志文件
        if [ -n "$LOG_FILE" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$LOG_FILE"
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" >> "$SCRIPT_LOG"
    fi
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        return 1
    fi
}

# 重置环境函数
reset_environment() {
    local domain_param="${1:-}"
    
    log_warn "开始重置环境..."
    log_warn "这将清理所有相关的容器、证书和配置文件！"
    
    # 如果没有指定域名，询问用户是否确认
    if [ -z "$domain_param" ]; then
        echo -n "是否确认要重置整个环境？这将删除所有证书和配置！(y/N): "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "取消重置操作"
            return 0
        fi
    fi
    
    # 1. 停止并删除所有相关Docker容器
    log_info "停止并删除Docker容器..."
    docker stop nginx-ssl nginx-cert 2>/dev/null || true
    docker rm nginx-ssl nginx-cert 2>/dev/null || true
    
    # 删除可能存在的其他nginx容器
    docker ps -a | grep nginx | awk '{print $1}' | xargs -r docker stop 2>/dev/null || true
    docker ps -a | grep nginx | awk '{print $1}' | xargs -r docker rm 2>/dev/null || true
    
    # 2. 清理证书目录
    log_info "清理证书目录..."
    if [ -n "$domain_param" ]; then
        # 只清理指定域名的证书
        rm -rf "/opt/ssl/${domain_param}" 2>/dev/null || true
        log_info "已清理域名 ${domain_param} 的证书文件"
    else
        # 清理所有证书
        rm -rf /opt/ssl/* 2>/dev/null || true
        log_info "已清理所有证书文件"
    fi
    
    # 3. 清理nginx配置
    log_info "清理nginx配置..."
    rm -rf /opt/nginx/conf/* 2>/dev/null || true
    rm -rf /opt/nginx/html/* 2>/dev/null || true
    
    # 4. 清理acme.sh域名配置
    log_info "清理acme.sh配置..."
    if [ -n "$domain_param" ]; then
        # 只清理指定域名
        rm -rf "/root/.acme.sh/${domain_param}" 2>/dev/null || true
        rm -rf "/root/.acme.sh/${domain_param}_ecc" 2>/dev/null || true
        log_info "已清理域名 ${domain_param} 的acme.sh配置"
    else
        # 清理所有域名配置（保留acme.sh主程序）
        find /root/.acme.sh -maxdepth 1 -type d -name "*.*" -exec rm -rf {} \; 2>/dev/null || true
        log_info "已清理所有域名的acme.sh配置"
    fi
    
    # 5. 清理cron任务
    log_info "清理cron任务..."
    # 删除包含acme或证书续期的cron任务
    (crontab -l 2>/dev/null | grep -v "acme\|renew_cert\|ssl") | crontab - 2>/dev/null || true
    
    # 6. 清理续期脚本
    log_info "清理续期脚本..."
    rm -f /opt/renew_cert.sh 2>/dev/null || true
    
    # 7. 清理日志文件
    log_info "清理日志文件..."
    rm -f /var/log/acme_renewal.log 2>/dev/null || true
    
    # 8. 清理其他配置文件
    log_info "清理其他配置文件..."
    rm -f ./cert_info.json 2>/dev/null || true
    rm -rf ./config 2>/dev/null || true
    
    # 9. 清理可能的临时文件
    log_info "清理临时文件..."
    rm -rf /tmp/acme* 2>/dev/null || true
    rm -rf /tmp/nginx* 2>/dev/null || true
    
    # 10. 重置防火墙规则（可选）
    if command -v ufw >/dev/null 2>&1; then
        log_info "重置UFW防火墙规则..."
        ufw --force reset 2>/dev/null || true
        ufw --force enable 2>/dev/null || true
        ufw allow ssh 2>/dev/null || true
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
    fi
    
    # 11. 清理Docker网络（如果有自定义网络）
    log_info "清理Docker网络..."
    docker network ls | grep -E "(nginx|ssl|cert)" | awk '{print $1}' | xargs -r docker network rm 2>/dev/null || true
    
    # 12. 清理Docker volumes（如果有）
    log_info "清理Docker volumes..."
    docker volume ls | grep -E "(nginx|ssl|cert)" | awk '{print $2}' | xargs -r docker volume rm 2>/dev/null || true
    
    log_info "环境重置完成！"
    
    # 验证清理结果
    log_info "验证清理结果..."
    
    # 检查容器
    if docker ps -a | grep -E "(nginx|ssl|cert)" >/dev/null 2>&1; then
        log_warn "仍有相关容器存在"
    else
        log_info "✓ 所有相关容器已清理"
    fi
    
    # 检查证书目录
    if [ -n "$domain_param" ]; then
        if [ -d "/opt/ssl/${domain_param}" ]; then
            log_warn "域名 ${domain_param} 的证书目录仍存在"
        else
            log_info "✓ 域名 ${domain_param} 的证书目录已清理"
        fi
    else
        if [ -d "/opt/ssl" ] && [ "$(ls -A /opt/ssl 2>/dev/null)" ]; then
            log_warn "证书目录仍有文件"
        else
            log_info "✓ 证书目录已清理"
        fi
    fi
    
    # 检查nginx配置
    if [ -d "/opt/nginx/conf" ] && [ "$(ls -A /opt/nginx/conf 2>/dev/null)" ]; then
        log_warn "nginx配置目录仍有文件"
    else
        log_info "✓ nginx配置已清理"
    fi
    
    log_info "重置操作完成！现在可以重新运行setup命令"
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
        return 1
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
    
    cat > /opt/nginx/conf/nginx.conf << EOF
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
    
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                   '\$status \$body_bytes_sent "\$http_referer" '
                   '"\$http_user_agent" "\$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    server {
        listen 80;
        server_name ${DOMAIN};
        
        location /.well-known/acme-challenge/ {
            root /usr/share/nginx/html;
        }
        
        location / {
            return 301 https://\$server_name\$request_uri;
        }
    }
    
    server {
        listen 443 ssl;
        http2 on;
        server_name ${DOMAIN};
        
        ssl_certificate /etc/ssl/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/ssl/${DOMAIN}/private.key;
        
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
    <title>${DOMAIN}</title>
</head>
<body>
    <h1>Welcome to ${DOMAIN}</h1>
    <p>Server is running normally.</p>
</body>
</html>
EOF
}

# 启动nginx容器进行证书验证
start_nginx_for_cert() {
    log_info "启动 nginx 容器进行证书验证..."
    
    # 停止可能存在的nginx容器
    log_debug "停止现有nginx容器..."
    docker stop nginx-cert 2>/dev/null || true
    docker rm nginx-cert 2>/dev/null || true
    
    # 确保webroot目录存在并有正确权限
    log_debug "检查webroot目录: ${NGINX_WEBROOT}"
    if [ ! -d "${NGINX_WEBROOT}" ]; then
        mkdir -p "${NGINX_WEBROOT}"
        log_debug "创建webroot目录: ${NGINX_WEBROOT}"
    fi
    
    # 创建测试文件
    echo "ACME Challenge Test" > "${NGINX_WEBROOT}/test.txt"
    log_debug "创建测试文件: ${NGINX_WEBROOT}/test.txt"
    
    # 启动nginx容器（仅HTTP，用于证书验证）
    log_debug "启动nginx容器命令: docker run -d --name nginx-cert -p 80:80 -v ${NGINX_WEBROOT}:/usr/share/nginx/html:ro nginx:alpine"
    
    docker run -d \
        --name nginx-cert \
        -p 80:80 \
        -v ${NGINX_WEBROOT}:/usr/share/nginx/html:ro \
        nginx:alpine
    
    local docker_result=$?
    if [ $docker_result -ne 0 ]; then
        log_error "nginx容器启动失败"
        return 1
    fi
    
    # 等待nginx启动
    log_debug "等待nginx容器启动..."
    sleep 5
    
    # 验证nginx是否正常运行
    if docker ps | grep nginx-cert >/dev/null; then
        log_info "nginx容器启动成功"
        log_debug "容器信息: $(docker ps | grep nginx-cert)"
        
        # 测试HTTP访问
        log_debug "测试HTTP访问..."
        if curl -s http://localhost/test.txt | grep -q "ACME Challenge Test"; then
            log_debug "HTTP访问测试成功"
        else
            log_warn "HTTP访问测试失败，可能影响证书验证"
        fi
    else
        log_error "nginx容器启动失败"
        return 1
    fi
}

# 申请SSL证书
request_certificate() {
    log_info "申请 SSL 证书..."
    
    # 设置日志文件路径
    local acme_log_file="${LOG_FILE:-/var/log/acme_${DOMAIN}.log}"
    local install_log_file="/var/log/acme_install_${DOMAIN}.log"
    
    # 检查域名解析
    log_info "检查域名 ${DOMAIN} 的解析状态..."
    log_debug "执行 nslookup ${DOMAIN}"
    
    if nslookup ${DOMAIN} >/dev/null 2>&1; then
        log_info "域名解析正常"
        if [ "$DEBUG_MODE" = true ]; then
            log_debug "域名解析详细信息:"
            nslookup ${DOMAIN} | head -10
        fi
    else
        log_warn "域名解析可能有问题，但继续尝试申请证书"
    fi
    
    # 检查HTTP访问
    log_info "检查HTTP访问状态..."
    log_debug "测试URL: http://${DOMAIN}/.well-known/acme-challenge/test"
    
    local http_test=$(curl -s -o /dev/null -w "%{http_code}" http://${DOMAIN}/.well-known/acme-challenge/test 2>/dev/null)
    log_debug "HTTP响应码: $http_test"
    
    if echo "$http_test" | grep -q "404"; then
        log_info "ACME challenge 路径可访问 (404正常)"
    else
        log_warn "ACME challenge 路径响应码: $http_test (可能无法访问，但继续尝试)"
    fi
    
    # 构建acme.sh命令参数
    local acme_args=""
    if [ "$DEBUG_MODE" = true ]; then
        acme_args="--debug 3"
        log_debug "启用最高级别调试模式 (debug 3)"
    else
        acme_args="--debug 2"
        log_debug "启用标准调试模式 (debug 2)"
    fi
    
    # 使用webroot模式申请证书（启用调试日志）
    log_info "开始申请证书，日志保存到: $acme_log_file"
    log_debug "执行命令: ~/.acme.sh/acme.sh --issue -d ${DOMAIN} --webroot ${NGINX_WEBROOT} --force $acme_args --log $acme_log_file"
    
    ~/.acme.sh/acme.sh --issue \
        -d ${DOMAIN} \
        --webroot ${NGINX_WEBROOT} \
        --force \
        $acme_args \
        --log "$acme_log_file"
    
    local issue_result=$?
    log_debug "证书申请命令退出码: $issue_result"
    
    # 显示详细的申请结果
    if [ $issue_result -eq 0 ]; then
        log_info "证书申请成功"
    else
        log_error "证书申请失败 (退出码: $issue_result)"
        log_error "查看详细日志: $acme_log_file"
        
        # 显示最近的错误日志
        if [ -f "$acme_log_file" ]; then
            log_error "最近的申请日志 (最后30行):"
            echo "=========================================="
            tail -30 "$acme_log_file"
            echo "=========================================="
        fi
        
        # 检查acme.sh的domain日志目录
        local domain_log_dir="/root/.acme.sh/${DOMAIN}_ecc"
        if [ -d "$domain_log_dir" ]; then
            log_debug "检查acme.sh域名日志目录: $domain_log_dir"
            if [ -f "$domain_log_dir/${DOMAIN}.log" ]; then
                log_error "ACME域名调试日志:"
                echo "=========================================="
                tail -20 "$domain_log_dir/${DOMAIN}.log"
                echo "=========================================="
            fi
        fi
        
        # 检查通用的acme.sh错误
        log_debug "检查常见问题..."
        
        # 检查端口占用
        if netstat -tlnp | grep :80 | grep -v nginx-cert; then
            log_warn "发现其他程序占用80端口:"
            netstat -tlnp | grep :80
        fi
        
        # 检查防火墙
        if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
            log_debug "UFW防火墙状态:"
            ufw status
        fi
        
        return 1
    fi
    
    # 安装证书到指定目录
    log_info "安装证书到指定目录..."
    log_debug "证书安装路径: ${CERT_DIR}"
    log_debug "执行命令: ~/.acme.sh/acme.sh --install-cert -d ${DOMAIN} --key-file ${CERT_DIR}/private.key --fullchain-file ${CERT_DIR}/fullchain.pem"
    
    ~/.acme.sh/acme.sh --install-cert \
        -d ${DOMAIN} \
        --key-file ${CERT_DIR}/private.key \
        --fullchain-file ${CERT_DIR}/fullchain.pem \
        --reloadcmd "docker restart nginx-ssl 2>/dev/null || true" \
        --log "$install_log_file"
    
    local install_result=$?
    log_debug "证书安装命令退出码: $install_result"
    
    if [ $install_result -eq 0 ]; then
        log_info "证书安装成功"
        
        # 验证安装的证书文件
        if [ -f "${CERT_DIR}/fullchain.pem" ] && [ -f "${CERT_DIR}/private.key" ]; then
            log_info "证书文件验证:"
            local cert_size=$(du -h ${CERT_DIR}/fullchain.pem | cut -f1)
            local key_size=$(du -h ${CERT_DIR}/private.key | cut -f1)
            echo "证书文件大小: $cert_size"
            echo "私钥文件大小: $key_size"
            log_debug "证书文件路径: ${CERT_DIR}/fullchain.pem"
            log_debug "私钥文件路径: ${CERT_DIR}/private.key"
            
            # 验证证书内容
            log_debug "验证证书格式..."
            if openssl x509 -in ${CERT_DIR}/fullchain.pem -text -noout >/dev/null 2>&1; then
                log_info "证书格式验证通过"
                
                if [ "$DEBUG_MODE" = true ]; then
                    log_debug "证书详细信息:"
                    openssl x509 -in ${CERT_DIR}/fullchain.pem -text -noout | head -20
                fi
            else
                log_error "证书格式验证失败"
                
                # 显示证书文件内容以便调试
                log_debug "证书文件前10行内容:"
                head -10 ${CERT_DIR}/fullchain.pem
                
                return 1
            fi
        else
            log_error "证书文件不存在或损坏"
            log_debug "检查证书目录内容:"
            ls -la ${CERT_DIR}/
            return 1
        fi
    else
        log_error "证书安装失败 (退出码: $install_result)"
        
        # 显示安装日志
        if [ -f "$install_log_file" ]; then
            log_error "安装错误日志:"
            echo "=========================================="
            cat "$install_log_file"
            echo "=========================================="
        fi
        
        return 1
    fi
    
    # 设置证书文件权限
    log_debug "设置证书文件权限..."
    chmod 600 ${CERT_DIR}/private.key
    chmod 644 ${CERT_DIR}/fullchain.pem
    
    # 验证权限设置
    local key_perm=$(stat -c "%a" ${CERT_DIR}/private.key 2>/dev/null)
    local cert_perm=$(stat -c "%a" ${CERT_DIR}/fullchain.pem 2>/dev/null)
    log_debug "私钥文件权限: $key_perm"
    log_debug "证书文件权限: $cert_perm"
    
    log_info "证书权限设置完成"
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
    
    # 验证证书文件存在
    if [ ! -f "${CERT_DIR}/fullchain.pem" ] || [ ! -f "${CERT_DIR}/private.key" ]; then
        log_error "证书文件不存在，无法启动SSL服务"
        return 1
    fi
    
    # 启动支持SSL的nginx容器
    docker run -d \
        --name nginx-ssl \
        --restart always \
        -p 80:80 \
        -p 443:443 \
        -v /opt/nginx/conf/nginx.conf:/etc/nginx/nginx.conf:ro \
        -v ${NGINX_WEBROOT}:/usr/share/nginx/html:ro \
        -v ${CERT_DIR}:/etc/ssl/${DOMAIN}:ro \
        nginx:alpine
    
    if [ $? -eq 0 ]; then
        log_info "nginx SSL 服务启动完成"
    else
        log_error "nginx SSL 服务启动失败"
        return 1
    fi
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
    local domain_to_check="${1:-$DOMAIN}"
    log_info "验证证书安装..."
    
    if [ -z "$domain_to_check" ]; then
        log_error "未指定要验证的域名"
        return 1
    fi
    
    local cert_dir="/opt/ssl/${domain_to_check}"
    
    if [ -f "${cert_dir}/fullchain.pem" ] && [ -f "${cert_dir}/private.key" ]; then
        log_info "证书文件存在"
        
        # 检查证书有效期
        cert_expiry=$(openssl x509 -in ${cert_dir}/fullchain.pem -noout -dates | grep "notAfter" | cut -d= -f2)
        log_info "证书有效期至: ${cert_expiry}"
        
        # 验证证书格式
        if openssl x509 -in ${cert_dir}/fullchain.pem -text -noout >/dev/null 2>&1; then
            log_info "证书格式验证成功"
        else
            log_error "证书格式验证失败"
            return 1
        fi
        
        # 测试HTTPS连接
        if curl -s -o /dev/null -w "%{http_code}" https://${domain_to_check} | grep -q "200\|301\|302"; then
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
    if [ -z "${DOMAIN}" ]; then
        log_error "必须通过 -d 参数指定域名"
        show_help
        return 1
    fi

    # 在此处设置依赖于 DOMAIN 的变量
    EMAIL="admin@${DOMAIN}"
    CERT_DIR="/opt/ssl/${DOMAIN}"
    NGINX_WEBROOT="/opt/nginx/html"

    log_info "开始为域名 ${DOMAIN} 申请SSL证书..."
    log_info "证书将保存到: ${CERT_DIR}"
    
    check_root || return 1
    install_dependencies || return 1
    install_acme || return 1
    create_directories || return 1
    create_nginx_config || return 1
    start_nginx_for_cert || return 1
    
    # 等待DNS解析生效
    log_info "等待DNS解析生效..."
    sleep 10
    
    request_certificate || return 1
    start_nginx_ssl || return 1
    setup_auto_renewal || return 1
    
    if verify_certificate; then
        create_cert_info
        log_info "证书申请和配置完成！"
        log_info "证书路径: ${CERT_DIR}/fullchain.pem"
        log_info "私钥路径: ${CERT_DIR}/private.key"
        log_info "网站已可通过 https://${DOMAIN} 访问"
    else
        log_error "证书验证失败，请检查配置"
        return 1
    fi
}

# 脚本参数处理
case "${1:-}" in
    "setup")
        shift
        FORCE_RESET=false
        
        # 处理参数
        while [[ $# -gt 0 ]]; do
            case $1 in
                -d)
                    DOMAIN="$2"
                    shift 2
                    ;;
                --force-reset)
                    FORCE_RESET=true
                    shift
                    ;;
                --debug)
                    DEBUG_MODE=true
                    shift
                    ;;
                --log-file)
                    LOG_FILE="$2"
                    shift 2
                    ;;
                -h)
                    show_help
                    exit 0
                    ;;
                *)
                    log_error "未知选项: $1"
                    show_help
                    exit 1
                    ;;
            esac
        done
        
        # 初始化日志
        if [ "$DEBUG_MODE" = true ]; then
            log_debug "调试模式已启用"
            log_debug "脚本参数: DOMAIN=$DOMAIN, FORCE_RESET=$FORCE_RESET, LOG_FILE=$LOG_FILE"
        fi
        
        # 创建日志目录
        mkdir -p /var/log
        if [ -n "$LOG_FILE" ]; then
            mkdir -p "$(dirname "$LOG_FILE")"
            log_info "自定义日志文件: $LOG_FILE"
        fi
        
        # 调用main函数，传递force_reset参数
        main "$FORCE_RESET"
        ;;
    "renew")
        shift
        # 处理renew命令的参数
        while [[ $# -gt 0 ]]; do
            case $1 in
                --debug)
                    DEBUG_MODE=true
                    shift
                    ;;
                --log-file)
                    LOG_FILE="$2"
                    shift 2
                    ;;
                *)
                    log_error "renew命令不支持选项: $1"
                    exit 1
                    ;;
            esac
        done
        
        log_info "手动续期证书..."
        if [ "$DEBUG_MODE" = true ]; then
            log_debug "执行: ~/.acme.sh/acme.sh --cron --force --debug 2"
            ~/.acme.sh/acme.sh --cron --force --debug 2
        else
            ~/.acme.sh/acme.sh --cron --force
        fi
        ;;
    "status")
        shift
        # 处理status命令的参数
        while [[ $# -gt 0 ]]; do
            case $1 in
                -d)
                    DOMAIN="$2"
                    shift 2
                    ;;
                --debug)
                    DEBUG_MODE=true
                    shift
                    ;;
                *)
                    log_error "status命令不支持选项: $1"
                    exit 1
                    ;;
            esac
        done
        
        # 如果没有指定域名，尝试从证书目录推断
        if [ -z "$DOMAIN" ]; then
            if [ -d "/opt/ssl" ]; then
                for domain_dir in /opt/ssl/*/; do
                    if [ -d "$domain_dir" ]; then
                        domain_name=$(basename "$domain_dir")
                        log_info "检查域名: $domain_name"
                        verify_certificate "$domain_name"
                    fi
                done
            else
                log_error "未找到证书目录"
            fi
        else
            verify_certificate
        fi
        ;;
    "reset")
        shift
        # 处理reset命令的参数
        while [[ $# -gt 0 ]]; do
            case $1 in
                --debug)
                    DEBUG_MODE=true
                    shift
                    ;;
                *)
                    log_error "reset命令不支持选项: $1"
                    exit 1
                    ;;
            esac
        done
        
        check_root || exit 1
        reset_environment
        ;;
    "clean")
        log_info "清理nginx容器..."
        docker stop nginx-ssl nginx-cert 2>/dev/null || true
        docker rm nginx-ssl nginx-cert 2>/dev/null || true
        log_info "清理完成"
        ;;
    "-h"|"--help")
        show_help
        exit 0
        ;;
    "-v"|"--version")
        show_version
        exit 0
        ;;
    "")
        log_error "未指定命令"
        show_help
        exit 1
        ;;
    *)
        log_error "未知命令: $1"
        show_help
        exit 1
        ;;
esac