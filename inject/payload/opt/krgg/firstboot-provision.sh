#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/krgg"
LOG_FILE="/var/log/krgg-provision.log"
ENV_FILE="/opt/krgg/device.env"
SETUP_SCRIPT="/opt/krgg/setup-raspi.sh"
ONYX_SETUP_SCRIPT="/opt/krgg/setup_eg25.sh"
MARKER_FILE="${STATE_DIR}/provisioned"
LAST_STATUS_FILE="${STATE_DIR}/last-status"
BOOT_STATUS_DIR=""
BOOT_LOG_FILE=""
BOOT_KRGG_DIR=""
UART_LOG_DEVICE=""
UART_BAUD="${KRGG_UART_BAUD:-115200}"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

init_boot_status_dir() {
  local dir
  for dir in "${KRGG_BOOT_KRGG_DIR:-}" /boot/firmware/krgg /boot/krgg; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    if mkdir -p "${dir}/status" 2>/dev/null; then
      BOOT_KRGG_DIR="$dir"
      BOOT_STATUS_DIR="${dir}/status"
      BOOT_LOG_FILE="${BOOT_STATUS_DIR}/provision.log"
      touch "$BOOT_LOG_FILE" 2>/dev/null || BOOT_LOG_FILE=""
      return
    fi
  done
}

init_boot_status_dir

load_env_file() {
  local env_file="$1"
  [ -f "$env_file" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

load_uart_env() {
  [ -n "$BOOT_KRGG_DIR" ] || return 0
  load_env_file "${BOOT_KRGG_DIR}/uart.env"
}

init_uart_log() {
  local enabled="${KRGG_UART_LOG:-false}"
  case "$enabled" in
    true|1|yes|y) ;;
    *) return 0 ;;
  esac

  UART_BAUD="${KRGG_UART_BAUD:-115200}"
  local candidate
  for candidate in "${KRGG_UART_DEVICE:-/dev/serial0}" /dev/serial0 /dev/ttyAMA0 /dev/ttyS0; do
    [ -n "$candidate" ] || continue
    if [ -w "$candidate" ]; then
      UART_LOG_DEVICE="$candidate"
      break
    fi
  done
  [ -n "$UART_LOG_DEVICE" ] || return 0
  if command -v stty >/dev/null 2>&1; then
    stty -F "$UART_LOG_DEVICE" "$UART_BAUD" cs8 -cstopb -parenb -ixon -ixoff -crtscts 2>/dev/null || true
  fi
}

uart_write() {
  [ -n "$UART_LOG_DEVICE" ] || return 0
  printf '%s\r\n' "$*" > "$UART_LOG_DEVICE" 2>/dev/null || true
}

load_uart_env
init_uart_log

log() {
  local message
  message="$(printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")"
  printf '%s\n' "$message"
  printf '%s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
  if [ -n "$BOOT_LOG_FILE" ]; then
    printf '%s\n' "$message" >> "$BOOT_LOG_FILE" 2>/dev/null || true
  fi
  uart_write "$message"
}

write_boot_status() {
  [ -n "$BOOT_STATUS_DIR" ] || return 0
  local status="$1"
  local message="${2:-}"
  {
    printf 'status=%s\n' "$status"
    printf 'message=%s\n' "$message"
    printf 'timestamp=%s\n' "$(timestamp)"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || true)"
    printf 'uptime_seconds=%s\n' "$(awk '{print int($1)}' /proc/uptime 2>/dev/null || true)"
  } > "${BOOT_STATUS_DIR}/last-status" 2>/dev/null || true
  printf '[%s]\t%s\t%s\n' "$(timestamp)" "$status" "$message" \
    >> "${BOOT_STATUS_DIR}/status-history.log" 2>/dev/null || true
  sync || true
}

copy_if_exists() {
  local src="$1"
  local dest="$2"
  [ -e "$src" ] || return 0
  cp "$src" "$dest" 2>/dev/null || true
}

run_diag() {
  local out_file="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  } > "$out_file" 2>&1 || true
}

stream_output() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
    if [ -n "$BOOT_LOG_FILE" ]; then
      printf '%s\n' "$line" >> "$BOOT_LOG_FILE" 2>/dev/null || true
    fi
    uart_write "$line"
  done
}

