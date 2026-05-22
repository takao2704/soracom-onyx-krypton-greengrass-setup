#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.1.0"
LOG_FILE="/var/log/soracom-krypton-greengrass-setup.log"
LOG_READY="false"

ENV_FILE=""
SORACOM_IFACE="${SORACOM_IFACE:-auto}"
CLI_SORACOM_IFACE=""
CLI_INSTALL_PACKAGES=""
FORCE_BOOTSTRAP="false"
SKIP_NETWORK="false"
SKIP_GREENGRASS="false"

usage() {
  cat <<'EOF'
Usage:
  sudo bash scripts/setup-raspi.sh [OPTIONS]

Options:
  --env PATH             Load environment variables from PATH.
  --interface IFACE      Use this network interface for Krypton bootstrap, e.g. wwan1.
  --force-bootstrap      Re-run Krypton bootstrap even if local certificate files exist.
  --skip-package-install Do not run apt; require base image prerequisites to exist.
  --skip-network         Skip NetworkManager/ModemManager setup.
  --skip-greengrass      Stop after Krypton certificate provisioning.
  -h, --help             Show this help.

Required environment variables:
  AWS_IOT_DATA_ENDPOINT
  AWS_IOT_CRED_ENDPOINT
  GREENGRASS_ROLE_ALIAS

Common optional environment variables:
  AWS_REGION                         default: ap-northeast-1
  SORACOM_APN                        default: soracom.io
  SORACOM_USERNAME                   default: sora
  SORACOM_PASSWORD                   default: sora
  SORACOM_IFACE                      default: auto
  KRGG_INSTALL_PACKAGES              default: true
  KRYPTON_THING_NAME                 default: use Soracom Krypton thingNamePattern
  KRYPTON_CERT_DIR                   default: /opt/soracom-krypton/aws-iot
  GREENGRASS_ROOT                    default: /greengrass/v2
  GREENGRASS_NUCLEUS_ZIP_URL         default: latest public AWS Nucleus zip
EOF
}

log() {
  local message
  message="$(printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")"
  if [ "$LOG_READY" = "true" ]; then
    printf '%s\n' "$message" | tee -a "$LOG_FILE"
  else
    printf '%s\n' "$message"
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

run() {
  log "RUN: $*"
  "$@" >>"$LOG_FILE" 2>&1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)
      ENV_FILE="${2:-}"
      [ -n "$ENV_FILE" ] || die "--env requires a path"
      shift 2
      ;;
    --interface)
      CLI_SORACOM_IFACE="${2:-}"
      [ -n "$CLI_SORACOM_IFACE" ] || die "--interface requires a value"
      shift 2
      ;;
    --force-bootstrap)
      FORCE_BOOTSTRAP="true"
      shift
      ;;
    --skip-package-install)
      CLI_INSTALL_PACKAGES="false"
      shift
      ;;
    --skip-network)
      SKIP_NETWORK="true"
      shift
      ;;
    --skip-greengrass)
      SKIP_GREENGRASS="true"
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

if [ "$(id -u)" -ne 0 ]; then
  die "Run as root: sudo bash scripts/setup-raspi.sh"
fi

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
LOG_READY="true"

if [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || die "Env file not found: $ENV_FILE"
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
fi

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
SORACOM_APN="${SORACOM_APN:-soracom.io}"
SORACOM_USERNAME="${SORACOM_USERNAME:-sora}"
SORACOM_PASSWORD="${SORACOM_PASSWORD:-sora}"
SORACOM_IFACE="${SORACOM_IFACE:-auto}"
if [ -n "$CLI_SORACOM_IFACE" ]; then
  SORACOM_IFACE="$CLI_SORACOM_IFACE"
fi
KRGG_INSTALL_PACKAGES="${KRGG_INSTALL_PACKAGES:-true}"
if [ -n "$CLI_INSTALL_PACKAGES" ]; then
  KRGG_INSTALL_PACKAGES="$CLI_INSTALL_PACKAGES"
fi
KRYPTON_ENDPOINT="${KRYPTON_ENDPOINT:-https://krypton.soracom.io:8036/v1/provisioning/aws/iot/bootstrap}"
KRYPTON_THING_NAME="${KRYPTON_THING_NAME:-}"
KRYPTON_CERT_DIR="${KRYPTON_CERT_DIR:-/opt/soracom-krypton/aws-iot}"
GREENGRASS_ROOT="${GREENGRASS_ROOT:-/greengrass/v2}"
GREENGRASS_NUCLEUS_ZIP_URL="${GREENGRASS_NUCLEUS_ZIP_URL:-https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip}"
GREENGRASS_DEFAULT_USER="${GREENGRASS_DEFAULT_USER:-ggc_user:ggc_group}"

[ -n "${AWS_IOT_DATA_ENDPOINT:-}" ] || die "AWS_IOT_DATA_ENDPOINT is required"
[ -n "${AWS_IOT_CRED_ENDPOINT:-}" ] || die "AWS_IOT_CRED_ENDPOINT is required"
[ -n "${GREENGRASS_ROLE_ALIAS:-}" ] || die "GREENGRASS_ROLE_ALIAS is required"
case "$KRGG_INSTALL_PACKAGES" in
  true|false) ;;
  *) die "KRGG_INSTALL_PACKAGES must be true or false" ;;
