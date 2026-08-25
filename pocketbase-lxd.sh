#!/usr/bin/env bash
#
# Self-contained PocketBase installer for LXD containers.
#
# This is an independent LXD adaptation informed by the Community Scripts
# PocketBase installer. The upstream project is MIT-licensed:
# https://github.com/community-scripts/ProxmoxVE/blob/main/LICENSE
# Source reference:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/pocketbase.sh
#
# Host usage:
#   ./pocketbase-lxd.sh --create
#   LXD_CONTAINER=pocketbase ./pocketbase-lxd.sh --update-container
#
# Guest usage:
#   lxc exec pocketbase -- bash -s -- --install < pocketbase-lxd.sh
#   lxc exec pocketbase -- bash -s -- --update  < pocketbase-lxd.sh
#   lxc exec pocketbase -- bash -s -- --status  < pocketbase-lxd.sh

set -Eeuo pipefail

readonly INSTALL_DIR="/opt/pocketbase"
readonly DATA_DIR="${INSTALL_DIR}/pb_data"
readonly SYSTEMD_UNIT="/etc/systemd/system/pocketbase.service"
readonly SERVICE_NAME="pocketbase"
readonly VERSION_FILE="${INSTALL_DIR}/.version"
readonly POCKETBASE_REPO="pocketbase/pocketbase"

log() {
  printf '[pocketbase] %s\n' "$*"
}

warn() {
  printf '[pocketbase] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[pocketbase] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die 'This operation must run as root inside the container.'
}

usage() {
  cat <<'EOF'
PocketBase LXD installer

Host operations:
  --create                    Launch/start an LXD container and install PocketBase.
  --update-container          Update PocketBase inside an existing LXD container.

Guest operations:
  --install                   Install PocketBase in the current Debian/Ubuntu or Alpine guest.
  --update                    Update PocketBase to the latest (or pinned) release preserving data.
  --status                    Show the service status and installation information.
  --help                      Show this help.

Host environment variables:
  LXD_CONTAINER=pocketbase    Existing or new container name.
  LXD_IMAGE=images:ubuntu/26.04  LXD image to launch with --create only.
  LXD_PROXY=false             Set true/1 to add an LXD proxy device with --create only.
  LXD_PROXY_LISTEN=0.0.0.0   Host address used by the proxy device.
  LXD_PROXY_PORT=8080         Host port used by the proxy device.
  LXD_PROXY_DEVICE=pocketbase-proxy
                              Name of the proxy device.

Guest/application environment variables:
  POCKETBASE_PORT=8080        Listening port for PocketBase (--http flag).
  POCKETBASE_VERSION=         Optional release tag (e.g. v0.40.1), otherwise latest.

Examples:
  LXD_CONTAINER=pocketbase LXD_PROXY=true ./pocketbase-lxd.sh --create
  LXD_CONTAINER=pocketbase ./pocketbase-lxd.sh --update-container
  POCKETBASE_VERSION=v0.40.1 \
    LXD_CONTAINER=pocketbase ./pocketbase-lxd.sh --update-container
  lxc exec pocketbase -- bash -s -- --install < pocketbase-lxd.sh
  lxc exec pocketbase -- bash -s -- --update  < pocketbase-lxd.sh
EOF
}

# --- Validation helpers ---

validate_port() {
  local value=$1 label=${2:-port}
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || die "Invalid ${label}: ${value}"
  (( 10#${value} >= 1 && 10#${value} <= 65535 )) || die "Invalid ${label}: ${value}"
}

validate_release_tag() {
  local value=$1 label=$2
  [[ "$value" =~ ^v?[0-9][0-9A-Za-z._-]*$ ]] || die "Invalid ${label} release tag: ${value}"
}

normalize_boolean() {
  local value=${1,,}
  case "$value" in
    true|yes|1|on) printf 'true\n' ;;
    false|no|0|off) printf 'false\n' ;;
    *) die "Expected a boolean value, got: ${1}" ;;
  esac
}

