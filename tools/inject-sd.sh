#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT_DIR=""
MODE="cmdline"
PAYLOAD_PATH=""
NUCLEUS_ZIP=""
RUN_PATH="/boot/firmware/krgg/firstrun.sh"
FORCE_USER_DATA="false"
ENABLE_UART_LOG="false"
UART_DEVICE="/dev/serial0"
UART_BAUD="115200"

usage() {
  cat <<'EOF'
Usage:
  tools/inject-sd.sh [--boot PATH] [OPTIONS]

Inject KRGG first-boot provisioning files into a mounted Raspberry Pi boot partition.

Options:
  --boot PATH, -b PATH   Mounted boot partition path, e.g. /Volumes/bootfs.
                         If omitted in an interactive shell, choose from candidates.
  --payload PATH         Use an existing payload tarball.
  --nucleus-zip PATH     Include a Greengrass Nucleus zip when building payload.
  --mode MODE            Hook mode: cmdline or cloud-init. Default: cmdline.
  --run-path PATH        Runtime path for firstrun.sh in cmdline mode.
                         Default: /boot/firmware/krgg/firstrun.sh.
  --uart-log             Enable debug log output to UART.
  --uart-device PATH     UART device path used on the Raspberry Pi. Default: /dev/serial0.
  --uart-baud BAUD       UART baud rate. Default: 115200.
  --force-user-data      In cloud-init mode, replace existing user-data/meta-data.
  -h, --help             Show this help.

Notes:
  cmdline mode appends a one-shot systemd.run hook to cmdline.txt and preserves
  existing Raspberry Pi Imager user-data.
EOF
}

find_boot_candidates() {
  local candidate
  if [ -d /Volumes ]; then
    for candidate in /Volumes/*; do
      [ -d "$candidate" ] || continue
      [ -f "${candidate}/cmdline.txt" ] || continue
      printf '%s\n' "$candidate"
    done
  fi
}

candidate_label() {
  local path="$1"
  local device=""
  local size=""
  if command -v diskutil >/dev/null 2>&1; then
    device="$(diskutil info "$path" 2>/dev/null | awk -F: '/Device Identifier/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    size="$(diskutil info "$path" 2>/dev/null | awk -F: '/Disk Size/ {gsub(/^[ \t]+/, "", $2); sub(/ *\(.*/, "", $2); print $2; exit}')"
  fi
  if [ -n "$device" ] && [ -n "$size" ]; then
    printf '%s (%s, %s)' "$path" "$device" "$size"
  elif [ -n "$device" ]; then
    printf '%s (%s)' "$path" "$device"
  else
    printf '%s' "$path"
  fi
}

select_boot_dir() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "--boot is required when not running in an interactive terminal." >&2
    usage >&2
    exit 2
  fi

  local candidates=()
  local candidate
  while IFS= read -r candidate; do
    candidates+=("$candidate")
  done < <(find_boot_candidates)

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "No mounted Raspberry Pi boot partition candidates found. Re-run with --boot PATH." >&2
    exit 1
  fi

  echo "Select a Raspberry Pi boot partition:"
  local i
  for i in "${!candidates[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "$(candidate_label "${candidates[$i]}")"
  done

  local choice
  while true; do
    printf 'Enter number, or q to quit: '
    IFS= read -r choice
    case "$choice" in
      q|Q)
        echo "Cancelled." >&2
        exit 1
        ;;
      ''|*[!0-9]*)
        echo "Enter a number from 1 to ${#candidates[@]}, or q to quit." >&2
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates[@]}" ]; then
          BOOT_DIR="${candidates[$((choice - 1))]}"
          return
        fi
        echo "Enter a number from 1 to ${#candidates[@]}, or q to quit." >&2
        ;;
    esac
  done
}

enable_uart_config() {
  local config="${BOOT_DIR}/config.txt"
  if [ ! -f "$config" ]; then
    echo "config.txt not found in boot partition; cannot enable UART: $config" >&2
    exit 1
  fi
  cp "$config" "${config}.pre-krgg-uart"
  python3 - "$config" "$UART_BAUD" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
uart_baud = sys.argv[2]
lines = path.read_text().splitlines()
updated = []
found_enable_uart = False
found_disable_bt = False
found_init_uart_baud = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("enable_uart="):
        updated.append("enable_uart=1")
        found_enable_uart = True
    elif stripped in ("dtoverlay=disable-bt", "dtoverlay=disable-bt,"):
        updated.append("dtoverlay=disable-bt")
        found_disable_bt = True
    elif stripped.startswith("#") and stripped.lstrip("# ").strip() == "dtoverlay=disable-bt":
        updated.append("dtoverlay=disable-bt")
        found_disable_bt = True
    elif stripped.startswith("init_uart_baud="):
        updated.append(f"init_uart_baud={uart_baud}")
        found_init_uart_baud = True
    else:
        updated.append(line)
missing = []
if not found_disable_bt:
    missing.append("dtoverlay=disable-bt")
if not found_enable_uart:
    missing.append("enable_uart=1")
if not found_init_uart_baud:
    missing.append(f"init_uart_baud={uart_baud}")
if missing:
    if updated and updated[-1].strip():
        updated.append("")
    updated.extend([
        "# KRGG UART debug",
        "[all]",
        *missing,
    ])
path.write_text("\n".join(updated) + "\n")
PY
}

