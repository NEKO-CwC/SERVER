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

仓库已更新时直接启动：

```bash
cd ~/SERVER && sudo bash agent/api-rescue-v1.sh
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
C(){ sed -i "\|${M}$|d" "$F" 2>/dev/null || true; }
[[ "$EUID" -eq 0 ]] || { echo '[rescue-v1] run as root' >&2; exit 1; }
curl --noproxy '*' --resolve "$H:443:$I" -sS --connect-timeout 10 --max-time 20 -o /dev/null "https://$H/"
C
sed -i "1i$I $H $M" "$F"
trap C EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}$H"
export no_proxy="${no_proxy:+$no_proxy,}$H"
echo "[rescue-v1] $H -> $I"
"$@"
NEKO_RESCUE_V1
cd ~/SERVER && sudo bash /tmp/neko-agent-api-rescue-v1.sh bash agent/cc.sh
```

只验证 API，不启动 Agent：

```bash
curl --noproxy '*' --resolve sub2api.284072.xyz:443:104.224.154.181 https://sub2api.284072.xyz/
```

进程被强制杀死后可手动清理残留标记：

```bash
sudo sed -i '\|# neko-agent-api-rescue-v1$|d' /etc/hosts
```
