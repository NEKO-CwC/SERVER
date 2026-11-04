# SERVER

Linux VPS 基础初始化、Agent 安装，以及独立的 sing-box client/server 部署脚本。

## 目录

| 入口 | 用途 |
| --- | --- |
| `agent/install.sh` | 安装 Magpie、Claude Code、Codex，导入配置并写入 cc/cx aliases |
| `agent/migrate-ccs-to-magpie.sh` | 已安装 CCS 的 Linux 客户端迁移：恢复 Magpie 配置、移除旧命令 |
| `VPS/ONE_STEP_INIT.sh` | 系统包、Docker、网络设置、仓库与 MOTD 初始化 |
| `VPS/singbox/client/install.sh` | 获取 Xboard 订阅配置，部署客户端与 SSH/HTTP/HTTPS/Tailscale bypass |
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

`.env` 是 Bash 文件，只加载自己信任的文件；值含空格、`&`、`$` 等字符时使用单引号。脚本不会自动加载当前目录的环境文件。`.env`、Magpie 加密备份、SQL 导出、日志、数据库、证书私钥和 `VPS/singbox/**/config.json` 已加入忽略规则。生产配置建议直接放在仓库外，禁止使用 `git add -f` 提交凭据。

## Agent 安装与重试

在 root Bash 中选择输入方式：

```bash
bash agent/install.sh                       # 默认交互输入
bash agent/install.sh --env                 # 使用已导出的环境变量，不提问
bash agent/install.sh --env /secure/agent.env # 加载指定环境文件，不提问
```

默认交互流程先选择代理方式（不使用代理、HTTP/HTTPS/SOCKS 地址、SSH SOCKS），再选择 Magpie 配置来源：**WebDAV（默认）或本地 Magpie 加密备份**。WebDAV 登录密码和独立加密口令均隐藏输入；必填项不能为空。交互模式不采用现有 Agent 配置变量作为默认答案。Magpie 会把连接密码和加密口令保存在自己的配置中；本安装器不额外保存明文凭据。

安装使用官方命令对应的脚本：

```bash
curl -fsSL https://usemagpie.ai/install.sh | sh
```

安装器先通过现有代理/重试逻辑下载该脚本，再用 `sh` 执行。Claude Code、Codex 安装完成后才恢复 Magpie 配置，使 Magpie 能识别这些 agent。

无终端时必须使用 `--env` 或 `--env FILE`；缺少必填配置会在安装前报错。`--env FILE` 按 Bash 语法读取明确指定的可信文件，文件中的赋值覆盖同名环境变量；不会自动查找 `.env`。

环境模式下的配置来源：

- `MAGPIE_CONFIG_SOURCE=dav`（默认）：填写 `MAGPIE_WEBDAV_BASE_URL`、`MAGPIE_WEBDAV_USERNAME`、`MAGPIE_WEBDAV_PASSWORD`、`MAGPIE_PASSPHRASE`。URL 是 Magpie 自己的 `magpie` 目录的父目录；Magpie 会再追加 `/magpie`。加密口令不能与 DAV 密码相同。
- `MAGPIE_CONFIG_SOURCE=backup`：填写 `MAGPIE_BACKUP_FILE`、`MAGPIE_PASSPHRASE`，指向本地可读的原生 `.magpie-backup` 加密备份，无需 DAV 凭据。

环境模式下的代理由 `INSTALL_PROXY_MODE` 选择：`none` 为直连；`env`（默认）使用 `INSTALL_PROXY_URL`，为空时继承已设置的 HTTP/HTTPS/ALL_PROXY；`ssh` 使用 `INSTALL_SSH_HOST`、`INSTALL_SSH_USER`、`INSTALL_SSH_PASSWORD` 建立临时隧道。这套 `INSTALL_*` 配置由 Agent、sing-box client/server 和 `with-proxy.sh` 共同使用；旧的 `AGENT_PROXY_*` / `AGENT_SSH_*` 变量仍可使用，同名用途的非空 `INSTALL_*` 值优先。

