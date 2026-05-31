#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/krgg"
LOG_FILE="/var/log/krgg-firstrun.log"
MARKER_FILE="${STATE_DIR}/injected"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_STATUS_DIR="${SCRIPT_DIR}/status"
BOOT_LOG_FILE=""

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

if mkdir -p "$BOOT_STATUS_DIR" 2>/dev/null; then
  BOOT_LOG_FILE="${BOOT_STATUS_DIR}/firstrun.log"
  touch "$BOOT_LOG_FILE" 2>/dev/null || BOOT_LOG_FILE=""
fi

if [ -n "$BOOT_LOG_FILE" ]; then
  exec > >(tee -a "$LOG_FILE" "$BOOT_LOG_FILE") 2>&1
else
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

record_boot_status() {
  [ -n "$BOOT_LOG_FILE" ] || return 0
  local status="$1"
  local message="${2:-}"
  {
    printf 'status=%s\n' "$status"
    printf 'message=%s\n' "$message"
    printf 'timestamp=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } > "${BOOT_STATUS_DIR}/last-status" 2>/dev/null || true
  printf '[%s]\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$status" "$message" \
    >> "${BOOT_STATUS_DIR}/status-history.log" 2>/dev/null || true
  sync || true
}

remove_cmdline_hook() {
  local cmdline
  for cmdline in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [ -f "$cmdline" ] || continue
    python3 - "$cmdline" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
tokens = path.read_text().strip().split()
filtered = []
for token in tokens:
    if token.startswith("systemd.run=") and "krgg/firstrun.sh" in token:
        continue
    if token == "systemd.run_success_action=reboot":
        continue
    if token == "systemd.unit=kernel-command-line.target":
        continue
    filtered.append(token)
path.write_text(" ".join(filtered) + "\n")
PY
  done
}

main() {
  if [ -f "$MARKER_FILE" ]; then
    log "KRGG payload already injected"
    record_boot_status "FIRSTRUN_ALREADY_INJECTED" "payload marker already exists"
    remove_cmdline_hook
    exit 0
  fi

  local payload="${SCRIPT_DIR}/payload.tgz"
  [ -f "$payload" ] || {
    log "ERROR: payload not found: $payload"
    record_boot_status "FIRSTRUN_FAILED" "payload not found: $payload"
    exit 1
  }

  record_boot_status "FIRSTRUN_STARTED" "extracting payload"
  log "Extracting KRGG payload from $payload"
  tar -xzf "$payload" -C /
  chmod +x /opt/krgg/*.sh

  systemctl daemon-reload
  systemctl enable --now krgg-provision.timer

  touch "$MARKER_FILE"
  remove_cmdline_hook
  log "KRGG payload injection complete; provisioning timer will run after reboot"
  record_boot_status "FIRSTRUN_COMPLETE" "provisioning timer enabled"
}

main "$@"
