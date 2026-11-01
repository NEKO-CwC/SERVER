#!/usr/bin/env bash
set -euo pipefail

# Claude reads the settings Magpie writes; no provider environment is injected.

CC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="/root/.local/bin:${HOME:-/root}/.local/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

log_warn() {
  printf '[cc] WARN: %s\n' "$*" >&2
}

log_error() {
  printf '[cc] ERROR: %s\n' "$*" >&2
}

find_claude() {
  local candidates=(
    "/root/.local/bin/claude"
    "${HOME:-/root}/.local/bin/claude"
    "/usr/local/bin/claude"
    "/usr/bin/claude"
    "/bin/claude"
  )

  if command -v claude &>/dev/null; then
    printf '%s' "$(command -v claude)"
    return 0
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

main() {
  export IS_SANDBOX=true

  local claude_bin
  if ! claude_bin="$(find_claude)"; then
    log_error "找不到 claude 可执行文件，请确认 Claude Code 已安装"
    exit 1
  fi

  exec "$claude_bin" --dangerously-skip-permissions "$@"
}

main "$@"