# --- Release resolution ---

latest_github_tag() {
  local repository=$1 location tag
  require_command curl
  location="$(curl --fail --silent --show-error --location --head --retry 3 \
    --proto '=https' --tlsv1.2 --output /dev/null --write-out '%{url_effective}' \
    "https://github.com/${repository}/releases/latest")" \
    || die "Unable to resolve the latest release for ${repository}."
  location="${location%%\?*}"
  tag="${location##*/}"
  [[ -n "$tag" && "$tag" != "$location" ]] || die "Could not determine the latest release tag for ${repository}."
  printf '%s\n' "$tag"
}

resolve_release_tag() {
  local requested=$1 repository=$2 label=$3 tag
  if [[ -n "$requested" ]]; then
    tag=$requested
  else
    tag="$(latest_github_tag "$repository")"
  fi
  validate_release_tag "$tag" "$label"
  printf '%s\n' "$tag"
}

# --- Architecture resolution ---

resolve_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) die "Unsupported architecture: ${arch}" ;;
  esac
}

# --- Download and deploy ---

download_pocketbase() {
  local tag=$1 arch=$2 tmp_dir version_number zip_name zip_path
  tmp_dir="$(mktemp -d /var/tmp/pocketbase-dl.XXXXXX)"
  chmod 0700 "$tmp_dir"

  # Strip leading v for the asset name
  version_number="${tag#v}"
  zip_name="pocketbase_${version_number}_linux_${arch}.zip"
  zip_path="${tmp_dir}/${zip_name}"

  log "Downloading PocketBase ${tag} for ${arch}."
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output "$zip_path" \
    "https://github.com/${POCKETBASE_REPO}/releases/download/${tag}/${zip_name}" \
    || {
      rm -rf "$tmp_dir"
      die "Unable to download PocketBase ${tag} (${zip_name})."
    }

  log "Extracting PocketBase binary."
  unzip -oq "$zip_path" pocketbase -d "$tmp_dir" \
    || {
      rm -rf "$tmp_dir"
      die 'Unable to extract the PocketBase binary from the zip archive.'
    }

  [[ -f "${tmp_dir}/pocketbase" ]] || {
    rm -rf "$tmp_dir"
    die 'The downloaded archive does not contain the pocketbase binary.'
  }

  printf '%s\n' "$tmp_dir"
}

deploy_binary() {
  local tmp_dir=$1 tag=$2
  local binary_tmp="${INSTALL_DIR}/.pocketbase.new.$$"

  install -m 0755 "${tmp_dir}/pocketbase" "$binary_tmp"
  chown root:root "$binary_tmp"
  mv -f "$binary_tmp" "${INSTALL_DIR}/pocketbase"
  rm -rf "$tmp_dir"

  printf '%s\n' "$tag" > "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE"
  chown root:root "$VERSION_FILE"
}

# --- Service management ---

write_systemd_unit() {
  local port=$1
  if [[ -e "$SYSTEMD_UNIT" ]]; then
    return 0
  fi
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=PocketBase
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=4096
Restart=always
RestartSec=5s
StandardOutput=append:${INSTALL_DIR}/errors.log
StandardError=append:${INSTALL_DIR}/errors.log
ExecStart=${INSTALL_DIR}/pocketbase serve --http=0.0.0.0:${port}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SYSTEMD_UNIT"
}

update_systemd_port() {
  local port=$1
  if [[ -f "$SYSTEMD_UNIT" ]]; then
    if grep -q -- '--http=' "$SYSTEMD_UNIT"; then
      sed -i "s|--http=[^ ]*|--http=0.0.0.0:${port}|" "$SYSTEMD_UNIT"
    fi
  fi
}

start_systemd_service() {
  require_command systemctl
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    die 'PocketBase systemd service is not active.'
  fi
}

# --- Guest install ---

