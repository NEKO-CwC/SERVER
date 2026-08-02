#!/usr/bin/env bash
set -euo pipefail

SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.15}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-http://la-new.284072.xyz:20081}"
STARTUP_STABILITY_SECONDS=5

INSTALL_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BYPASS_FILE="${CONFIG_DIR}/bypass.sh"
BYPASS_UNIT="/etc/systemd/system/bypass.service"
SINGBOX_UNIT="/etc/systemd/system/sing-box.service"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BYPASS_SOURCE="${SCRIPT_DIR}/bypass.sh"
TMP_DIR=""
STAGED_BIN=""
STAGED_CONFIG=""

info() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

usage() {
  printf 'Usage: sudo %s <subscription-url>\n' "${0##*/}"
  printf '       sudo SUBSCRIPTION_URL=<url> %s\n' "${0##*/}"
}

cleanup_tmpdir() {
  case "${TMP_DIR}" in
    /var/tmp/sing-box-install.*)
      rm -rf -- "${TMP_DIR}"
      ;;
  esac
}

require_root_and_systemd() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "Run this installer as root."
    exit 1
  fi

  if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    error "A running systemd instance is required."
    exit 1
  fi
}

install_dependencies() {
  local missing=()
  local command_name

  for command_name in curl ip nft tar gzip awk grep install mktemp readlink unlink; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing+=("${command_name}")
    fi
  done

  if ((${#missing[@]} == 0)); then
    return
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    error "Missing commands: ${missing[*]}"
    error "Automatic dependency installation currently supports Debian and Ubuntu."
    exit 1
  fi

  info "Installing required system packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update
  apt-get install -y --no-install-recommends \
    ca-certificates curl iproute2 nftables tar gzip coreutils gawk grep
  unset DEBIAN_FRONTEND
}

require_commands() {
  local missing=()
  local command_name

  for command_name in curl ip nft tar gzip awk grep install mktemp readlink unlink systemctl; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing+=("${command_name}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    error "Missing required commands after package installation: ${missing[*]}"
    exit 1
  fi
}

resolve_architecture() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'amd64\n'
      ;;
    aarch64|arm64)
      printf 'arm64\n'
      ;;
    *)
      error "Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac
}

resolve_subscription_url() {
  local subscription_url=""

  if (($# > 1)); then
    usage >&2
    exit 1
  fi

  if (($# == 1)); then
    subscription_url="$1"
  elif [[ -n "${SUBSCRIPTION_URL:-}" ]]; then
    subscription_url="${SUBSCRIPTION_URL}"
  elif [[ -t 0 ]]; then
    printf 'Enter sing-box subscription URL: ' >&2
    read -r subscription_url
  else
    error "A subscription URL is required."
    usage >&2
    exit 1
  fi

  case "${subscription_url}" in
    https://*)
      ;;
    http://*)
      warn "The subscription URL uses unencrypted HTTP."
      ;;
    *)
      error "The subscription URL must use HTTP or HTTPS."
      exit 1
      ;;
  esac

  printf '%s\n' "${subscription_url}"
}

download_file() {
  local output_file="$1"
  local download_url="$2"
  shift 2

  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-all-errors \
    --retry-delay 2 \
    --connect-timeout 20 \
    --output "${output_file}" \
    "$@" \
    "${download_url}"
}

stage_singbox() {
  local architecture="$1"
  local archive_name="sing-box-${SINGBOX_VERSION}-linux-${architecture}.tar.gz"
  local archive_file="${TMP_DIR}/${archive_name}"
  local download_url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${archive_name}"
  local extracted_bin="${TMP_DIR}/sing-box-${SINGBOX_VERSION}-linux-${architecture}/sing-box"
  local curl_options=()

  if [[ -n "${DOWNLOAD_PROXY}" ]]; then
    curl_options+=(--proxy "${DOWNLOAD_PROXY}")
  fi

  info "Downloading sing-box ${SINGBOX_VERSION} for ${architecture}..."
  download_file "${archive_file}" "${download_url}" "${curl_options[@]}"
  tar -xzf "${archive_file}" -C "${TMP_DIR}"

  if [[ ! -x "${extracted_bin}" ]]; then
    error "The sing-box archive did not contain the expected binary."
    exit 1
  fi

  if ! "${extracted_bin}" version | grep -Fq "sing-box version ${SINGBOX_VERSION}"; then
    error "The downloaded sing-box binary has an unexpected version."
    exit 1
  fi

  STAGED_BIN="${extracted_bin}"
}

stage_config() {
  local staged_bin="$1"
  local subscription_url="$2"
  local staged_config="${TMP_DIR}/config.json"

  info "Downloading the subscription with User-Agent: sing-box..."
  download_file "${staged_config}" "${subscription_url}" --user-agent sing-box

  info "Validating the downloaded configuration..."
  "${staged_bin}" check -c "${staged_config}"
  STAGED_CONFIG="${staged_config}"
}

render_systemd_units() {
  cat > "${TMP_DIR}/bypass.service" <<'UNIT'
[Unit]
Description=sing-box bypass routing rules
After=network-online.target tailscaled.service
Wants=network-online.target
Before=sing-box.service
PartOf=sing-box.service

[Service]
Type=oneshot
ExecStart=/etc/sing-box/bypass.sh apply
ExecReload=/etc/sing-box/bypass.sh apply
ExecStop=/etc/sing-box/bypass.sh cleanup
RemainAfterExit=yes
UNIT

  cat > "${TMP_DIR}/sing-box.service" <<'UNIT'
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target bypass.service
Wants=network-online.target
Requires=bypass.service

[Service]
Type=simple
StateDirectory=sing-box
StateDirectoryMode=0700
WorkingDirectory=/var/lib/sing-box
UMask=0077
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/config.json
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/usr/local/bin/sing-box check -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
ExecStopPost=/etc/sing-box/bypass.sh cleanup
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
}

backup_config() {
  local backup_file

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    return
  fi

  backup_file="${CONFIG_FILE}.bak-$(date +%Y%m%d-%H%M%S)-$$"
  info "Backing up the current config to ${backup_file}..."
  cp -a "${CONFIG_FILE}" "${backup_file}"
}

install_files() {
  local staged_bin="$1"
  local staged_config="$2"

  install -d -m 0755 "${CONFIG_DIR}"
  backup_config

  info "Installing sing-box and its configuration..."
  install -m 0755 "${staged_bin}" "${INSTALL_BIN}"
  install -m 0600 "${staged_config}" "${CONFIG_FILE}"
  install -m 0755 "${BYPASS_SOURCE}" "${BYPASS_FILE}"
  install -m 0644 "${TMP_DIR}/bypass.service" "${BYPASS_UNIT}"
  install -m 0644 "${TMP_DIR}/sing-box.service" "${SINGBOX_UNIT}"
}

start_services() {
  local elapsed
  local legacy_bypass_link="/etc/systemd/system/multi-user.target.wants/bypass.service"

  stop_failed_services() {
    systemctl stop sing-box.service bypass.service 2>/dev/null || true
  }

  info "Reloading systemd and enabling sing-box..."
  if [[ -L "${legacy_bypass_link}" ]] &&
     [[ "$(readlink -f -- "${legacy_bypass_link}")" == "${BYPASS_UNIT}" ]]; then
    unlink -- "${legacy_bypass_link}"
  fi
  systemctl daemon-reload
  systemctl enable sing-box.service

  info "Starting sing-box and its bypass rules..."
  if ! systemctl restart sing-box.service; then
    stop_failed_services
    systemctl --no-pager status bypass.service sing-box.service || true
    journalctl -u sing-box.service -n 50 --no-pager || true
    exit 1
  fi

  info "Checking sing-box startup stability for ${STARTUP_STABILITY_SECONDS} seconds..."
  for ((elapsed = 1; elapsed <= STARTUP_STABILITY_SECONDS; elapsed++)); do
    sleep 1
    if ! systemctl is-active --quiet sing-box.service; then
      error "sing-box stopped during startup initialization."
      stop_failed_services
      systemctl --no-pager status bypass.service sing-box.service || true
      journalctl -u sing-box.service -n 50 --no-pager || true
      exit 1
    fi
  done

  systemctl is-active --quiet bypass.service
  systemctl is-active --quiet sing-box.service
}

main() {
  local subscription_url
  local architecture

  umask 077
  require_root_and_systemd
  install_dependencies
  require_commands

  if [[ ! -f "${BYPASS_SOURCE}" ]]; then
    error "bypass.sh was not found next to this installer."
    exit 1
  fi
  bash -n "${BYPASS_SOURCE}"

  subscription_url="$(resolve_subscription_url "$@")"
  architecture="$(resolve_architecture)"
  TMP_DIR="$(mktemp -d /var/tmp/sing-box-install.XXXXXX)"
  trap cleanup_tmpdir EXIT

  stage_singbox "${architecture}"
  stage_config "${STAGED_BIN}" "${subscription_url}"
  render_systemd_units
  install_files "${STAGED_BIN}" "${STAGED_CONFIG}"
  start_services

  info "sing-box ${SINGBOX_VERSION} installation completed."
  "${INSTALL_BIN}" version
  systemctl --no-pager --full status bypass.service sing-box.service || true
}

main "$@"
