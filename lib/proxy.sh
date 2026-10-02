#!/usr/bin/env bash
# Shared process-scoped HTTP/SOCKS and temporary SSH proxy support.
USE_ENV=0
ENV_FILE=""
PROXY_URL=""
PROXY_MODE="none"
SSH_PROXY_HOST=""
SSH_PROXY_USER=""
SSH_PROXY_PASSWORD=""
SSH_PROXY_PORT=22
SSH_PROXY_SOCKS_PORT=1080
SSH_PROXY_HOST_KEY_CHECKING=no
SSH_PROXY_KNOWN_HOSTS_FILE=""
SSH_PROXY_PID=""
SSH_PROXY_DIR=""

proxy_log_info() { printf '[proxy] %s\n' "$*"; }
proxy_log_error() { printf '[proxy] ERROR: %s\n' "$*" >&2; }

load_env_file() {
  if [[ -n "$ENV_FILE" ]]; then
    [[ -f "$ENV_FILE" && -r "$ENV_FILE" ]] || { proxy_log_error "--env 文件不存在或不可读"; return 2; }
    if [[ "$ENV_FILE" != /* ]]; then ENV_FILE="./${ENV_FILE}"; fi
    source "$ENV_FILE"
  fi
}

proxy_load_environment() {
  PROXY_MODE="${INSTALL_PROXY_MODE:-${AGENT_PROXY_MODE:-env}}"
  PROXY_URL="${INSTALL_PROXY_URL:-${AGENT_PROXY_URL:-}}"
  SSH_PROXY_HOST="${INSTALL_SSH_HOST:-${AGENT_SSH_HOST:-}}"
  SSH_PROXY_USER="${INSTALL_SSH_USER:-${AGENT_SSH_USER:-}}"
  SSH_PROXY_PASSWORD="${INSTALL_SSH_PASSWORD:-${AGENT_SSH_PASSWORD:-}}"
  SSH_PROXY_PORT="${INSTALL_SSH_PORT:-${AGENT_SSH_PORT:-22}}"
  SSH_PROXY_SOCKS_PORT="${INSTALL_SSH_SOCKS_PORT:-${AGENT_SSH_SOCKS_PORT:-1080}}"
  SSH_PROXY_HOST_KEY_CHECKING="${INSTALL_SSH_HOST_KEY_CHECKING:-${AGENT_SSH_HOST_KEY_CHECKING:-no}}"
  SSH_PROXY_KNOWN_HOSTS_FILE="${INSTALL_SSH_KNOWN_HOSTS_FILE:-${AGENT_SSH_KNOWN_HOSTS_FILE:-}}"
}

proxy_hide_password() {
  unset INSTALL_SSH_PASSWORD AGENT_SSH_PASSWORD
  export -n SSH_PROXY_PASSWORD
}

prompt_value() {
  local target="$1" label="$2" default="${3:-}" required="${4:-1}" secret="${5:-0}" answer
  while true; do
    printf '%s' "$label" >&2
    if [[ -n "$default" ]]; then printf ' [%s]' "$default" >&2; fi
    printf ': ' >&2
    if ((secret)); then
      if ! IFS= read -r -s answer; then printf '\n' >&2; proxy_log_error "输入已取消"; return 2; fi
      printf '\n' >&2
    else
      if ! IFS= read -r answer; then proxy_log_error "输入已取消"; return 2; fi
    fi
    answer="${answer:-$default}"
    if ((required)) && [[ -z "$answer" ]]; then proxy_log_error "此项不能为空"; continue; fi
    printf -v "$target" '%s' "$answer"
    return 0
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

prompt_port() {
  local port_value
  while true; do
    prompt_value port_value "$2" "$3" || return $?
    if valid_port "$port_value"; then printf -v "$1" '%s' "$port_value"; return; fi
    proxy_log_error "端口必须在 1–65535 之间"
  done
}

prompt_proxy() {
  local choice
  if [[ ! -t 0 ]]; then
    proxy_log_error "默认交互模式需要终端；自动运行请使用 --env 或 --env FILE"
    return 2
  fi
  while true; do
    prompt_value choice "代理方式：1) 不使用代理  2) HTTP/HTTPS/SOCKS 地址  3) SSH SOCKS" 1
    case "$choice" in
      1) PROXY_MODE=none; break ;;
      2) PROXY_MODE=env; prompt_value PROXY_URL "代理 URL"; break ;;
      3)
        PROXY_MODE=ssh
        prompt_value SSH_PROXY_HOST "SSH 主机"
        prompt_value SSH_PROXY_USER "SSH 用户" bash-proxy
        prompt_value SSH_PROXY_PASSWORD "SSH 密码" "" 1 1
        prompt_port SSH_PROXY_PORT "SSH 端口" 22
        prompt_port SSH_PROXY_SOCKS_PORT "本地 SOCKS 端口" 1080
        while true; do
          prompt_value choice "主机密钥校验：1) 不校验、不登记  2) 首次自动登记  3) 严格校验" 1
          case "$choice" in
            1) SSH_PROXY_HOST_KEY_CHECKING=no; break ;;
            2) SSH_PROXY_HOST_KEY_CHECKING=accept-new; break ;;
            3) SSH_PROXY_HOST_KEY_CHECKING=yes; break ;;
            *) proxy_log_error "请选择 1、2 或 3" ;;
          esac
        done
        if [[ "$SSH_PROXY_HOST_KEY_CHECKING" != no ]]; then
          prompt_value SSH_PROXY_KNOWN_HOSTS_FILE "known_hosts 文件（留空使用 OpenSSH 默认文件）" "" 0
        fi
        break ;;
      *) proxy_log_error "请选择 1、2 或 3" ;;
    esac
  done
}

proxy_configure() {
  if ((USE_ENV)); then
    load_env_file
    proxy_load_environment
  else
    prompt_proxy
  fi
  proxy_hide_password
  proxy_prepare_env
}

proxy_prepare_env() {
  proxy_log_info "配置当前安装进程的下载代理"

  if ((USE_ENV == 0)); then
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
  else
    local proxy_key
    for proxy_key in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY; do
      if [[ -v "$proxy_key" ]]; then export "$proxy_key"; fi
    done
  fi
  case "$PROXY_MODE" in
    none)
      unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
      proxy_log_info "不使用代理"
      ;;
    env)
      if [[ -n "$PROXY_URL" ]]; then
        case "$PROXY_URL" in
          http://?*|https://?*|socks5://?*|socks5h://?*) ;;
          *) proxy_log_error "代理 URL 必须使用 http、https、socks5 或 socks5h"; return 2 ;;
        esac
      fi
      if [[ -n "$PROXY_URL" ]]; then export_proxy "$PROXY_URL"; fi
      proxy_log_info "使用当前进程的代理环境变量"
      ;;
    ssh) proxy_log_info "SSH SOCKS 模式：需要联网时建立临时隧道" ;;
    *) proxy_log_error "INSTALL_PROXY_MODE（或 AGENT_PROXY_MODE）仅支持 none、env 或 ssh"; return 2 ;;
  esac
}

export_proxy() {
  export http_proxy="$1" https_proxy="$1" all_proxy="$1"
  export HTTP_PROXY="$1" HTTPS_PROXY="$1" ALL_PROXY="$1"
}

ssh_proxy_control() {
  ssh -F /dev/null -S "${SSH_PROXY_DIR}/control" -O check \
    -p "$SSH_PROXY_PORT" -l "$SSH_PROXY_USER" "$SSH_PROXY_HOST" \
    >/dev/null 2>&1
}

ensure_download_proxy() {
  [[ "$PROXY_MODE" == ssh ]] || return 0
  if [[ -n "$SSH_PROXY_PID" ]]; then
    if kill -0 "$SSH_PROXY_PID" 2>/dev/null && ssh_proxy_control; then return 0; fi
    proxy_log_error "SSH SOCKS 隧道已断开；停止安装，请修复连接后重试"
    return 1
  fi

  local ssh_port="$SSH_PROXY_PORT" socks_port="$SSH_PROXY_SOCKS_PORT"
  local value deadline
  if [[ -z "$SSH_PROXY_HOST" || -z "$SSH_PROXY_USER" || -z "$SSH_PROXY_PASSWORD" ]]; then
    proxy_log_error "SSH 模式需要主机、用户名和密码（--env 模式使用 INSTALL_SSH_HOST、INSTALL_SSH_USER、INSTALL_SSH_PASSWORD）"
    return 2
  fi
  if [[ "$SSH_PROXY_HOST" == -* || "$SSH_PROXY_HOST" == *[!a-zA-Z0-9.:-]* ||
        "$SSH_PROXY_USER" == -* || "$SSH_PROXY_USER" == *[!a-zA-Z0-9_.-]* ]]; then
    proxy_log_error "SSH 主机或用户名格式无效"
    return 2
  fi
  for value in "$ssh_port" "$socks_port"; do
    if ! valid_port "$value"; then
      proxy_log_error "SSH 端口和 SOCKS 端口必须在 1–65535 之间"
      return 2
    fi
  done
  if [[ "$SSH_PROXY_PASSWORD" == *$'\n'* || "$SSH_PROXY_PASSWORD" == *$'\r'* ]]; then
    proxy_log_error "SSH 密码不能包含换行符"
    return 2
  fi
  command -v ssh >/dev/null 2>&1 || { proxy_log_error "SSH 模式需要 OpenSSH 客户端"; return 1; }
  STATE_DIR="${STATE_DIR:-${HOME:-/root}/.local/state/neko-proxy}"
  install -d -m 0700 "$STATE_DIR" || return 1
  SSH_PROXY_DIR="$(mktemp -d /tmp/neko-agent-ssh.XXXXXX)" || return 1
  cat >"${SSH_PROXY_DIR}/askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' "$AGENT_SSH_PASSWORD"
ASKPASS
  chmod 0700 "${SSH_PROXY_DIR}/askpass" || return 1

  local options=(
    -F /dev/null -N -T -n -M -S "${SSH_PROXY_DIR}/control"
    -D "127.0.0.1:${socks_port}" -p "$ssh_port" -l "$SSH_PROXY_USER"
    -o ExitOnForwardFailure=yes -o ControlPersist=no
    -o ConnectTimeout=15 -o ConnectionAttempts=1
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2
    -o PreferredAuthentications=password -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=1
    -o UpdateHostKeys=no
  )
  case "$SSH_PROXY_HOST_KEY_CHECKING" in
    no)
      options+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null)
      ;;
    accept-new)
      local known_hosts="${SSH_PROXY_KNOWN_HOSTS_FILE:-${HOME:-/root}/.ssh/known_hosts}"
      local known_hosts_dir
      known_hosts_dir="$(dirname "$known_hosts")" || return 1
      if [[ ! -d "$known_hosts_dir" ]]; then install -d -m 0700 "$known_hosts_dir" || return 1; fi
      if [[ ! -e "$known_hosts" ]]; then
        touch "$known_hosts" || return 1
        chmod 0600 "$known_hosts" || return 1
      fi
      if [[ ! -f "$known_hosts" || ! -r "$known_hosts" || ! -w "$known_hosts" ]]; then
        proxy_log_error "accept-new 模式需要可读写的 known_hosts 普通文件"
        return 2
      fi
      options+=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=\"${known_hosts}\"")
      ;;
    yes)
      options+=(-o StrictHostKeyChecking=yes)
      if [[ -n "$SSH_PROXY_KNOWN_HOSTS_FILE" ]]; then
        [[ -r "$SSH_PROXY_KNOWN_HOSTS_FILE" ]] || { proxy_log_error "SSH known_hosts 文件不可读"; return 2; }
        options+=(-o "UserKnownHostsFile=\"${SSH_PROXY_KNOWN_HOSTS_FILE}\"")
      fi
      ;;
    *) proxy_log_error "INSTALL_SSH_HOST_KEY_CHECKING（或 AGENT_SSH_HOST_KEY_CHECKING）仅支持 no、accept-new 或 yes"; return 2 ;;
  esac
  proxy_log_info "建立临时 SSH SOCKS 隧道（仅监听 127.0.0.1:${socks_port}）"
  AGENT_SSH_PASSWORD="$SSH_PROXY_PASSWORD" \
    SSH_ASKPASS="${SSH_PROXY_DIR}/askpass" SSH_ASKPASS_REQUIRE=force \
    ssh "${options[@]}" "$SSH_PROXY_HOST" \
    </dev/null 9>&- >"${STATE_DIR}/ssh-proxy.log" 2>&1 &
  SSH_PROXY_PID=$!
  deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    if ! kill -0 "$SSH_PROXY_PID" 2>/dev/null; then
      proxy_log_error "SSH 隧道启动失败；检查认证、主机密钥和端口。详情：${STATE_DIR}/ssh-proxy.log"
      return 1
    fi
    if [[ -S "${SSH_PROXY_DIR}/control" ]] && ssh_proxy_control; then
      export_proxy "socks5h://127.0.0.1:${socks_port}"
      proxy_log_info "SSH SOCKS 隧道已就绪，下载使用远程 DNS 解析"
      return 0
    fi
    sleep 0.1
  done
  proxy_log_error "等待 SSH 隧道启动超时；详情：${STATE_DIR}/ssh-proxy.log"
  return 1
}

cleanup_proxy() {
  local ssh_result=0
  if [[ -n "$SSH_PROXY_PID" ]]; then
    if kill -0 "$SSH_PROXY_PID" 2>/dev/null; then
      if ! kill "$SSH_PROXY_PID" 2>/dev/null; then proxy_log_error "未能发送 SSH 停止信号"; fi
    fi
    wait "$SSH_PROXY_PID" || ssh_result=$?
    proxy_log_info "本次安装的 SSH 隧道已结束（退出码 ${ssh_result}）"
    SSH_PROXY_PID=""
  fi
  if [[ -n "$SSH_PROXY_DIR" ]]; then
    rm -rf -- "$SSH_PROXY_DIR"
    SSH_PROXY_DIR=""
  fi
}
