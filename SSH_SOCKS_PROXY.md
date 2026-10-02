# 安装前的下载代理

Agent、sing-box client/server 共用 `lib/proxy.sh` 中的普通代理与临时 SSH SOCKS 隧道。默认交互选择；使用 `--env` 才读取已导出的环境变量，`--env FILE` 可直接加载指定的私有配置文件。SSH 隧道由系统 OpenSSH 提供，在 sing-box 尚未安装或运行时也可用于下载。

交互模式可以选择不使用代理、输入 HTTP/HTTPS/SOCKS 地址，或输入 SSH 主机、用户名、隐藏密码、端口及主机密钥策略。默认不校验、不登记，无需准备 known_hosts；选择自动登记或严格校验后才询问可选的 known_hosts 文件。现有代理环境变量不会作为默认答案使用。代理配置之后会询问 cc-switch 配置来源，默认 WebDAV，也可以选择本地 SQL 文件。

上面的 cc-switch 选择仅属于 Agent；client 还需订阅 URL，server 使用其本地或远程配置文件。新配置统一采用 `INSTALL_*` 变量，兼容旧 `AGENT_PROXY_*` / `AGENT_SSH_*` 名称；非空 `INSTALL_*` 值优先。

## 普通环境代理

以下配置仅在 `--env` 模式读取：

```bash
INSTALL_PROXY_MODE=env
INSTALL_PROXY_URL='http://127.0.0.1:8080'
```

`INSTALL_PROXY_URL` 同时设置 `http_proxy`、`https_proxy`、`all_proxy` 及其大写形式，也接受 `socks5h://127.0.0.1:1080`。环境模式留空时保留当前 shell 的代理设置，`NO_PROXY` / `no_proxy` 排除规则保持有效。设置 `INSTALL_PROXY_MODE=none` 可明确直连。

## 自动 SSH SOCKS

客户端需要支持 `SSH_ASKPASS_REQUIRE=force` 的 OpenSSH。Debian/Ubuntu 缺少客户端时先安装 `openssh-client`。不需要 `sshpass`，也不需要远端提供 shell、远程命令或 SFTP。

私有 `.env` 示例（替换占位值，不要提交真实内容）：

```bash
INSTALL_PROXY_MODE=ssh
INSTALL_SSH_HOST='ssh.example.com'
INSTALL_SSH_USER='bash-proxy'
INSTALL_SSH_PASSWORD='replace-with-your-password'
INSTALL_SSH_PORT=22
INSTALL_SSH_SOCKS_PORT=1080
INSTALL_SSH_HOST_KEY_CHECKING=no
INSTALL_SSH_KNOWN_HOSTS_FILE=
```

SSH 服务端需要允许该账户使用密码认证和 TCP 转发。账户的创建、权限限制与密码轮换由服务器管理员管理；安装器只建立客户端隧道。`INSTALL_PROXY_URL` 在 `ssh` 模式下不参与代理选择。

主机密钥策略通过交互选择，或在 `--env` 模式设置 `INSTALL_SSH_HOST_KEY_CHECKING`：

| 值 | 行为 |
| --- | --- |
| `no`（默认） | 不校验、不登记、不保存主机密钥，只用密码认证；忽略用户及系统 known_hosts。 |
| `accept-new` | 首次连接自动保存密钥，以后拒绝变化的密钥，无需手工登记。 |
| `yes` | 严格校验，必须事先准备可信主机密钥。 |

`no` 模式无法验证服务器身份，连接到伪造服务器时密码可能泄露。`accept-new` 记录首次遇到的密钥，后续会校验它。

`INSTALL_SSH_KNOWN_HOSTS_FILE` 仅在 `accept-new` / `yes` 下使用，默认文件为当前用户的 `~/.ssh/known_hosts`。`accept-new` 会创建缺失的目录和文件；文件必须可读写。`yes` 可使用提前准备的可信文件；非默认 SSH 端口的条目使用 OpenSSH 的 `[host]:port` 格式。