esac
if [ -n "$KRYPTON_THING_NAME" ]; then
  [ "${#KRYPTON_THING_NAME}" -le 128 ] || die "KRYPTON_THING_NAME must be 128 characters or fewer"
  case "$KRYPTON_THING_NAME" in
    *[!A-Za-z0-9:_-]*)
      die "KRYPTON_THING_NAME may contain only letters, digits, colon, underscore, and hyphen"
      ;;
  esac
fi

log "soracom-onyx-krypton-greengrass setup version ${SCRIPT_VERSION}"

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  local packages=(
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
  log "Installing packages"
  run apt-get update
  run apt-get install -y "${packages[@]}"
}

check_prerequisites() {
  local required_commands=(
    curl
    ip
    python3
    systemctl
  )

  if [ "$SKIP_NETWORK" != "true" ]; then
    required_commands+=(
      lsusb
      mmcli
      nmcli
      usb_modeswitch
    )
  fi

  if [ "$SKIP_GREENGRASS" != "true" ]; then
    required_commands+=(
      java
      unzip
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
    die "Missing base image prerequisites: ${missing[*]}. Run tools/prepare-base-image.sh before imaging, or allow package installation."
  fi
}

ensure_services() {
  log "Enabling NetworkManager and ModemManager"
  run systemctl enable NetworkManager
  run systemctl enable ModemManager
  run systemctl start NetworkManager
  run systemctl start ModemManager
}

get_wwan_interfaces() {
  find /sys/class/net -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | grep -E '^(wwan[0-9]+|.*wwp.*)$' | sort || true
}

get_nmcli_gsm_devices() {
  nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2 == "gsm" {print $1}' | sort || true
}

setup_soracom_routes() {
  log "Installing NetworkManager dispatcher route script"
  install -d -m 755 /etc/NetworkManager/dispatcher.d
  cat > /etc/NetworkManager/dispatcher.d/90-soracom-krypton-route <<'ROUTE_SCRIPT'
#!/usr/bin/env bash
set -u

add_routes() {
  local iface="$1"
  local gateway="$2"
  if [ -n "$gateway" ]; then
    /sbin/ip route replace 100.127.0.0/16 via "$gateway" dev "$iface" metric 0
    /sbin/ip route replace 54.250.252.67/32 via "$gateway" dev "$iface" metric 0
    /sbin/ip route replace 54.250.252.99/32 via "$gateway" dev "$iface" metric 0
  else
    /sbin/ip route replace 100.127.0.0/16 dev "$iface" metric 0
    /sbin/ip route replace 54.250.252.67/32 dev "$iface" metric 0
    /sbin/ip route replace 54.250.252.99/32 dev "$iface" metric 0
  fi
  logger -t soracom-krypton-route "Added SORACOM service routes for $iface"
}

remove_routes() {
  local iface="$1"
  local gateway="${2:-}"
  /sbin/ip route del 100.127.0.0/16 dev "$iface" 2>/dev/null || true
  /sbin/ip route del 54.250.252.67/32 dev "$iface" 2>/dev/null || true
  /sbin/ip route del 54.250.252.99/32 dev "$iface" 2>/dev/null || true
  if [ -n "$gateway" ]; then
    /sbin/ip route del 100.127.0.0/16 via "$gateway" dev "$iface" 2>/dev/null || true
    /sbin/ip route del 54.250.252.67/32 via "$gateway" dev "$iface" 2>/dev/null || true
    /sbin/ip route del 54.250.252.99/32 via "$gateway" dev "$iface" 2>/dev/null || true
  fi
  logger -t soracom-krypton-route "Removed SORACOM service routes for $iface"
}

iface="${1:-}"
state="${2:-}"

case "$iface" in
  ppp0|wwan[0-9]*|*wwp*)
    gateway="$(/sbin/ip route show default dev "$iface" | awk 'NR==1 {print $3}')"
    if [ "$state" = "up" ]; then
      add_routes "$iface" "$gateway"
    elif [ "$state" = "down" ]; then
      remove_routes "$iface" "$gateway"
    fi
    ;;
esac
ROUTE_SCRIPT
  chmod 755 /etc/NetworkManager/dispatcher.d/90-soracom-krypton-route
}