run_streamed() {
  set +e
  "$@" 2>&1 | stream_output
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

collect_diagnostics() {
  [ -n "$BOOT_STATUS_DIR" ] || return 0
  local status="$1"
  local message="${2:-}"
  local diag_dir="${BOOT_STATUS_DIR}/diag-$(date '+%Y%m%d-%H%M%S')"

  mkdir -p "$diag_dir" 2>/dev/null || return 0
  {
    printf 'status=%s\n' "$status"
    printf 'message=%s\n' "$message"
    printf 'timestamp=%s\n' "$(timestamp)"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || true)"
    printf 'kernel=%s\n' "$(uname -a 2>/dev/null || true)"
  } > "${diag_dir}/summary.txt" 2>/dev/null || true

  copy_if_exists "$LAST_STATUS_FILE" "${diag_dir}/last-status"
  copy_if_exists "$LOG_FILE" "${diag_dir}/krgg-provision.log"
  copy_if_exists /var/log/soracom-krypton-greengrass-setup.log "${diag_dir}/soracom-krypton-greengrass-setup.log"
  copy_if_exists /var/log/soracom_setup.log "${diag_dir}/soracom_setup.log"
  copy_if_exists /var/log/soracom_status.log "${diag_dir}/soracom_status.log"

  run_diag "${diag_dir}/systemctl-failed.txt" systemctl --failed --no-pager
  run_diag "${diag_dir}/krgg-provision-service.txt" systemctl status krgg-provision.service --no-pager
  run_diag "${diag_dir}/system-bus-services.txt" systemctl status dbus dbus.socket polkit iwd systemd-networkd systemd-resolved systemd-timesyncd --no-pager
  run_diag "${diag_dir}/network-services.txt" systemctl status NetworkManager ModemManager --no-pager
  run_diag "${diag_dir}/network-devices.txt" nmcli device status
  run_diag "${diag_dir}/network-active-connections.txt" nmcli connection show --active
  run_diag "${diag_dir}/machine-id.txt" sh -c 'ls -l /etc/machine-id /var/lib/dbus/machine-id 2>&1; printf "etc_machine_id_bytes="; wc -c < /etc/machine-id 2>/dev/null || true; printf "dbus_machine_id_bytes="; wc -c < /var/lib/dbus/machine-id 2>/dev/null || true'
  run_diag "${diag_dir}/modems.txt" mmcli -L
  run_diag "${diag_dir}/usb.txt" lsusb
  run_diag "${diag_dir}/ip-addresses.txt" ip -br addr
  run_diag "${diag_dir}/ip-routes.txt" ip route
  run_diag "${diag_dir}/journal-krgg-provision.txt" journalctl -u krgg-provision.service -n 200 --no-pager
  run_diag "${diag_dir}/journal-system-bus.txt" journalctl -u dbus -u dbus.socket -u polkit -u iwd -u systemd-networkd -u systemd-resolved -u systemd-timesyncd -n 300 --no-pager
  run_diag "${diag_dir}/journal-network.txt" journalctl -u NetworkManager -u ModemManager -n 200 --no-pager
  run_diag "${diag_dir}/greengrass-service.txt" systemctl status greengrass --no-pager

  printf '%s\n' "$diag_dir" > "${BOOT_STATUS_DIR}/latest-diagnostic" 2>/dev/null || true
  sync || true
}

report_status() {
  local status="$1"
  local message="${2:-}"
  printf '%s\t%s\n' "$status" "$message" > "$LAST_STATUS_FILE"
  log "STATUS: ${status} ${message}"
  write_boot_status "$status" "$message"

  if [ "$status" = "FAILED" ]; then
    collect_diagnostics "$status" "$message"
  fi

  if [ -n "${KRGG_STATUS_URL:-}" ]; then
    curl -fsS \
      --connect-timeout 5 \
      --max-time 15 \
      -H 'content-type: application/json' \
      -d "{\"status\":\"${status}\",\"message\":\"${message}\"}" \
      "$KRGG_STATUS_URL" >>"$LOG_FILE" 2>&1 || true
  fi
}

on_error() {
  local exit_code=$?
  local line="${BASH_LINENO[0]:-${LINENO}}"
  trap - ERR
  report_status "FAILED" "unexpected error at line ${line}; timer will retry"
  exit "$exit_code"
}

trap on_error ERR

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

ensure_system_bus_identity() {
  report_status "SYSTEM_BUS" "ensuring D-Bus machine identity"
  if [ ! -s /etc/machine-id ] && command -v systemd-machine-id-setup >/dev/null 2>&1; then
    systemd-machine-id-setup >>"$LOG_FILE" 2>&1 || true
  fi

  install -d -m 755 /var/lib/dbus
  if [ ! -e /var/lib/dbus/machine-id ]; then
    ln -s /etc/machine-id /var/lib/dbus/machine-id
  elif [ ! -L /var/lib/dbus/machine-id ] && [ -s /etc/machine-id ] && [ ! -s /var/lib/dbus/machine-id ]; then
    rm -f /var/lib/dbus/machine-id
    ln -s /etc/machine-id /var/lib/dbus/machine-id
  fi
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
  init_uart_log

  if [ "${KRGG_REQUIRE_BASE_IMAGE_PREREQS:-true}" = "true" ]; then
    check_base_image_prereqs
  fi

  ensure_system_bus_identity
  ensure_base_services

  if [ "${KRGG_RUN_ONYX_SETUP:-true}" = "true" ]; then
    [ -x "$ONYX_SETUP_SCRIPT" ] || {
      report_status "FAILED" "Onyx setup script missing: $ONYX_SETUP_SCRIPT"
      exit 1
    }
    report_status "ONYX_SETUP" "preparing soracom.io cellular profile"
    run_streamed timeout "${KRGG_ONYX_SETUP_TIMEOUT:-300}" \
      "$ONYX_SETUP_SCRIPT" \
      "${SORACOM_APN:-soracom.io}" \
      "${SORACOM_USERNAME:-sora}" \
      "${SORACOM_PASSWORD:-sora}" || {
        report_status "FAILED" "Onyx setup failed or timed out"
        exit 1
      }
    report_status "ONYX_SETUP_DONE" "cellular profile prepared"
  fi

  report_status "STARTED" "running KRGG provisioning"
  if run_streamed "$SETUP_SCRIPT" --env "$ENV_FILE"; then
    report_status "GREENGRASS_OK" "setup completed"
    touch "$MARKER_FILE"
    systemctl disable krgg-provision.timer >>"$LOG_FILE" 2>&1 || true
    exit 0
  fi

  report_status "FAILED" "setup failed; timer will retry"
  exit 1
}

main "$@"
