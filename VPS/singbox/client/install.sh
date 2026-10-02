#!/usr/bin/env bash
set -euo pipefail

SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.15}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"
STARTUP_STABILITY_SECONDS=5

INSTALL_BIN="/usr/local/lib/sing-box-client/sing-box"
CONFIG_DIR="/etc/sing-box-client"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BYPASS_FILE="${CONFIG_DIR}/bypass.sh"
BYPASS_UNIT="/etc/systemd/system/sing-box-client-bypass.service"
SINGBOX_UNIT="/etc/systemd/system/sing-box-client.service"
LOCK_FILE="/run/lock/neko-sing-box-client.lock"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BYPASS_SOURCE="${SCRIPT_DIR}/bypass.sh"
TMP_DIR=""
STAGED_BIN=""
STAGED_CONFIG=""
CLI_SUBSCRIPTION_URL=""

source "${SCRIPT_DIR}/../common.sh"

info() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

usage() {
  printf 'Usage: sudo bash %s [--env [FILE]] [subscription-url]\n' "${0##*/}"
  printf 'Default: interactive proxy and subscription URL. --env uses INSTALL_* and SUBSCRIPTION_URL.\n'
}

parse_args() {
  while (($#)); do
    case "$1" in
      --env)
        USE_ENV=1; shift
        if [[ $# -gt 0 && "$1" != -* && "$1" != http://* && "$1" != https://* ]]; then ENV_FILE="$1"; shift; fi ;;
      -h|--help) usage; exit 0 ;;
      http://*|https://*)
        [[ -z "$CLI_SUBSCRIPTION_URL" ]] || { error "Only one subscription URL is allowed."; return 2; }
        CLI_SUBSCRIPTION_URL="$1"; shift ;;
      *) error "Unknown argument: $1"; usage >&2; return 2 ;;
    esac
  done
}

cleanup_tmpdir() {
  case "${TMP_DIR}" in
    /var/tmp/sing-box-install.*)
      rm -rf -- "${TMP_DIR}"
      ;;
  esac
}

cleanup() {
  cleanup_proxy
  cleanup_tmpdir
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

  for command_name in curl ip nft tar gzip awk grep install mktemp readlink unlink flock mv; do
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
  ensure_download_proxy
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update
  apt-get install -y --no-install-recommends \
    ca-certificates curl iproute2 nftables tar gzip coreutils gawk grep util-linux
  unset DEBIAN_FRONTEND
}