configure_network_profiles() {
  log "Waiting for Onyx/EG25 modem to appear"
  local found="false"
  for _ in $(seq 1 30); do
    if lsusb | grep -Eq '2c7c|QUECTEL' || mmcli -L 2>/dev/null | grep -Eq 'QUECTEL|EG25'; then
      found="true"
      break
    fi
    sleep 2
  done
  [ "$found" = "true" ] || die "No Soracom Onyx/EG25 modem detected"

  setup_soracom_routes

  local gsm_devices
  gsm_devices="$(get_nmcli_gsm_devices)"
  [ -n "$gsm_devices" ] || die "NetworkManager did not expose any GSM devices"

  for device in $gsm_devices; do
    local con_name="soracom-${device}"
    if nmcli con show "$con_name" >/dev/null 2>&1; then
      log "NetworkManager connection already exists: $con_name"
      nmcli con mod "$con_name" gsm.apn "$SORACOM_APN" gsm.username "$SORACOM_USERNAME" gsm.password "$SORACOM_PASSWORD" >>"$LOG_FILE" 2>&1 || true
    else
      log "Creating NetworkManager connection: $con_name"
      run nmcli con add type gsm ifname "$device" con-name "$con_name" apn "$SORACOM_APN" user "$SORACOM_USERNAME" password "$SORACOM_PASSWORD"
    fi
  done

  for iface in $(get_wwan_interfaces); do
    if [ -e "/sys/class/net/${iface}/qmi/raw_ip" ]; then
      log "Setting raw_ip=Y for $iface"
      ip link set "$iface" down >>"$LOG_FILE" 2>&1 || true
      printf 'Y' > "/sys/class/net/${iface}/qmi/raw_ip" || true
      ip link set "$iface" up >>"$LOG_FILE" 2>&1 || true
    fi
  done

  for device in $gsm_devices; do
    local con_name="soracom-${device}"
    log "Bringing up $con_name on $device"
    nmcli con up "$con_name" ifname "$device" >>"$LOG_FILE" 2>&1 || log "Failed to bring up $con_name; continuing"
  done
}

candidate_interfaces() {
  if [ "$SORACOM_IFACE" != "auto" ]; then
    printf '%s\n' "$SORACOM_IFACE"
    return
  fi
  get_wwan_interfaces
}

save_krypton_response() {
  local response_path="$1"
  KRYPTON_RESPONSE_PATH="$response_path" KRYPTON_CERT_DIR="$KRYPTON_CERT_DIR" python3 - <<'PY'
import json
import os
from pathlib import Path

base = Path(os.environ["KRYPTON_CERT_DIR"])
data = json.loads(Path(os.environ["KRYPTON_RESPONSE_PATH"]).read_text())
base.mkdir(parents=True, exist_ok=True)

def first(*names):
    for name in names:
        value = data.get(name)
        if isinstance(value, str) and value.strip():
            return value
    return None

private_key = first("privateKey", "private_key", "key", "thingPrivateKey")
certificate = first("certificate", "cert", "thingCertificate")
root_ca = first("rootCaCertificate", "caCertificate", "rootCACertificate", "rootCaCert")

missing = [name for name, value in (
    ("privateKey", private_key),
    ("certificate", certificate),
    ("rootCaCertificate", root_ca),
) if not value]
if missing:
    raise SystemExit("missing expected fields: " + ", ".join(missing) + "; keys=" + ",".join(sorted(data.keys())))

files = {
    "private.pem.key": (private_key, 0o600),
    "certificate.pem.crt": (certificate, 0o644),
    "AmazonRootCA1.pem": (root_ca, 0o644),
}
for name, (content, mode) in files.items():
    path = base / name
    path.write_text(content if content.endswith("\n") else content + "\n")
    os.chmod(path, mode)

client_id = data.get("clientId") or data.get("thingName")
config = {
    "region": data.get("region"),
    "host": data.get("host"),
    "endpoint": data.get("host"),
    "port": data.get("port", 8883),
    "thingName": data.get("thingName") or client_id,
    "clientId": client_id,
    "certificateId": data.get("certificateId") or data.get("certId"),
    "paths": {
        "privateKey": str(base / "private.pem.key"),
        "certificate": str(base / "certificate.pem.crt"),
        "rootCaCertificate": str(base / "AmazonRootCA1.pem"),
    },
}
(base / "config.json").write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
os.chmod(base / "config.json", 0o600)

print(json.dumps({
    "thingName": config["thingName"],
    "clientId": config["clientId"],
    "certificateId": config["certificateId"],
    "host": config["host"],
}, sort_keys=True))
PY
}

