# Magpie 迁移交接：Claude 已接管，Codex 待迁移

更新日期：2026-11-01。本文件供用户和接手的 Claude Code 阅读，不包含 API 密钥、DAV 密码或加密口令。

## 当前结论

Claude 的 provider、MCP、全局提示词和选定技能已由 Magpie 管理，WebDAV 已同步。Codex 的配置和全局提示词保持迁移前内容，本轮只读取了它们以准备交接，**尚未接管 Codex**。

不要按早期迁移结果恢复用户后来主动调整的配置。用户先将技能管理范围缩为原 CC Switch 的 30 个，再主动删除 `huashu-design`，明确要求保持 **29 个**。另外 54 个既有第三方工作流技能及其 `_shared` 留在 Claude 自己的目录。

## 已完成的本机迁移

| 项目 | 已完成内容／当前状态 |
| --- | --- |
| Provider | 最初导入 15 个条目，保留 Anthropic、Responses、Chat Completions 协议区别，并建立各条目的模型／角色映射档案。用户随后在 Magpie 中自行调整；本次最终读取到 9 个显式 provider 条目，以当前配置为准。 |
| Claude 当前模型 | 最初按要求恢复 DeepSeek v4.1 Flash；用户随后自行改为 `neko-sub2api-cn0-4/kimi-k3.1-pro[1m]`。本轮保留这个最新选择。 |
| 网关 | Claude 设置中的代理地址为本机 Magpie `http://127.0.0.1:3425`；已移除旧 CC Switch 模型菜单和目录链接依赖。 |
| MCP | chatgpt-oracle、deepwiki、gemini-oracle、refero，保留原地址及认证头。目前 Library 分配对象均只有 `claude`。 |
| 全局提示词 | Claude 原文完整纳入 Library，保留两份未启用的旧提示词作为独立指令集。目前只分配给 Claude。 |
| 技能 | 当前 Library 29 个，分配给 Claude；不恢复用户删除的 `huashu-design`，不把另外 54 个工作流技能接管进来。 |
| Claude 其他资源 | `agents`、`commands`、`plugins`、`scripts` 等继续保留在原生目录；不属于这次 provider 管理迁移。 |
| WebDAV | 使用 OpenList 既有挂载点内的独立 `magpie-sync` 子目录，Magpie 再使用其中的 `magpie` 子目录。CC Switch 原来的 `v2` 目录未覆盖。 |
| 同步频率 | 手动同步：`magpie webdav now`；没有启用定时同步。 |
| 加密口令 | 已按用户最新指定值替换，并重新加密远端主备份和历史音频补充包。口令不进入仓库。 |

### 加密与历史补充包

DAV 用户名／密码只用于服务器登录；Magpie 的独立口令负责在客户端加密备份。实际 DAV 地址及凭据保存在本机 Magpie 的 `sync.json`，交接时在本机读取，不把内容输出到会话或仓库。

Magpie 0.1.2552 的原生技能同步有 32 MiB 总预算、16 MiB 单文件限制。早期包含 `huashu-design` 时，超过预算的音频曾放入单独的加密补充包。用户删除该技能后，当前 29 个技能不再需要音频补充包。远端仍保留 `claude-library-extras.7z` 作为历史材料，本轮也已用新口令重加密；**不要因为它还存在就恢复 `huashu-design`**。

`_shared` 中的两份规范文档属于留在 Claude 目录的其他工作流技能，也不应因为这次 Magpie 同步而扩大管理范围。

### 私有备份位置

此前迁移创建的本机目录为：

```text
%USERPROFILE%\.magpie-migration\20261101-143614\
```

该目录是执行迁移时由 Codex 自行选择的位置，不是仓库或用户指定的存储规范。本轮交接文档改为放在当前仓库的 `docs/handoffs/`，没有另建一个用户根目录文件夹。

上述私有目录包含迁移前文件、完整 CC Switch SQLite 快照、原 Claude skills 目录、provider 映射记录、范围调整记录和口令变更前后的备份。`WEBDAV-ENCRYPTION-PASSPHRASE.txt` 记录当前口令；旧口令只保留在相应历史备份中。不要把整个目录复制进 Git。

## 仓库安装器已怎样修改

| 文件 | 变化 |
| --- | --- |
| `agent/install.sh` | 使用 `https://usemagpie.ai/install.sh`，下载后交给 `sh` 执行，等价于用户提供的官方安装命令，同时保留现有下载代理、私有日志及重跑逻辑。先安装 Magpie、Claude、Codex，再恢复配置。 |
| `agent/install.sh` | WebDAV 使用 Magpie 原生命令；DAV 密码和加密口令经 stdin 输入，不出现在命令参数或下载程序环境中；同步完成后关闭自动同步。 |
| `agent/install.sh` | 本地来源改为加密的 `.magpie-backup`，使用 `--backup-file`；旧 `--sql-file` 给出迁移提示，不再尝试把 CC Switch SQL 导入 Magpie。 |
| `agent/cc.sh` | 删除从 CC Switch 导出 provider 并注入环境变量的逻辑；Claude 直接读取 Magpie 写入的原生设置。 |
| `.env.example` | `CC_SWITCH_*` 改为 `MAGPIE_CONFIG_SOURCE`、`MAGPIE_BACKUP_FILE`、`MAGPIE_WEBDAV_*`、`MAGPIE_PASSPHRASE`；支持标准 `XDG_CONFIG_HOME`。 |
| `agent/import_sql.py` | 删除已不再使用的 CC Switch SQL 确认适配器；测试改为 Magpie 加密备份恢复。 |
| README／代理说明／测试 | 更新命令、路径、交互输入、恢复流程及重试检查。原生 Magpie 备份已加入 Git 忽略规则。 |

