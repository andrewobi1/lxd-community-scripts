#!/usr/bin/env bash
#
# Self-contained Forgejo Runner installer for LXD containers.
#
# This is an independent LXD adaptation informed by the Community Scripts
# Forgejo Runner installer. The upstream project is MIT-licensed:
# https://github.com/community-scripts/ProxmoxVE/blob/main/LICENSE
# Source reference:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/forgejo-runner.sh
#
# Host usage:
#   ./forgejo-runner-lxd.sh --create
#   LXD_CONTAINER=forgejo-runner ./forgejo-runner-lxd.sh --update-container
#
# Guest usage:
#   lxc exec forgejo-runner -- bash -s -- --install < forgejo-runner-lxd.sh
#   lxc exec forgejo-runner -- bash -s -- --update  < forgejo-runner-lxd.sh
#   lxc exec forgejo-runner -- bash -s -- --status  < forgejo-runner-lxd.sh

set -Eeuo pipefail

readonly BINARY_PATH="/usr/local/bin/forgejo-runner"
readonly CONFIG_DIR="/etc/forgejo-runner"
readonly CONFIG_FILE="${CONFIG_DIR}/config.yaml"
readonly SYSTEMD_UNIT="/etc/systemd/system/forgejo-runner.service"
readonly SERVICE_NAME="forgejo-runner"
readonly VERSION_FILE="${HOME}/.forgejo-runner"
readonly FORGEJO_RUNNER_REPO_API="https://data.forgejo.org/api/v1/repos/forgejo/runner/releases/latest"
readonly FORGEJO_RUNNER_DOWNLOAD_BASE="https://code.forgejo.org/forgejo/runner/releases/download"

log() {
  printf '[forgejo-runner] %s\n' "$*"
}