write_krypton_request_body() {
  local request_path="$1"
  KRYPTON_THING_NAME="$KRYPTON_THING_NAME" python3 - "$request_path" <<'PY'
import json
import os
import sys

body = {"requestParameters": {"thingName": os.environ["KRYPTON_THING_NAME"]}}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(body, f, separators=(",", ":"))
PY
}

krypton_cert_exists() {
  [ -s "$KRYPTON_CERT_DIR/private.pem.key" ] &&
  [ -s "$KRYPTON_CERT_DIR/certificate.pem.crt" ] &&
  [ -s "$KRYPTON_CERT_DIR/AmazonRootCA1.pem" ] &&
  [ -s "$KRYPTON_CERT_DIR/config.json" ]
}

bootstrap_krypton() {
  if krypton_cert_exists && [ "$FORCE_BOOTSTRAP" != "true" ]; then
    log "Krypton certificate files already exist under $KRYPTON_CERT_DIR; skipping bootstrap"
    return
  fi

  install -d -m 700 "$KRYPTON_CERT_DIR"

  local candidates
  candidates="$(candidate_interfaces)"
  [ -n "$candidates" ] || die "No candidate cellular interface found. Use --interface IFACE."

  local tmp
  tmp="$(mktemp)"
  local request_body
  request_body="$(mktemp)"
  local body_args=()
  if [ -n "$KRYPTON_THING_NAME" ]; then
    write_krypton_request_body "$request_body"
    body_args=(--data-binary "@$request_body")
    log "Using explicit Krypton thingName: $KRYPTON_THING_NAME"
  fi
  local last_error=""
  for iface in $candidates; do
    log "Trying Krypton bootstrap through $iface"
    local http_code
    http_code="$(
      curl --interface "$iface" \
        --connect-timeout 10 \
        --max-time 60 \
        -sS \
        -o "$tmp" \
        -w "%{http_code}" \
        -X POST \
        -H "content-type: application/json" \
        "${body_args[@]}" \
        "$KRYPTON_ENDPOINT" || true
    )"
    if [ "$http_code" = "200" ]; then
      local summary
      summary="$(save_krypton_response "$tmp")"
      log "Krypton bootstrap succeeded via $iface: $summary"
      rm -f "$tmp" "$request_body"
      return
    fi
    last_error="$(head -c 500 "$tmp" 2>/dev/null || true)"
    log "Krypton bootstrap failed via $iface: http_status=$http_code response=${last_error}"
  done
  rm -f "$tmp" "$request_body"
  die "Krypton bootstrap failed for all candidate interfaces. Last response: $last_error"
}

config_value() {
  local key="$1"
  KRYPTON_CERT_DIR="$KRYPTON_CERT_DIR" CONFIG_KEY="$key" python3 - <<'PY'
import json
import os
from pathlib import Path
cfg = json.loads((Path(os.environ["KRYPTON_CERT_DIR"]) / "config.json").read_text())
value = cfg.get(os.environ["CONFIG_KEY"]) or ""
print(value)
PY
}

