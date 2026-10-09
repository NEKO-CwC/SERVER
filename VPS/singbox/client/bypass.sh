#!/usr/bin/env bash
set -euo pipefail

MARK_ID="0x100"
NFT_TABLE="singbox_client_bypass"
SSH_PORT="${SSH_PORT:-22}"
INGRESS_TCP_PORTS="${INGRESS_TCP_PORTS-80,443}"

BYPASS_RULE_PREF="5000"
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

ensure_rule() {
  local family="$1"
  shift
  local selectors=("$@")
  local suppression=""
  local existing

  # ip rule show supports selectors, but not suppress_prefixlength.
  if [[ "${selectors[-2]}" == suppress_prefixlength ]]; then
    suppression="suppress_prefixlength ${selectors[-1]}"
    unset 'selectors[-1]'
    unset 'selectors[-1]'
  fi
  existing="$(ip "${family}" rule show "${selectors[@]}")"
  if [[ -z "${existing}" || (-n "${suppression}" && "${existing}" != *"${suppression}"*) ]]; then
    ip "${family}" rule add "$@"
  fi
}

validate_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

cleanup() {
  nft delete table inet "${NFT_TABLE}" 2>/dev/null || true

  local family
  for family in -4 -6; do
    delete_rule "${family}" priority "${BYPASS_RULE_PREF}" fwmark "${MARK_ID}/${MARK_ID}" table main
    # Remove rules from versions which matched the entire mark.
    delete_rule "${family}" priority "${BYPASS_RULE_PREF}" fwmark "${MARK_ID}/0xffffffff" table main
  done
  delete_rule -4 priority "${TAILSCALE_RULE_PREF}" to "${TAILSCALE_V4_CIDR}" table "${TAILSCALE_ROUTE_TABLE}"
  delete_rule -6 priority "${TAILSCALE_RULE_PREF}" to "${TAILSCALE_V6_CIDR}" table "${TAILSCALE_ROUTE_TABLE}"
}

apply() {
  local public_iface
  local public_ip
  local ingress_ports
  local port
  local ports=()
  local replace_table=""
  local family

  if ! validate_port "${SSH_PORT}"; then
    echo "Error: SSH_PORT must be a TCP port between 1 and 65535." >&2
    return 1
  fi
  SSH_PORT="$((10#${SSH_PORT}))"
  ingress_ports="${SSH_PORT}"
  if [[ -n "${INGRESS_TCP_PORTS}" ]]; then
    if [[ ! "${INGRESS_TCP_PORTS}" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
      echo "Error: INGRESS_TCP_PORTS must be a comma-separated list of TCP ports." >&2
      return 1
    fi
    IFS=, read -r -a ports <<<"${INGRESS_TCP_PORTS}"
    for port in "${ports[@]}"; do
      if ! validate_port "${port}"; then
        echo "Error: ingress TCP ports must be between 1 and 65535." >&2
        return 1
      fi
      port="$((10#${port}))"
      if [[ ",${ingress_ports}," != *",${port},"* ]]; then
        ingress_ports+=",${port}"
      fi
    done
  fi

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

  # Keep existing protection during reload, including if a later command fails.
  for family in -4 -6; do
    ensure_rule "${family}" priority "${BYPASS_RULE_PREF}" fwmark "${MARK_ID}/${MARK_ID}" table main
  done
  # Ignore an exit-node default while still using concrete Tailscale routes.
  ensure_rule -4 priority "${TAILSCALE_RULE_PREF}" to "${TAILSCALE_V4_CIDR}" table "${TAILSCALE_ROUTE_TABLE}" suppress_prefixlength 0
  ensure_rule -6 priority "${TAILSCALE_RULE_PREF}" to "${TAILSCALE_V6_CIDR}" table "${TAILSCALE_ROUTE_TABLE}" suppress_prefixlength 0

  if nft list table inet "${NFT_TABLE}" >/dev/null 2>&1; then
    replace_table="delete table inet ${NFT_TABLE}"
  fi

  # Deleting and recreating this table in one nft transaction is atomic.
  nft -f - <<NFT
${replace_table}
table inet ${NFT_TABLE} {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "${public_iface}" tcp dport { ${ingress_ports} } ct state new ct mark set ct mark | ${MARK_ID} meta mark set meta mark | ${MARK_ID} counter
    # Keep marked ingress flows on main, including replies from containers.
    ct mark & ${MARK_ID} != 0 meta mark set meta mark | ${MARK_ID} counter
  }

  chain output {
    type route hook output priority mangle; policy accept;
    ct direction reply ct mark & ${MARK_ID} != 0 meta mark set meta mark | ${MARK_ID} counter
    tcp sport ${SSH_PORT} meta mark set meta mark | ${MARK_ID} counter
    tcp dport ${SSH_PORT} meta mark set meta mark | ${MARK_ID} counter
  }
}
NFT

  for family in -4 -6; do
    delete_rule "${family}" priority "${BYPASS_RULE_PREF}" fwmark "${MARK_ID}/0xffffffff" table main
  done

  echo "Configured sing-box bypass rules for ${public_iface} (${public_ip}), ingress TCP ports ${ingress_ports}."
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