write_uart_env() {
  cat > "${BOOT_DIR}/krgg/uart.env" <<EOF
KRGG_UART_LOG="true"
KRGG_UART_DEVICE="${UART_DEVICE}"
KRGG_UART_BAUD="${UART_BAUD}"
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --boot|-b)
      BOOT_DIR="${2:-}"
      [ -n "$BOOT_DIR" ] || { echo "--boot requires a path" >&2; exit 2; }
      shift 2
      ;;
    --payload)
      PAYLOAD_PATH="${2:-}"
      [ -n "$PAYLOAD_PATH" ] || { echo "--payload requires a path" >&2; exit 2; }
      shift 2
      ;;
    --nucleus-zip)
      NUCLEUS_ZIP="${2:-}"
      [ -n "$NUCLEUS_ZIP" ] || { echo "--nucleus-zip requires a path" >&2; exit 2; }
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      [ "$MODE" = "cmdline" ] || [ "$MODE" = "cloud-init" ] || {
        echo "--mode must be cmdline or cloud-init" >&2
        exit 2
      }
      shift 2
      ;;
    --run-path)
      RUN_PATH="${2:-}"
      [ -n "$RUN_PATH" ] || { echo "--run-path requires a path" >&2; exit 2; }
      shift 2
      ;;
    --uart-log)
      ENABLE_UART_LOG="true"
      shift
      ;;
    --uart-device)
      UART_DEVICE="${2:-}"
      [ -n "$UART_DEVICE" ] || { echo "--uart-device requires a path" >&2; exit 2; }
      shift 2
      ;;
    --uart-baud)
      UART_BAUD="${2:-}"
      case "$UART_BAUD" in
        ''|*[!0-9]*) echo "--uart-baud must be numeric" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --force-user-data)
      FORCE_USER_DATA="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$BOOT_DIR" ]; then
  select_boot_dir
fi
[ -d "$BOOT_DIR" ] || { echo "boot partition path not found: $BOOT_DIR" >&2; exit 1; }

TEMP_PAYLOAD=""
if [ -z "$PAYLOAD_PATH" ]; then
  TEMP_PAYLOAD="$(mktemp "${TMPDIR:-/tmp}/krgg-payload.XXXXXX.tgz")"
  BUILD_ARGS=(--out "$TEMP_PAYLOAD")
  if [ -n "$NUCLEUS_ZIP" ]; then
    BUILD_ARGS+=(--nucleus-zip "$NUCLEUS_ZIP")
  fi
  "${ROOT_DIR}/tools/build-payload.sh" "${BUILD_ARGS[@]}" >/dev/null
  PAYLOAD_PATH="$TEMP_PAYLOAD"
fi
trap 'if [ -n "$TEMP_PAYLOAD" ]; then rm -f "$TEMP_PAYLOAD"; fi' EXIT

[ -f "$PAYLOAD_PATH" ] || { echo "payload not found: $PAYLOAD_PATH" >&2; exit 1; }

mkdir -p "${BOOT_DIR}/krgg"
cp "$PAYLOAD_PATH" "${BOOT_DIR}/krgg/payload.tgz"
cp "${ROOT_DIR}/inject/boot/firstrun.sh" "${BOOT_DIR}/krgg/firstrun.sh"
if [ "$ENABLE_UART_LOG" = "true" ]; then
  enable_uart_config
  write_uart_env
fi

if [ "$MODE" = "cmdline" ]; then
  CMDLINE="${BOOT_DIR}/cmdline.txt"
  [ -f "$CMDLINE" ] || { echo "cmdline.txt not found in boot partition: $CMDLINE" >&2; exit 1; }
  cp "$CMDLINE" "${CMDLINE}.pre-krgg"
  python3 - "$CMDLINE" "$RUN_PATH" "$ENABLE_UART_LOG" "$UART_BAUD" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
run_path = sys.argv[2]
uart_log = sys.argv[3] == "true"
uart_baud = sys.argv[4]
tokens = path.read_text().strip().split()
if not any(token.startswith("systemd.run=") and "krgg/firstrun.sh" in token for token in tokens):
    tokens.extend([
        f"systemd.run={run_path}",
        "systemd.run_success_action=reboot",
        "systemd.unit=kernel-command-line.target",
    ])
if uart_log and not any(token.startswith("console=serial0,") or token == "console=serial0" for token in tokens):
    tokens.append(f"console=serial0,{uart_baud}")
path.write_text(" ".join(tokens) + "\n")
PY
elif [ "$MODE" = "cloud-init" ]; then
  for name in user-data meta-data; do
    target="${BOOT_DIR}/${name}"
    if [ -e "$target" ] && [ "$FORCE_USER_DATA" != "true" ]; then
      echo "$target already exists. Re-run with --force-user-data to replace it, or use --mode cmdline." >&2
      exit 1
    fi
    if [ -e "$target" ]; then
      cp "$target" "${target}.pre-krgg"
    fi
    cp "${ROOT_DIR}/inject/boot/${name}" "$target"
  done
fi

sync
echo "Injected KRGG payload into $BOOT_DIR using mode=$MODE"
