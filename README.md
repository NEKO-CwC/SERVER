# SERVER

Linux VPS 基础初始化、Agent 安装，以及独立的 sing-box client/server 部署脚本。

## 目录

| 入口 | 用途 |
| --- | --- |
| `agent/install.sh` | 安装 cc-switch、Claude Code、Codex，导入配置并写入 cc/cx aliases |
| `VPS/ONE_STEP_INIT.sh` | 系统包、Docker、网络设置、仓库与 MOTD 初始化 |
| `VPS/singbox/client/install.sh` | 获取 Xboard 订阅配置，部署客户端与 SSH/Tailscale bypass |
| `VPS/singbox/server/install.sh` | 从本地文件或远程文件地址部署服务端 |
| `agent/api-rescue-v1.sh` | 临时 API DNS 映射，退出时清理 |
| `with-proxy.sh` | 为 Git、VPS 初始化等命令提供交互或环境配置的临时代理 |

基础初始化不会自动启动代理。Clash、sub-store 和生产节点配置不再由本仓库维护。

## 私有配置

仓库不提供真实密码、订阅 token、服务器地址或证书。Agent 与 sing-box 安装器默认在终端交互选择代理，无需环境文件。需要保存参数时，可创建私有配置：

```bash
cp .env.example .env
chmod 600 .env
# 编辑 .env，填写本次需要的变量
# Agent/client/server 均通过 --env .env 直接加载。
# 使用 --env（不带文件）模式可先导出变量：
set -a
source .env
set +a
```

`.env` 是 Bash 文件，只加载自己信任的文件；值含空格、`&`、`$` 等字符时使用单引号。脚本不会自动加载当前目录的环境文件。`.env`、SQL 导出、日志、数据库、证书私钥和 `VPS/singbox/**/config.json` 已加入忽略规则。生产配置建议直接放在仓库外，禁止使用 `git add -f` 提交凭据。

## Agent 安装与重试

在 root Bash 中选择输入方式：

```bash
bash agent/install.sh                       # 默认交互输入
bash agent/install.sh --env                 # 使用已导出的环境变量，不提问
bash agent/install.sh --env /secure/agent.env # 加载指定环境文件，不提问
```

默认交互流程先选择代理方式（不使用代理、HTTP/HTTPS/SOCKS 地址、SSH SOCKS），再选择 cc-switch 配置来源：**WebDAV（默认）或本地 SQL 文件**。选择后输入相应参数，密码隐藏输入，必填项不能为空。直接回车默认不使用代理、通过 WebDAV 获取配置。交互模式不从现有 Agent 配置变量或代理环境变量中取值，也不保存输入的密码。

无终端时必须使用 `--env` 或 `--env FILE`；缺少必填配置会在安装前报错，不会切换到交互模式。旧的自动化安装命令需要补上 `--env`。`--env FILE` 按 Bash 语法读取明确指定的可信文件，文件中的赋值覆盖同名环境变量；不会自动查找 `.env`。

环境模式下的配置来源：

- `CC_SWITCH_CONFIG_SOURCE=dav`（默认）：填写 `CC_SWITCH_WEBDAV_BASE_URL`、`CC_SWITCH_WEBDAV_USERNAME`、`CC_SWITCH_WEBDAV_PASSWORD`；Remote Root 默认 `cc-switch-sync`，Profile 默认 `default`。
- `CC_SWITCH_CONFIG_SOURCE=sql`：填写 `CC_SWITCH_SQL_FILE`，指向本地可读 SQL 文件，无需 WebDAV 凭据。

环境模式下的代理由 `INSTALL_PROXY_MODE` 选择：`none` 为直连；`env`（默认）使用 `INSTALL_PROXY_URL`，为空时继承已设置的 HTTP/HTTPS/ALL_PROXY；`ssh` 使用 `INSTALL_SSH_HOST`、`INSTALL_SSH_USER`、`INSTALL_SSH_PASSWORD` 建立临时隧道。这套 `INSTALL_*` 配置由 Agent、sing-box client/server 和 `with-proxy.sh` 共同使用；旧的 `AGENT_PROXY_*` / `AGENT_SSH_*` 变量仍可使用，同名用途的非空 `INSTALL_*` 值优先。

SSH 只在需要下载或 WebDAV 同步时启动，安装成功、失败或终止后关闭。默认仅用密码连接，不预先登记、不保存或校验服务器主机密钥；也可交互选择首次自动登记（`accept-new`）或严格校验（`yes`）。环境模式使用 `INSTALL_SSH_HOST_KEY_CHECKING` 选择，默认 `no`。不校验时无法确认服务器身份。详细设置见 [SSH_SOCKS_PROXY.md](SSH_SOCKS_PROXY.md)。脚本不配置远端账户、不启用 TUN，也不修改路由。

保留以下显式选项：

