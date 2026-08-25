#!/usr/bin/env bash
#
# Self-contained Forgejo installer for LXD containers.
#
# This is an independent LXD adaptation informed by the Community Scripts
# Forgejo installer. The upstream project is MIT-licensed:
# https://github.com/community-scripts/ProxmoxVE/blob/main/LICENSE
# Source reference:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/forgejo.sh
#
# Host usage:
#   ./forgejo-lxd.sh --create
#   LXD_CONTAINER=forgejo ./forgejo-lxd.sh --update-container
#
# Guest usage:
#   lxc exec forgejo -- bash -s -- --install < forgejo-lxd.sh
#   lxc exec forgejo -- bash -s -- --update  < forgejo-lxd.sh
#   lxc exec forgejo -- bash -s -- --status  < forgejo-lxd.sh

set -Eeuo pipefail

readonly INSTALL_DIR="/opt/forgejo"
readonly BINARY_LINK="/usr/local/bin/forgejo"
readonly WORK_DIR="/var/lib/forgejo"
readonly CONFIG_DIR="/etc/forgejo"
readonly CONFIG_FILE="${CONFIG_DIR}/app.ini"
readonly SYSTEMD_UNIT="/etc/systemd/system/forgejo.service"
readonly SERVICE_NAME="forgejo"
readonly VERSION_FILE="${HOME}/.forgejo"
readonly CODEBERG_API="https://codeberg.org/api/v1/repos/forgejo/forgejo/releases/latest"
readonly CODEBERG_DL_BASE="https://codeberg.org/forgejo/forgejo/releases/download"

OS_FAMILY=""

log() {
  printf '[forgejo] %s\n' "$*"
}

warn() {
  printf '[forgejo] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[forgejo] ERROR: %s\n' "$*" >&2
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
Forgejo LXD installer

Host operations:
  --create                    Launch/start an LXD container and install Forgejo.
  --update-container          Update Forgejo inside an existing LXD container.

Guest operations:
  --install                   Install Forgejo in the current Debian/Ubuntu or Alpine guest.
  --update                    Update Forgejo binary while preserving data and configuration.
  --status                    Show the service status and installation information.
  --help                      Show this help.

Host environment variables:
  LXD_CONTAINER=forgejo       Existing or new container name.
  LXD_IMAGE=images:ubuntu/26.04  LXD image to launch with --create only.
  LXD_PROXY=false             Set true/1 to add an LXD proxy device with --create only.
  LXD_PROXY_LISTEN=0.0.0.0   Host address used by the proxy device.
  LXD_PROXY_PORT=3000         Host port used by the proxy device.
  LXD_PROXY_DEVICE=forgejo-proxy
                              Name of the proxy device.

Guest/application environment variables:
  FORGEJO_PORT=3000           Informational; Forgejo defaults to 3000 unless app.ini overrides.
  FORGEJO_VERSION=            Optional release version (e.g. 16.0.3), otherwise latest.

Examples:
  LXD_CONTAINER=forgejo LXD_PROXY=true ./forgejo-lxd.sh --create
  LXD_CONTAINER=forgejo ./forgejo-lxd.sh --update-container
  FORGEJO_VERSION=16.0.3 \
    lxc exec forgejo -- bash -s -- --update < forgejo-lxd.sh
  lxc exec forgejo -- bash -s -- --status < forgejo-lxd.sh
EOF
}

# --- Validation helpers ---

validate_port() {
  local value=$1 label=${2:-port}
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || die "Invalid ${label}: ${value}"
  (( 10#${value} >= 1 && 10#${value} <= 65535 )) || die "Invalid ${label}: ${value}"
}

normalize_boolean() {
  local value=${1,,}
  case "$value" in
    true|yes|1|on) printf 'true\n' ;;
    false|no|0|off) printf 'false\n' ;;
    *) die "Expected a boolean value, got: ${1}" ;;
  esac
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

# --- OS detection ---

detect_os() {
  local id like
  [[ -r /etc/os-release ]] || die '/etc/os-release is not available; unsupported guest OS.'
  # shellcheck disable=SC1091
  . /etc/os-release
  id=${ID:-}
  like=${ID_LIKE:-}
  case "$id" in
    alpine)
      OS_FAMILY=alpine
      ;;
    debian|ubuntu)
      OS_FAMILY=debian
      ;;
    *)
      if [[ " ${like} " == *' debian '* || " ${like} " == *' ubuntu '* ]]; then
        OS_FAMILY=debian
      else
        die "Unsupported guest OS: ${id:-unknown}. Supported: Debian/Ubuntu and Alpine."
      fi
      ;;
  esac
}

# --- Release resolution ---

