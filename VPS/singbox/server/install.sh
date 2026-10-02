#!/usr/bin/env bash
set -euo pipefail

SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.13}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"
INSTALL_BIN="/usr/local/lib/sing-box-server/sing-box"
CONFIG_DIR="/etc/sing-box-server"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SINGBOX_UNIT="/etc/systemd/system/sing-box-server.service"
LOCK_FILE="/run/lock/neko-sing-box-server.lock"
CONFIG_SOURCE=""
CONFIG_URL=""
CLI_CONFIG_SOURCE=""
CLI_CONFIG_URL=""
TMP_DIR=""
STAGED_BIN=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '[INFO] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
source "${SCRIPT_DIR}/../common.sh"

usage() {
  cat <<'EOF'
Usage: install.sh [--env [FILE]] [--config-file FILE | --config-url URL]
Default: choose a proxy interactively. --env reads INSTALL_* proxy variables and
SINGBOX_SERVER_CONFIG_FILE or SINGBOX_SERVER_CONFIG_URL.
With neither set, reuse /etc/sing-box-server/config.json if it exists.
Environment: SINGBOX_VERSION. DOWNLOAD_PROXY remains a legacy binary-only fallback.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --env)
        USE_ENV=1; shift
        if [[ $# -gt 0 && "$1" != -* ]]; then ENV_FILE="$1"; shift; fi ;;
      --config-file|--config-url)
        if (($# < 2)) || [[ -z "$2" ]]; then error "Missing value for $1"; return 2; fi
        if [[ "$1" == --config-file ]]; then CLI_CONFIG_SOURCE="$2"; CLI_CONFIG_URL="";
        else CLI_CONFIG_URL="$2"; CLI_CONFIG_SOURCE=""; fi
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) error "Unknown argument: $1"; usage >&2; return 2 ;;
    esac
  done
}

resolve_config_source() {
  if ((USE_ENV)); then
    CONFIG_SOURCE="${SINGBOX_SERVER_CONFIG_FILE:-}"
    CONFIG_URL="${SINGBOX_SERVER_CONFIG_URL:-}"
  fi
  if [[ -n "$CLI_CONFIG_SOURCE" || -n "$CLI_CONFIG_URL" ]]; then
    CONFIG_SOURCE="$CLI_CONFIG_SOURCE"
    CONFIG_URL="$CLI_CONFIG_URL"
  fi
  if [[ -n "$CONFIG_SOURCE" && -n "$CONFIG_URL" ]]; then
    error "Set only one server configuration source."; return 2
  fi
  if [[ -n "$CONFIG_URL" ]]; then
    case "$CONFIG_URL" in http://*|https://*) ;; *) error "Config URL must use HTTP(S)."; return 2 ;; esac
  else
    CONFIG_SOURCE="${CONFIG_SOURCE:-$CONFIG_FILE}"
    if [[ ! -r "$CONFIG_SOURCE" ]]; then error "A readable server config file or URL is required."; return 2; fi
  fi
}

require_environment() {
  [[ "$EUID" -eq 0 ]] || { error "Run this installer as root."; return 1; }
  [[ -d /run/systemd/system ]] || { error "A running systemd instance is required."; return 1; }
  local cmd
  for cmd in curl tar gzip install mktemp systemctl flock cp mv; do
    command -v "$cmd" >/dev/null 2>&1 || { error "Missing command: $cmd"; return 1; }
  done
  require_legacy_stopped
}

stage_config() {
  if [[ -n "$CONFIG_URL" ]]; then
    info "Downloading server configuration..."
    download_file "${TMP_DIR}/config.json" "$CONFIG_URL"
  else
    cp -- "$CONFIG_SOURCE" "${TMP_DIR}/config.json"
  fi
  info "Validating server configuration..."
  "$STAGED_BIN" check -c "${TMP_DIR}/config.json"
}

install_files() {
  install -d -m 0700 "$CONFIG_DIR"
  if [[ -f "$CONFIG_FILE" ]]; then
    cp -a -- "$CONFIG_FILE" "${CONFIG_FILE}.bak-$(date +%Y%m%d-%H%M%S)-$$"
  fi
  install_binary
  install -m 0600 "${TMP_DIR}/config.json" "${CONFIG_FILE}.new"
  mv -f -- "${CONFIG_FILE}.new" "$CONFIG_FILE"
  cat >"${TMP_DIR}/sing-box-server.service" <<'UNIT'
[Unit]
Description=sing-box server
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
StateDirectory=sing-box-server
StateDirectoryMode=0700
WorkingDirectory=/var/lib/sing-box-server
UMask=0077
ExecStartPre=/usr/local/lib/sing-box-server/sing-box check -c /etc/sing-box-server/config.json
ExecStart=/usr/local/lib/sing-box-server/sing-box run -c /etc/sing-box-server/config.json
ExecReload=/usr/local/lib/sing-box-server/sing-box check -c /etc/sing-box-server/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
  install -m 0644 "${TMP_DIR}/sing-box-server.service" "$SINGBOX_UNIT"
}

start_service() {
  systemctl daemon-reload
  systemctl enable sing-box-server.service
  systemctl restart sing-box-server.service
  local elapsed
  for ((elapsed = 0; elapsed < 5; elapsed++)); do
    sleep 1
    if ! systemctl is-active --quiet sing-box-server.service; then
      systemctl stop sing-box-server.service
      error "Server startup failed. Inspect journalctl -u sing-box-server.service."
      return 1
    fi
  done
}

cleanup() {
  cleanup_proxy
  if [[ -n "$TMP_DIR" ]]; then rm -rf -- "$TMP_DIR"; fi
}

main() {
  parse_args "$@"
  require_environment
  umask 077
  STATE_DIR="${HOME:-/root}/.local/state/neko-sing-box-server-install"
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  proxy_configure
  if ((USE_ENV)); then
    STATE_DIR="${INSTALL_PROXY_STATE_DIR:-$STATE_DIR}"
  else
    SINGBOX_VERSION=1.13.13; DOWNLOAD_PROXY=""
  fi
  resolve_config_source
  exec 9>"$LOCK_FILE"
  flock -n 9 || { error "Another server installation is running."; return 1; }
  TMP_DIR="$(mktemp -d /var/tmp/sing-box-server-install.XXXXXX)"
  stage_singbox "$(resolve_architecture)"
  stage_config
  cleanup_proxy
  install_files
  start_service
  info "sing-box server ${SINGBOX_VERSION} is running."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