Linux 使用示例（root Bash）：

```bash
bash agent/install.sh
bash agent/install.sh --env /secure/agent.env
bash agent/install.sh --backup-file /secure/magpie.magpie-backup
bash agent/install.sh --env --refresh-config
```

私有环境文件变量示例，实际值由用户在本机填写：

```bash
MAGPIE_CONFIG_SOURCE=dav
MAGPIE_WEBDAV_BASE_URL='https://dav.example.invalid/dav/storage/magpie-sync'
MAGPIE_WEBDAV_USERNAME='your-user'
MAGPIE_WEBDAV_PASSWORD='your-dav-password'
MAGPIE_PASSPHRASE='your-separate-encryption-passphrase'
INSTALL_PROXY_MODE=none
```

`MAGPIE_WEBDAV_BASE_URL` 是 Magpie 自己的 `magpie` 文件夹的父目录，不再传 CC Switch 的 Remote Root 或 Profile。已有私有环境文件须手动替换这些变量。

安装器不自动迁移旧 CC Switch 数据，不卸载旧软件，不自动启动常驻服务。使用代理模型时须运行 Magpie 应用、`magpie serve` 或自行配置 `magpie daemon install`；Linux 用户服务需要相应运行环境。新机器的订阅 OAuth 登录不在 Magpie 备份中，须重新登录。

## 交给 Claude Code：怎样继续迁移 Codex

### 目标与边界

将 Codex 的 provider／转发、MCP、公共提示词及选定技能接入现有 Magpie；保留当前 Codex 的模型选择、推理强度、上下文设置和其他个性化配置。不要把整个 `.claude` 目录复制成 `.codex`，也不要重新安装全部第三方工作流技能。

本轮读到的 Codex 有效用户配置如下，接手时须重读，用户可能继续调整：

```text
model_provider = newapi
model = gpt-6.1-sol
model_reasoning_effort = medium
model_context_window = 1000000
model_auto_compact_token_limit = 900000
```

当前 Codex 有 4 个同名 MCP：deepwiki、chatgpt-oracle、gemini-oracle、refero；全局提示词位于 `~/.codex/AGENTS.md`，并保留 `~/.codex/skills` 中的历史技能。用户共享目录 `~/.agents/skills` 和项目内覆盖也应单独检查。CC Switch 的 Codex 当前条目记录与有效 `config.toml` 可能不同，不能用数据库中的旧模型覆盖正在使用的 `gpt-6.1-sol`。

### 操作顺序

1. **保留当前状态。** 备份 `~/.codex/config.toml`、全局 `AGENTS.md`、认证文件（或确认凭据存储方式），记录技能原目录和链接目标；同时备份 Magpie 的 provider、Library 和 profiles 元数据。认证内容只在本机处理，不写入仓库或终端输出。检查是否设置 `CODEX_HOME`、全局 `AGENTS.override.md`，以及项目 `.codex/config.toml`、`AGENTS.md` 覆盖。
2. **先迁移 Codex 实际使用的转发。** 从有效 TOML 的 `model_providers.newapi` 核对地址、`wire_api` 和认证方式，按地址、协议、凭据匹配已有 Magpie provider；确实相同才复用。若缺少就新建，Responses 转发使用 `responses=`，不能按 Claude 的 `anthropic=` 导入。保持 Codex 当前模型 `gpt-6.1-sol`，不要因为 Claude 在用 Kimi 就替 Codex 换模型。确认可用模型 ID 后，再执行 `magpie codex <provider/model>`、`magpie codex effort medium`；保留现有上下文和压缩值，并检查 Magpie 是否重写了它们。
3. **扩展现有 MCP 分配。** 对同名服务器比较 Codex 实际配置与 Library；若地址、认证相同，直接把分配对象从 `claude` 扩成 `claude,codex`，无需新建第二份。若内容不同，保留独立配置并用不同名称。让 Magpie 写出 Codex 所需 TOML，不把 Claude JSON 结构原样粘贴进去。
4. **合并公共提示词，保留差异。** 比较当前 Library 指令、Claude 的专属前言和 Codex 的全局合同。Claude 原文中含预算等专属表述，不应未经判断复制到 Codex。可以把相同的 Global Agent Contract 设为公共指令，把专属内容留在各 agent 的 extra／原生部分，确认文字和优先级不变后，再给 Codex 分配公共指令。防止同一合同出现两遍。
5. **只接管既定范围的技能。** 以“当前 Library 的 29 个技能”与“CC Switch 中启用 Codex 的技能”取交集；本轮读取结果交集为 29 个。逐个核对 Codex 现有文件：完全相同的旧链接／副本才替换成 Library 的版本；有本机修改先保留并比较。其余原生／第三方技能、`.system` 和 `~/.agents/skills` 不批量搬迁。`huashu-design` 不恢复；Codex 中若仍有旧的该技能链接，不因这次接管自动删掉，先向用户说明差异。
6. **验证后才上传。** 确认 Codex 主模型和推理强度正确、4 个 MCP 配置保留、全局提示词没有重复、技能内容及链接符合范围、其他 TOML 节未丢失。通过新网关做一个最小 Responses 请求和一次无副作用的工具调用，再做一个临时目录中的 Codex 实际请求，确认它确实使用新设置。成功后执行 `magpie webdav now`，把两端分配及 Codex 模型同步到同一份远端备份。

