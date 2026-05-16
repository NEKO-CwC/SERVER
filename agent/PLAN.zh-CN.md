# Linux Claude Code Agent 安装脚本实施计划

## 1. 背景与目标

在仓库新增 `agent/` 目录，实现一个 Linux 一键安装脚本，用于在轻量 Linux 环境或 VPS 上快速完成 Claude Code + cc-switch + WebDAV 配置 + `cc` 普通用户启动器的安装。

目标安装效果：

1. 自动设置 HTTP/HTTPS 代理环境变量。
2. 根据平台检测并在 Linux 上安装 `cc-switch`。
3. 持久化 `PATH="/root/.local/bin:$PATH"`，使 root 能直接调用 `cc-switch`。
4. 使用 `cc-switch` CLI 配置 WebDAV，并下载远端最近配置。
5. 安装最新版 Claude Code。
6. 注入 `IS_SANDBOX=true` 环境变量，并创建 `cc` alias 指向 Claude Code 启动命令。
7. 创建 `/usr/local/bin/cc` 启动脚本：注入 `IS_SANDBOX=true`，在当前工作目录启动 `claude --dangerously-skip-permissions`。
8. 每个阶段落地后，用 Docker 轻量 Linux 环境验证该阶段功能。
9. 日志要实时展示当前进度；出现错误要及时报告，并尽可能回滚本脚本创建的系统文件。

## 2. 目录与交付物

建议最终目录：

```text
agent/
  PLAN.zh-CN.md              # 本计划
  START_PROMPT.zh-CN.md      # 交给下一个 agent 的启动 prompt
  install.sh                 # Linux 一键安装脚本
  cc.sh                      # cc 启动器模板，安装时复制到 /usr/local/bin/cc
  docker-test.sh             # 可选：本地 Docker 阶段测试入口
```

如果实现时为了简单，也可以把 `cc.sh` 作为 heredoc 内嵌到 `install.sh`，但优先保留独立 `cc.sh`，方便审查和测试。

## 3. 已确认的关键可行性

### 3.1 cc-switch 安装命令

Linux 安装命令按需求固定为：

```bash
curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash
```

安装后通常位于：

```text
/root/.local/bin/cc-switch
```

### 3.2 cc-switch WebDAV CLI 能力

已从 `SaladDay/cc-switch-cli` README 与源码确认，WebDAV 配置与同步可通过 CLI 非交互完成。

支持命令：

```bash
cc-switch config webdav show
cc-switch config webdav set --base-url <url> --remote-root <root> --profile <profile> --username <user> --password <password> --enable --no-auto-sync
cc-switch config webdav check-connection
cc-switch config webdav download
```

源码确认 `config webdav set` 支持字段：

- `--base-url`
- `--remote-root`
- `--profile`
- `--username`
- `--password`
- `--enable` / `--disable`
- `--auto-sync` / `--no-auto-sync`

用户提供的 WebDAV 配置对应 CLI：

```bash
cc-switch config webdav set \
  --base-url "https://openlist.neko-dashboard.com:8443/dav" \
  --remote-root "cc-switch-sync" \
  --profile "default" \
  --username "dav" \
  --password "ercvddDwdFcNaFyCbtX9wt7ARUTQzjLC" \
  --enable \
  --no-auto-sync

cc-switch config webdav check-connection
cc-switch config webdav download
```

注意：`status` 字段由 `cc-switch` 自己维护，不应由安装脚本手动写入。

### 3.3 密码处理约束

用户已明确授权：WebDAV 密码可以明文写入本仓库，因为该仓库最终会上传到用户私人仓库，GitHub 云端仅作为备份。

安装脚本应内置默认密码：

```bash
WEBDAV_PASSWORD="${CC_SWITCH_WEBDAV_PASSWORD:-ercvddDwdFcNaFyCbtX9wt7ARUTQzjLC}"
```

实现要求：

- 默认无需交互，直接使用内置密码完成 WebDAV 配置。
- 仍保留 `CC_SWITCH_WEBDAV_PASSWORD` 环境变量覆盖能力，便于未来轮换密码。
- 允许密码出现在 `agent/install.sh` 和本计划中。
- 日志中仍不要主动打印密码，避免终端历史和 CI 日志扩散。

## 4. 分阶段实施计划

### Phase 0：团队模式启动与上下文分工

实施时必须优先使用 team 模式加快工作效率。

建议团队角色：

1. `planner/reviewer`：审查计划、风险点和验收标准。
2. `script-dev`：实现 `install.sh` 与 `cc.sh`。
3. `docker-tester`：设计并运行 Docker 阶段测试。
4. `security-reviewer`：检查密码处理、IS_SANDBOX 注入、curl pipe bash、回滚逻辑。

并行策略：

- `script-dev` 先实现 Phase 1-3 的骨架与日志。
- `docker-tester` 同步准备 Docker 测试命令和临时容器策略。
- `security-reviewer` 同步检查明文密码是否符合用户授权边界、IS_SANDBOX 注入安全性、是否有危险回滚。
- 每个 Phase 完成后，至少让一个 reviewer 做快速检查再进入下一 Phase。

### Phase 1：脚本骨架、日志与平台检测

实现内容：

- 新增 `agent/install.sh`。
- 使用：

```bash
#!/usr/bin/env bash
set -euo pipefail
```

- 实现日志函数：
  - `log_step`
  - `log_info`
  - `log_warn`
  - `log_error`
  - `log_ok`
- 实现错误处理：
  - `trap 'on_error $LINENO' ERR`
  - 回滚栈：`register_rollback`、`run_rollbacks`
- 实现 root 检查：必须 root 执行。
- 实现 Linux 检查：非 Linux 明确报错退出。
- 实现基础命令检测：`curl`、`bash`、`id`、`getent`、`chmod`、`install` 等。

Docker 测试：

```bash
docker run --rm -v "$PWD:/repo" -w /repo debian:bookworm bash agent/install.sh --dry-run
```

如果实现 `--dry-run` 成本过高，可先用：

```bash
docker run --rm -v "$PWD:/repo" -w /repo debian:bookworm bash -n agent/install.sh
```

验收标准：

- `bash -n agent/install.sh` 通过。
- Debian 容器内能启动脚本并打印 Phase 1 日志。
- 非 Linux 分支代码存在，但实际可不在 Docker 中测。

### Phase 2：代理环境变量与 PATH 持久化

实现内容：

代理值：

```text
http://la-new.284072.xyz:20081
```

写入：

```text
/etc/profile.d/cc-agent-proxy.sh
/etc/profile.d/cc-switch-path.sh
```

代理文件内容：

```bash
export http_proxy="http://la-new.284072.xyz:20081"
export https_proxy="http://la-new.284072.xyz:20081"
export HTTP_PROXY="http://la-new.284072.xyz:20081"
export HTTPS_PROXY="http://la-new.284072.xyz:20081"
```

PATH 文件内容：

```bash
export PATH="/root/.local/bin:$PATH"
```

当前进程也立即 export，保证后续命令生效。

回滚：

- 如果文件由本次创建，失败时删除。
- 如果文件已存在，先备份为 `.bak.<timestamp>`，失败时恢复。

Docker 测试：

```bash
docker run --rm -v "$PWD:/repo" -w /repo debian:bookworm bash -lc '
  bash agent/install.sh --phase proxy-path-test || exit 1
  test -f /etc/profile.d/cc-agent-proxy.sh
  test -f /etc/profile.d/cc-switch-path.sh
  grep -q "la-new.284072.xyz:20081" /etc/profile.d/cc-agent-proxy.sh
'
```

如果不实现 phase 参数，可以用脚本内测试模式或拆成函数后 source 测试。

验收标准：

- 文件正确创建。
- 当前 shell 中 `http_proxy`、`https_proxy`、`PATH` 生效。
- 回滚路径不覆盖用户已有文件。

### Phase 3：安装 cc-switch 并验证

实现内容：

- 执行 Linux 官方安装命令。
- 建议设置：

```bash
export CC_SWITCH_FORCE=1
```

以适配非交互覆盖安装场景。

- 安装后解析 `cc-switch` 路径：
  - `/root/.local/bin/cc-switch`
  - `command -v cc-switch`
- 验证：

```bash
cc-switch --version
```

Docker 测试：

```bash
docker run --rm -v "$PWD:/repo" -w /repo debian:bookworm bash -lc '
  apt-get update && apt-get install -y curl ca-certificates bash
  CC_SWITCH_WEBDAV_PASSWORD=dummy bash agent/install.sh --phase cc-switch-test
  /root/.local/bin/cc-switch --version
'
```

验收标准：

- Debian 容器内能安装并执行 `cc-switch --version`。
- 安装失败时日志清楚说明是下载失败、权限失败还是路径失败。

### Phase 4：配置 WebDAV 并下载远端配置

实现内容：

常量：

```bash
WEBDAV_BASE_URL="https://openlist.neko-dashboard.com:8443/dav"
WEBDAV_REMOTE_ROOT="cc-switch-sync"
WEBDAV_PROFILE="default"
WEBDAV_USERNAME="dav"
WEBDAV_PASSWORD="${CC_SWITCH_WEBDAV_PASSWORD:-ercvddDwdFcNaFyCbtX9wt7ARUTQzjLC}"
```

密码策略：

- 默认使用内置明文密码，满足一键安装。
- 如设置了 `CC_SWITCH_WEBDAV_PASSWORD`，优先使用环境变量覆盖内置密码。
- 不需要交互式输入密码。

执行：

```bash
cc-switch config webdav set \
  --base-url "$WEBDAV_BASE_URL" \
  --remote-root "$WEBDAV_REMOTE_ROOT" \
  --profile "$WEBDAV_PROFILE" \
  --username "$WEBDAV_USERNAME" \
  --password "$WEBDAV_PASSWORD" \
  --enable \
  --no-auto-sync

cc-switch config webdav check-connection
cc-switch config webdav download
```

注意：虽然允许明文落库，但日志中仍不得主动打印密码。

Docker 测试：

```bash
docker run --rm -e CC_SWITCH_WEBDAV_PASSWORD="$CC_SWITCH_WEBDAV_PASSWORD" -v "$PWD:/repo" -w /repo debian:bookworm bash -lc '
  apt-get update && apt-get install -y curl ca-certificates bash
  bash agent/install.sh --phase webdav-test
  /root/.local/bin/cc-switch config webdav show
'
```

验收标准：

- `cc-switch config webdav show` 显示 enabled/baseUrl/remoteRoot/profile/username 正确。
- 密码被 cc-switch show 掩码展示，脚本日志不泄露密码。
- `check-connection` 成功。
- `download` 成功后，live config 同步由 cc-switch 自己处理。

### Phase 5：安装 Claude Code

实现内容：

执行：

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

安装后解析 `claude` 路径：

- `/usr/local/bin/claude`
- `/usr/bin/claude`
- `/bin/claude`
- `command -v claude`
- 如安装在 `/root/.local/bin/claude`，需要确保后续 `/usr/local/bin/cc` 的 root 阶段能找到，但切到 `cc` 用户后不应依赖 root home 下不可执行路径。

如果 Claude 官方安装只落到 root home，考虑创建安全 symlink：

```bash
ln -sf /root/.local/bin/claude /usr/local/bin/claude
```

前提：目标存在且可执行；如 `/usr/local/bin/claude` 已存在，不覆盖。

Docker 测试：

```bash
docker run --rm -v "$PWD:/repo" -w /repo debian:bookworm bash -lc '
  apt-get update && apt-get install -y curl ca-certificates bash
  bash agent/install.sh --phase claude-test
  command -v claude
  claude --version
'
```

验收标准：

- `claude --version` 可执行。
- 安装失败时明确报错。

### Phase 6：创建 `/usr/local/bin/cc` 启动脚本与 cc alias

实现内容：

#### 6a. 创建 cc alias 环境文件

在 `install.sh` 中写入 `/etc/profile.d/cc-alias.sh`：

```bash
alias cc='IS_SANDBOX=true claude --dangerously-skip-permissions'
```

该文件确保所有登录 shell 中 `cc` 命令可用。

#### 6b. 创建 `/usr/local/bin/cc` 启动脚本

新增 `agent/cc.sh`，安装时复制到：

```text
/usr/local/bin/cc
```

脚本行为：

1. 注入 `IS_SANDBOX=true` 环境变量。
2. 解析 `claude` 可执行文件路径（`command -v claude`，或 `/usr/local/bin/claude`、`/usr/bin/claude`）。
3. 执行 `claude --dangerously-skip-permissions "$@"`。

不再需要 `runuser`、用户切换、`pick_run_user` 等逻辑。

`collect_cc_switch_env` 保留：从当前 Claude provider 导出 env，用 python3 提取并注入。若 python3 不存在，跳过并警告。

```bash
cc-switch provider current -a claude
cc-switch provider export -a claude "$provider_id" -o "$tmp/settings.local.json"
```

回滚：

- `/etc/profile.d/cc-alias.sh` 由本脚本创建，失败时删除。
- `/usr/local/bin/cc` 由本脚本创建，失败时删除。

Docker 测试：

使用 fake claude，避免每次都访问网络：

```bash
docker run --rm -v "$PWD:/repo" -w /repo debian:bookworm bash -lc '
  install -m 0755 agent/cc.sh /usr/local/bin/cc
  printf "#!/usr/bin/env bash\necho IS_SANDBOX=$IS_SANDBOX args=$* pwd=$PWD\n" > /usr/local/bin/claude
  chmod +x /usr/local/bin/claude
  /usr/local/bin/cc --version
'
```

验收标准：

- `/usr/local/bin/cc --version` 输出中 `IS_SANDBOX=true`。
- 参数能透传。
- 当前工作目录能保持。
- `/etc/profile.d/cc-alias.sh` 存在，包含 `cc` alias 定义。
- 找不到 `claude` 时错误清晰。

### Phase 7：全链路 Docker 验收

全链路测试建议至少覆盖：

1. 静态语法：

```bash
bash -n agent/install.sh
bash -n agent/cc.sh
```

2. Debian bookworm 基础安装：

```bash
docker run --rm \
  -e CC_SWITCH_WEBDAV_PASSWORD="$CC_SWITCH_WEBDAV_PASSWORD" \
  -v "$PWD:/repo" \
  -w /repo \
  debian:bookworm \
  bash -lc 'apt-get update && apt-get install -y curl ca-certificates && bash agent/install.sh'
```

3. Ubuntu LTS 基础安装：

```bash
docker run --rm \
  -e CC_SWITCH_WEBDAV_PASSWORD="$CC_SWITCH_WEBDAV_PASSWORD" \
  -v "$PWD:/repo" \
  -w /repo \
  ubuntu:24.04 \
  bash -lc 'apt-get update && apt-get install -y curl ca-certificates && bash agent/install.sh'
```

如果 Claude Code 官方安装脚本在容器里需要额外依赖或交互，记录实际错误并在脚本中补齐必要依赖，但不要用忽略错误来掩盖。

## 5. 安全与回滚要求

### 5.1 WebDAV 密码落库与日志边界

- 用户已明确授权 WebDAV 密码明文写入仓库文件。
- `agent/install.sh` 应内置默认密码，并允许 `CC_SWITCH_WEBDAV_PASSWORD` 覆盖。
- 不在运行日志中主动打印密码。
- 命令日志不要开启 `set -x`。
- 如必须展示配置，只展示 URL、remote root、profile、username；密码展示依赖 `cc-switch config webdav show` 自身的掩码行为。

### 5.2 谨慎处理系统文件

涉及文件：

```text
/etc/profile.d/cc-agent-proxy.sh
/etc/profile.d/cc-switch-path.sh
/etc/profile.d/cc-alias.sh
/usr/local/bin/cc
```

规则：

- 文件不存在：创建，并登记失败回滚删除。
- 文件存在且内容由本脚本管理：覆盖前备份。
- 文件存在但非本脚本管理：不要静默覆盖，先备份或报错。

### 5.3 第三方安装器回滚边界

以下命令会运行第三方安装器：

```bash
curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash
curl -fsSL https://claude.ai/install.sh | bash
```

脚本可以验证与报告失败，但不要尝试猜测删除第三方安装器创建的所有文件；只回滚本脚本自己创建的 wrapper/profile 文件。

## 6. 实现风格

- Bash 风格保持简单直接，不引入复杂框架。
- 默认不写大段注释，只在安全边界或回滚逻辑处写必要说明。
- 日志中文优先，便于 VPS 安装时快速判断进度。
- 不添加无关功能。
- 不生成额外报告文件。
- 每个 Phase 小步提交式实现，完成后立即 Docker 验证。

## 7. 最终验收清单

完成后至少确认：

```bash
bash -n agent/install.sh
bash -n agent/cc.sh
```

Linux 容器内：

```bash
command -v cc-switch
cc-switch --version
cc-switch config webdav show
cc-switch config webdav check-connection
command -v claude
claude --version
command -v cc
cc --version
test -f /etc/profile.d/cc-alias.sh
grep -q 'IS_SANDBOX=true' /etc/profile.d/cc-alias.sh
```

预期：

- `cc-switch` 可用。
- WebDAV 配置正确并可下载远端配置。
- Claude Code 可用。
- `/etc/profile.d/cc-alias.sh` 存在，包含 `IS_SANDBOX=true`。
- `/usr/local/bin/cc` 注入 `IS_SANDBOX=true` 并启动 Claude Code。
