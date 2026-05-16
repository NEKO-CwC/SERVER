#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# sing-box client initializer for Linux (amd64)
# Usage: sudo bash init.sh
# ============================================================

# --- Configuration ---
SINGBOX_VERSION="1.13.12"
DOWNLOAD_PROXY="http://la-new.284072.xyz:20081"
INSTALL_BIN="/usr/local/bin/sing-box"
INSTALL_CONF_DIR="/etc/sing-box"
INSTALL_CONF="${INSTALL_CONF_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
TARBALL="sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${TARBALL}"

# --- Helpers ---
info()  { echo -e "\033[1;32m[INFO]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

# --- Preflight ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo bash init.sh)"
    exit 1
fi

if ! command -v curl &>/dev/null; then
    error "curl is required but not found. Install it first."
    exit 1
fi

# Locate base.json next to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_JSON="${SCRIPT_DIR}/base.json"
if [[ ! -f "${BASE_JSON}" ]]; then
    error "base.json not found in ${SCRIPT_DIR}"
    exit 1
fi

# --- Download ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

info "Downloading sing-box v${SINGBOX_VERSION} via proxy..."
export http_proxy="${DOWNLOAD_PROXY}"
export https_proxy="${DOWNLOAD_PROXY}"
curl -fSL -o "${TMPDIR}/${TARBALL}" "${DOWNLOAD_URL}"
unset http_proxy https_proxy

# --- Install binary ---
info "Installing binary to ${INSTALL_BIN}..."
tar -xzf "${TMPDIR}/${TARBALL}" -C "${TMPDIR}"
install -m 755 "${TMPDIR}/sing-box-${SINGBOX_VERSION}-linux-amd64/sing-box" "${INSTALL_BIN}"

# --- Install config ---
info "Installing config to ${INSTALL_CONF}..."
mkdir -p "${INSTALL_CONF_DIR}"
cp "${BASE_JSON}" "${INSTALL_CONF}"

# --- Create systemd service ---
info "Creating systemd service..."
cat > "${SERVICE_FILE}" <<'UNIT'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT

# --- Enable & start ---
info "Enabling and starting sing-box service..."
systemctl daemon-reload
systemctl enable --now sing-box

# --- Done ---
info "sing-box v${SINGBOX_VERSION} installed and running."
echo ""
systemctl --no-pager status sing-box || true