resolve_forgejo_version() {
  local requested=$1 version
  if [[ -n "$requested" ]]; then
    version="${requested#v}"
  else
    require_command curl
    version="$(curl -fsSL "$CODEBERG_API" | grep -oP '"tag_name":\s*"\Kv?[^"]+' | head -1)" \
      || die "Unable to resolve the latest Forgejo release."
    version="${version#v}"
    [[ -n "$version" ]] || die "Could not parse the latest Forgejo release tag."
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid Forgejo version: ${version}"
  printf '%s\n' "$version"
}

# --- Download binary ---

download_forgejo() {
  local version=$1 arch=$2 asset_name url tmp_file
  asset_name="forgejo-${version}-linux-${arch}"
  url="${CODEBERG_DL_BASE}/v${version}/${asset_name}"
  tmp_file="$(mktemp /var/tmp/forgejo-binary.XXXXXX)"

  log "Downloading Forgejo v${version} for ${arch}."
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output "$tmp_file" "$url" \
    || {
      rm -f "$tmp_file"
      die "Unable to download Forgejo v${version} from ${url}."
    }

  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$tmp_file" "${INSTALL_DIR}/forgejo"
  rm -f "$tmp_file"
  ln -sf "${INSTALL_DIR}/forgejo" "$BINARY_LINK"

  printf '%s\n' "$version" > "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE"
  log "Installed Forgejo v${version} to ${INSTALL_DIR}/forgejo"
}

# --- Service management (Debian) ---

ensure_git_user() {
  if ! id -u git >/dev/null 2>&1; then
    adduser --system --shell /bin/bash --gecos 'Git Version Control' \
      --group --disabled-password --home /home/git git
  fi
}

setup_directories() {
  mkdir -p "$WORK_DIR"
  chown git:git "$WORK_DIR"
  chmod 750 "$WORK_DIR"
  mkdir -p "$CONFIG_DIR"
  chown root:git "$CONFIG_DIR"
  chmod 770 "$CONFIG_DIR"
}

write_systemd_unit() {
  if [[ -e "$SYSTEMD_UNIT" ]]; then
    # Update legacy GITEA_WORK_DIR if present
    if grep -q "GITEA_WORK_DIR" "$SYSTEMD_UNIT"; then
      sed -i "s/GITEA_WORK_DIR/FORGEJO_WORK_DIR/g" "$SYSTEMD_UNIT"
      systemctl daemon-reload
    fi
    return 0
  fi
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Forgejo
After=syslog.target
After=network.target

[Service]
RestartSec=2s
Type=simple
User=git
Group=git
WorkingDirectory=${WORK_DIR}
ExecStart=${BINARY_LINK} web --config ${CONFIG_FILE}
Restart=always
Environment=USER=git HOME=/home/git FORGEJO_WORK_DIR=${WORK_DIR}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SYSTEMD_UNIT"
}

start_systemd_service() {
  require_command systemctl
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  sleep 2
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    warn "Forgejo service may still be starting. Check: systemctl status forgejo"
  else
    log "Forgejo service is active."
  fi
}

# --- Debian install ---

install_debian() {
  local version arch

  export DEBIAN_FRONTEND=noninteractive
  log 'Installing dependencies (Debian/Ubuntu).'
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl git git-lfs

  version="$(resolve_forgejo_version "${FORGEJO_VERSION:-}")"
  arch="$(resolve_arch)"

  download_forgejo "$version" "$arch"
  ensure_git_user
  setup_directories
  write_systemd_unit
  start_systemd_service

  log "Forgejo v${version} is installed and running."
  log "Access: http://<container-ip>:3000"
  log "Configuration: ${CONFIG_FILE} (created on first access)"
}

# --- Debian update ---

update_debian() {
  [[ -d "$INSTALL_DIR" && -x "${INSTALL_DIR}/forgejo" ]] \
    || die "No Forgejo installation found at ${INSTALL_DIR}."

  local version arch
  version="$(resolve_forgejo_version "${FORGEJO_VERSION:-}")"
  arch="$(resolve_arch)"

  if [[ -r "$VERSION_FILE" ]]; then
    local current
    current="$(cat "$VERSION_FILE")"
    if [[ "$current" == "$version" ]]; then
      log "Forgejo is already at v${version}; nothing to do."
      return 0
    fi
  fi

  log "Stopping Forgejo service."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  download_forgejo "$version" "$arch"

  # Migrate legacy service file
  if [[ -f "$SYSTEMD_UNIT" ]] && grep -q "GITEA_WORK_DIR" "$SYSTEMD_UNIT"; then
    sed -i "s/GITEA_WORK_DIR/FORGEJO_WORK_DIR/g" "$SYSTEMD_UNIT"
  fi

  log "Starting Forgejo service."
  start_systemd_service
  log "Forgejo updated to v${version}."
}

# --- Alpine install ---

install_alpine() {
  log 'Installing Forgejo (Alpine).'
  apk add --no-cache forgejo

  rc-update add forgejo default >/dev/null
  rc-service forgejo start 2>/dev/null || rc-service forgejo restart
  if ! rc-service forgejo status >/dev/null 2>&1; then
    warn "Forgejo service may still be starting."
  else
    log "Forgejo service is active."
  fi

  log "Forgejo is installed via Alpine package."
  log "Access: http://<container-ip>:3000"
}

# --- Alpine update ---

update_alpine() {
  log 'Updating Forgejo (Alpine).'
  apk update
  apk upgrade forgejo
  rc-service forgejo restart
  log "Forgejo updated successfully."
}

# --- Guest status ---

status_guest() {
  detect_os
  case "$OS_FAMILY" in
    debian)
      printf 'Platform: Debian/Ubuntu\n'
      printf 'Binary: %s\n' "${INSTALL_DIR}/forgejo"
      if [[ -r "$VERSION_FILE" ]]; then
        printf 'Installed version: v%s\n' "$(cat "$VERSION_FILE")"
      else
        printf 'Installed version: unknown\n'
      fi
      printf 'Work directory: %s\n' "$WORK_DIR"
      printf 'Configuration: %s\n' "$CONFIG_FILE"
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status "$SERVICE_NAME" || true
      fi
      ;;
    alpine)
      printf 'Platform: Alpine\n'
      if command -v forgejo >/dev/null 2>&1; then
        printf 'Binary: %s\n' "$(command -v forgejo)"
        forgejo --version 2>/dev/null || true
      fi
      if command -v rc-service >/dev/null 2>&1; then
        rc-service forgejo status || true
      fi
      ;;
  esac
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
  if [[ -v FORGEJO_VERSION ]]; then
    guest_env+=("FORGEJO_VERSION=${FORGEJO_VERSION}")
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
  ' forgejo-lxd "$action" < "$script_path"
}

