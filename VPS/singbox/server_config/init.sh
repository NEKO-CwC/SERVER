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
SSH_PORT="22"
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
  local line
  local candidate

  while read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" == *" linkdown"* ]] && continue

    candidate="$(
      awk '{
        for (i = 1; i <= NF; i++) {
          if ($i == "dev") {
            print $(i + 1);
            exit;
          }
        }
      }' <<<"${line}"
    )"

    if [[ -n "${candidate}" ]] &&
       ! is_virtual_iface "${candidate}" &&
       ip -o link show dev "${candidate}" 2>/dev/null | grep -q 'LOWER_UP'; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(ip -4 route show default table main 2>/dev/null)

  candidate="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
  )"
  if [[ -n "${candidate}" ]] &&
     ! is_virtual_iface "${candidate}" &&
     ip -o link show dev "${candidate}" 2>/dev/null | grep -q 'LOWER_UP'; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  while read -r candidate; do
    if [[ -n "${candidate}" ]] &&
       ! is_virtual_iface "${candidate}" &&
       ip -o link show dev "${candidate}" 2>/dev/null | grep -q 'LOWER_UP'; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(
    ip -o -4 addr show scope global up 2>/dev/null |
      awk '{print $2}'
  )

  return 1
}

delete_rule_pref() {
  local pref="$1"
  while ip rule show | grep -Fq "${pref}:"; do
    ip rule del pref "${pref}"
  done
}

cleanup() {
  nft "delete table inet ${TABLE_NAME}" 2>/dev/null || true

  delete_rule_pref 3999
  delete_rule_pref 4000
  delete_rule_pref 4001
  delete_rule_pref 4003
  delete_rule_pref 4004
  delete_rule_pref 5000
}

apply() {
  local iface_public
  local internal_ip

  iface_public="${IFACE_PUBLIC:-$(detect_public_iface || true)}"
  if [[ -z "${iface_public}" ]]; then
    echo "Error: failed to detect public network interface." >&2
    exit 1
  fi

  internal_ip="$(
    ip -4 addr show dev "${iface_public}" scope global 2>/dev/null |
      awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}'
  )"
  if [[ -z "${internal_ip}" ]]; then
    echo "Error: failed to find IPv4 address on ${iface_public}." >&2
    exit 1
  fi

  echo "Detected public interface: ${iface_public} (${internal_ip})"
  echo "Configuring sing-box bypass routing rules..."

  cleanup

  nft "add table inet ${TABLE_NAME}"
  nft "add chain inet ${TABLE_NAME} prerouting { type filter hook prerouting priority mangle; policy accept; }"
  nft "add chain inet ${TABLE_NAME} output { type route hook output priority mangle; policy accept; }"
  nft "add rule inet ${TABLE_NAME} prerouting ip saddr ${NAPCAT_IP} ct mark set 0x00002024 meta mark set 0x00002024 counter"
  nft "add rule inet ${TABLE_NAME} prerouting iifname \"${iface_public}\" meta l4proto tcp tcp dport ${SSH_PORT} ct state new ct mark set ${MARK_ID} meta mark set ${MARK_ID} counter"
  nft "add rule inet ${TABLE_NAME} output ct mark ${MARK_ID} meta mark set ct mark counter"
  nft "add rule inet ${TABLE_NAME} output meta l4proto tcp tcp sport ${SSH_PORT} meta mark set ${MARK_ID} counter"
  nft "add rule inet ${TABLE_NAME} output meta l4proto tcp tcp dport ${SSH_PORT} meta mark set ${MARK_ID} counter"

  ip rule add fwmark "${MARK_ID}" pref 5000 lookup main
  ip rule add from "${NAPCAT_IP}" pref 3999 lookup main
  ip rule add to "${K8S_POD_CIDR}" pref 4000 lookup main
  ip rule add to "${K8S_SVC_CIDR}" pref 4001 lookup main
  ip rule add to "${LAN_CIDR}" pref 4003 lookup main
  ip rule add to "${TAILSCALE_CIDR}" pref 4004 lookup main

  echo "sing-box bypass routing rules configured."
}

case "${1:-apply}" in
  apply)
    apply
    ;;
  cleanup)
    cleanup
    ;;
  *)
    echo "Usage: $0 [apply|cleanup]" >&2
    exit 1
    ;;
esac
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
ExecStart=/etc/sing-box/bypass.sh apply
ExecReload=/etc/sing-box/bypass.sh apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

  info "Writing ${SINGBOX_SERVICE}..."
  cat > "${SINGBOX_SERVICE}" <<'UNIT'
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target bypass.service

[Service]
Type=simple
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
ExecStartPre=/etc/sing-box/bypass.sh apply
ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/config.json
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/etc/sing-box/bypass.sh apply
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
