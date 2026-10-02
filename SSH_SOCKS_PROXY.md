# Agent 下载代理

Agent 安装器支持现有环境代理，以及安装期间按需启动的 SSH SOCKS 隧道。两种方式都通过私有 `.env` 配置，加载后运行同一个 `agent/install.sh`。

## 普通环境代理

```bash
AGENT_PROXY_MODE=env
AGENT_PROXY_URL='http://127.0.0.1:8080'
```

`AGENT_PROXY_URL` 同时设置 `http_proxy`、`https_proxy`、`all_proxy` 及其大写形式，也接受 `socks5h://127.0.0.1:1080`。留空则保留当前 shell 的代理设置。`NO_PROXY` / `no_proxy` 排除规则保持有效。

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
AGENT_SSH_KNOWN_HOSTS_FILE=
```

SSH 服务端需要允许该账户使用密码认证和 TCP 转发。账户的创建、权限限制与密码轮换由服务器管理员管理；安装器只建立客户端隧道。`AGENT_PROXY_URL` 在 `ssh` 模式下不参与代理选择。

**首次连接前先核对服务器主机密钥。** 使用与安装器相同的本地用户（安装器要求 root），在交互终端执行：

```bash
ssh -N -D 127.0.0.1:1080 -p 22 -o ExitOnForwardFailure=yes bash-proxy@ssh.example.com
```

与管理员通过可信渠道核对显示的指纹后再接受。密码认证完成后按 `Ctrl-C` 关闭手动隧道，再启动自动安装，避免占用相同端口。也可设置 `AGENT_SSH_KNOWN_HOSTS_FILE` 指向提前准备好的可信主机密钥文件；非默认 SSH 端口的条目使用 OpenSSH 的 `[host]:port` 格式。

随后在 root Bash 中加载配置并安装：

```bash
chmod 600 .env
set -a
source .env
set +a
bash agent/install.sh --skip-config
# 如需 WebDAV 同步，填写相应环境变量后去掉 --skip-config。
```

安装器在第一次联网前启动 `ssh -N -D 127.0.0.1:端口`，仅使用密码认证。主机密钥校验始终启用，未知或变化的密钥会报错，不会自动信任。自动隧道使用显式参数，不读取个人 SSH config 中的 ProxyCommand、跳板、转发或远程命令设置。

隧道就绪后，大小写 HTTP/HTTPS/ALL_PROXY 都指向 `socks5h://127.0.0.1:端口`，域名通过 SOCKS 在远端解析。环境会传给下载的安装脚本，使其中的后续下载也使用代理；WebDAV 命令同样继承这些变量。`NO_PROXY` / `no_proxy` 仍可使指定目的地直连。

密码只通过 SSH 进程和临时 askpass helper 的环境传递，不放入命令行、临时脚本正文或日志，也不传给下载的安装器。隧道只属于本次安装，成功、失败以及 `INT` / `TERM` / `HUP` 时均会回收。已安装工具和已成功同步的配置全部跳过时，不建立 SSH 连接。

连接失败、密码错误、主机密钥错误或端口已占用会停止安装；不会自动退回直连或旧明文代理。修复后直接重跑即可继续。SSH 日志保存在 `~/.local/state/neko-agent-install/ssh-proxy.log`，遵循安装器的私有目录权限；如设置 `AGENT_INSTALL_STATE_DIR`，日志跟随该目录。

## 手动使用

也可由自己管理隧道，在第一个终端运行上面的 `ssh -N -D ...` 命令；第二个终端设置：

```bash
export AGENT_PROXY_MODE=env
export AGENT_PROXY_URL='socks5h://127.0.0.1:1080'
bash agent/install.sh --skip-config
```

手动模式的隧道由第一个终端中的 `Ctrl-C` 关闭，安装器不会停止它。代理只对设置了环境变量的进程生效，不启用 TUN、不修改路由，也不写入 shell 的持久代理设置。

服务端密码变更后，只更新私有 `.env` 中的 `AGENT_SSH_PASSWORD`，重新加载环境并运行安装器。仓库不包含特定服务器的管理凭据或改密命令。
