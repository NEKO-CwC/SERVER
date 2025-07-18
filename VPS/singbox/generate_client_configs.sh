#!/bin/bash

# Sing-box 代理服务一键部署脚本
# 自动完成证书申请、服务端配置、客户端配置生成

set -e

DOMAIN="284072.xyz"
PROJECT_DIR="/opt/singbox-proxy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_success() {
    echo -e "${PURPLE}[SUCCESS]${NC} $1"
}

# 显示标题
show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════╗
║              Sing-box 代理服务部署               ║
║              一键自动化部署脚本                  ║
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# 检查系统环境
check_environment() {
    log_step "检查系统环境..."
    
    # 检查是否为root权限
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
    
    # 检查操作系统
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法识别的操作系统"
        exit 1
    fi
    
    source /etc/os-release
    log_info "操作系统: $PRETTY_NAME"
    
    # 检查必要命令
    local required_commands=("curl" "docker" "docker-compose")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_warn "$cmd 未安装，将自动安装"
        fi
    done
}

# 创建项目目录结构
create_project_structure() {
    log_step "创建项目目录结构..."
    
    mkdir -p ${PROJECT_DIR}/{scripts,config,client_configs,logs,backup}
    cd ${PROJECT_DIR}
    
    log_info "项目目录: ${PROJECT_DIR}"
}

