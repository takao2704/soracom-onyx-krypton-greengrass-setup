#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGES=(
  ca-certificates
  curl
  default-jdk-headless
  modemmanager
  network-manager
  net-tools
  python3
  unzip
  usbutils
  usb-modeswitch
)

REQUIRED_COMMANDS=(
  curl
  ip
  java
  lsusb
  mmcli
  nmcli
  python3
  route
  unzip
  usb_modeswitch
)

NUCLEUS_URL="${GREENGRASS_NUCLEUS_ZIP_URL:-https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip}"
NUCLEUS_PATH="/opt/krgg/greengrass-nucleus.zip"
CHECK_ONLY="false"
SKIP_INSTALL="false"
SKIP_NUCLEUS="false"

usage() {
  cat <<'EOF'
Usage:
  sudo tools/prepare-base-image.sh [OPTIONS]

Install the fixed dependencies that a zero-touch KRGG image needs before it has
cellular data connectivity. Run this once while preparing a base Raspberry Pi OS
image, then clone/capture that image for distribution.

Options:
  --check-only           Only verify required commands and services.
  --skip-install         Do not run apt install; useful after manual package prep.
  --skip-nucleus         Do not download Greengrass Nucleus into /opt/krgg.
  --nucleus-url URL      Greengrass Nucleus zip URL to download.
  --nucleus-path PATH    Where to store the Greengrass Nucleus zip.
  -h, --help             Show this help.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only)
      CHECK_ONLY="true"
      SKIP_INSTALL="true"
      SKIP_NUCLEUS="true"
      shift
      ;;
    --skip-install)
      SKIP_INSTALL="true"
      shift
      ;;
    --skip-nucleus)
      SKIP_NUCLEUS="true"
      shift
      ;;
    --nucleus-url)
      NUCLEUS_URL="${2:-}"
      [ -n "$NUCLEUS_URL" ] || die "--nucleus-url requires a value"
      shift 2
      ;;
    --nucleus-path)
      NUCLEUS_PATH="${2:-}"
      [ -n "$NUCLEUS_PATH" ] || die "--nucleus-path requires a value"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_root_for_changes() {
  if [ "$SKIP_INSTALL" = "true" ] && [ "$SKIP_NUCLEUS" = "true" ]; then
    return
  fi
  [ "$(id -u)" -eq 0 ] || die "Run as root: sudo tools/prepare-base-image.sh"
}

install_packages() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; this script targets Raspberry Pi OS / Debian"
  export DEBIAN_FRONTEND=noninteractive
  log "Installing base image packages: ${PACKAGES[*]}"
  apt-get update
  apt-get install -y "${PACKAGES[@]}"
}

enable_services() {
  command -v systemctl >/dev/null 2>&1 || return
  log "Enabling NetworkManager and ModemManager"
  systemctl enable NetworkManager
  systemctl enable ModemManager
}

download_nucleus() {
  log "Downloading Greengrass Nucleus zip to $NUCLEUS_PATH"
  install -d -m 755 "$(dirname "$NUCLEUS_PATH")"
  curl -fsSL "$NUCLEUS_URL" -o "$NUCLEUS_PATH"
  chmod 644 "$NUCLEUS_PATH"
}

check_prereqs() {
  local missing=()
  local command_name
  for command_name in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing+=("$command_name")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    die "Missing required commands: ${missing[*]}"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled --quiet NetworkManager || die "NetworkManager is not enabled"
    systemctl is-enabled --quiet ModemManager || die "ModemManager is not enabled"
  fi

  if [ "$SKIP_NUCLEUS" != "true" ] && [ ! -s "$NUCLEUS_PATH" ]; then
    die "Greengrass Nucleus zip missing or empty: $NUCLEUS_PATH"
  fi

  log "Base image prerequisites OK"
}

main() {
  require_root_for_changes

  if [ "$CHECK_ONLY" = "true" ]; then
    check_prereqs
    return
  fi

  if [ "$SKIP_INSTALL" != "true" ]; then
    install_packages
    enable_services
  fi

  if [ "$SKIP_NUCLEUS" != "true" ]; then
    download_nucleus
  fi

  check_prereqs
}

main "$@"
