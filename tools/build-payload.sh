#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_PATH="${ROOT_DIR}/dist/krgg-payload.tgz"
NUCLEUS_ZIP=""

usage() {
  cat <<'EOF'
Usage:
  tools/build-payload.sh [OPTIONS]

Options:
  --out PATH              Write payload tarball to PATH.
  --nucleus-zip PATH      Include a Greengrass Nucleus zip as /opt/krgg/greengrass-nucleus.zip.
  -h, --help              Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      OUT_PATH="${2:-}"
      [ -n "$OUT_PATH" ] || { echo "--out requires a path" >&2; exit 2; }
      shift 2
      ;;
    --nucleus-zip)
      NUCLEUS_ZIP="${2:-}"
      [ -n "$NUCLEUS_ZIP" ] || { echo "--nucleus-zip requires a path" >&2; exit 2; }
      shift 2
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

[ -f "${ROOT_DIR}/scripts/setup-raspi.sh" ] || {
  echo "setup script not found: ${ROOT_DIR}/scripts/setup-raspi.sh" >&2
  exit 1
}
if [ -n "$NUCLEUS_ZIP" ] && [ ! -f "$NUCLEUS_ZIP" ]; then
  echo "Greengrass Nucleus zip not found: $NUCLEUS_ZIP" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$(dirname "$OUT_PATH")"
cp -R "${ROOT_DIR}/inject/payload/." "$STAGING_DIR/"
mkdir -p "${STAGING_DIR}/opt/krgg"
install -m 755 "${ROOT_DIR}/scripts/setup-raspi.sh" "${STAGING_DIR}/opt/krgg/setup-raspi.sh"
chmod 755 "${STAGING_DIR}/opt/krgg/firstboot-provision.sh"
if [ -f "${STAGING_DIR}/opt/krgg/setup_eg25.sh" ]; then
  chmod 755 "${STAGING_DIR}/opt/krgg/setup_eg25.sh"
fi

if [ -n "$NUCLEUS_ZIP" ]; then
  install -m 644 "$NUCLEUS_ZIP" "${STAGING_DIR}/opt/krgg/greengrass-nucleus.zip"
fi

COPYFILE_DISABLE=1 tar -C "$STAGING_DIR" -czf "$OUT_PATH" .
echo "$OUT_PATH"