install_greengrass() {
  local thing_name
  thing_name="$(config_value thingName)"
  [ -n "$thing_name" ] || die "thingName missing in $KRYPTON_CERT_DIR/config.json"

  if systemctl is-active --quiet greengrass; then
    log "greengrass.service is already active; skipping Greengrass install"
    return
  fi

  log "Installing Greengrass with thingName=$thing_name"
  install -d -m 755 "$(dirname "$GREENGRASS_ROOT")"
  install -d -m 700 "$GREENGRASS_ROOT"
  install -o root -g root -m 644 "$KRYPTON_CERT_DIR/certificate.pem.crt" "$GREENGRASS_ROOT/device.pem.crt"
  install -o root -g root -m 600 "$KRYPTON_CERT_DIR/private.pem.key" "$GREENGRASS_ROOT/private.pem.key"
  install -o root -g root -m 644 "$KRYPTON_CERT_DIR/AmazonRootCA1.pem" "$GREENGRASS_ROOT/AmazonRootCA1.pem"

  local installer_dir
  installer_dir="$(mktemp -d)"
  local zip_path="${installer_dir}/greengrass-nucleus.zip"
  log "Downloading Greengrass Nucleus from $GREENGRASS_NUCLEUS_ZIP_URL"
  run curl -fsSL "$GREENGRASS_NUCLEUS_ZIP_URL" -o "$zip_path"
  run unzip -q "$zip_path" -d "$installer_dir"

  local raw_version
  raw_version="$(java -jar "$installer_dir/lib/Greengrass.jar" --version | awk '{print $NF}')"
  local nucleus_version="${raw_version#v}"
  [ -n "$nucleus_version" ] || die "Failed to detect Greengrass Nucleus version"
  log "Greengrass Nucleus version: $nucleus_version"

  cat > "$installer_dir/config.yaml" <<YAML
---
system:
  certificateFilePath: "$GREENGRASS_ROOT/device.pem.crt"
  privateKeyPath: "$GREENGRASS_ROOT/private.pem.key"
  rootCaPath: "$GREENGRASS_ROOT/AmazonRootCA1.pem"
  rootpath: "$GREENGRASS_ROOT"
  thingName: "$thing_name"
services:
  aws.greengrass.Nucleus:
    componentType: "NUCLEUS"
    version: "$nucleus_version"
    configuration:
      awsRegion: "$AWS_REGION"
      iotRoleAlias: "$GREENGRASS_ROLE_ALIAS"
      iotDataEndpoint: "$AWS_IOT_DATA_ENDPOINT"
      iotCredEndpoint: "$AWS_IOT_CRED_ENDPOINT"
YAML
  chmod 600 "$installer_dir/config.yaml"

  java -Droot="$GREENGRASS_ROOT" -Dlog.store=FILE \
    -jar "$installer_dir/lib/Greengrass.jar" \
    --init-config "$installer_dir/config.yaml" \
    --component-default-user "$GREENGRASS_DEFAULT_USER" \
    --setup-system-service true | tee -a "$LOG_FILE"
}

verify_installation() {
  log "Verifying local installation"
  local active_state
  local enabled_state
  active_state="$(systemctl is-active greengrass || true)"
  enabled_state="$(systemctl is-enabled greengrass || true)"
  printf '%s\n' "$active_state" | tee -a "$LOG_FILE"
  printf '%s\n' "$enabled_state" | tee -a "$LOG_FILE"
  if [ -f "$GREENGRASS_ROOT/logs/greengrass.log" ]; then
    tail -n 80 "$GREENGRASS_ROOT/logs/greengrass.log" | tee -a "$LOG_FILE" || true
  fi
  [ "$active_state" = "active" ] || die "greengrass.service is not active: $active_state"
  [ "$enabled_state" = "enabled" ] || die "greengrass.service is not enabled: $enabled_state"
}

main() {
  if [ "$KRGG_INSTALL_PACKAGES" != "true" ]; then
    log "Skipping package installation; validating base image prerequisites"
    check_prerequisites
  fi

  if [ "$SKIP_NETWORK" != "true" ]; then
    if [ "$KRGG_INSTALL_PACKAGES" = "true" ]; then
      install_packages
    fi
    ensure_services
    configure_network_profiles
  else
    log "Skipping network setup"
  fi

  bootstrap_krypton

  if [ "$SKIP_GREENGRASS" != "true" ]; then
    install_greengrass
    verify_installation
  else
    log "Skipping Greengrass install"
  fi

  log "Setup finished"
}

main "$@"