install_guest() {
  local mode=$1 port tag arch tmp_dir
  require_root

  port=${POCKETBASE_PORT:-8080}
  validate_port "$port" POCKETBASE_PORT

  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    log 'Installing runtime dependencies (Debian/Ubuntu).'
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl unzip
  elif command -v apk >/dev/null 2>&1; then
    log 'Installing runtime dependencies (Alpine).'
    apk add --no-cache bash ca-certificates curl unzip
  else
    die 'Unsupported guest OS. Only Debian/Ubuntu and Alpine are supported.'
  fi

  install -d -m 0755 "$INSTALL_DIR"
  mkdir -p "${INSTALL_DIR}/pb_public" "${INSTALL_DIR}/pb_migrations" "${INSTALL_DIR}/pb_hooks"
  mkdir -p "$DATA_DIR"

  tag="$(resolve_release_tag "${POCKETBASE_VERSION:-}" "$POCKETBASE_REPO" PocketBase)"
  arch="$(resolve_arch)"

  if [[ "$mode" == update ]]; then
    if [[ -r "$VERSION_FILE" ]]; then
      local current
      current="$(cat "$VERSION_FILE")"
      if [[ "$current" == "$tag" ]]; then
        log "PocketBase is already at ${tag}; nothing to do."
        start_systemd_service
        return 0
      fi
    fi
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fi

  tmp_dir="$(download_pocketbase "$tag" "$arch")"
  deploy_binary "$tmp_dir" "$tag"

  if [[ "$mode" == update ]]; then
    update_systemd_port "$port"
  else
    write_systemd_unit "$port"
  fi

  start_systemd_service
  log "PocketBase ${tag} is installed and running on port ${port}."
  log "Admin UI: http://<container-ip>:${port}/_/"
}

# --- Guest status ---

status_guest() {
  printf 'Installation directory: %s\n' "$INSTALL_DIR"
  if [[ -r "$VERSION_FILE" ]]; then
    printf 'Installed version: %s\n' "$(cat "$VERSION_FILE")"
  else
    printf 'Installed version: unknown\n'
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$SERVICE_NAME" status || true
  fi
}

# --- LXD host helpers ---

host_container_exists() {
  local name=$1
  lxc info "$name" >/dev/null 2>&1
}

host_container_state() {
  local name=$1
  lxc list "$name" --format csv -c s 2>/dev/null | tr -d '\r\n'
}

validate_lxd_container_name() {
  local name=$1
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Invalid LXD_CONTAINER: ${name}"
}

host_wait_for_exec() {
  local name=$1 attempt
  for attempt in {1..30}; do
    if lxc exec "$name" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "LXD container ${name} did not become ready for lxc exec."
}

host_wait_for_ip() {
  local name=$1 attempt ip=""
  for attempt in {1..30}; do
    ip="$(lxc list "$name" --format csv -c 4 2>/dev/null | \
      tr ',' '\n' | awk '/^[0-9]+\./ { print; exit }')" || true
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
    sleep 2
  done
  warn "Container ${name} did not receive an IPv4 address within 60 seconds."
  return 1
}

