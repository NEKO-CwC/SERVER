# Agent 下载代理

Agent 安装器支持代理地址和安装期间按需启动的 SSH SOCKS 隧道。默认运行 `bash agent/install.sh` 后交互选择；使用 `--env` 才读取已导出的环境变量，`--env FILE` 可直接加载指定的私有配置文件。

交互模式可以选择不使用代理、输入 HTTP/HTTPS/SOCKS 地址，或输入 SSH 主机、用户名、隐藏密码、端口及主机密钥策略。默认不校验、不登记，无需准备 known_hosts；选择自动登记或严格校验后才询问可选的 known_hosts 文件。现有代理环境变量不会作为默认答案使用。代理配置之后会询问 cc-switch 配置来源，默认 WebDAV，也可以选择本地 SQL 文件。

## 普通环境代理

以下配置仅在 `--env` 模式读取：

```bash
AGENT_PROXY_MODE=env
AGENT_PROXY_URL='http://127.0.0.1:8080'
```

`AGENT_PROXY_URL` 同时设置 `http_proxy`、`https_proxy`、`all_proxy` 及其大写形式，也接受 `socks5h://127.0.0.1:1080`。环境模式留空时保留当前 shell 的代理设置，`NO_PROXY` / `no_proxy` 排除规则保持有效。设置 `AGENT_PROXY_MODE=none` 可明确直连。

## 自动 SSH SOCKS

客户端需要支持 `SSH_ASKPASS_REQUIRE=force` 的 OpenSSH。Debian/Ubuntu 缺少客户端时先安装 `openssh-client`。不需要 `sshpass`，也不需要远端提供 shell、远程命令或 SFTP。

私有 `.env` 示例（替换占位值，不要提交真实内容）：

```bash
AGENT_PROXY_MODE=ssh
AGENT_SSH_HOST='ssh.example.com'
AGENT_SSH_USER='bash-proxy'
AGENT_SSH_PASSWORD='replace-with-your-password'
AGENT_SSH_PORT=22
AGENT_SSH_SOCKS_PORT=1080
AGENT_SSH_HOST_KEY_CHECKING=no
AGENT_SSH_KNOWN_HOSTS_FILE=
```

SSH 服务端需要允许该账户使用密码认证和 TCP 转发。账户的创建、权限限制与密码轮换由服务器管理员管理；安装器只建立客户端隧道。`AGENT_PROXY_URL` 在 `ssh` 模式下不参与代理选择。

主机密钥策略通过交互选择，或在 `--env` 模式设置 `AGENT_SSH_HOST_KEY_CHECKING`：

| 值 | 行为 |
| --- | --- |
| `no`（默认） | 不校验、不登记、不保存主机密钥，只用密码认证；忽略用户及系统 known_hosts。 |
| `accept-new` | 首次连接自动保存密钥，以后拒绝变化的密钥，无需手工登记。 |
| `yes` | 严格校验，必须事先准备可信主机密钥。 |

`no` 模式无法验证服务器身份，连接到伪造服务器时密码可能泄露。`accept-new` 记录首次遇到的密钥，后续会校验它。

`AGENT_SSH_KNOWN_HOSTS_FILE` 仅在 `accept-new` / `yes` 下使用，默认文件为当前用户的 `~/.ssh/known_hosts`。`accept-new` 会创建缺失的目录和文件；文件必须可读写。`yes` 可使用提前准备的可信文件；非默认 SSH 端口的条目使用 OpenSSH 的 `[host]:port` 格式。

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
```

安装器在第一次联网前启动 `ssh -N -D 127.0.0.1:端口`，仅使用密码认证，并按所选策略处理主机密钥。自动隧道使用显式参数，不读取个人 SSH config 中的 ProxyCommand、跳板、转发或远程命令设置。

隧道就绪后，大小写 HTTP/HTTPS/ALL_PROXY 都指向 `socks5h://127.0.0.1:端口`，域名通过 SOCKS 在远端解析。环境会传给下载的安装脚本，使其中的后续下载也使用代理；WebDAV 命令同样继承这些变量。只有 `--env` 模式会继承 `NO_PROXY` / `no_proxy` 来使指定目的地直连。

密码只通过 SSH 进程和临时 askpass helper 的环境传递，不放入命令行、临时脚本正文或日志，也不传给下载的安装器。隧道只属于本次安装，成功、失败以及 `INT` / `TERM` / `HUP` 时均会回收。已安装工具和已成功同步的配置全部跳过时，不建立 SSH 连接。

连接失败、密码错误、主机密钥错误或端口已占用会停止安装；不会自动退回直连或旧明文代理。修复后直接重跑即可继续。SSH 日志保存在 `~/.local/state/neko-agent-install/ssh-proxy.log`，遵循安装器的私有目录权限；如设置 `AGENT_INSTALL_STATE_DIR`，日志跟随该目录。

## 手动使用

也可由自己管理隧道，在第一个终端运行上面的 `ssh -N -D ...` 命令；第二个终端设置：

```bash
export AGENT_PROXY_MODE=env
export AGENT_PROXY_URL='socks5h://127.0.0.1:1080'
bash agent/install.sh --env --skip-config
```

手动模式的隧道由第一个终端中的 `Ctrl-C` 关闭，安装器不会停止它。代理只对设置了环境变量的进程生效，不启用 TUN、不修改路由，也不写入 shell 的持久代理设置。

服务端密码变更后，在下次交互时输入新密码，或更新私有 `.env` 中的 `AGENT_SSH_PASSWORD` 后使用 `--env .env` 运行。仓库不包含特定服务器的管理凭据或改密命令。