```bash
bash agent/install.sh --sql-file /secure/cc-switch.sql # 仅询问代理，直接采用指定 SQL
bash agent/install.sh --skip-config                   # 仅询问代理，只安装工具
bash agent/install.sh --env --sql-file /secure/cc-switch.sql # 环境代理 + 指定 SQL
```

`--sql-file` 优先于环境中的配置来源；`--skip-config` 跳过整个配置导入阶段。

本地 SQL 导入需要 `python3` 和同目录的 `agent/import_sql.py`，请更新完整仓库。选择 SQL 来源即请求用该备份替换 cc-switch 当前数据库，cc-switch 会先自动备份。其 CLI 强制要求终端确认，因此安装器使用临时终端完成这一次确认；收到明确的导入成功结果后才记录完成状态。输出仍保存在私有日志中，不再出现确认提示被重定向后无法作答的问题。

- 每次运行都检查工具的 `--version`；正常则跳过，缺失或不可运行则重新安装。
- 配置成功后保存来源指纹；相同来源且本地数据库存在时跳过。SQL 内容或 WebDAV 参数变化会触发重新导入。
- 安装后续工具失败时，已完成的配置不会在下次重跑时重复同步。
- `--refresh-config` 强制重新下载/导入配置；相同 URL 的远端内容变化需要使用此参数。
- `--force` 强制重装工具；重新同步配置需另加 `--refresh-config`。
- aliases 可重复写入。运行 `source ~/.bashrc` 后可使用 `cc` / `cx`；它们沿用跳过权限确认的启动参数。

状态默认在 `~/.local/state/neko-agent-install/`（目录权限 700）。配置命令失败日志可能含凭据，仅保存在该目录。成功指纹不包含明文凭据。旧安装没有成功记录时，首次运行新脚本会同步一次配置。

`--env` 模式可用 `AGENT_INSTALL_STATE_DIR` 调整状态目录、`AGENT_BASHRC` 调整 aliases 文件、`CC_SWITCH_CONFIG_DIR` 调整 cc-switch 数据目录。交互模式使用默认路径，分别为 `~/.local/state/neko-agent-install/`、`~/.bashrc` 和 `~/.cc-switch`。这里仅以非空数据库和成功记录判断是否已导入；需要修复被修改的配置时请使用 `--refresh-config`。

## sing-box client

要求 root、运行中的 systemd；自动补齐依赖支持 Debian/Ubuntu。

```bash
bash VPS/singbox/client/install.sh # 交互选择代理并输入订阅 URL
bash VPS/singbox/client/install.sh --env .env # 读取代理和 SUBSCRIPTION_URL
```

订阅请求使用 `User-Agent: sing-box`，Xboard 必须返回可直接运行的完整 JSON。每次执行都会获取并校验配置，校验成功后备份旧配置、替换并重启。已安装且版本匹配的二进制会复用。默认版本为 `1.13.15`。

安装前无需运行 sing-box：选择 SSH 代理时，安装器用系统 OpenSSH 建立独立 SOCKS 隧道，供依赖安装、GitHub 二进制和订阅配置下载使用。下载与校验完成后关闭隧道，再安装文件并启动客户端。SSH 模式需要预先具备 OpenSSH 客户端；无法通过尚未建立的 SSH 隧道安装 SSH 自身。Debian/Ubuntu 的 APT 支持这里使用的 `socks5h` 代理环境。

无终端自动化请加 `--env`。命令行订阅 URL 优先于 `SUBSCRIPTION_URL`，例如 `bash VPS/singbox/client/install.sh --env .env 'https://subscription.example.com/config'`。

客户端保留 SSH 及 Tailscale IPv4/IPv6 bypass。`SSH_PORT` 可指定非 22 端口；自定义值应在 systemd override 中对 `sing-box-client-bypass.service` 设置 `Environment=SSH_PORT=...`，这样重启后仍有效。

## sing-box server

要求 root、运行中的 systemd，以及 curl、tar、gzip、coreutils、util-linux。默认版本为 `1.13.13`。服务端只运行给定配置，不使用客户端订阅逻辑，也不安装 bypass。

```bash
bash VPS/singbox/server/install.sh --config-file /secure/server-config.json

# 后续改用远程完整配置：在私有环境文件设置 SINGBOX_SERVER_CONFIG_URL
bash VPS/singbox/server/install.sh --env .env
```

第一条命令会交互选择下载代理；自动化可加 `--env`。环境模式也可用 `SINGBOX_SERVER_CONFIG_FILE` 指定本地文件，两种来源环境变量只设置一个；命令行来源优先。没有提供来源时复用 `/etc/sing-box-server/config.json`。远程内容每次运行时重新下载，不安装定时更新任务。GitHub 二进制与远程配置使用同一个代理。

`VPS/singbox/server/config.example.json` 是不含真实节点信息的 Hysteria2 示例；必须自行设置认证值并准备证书，不能直接当生产配置运行。sing-box JSON 不自动展开 shell 环境变量。认证信息应保存在仓库外的私有配置文件，或由远程配置服务生成。