host_set_static_ip() {
  local name=$1 ip gateway subnet cidr nic
  local static="${LXD_STATIC_IP:-true}"
  static="$(normalize_boolean "$static")"
  [[ "$static" == true ]] || return 0

  ip="$(host_wait_for_ip "$name")" || return 0

  nic="$(lxc config device show "$name" 2>/dev/null | awk '/^[a-z].*:$/ {name=substr($1,1,length($1)-1)} /nictype:|network:/ {print name; exit}')" || true
  [[ -n "$nic" ]] || nic="eth0"

  local network
  network="$(lxc config device get "$name" "$nic" network 2>/dev/null)" || true
  if [[ -n "$network" ]]; then
    cidr="$(lxc network get "$network" ipv4.address 2>/dev/null)" || true
    if [[ -n "$cidr" && "$cidr" == */* ]]; then
      gateway="${cidr%%/*}"
      subnet="${cidr##*/}"
    fi
  fi

  if [[ -z "${gateway:-}" ]]; then
    gateway="$(lxc exec "$name" -- ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')" || true
  fi
  if [[ -z "${subnet:-}" ]]; then
    subnet="$(lxc exec "$name" -- ip -4 addr show 2>/dev/null | awk -v ip="$ip" '$0 ~ ip {split($2,a,"/"); print a[2]; exit}')" || true
  fi
  [[ -n "${subnet:-}" ]] || subnet="24"

  lxc config device override "$name" "$nic" \
    ipv4.address="${ip}" 2>/dev/null \
    && log "Static IP set: ${ip}/${subnet} (device: ${nic})" \
    || host_set_static_ip_guest "$name" "$ip" "$subnet" "${gateway:-}"
}

host_set_static_ip_guest() {
  local name=$1 ip=$2 subnet=$3 gateway=$4
  if lxc exec "$name" -- test -d /etc/netplan 2>/dev/null; then
    lxc exec "$name" -- bash -c "
      cat > /etc/netplan/50-static.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - ${ip}/${subnet}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
NETPLAN
      chmod 0600 /etc/netplan/50-static.yaml
      rm -f /etc/netplan/10-lxc.yaml 2>/dev/null
      netplan apply 2>/dev/null
    " && log "Static IP configured via netplan: ${ip}/${subnet} gw ${gateway}" \
      || warn "Failed to apply static IP via netplan."
  elif lxc exec "$name" -- test -f /etc/network/interfaces 2>/dev/null; then
    lxc exec "$name" -- bash -c "
      cat > /etc/network/interfaces <<IFACES
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${ip}/${subnet}
    gateway ${gateway}
    dns-nameservers 1.1.1.1 8.8.8.8
IFACES
      ifdown eth0 2>/dev/null; ifup eth0 2>/dev/null
    " && log "Static IP configured via interfaces: ${ip}/${subnet} gw ${gateway}" \
      || warn "Failed to apply static IP via interfaces file."
  else
    warn "Could not determine network configuration method for static IP."
  fi
}

host_start_existing_container() {
  local name=$1 state
  host_container_exists "$name" \
    || die "LXD container ${name} does not exist. Run --create first."
  state="$(host_container_state "$name")"
  case "$state" in
    RUNNING)
      log "Using running LXD container ${name}."
      ;;
    STOPPED)
      log "Starting existing LXD container ${name}."
      lxc start "$name"
      ;;
    *)
      die "LXD container ${name} is in state ${state:-unknown}; start or unfreeze it before continuing."
      ;;
  esac
  host_wait_for_exec "$name"
}

host_configure_proxy() {
  local name=$1 listen=$2 proxy_port=$3 device=$4 guest_port=$5
  local listen_spec="tcp:${listen}:${proxy_port}"
  local connect_spec="tcp:127.0.0.1:${guest_port}"
  validate_port "$proxy_port" LXD_PROXY_PORT
  [[ "$device" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || die "Invalid LXD_PROXY_DEVICE: ${device}"
  [[ "$listen" =~ ^[A-Za-z0-9_.:\[\]-]+$ ]] \
    || die "Invalid LXD_PROXY_LISTEN: ${listen}"

  if lxc config device show "$name" 2>/dev/null | \
    grep -qE "^[[:space:]]*${device}:"; then
    lxc config device set "$name" "$device" listen "$listen_spec"
    lxc config device set "$name" "$device" connect "$connect_spec"
  else
    lxc config device add "$name" "$device" proxy \
      listen="$listen_spec" connect="$connect_spec"
  fi
  log "LXD proxy device ${device} listens on ${listen}:${proxy_port}."
}

host_run_guest_action() {
  local name=$1 action=$2 script_path
  local -a guest_env
  case "$action" in
    --install|--update) ;;
    *) die "Unsupported guest action: ${action}" ;;
  esac

  script_path=${BASH_SOURCE[0]}
  [[ -r "$script_path" ]] || die "The script source is not readable: ${script_path}"
  guest_env=(env)
  if [[ -v POCKETBASE_PORT ]]; then
    guest_env+=("POCKETBASE_PORT=${POCKETBASE_PORT}")
  fi
  if [[ -v POCKETBASE_VERSION ]]; then
    guest_env+=("POCKETBASE_VERSION=${POCKETBASE_VERSION}")
  fi

  lxc exec "$name" -- "${guest_env[@]}" sh -c '
    if ! command -v bash >/dev/null 2>&1; then
      if command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash
      else
        printf "%s\n" "bash is required in the LXD guest" >&2
        exit 1
      fi
    fi
    exec bash -s -- "$1"
  ' pocketbase-lxd "$action" < "$script_path"
}

