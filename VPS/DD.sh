#!/usr/bin/env bash
set -euo pipefail

# This script reinstalls the OS and reboots. Never run it as an installation test.
: "${VPS_ROOT_PASSWORD:?Set VPS_ROOT_PASSWORD before reinstalling the OS}"
: "${VPS_SSH_PUBLIC_KEY:?Set VPS_SSH_PUBLIC_KEY before reinstalling the OS}"
[[ "$EUID" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl is required.' >&2; exit 1; }

REINSTALL_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$REINSTALL_TMP_DIR"' EXIT
curl -fsSL --connect-timeout 20 --max-time 180 \
  https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh \
  -o "${REINSTALL_TMP_DIR}/reinstall.sh"
bash "${REINSTALL_TMP_DIR}/reinstall.sh" debian \
  --password="$VPS_ROOT_PASSWORD" --ssh-key="$VPS_SSH_PUBLIC_KEY"
echo 'Reinstall prepared. Rebooting in 5 seconds.'
sleep 5
reboot
