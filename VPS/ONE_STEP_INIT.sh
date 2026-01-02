#!/bin/bash

# 下载 util.sh
curl -fsSL https://raw.githubusercontent.com/NEKO-CwC/SERVER/refs/heads/main/VPS/util.sh -o util.sh

# Source util.sh
source ./util.sh

# 检查依赖
main() {
    log_step "检查系统依赖..."
    
    # Check dependencies using the function from util.sh
    check_dependencies curl wget bash sudo || return 1

    log_info "所有依赖已满足"

    # 下载并执行安装脚本
    curl -fsSL https://raw.githubusercontent.com/NEKO-CwC/SERVER/refs/heads/main/VPS/package_install.sh -o package_install.sh
    bash package_install.sh

    curl -fsSL https://raw.githubusercontent.com/NEKO-CwC/SERVER/refs/heads/main/VPS/init.sh -o init.sh
    bash init.sh

    # 清理临时文件
    rm -f package_install.sh init.sh util.sh
    log_info "一键初始化脚本执行完成"
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi