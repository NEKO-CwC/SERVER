# 下一个 Agent 启动 Prompt

你将接手在 `D:\Project\NEKO\SERVER` 仓库中实现 `agent/` 目录下的 Linux Claude Code Agent 一键安装脚本。

请先阅读：

```text
agent/PLAN.zh-CN.md
```

然后按计划开始实现。

## 强制要求：使用 team 模式

本任务涉及安装脚本、系统权限、WebDAV 配置、Docker 验证、安全审查和回滚逻辑。请不要单 agent 独自完成，必须使用 team 模式加快工作效率并降低遗漏风险。

建议立即创建团队并分工：

1. `script-dev`：实现 `agent/install.sh` 和 `agent/cc.sh`。
2. `docker-tester`：为每个 Phase 准备并运行轻量 Docker Linux 验证。
3. `security-reviewer`：检查密码处理、IS_SANDBOX 注入安全性、回滚边界、curl pipe bash 风险说明。
4. `reviewer`：做最终代码审查，确认脚本简单、可维护、符合现有仓库风格。

请让团队并行推进，但主 agent 必须负责最终整合与判断，不要把架构决策完全丢给子 agent。

## 任务目标

在 `agent/` 文件夹中落地：

```text
agent/install.sh
agent/cc.sh
```

可选：

```text
agent/docker-test.sh
```

实现 Linux 一键安装：

1. 自动设置代理环境变量：
   - `http_proxy`
   - `https_proxy`
   - `HTTP_PROXY`
   - `HTTPS_PROXY`
   - 值：`http://la-new.284072.xyz:20081`
2. Linux 下安装 `cc-switch`：
   ```bash
   curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash
   ```
3. 持久保存：
   ```bash
   export PATH="/root/.local/bin:$PATH"
   ```
4. 使用 `cc-switch` CLI 配置 WebDAV，并下载最近配置。
5. 执行：
   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   ```
   安装最新版 Claude Code。
6. 注入 `IS_SANDBOX=true` 环境变量，并创建 `cc` alias 指向 Claude Code 启动命令。
7. 创建 `/usr/local/bin/cc`，注入 `IS_SANDBOX=true`，在当前目录启动：
   ```bash
   claude --dangerously-skip-permissions
   ```
8. 日志必须实时展示进度，出错时要清楚报告，并尽量回滚本脚本创建的系统文件。

## WebDAV 配置

`cc-switch` WebDAV CLI 能力已确认可用。使用：

```bash
cc-switch config webdav set \
  --base-url "https://openlist.neko-dashboard.com:8443/dav" \
  --remote-root "cc-switch-sync" \
  --profile "default" \
  --username "dav" \
  --password "${CC_SWITCH_WEBDAV_PASSWORD:-ercvddDwdFcNaFyCbtX9wt7ARUTQzjLC}" \
  --enable \
  --no-auto-sync

cc-switch config webdav check-connection
cc-switch config webdav download
```

注意：

- 用户已明确授权：WebDAV 密码可以明文写入本仓库，因为该仓库最终会上传到用户私人仓库，GitHub 云端仅作为备份。
- `agent/install.sh` 应内置默认密码：`ercvddDwdFcNaFyCbtX9wt7ARUTQzjLC`。
- 仍保留 `CC_SWITCH_WEBDAV_PASSWORD` 环境变量覆盖能力，便于未来轮换密码。
- 不需要交互式输入密码。
- 日志不要主动打印密码，也不要开启 `set -x`。
- 用户给出的 JSON 中 `status` 字段由 `cc-switch` 自己维护，脚本不要手动写。

## Docker 分阶段测试要求

每完成一个 Phase，都启动轻量 Linux Docker 环境验证该 Phase 功能是否正常。

建议基础镜像：

```text
debian:bookworm
ubuntu:24.04
```

每阶段至少做：

```bash
bash -n agent/install.sh
bash -n agent/cc.sh
```

对涉及系统变更的阶段，用容器验证：

- `/etc/profile.d/cc-agent-proxy.sh` 是否写入正确。
- `/etc/profile.d/cc-switch-path.sh` 是否写入正确。
- `cc-switch --version` 是否可用。
- `cc-switch config webdav show/check-connection/download` 是否可用。
- `claude --version` 是否可用。
- `/etc/profile.d/cc-alias.sh` 是否存在，包含 `IS_SANDBOX=true`。
- `/usr/local/bin/cc` 是否注入 `IS_SANDBOX=true` 并启动 Claude Code。

对于 `/usr/local/bin/cc` 的测试，可以用 fake `claude` 替代真实 Claude Code，以减少网络安装成本：

```bash
printf '#!/usr/bin/env bash\necho IS_SANDBOX=$IS_SANDBOX args="$*" pwd="$PWD"\n' > /usr/local/bin/claude
chmod +x /usr/local/bin/claude
/usr/local/bin/cc --version
```

期望输出中应包含：

```text
IS_SANDBOX=true
```

## 实现注意事项

1. Bash 代码保持简单，不要引入复杂框架。
2. 允许 WebDAV 密码明文写入 `agent/install.sh`，但不要在运行日志中主动打印密码，也不要开启 `set -x`。
3. 不要盲目覆盖用户已有文件；覆盖前备份或判断是否由本脚本管理。
4. 本脚本不创建系统用户，无需用户相关回滚逻辑。
5. 第三方安装器产生的文件不要猜测删除，只回滚本脚本直接创建的内容。
6. 不要生成额外文档或报告；如需临时记录，放 `.workflow/.scratchpad/`。
7. 每次修改后运行静态语法检查与对应 Docker 测试。

## 最终交付前检查

完成后请给出简短结果说明，并确认以下命令已通过或说明阻塞原因：

```bash
bash -n agent/install.sh
bash -n agent/cc.sh
```

至少一个 Docker Linux 环境中完成分阶段验证。

最终文件应至少包括：

```text
agent/install.sh
agent/cc.sh
```