SSH 只在需要下载或 WebDAV 同步时启动，安装成功、失败或终止后关闭。默认仅用密码连接，不预先登记、不保存或校验服务器主机密钥；也可选择 `accept-new` 或严格校验 `yes`。详细设置见 [SSH_SOCKS_PROXY.md](SSH_SOCKS_PROXY.md)。脚本不配置远端账户、不启用 TUN，也不修改路由。

显式选项：

```bash
bash agent/install.sh --backup-file /secure/magpie.magpie-backup # 询问代理及加密口令
bash agent/install.sh --skip-config                            # 只安装工具并写 aliases
bash agent/install.sh --env --backup-file /secure/magpie.magpie-backup
bash agent/install.sh --env /secure/agent.env --verify           # 启动常驻网关并验证两种客户端
```

`--backup-file` 优先于环境中的配置来源。旧 `--sql-file` 会提示先迁移并导出 Magpie 原生备份；Magpie 无法直接读取 CC Switch SQL。旧 `CC_SWITCH_*` 配置变量已改为 `.env.example` 中的 `MAGPIE_*` 变量。

WebDAV 使用 `magpie webdav on` 同步，登录密码和加密口令通过标准输入传入，不放在命令参数中，也不传给下载的安装程序；同步包含 API keys、agent 模型和 Library，自动同步关闭。Magpie 首次接入已有远端时采用其合并/恢复规则，可能替换本机不同的配置，并由 Magpie 保留副本。它不是只读下载工具；请连接到已经准备好的 Magpie 备份目录，不能把旧 CC Switch 数据目录当成 Magpie 备份直接使用。

需要 DAV 同步时，安装工具之前先对远端备份发送只读 HEAD 请求，复用所选代理，凭据通过标准输入交给 curl。网络不可达、401/403、404 会分别提示检查路由/代理、登录权限、同步目录；此时停止，不改写 agent 配置。DAV 不支持 HEAD（405/501）时继续由 Magpie 同步确认。不强制选择 IPv4，也不自动创建代理或修改路由；仅有 IPv6 地址的 DAV 在无 IPv6 路由的机器上需要可用代理。已有相同配置成功记录且无需同步时跳过预检，本地备份来源无需访问 DAV。

- 每次运行都检查工具的 `--version`；正常则跳过，缺失或不可运行则重新安装。
- 配置成功且 Magpie 的 `providers.json` 存在时保存来源指纹；相同来源重跑跳过同步。备份内容、DAV 参数或加密口令变化会重新同步。
- `--refresh-config` 强制重新同步/恢复；相同 URL 的远端内容变化需要使用此参数。
- `--force` 强制重装工具；重新同步配置需另加 `--refresh-config`。
- aliases 可重复写入。运行 `source ~/.bashrc` 后可使用 `cc` / `cx`；它们沿用跳过权限确认的启动参数。`agent/cc.sh` 直接启动 Claude，读取 Magpie 已写入的原生设置，不再注入旧 provider 环境变量。

状态默认在 `~/.local/state/neko-agent-install/`（目录权限 700）。失败配置日志可能含凭据，仅保存于此目录，成功后删除；成功指纹不包含明文凭据。`--env` 模式可用 `AGENT_INSTALL_STATE_DIR` 调整状态目录、`AGENT_BASHRC` 调整 aliases 文件。Magpie 配置位于 `${XDG_CONFIG_HOME:-~/.config}/magpie`；在环境文件中设置 `XDG_CONFIG_HOME` 可调整其父目录。

使用 Magpie 代理模型时必须保持网关运行。默认不配置服务；前台可用 `magpie serve`。加 `--start-gateway` 会检查 systemd 用户服务环境，执行 `magpie daemon install --no-web` 并启用用户 linger，使服务在退出登录后继续运行；检查默认本机端口 3425 是否响应，不打开 Web 管理页面或局域网访问。自定义网关端口应自行管理服务。

