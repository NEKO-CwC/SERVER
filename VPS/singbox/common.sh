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

# Upstream releases carry libcronet.so from 1.13.0 onward; the naive outbound needs it.
singbox_ships_cronet_lib() {
  local major minor
  [[ "$SINGBOX_VERSION" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
  ((major > 1 || (major == 1 && minor >= 13)))
}

stage_singbox() {
  local architecture="$1" installed_version
  local extracted_dir
  SINGBOX_LIB_SOURCE=""
  SINGBOX_FROM_ARCHIVE=0
  if [[ -x "$INSTALL_BIN" ]] && installed_version="$("$INSTALL_BIN" version 2>/dev/null)" &&
     [[ "${installed_version%%$'\n'*}" == "sing-box version ${SINGBOX_VERSION}" ]]; then
    # Only the client refuses to start over a missing library: a subscription may
    # contain naive outbounds, and installers written before this check copied the
    # executable alone.
    if [[ "${SINGBOX_REQUIRE_CRONET_LIB:-0}" != 1 ]] || ! singbox_ships_cronet_lib ||
       [[ -f "$(dirname "$INSTALL_BIN")/libcronet.so" ]]; then
      info "Using installed sing-box ${SINGBOX_VERSION}."
      STAGED_BIN="$INSTALL_BIN"
      return
    fi
    info "Installed sing-box ${SINGBOX_VERSION} is missing libcronet.so; downloading the archive again to add it."
  fi
  local archive_name="sing-box-${SINGBOX_VERSION}-linux-${architecture}.tar.gz"
  local archive_file="${TMP_DIR}/${archive_name}"
  extracted_dir="${TMP_DIR}/sing-box-${SINGBOX_VERSION}-linux-${architecture}"
  local extracted_bin="${extracted_dir}/sing-box"
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
  SINGBOX_FROM_ARCHIVE=1
  # The naive outbound loads libcronet.so from the executable's own directory, so it
  # must be installed next to sing-box; upstream ships it inside the release archive.
  if [[ -f "${extracted_dir}/libcronet.so" ]]; then
    SINGBOX_LIB_SOURCE="${extracted_dir}/libcronet.so"
  fi
}

install_binary() {
  local lib_target
  if [[ "$STAGED_BIN" != "$INSTALL_BIN" ]]; then
    install -d -m 0755 "$(dirname "$INSTALL_BIN")"
    install -m 0755 "$STAGED_BIN" "${INSTALL_BIN}.new"
    mv -f -- "${INSTALL_BIN}.new" "$INSTALL_BIN"
  fi
  # A fresh archive defines the complete install: place its library, or remove one left
  # behind by an earlier version whose archive no longer ships it.
  if [[ "${SINGBOX_FROM_ARCHIVE:-0}" == 1 ]]; then
    lib_target="$(dirname "$INSTALL_BIN")/libcronet.so"
    if [[ -n "$SINGBOX_LIB_SOURCE" ]]; then
      install -m 0644 "$SINGBOX_LIB_SOURCE" "${lib_target}.new"
      mv -f -- "${lib_target}.new" "$lib_target"
    else
      rm -f -- "$lib_target"
    fi
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