require_commands() {
  local missing=()
  local command_name

  for command_name in curl ip nft tar gzip awk grep install mktemp readlink unlink flock mv systemctl; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing+=("${command_name}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    error "Missing required commands after package installation: ${missing[*]}"
    exit 1
  fi
}

resolve_subscription_url() {
  local subscription_url=""

  if [[ -n "$CLI_SUBSCRIPTION_URL" ]]; then
    subscription_url="$CLI_SUBSCRIPTION_URL"
  elif ((USE_ENV)) && [[ -n "${SUBSCRIPTION_URL:-}" ]]; then
    subscription_url="${SUBSCRIPTION_URL}"
  elif ((USE_ENV == 0)) && [[ -t 0 ]]; then
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
  cat > "${TMP_DIR}/sing-box-client-bypass.service" <<'UNIT'
[Unit]
Description=sing-box bypass routing rules
After=network-online.target tailscaled.service
Wants=network-online.target
Before=sing-box-client.service
PartOf=sing-box-client.service

[Service]
Type=oneshot
ExecStart=/etc/sing-box-client/bypass.sh apply
ExecReload=/etc/sing-box-client/bypass.sh apply
ExecStop=/etc/sing-box-client/bypass.sh cleanup
RemainAfterExit=yes
UNIT

  cat > "${TMP_DIR}/sing-box-client.service" <<'UNIT'
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target sing-box-client-bypass.service
Wants=network-online.target
Requires=sing-box-client-bypass.service

[Service]
Type=simple
StateDirectory=sing-box-client
StateDirectoryMode=0700
WorkingDirectory=/var/lib/sing-box-client
UMask=0077
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
ExecStartPre=/usr/local/lib/sing-box-client/sing-box check -c /etc/sing-box-client/config.json
ExecStart=/usr/local/lib/sing-box-client/sing-box run -c /etc/sing-box-client/config.json
ExecReload=/usr/local/lib/sing-box-client/sing-box check -c /etc/sing-box-client/config.json
ExecReload=/bin/kill -HUP $MAINPID
ExecStopPost=/etc/sing-box-client/bypass.sh cleanup
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
  local staged_config="$1"

  install -d -m 0755 "${CONFIG_DIR}" "$(dirname "${INSTALL_BIN}")"
  backup_config

  info "Installing sing-box and its configuration..."
  install_binary
  install -m 0600 "${staged_config}" "${CONFIG_FILE}.new"
  mv -f -- "${CONFIG_FILE}.new" "${CONFIG_FILE}"
  install -m 0755 "${BYPASS_SOURCE}" "${BYPASS_FILE}"
  install -m 0644 "${TMP_DIR}/sing-box-client-bypass.service" "${BYPASS_UNIT}"
  install -m 0644 "${TMP_DIR}/sing-box-client.service" "${SINGBOX_UNIT}"
}

start_services() {
  local elapsed
  local legacy_bypass_link="/etc/systemd/system/multi-user.target.wants/sing-box-client-bypass.service"

  stop_failed_services() {
    systemctl stop sing-box-client.service sing-box-client-bypass.service 2>/dev/null || true
  }

  info "Reloading systemd and enabling sing-box..."
  if [[ -L "${legacy_bypass_link}" ]] &&
     [[ "$(readlink -f -- "${legacy_bypass_link}")" == "${BYPASS_UNIT}" ]]; then
    unlink -- "${legacy_bypass_link}"
  fi
  systemctl daemon-reload
  systemctl enable sing-box-client.service

  info "Starting sing-box and its bypass rules..."
  if ! systemctl restart sing-box-client.service; then
    stop_failed_services
    systemctl --no-pager status sing-box-client-bypass.service sing-box-client.service || true
    journalctl -u sing-box-client.service -n 50 --no-pager || true
    exit 1
  fi

  info "Checking sing-box startup stability for ${STARTUP_STABILITY_SECONDS} seconds..."
  for ((elapsed = 1; elapsed <= STARTUP_STABILITY_SECONDS; elapsed++)); do
    sleep 1
    if ! systemctl is-active --quiet sing-box-client.service; then
      error "sing-box stopped during startup initialization."
      stop_failed_services
      systemctl --no-pager status sing-box-client-bypass.service sing-box-client.service || true
      journalctl -u sing-box-client.service -n 50 --no-pager || true
      exit 1
    fi
  done

  systemctl is-active --quiet sing-box-client-bypass.service
  systemctl is-active --quiet sing-box-client.service
}

main() {
  local subscription_url
  local architecture

  parse_args "$@"
  umask 077
  require_root_and_systemd
  STATE_DIR="${HOME:-/root}/.local/state/neko-sing-box-client-install"
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  proxy_configure
  if ((USE_ENV)); then
    STATE_DIR="${INSTALL_PROXY_STATE_DIR:-$STATE_DIR}"
  else
    SINGBOX_VERSION=1.13.15; DOWNLOAD_PROXY=""
  fi
  subscription_url="$(resolve_subscription_url)"
  install_dependencies
  require_commands
  require_legacy_stopped
  exec 9>"$LOCK_FILE"
  flock -n 9 || { error "Another client installation is running."; return 1; }

  if [[ ! -f "${BYPASS_SOURCE}" ]]; then
    error "bypass.sh was not found next to this installer."
    exit 1
  fi
  bash -n "${BYPASS_SOURCE}"

  architecture="$(resolve_architecture)"
  TMP_DIR="$(mktemp -d /var/tmp/sing-box-install.XXXXXX)"

  stage_singbox "${architecture}"
  stage_config "${STAGED_BIN}" "${subscription_url}"
  cleanup_proxy
  render_systemd_units
  install_files "${STAGED_CONFIG}"
  start_services

  info "sing-box ${SINGBOX_VERSION} installation completed."
  "${INSTALL_BIN}" version
  systemctl --no-pager --full status sing-box-client-bypass.service sing-box-client.service || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
