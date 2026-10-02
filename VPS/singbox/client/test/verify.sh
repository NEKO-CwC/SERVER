#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_URL="${1:?subscription URL is required}"
WORKSPACE="/workspace"
CONFIG_DIR="/etc/sing-box-client"

assert_file() {
  [[ -f "$1" ]] || { echo "missing file: $1" >&2; exit 1; }
}

assert_active() {
  systemctl is-active --quiet "$1" || {
    systemctl --no-pager status "$1" || true
    exit 1
  }
}

echo "[verify] waiting for systemd"
systemctl is-system-running --wait 2>/dev/null || true

echo "[verify] installing from the local sing-box-UA subscription"
bash "${WORKSPACE}/install.sh" "${SUBSCRIPTION_URL}"

echo "[verify] checking installed files and services"
assert_file /usr/local/lib/sing-box-client/sing-box
assert_file "${CONFIG_DIR}/config.json"
assert_file "${CONFIG_DIR}/bypass.sh"
assert_file /etc/systemd/system/sing-box-client-bypass.service
assert_file /etc/systemd/system/sing-box-client.service
/usr/local/lib/sing-box-client/sing-box version | grep -F "sing-box version 1.13.15"
[[ "$(stat -c '%a' "${CONFIG_DIR}/config.json")" == 600 ]]
[[ "$(stat -c '%a' "${CONFIG_DIR}/bypass.sh")" == 755 ]]
cmp -s "${WORKSPACE}/bypass.sh" "${CONFIG_DIR}/bypass.sh"
assert_active sing-box-client-bypass.service
assert_active sing-box-client.service
[[ "$(systemctl is-enabled sing-box-client-bypass.service)" == static ]]
systemctl is-enabled sing-box-client.service
grep -F 'PartOf=sing-box-client.service' /etc/systemd/system/sing-box-client-bypass.service
grep -F 'Requires=sing-box-client-bypass.service' /etc/systemd/system/sing-box-client.service
grep -F 'After=network-online.target nss-lookup.target sing-box-client-bypass.service' /etc/systemd/system/sing-box-client.service
grep -F 'ExecStopPost=/etc/sing-box-client/bypass.sh cleanup' /etc/systemd/system/sing-box-client.service
[[ "$(readlink -f "/proc/$(systemctl show -p MainPID --value sing-box-client.service)/cwd")" == /var/lib/sing-box-client ]]
assert_file /var/lib/sing-box-client/cache.db
assert_file /subscription-state/user-agent.ok
[[ "$(cat /subscription-state/user-agent.ok)" == sing-box ]]

echo "[verify] simulating Tailscale routes and checking marked SSH paths"
ip link add tailscale0 type dummy 2>/dev/null || true
ip link set tailscale0 up
ip addr add 100.117.226.6/32 dev tailscale0 2>/dev/null || true
ip -6 addr add fd7a:115c:a1e0::793b:e208/128 dev tailscale0 2>/dev/null || true
ip route replace table 52 100.100.100.100/32 dev tailscale0
ip route replace table 52 default dev tailscale0
ip -6 route replace table 52 fd7a:115c:a1e0::/48 dev tailscale0
systemctl restart sing-box-client-bypass.service

ip -4 rule show | grep -Eq '^4004:[[:space:]]+from all to 100\.64\.0\.0/10 lookup 52 suppress_prefixlength 0$'
ip -6 rule show | grep -Eq '^4004:[[:space:]]+from all to fd7a:115c:a1e0::/48 lookup 52 suppress_prefixlength 0$'
ip route get 100.100.100.100 mark 0x100 | grep -F 'dev tailscale0'
if ip route get 100.99.88.77 | grep -Fq 'dev tailscale0'; then
  echo "an unknown CGNAT address used the Tailscale default route" >&2
  exit 1
fi
ip -6 route get fd7a:115c:a1e0::53 mark 0x100 | grep -F 'dev tailscale0'
nft list table inet singbox_client_bypass | grep -Eq '[[:space:]]tcp sport 22[[:space:]]'

echo "[verify] checking sing-box-owned cleanup and restart"
systemctl stop sing-box-client.service
if systemctl is-active --quiet sing-box-client-bypass.service; then
  echo "sing-box-client-bypass.service remained active after sing-box stopped" >&2
  exit 1
fi
if nft list table inet singbox_client_bypass >/dev/null 2>&1; then
  echo "bypass nft table was not cleaned up" >&2
  exit 1
fi
if ip -4 rule show | grep -Eq '^4004:[[:space:]]+from all to 100\.64\.0\.0/10 lookup 52'; then
  echo "bypass IPv4 rule was not cleaned up" >&2
  exit 1
fi
systemctl start sing-box-client.service
assert_active sing-box-client-bypass.service
assert_active sing-box-client.service

echo "[verify] checking idempotent reinstall"
ln -sfn /etc/systemd/system/sing-box-client-bypass.service /etc/systemd/system/multi-user.target.wants/sing-box-client-bypass.service
[[ "$(systemctl is-enabled sing-box-client-bypass.service)" == enabled ]]
bash "${WORKSPACE}/install.sh" "${SUBSCRIPTION_URL}" >/tmp/singbox-reinstall.log 2>&1
if grep -Fq 'The unit files have no installation config' /tmp/singbox-reinstall.log; then
  echo "reinstall tried to disable the static bypass unit" >&2
  exit 1
fi
compgen -G "${CONFIG_DIR}/config.json.bak-*" >/dev/null
[[ "$(systemctl is-enabled sing-box-client-bypass.service)" == static ]]
assert_active sing-box-client-bypass.service
assert_active sing-box-client.service
ip route get 100.100.100.100 mark 0x100 | grep -F 'dev tailscale0'

echo "[verify] all checks passed"