host_create() {
  local name image port proxy proxy_port proxy_listen proxy_device ip url
  require_command lxc

  name=${LXD_CONTAINER:-forgejo}
  image=${LXD_IMAGE:-images:ubuntu/26.04}
  port=${FORGEJO_PORT:-3000}
  validate_port "$port" FORGEJO_PORT
  proxy="$(normalize_boolean "${LXD_PROXY:-false}")"
  proxy_port=${LXD_PROXY_PORT:-$port}
  proxy_listen=${LXD_PROXY_LISTEN:-0.0.0.0}
  proxy_device=${LXD_PROXY_DEVICE:-forgejo-proxy}
  validate_lxd_container_name "$name"

  if host_container_exists "$name"; then
    host_start_existing_container "$name"
  else
    log "Launching ${name} from ${image}."
    lxc launch "$image" "$name"
    host_wait_for_exec "$name"
    host_set_static_ip "$name"
  fi

  log "Installing Forgejo inside ${name}."
  host_run_guest_action "$name" --install

  if [[ "$proxy" == true ]]; then
    host_configure_proxy "$name" "$proxy_listen" "$proxy_port" "$proxy_device" "$port"
  fi

  ip="$(lxc list "$name" --format csv -c 4 2>/dev/null | \
    tr ',' '\n' | awk '/^[0-9]+\./ { print; exit }' || true)"
  if [[ "$proxy" == true ]]; then
    url="http://127.0.0.1:${proxy_port}"
  elif [[ -n "$ip" ]]; then
    url="http://${ip}:${port}"
  else
    url="http://${name}:${port}"
  fi

  printf '\nForgejo LXD container is ready.\n'
  printf 'Container: %s\n' "$name"
  [[ -n "$ip" ]] && printf 'IPv4 address: %s\n' "$ip"
  printf 'URL: %s\n' "$url"
  printf 'Note: Complete the initial setup via the web UI on first access.\n'
}

host_update() {
  local name
  require_command lxc

  name=${LXD_CONTAINER:-forgejo}
  validate_lxd_container_name "$name"
  host_start_existing_container "$name"
  log "Updating Forgejo inside ${name}."
  host_run_guest_action "$name" --update
  log "Forgejo update completed in ${name}."
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
    --install)
      [[ "$#" -eq 1 ]] || die '--install does not accept additional arguments.'
      require_root
      detect_os
      case "$OS_FAMILY" in
        debian) install_debian ;;
        alpine) install_alpine ;;
      esac
      ;;
    --update)
      [[ "$#" -eq 1 ]] || die '--update does not accept additional arguments.'
      require_root
      detect_os
      case "$OS_FAMILY" in
        debian) update_debian ;;
        alpine) update_alpine ;;
      esac
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