`--verify` 包含上述服务启动，并在独立临时工作目录让 Claude、Codex 各发起一次真实请求，要求返回 `MAGPIE_OK` 且不使用工具；每次调用最多 120 秒，Codex 使用临时会话。验证显式关闭标准输入，避免通过 SSH 执行时等待输入。调用按所选模型正常计费；失败日志仅写入私有状态目录，不打印凭据。默认不发送模型请求，完成时明确提示“尚未验证”。安装阶段的临时代理不会自动变成网关长期使用的代理；订阅 OAuth 登录仍需自行完成。

本机迁移结果及交给 Claude Code 的 Codex 迁移说明见 [Magpie 迁移交接文档](docs/handoffs/magpie-migration-20261101.md)。

## 已有 CCS 客户端迁移

先在配置源机器上完成 Magpie 迁移并同步 DAV，确保需要的 Claude/Codex 模型和 Library 分配已包含在备份中。客户端使用与上面安装器相同的 `MAGPIE_*` 和代理变量，DAV URL 改成已准备好的 Magpie 同步父目录，不能沿用 CCS 的 Remote Root/Profile 或 SQL 文件。

在原客户端的 root 账户、原 HOME 中运行，先关闭 Claude、Codex、CC Switch 和 Magpie 网关，停止对应后台服务：

```bash
bash agent/migrate-ccs-to-magpie.sh
bash agent/migrate-ccs-to-magpie.sh --env /secure/agent.env
bash agent/migrate-ccs-to-magpie.sh --env /secure/agent.env --verify
# 离线配置源（安装缺失工具仍可能需要联网）：
bash agent/migrate-ccs-to-magpie.sh --env /secure/agent.env --backup-file /secure/config.magpie-backup
```

脚本检查运行进程和常见 systemd 服务，与安装器共用锁；安装缺失工具、强制恢复指定配置并同步 Library。配置回退交给 Magpie 自身，不额外归档 Claude/Codex 目录、历史会话、缓存或 CCS 数据库。迁移记录位于 `~/.local/state/neko-agent-install/ccs-migration.XXXXXX/`，目录权限 700。

恢复与 aliases 写入都成功后，PATH 中的 `cc-switch` 可执行文件移到迁移状态目录的 `bin/`，原路径记录于 `binaries.tsv`；指定了 `--start-gateway`/`--verify` 时，还须服务启动/实际调用验证成功才移除旧命令。`complete` 文件表示所选步骤全部成功，默认仅代表配置迁移成功。旧 CCS 数据目录保留，以免破坏仍指向它的技能链接；旧 DAV 远端保留。脚本不转换本机 CCS 数据库，也不自动搬运仅存在于旧 CCS 的条目。自定义 shell 函数、PATH 外安装副本和自行创建的服务需要另行检查。

失败时会显示状态目录；配置恢复失败不会移除 CCS 命令，但 Magpie 可能已部分改写原生配置。修正问题后可重跑。配置回退使用 Magpie 自带功能（DAV 恢复对应 `magpie webdav undo`）；若还需恢复旧 CCS 命令，按 `binaries.tsv` 将保存的命令移回原路径。

完成后重新登录加载 aliases。未选择启动/验证选项时，需自行运行网关并核对模型和连接；已完成迁移的机器可用 `bash agent/install.sh --env /secure/agent.env --verify` 补做调用验证，相同配置会跳过 DAV 同步。迁移脚本拒绝 `--skip-config`，不自动终止正在运行的客户端，也不替你完成订阅 OAuth 登录。

## sing-box client

要求 root、运行中的 systemd；自动补齐依赖支持 Debian/Ubuntu。

```bash
bash VPS/singbox/client/install.sh # 交互选择代理并输入订阅 URL
bash VPS/singbox/client/install.sh --env .env # 读取代理和 SUBSCRIPTION_URL
```