host_create() {
  local name image port proxy proxy_port proxy_listen proxy_device ip url
  require_command lxc

  name=${LXD_CONTAINER:-pocketbase}
  image=${LXD_IMAGE:-images:ubuntu/26.04}
  port=${POCKETBASE_PORT:-8080}
  validate_port "$port" POCKETBASE_PORT
  proxy="$(normalize_boolean "${LXD_PROXY:-false}")"
  proxy_port=${LXD_PROXY_PORT:-$port}
  proxy_listen=${LXD_PROXY_LISTEN:-0.0.0.0}
  proxy_device=${LXD_PROXY_DEVICE:-pocketbase-proxy}
  validate_lxd_container_name "$name"

  if host_container_exists "$name"; then
    host_start_existing_container "$name"
  else
    log "Launching ${name} from ${image}."
    lxc launch "$image" "$name"
    host_wait_for_exec "$name"
    host_set_static_ip "$name"
  fi

  log "Installing PocketBase inside ${name}."
  host_run_guest_action "$name" --install

  if [[ "$proxy" == true ]]; then
    host_configure_proxy "$name" "$proxy_listen" "$proxy_port" "$proxy_device" "$port"
  fi

  ip="$(lxc list "$name" --format csv -c 4 2>/dev/null | \
    tr ',' '\n' | awk '/^[0-9]+\./ { print; exit }' || true)"
  if [[ "$proxy" == true ]]; then
    url="http://127.0.0.1:${proxy_port}/_/"
  elif [[ -n "$ip" ]]; then
    url="http://${ip}:${port}/_/"
  else
    url="http://${name}:${port}/_/"
  fi

  printf '\nPocketBase LXD container is ready.\n'
  printf 'Container: %s\n' "$name"
  [[ -n "$ip" ]] && printf 'IPv4 address: %s\n' "$ip"
  printf 'Admin UI: %s\n' "$url"
}

host_update() {
  local name
  require_command lxc

  name=${LXD_CONTAINER:-pocketbase}
  validate_lxd_container_name "$name"
  host_start_existing_container "$name"
  log "Updating PocketBase inside ${name}."
  host_run_guest_action "$name" --update
  log "PocketBase update completed in ${name}."
}

# --- Main dispatch ---

main() {
  local action=${1:-}
  case "$action" in
    --help|-h)
      [[ "$#" -eq 1 ]] || die '--help does not accept additional arguments.'
      usage
      ;;
    --create)
      [[ "$#" -eq 1 ]] || die '--create does not accept additional arguments.'
      host_create
      ;;
    --update-container)
      [[ "$#" -eq 1 ]] || die '--update-container does not accept additional arguments.'
      host_update
      ;;
    --install|--update)
      [[ "$#" -eq 1 ]] || die "${action} does not accept additional arguments."
      install_guest "${action#--}"
      ;;
    --status)
      [[ "$#" -eq 1 ]] || die '--status does not accept additional arguments.'
      status_guest
      ;;
    '')
      usage >&2
      exit 2
      ;;
    *)
      die "Unknown option: ${action}. Use --help for usage."
      ;;
  esac
}

main "$@"
