#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/krgg"
LOG_FILE="/var/log/krgg-firstrun.log"
MARKER_FILE="${STATE_DIR}/injected"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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
    remove_cmdline_hook
    exit 0
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local payload="${script_dir}/payload.tgz"
  [ -f "$payload" ] || {
    log "ERROR: payload not found: $payload"
    exit 1
  }

  log "Extracting KRGG payload from $payload"
  tar -xzf "$payload" -C /
  chmod +x /opt/krgg/*.sh

  systemctl daemon-reload
  systemctl enable --now krgg-provision.timer

  touch "$MARKER_FILE"
  remove_cmdline_hook
  log "KRGG payload injection complete; provisioning timer will run after reboot"
}

main "$@"
