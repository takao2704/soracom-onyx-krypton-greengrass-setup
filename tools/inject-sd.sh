#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT_DIR=""
MODE="cmdline"
PAYLOAD_PATH=""
NUCLEUS_ZIP=""
RUN_PATH="/boot/firmware/krgg/firstrun.sh"
FORCE_USER_DATA="false"

usage() {
  cat <<'EOF'
Usage:
  tools/inject-sd.sh --boot PATH [OPTIONS]

Inject KRGG first-boot provisioning files into a mounted Raspberry Pi boot partition.

Options:
  --boot PATH            Mounted boot partition path, e.g. /Volumes/bootfs.
  --payload PATH         Use an existing payload tarball.
  --nucleus-zip PATH     Include a Greengrass Nucleus zip when building payload.
  --mode MODE            Hook mode: cmdline or cloud-init. Default: cmdline.
  --run-path PATH        Runtime path for firstrun.sh in cmdline mode.
                         Default: /boot/firmware/krgg/firstrun.sh.
  --force-user-data      In cloud-init mode, replace existing user-data/meta-data.
  -h, --help             Show this help.

Notes:
  cmdline mode appends a one-shot systemd.run hook to cmdline.txt and preserves
  existing Raspberry Pi Imager user-data.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --boot)
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

[ -n "$BOOT_DIR" ] || { usage >&2; exit 2; }
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

if [ "$MODE" = "cmdline" ]; then
  CMDLINE="${BOOT_DIR}/cmdline.txt"
  [ -f "$CMDLINE" ] || { echo "cmdline.txt not found in boot partition: $CMDLINE" >&2; exit 1; }
  cp "$CMDLINE" "${CMDLINE}.pre-krgg"
  python3 - "$CMDLINE" "$RUN_PATH" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
run_path = sys.argv[2]
tokens = path.read_text().strip().split()
if not any(token.startswith("systemd.run=") and "krgg/firstrun.sh" in token for token in tokens):
    tokens.extend([
        f"systemd.run={run_path}",
        "systemd.run_success_action=reboot",
        "systemd.unit=kernel-command-line.target",
    ])
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