可用的 Magpie 命令形状（先完成上述比对，不要照抄占位模型执行）：

```bash
magpie codex
magpie models codex
magpie provider add 'Codex relay' responses=https://relay.example.invalid/v1 models=gpt-6.1-sol
# API key 在本机交互界面中设置，避免写进共享脚本或会话。
magpie codex '<provider-id>/gpt-6.1-sol'
magpie codex effort medium
magpie library mcp agents deepwiki claude,codex
magpie library skill agents agent-browser claude,codex
# 完成提示词差异处理后，才能扩展其分配：
magpie library instructions agents claude,codex
magpie library sync
magpie webdav now
```

上面只展示一个 MCP 和一个 skill 的分配命令；其余按已核对清单处理。直接在 Magpie 切换 provider 不等于恢复任意 CC Switch 专用环境变量；之前导入的 profiles 主要保存模型、角色映射和推理强度，其他原始设置保留于私有迁移记录。

### 交付验收与回退

接手方最终交付应列明：Codex 实际模型／上游协议、接管的 MCP 和技能数量、保留的专属提示词、实际请求验证结果、远端同步结果，以及尚未兼容的旧设置。不要把“文件已写入”当成“Codex 已成功调用”。

若连接失败，先使用本次新建的 Codex／Magpie 备份回退，仅恢复相关文件；不要运行整个旧迁移脚本，也不要把用户当前的 29 个技能、Kimi 选择或 9 个 provider 强行还原成早期快照。修改加密口令时，不能仅更改客户端字段后假定旧远端会自动解密；应先保留旧代备份，用新口令重新加密，再更新远端和客户端。本轮已完成这一过程。

### 可直接交给 Claude Code 的任务

> 请先阅读本文件，再将本机 Codex 的 provider、MCP、公共提示词和约定范围内的技能迁入现有 Magpie。先读当前有效配置并备份，保留 gpt-6.1-sol、medium 推理及现有上下文设置，除非用户后续明确修改。复用匹配的 provider，按 Responses 协议配置；扩展现有 MCP／技能分配，不复制整个 Claude 配置目录，不批量接管其他工作流技能，不恢复用户删除的 huashu-design。处理提示词公共部分与专属部分的差异，完成真实 Codex 请求和工具调用验证后同步 WebDAV。密钥和加密口令只在本机读取，不进入仓库或报告。交付变更清单、验证结果和回退路径。

## 验证记录

此前 Claude 的 DeepSeek 路由曾通过 HTTP 200 和工具调用验证；用户后来切换的 Kimi 模型没有在本轮额外发送请求，不能把之前测试当作对当前所有 provider 的保证。

本轮口令修改后，Magpie 报告 WebDAV 同步成功；历史音频补充包重加密后已下载校验 SHA-256。Codex `config.toml` 和全局 `AGENTS.md` 的哈希与原始迁移记录一致。

仓库测试在 WSL Ubuntu 24.04 中运行：

```bash
python3 -m unittest discover -s tests -v
```

记录：整套运行 60 个测试，结果成功，16 项跳过；跳过包括缺少 Paramiko 的 SSH／bootstrap 集成测试，以及当前 WSL 内核不支持的 netfilter/veth 测试。随后新增的 Claude 启动器回归测试 1 项通过，整理后的交互输入测试 8 项通过。测试使用隔离的安装／Magpie 替身，未在真实服务器执行安装、未启动服务。Shell 语法和 Git diff 检查通过。

Codex 配置行为参考已读取的 OpenAI 官方文档：

- [高级配置与配置位置](https://developers.openai.com/codex/config-advanced/)
- [MCP 配置](https://developers.openai.com/codex/mcp/)
- [Skills 与作用域](https://developers.openai.com/codex/skills/)
- [AGENTS.md 的发现与优先级](https://developers.openai.com/codex/guides/agents-md/)

Magpie 命令及加密行为依据本机 0.1.2552 的 CLI help 与 [Magpie 源码](https://github.com/yetone/magpie)；换版本或换机后先重新核对帮助信息。
