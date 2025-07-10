#!/bin/bash

# 检查依赖
log_step "检查系统依赖..."
local missing_dependencies=()

for dep in curl git; do
    if ! command -v "$dep" &>/dev/null; then
        missing_dependencies+=("$dep")
    fi
done

if [[ ${#missing_dependencies[@]} -ne 0 ]]; then
    log_error "缺少以下依赖: ${missing_dependencies[*]}"
    log_info "请安装缺少的依赖后重试"
    exit 1
fi

log_info "所有依赖已满足"

# 下载并执行安装脚本
curl https://raw.githubusercontent.com/NEKO-CwC/SERVER/refs/heads/main/VPS/package_install.sh -o package_install.sh
bash package_install.sh

curl https://raw.githubusercontent.com/NEKO-CwC/SERVER/refs/heads/main/VPS/init.sh -o init.sh
bash init.sh

# 清理临时文件
rm -f package_install.sh init.sh
log_info "一键初始化脚本执行完成"