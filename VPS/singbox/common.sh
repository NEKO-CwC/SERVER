#!/usr/bin/env bash
# Shared download helpers. Each role owns its binary, configuration and service.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/proxy.sh"

resolve_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) error "Unsupported architecture: $(uname -m)"; return 1 ;;
  esac
}

download_file() {
  local output_file="$1" download_url="$2"
  shift 2
  ensure_download_proxy || return $?
  curl --fail --silent --show-error --location \
    --retry 3 --retry-all-errors --retry-delay 2 \
    --connect-timeout 20 --max-time 180 \
    --output "$output_file" "$@" "$download_url"
}

stage_singbox() {
  local architecture="$1" installed_version
  if [[ -x "$INSTALL_BIN" ]] && installed_version="$("$INSTALL_BIN" version 2>/dev/null)" &&
     [[ "${installed_version%%$'\n'*}" == "sing-box version ${SINGBOX_VERSION}" ]]; then
    info "Using installed sing-box ${SINGBOX_VERSION}."
    STAGED_BIN="$INSTALL_BIN"
    return
  fi
  local archive_name="sing-box-${SINGBOX_VERSION}-linux-${architecture}.tar.gz"
  local archive_file="${TMP_DIR}/${archive_name}"
  local extracted_bin="${TMP_DIR}/sing-box-${SINGBOX_VERSION}-linux-${architecture}/sing-box"
  local curl_options=()
  # Backward compatibility: only an otherwise unspecified env proxy may use this binary-only override.
  if [[ "$PROXY_MODE" == env && -z "$PROXY_URL" && -n "${DOWNLOAD_PROXY:-}" ]]; then
    curl_options+=(--proxy "$DOWNLOAD_PROXY")
  fi
  info "Downloading sing-box ${SINGBOX_VERSION} for ${architecture}..."
  download_file "$archive_file" "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${archive_name}" "${curl_options[@]}"
  tar -xzf "$archive_file" -C "$TMP_DIR"
  if [[ ! -x "$extracted_bin" ]] || ! installed_version="$("$extracted_bin" version)" ||
     [[ "${installed_version%%$'\n'*}" != "sing-box version ${SINGBOX_VERSION}" ]]; then
    error "The downloaded binary is missing or has an unexpected version."
    return 1
  fi
  STAGED_BIN="$extracted_bin"
}

install_binary() {
  if [[ "$STAGED_BIN" != "$INSTALL_BIN" ]]; then
    install -d -m 0755 "$(dirname "$INSTALL_BIN")"
    install -m 0755 "$STAGED_BIN" "${INSTALL_BIN}.new"
    mv -f -- "${INSTALL_BIN}.new" "$INSTALL_BIN"
  fi
}

require_legacy_stopped() {
  local unit
  for unit in sing-box.service bypass.service; do
    if systemctl is-active --quiet "$unit" || systemctl is-enabled --quiet "$unit"; then
      error "Legacy ${unit} is active or enabled. Disable the old installation first; see README migration instructions."
      return 1
    fi
  done
}
