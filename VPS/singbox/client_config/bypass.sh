#!/usr/bin/env bash
set -euo pipefail

MARK_ID="0x100"
NFT_TABLE="singbox_bypass"
SSH_PORT="${SSH_PORT:-22}"

SSH_RULE_PREF="5000"
TAILSCALE_RULE_PREF="4004"
TAILSCALE_ROUTE_TABLE="52"
TAILSCALE_V4_CIDR="100.64.0.0/10"
TAILSCALE_V6_CIDR="fd7a:115c:a1e0::/48"

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

delete_rule() {
  local family="$1"
  shift

  while ip "${family}" rule del "$@" 2>/dev/null; do
    :
  done
}

cleanup() {
  nft delete table inet "${NFT_TABLE}" 2>/dev/null || true

  delete_rule -4 priority "${SSH_RULE_PREF}" fwmark "${MARK_ID}" table main
  delete_rule -4 priority "${TAILSCALE_RULE_PREF}" to "${TAILSCALE_V4_CIDR}" table "${TAILSCALE_ROUTE_TABLE}"
  delete_rule -6 priority "${TAILSCALE_RULE_PREF}" to "${TAILSCALE_V6_CIDR}" table "${TAILSCALE_ROUTE_TABLE}"
}

apply() {
  local public_iface
  local public_ip

  public_iface="${IFACE_PUBLIC:-$(detect_public_iface || true)}"
  if [[ -z "${public_iface}" ]]; then
    echo "Error: failed to detect the public network interface." >&2
    exit 1
  fi

  public_ip="$(
    ip -4 addr show dev "${public_iface}" scope global 2>/dev/null |
      awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}'
  )"
  if [[ -z "${public_ip}" ]]; then
    echo "Error: no IPv4 address found on ${public_iface}." >&2
    exit 1
  fi

  cleanup

  nft -f - <<NFT
table inet ${NFT_TABLE} {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "${public_iface}" tcp dport ${SSH_PORT} ct state new ct mark set ${MARK_ID} meta mark set ${MARK_ID} counter
  }

  chain output {
    type route hook output priority mangle; policy accept;
    ct mark ${MARK_ID} meta mark set ct mark counter
    tcp sport ${SSH_PORT} meta mark set ${MARK_ID} counter
    tcp dport ${SSH_PORT} meta mark set ${MARK_ID} counter
  }
}
NFT

  ip -4 rule add priority "${SSH_RULE_PREF}" fwmark "${MARK_ID}" table main
  ip -4 rule add priority "${TAILSCALE_RULE_PREF}" to "${TAILSCALE_V4_CIDR}" table "${TAILSCALE_ROUTE_TABLE}"
  ip -6 rule add priority "${TAILSCALE_RULE_PREF}" to "${TAILSCALE_V6_CIDR}" table "${TAILSCALE_ROUTE_TABLE}"

  echo "Configured sing-box bypass rules for ${public_iface} (${public_ip})."
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