默认模式无需先运行 SSH 命令登记密钥。需要手动建立同样的隧道时，在一个终端运行：

```bash
ssh -N -D 127.0.0.1:1080 -p 22 \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null \
  bash-proxy@ssh.example.com
```

按提示输入密码即可连接。自动安装会管理自己的隧道，请先按 `Ctrl-C` 关闭手动隧道，避免占用相同端口。若需要首次自动登记，将上述三个主机密钥相关选项替换为 `-o StrictHostKeyChecking=accept-new`。

随后在 root Bash 中安装：

```bash
chmod 600 .env
bash agent/install.sh --env .env --skip-config
# 如需 WebDAV 同步，填写相应环境变量后去掉 --skip-config。
bash VPS/singbox/client/install.sh --env .env
bash VPS/singbox/server/install.sh --env .env
```

安装器在第一次联网前启动 `ssh -N -D 127.0.0.1:端口`，仅使用密码认证，并按所选策略处理主机密钥。自动隧道使用显式参数，不读取个人 SSH config 中的 ProxyCommand、跳板、转发或远程命令设置。

隧道就绪后，大小写 HTTP/HTTPS/ALL_PROXY 都指向 `socks5h://127.0.0.1:端口`，域名通过 SOCKS 在远端解析。环境会传给下载的安装脚本，使其中的后续下载也使用代理；WebDAV 命令同样继承这些变量。只有 `--env` 模式会继承 `NO_PROXY` / `no_proxy` 来使指定目的地直连。

密码只通过 SSH 进程和临时 askpass helper 的环境传递，不放入命令行、临时脚本正文或日志，也不传给下载的安装器。隧道只属于本次安装，成功、失败以及 `INT` / `TERM` / `HUP` 时均会回收。已安装工具和已成功同步的配置全部跳过时，不建立 SSH 连接。

sing-box 安装器会在必要的依赖下载、GitHub 二进制下载和远程配置下载前建立隧道，下载校验完成后关闭隧道，再启动 sing-box 服务。此代理不写入 sing-box 的 systemd 服务，运行配置由 Xboard 或服务端配置文件负责。

连接失败、密码错误、主机密钥错误或端口已占用会停止安装；不会自动退回直连或旧明文代理。修复后直接重跑即可继续。SSH 日志位于各自私有状态目录中的 `ssh-proxy.log`：Agent 为 `~/.local/state/neko-agent-install`，client/server 为 `~/.local/state/neko-sing-box-client-install` / `neko-sing-box-server-install`，通用包装器为 `~/.local/state/neko-proxy`。

## 其他命令使用代理

```bash
bash with-proxy.sh --env .env -- git pull --ff-only
bash with-proxy.sh --env .env -- bash VPS/ONE_STEP_INIT.sh
```

省略 `--env` 可交互输入。包装器先准备代理，再执行命令并在退出时回收自己创建的隧道；适用于 curl、Git HTTP(S)、APT 等会读取这些代理环境变量的程序。`--env FILE` 还会将文件中其他变量导出给命令（SSH 密码除外），以便被包装的脚本读取自己的配置。client/server/Agent 已内置代理支持，直接使用各自的 `--env` 即可。

## 手动使用

也可由自己管理隧道，在第一个终端运行上面的 `ssh -N -D ...` 命令；第二个终端设置：

```bash
export INSTALL_PROXY_MODE=env
export INSTALL_PROXY_URL='socks5h://127.0.0.1:1080'
bash agent/install.sh --env --skip-config
```

手动模式的隧道由第一个终端中的 `Ctrl-C` 关闭，安装器不会停止它。代理只对设置了环境变量的进程生效，不启用 TUN、不修改路由，也不写入 shell 的持久代理设置。

服务端密码变更后，在下次交互时输入新密码，或更新私有 `.env` 中的 `INSTALL_SSH_PASSWORD` 后使用 `--env .env` 运行。仓库不包含特定服务器的管理凭据或改密命令。