订阅请求使用带内核版本的 `User-Agent: sing-box/1.14.4`（覆盖 `SINGBOX_VERSION` 时同步变化），Xboard 必须返回该版本可直接运行的完整 JSON。每次执行都会获取并校验配置，校验成功后备份旧配置、替换并重启。已安装且版本匹配的二进制会复用；若已装内核缺少 `libcronet.so`（旧安装器只复制了可执行文件），安装器会重新下载压缩包补上该库。默认版本为 `1.14.4`。

需要持久化本机出口等配置时，在仓库外创建 `/etc/sing-box-client/config.override.json`（建议权限 `600`）。安装器使用当前版本的 `sing-box merge` 合并订阅与此文件，再校验最终配置；合并或校验失败不修改运行文件。例如，多网卡机器存在断链的默认出口时，可明确指定实际可用接口：

```json
{"route":{"auto_detect_interface":false,"default_interface":"eth0"}}
```

将 `eth0` 替换为本机接口；不要把某台机器的接口名写入通用订阅模板。覆盖文件遵循 sing-box 的合并语义，推荐用于标量字段；数组不是按 `tag` 修改单个节点的补丁。原订阅和覆盖文件均保持原样，最终运行配置保存到 `config.json`。

客户端安装前会暂存旧配置、二进制、动态库、bypass 脚本和两个自有 unit。替换或启动失败时，自动恢复这些文件及客户端原来的启用/运行状态；首次安装失败则移除本次创建的文件并禁用客户端。恢复失败会保留恢复目录并报出路径。回退不包含订阅外的 systemd drop-in、DNS/CNI 配置或运行缓存；若这些本机配置本身有错，恢复旧文件也不能保证旧服务可启动。

`naive` 出站通过动态加载 `libcronet.so` 工作，sing-box 只在该可执行文件所在目录查找它。上游 1.13.0 起把该库放进发布压缩包，因此安装器现在把 `sing-box` 和 `libcronet.so` 一起装到 `/usr/local/lib/sing-box-client/`。缺少此库时，含 `naive` 节点的订阅会在校验阶段报 `initialize outbound[N]: cronet: library not found`。

安装前无需运行 sing-box：选择 SSH 代理时，安装器用系统 OpenSSH 建立独立 SOCKS 隧道，供依赖安装、GitHub 二进制和订阅配置下载使用。下载与校验完成后关闭隧道，再安装文件并启动客户端。SSH 模式需要预先具备 OpenSSH 客户端；无法通过尚未建立的 SSH 隧道安装 SSH 自身。Debian/Ubuntu 的 APT 支持这里使用的 `socks5h` 代理环境。

无终端自动化请加 `--env`。命令行订阅 URL 优先于 `SUBSCRIPTION_URL`，例如 `bash VPS/singbox/client/install.sh --env .env 'https://subscription.example.com/config'`。

客户端提供 SSH、HTTP/HTTPS 入站回程及 Tailscale 的 IPv4/IPv6 bypass。默认保护公网接口收到的 TCP 22（SSH）、80、443 入站连接；宿主机回复和 Docker bridge/DNAT 转发回复都恢复连接标记，优先查询 `main` 路由表。本机主动访问 HTTP/HTTPS 仍遵循 sing-box 路由，主动 SSH 连接保留原有直连行为。公网接口目前仍需具有 IPv4 地址。

`SSH_PORT` 可指定非 22 端口；`INGRESS_TCP_PORTS` 是额外保护的 TCP 入站端口，默认为 `80,443`，使用逗号分隔；设为空字符串可只保护 SSH。端口按宿主机实际入口、DNAT 前的端口填写，例如 `443:8443` 映射填 `443`。使用 systemd override 持久化配置：

```ini
# systemctl edit sing-box-client-bypass.service
[Service]
Environment=SSH_PORT=2222
Environment=INGRESS_TCP_PORTS=80,443,8443
```

