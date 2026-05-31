#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_BIN="${DOCKER:-}"
RPI_IMAGE_GEN_REF="${RPI_IMAGE_GEN_REF:-v2.6.0}"
RPI_IMAGE_GEN_DIR="${RPI_IMAGE_GEN_DIR:-${ROOT_DIR}/.cache/rpi-image-gen}"
CONFIG_PATH="${ROOT_DIR}/image/rpi-image-gen/config/krgg-pi4-trixie.yaml"
SOURCE_DIR="${ROOT_DIR}/image/rpi-image-gen"
DOCKER_IMAGE="${RPI_IMAGE_GEN_DOCKER_IMAGE:-debian:trixie-slim}"
DIST_DIR="${ROOT_DIR}/dist/rpi-image-gen"
NUCLEUS_VERSION="${GREENGRASS_NUCLEUS_VERSION:-2.17.0}"
BUILD_MODE="${KRGG_RPI_IMAGE_GEN_MODE:-auto}"
SKIP_INSTALL_DEPS="false"

usage() {
  cat <<'EOF'
Usage:
  tools/build-rpi-image-gen.sh [OPTIONS]

Build a KRGG Raspberry Pi OS image with rpi-image-gen.

The default --mode auto uses Docker on macOS and native rpi-image-gen on
Linux/WSL.

Options:
  --config PATH             rpi-image-gen config YAML. Default: image/rpi-image-gen/config/krgg-pi4-trixie.yaml.
  --rpi-image-gen-dir PATH  Local rpi-image-gen checkout/cache directory. Default: .cache/rpi-image-gen.
  --ref REF                 rpi-image-gen git ref to clone. Default: v2.6.0.
  --mode auto|docker|native Execution mode. Default: auto.
  --docker-image IMAGE      Debian container image. Default: debian:trixie-slim.
  --nucleus-version VERSION Greengrass Nucleus version to bundle. Default: 2.17.0.
  --skip-install-deps       Skip rpi-image-gen dependency installation.
  -h, --help                Show this help.

Environment:
  DOCKER                    Docker CLI path or command name.
  RPI_IMAGE_GEN_REF         Default rpi-image-gen ref.
  RPI_IMAGE_GEN_DIR         Default rpi-image-gen checkout/cache directory.
  RPI_IMAGE_GEN_DOCKER_IMAGE
  GREENGRASS_NUCLEUS_VERSION
  KRGG_RPI_IMAGE_GEN_MODE   auto, docker, or native.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

normalize_existing_path() {
  local path="$1"
  local dir
  local base
  case "$path" in
    /*) ;;
    *) path="${PWD}/${path}" ;;
  esac
  dir="$(cd "$(dirname "$path")" && pwd)" || die "Directory not found: $(dirname "$path")"
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

normalize_new_path() {
  local path="$1"
  local dir
  local base
  case "$path" in
    /*) ;;
    *) path="${PWD}/${path}" ;;
  esac
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)" || die "Directory not found: $dir"
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

find_docker() {
  if [ -n "$DOCKER_BIN" ]; then
    command -v "$DOCKER_BIN" >/dev/null 2>&1 || [ -x "$DOCKER_BIN" ] || die "Docker not found: $DOCKER_BIN"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    DOCKER_BIN="docker"
    return
  fi

  for candidate in \
    "${HOME}/.docker/bin/docker" \
    "/Applications/Docker.app/Contents/Resources/bin/docker"; do
    if [ -x "$candidate" ]; then
      DOCKER_BIN="$candidate"
      return
    fi
  done

  die "Docker CLI not found. Start Docker Desktop or set DOCKER=/path/to/docker."
}

resolve_mode() {
  case "$BUILD_MODE" in
    auto)
      case "$(uname -s)" in
        Darwin) BUILD_MODE="docker" ;;
        Linux) BUILD_MODE="native" ;;
        *) die "Cannot auto-detect build mode for $(uname -s). Use --mode docker or --mode native." ;;
      esac
      ;;
    docker|native) ;;
    *) die "--mode must be auto, docker, or native" ;;
  esac
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi
  command -v sudo >/dev/null 2>&1 || die "sudo not found; dependency installation requires root. Re-run as root or use --skip-install-deps."
  sudo "$@"
}

clone_rpi_image_gen() {
  if [ ! -d "${RPI_IMAGE_GEN_DIR}/.git" ]; then
    mkdir -p "$(dirname "$RPI_IMAGE_GEN_DIR")"
    command -v git >/dev/null 2>&1 || die "git not found"
    git clone --depth 1 --branch "$RPI_IMAGE_GEN_REF" \
      https://github.com/raspberrypi/rpi-image-gen.git \
      "$RPI_IMAGE_GEN_DIR"
  fi
}

copy_artifacts() {
  mkdir -p "$DIST_DIR"
  shopt -s nullglob
  local copied="false"
  local file
  for file in "${RPI_IMAGE_GEN_DIR}"/work/deploy-*/* "${RPI_IMAGE_GEN_DIR}"/work/image-*/*; do
    [ -f "$file" ] || continue
    cp -av "$file" "$DIST_DIR/"
    copied="true"
  done
  [ "$copied" = "true" ] || die "No build artefacts found under ${RPI_IMAGE_GEN_DIR}/work"
  echo
  echo "Build artefacts copied to $DIST_DIR:"
  find "$DIST_DIR" -maxdepth 1 -type f -print | sort
}

install_native_deps() {
  [ "$SKIP_INSTALL_DEPS" = "false" ] || return
  command -v apt-get >/dev/null 2>&1 || die "Native mode requires Debian/Ubuntu/Raspberry Pi OS with apt-get. Use --mode docker on other hosts."

  case "$(uname -m)" in
    aarch64|arm*) ;;
    *)
      run_as_root apt-get update
      run_as_root apt-get install -y --no-install-recommends \
        binfmt-support \
        debian-archive-keyring \
        git \
        qemu-user-static
      ;;
  esac

  run_as_root "${RPI_IMAGE_GEN_DIR}/install_deps.sh"
}

build_native() {
  [ "$(uname -s)" = "Linux" ] || die "Native mode requires Linux. Use --mode docker on macOS."
  clone_rpi_image_gen
  install_native_deps
  (
    cd "$RPI_IMAGE_GEN_DIR"
    ./rpi-image-gen build \
      -S "$SOURCE_DIR" \
      -c "$CONFIG_PATH" \
      -- "IGconf_krgg_nucleus_version=${NUCLEUS_VERSION}"
  )
  copy_artifacts
}

build_docker() {
  find_docker
  "$DOCKER_BIN" info >/dev/null 2>&1 || die "Docker daemon is not reachable. Start Docker Desktop and retry."
  clone_rpi_image_gen
  mkdir -p "$DIST_DIR"

  local install_deps="true"
  if [ "$SKIP_INSTALL_DEPS" = "true" ]; then
    install_deps="false"
  fi

  CONFIG_REL="${CONFIG_PATH#"$ROOT_DIR"/}"
  PATH="$DOCKER_PATH" "$DOCKER_BIN" run --rm --privileged \
    -v "${RPI_IMAGE_GEN_DIR}:/work/rpi-image-gen" \
    -v "${ROOT_DIR}:/work/krgg" \
    -w /work/rpi-image-gen \
    -e DEBIAN_FRONTEND=noninteractive \
    -e KRGG_CONFIG_REL="$CONFIG_REL" \
    -e KRGG_INSTALL_DEPS="$install_deps" \
    -e KRGG_NUCLEUS_VERSION="$NUCLEUS_VERSION" \
    "$DOCKER_IMAGE" \
    bash -lc '
      set -Eeuo pipefail
      apt-get update
      apt-get install -y --no-install-recommends ca-certificates git
      if [ "$KRGG_INSTALL_DEPS" = "true" ]; then
        apt-get install -y --no-install-recommends binfmt-support debian-archive-keyring qemu-user-static
        ./install_deps.sh
      fi
      ./rpi-image-gen build \
        -S /work/krgg/image/rpi-image-gen \
        -c "/work/krgg/${KRGG_CONFIG_REL}" \
        -- "IGconf_krgg_nucleus_version=${KRGG_NUCLEUS_VERSION}"
      mkdir -p /work/krgg/dist/rpi-image-gen
      shopt -s nullglob
      copied=false
      for file in work/deploy-*/* work/image-*/*; do
        [ -f "$file" ] || continue
        cp -av "$file" /work/krgg/dist/rpi-image-gen/
        copied=true
      done
      [ "$copied" = "true" ] || { echo "No build artefacts found under /work/rpi-image-gen/work" >&2; exit 1; }
      echo
      echo "Build artefacts copied to /work/krgg/dist/rpi-image-gen:"
      find /work/krgg/dist/rpi-image-gen -maxdepth 1 -type f -print | sort
    '
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      [ -n "$CONFIG_PATH" ] || die "--config requires a path"
      shift 2
      ;;
    --rpi-image-gen-dir)
      RPI_IMAGE_GEN_DIR="${2:-}"
      [ -n "$RPI_IMAGE_GEN_DIR" ] || die "--rpi-image-gen-dir requires a path"
      shift 2
      ;;
    --ref)
      RPI_IMAGE_GEN_REF="${2:-}"
      [ -n "$RPI_IMAGE_GEN_REF" ] || die "--ref requires a value"
      shift 2
      ;;
    --mode)
      BUILD_MODE="${2:-}"
      [ -n "$BUILD_MODE" ] || die "--mode requires a value"
      shift 2
      ;;
    --docker-image)
      DOCKER_IMAGE="${2:-}"
      [ -n "$DOCKER_IMAGE" ] || die "--docker-image requires a value"
      shift 2
      ;;
    --nucleus-version)
      NUCLEUS_VERSION="${2:-}"
      [ -n "$NUCLEUS_VERSION" ] || die "--nucleus-version requires a value"
      shift 2
      ;;
    --skip-install-deps)
      SKIP_INSTALL_DEPS="true"
      shift
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

CONFIG_PATH="$(normalize_existing_path "$CONFIG_PATH")"
SOURCE_DIR="$(normalize_existing_path "$SOURCE_DIR")"
RPI_IMAGE_GEN_DIR="$(normalize_new_path "$RPI_IMAGE_GEN_DIR")"
DIST_DIR="$(normalize_new_path "$DIST_DIR")"

[ -f "$CONFIG_PATH" ] || die "Config not found: $CONFIG_PATH"
[ -d "$SOURCE_DIR" ] || die "Source directory not found: $SOURCE_DIR"
[[ "$NUCLEUS_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "--nucleus-version must look like 2.17.0"

case "$CONFIG_PATH" in
  "$ROOT_DIR"/*) ;;
  *) die "--config must point to a file inside this repository: $ROOT_DIR" ;;
esac

DOCKER_DIR=""
case "$DOCKER_BIN" in
  */*) DOCKER_DIR="$(dirname "$DOCKER_BIN")" ;;
esac
if [ -n "$DOCKER_DIR" ]; then
  DOCKER_PATH="${DOCKER_DIR}:${HOME}/.docker/bin:${PATH}"
else
  DOCKER_PATH="${HOME}/.docker/bin:${PATH}"
fi

resolve_mode
echo "Using rpi-image-gen mode: $BUILD_MODE"
case "$BUILD_MODE" in
  docker) build_docker ;;
  native) build_native ;;
esac
