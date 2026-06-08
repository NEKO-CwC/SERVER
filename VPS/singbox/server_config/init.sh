#!/usr/bin/env bash
set -euo pipefail

SINGBOX_VERSION="1.13.13"
DEB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box_${SINGBOX_VERSION}_linux_amd64.deb"
INSTALL_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BYPASS_SCRIPT="${CONFIG_DIR}/bypass.sh"
BYPASS_SERVICE="/etc/systemd/system/bypass.service"
SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"

info() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "Run this script as root."
    exit 1
  fi
}

require_commands() {
  local missing=()
  local cmd
  for cmd in curl dpkg-deb systemctl ip nft awk sort install grep; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    error "Missing required commands: ${missing[*]}"
    exit 1
  fi
}

prompt_subscription_url() {
  local sub_url
  printf 'Enter sing-box subscription URL: ' >&2
  read -r sub_url
  if [[ -z "${sub_url}" ]]; then
    error "Subscription URL cannot be empty."
    exit 1
  fi
  printf '%s\n' "${sub_url}"
}

install_singbox() {
  local tmpdir="$1"
  local deb_file="${tmpdir}/sing-box.deb"
  local extract_dir="${tmpdir}/deb"
  local extracted_bin

  info "Downloading sing-box ${SINGBOX_VERSION}..."
  curl -fSL -o "${deb_file}" "${DEB_URL}"

  info "Extracting sing-box package..."
  mkdir -p "${extract_dir}"
  dpkg-deb -x "${deb_file}" "${extract_dir}"

  extracted_bin="${extract_dir}/usr/bin/sing-box"
  if [[ ! -x "${extracted_bin}" ]]; then
    error "sing-box binary not found in package: ${extracted_bin}"
    exit 1
  fi

  info "Installing sing-box to ${INSTALL_BIN}..."
  install -m 0755 "${extracted_bin}" "${INSTALL_BIN}"
}

install_config() {
  local tmpdir="$1"
  local sub_url="$2"
  local tmp_config="${tmpdir}/config.json"
  local backup_file

  info "Downloading subscription config with User-Agent: sing-box..."
  curl -fSL -A sing-box -o "${tmp_config}" "${sub_url}"

  info "Checking downloaded config..."
  "${INSTALL_BIN}" check -c "${tmp_config}"

  mkdir -p "${CONFIG_DIR}"
  if [[ -f "${CONFIG_FILE}" ]]; then
    backup_file="${CONFIG_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
    info "Backing up existing config to ${backup_file}..."
    cp -a "${CONFIG_FILE}" "${backup_file}"
  fi

  info "Installing config to ${CONFIG_FILE}..."
  install -m 0644 "${tmp_config}" "${CONFIG_FILE}"
}

install_bypass_script() {
  mkdir -p "${CONFIG_DIR}"

  info "Writing ${BYPASS_SCRIPT}..."
  cat > "${BYPASS_SCRIPT}" <<'BYPASS'
#!/usr/bin/env bash
set -euo pipefail

MARK_ID="0x100"
TABLE_NAME="singbox_bypass"
NAPCAT_IP="10.42.0.143"
K8S_POD_CIDR="10.42.0.0/16"
K8S_SVC_CIDR="10.43.0.0/16"
LAN_CIDR="192.168.0.0/16"
TAILSCALE_CIDR="100.64.0.0/10"

is_virtual_iface() {
  case "$1" in
    lo|singbox|tun*|tap*|wg*|tailscale*|docker*|br-*|veth*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_public_iface() {
  local candidate

  while read -r candidate; do
    if [[ -n "${candidate}" ]] && ! is_virtual_iface "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(
    ip -4 route show default table main 2>/dev/null |
      awk '{
        dev = "";
        metric = 0;
        for (i = 1; i <= NF; i++) {
          if ($i == "dev") dev = $(i + 1);
          if ($i == "metric") metric = $(i + 1);
        }
        if (dev != "") print metric, dev;
      }' |
      sort -n |
      awk '{print $2}'
  )

  candidate="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
  )"
  if [[ -n "${candidate}" ]] && ! is_virtual_iface "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  while read -r candidate; do
    if [[ -n "${candidate}" ]] && ! is_virtual_iface "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(
    ip -o -4 addr show scope global up 2>/dev/null |
      awk '{print $2}'
  )

  return 1
}

