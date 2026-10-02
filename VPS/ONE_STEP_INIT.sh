#!/usr/bin/env bash
set -euo pipefail

[[ "$EUID" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl is required.' >&2; exit 1; }
INIT_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$INIT_TMP_DIR"' EXIT
REPO_RAW="https://raw.githubusercontent.com/NEKO-CwC/SERVER/main/VPS"

# Every download and stage must succeed before the next one starts.
for script in util.sh package_install.sh os_setting.sh init.sh; do
  curl -fsSL --connect-timeout 20 --max-time 180 "${REPO_RAW}/${script}" -o "${INIT_TMP_DIR}/${script}"
done
cd "$INIT_TMP_DIR"
for script in package_install.sh os_setting.sh init.sh; do
  bash "$script"
done
echo 'VPS basic initialization completed. Proxy deployment is a separate step.'
