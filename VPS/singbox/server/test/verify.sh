#!/usr/bin/env bash
set -euo pipefail

systemctl is-system-running --wait || [[ "$(systemctl is-system-running)" == degraded ]]
bash /workspace/install.sh --config-file /workspace/test/fixture-config.json
systemctl is-active --quiet sing-box-server.service
[[ "$(stat -c '%a' /etc/sing-box-server/config.json)" == 600 ]]
[[ ! -e /etc/systemd/system/sing-box-client.service ]]
[[ ! -e /etc/systemd/system/sing-box-client-bypass.service ]]
[[ ! -e /etc/sing-box-client ]]
curl -fsS --socks5-hostname 127.0.0.1:10801 http://subscription:8080/fixture-config.json -o /tmp/proxy-result.json
cmp /tmp/proxy-result.json /workspace/test/fixture-config.json

SINGBOX_SERVER_CONFIG_URL=http://subscription:8080/fixture-config.json bash /workspace/install.sh
systemctl is-active --quiet sing-box-server.service
compgen -G '/etc/sing-box-server/config.json.bak-*' >/dev/null
before="$(sha256sum /etc/sing-box-server/config.json)"
before_pid="$(systemctl show -p MainPID --value sing-box-server.service)"
if SINGBOX_SERVER_CONFIG_URL=http://subscription:8080/invalid.txt bash /workspace/install.sh; then
  echo 'Invalid config unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(sha256sum /etc/sing-box-server/config.json)" == "$before" ]]
[[ "$(systemctl show -p MainPID --value sing-box-server.service)" == "$before_pid" ]]
systemctl is-active --quiet sing-box-server.service
bash /workspace/install.sh
systemctl is-active --quiet sing-box-server.service
echo '[verify] server local/remote configuration, proxy traffic and failure preservation passed'
