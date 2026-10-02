#!/usr/bin/env bash
set -euo pipefail

PROXY_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PROXY_WRAPPER_DIR}/lib/proxy.sh"
STATE_DIR="${HOME:-/root}/.local/state/neko-proxy"

usage() {
  cat <<'EOF'
Usage: bash with-proxy.sh [--env [FILE]] -- COMMAND [ARG...]
Default: choose a proxy interactively. --env uses INSTALL_* (or legacy AGENT_*) variables.
The command inherits the proxy; its temporary SSH tunnel is closed on exit.
EOF
}

while (($#)); do
  case "$1" in
    --env)
      USE_ENV=1; shift
      if [[ $# -gt 0 && "$1" != -* ]]; then ENV_FILE="$1"; shift; fi ;;
    --) shift; break ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
(($# > 0)) || { usage >&2; exit 2; }
umask 077
trap cleanup_proxy EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if ((USE_ENV)) && [[ -n "$ENV_FILE" ]]; then
  # Commands such as VPS/DD.sh also need their own values from the selected file.
  set -a
  load_env_file
  set +a
  ENV_FILE=""
fi
proxy_configure
if ((USE_ENV)); then STATE_DIR="${INSTALL_PROXY_STATE_DIR:-$STATE_DIR}"; fi
ensure_download_proxy
"$@"