保存后运行 `systemctl daemon-reload` 和 `systemctl reload sing-box-client-bypass.service`。规则重载以单次 nft 事务替换自有表，失败时保留旧 nft 规则；策略路由重复加载不会叠加。脚本使用保留位 `0x100`，写入时保留其他 mark 位；部署前应确认该位及策略路由优先级 `5000` 与其他网络组件不冲突，并早于 sing-box 的接管规则。Kubernetes/CNI、跨节点转发与多公网出口需结合实际路由适配，此处不提供通用保证。

`VPS/singbox/client/template.json` 保存适配 1.14 的 NEKO 订阅模板，包含本项目的 NetBird/K8s 内网 DNS 和直连规则。订阅端必须填充真实节点及 selector/urltest 的节点列表后才能运行；安装器仍下载订阅端生成的完整配置，不会自动合并此模板，也不会修改现有集群网络。

升级模板修正了节点 DNS 的引导解析：`dns-node` 使用独立的直连 DoH，省略空 `direct` 出站的 `detour`，并将 `route.default_domain_resolver` 指向 `dns-node`，避免代理节点域名仍由 `ali-dns` 解析。模板同时移除未使用的旧 `block` 出站和 `independent_cache`，将远程规则集下载迁移到 1.14 的显式 `http_clients` / `route.default_http_client`。先更新订阅端模板，再重新运行安装器获取配置；下载或配置校验失败时不会替换当前运行配置。

该模板含 1.14 新字段，使用它的客户端也需要升级内核。版本依据：[1.14.4 稳定版](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4)、[官方迁移说明](https://sing-box.sagernet.org/migration/)；升级细节见 [验证记录](docs/validation/singbox-1.14.4-20261028.md)。

若出现 `route.default_http_client: json: unknown field "default_http_client"`，校验配置的内核通常仍低于 1.14。先确认服务器已取得包含 1.14.4 升级的安装器，再检查环境或 `--env` 文件是否固定了旧 `SINGBOX_VERSION`。安装日志会显示目标版本，以及实际执行配置校验的二进制版本和路径；此类校验失败不会替换现有二进制或配置。仅更新订阅模板、没有更新安装器时，旧客户端仍会收到无法识别的新字段。

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

安装器只管理 `sing-box-client.service` 和 `sing-box-client-bypass.service`。本机另加的 DNS guard、site bypass、审计和定时器必须单独核对：DNS guard 的接口名应与新订阅的 TUN `interface_name` 一致，审计应读取新服务日志；旧定时器需停止、禁用并按需归档。保留在 `*.service.d/` 中的 drop-in 在重装后仍会生效，单纯重跑安装器不能修复这些本机设置。确认不再被引用后再归档旧 unit；不要直接删除仍服务于 K8s/CNI 或内网入口的规则。

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

`tests/test_singbox_bypass.py` 包含重载失败保护、旧规则迁移和清理测试；以 Linux root 运行且内核支持 network namespace、veth、nftables 时，还会在三个临时网络命名空间中验证真实 IPv4/IPv6 HTTP 入站、DNAT 端口映射回程、mark 位保留，以及主动 HTTP/HTTPS 仍遵循代理路由。网络测试缺少条件时明确跳过；它不修改宿主机的网络规则。

SSH 集成测试使用回环地址上的临时转发服务，验证真实 OpenSSH 的密码认证、SOCKS 下载、远端 DNS 与清理行为；需要 OpenSSH 和 Python `paramiko`（Debian/Ubuntu 包名 `python3-paramiko`），缺少时会明确跳过这组测试。

## 历史清理与公开

公开前必须同时清理文件和 Git 历史，并轮换曾提交的密码、token、节点认证值。强推新历史只替换远程引用，不能撤回已有克隆、缓存、fork 或平台保留的旧提交；若旧提交仍可访问，需要联系托管平台处理。清理后其他机器应重新克隆，避免把旧历史重新推回。
