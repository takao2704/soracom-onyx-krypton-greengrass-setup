#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/krgg"
LOG_FILE="/var/log/krgg-provision.log"
ENV_FILE="/opt/krgg/device.env"
SETUP_SCRIPT="/opt/krgg/setup-raspi.sh"
ONYX_SETUP_SCRIPT="/opt/krgg/setup_eg25.sh"
MARKER_FILE="${STATE_DIR}/provisioned"
LAST_STATUS_FILE="${STATE_DIR}/last-status"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

report_status() {
  local status="$1"
  local message="${2:-}"
  printf '%s\t%s\n' "$status" "$message" > "$LAST_STATUS_FILE"
  log "STATUS: ${status} ${message}"

  if [ -n "${KRGG_STATUS_URL:-}" ]; then
    curl -fsS \
      --connect-timeout 5 \
      --max-time 15 \
      -H 'content-type: application/json' \
      -d "{\"status\":\"${status}\",\"message\":\"${message}\"}" \
      "$KRGG_STATUS_URL" >>"$LOG_FILE" 2>&1 || true
  fi
}

check_base_image_prereqs() {
  local required_commands=(
    curl
    ip
    lsusb
    mmcli
    nmcli
    python3
    systemctl
    timeout
    usb_modeswitch
  )

  if [ "${SKIP_GREENGRASS:-false}" != "true" ]; then
    required_commands+=(
      java
      unzip
    )
  fi

  if [ "${KRGG_RUN_ONYX_SETUP:-true}" = "true" ]; then
    required_commands+=(
      route
    )
  fi

  local missing=()
  local command_name
  for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing+=("$command_name")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    report_status "FAILED" "base image missing prerequisites: ${missing[*]}"
    exit 1
  fi
}

ensure_base_services() {
  report_status "BASE_SERVICES" "starting NetworkManager and ModemManager"
  systemctl enable NetworkManager ModemManager >>"$LOG_FILE" 2>&1 || {
    report_status "FAILED" "failed to enable NetworkManager or ModemManager"
    exit 1
  }
  systemctl start NetworkManager ModemManager >>"$LOG_FILE" 2>&1 || {
    report_status "FAILED" "failed to start NetworkManager or ModemManager"
    exit 1
  }
}

main() {
  if [ -f "$MARKER_FILE" ]; then
    log "Provisioning already completed: $MARKER_FILE"
    exit 0
  fi

  [ -x "$SETUP_SCRIPT" ] || {
    report_status "FAILED" "setup script missing: $SETUP_SCRIPT"
    exit 1
  }
  [ -f "$ENV_FILE" ] || {
    report_status "FAILED" "env file missing: $ENV_FILE"
    exit 1
  }
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  if [ "${KRGG_REQUIRE_BASE_IMAGE_PREREQS:-true}" = "true" ]; then
    check_base_image_prereqs
  fi

  ensure_base_services

  if [ "${KRGG_RUN_ONYX_SETUP:-true}" = "true" ]; then
    [ -x "$ONYX_SETUP_SCRIPT" ] || {
      report_status "FAILED" "Onyx setup script missing: $ONYX_SETUP_SCRIPT"
      exit 1
    }
    report_status "ONYX_SETUP" "preparing soracom.io cellular profile"
    timeout "${KRGG_ONYX_SETUP_TIMEOUT:-300}" \
      "$ONYX_SETUP_SCRIPT" \
      "${SORACOM_APN:-soracom.io}" \
      "${SORACOM_USERNAME:-sora}" \
      "${SORACOM_PASSWORD:-sora}" >>"$LOG_FILE" 2>&1 || {
        report_status "FAILED" "Onyx setup failed or timed out"
        exit 1
      }
  fi

  report_status "STARTED" "running KRGG provisioning"
  if "$SETUP_SCRIPT" --env "$ENV_FILE"; then
    report_status "GREENGRASS_OK" "setup completed"
    touch "$MARKER_FILE"
    systemctl disable krgg-provision.timer >>"$LOG_FILE" 2>&1 || true
    exit 0
  fi

  report_status "FAILED" "setup failed; timer will retry"
  exit 1
}

main "$@"