warn() {
  printf '[forgejo-runner] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[forgejo-runner] ERROR: %s\n' "$*" >&2
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
Forgejo Runner LXD installer

Host operations:
  --create                    Launch/start an LXD container and install Forgejo Runner.
  --update-container          Update Forgejo Runner inside an existing LXD container.

Guest operations:
  --install                   Install Forgejo Runner in the current Debian/Ubuntu guest.
  --update                    Update Forgejo Runner to the latest (or pinned) release.
  --status                    Show the service status and installation information.
  --help                      Show this help.

Host environment variables:
  LXD_CONTAINER=forgejo-runner   Existing or new container name.
  LXD_IMAGE=images:ubuntu/26.04     LXD image to launch with --create only.
  LXD_NESTING=true               Enable container nesting (required for Podman).
  LXD_KEYCTL=true                Enable keyctl syscall interception.

Guest/registration environment variables (required for --install):
  FORGEJO_INSTANCE=              Forgejo instance URL (e.g. https://codeberg.org).
  FORGEJO_RUNNER_UUID=           Runner UUID from the Forgejo instance.
  FORGEJO_RUNNER_TOKEN=          Runner registration token from the Forgejo instance.
  RUNNER_LABELS=                 Comma-separated labels (default: linux-amd64:docker://node:22-bookworm).

Guest/application environment variables:
  FORGEJO_RUNNER_VERSION=        Optional release version (e.g. 13.0.0), otherwise latest.

Examples:
  FORGEJO_INSTANCE=https://codeberg.org \
    FORGEJO_RUNNER_UUID=abc123 \
    FORGEJO_RUNNER_TOKEN=secret123 \
    LXD_CONTAINER=forgejo-runner ./forgejo-runner-lxd.sh --create

  LXD_CONTAINER=forgejo-runner ./forgejo-runner-lxd.sh --update-container

  FORGEJO_INSTANCE=https://codeberg.org \
    FORGEJO_RUNNER_UUID=abc123 \
    FORGEJO_RUNNER_TOKEN=secret123 \
    lxc exec forgejo-runner -- bash -s -- --install < forgejo-runner-lxd.sh
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

# --- Release resolution ---

resolve_runner_version() {
  local requested=$1 version
  if [[ -n "$requested" ]]; then
    version="${requested#v}"
  else
    require_command curl
    require_command grep
    version="$(curl -fsSL "$FORGEJO_RUNNER_REPO_API" \
      | grep -oP '"tag_name":\s*"\Kv?[^"]+' \
      | sed 's/^v//' \
      | head -1)" \
      || die "Unable to resolve the latest Forgejo Runner release."
    [[ -n "$version" ]] || die "Could not parse the latest Forgejo Runner release tag."
  fi
  printf '%s\n' "$version"
}

# --- Download and deploy ---

download_runner() {
  local version=$1 arch=$2 url tmp_file
  url="${FORGEJO_RUNNER_DOWNLOAD_BASE}/v${version}/forgejo-runner-${version}-linux-${arch}"
  tmp_file="$(mktemp /var/tmp/forgejo-runner.XXXXXX)"

  log "Downloading Forgejo Runner v${version} for ${arch}."
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output "$tmp_file" "$url" \
    || {
      rm -f "$tmp_file"
      die "Unable to download Forgejo Runner v${version} from ${url}."
    }

  install -m 0755 "$tmp_file" "$BINARY_PATH"
  rm -f "$tmp_file"
  printf '%s\n' "$version" > "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE"
  log "Installed Forgejo Runner v${version} to ${BINARY_PATH}."
}

# --- yq installation ---

ensure_yq() {
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi
  local arch yq_url tmp_file
  arch="$(resolve_arch)"
  yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
  tmp_file="$(mktemp /var/tmp/yq.XXXXXX)"

  log "Installing yq."
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output "$tmp_file" "$yq_url" \
    || {
      rm -f "$tmp_file"
      die "Unable to download yq."
    }
  install -m 0755 "$tmp_file" /usr/local/bin/yq
  rm -f "$tmp_file"
  command -v yq >/dev/null 2>&1 || die "yq installation failed."
}

# --- Configuration ---

configure_runner() {
  local instance=$1 uuid=$2 token=$3 labels=$4 docker_host
  docker_host="unix:///run/podman/podman.sock"

  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    forgejo-runner generate-config > "$CONFIG_FILE" \
      || die "Failed to generate Forgejo Runner configuration."
  fi

  export DOCKER_HOST="$docker_host"
  export FORGEJO_INSTANCE="$instance"
  export FORGEJO_RUNNER_UUID="$uuid"
  export FORGEJO_RUNNER_TOKEN="$token"
  export RUNNER_LABELS="$labels"

  yq -i '
    .container.docker_host = strenv(DOCKER_HOST) |
    .server.connections.forgejo.url = strenv(FORGEJO_INSTANCE) |
    .server.connections.forgejo.uuid = strenv(FORGEJO_RUNNER_UUID) |
    .server.connections.forgejo.token = strenv(FORGEJO_RUNNER_TOKEN) |
    .server.connections.forgejo.labels = (strenv(RUNNER_LABELS) | split(",") | map(select(length > 0)))
  ' "$CONFIG_FILE" \
    || die "Failed to configure Forgejo Runner with yq."

  chmod 0600 "$CONFIG_FILE"
  log "Configuration written to ${CONFIG_FILE}."
}

# --- Service management ---

write_systemd_unit() {
  if [[ -e "$SYSTEMD_UNIT" ]]; then
    return 0
  fi
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Forgejo Runner
Documentation=https://forgejo.org/docs/latest/admin/actions/
After=podman.socket
Requires=podman.socket

[Service]
User=root
WorkingDirectory=/root
Environment=DOCKER_HOST=unix:///run/podman/podman.sock
ExecStart=${BINARY_PATH} daemon -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10
TimeoutSec=0

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SYSTEMD_UNIT"
}

start_systemd_service() {
  require_command systemctl
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    die 'Forgejo Runner systemd service is not active.'
  fi
}

# --- Guest install ---

install_guest() {
  local mode=$1
  local version arch instance uuid token labels
  require_root

  version="$(resolve_runner_version "${FORGEJO_RUNNER_VERSION:-}")"
  arch="$(resolve_arch)"

  if [[ "$mode" == install ]]; then
    # Registration parameters are required for initial install
    instance=${FORGEJO_INSTANCE:-}
    uuid=${FORGEJO_RUNNER_UUID:-}
    token=${FORGEJO_RUNNER_TOKEN:-}

    [[ -n "$instance" ]] || die "FORGEJO_INSTANCE is required. Set it to your Forgejo instance URL."
    [[ -n "$uuid" ]] || die "FORGEJO_RUNNER_UUID is required."
    [[ -n "$token" ]] || die "FORGEJO_RUNNER_TOKEN is required."

    local default_label="linux-$(resolve_arch):docker://node:22-bookworm"
    if [[ -n "${RUNNER_LABELS:-}" ]]; then
      labels="${default_label},${RUNNER_LABELS}"
    else
      labels="$default_label"
    fi

    export DEBIAN_FRONTEND=noninteractive
    log 'Installing runtime dependencies.'
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl git podman podman-docker

    log 'Enabling Podman socket.'
    systemctl enable --now podman.socket

    download_runner "$version" "$arch"
    ensure_yq
    configure_runner "$instance" "$uuid" "$token" "$labels"
    write_systemd_unit
    start_systemd_service
    log "Forgejo Runner v${version} is installed and registered."
    log "Check your Forgejo instance for the new runner."

  elif [[ "$mode" == update ]]; then
    [[ -f "$BINARY_PATH" ]] || die "No Forgejo Runner installation found at ${BINARY_PATH}."

    if [[ -r "$VERSION_FILE" ]]; then
      local current
      current="$(cat "$VERSION_FILE")"
      if [[ "$current" == "$version" ]]; then
        log "Forgejo Runner is already at v${version}; nothing to do."
        start_systemd_service
        return 0
      fi
    fi

    log "Stopping Forgejo Runner service."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    download_runner "$version" "$arch"

    log "Starting Forgejo Runner service."
    start_systemd_service
    log "Forgejo Runner updated to v${version}."
  fi
}

# --- Guest status ---

status_guest() {
  printf 'Binary: %s\n' "$BINARY_PATH"
  if [[ -r "$VERSION_FILE" ]]; then
    printf 'Installed version: v%s\n' "$(cat "$VERSION_FILE")"
  else
    printf 'Installed version: unknown\n'
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    printf 'Configuration: %s\n' "$CONFIG_FILE"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
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
  if [[ -v FORGEJO_INSTANCE ]]; then
    guest_env+=("FORGEJO_INSTANCE=${FORGEJO_INSTANCE}")
  fi
  if [[ -v FORGEJO_RUNNER_UUID ]]; then
    guest_env+=("FORGEJO_RUNNER_UUID=${FORGEJO_RUNNER_UUID}")
  fi
  if [[ -v FORGEJO_RUNNER_TOKEN ]]; then
    guest_env+=("FORGEJO_RUNNER_TOKEN=${FORGEJO_RUNNER_TOKEN}")
  fi
  if [[ -v RUNNER_LABELS ]]; then
    guest_env+=("RUNNER_LABELS=${RUNNER_LABELS}")
  fi
  if [[ -v FORGEJO_RUNNER_VERSION ]]; then
    guest_env+=("FORGEJO_RUNNER_VERSION=${FORGEJO_RUNNER_VERSION}")
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
  ' forgejo-runner-lxd "$action" < "$script_path"
}

host_create() {
  local name image nesting keyctl
  require_command lxc

  name=${LXD_CONTAINER:-forgejo-runner}
  image=${LXD_IMAGE:-images:ubuntu/26.04}
  nesting="$(normalize_boolean "${LXD_NESTING:-true}")"
  keyctl="$(normalize_boolean "${LXD_KEYCTL:-true}")"
  validate_lxd_container_name "$name"

  # Validate registration params before creating container
  [[ -n "${FORGEJO_INSTANCE:-}" ]] || die "FORGEJO_INSTANCE is required for --create."
  [[ -n "${FORGEJO_RUNNER_UUID:-}" ]] || die "FORGEJO_RUNNER_UUID is required for --create."
  [[ -n "${FORGEJO_RUNNER_TOKEN:-}" ]] || die "FORGEJO_RUNNER_TOKEN is required for --create."

  if host_container_exists "$name"; then
    host_start_existing_container "$name"
  else
    log "Launching ${name} from ${image}."
    local -a launch_args=()
    if [[ "$nesting" == true ]]; then
      launch_args+=(-c security.nesting=true)
    fi
    if [[ "$keyctl" == true ]]; then
      launch_args+=(-c security.syscalls.intercept.mknod=true)
      launch_args+=(-c security.syscalls.intercept.setxattr=true)
    fi
    lxc launch "$image" "$name" "${launch_args[@]}"
    host_wait_for_exec "$name"
    host_set_static_ip "$name"
  fi

  log "Installing Forgejo Runner inside ${name}."
  host_run_guest_action "$name" --install

  printf '\nForgejo Runner LXD container is ready.\n'
  printf 'Container: %s\n' "$name"
  printf 'Check your Forgejo instance for the new runner.\n'
}

host_update() {
  local name
  require_command lxc

  name=${LXD_CONTAINER:-forgejo-runner}
  validate_lxd_container_name "$name"
  host_start_existing_container "$name"
  log "Updating Forgejo Runner inside ${name}."
  host_run_guest_action "$name" --update
  log "Forgejo Runner update completed in ${name}."
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
