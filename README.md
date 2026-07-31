# VPS DD

```bash
curl -fsSL https://raw.githubusercontent.com/NEKO-CwC/SERVER/refs/heads/main/VPS/DD.sh -o DD.sh && bash DD.sh && rm -f DD.sh
```

# VPS ONE_STEP_INIT

```bash
curl -fsSL https://raw.githubusercontent.com/NEKO-CwC/SERVER/refs/heads/main/VPS/ONE_STEP_INIT.sh -o ONE_STEP_INIT.sh && bash ONE_STEP_INIT.sh && rm -f ONE_STEP_INIT.sh
```

# Agent API DNS Rescue v1

固定映射 `sub2api.284072.xyz` 到 `104.224.154.181`，保留 HTTPS 域名、SNI 和证书校验。脚本退出后自动删除临时 `/etc/hosts` 记录。

仓库已更新时直接启动 Claude（不传参数时也默认 Claude）或 Codex：

```bash
cd ~/SERVER && sudo bash agent/api-rescue-v1.sh claude
cd ~/SERVER && sudo bash agent/api-rescue-v1.sh codex
```

DNS 已失效且无法更新仓库时，整段复制到服务器终端：

```bash
cat >/tmp/neko-agent-api-rescue-v1.sh <<'NEKO_RESCUE_V1'
#!/usr/bin/env bash
set -euo pipefail
H="${AGENT_API_HOST:-sub2api.284072.xyz}"
I="${AGENT_API_IP:-104.224.154.181}"
F="/etc/hosts"
M="# neko-agent-api-rescue-v1"
A(){ command -v "$1" 2>/dev/null || { for B in "/root/.local/bin/$1" "${HOME:-/root}/.local/bin/$1" "/usr/local/bin/$1" "/usr/bin/$1" "/bin/$1"; do [[ -x "$B" ]] && { echo "$B"; return; }; done; return 1; }; }
C(){ sed -i "\|${M}$|d" "$F" 2>/dev/null || true; }
[[ "$EUID" -eq 0 ]] || { echo '[rescue-v1] run as root' >&2; exit 1; }
export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
curl --noproxy '*' --resolve "$H:443:$I" -sS --connect-timeout 10 --max-time 20 -o /dev/null "https://$H/"
C
sed -i "1i$I $H $M" "$F"
trap C EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}$H"
export no_proxy="${no_proxy:+$no_proxy,}$H"
[[ $# -gt 0 ]] || set -- claude
case "$1" in
  claude) shift; set -- bash agent/cc.sh "$@" ;;
  codex) shift; B="$(A codex)" || { echo '[rescue-v1] codex not found' >&2; exit 1; }; set -- "$B" --yolo "$@" ;;
  --) shift; [[ $# -gt 0 ]] || { echo '[rescue-v1] missing command' >&2; exit 1; } ;;
esac
echo "[rescue-v1] $H -> $I"
"$@"
NEKO_RESCUE_V1
cd ~/SERVER && sudo bash /tmp/neko-agent-api-rescue-v1.sh codex
```

最后一行把 `codex` 改成 `claude` 即可启动 Claude；两者都可以在后面继续追加 Agent 参数。

只验证 API，不启动 Agent：

```bash
curl --noproxy '*' --resolve sub2api.284072.xyz:443:104.224.154.181 https://sub2api.284072.xyz/
```

进程被强制杀死后可手动清理残留标记：

```bash
sudo sed -i '\|# neko-agent-api-rescue-v1$|d' /etc/hosts
```
