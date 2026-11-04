# sing-box client 升级与恢复验证（2026-11-04）

## 问题归属

服务器环境：旧客户端被禁用；历史启动日志中 DNS/规则集下载报 `no route to host`。本机额外安装的 DNS guard 等待 `tun0`，新订阅实际创建 `singbox`；这会使已运行的客户端因 ExecStartPost 失败而被 systemd 停止。机器同时存在断链的默认出口与可用出口，需按本机拓扑选择。旧服务、DNS 定时器与仍读取旧服务的审计任务不属于当前通用安装器。

安装器风险：直接用新订阅覆盖配置，无法持久保存本机出口设置；替换文件或启动失败后只停服务，没有恢复旧安装。修复增加仓库外的 `config.override.json` 合并，以及替换前快照、失败时恢复自有文件和客户端启用/运行状态。没有在通用代码中加入生产接口名、DNS guard、K8s 规则或订阅凭据。

## 验证

在 Linux/systemd 目标机器执行：

```bash
PYTHONPATH=tests python3 -m unittest \
  test_installers.SingBoxTests test_installers.RepositoryTests \
  test_singbox_client_upgrade.ClientUpgradeTests
python3 -m unittest discover -s tests -p test_singbox_bypass.py
```

- 升级、既有 sing-box 安装器和 shell 语法检查：22 项通过。
- bypass 生命周期和隔离 network namespace 的真实路由测试：9 项通过。
- 使用真实 sing-box 1.14.4 合并新订阅和本机覆盖文件，配置校验通过。`merge` 会省略值为默认值的 `auto_detect_interface: false`；验证最终值按缺省 false 读取。
- 使用修复后的完整安装器实际重装成功，本机出口设置保留；客户端 `enabled / active / running`，重启计数为 0。
- DNS guard 按实际 TUN 接口检查成功；通过透明代理和 `127.0.0.1:7890` 显式代理访问 HTTPS，均返回 204。
- SSH/Tailscale 连通性、K8s 路由保持；旧单元归档，本机 DNS 监控改为随客户端运行、每 5 分钟检查，审计任务改读客户端日志并成功采集。

扩大运行完整仓库测试时未全通过：Agent 测试调用了宿主机已安装的真实工具，另外两项 sing-box 测试读到了真实覆盖文件。后者已通过显式沙箱路径修复并重跑上述相关测试；Agent 测试隔离问题不在本次修改范围内。因此这里只声明上述相关检查通过，不声明全仓库测试通过。

回退不覆盖宿主机 DNS/CNI、额外 systemd drop-in 或 sing-box 数据缓存；文件系统损坏、权限错误或原配置本身无法启动时，仍可能需要按报出的恢复目录人工恢复。测试未向生产服务注入故障；失败回退通过沙箱故障测试验证。
