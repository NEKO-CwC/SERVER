# sing-box 1.14.3 与入站回程验证

验证日期：2026-10-09。使用 medical 主机上的独立 Ubuntu 22.04 Docker 容器，内核为 Linux 5.15；容器具有独立网络、PID、mount 和 cgroup 命名空间。没有替换宿主机的 sing-box 配置、重启其服务或修改 K3s 配置。测试使用现有节点凭据，凭据和生成的完整配置未提交。

## 修改

- 客户端默认内核由 1.13.15 升为 GitHub 当日最新稳定版 1.14.3，订阅 User-Agent 为 `sing-box/1.14.3`。
- 默认标记 SSH 和 TCP 80/443 入站连接；`INGRESS_TCP_PORTS` 可配置额外端口。
- `prerouting` 恢复已标记连接的包标记，覆盖 DNAT 容器回程；宿主机回复在 `output` 恢复。
- IPv4/IPv6 使用 `fwmark 0x100/0x100 lookup main`，保留其他 mark 位。
- nft 表在一次事务内替换；策略路由幂等加载，并精确清理旧的完整 mark 匹配规则。
- 升级模板保留原有内网 DNS/直连策略，修正节点域名解析并迁移 1.14 HTTP 客户端字段。

## 自动化和安装流程

在容器内执行：

```bash
python3 -m unittest discover -s tests -v
```

结果：**55 项测试全部通过，无跳过项**。其中 9 项 bypass 测试包含：

- 在三个临时网络命名空间中设置独立客户端、节点与容器后端。
- 未安装 bypass 时，模拟 TUN 策略造成公网回复失败；加载后，宿主机 TCP 80/443 和 DNAT 到后端 8080/8443 的请求返回 HTTP 200，覆盖 IPv4/IPv6。
- 主动 HTTP/HTTPS 仍遵循模拟代理路由，主动 SSH 保留直连行为。
- 自定义 SSH/入站端口、非法配置无副作用、重复加载、旧规则迁移及完整清理。
- 其他组件的 mark 位保留；nft 事务注入语法错误后旧表保持不变，现有请求继续成功。

命名空间测试使用真实 netfilter/DNAT/策略路由，以 dummy 设备模拟 TUN 接管，未将其冒充为真实 sing-box 流量测试。

另外执行 `VPS/singbox/client/test/verify.sh`，通过容器回环订阅服务提供仓库 fixture，使用真实 1.14.3 二进制和 systemd 安装流程。文件权限、订阅 User-Agent、真实 TUN 启动、Tailscale 路由、双栈 mark 规则、服务停止清理、重新启动和重复安装均通过。

容器 `/tmp` 默认为 `noexec`，首次运行 SSH askpass 测试因此失败。仅在测试容器的 mount 命名空间内启用 `/tmp` 执行权限后，全套测试通过。

## 升级模板与真实节点

将 `VPS/singbox/client/template.json` 与本机现有配置中的五个节点组合，填充 selector/urltest 节点列表。使用真实二进制执行 `sing-box check` 通过，再通过客户端安装器从容器回环订阅服务安装完整候选配置。

验证结果：

| 检查 | 结果 |
| --- | --- |
| 服务状态 | `active`，`NRestarts=0` |
| 节点 DNS | `la-new.284072.xyz` → `104.224.154.181` |
| urltest | LA x2 / LA native 可用，观测延迟约 323 / 331 ms |
| 自动选择 | LA x2 |
| 远程规则集 | 七个全部更新成功 |
| SOCKS：gstatic / Google / Anthropic 根路径 | 204 / 200 / 404 |
| TUN：gstatic / Google / Anthropic 根路径 | 204 / 200 / 404 |

Anthropic 根路径的 404 用于证明 TLS 和 HTTP 连通，不代表 API 鉴权或模型请求已验证。

首次 TUN 检查中 Google TLS 失败：容器继承了宿主机的内网 DNS，而这些服务器地址属于模板排除的私网路由；Google 被解析为错误地址。仅将测试容器 `/etc/resolv.conf` 指向该隔离实例的 `127.0.0.1:53` 后，六项 SOCKS/TUN 请求全部通过。宿主机 DNS 未变；部署此模板时，应用 DNS 也应进入对应 sing-box 实例，不能假设排除的私网 DNS 会被 TUN 自动接管。

## 发布边界

仓库模板不含节点密码，必须由订阅端补全节点后下发。模板包含 1.14 字段，使用它的客户端内核也需升级。

线上模板未在本次验证中发布。更新订阅端后，应重新拉取订阅；本次安装器不会自动修补旧订阅的 DNS 或业务策略。

Kubernetes/CNI 的跨节点、DSR、多公网出口及现有 mark 位冲突未验证，不能将本次 Docker/DNAT 结果推广为所有 K8s 部署均已适配。

上游参考：[1.14.3 稳定版](https://github.com/SagerNet/sing-box/releases/tag/v1.14.3)、[迁移说明](https://sing-box.sagernet.org/migration/)。