本地/远程配置都会先通过 `sing-box check`，再覆盖运行配置。下载或校验失败不修改旧配置。服务启动失败会报错；不会自动回滚配置，可使用 `.bak-*` 备份恢复。`--env` 模式中 `SINGBOX_VERSION` 可覆盖版本。兼容旧的 `DOWNLOAD_PROXY`：仅在代理模式为 `env` 且未指定代理 URL 时作为二进制下载的备用设置；显式普通代理和 SSH 代理优先。

| 资源 | client | server |
| --- | --- | --- |
| 服务 | `sing-box-client.service` | `sing-box-server.service` |
| 配置 | `/etc/sing-box-client/config.json` | `/etc/sing-box-server/config.json` |
| 二进制 | `/usr/local/lib/sing-box-client/sing-box` | `/usr/local/lib/sing-box-server/sing-box` |
| 数据 | `/var/lib/sing-box-client` | `/var/lib/sing-box-server` |

两端安装资源独立；同机运行时，监听端口、TUN 和实际流量路由仍需自行协调。

## 旧部署迁移

旧版 client/server 脚本共用 `/etc/sing-box`、`sing-box.service`、`bypass.service`。先备份旧配置和 unit，再停止并禁用机器上实际存在的旧服务：

```bash
systemctl disable --now sing-box.service bypass.service
```

新版安装器会拒绝仍启用或运行的旧 systemd 服务。旧 Docker 部署请先在原部署目录执行 `docker compose down`；若使用单独的 sub-store 容器，按需停止它。新版不会删除旧容器、配置或服务文件，也不会自动把旧生产配置提交回仓库。停止旧客户端可能改变连接路径，应通过仍可用的 SSH/Tailscale 通道操作。

旧目录 `client_config/`、`server_config/` 已由 `client/`、`server/` 替代；所有脚本都应从完整仓库运行。

## VPS 基础初始化

已有完整仓库时，可用同一套配置给其他脚本及 Git 命令提供代理：

```bash
bash with-proxy.sh --env .env -- git pull --ff-only
bash with-proxy.sh --env .env -- bash VPS/ONE_STEP_INIT.sh
# 不加 --env 时先交互选择代理
bash with-proxy.sh -- git pull --ff-only
```

包装命令结束、失败或中断后，临时 SSH 隧道会关闭。它不安装 sing-box，不更改系统代理或路由。首次获取仓库若也需要代理，可先按 [SSH_SOCKS_PROXY.md](SSH_SOCKS_PROXY.md) 建立手动 SSH 隧道，再下载仓库；公共代理模块位于 `lib/proxy.sh`，安装时需保留完整仓库结构。

Docker 安装源当前按 Debian 配置；完整一键初始化用于 Debian VPS。

```bash
curl -fsSL https://raw.githubusercontent.com/NEKO-CwC/SERVER/main/VPS/ONE_STEP_INIT.sh -o ONE_STEP_INIT.sh
bash ONE_STEP_INIT.sh
```

任何阶段失败会立即停止。已安装 Docker 和 Compose 时跳过 Docker 安装。网络设置仍会在每次运行时应用。

`VPS/DD.sh` 会重装 Debian 并重启，必须先设置 `VPS_ROOT_PASSWORD` 和 `VPS_SSH_PUBLIC_KEY`。不要将它用于测试现有机器的安装流程。

## API DNS 救援

在私有环境中设置 `AGENT_API_HOST` 与 `AGENT_API_IP` 后运行：

```bash
bash agent/api-rescue-v1.sh claude
bash agent/api-rescue-v1.sh codex
```

HTTPS 域名、SNI 与证书校验保持启用。正常退出时自动清理临时 hosts 映射；被强制杀死后，可手动删除 `/etc/hosts` 中带 `# neko-agent-api-rescue-v1` 标记的行。

## 验证

```bash
python3 -m unittest discover -s tests -v
bash VPS/singbox/client/test/run-compose.sh
bash VPS/singbox/server/test/run-compose.sh
```

单元/流程测试使用临时目录和模拟安装器，不调用真实账户或修改主机服务。Compose 集成测试需要支持 systemd、cgroup 与特权容器的 Linux Docker 环境；client 测试验证 TUN/bypass，server 测试验证本地与远程配置和失败保护。

SSH 集成测试使用回环地址上的临时转发服务，验证真实 OpenSSH 的密码认证、SOCKS 下载、远端 DNS 与清理行为；需要 OpenSSH 和 Python `paramiko`（Debian/Ubuntu 包名 `python3-paramiko`），缺少时会明确跳过这组测试。

## 历史清理与公开

公开前必须同时清理文件和 Git 历史，并轮换曾提交的密码、token、节点认证值。强推新历史只替换远程引用，不能撤回已有克隆、缓存、fork 或平台保留的旧提交；若旧提交仍可访问，需要联系托管平台处理。清理后其他机器应重新克隆，避免把旧历史重新推回。