# 复制脚本文件
copy_scripts() {
    log_step "复制部署脚本..."
    
    # 复制所有脚本到项目目录
    cp ${SCRIPT_DIR}/*.sh ${PROJECT_DIR}/scripts/ 2>/dev/null || true
    
    # 确保脚本可执行
    chmod +x ${PROJECT_DIR}/scripts/*.sh
}

# 执行证书申请
setup_certificates() {
    log_step "申请SSL证书..."
    
    # 检查证书申请脚本
    local cert_script="${PROJECT_DIR}/scripts/cert_setup.sh"
    if [[ ! -f "$cert_script" ]]; then
        log_error "证书申请脚本不存在"
        return 1
    fi
    
    # 执行证书申请
    bash "$cert_script"
    
    # 验证证书
    local cert_path="/opt/ssl/${DOMAIN}/fullchain.pem"
    local key_path="/opt/ssl/${DOMAIN}/private.key"
    
    if [[ -f "$cert_path" ]] && [[ -f "$key_path" ]]; then
        log_success "SSL证书申请成功"
        return 0
    else
        log_error "SSL证书申请失败"
        return 1
    fi
}

# 生成服务端配置
setup_server_configs() {
    log_step "生成服务端配置..."
    
    local server_script="${PROJECT_DIR}/scripts/generate_server_configs.sh"
    if [[ ! -f "$server_script" ]]; then
        log_error "服务端配置生成脚本不存在"
        return 1
    fi
    
    # 执行配置生成
    cd ${PROJECT_DIR}
    bash "$server_script"
    
    log_success "服务端配置生成完成"
}

# 生成客户端配置
setup_client_configs() {
    log_step "生成客户端配置..."
    
    local client_script="${PROJECT_DIR}/scripts/generate_client_configs.sh"
    if [[ ! -f "$client_script" ]]; then
        log_error "客户端配置生成脚本不存在"
        return 1
    fi
    
    # 执行配置生成
    cd ${PROJECT_DIR}
    bash "$client_script"
    
    log_success "客户端配置生成完成"
}

# 选择并启动协议
select_and_start_protocol() {
    log_step "选择要启动的协议..."
    
    # 列出可用配置
    local configs=($(ls ${PROJECT_DIR}/config/*.json 2>/dev/null | xargs -n1 basename | grep -v config.json | grep -v server_info.json))
    
    if [[ ${#configs[@]} -eq 0 ]]; then
        log_error "没有找到可用的配置文件"
        return 1
    fi
    
    echo "可用协议配置:"
    for i in "${!configs[@]}"; do
        local protocol=$(echo "${configs[$i]}" | cut -d'.' -f1)
        echo "$((i+1)). $protocol"
    done
    
    echo -n "请选择要启动的协议 (1-${#configs[@]}) [默认: 1]: "
    read choice
    
    # 默认选择第一个
    if [[ -z "$choice" ]]; then
        choice=1
    fi
    
    if [[ "$choice" -gt 0 ]] && [[ "$choice" -le "${#configs[@]}" ]]; then
        local selected_config="${configs[$((choice-1))]}"
        local protocol=$(echo "$selected_config" | cut -d'.' -f1)
        
        log_info "启动协议: $protocol"
        cd ${PROJECT_DIR}
        bash ./start_proxy.sh "$selected_config"
        
        log_success "协议 $protocol 启动成功"
        return 0
    else
        log_error "无效选择"
        return 1
    fi
}

# 创建管理脚本
create_management_scripts() {
    log_step "创建管理脚本..."
    
    # 创建服务管理脚本
    cat > ${PROJECT_DIR}/manage.sh << 'EOF'
#!/bin/bash

# Sing-box 服务管理脚本

PROJECT_DIR="/opt/singbox-proxy"
cd ${PROJECT_DIR}

case "${1:-}" in
    "start")
        echo "启动服务..."
        docker-compose up -d
        echo "服务已启动"
        ;;
    "stop")
        echo "停止服务..."
        docker-compose down
        echo "服务已停止"
        ;;
    "restart")
        echo "重启服务..."
        docker-compose restart
        echo "服务已重启"
        ;;
    "status")
        echo "服务状态:"
        docker-compose ps
        ;;
    "logs")
        echo "查看日志:"
        docker-compose logs -f --tail=100
        ;;
    "switch")
        echo "切换协议配置:"
        bash ./switch_config.sh
        ;;
    "update")
        echo "更新 sing-box 镜像:"
        docker-compose pull
        docker-compose up -d
        ;;
    "backup")
        echo "备份配置:"
        tar -czf "backup/singbox-backup-$(date +%Y%m%d-%H%M%S).tar.gz" config/ client_configs/
        echo "备份完成"
        ;;
    "clean")
        echo "清理日志和缓存:"
        docker system prune -f
        rm -rf logs/*.log
        echo "清理完成"
        ;;
    *)
        echo "Sing-box 服务管理"
        echo "用法: $0 {start|stop|restart|status|logs|switch|update|backup|clean}"
        echo ""
        echo "命令说明:"
        echo "  start   - 启动服务"
        echo "  stop    - 停止服务"
        echo "  restart - 重启服务"
        echo "  status  - 查看状态"
        echo "  logs    - 查看日志"
        echo "  switch  - 切换协议"
        echo "  update  - 更新镜像"
        echo "  backup  - 备份配置"
        echo "  clean   - 清理缓存"
        exit 1
        ;;
esac
EOF
    
    chmod +x ${PROJECT_DIR}/manage.sh
    
    # 创建系统服务
    cat > /etc/systemd/system/singbox-proxy.service << EOF
[Unit]
Description=Sing-box Proxy Service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PROJECT_DIR}
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable singbox-proxy.service
    
    log_success "管理脚本创建完成"
}

# 生成客户端连接信息
generate_connection_info() {
    log_step "生成客户端连接信息..."
    
    local info_file="${PROJECT_DIR}/connection_info.md"
    
    cat > "$info_file" << EOF
# Sing-box 客户端连接信息

## 服务器信息
- **域名**: ${DOMAIN}
- **服务器IP**: $(curl -s http://checkip.amazonaws.com/ || echo "获取失败")
- **部署时间**: $(date)

## 可用协议配置

### 客户端文件下载
客户端配置文件位于: \`${PROJECT_DIR}/client_configs/\`

### 连接方式

#### 方法一：使用配置文件
1. 下载对应协议的客户端配置文件
2. 使用 sing-box 客户端导入配置
3. 启动连接

#### 方法二：手动配置
根据以下信息手动配置客户端:

EOF
    
    # 读取认证信息
    if [[ -f "${PROJECT_DIR}/config/server_info.json" ]]; then
        local password=$(grep '"password"' ${PROJECT_DIR}/config/server_info.json | cut -d'"' -f4)
        local vless_uuid=$(grep -A 10 '"vless"' ${PROJECT_DIR}/config/server_info.json | grep '"uuid"' | cut -d'"' -f4)
        local vmess_uuid=$(grep -A 10 '"vmess"' ${PROJECT_DIR}/config/server_info.json | grep '"uuid"' | cut -d'"' -f4)
        local tuic_uuid=$(grep -A 10 '"tuic"' ${PROJECT_DIR}/config/server_info.json | grep '"uuid"' | cut -d'"' -f4)
        
        cat >> "$info_file" << EOF

**通用密码**: \`${password}\`

**Hysteria2**
- 端口: 36712
- 密码: \`${password}\`

**VLESS**
- 端口: 443
- UUID: \`${vless_uuid}\`
- 传输: WebSocket
- 路径: /vless

**VMess** 
- 端口: 443
- UUID: \`${vmess_uuid}\`
- 传输: WebSocket
- 路径: /vmess

**Shadowsocks**
- 端口: 8388
- 密码: \`${password}\`
- 加密: chacha20-ietf-poly1305

**TUIC**
- 端口: 443
- UUID: \`${tuic_uuid}\`
- 密码: \`${password}\`

**Trojan**
- 端口: 443
- 密码: \`${password}\`

**Naive**
- 端口: 443
- 用户名: user
- 密码: \`${password}\`

## 客户端下载

### Sing-box 官方客户端
- [GitHub Releases](https://github.com/SagerNet/sing-box/releases)
- [图形界面客户端](https://sing-box.sagernet.org/clients/)

### 第三方客户端
- **Android**: [SFA](https://github.com/SagerNet/sing-box-for-android)
- **iOS**: [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118)
- **Windows**: [v2rayN](https://github.com/2dust/v2rayN)
- **macOS**: [ClashX Pro](https://github.com/yichengchen/clashX)

## 使用建议

### 协议选择
- **Hysteria2**: 高速度，适合高带宽需求
- **VLESS**: 平衡性能和兼容性
- **Shadowsocks**: 简单稳定，兼容性好
- **TUIC**: 基于QUIC，移动网络表现好

### 网络优化
- 优先选择支持UDP的协议（Hysteria2、TUIC）
- 在网络不稳定时使用TCP协议（VLESS、VMess、Shadowsocks）
- 根据实际测试结果选择最佳协议

## 故障排除

### 连接问题
1. 检查服务器状态: \`sudo ${PROJECT_DIR}/manage.sh status\`
2. 查看服务日志: \`sudo ${PROJECT_DIR}/manage.sh logs\`
3. 测试端口连通性: \`telnet ${DOMAIN} 端口号\`

### 性能问题
1. 切换协议: \`sudo ${PROJECT_DIR}/manage.sh switch\`
2. 重启服务: \`sudo ${PROJECT_DIR}/manage.sh restart\`
3. 更新镜像: \`sudo ${PROJECT_DIR}/manage.sh update\`

---
*此信息由自动化部署脚本生成*
EOF
    fi
    
    log_success "连接信息生成完成: $info_file"
}

# 显示部署结果
show_deployment_result() {
    log_step "部署完成！"
    
    echo -e "${GREEN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════╗
║                  部署成功！                      ║
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    echo "项目目录: ${PROJECT_DIR}"
    echo "管理命令: sudo ${PROJECT_DIR}/manage.sh"
    echo "连接信息: cat ${PROJECT_DIR}/connection_info.md"
    echo ""
    echo "常用操作:"
    echo "  查看状态: sudo ${PROJECT_DIR}/manage.sh status"
    echo "  查看日志: sudo ${PROJECT_DIR}/manage.sh logs"
    echo "  切换协议: sudo ${PROJECT_DIR}/manage.sh switch"
    echo "  重启服务: sudo ${PROJECT_DIR}/manage.sh restart"
    echo ""
    echo "客户端配置文件位于: ${PROJECT_DIR}/client_configs/"
    echo ""
    
    # 显示当前运行状态
    if docker-compose ps | grep -q "Up"; then
        echo -e "${GREEN}✓ 服务正在运行${NC}"
    else
        echo -e "${YELLOW}! 服务未启动，请运行: sudo ${PROJECT_DIR}/manage.sh start${NC}"
    fi
}

# 主函数
main() {
    show_banner
    
    log_info "开始自动化部署 Sing-box 代理服务"
    log_info "域名: ${DOMAIN}"
    
    # 确认开始部署
    echo -n "确认开始部署? (y/N): "
    read confirm
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        log_info "部署已取消"
        exit 0
    fi
    
    # 执行部署步骤
    check_environment
    create_project_structure
    copy_scripts
    
    # 证书申请
    if setup_certificates; then
        log_success "证书配置完成"
    else
        log_error "证书配置失败，请检查域名解析"
        exit 1
    fi
    
    # 配置生成
    setup_server_configs
    setup_client_configs
    
    # 选择并启动协议
    select_and_start_protocol
    
    # 创建管理工具
    create_management_scripts
    generate_connection_info
    
    # 显示结果
    show_deployment_result
    
    log_success "自动化部署完成！"
}

# 脚本参数处理
case "${1:-}" in
    "")
        main
        ;;
    "uninstall")
        log_info "卸载 Sing-box 代理服务..."
        systemctl stop singbox-proxy 2>/dev/null || true
        systemctl disable singbox-proxy 2>/dev/null || true
        docker-compose -f ${PROJECT_DIR}/docker-compose.yml down 2>/dev/null || true
        rm -rf ${PROJECT_DIR}
        rm -f /etc/systemd/system/singbox-proxy.service
        systemctl daemon-reload
        log_success "卸载完成"
        ;;
    "update")
        log_info "更新部署脚本..."
        cd ${PROJECT_DIR}
        git pull 2>/dev/null || log_warn "无法自动更新，请手动更新脚本"
        ;;
    "status")
        if [[ -d "${PROJECT_DIR}" ]]; then
            cd ${PROJECT_DIR}
            bash ./manage.sh status
        else
            log_error "服务未安装"
        fi
        ;;
    *)
        echo "用法: $0 [uninstall|update|status]"
        echo ""
        echo "  无参数  - 执行完整部署"
        echo "  uninstall - 卸载服务"
        echo "  update    - 更新脚本"
        echo "  status    - 查看状态"
        exit 1
        ;;
esac