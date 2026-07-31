#!/usr/bin/env bash
set -euo pipefail

API_HOST="${AGENT_API_HOST:-sub2api.284072.xyz}"
API_IP="${AGENT_API_IP:-104.224.154.181}"
HOSTS_FILE="${AGENT_HOSTS_FILE:-/etc/hosts}"
MARKER="# neko-agent-api-rescue-v1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

cleanup() {
  sed -i "\|${MARKER}$|d" "${HOSTS_FILE}" 2>/dev/null ||
    printf '[rescue-v1] WARN: failed to clean %s\n' "${HOSTS_FILE}" >&2
}

find_binary() {
  local name="$1"
  local candidate

  if command -v "${name}" >/dev/null 2>&1; then
    command -v "${name}"
    return 0
  fi

  for candidate in \
    "/root/.local/bin/${name}" \
    "${HOME:-/root}/.local/bin/${name}" \
    "/usr/local/bin/${name}" \
    "/usr/bin/${name}" \
    "/bin/${name}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

if [[ "${EUID}" -ne 0 ]]; then
  printf '[rescue-v1] ERROR: run this script as root\n' >&2
  exit 1
fi
for command_name in curl sed; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '[rescue-v1] ERROR: missing command: %s\n' "${command_name}" >&2
    exit 1
  }
done
[[ "${API_HOST}" =~ ^[A-Za-z0-9.-]+$ ]] || { printf '[rescue-v1] ERROR: invalid host\n' >&2; exit 1; }
[[ "${API_IP}" =~ ^[0-9.]+$ ]] || { printf '[rescue-v1] ERROR: invalid IPv4 address\n' >&2; exit 1; }

printf '[rescue-v1] checking https://%s through %s\n' "${API_HOST}" "${API_IP}"
curl --noproxy '*' --resolve "${API_HOST}:443:${API_IP}" \
  --silent --show-error --connect-timeout 10 --max-time 20 \
  --output /dev/null "https://${API_HOST}/"

cleanup
sed -i "1i${API_IP} ${API_HOST} ${MARKER}" "${HOSTS_FILE}"
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export NO_PROXY="${NO_PROXY:+${NO_PROXY},}${API_HOST}"
export no_proxy="${no_proxy:+${no_proxy},}${API_HOST}"

if (($# == 0)); then
  set -- claude
fi

case "$1" in
  claude)
    shift
    set -- bash "${SCRIPT_DIR}/cc.sh" "$@"
    ;;
  codex)
    shift
    if ! agent_bin="$(find_binary codex)"; then
      printf '[rescue-v1] ERROR: codex not found (checked PATH and local bin directories)\n' >&2
      exit 1
    fi
    set -- "${agent_bin}" --yolo "$@"
    ;;
  --)
    shift
    (($# > 0)) || { printf '[rescue-v1] ERROR: missing command after --\n' >&2; exit 1; }
    ;;
esac

printf '[rescue-v1] temporary host mapping active; starting: %s\n' "$*"
"$@"
