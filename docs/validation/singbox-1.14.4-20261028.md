# sing-box 1.14.4 与 libcronet.so 安装验证

验证日期：2026-10-28。本机 WSL Ubuntu 24.04（Linux x86_64）、Windows 11。使用上游官方发布包与用户提供的真实订阅响应校验，未修改任何服务器、未提交订阅内容。

## 变更

- 客户端默认内核由 1.14.3 升为当前最新稳定版 1.14.4（发布 2026-10-24），订阅 `User-Agent` 同步变为 `sing-box/1.14.4`。
- 安装器改为把发布压缩包里的 `libcronet.so` 与 `sing-box` 一起装到二进制目录。此前只复制可执行文件。
- 安装以压缩包为准做完整覆盖：压缩包带库则安装该库，不带则删除上一版本残留的库。复用已装内核时不写二进制目录。
- 客户端发现已装内核缺少该库时，会重新下载压缩包补齐，而不是直接复用；服务端不受影响。

## 为什么必须装 libcronet.so

新订阅响应含 `naive` 出站，sing-box 的 naive 支持在运行时动态加载 `libcronet.so`，并且只在可执行文件自身目录中查找。上游自 1.13.0 起把该库放进每个 Linux 发布包，因此旧安装器只复制 `sing-box` 的安装方式对该订阅不完整。

实测（均为真实上游二进制）：

| 场景 | 结果 |
| --- | --- |
| 1.14.4 二进制单独运行时 `sing-box version` | 正常，说明不加载该库也能启动 |
| 只放 `sing-box`，校验含 naive 的真实订阅 | `FATAL initialize outbound[10]: cronet: library not found` |
| 同目录补上 `libcronet.so` 后，相同配置 | 校验退出码 0 |
| 从配置中删除 naive 出站、不留该库 | 校验退出码 0，确认依赖来自 naive |
| 1.13.13 / 1.13.15 只放二进制 | 同样报该错误 |
| 库放在二进制目录、当前目录另放一份 | 生效的是二进制目录那份；改变 cwd 不影响结果 |

上游发布包内容（`tar -tzf`）：

| 版本 | `libcronet.so` |
| --- | --- |
| 1.12.12 | 无 |
| 1.13.0 / 1.13.5 / 1.13.13 / 1.13.15 / 1.14.3 / 1.14.4 | 有（amd64 与 arm64 布局一致） |

## 订阅响应

同一地址在 `User-Agent` 为 `sing-box/1.13.15`、`1.14.0`、`1.14.3`、`1.14.4` 时返回完全相同的内容（13023 字节，SHA256 一致），订阅端不按内核版本降级。内容以两行 `//` 注释开头，其后是被 sing-box 接受的 JSON；顶层含 `http_clients` 与 `route.default_http_client`，因此需要 1.14 及以上内核。出站类型为 `anytls`、`block`、`direct`、`naive`、`selector`、`urltest`。

1.14.4 对该响应执行 `sing-box check` 通过（退出码 0）；未补充 `libcronet.so` 时失败，与上表一致。

订阅 token 与节点凭据不写入本仓库；本地校验用副本已删除。

## 安装路径验证

以真实 1.14.4 压缩包和真实订阅响应驱动安装器函数（`stage_singbox`、`install_binary`、`stage_config` 均为脚本原实现，仅把 GitHub 下载替换为本地副本，systemd 与 APT 不参与）：

- 首次安装：二进制目录得到 `sing-box`（0755）与 `libcronet.so`（0644），后者取自压缩包。
- 随后 `stage_config` 用该安装校验真实订阅通过，日志显示目标版本与实际校验内核均为 1.14.4。
- 二次运行：输出 `Using installed sing-box 1.14.4.`，不再下载，也不改写已装库。
- 升级路径：模拟旧安装器留下的“只有 `sing-box`”目录，安装器提示缺少 `libcronet.so` 并重新下载补齐，补齐后真实订阅校验通过。
- 残留清理：压缩包不含该库时（1.12.x 及更早），目录里上一版本留下的库会被删除，与“以压缩包为准完整覆盖”一致。

## 自动化测试

`python3 -m unittest discover -s tests`：**56 项通过，16 项跳过**（跳过项为需要 Linux 命名空间与 root 的 bypass 测试，Windows 与 WSL 环境均不执行）。

新增/更新覆盖：

- 客户端首次安装断言二进制目录同时存在 `libcronet.so`，内容与压缩包一致，权限 0644。
- 客户端已装同版本且库存在时复用，不产生网络请求，且不改写已装库。
- 客户端已装同版本但库缺失时重新下载一次补齐，并校验安装后的库内容。
- 服务端已装同版本时不因缺少该库重新下载（服务端不使用订阅，也不含 naive 逻辑）。
- 压缩包不含该库时 `install_binary` 只安装二进制，不创建库文件；若目录里已有旧库，则删除它。
- 订阅 `User-Agent` 断言更新为 `sing-box/1.14.4`。

`VPS/singbox/client/test/verify.sh` 与容器内订阅夹具同步到 1.14.4，并新增对 `/usr/local/lib/sing-box-client/libcronet.so` 的存在性断言。容器端到端测试未在本机执行：Windows Docker 守护进程未运行，且该测试需要 systemd、cgroup 与特权容器。

## 参考

- [1.14.4 稳定版](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4)
- [官方迁移说明](https://sing-box.sagernet.org/migration/)
- [TUN 入站文档](https://sing-box.sagernet.org/configuration/inbound/tun/)（用于核对 `interface_name` 缺省行为）
