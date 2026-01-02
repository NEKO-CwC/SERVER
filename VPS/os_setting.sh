#!/bin/bash

# ====================================================
# 系统自适应网络优化脚本 (支持 BBR + Hy2 优化)
# 适用环境: Debian 11/12/13, Ubuntu 20.04+
# ====================================================

# Source util.sh
source "$(dirname "$0")/util.sh"

if [[ $EUID -ne 0 ]]; then
   error_exit "必须使用 root 权限运行"
fi

# --- 1. 系统信息采集 ---
log_step "采集系统硬件信息..."

# 获取总内存 (MB)
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
# 获取内核版本
KERNEL_VER=$(uname -r | cut -d'.' -f1,2)

log_info "检测到总内存: ${TOTAL_MEM} MB"
log_info "检测到内核版本: ${KERNEL_VER}"

# --- 2. 逻辑判断：计算最合适参数 ---
# 我们根据内存大小将机器分为三档：
# 1. 微型 (<= 512MB): 极保守，防止 OOM
# 2. 中型 (512MB - 2GB): 平衡型，兼顾速度与安全 (你的 1C1G 属于此类)
# 3. 大型 (> 2GB): 高性能型，全力冲刺千兆

if [ "$TOTAL_MEM" -le 512 ]; then
    # <= 512MB 内存
    MEM_LEVEL="Tiny"
    TCP_MAX_BUF=8388608      # 8MB
    UDP_MAX_BUF=8388608      # 8MB
    BACKLOG=2000
elif [ "$TOTAL_MEM" -le 2048 ]; then
    # 512MB - 2GB 内存 (你的情况)
    MEM_LEVEL="Medium"
    TCP_MAX_BUF=33554432     # 32MB
    UDP_MAX_BUF=33554432     # 32MB
    BACKLOG=5000
else
    # > 2GB 内存
    MEM_LEVEL="Large"
    TCP_MAX_BUF=67108864     # 64MB
    UDP_MAX_BUF=67108864     # 64MB
    BACKLOG=10000
fi

log_info "系统分级: ${MEM_LEVEL} | 设置 TCP/UDP 最大缓冲区: $((TCP_MAX_BUF / 1024 / 1024)) MB"

# --- 3. 写入配置 ---
log_step "应用内核参数优化..."

# 清理旧配置
sed -i '/# --- Network Optimization ---/,$d' /etc/sysctl.conf

cat >> /etc/sysctl.conf << EOF

# --- Network Optimization ---
# 拥塞控制算法 BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 缓冲区自适应设置
net.ipv4.tcp_rmem = 4096 87380 $TCP_MAX_BUF
net.ipv4.tcp_wmem = 4096 16384 $TCP_MAX_BUF

# UDP 缓冲区优化 (Hy2 关键)
net.core.rmem_max = $UDP_MAX_BUF
net.core.wmem_max = $UDP_MAX_BUF

# 队列与并发优化
net.core.netdev_max_backlog = $BACKLOG
fs.file-max = 1000000
net.ipv4.tcp_max_syn_backlog = $BACKLOG
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
# --- Optimization End ---
EOF

# 应用配置
sysctl -p > /dev/null 2>&1

# --- 4. BBR 状态验证 ---
log_step "验证优化状态..."

if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    log_info "✅ BBR 状态: 已激活"
else
    log_warn "❌ BBR 状态: 未激活，请检查内核是否支持"
fi

# 检查是否存在 Hy2 常见的 UDP 限制警告
if [ $(sysctl -n net.core.rmem_max) -lt 8388608 ]; then
    log_warn "⚠️ 警告: UDP 接收缓冲区似乎仍受限"
else
    log_info "✅ UDP 缓冲区已调整完毕"
fi

log_info "所有操作已完成！针对您的 ${MEM_LEVEL} 级别服务器已配置最优参数。"