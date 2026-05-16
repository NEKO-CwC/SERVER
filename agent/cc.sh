#!/usr/bin/env bash
set -euo pipefail

# cc launcher — injects IS_SANDBOX=true and starts claude --dangerously-skip-permissions

CC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_warn() {
  printf '[cc] WARN: %s\n' "$*" >&2
}

log_error() {
  printf '[cc] ERROR: %s\n' "$*" >&2
}

collect_cc_switch_env() {
  if ! command -v cc-switch &>/dev/null; then
    return 0
  fi

  local provider_id
  provider_id="$(cc-switch provider current -a claude 2>/dev/null)" || return 0
  provider_id="$(printf '%s' "$provider_id" | tr -d '[:space:]')"
  if [[ -z "$provider_id" ]]; then
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    log_warn "python3 不存在，跳过 cc-switch provider env 注入"
    return 0
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  if cc-switch provider export -a claude "$provider_id" -o "$tmp/settings.local.json" 2>/dev/null; then
    if [[ -f "$tmp/settings.local.json" ]]; then
      local env_json
      env_json="$(python3 -c "
import json, sys
try:
    with open('$tmp/settings.local.json') as f:
        data = json.load(f)
    env = data.get('env', {})
    for k, v in env.items():
        print(f'{k}={v}')
except Exception:
    pass
" 2>/dev/null)" || true
      if [[ -n "$env_json" ]]; then
        while IFS='=' read -r key value; do
          if [[ -n "$key" ]]; then
            export "$key=$value"
          fi
        done <<< "$env_json"
      fi
    fi
  fi
}

find_claude() {
  local candidates=(
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

  collect_cc_switch_env

  local claude_bin
  if ! claude_bin="$(find_claude)"; then
    log_error "找不到 claude 可执行文件，请确认 Claude Code 已安装"
    exit 1
  fi

  exec "$claude_bin" --dangerously-skip-permissions "$@"
}

main "$@"