IFACE_PUBLIC="${IFACE_PUBLIC:-$(detect_public_iface || true)}"
if [[ -z "${IFACE_PUBLIC}" ]]; then
  echo "Error: failed to detect public network interface." >&2
  exit 1
fi

INTERNAL_IP="$(
  ip -4 addr show dev "${IFACE_PUBLIC}" scope global 2>/dev/null |
    awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}'
)"
if [[ -z "${INTERNAL_IP}" ]]; then
  echo "Error: failed to find IPv4 address on ${IFACE_PUBLIC}." >&2
  exit 1
fi

echo "Detected public interface: ${IFACE_PUBLIC} (${INTERNAL_IP})"
echo "Configuring sing-box bypass routing rules..."

nft "delete table inet ${TABLE_NAME}" 2>/dev/null || true
nft "add table inet ${TABLE_NAME}"
nft "add chain inet ${TABLE_NAME} prerouting { type filter hook prerouting priority -150; policy accept; }"
nft "add chain inet ${TABLE_NAME} napcat_bypass { type filter hook prerouting priority dstnat - 2; policy accept; }"
nft "add rule inet ${TABLE_NAME} napcat_bypass ip saddr ${NAPCAT_IP} ct mark set 0x00002024 meta mark set 0x00002024 counter"
nft "add rule inet ${TABLE_NAME} prerouting iifname \"${IFACE_PUBLIC}\" fib daddr type local ct state new ct mark set ${MARK_ID} counter"
nft "add rule inet ${TABLE_NAME} prerouting iifname != \"${IFACE_PUBLIC}\" ct mark ${MARK_ID} meta mark set ct mark counter"

ensure_rule() {
  local pattern="$1"
  shift
  if ! ip rule show | grep -Fq "${pattern}"; then
    ip rule add "$@"
  fi
}

ensure_rule "fwmark ${MARK_ID}" fwmark "${MARK_ID}" pref 5000 lookup main
ensure_rule "from ${NAPCAT_IP}" from "${NAPCAT_IP}" pref 3999 lookup main
ensure_rule "to ${K8S_POD_CIDR}" to "${K8S_POD_CIDR}" pref 4000 lookup main
ensure_rule "to ${K8S_SVC_CIDR}" to "${K8S_SVC_CIDR}" pref 4001 lookup main
ensure_rule "to ${LAN_CIDR}" to "${LAN_CIDR}" pref 4003 lookup main
ensure_rule "to ${TAILSCALE_CIDR}" to "${TAILSCALE_CIDR}" pref 4004 lookup main

echo "sing-box bypass routing rules configured."
BYPASS

  chmod 0755 "${BYPASS_SCRIPT}"
}

install_systemd_units() {
  info "Writing ${BYPASS_SERVICE}..."
  cat > "${BYPASS_SERVICE}" <<'UNIT'
[Unit]
Description=sing-box bypass routing rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/sing-box/bypass.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

  info "Writing ${SINGBOX_SERVICE}..."
  cat > "${SINGBOX_SERVICE}" <<'UNIT'
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target bypass.service
Wants=network-online.target
Requires=bypass.service

[Service]
Type=simple
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/config.json
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
}

enable_and_start_services() {
  info "Reloading systemd..."
  systemctl daemon-reload

  info "Enabling services..."
  systemctl enable bypass.service sing-box.service

  info "Starting bypass.service..."
  systemctl restart bypass.service

  info "Starting sing-box.service..."
  systemctl restart sing-box.service
}

main() {
  local sub_url
  local tmpdir

  require_root
  require_commands
  sub_url="$(prompt_subscription_url)"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT

  install_singbox "${tmpdir}"
  install_config "${tmpdir}" "${sub_url}"
  install_bypass_script
  install_systemd_units
  enable_and_start_services

  info "Installed sing-box ${SINGBOX_VERSION}."
  "${INSTALL_BIN}" version
  systemctl --no-pager status bypass.service sing-box.service || true
}

main "$@"
