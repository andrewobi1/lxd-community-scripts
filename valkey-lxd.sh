#!/usr/bin/env bash
#
# Self-contained Valkey installer for LXD containers.
#
# This is an independent LXD adaptation informed by the Community Scripts
# Valkey installer. The upstream project is MIT-licensed:
# https://github.com/community-scripts/ProxmoxVE/blob/main/LICENSE
# Source reference:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/valkey.sh
#
# Host usage:
#   ./valkey-lxd.sh --create
#   LXD_CONTAINER=valkey ./valkey-lxd.sh --update-container
#
# Guest usage:
#   lxc exec valkey -- bash -s -- --install < valkey-lxd.sh
#   lxc exec valkey -- bash -s -- --update  < valkey-lxd.sh
#   lxc exec valkey -- bash -s -- --status  < valkey-lxd.sh
#   lxc exec valkey -- bash -s -- --set-bind < valkey-lxd.sh

set -Eeuo pipefail

readonly VALKEY_CONF="/etc/valkey/valkey.conf"
readonly CREDS_FILE="/root/valkey.creds"
readonly TLS_DIR="/etc/ssl/valkey"
readonly SERVICE_NAME_DEBIAN="valkey-server"
readonly SERVICE_NAME_ALPINE="valkey"

OS_FAMILY=""

log() {
  printf '[valkey] %s\n' "$*"
}

warn() {
  printf '[valkey] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[valkey] ERROR: %s\n' "$*" >&2
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
Valkey LXD installer

Host operations:
  --create                    Launch/start an LXD container and install Valkey.
  --update-container          Update Valkey packages inside an existing LXD container.

Guest operations:
  --install                   Install Valkey in the current Debian/Ubuntu or Alpine guest.
  --update                    Update Valkey packages while preserving configuration/data.
  --set-bind [ADDRESS]        Change the Valkey bind address (default: 0.0.0.0).
  --status                    Show the service status and connection information.
  --help                      Show this help.

Host environment variables:
  LXD_CONTAINER=valkey        Existing or new container name.
  LXD_IMAGE=images:debian/13  LXD image to launch with --create only.
  LXD_PROXY=false             Set true/1 to add an LXD proxy device with --create only.
  LXD_PROXY_LISTEN=0.0.0.0   Host address used by the proxy device.
  LXD_PROXY_PORT=6379         Host port used by the proxy device.
  LXD_PROXY_DEVICE=valkey-proxy
                              Name of the proxy device.

Guest/application environment variables:
  VALKEY_PORT=6379            Default Valkey port (used only during fresh --install).
  VALKEY_BIND=0.0.0.0         Bind address for Valkey (default: 0.0.0.0).
  VALKEY_TLS=false            Enable TLS with a self-signed certificate on fresh install.
  VALKEY_TLS_ONLY=false       If TLS enabled, disable the plaintext TCP port entirely.
  VALKEY_PASSWORD=            Set a specific password; if empty one is auto-generated.

Examples:
  LXD_CONTAINER=valkey LXD_PROXY=true ./valkey-lxd.sh --create
  LXD_CONTAINER=valkey ./valkey-lxd.sh --update-container
  VALKEY_TLS=true VALKEY_TLS_ONLY=true \
    lxc exec valkey -- bash -s -- --install < valkey-lxd.sh
  lxc exec valkey -- bash -s -- --set-bind 127.0.0.1 < valkey-lxd.sh
  lxc exec valkey -- bash -s -- --status < valkey-lxd.sh
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

validate_bind_address() {
  local addr=$1
  # Allow IPv4 addresses, 0.0.0.0, 127.0.0.1, or hostnames
  [[ "$addr" =~ ^[A-Za-z0-9.:_-]+$ ]] || die "Invalid bind address: ${addr}"
  [[ ${#addr} -le 253 ]] || die "Bind address too long: ${addr}"
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

# --- Password generation ---

generate_password() {
  local pass
  if command -v openssl >/dev/null 2>&1; then
    pass="$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c32)"
  else
    pass="$(head -c 100 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c32)"
  fi
  [[ -n "$pass" ]] || die "Unable to generate a random password."
  printf '%s\n' "$pass"
}

# --- Memory calculation ---

calculate_maxmemory() {
  local mem_total_mb max_mb
  mem_total_mb="$(free -m | awk '/^Mem:/ {print $2}')"
  max_mb=$(( mem_total_mb * 75 / 100 ))
  (( max_mb < 1 )) && max_mb=1
  printf '%s\n' "$max_mb"
}

# --- TLS certificate generation ---

create_tls_cert() {
  local cert_file="${TLS_DIR}/valkey.crt" key_file="${TLS_DIR}/valkey.key"
  require_command openssl

  if [[ -s "$cert_file" && -s "$key_file" ]]; then
    return 0
  fi

  mkdir -p "$TLS_DIR"
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
    -subj "/CN=valkey" \
    -addext "subjectAltName=DNS:valkey" \
    -keyout "$key_file" -out "$cert_file" \
    >/dev/null 2>&1 \
    || die 'Unable to generate a self-signed TLS certificate for Valkey.'

  chmod 0644 "$cert_file"
  chmod 0600 "$key_file"
  if id -u valkey >/dev/null 2>&1; then
    chown valkey:valkey "$cert_file" "$key_file"
  fi
  log "TLS certificate generated in ${TLS_DIR}."
}

# --- Debian install ---

install_debian() {
  local port bind_addr tls_enabled tls_only password maxmem

  port=${VALKEY_PORT:-6379}
  bind_addr=${VALKEY_BIND:-0.0.0.0}
  tls_enabled="$(normalize_boolean "${VALKEY_TLS:-false}")"
  tls_only="$(normalize_boolean "${VALKEY_TLS_ONLY:-false}")"
  validate_port "$port" VALKEY_PORT
  validate_bind_address "$bind_addr"

  export DEBIAN_FRONTEND=noninteractive
  log 'Installing Valkey (Debian/Ubuntu).'
  apt-get update
  apt-get install -y --no-install-recommends valkey openssl ca-certificates

  # Generate or use provided password
  if [[ -n "${VALKEY_PASSWORD:-}" ]]; then
    password="$VALKEY_PASSWORD"
  else
    password="$(generate_password)"
  fi

  # Save credentials
  printf '%s\n' "$password" > "$CREDS_FILE"
  chmod 0600 "$CREDS_FILE"

  # Configure
  maxmem="$(calculate_maxmemory)"

  # Preserve existing conf if this is a re-run with existing data
  if [[ -f "$VALKEY_CONF" ]]; then
    sed -i "s/^bind .*/bind ${bind_addr}/" "$VALKEY_CONF"
    if ! grep -q '^requirepass ' "$VALKEY_CONF"; then
      printf 'requirepass %s\n' "$password" >> "$VALKEY_CONF"
    fi
    if ! grep -q '^maxmemory ' "$VALKEY_CONF"; then
      cat >> "$VALKEY_CONF" <<EOF

# Memory-optimized settings for small-scale deployments
maxmemory ${maxmem}mb
maxmemory-policy allkeys-lru
maxmemory-samples 10
EOF
    fi
  else
    mkdir -p "$(dirname "$VALKEY_CONF")"
    cat > "$VALKEY_CONF" <<EOF
bind ${bind_addr}
requirepass ${password}

# Memory-optimized settings for small-scale deployments
maxmemory ${maxmem}mb
maxmemory-policy allkeys-lru
maxmemory-samples 10
EOF
  fi

  # TLS configuration
  if [[ "$tls_enabled" == true ]]; then
    create_tls_cert
    # Remove any existing TLS lines before adding new ones
    sed -i '/^tls-port/d; /^tls-cert-file/d; /^tls-key-file/d; /^tls-auth-clients/d' "$VALKEY_CONF"
    if [[ "$tls_only" == true ]]; then
      sed -i "s/^port .*/port 0/" "$VALKEY_CONF" 2>/dev/null || true
      if ! grep -q '^port ' "$VALKEY_CONF"; then
        printf 'port 0\n' >> "$VALKEY_CONF"
      fi
      cat >> "$VALKEY_CONF" <<EOF
tls-port ${port}
tls-cert-file ${TLS_DIR}/valkey.crt
tls-key-file ${TLS_DIR}/valkey.key
tls-auth-clients no
EOF
      log "TLS-only mode enabled on port ${port}."
    else
      cat >> "$VALKEY_CONF" <<EOF
tls-port 6380
tls-cert-file ${TLS_DIR}/valkey.crt
tls-key-file ${TLS_DIR}/valkey.key
tls-auth-clients no
EOF
      log "TLS enabled on port 6380; plaintext on port ${port}."
    fi
  fi

  systemctl enable --now "$SERVICE_NAME_DEBIAN"
  systemctl restart "$SERVICE_NAME_DEBIAN"
  if ! systemctl is-active --quiet "$SERVICE_NAME_DEBIAN"; then
    systemctl --no-pager --full status "$SERVICE_NAME_DEBIAN" || true
    die 'Valkey systemd service is not active.'
  fi

  log "Valkey is installed and running."
  log "Password saved to ${CREDS_FILE} (mode 0600)."
  log "Connect: valkey-cli -a \$(cat ${CREDS_FILE}) -h ${bind_addr} -p ${port}"
}

# --- Alpine install ---

install_alpine() {
  local bind_addr password maxmem

  bind_addr=${VALKEY_BIND:-0.0.0.0}
  validate_bind_address "$bind_addr"

  log 'Installing Valkey (Alpine).'
  apk add --no-cache valkey valkey-openrc valkey-cli

  # Generate or use provided password
  if [[ -n "${VALKEY_PASSWORD:-}" ]]; then
    password="$VALKEY_PASSWORD"
  else
    password="$(generate_password)"
  fi

  # Save credentials
  printf '%s\n' "$password" > "$CREDS_FILE"
  chmod 0600 "$CREDS_FILE"

  # Configure
  maxmem="$(calculate_maxmemory)"

  if [[ -f "$VALKEY_CONF" ]]; then
    sed -i "s/^bind .*/bind ${bind_addr}/" "$VALKEY_CONF"
    if ! grep -q '^requirepass ' "$VALKEY_CONF"; then
      printf 'requirepass %s\n' "$password" >> "$VALKEY_CONF"
    fi
    if ! grep -q '^maxmemory ' "$VALKEY_CONF"; then
      cat >> "$VALKEY_CONF" <<EOF

# Memory-optimized settings for small-scale deployments
maxmemory ${maxmem}mb
maxmemory-policy allkeys-lru
maxmemory-samples 10
EOF
    fi
  else
    mkdir -p "$(dirname "$VALKEY_CONF")"
    cat > "$VALKEY_CONF" <<EOF
bind ${bind_addr}
requirepass ${password}

# Memory-optimized settings for small-scale deployments
maxmemory ${maxmem}mb
maxmemory-policy allkeys-lru
maxmemory-samples 10
EOF
  fi

  # Note: Alpine's valkey package is compiled without TLS support
  if [[ "$(normalize_boolean "${VALKEY_TLS:-false}")" == true ]]; then
    warn "TLS is not supported on Alpine's valkey package. Use a Debian-based image for TLS."
  fi

  rc-update add valkey default >/dev/null
  rc-service valkey start 2>/dev/null || rc-service valkey restart
  if ! rc-service valkey status >/dev/null 2>&1; then
    die 'Valkey OpenRC service is not active.'
  fi

  log "Valkey is installed and running."
  log "Password saved to ${CREDS_FILE} (mode 0600)."
  log "Connect: valkey-cli -a \$(cat ${CREDS_FILE}) -h ${bind_addr}"
}

# --- Guest update ---

update_guest() {
  require_root
  detect_os
  case "$OS_FAMILY" in
    debian)
      [[ -f /lib/systemd/system/valkey-server.service || -f "$VALKEY_CONF" ]] \
        || die "No Valkey installation found."
      export DEBIAN_FRONTEND=noninteractive
      log 'Updating Valkey packages (Debian/Ubuntu).'
      apt-get update
      apt-get -y upgrade valkey
      systemctl restart "$SERVICE_NAME_DEBIAN"
      log 'Valkey updated successfully.'
      ;;
    alpine)
      [[ -f "$VALKEY_CONF" ]] || die "No Valkey installation found."
      log 'Updating Valkey packages (Alpine).'
      apk update
      apk upgrade valkey
      rc-service valkey restart
      log 'Valkey updated successfully.'
      ;;
  esac
}

# --- Set bind address ---

set_bind() {
  local addr=${1:-0.0.0.0}
  require_root
  detect_os
  validate_bind_address "$addr"

  [[ -f "$VALKEY_CONF" ]] || die "No Valkey configuration found at ${VALKEY_CONF}."
  sed -i "s/^bind .*/bind ${addr}/" "$VALKEY_CONF"

  case "$OS_FAMILY" in
    debian)
      systemctl restart "$SERVICE_NAME_DEBIAN"
      ;;
    alpine)
      rc-service valkey restart
      ;;
  esac
  log "Valkey bind address changed to ${addr}."
}

# --- Guest status ---

status_guest() {
  detect_os
  printf 'Configuration: %s\n' "$VALKEY_CONF"
  if [[ -f "$VALKEY_CONF" ]]; then
    local bind_line port_line
    bind_line="$(grep '^bind ' "$VALKEY_CONF" 2>/dev/null || echo 'bind (not set)')"
    port_line="$(grep '^port \|^tls-port ' "$VALKEY_CONF" 2>/dev/null || echo 'port 6379')"
    printf 'Bind: %s\n' "$bind_line"
    printf 'Port config: %s\n' "$port_line"
  fi
  if [[ -r "$CREDS_FILE" ]]; then
    printf 'Credentials file: %s (use cat to read)\n' "$CREDS_FILE"
  fi
  case "$OS_FAMILY" in
    debian)
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status "$SERVICE_NAME_DEBIAN" || true
      fi
      ;;
    alpine)
      if command -v rc-service >/dev/null 2>&1; then
        rc-service valkey status || true
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
  if [[ -v VALKEY_PORT ]]; then
    guest_env+=("VALKEY_PORT=${VALKEY_PORT}")
  fi
  if [[ -v VALKEY_BIND ]]; then
    guest_env+=("VALKEY_BIND=${VALKEY_BIND}")
  fi
  if [[ -v VALKEY_TLS ]]; then
    guest_env+=("VALKEY_TLS=${VALKEY_TLS}")
  fi
  if [[ -v VALKEY_TLS_ONLY ]]; then
    guest_env+=("VALKEY_TLS_ONLY=${VALKEY_TLS_ONLY}")
  fi
  if [[ -v VALKEY_PASSWORD ]]; then
    guest_env+=("VALKEY_PASSWORD=${VALKEY_PASSWORD}")
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
  ' valkey-lxd "$action" < "$script_path"
}

host_create() {
  local name image port proxy proxy_port proxy_listen proxy_device ip url
  require_command lxc

  name=${LXD_CONTAINER:-valkey}
  image=${LXD_IMAGE:-images:debian/13}
  port=${VALKEY_PORT:-6379}
  validate_port "$port" VALKEY_PORT
  proxy="$(normalize_boolean "${LXD_PROXY:-false}")"
  proxy_port=${LXD_PROXY_PORT:-$port}
  proxy_listen=${LXD_PROXY_LISTEN:-0.0.0.0}
  proxy_device=${LXD_PROXY_DEVICE:-valkey-proxy}
  validate_lxd_container_name "$name"

  if host_container_exists "$name"; then
    host_start_existing_container "$name"
  else
    log "Launching ${name} from ${image}."
    lxc launch "$image" "$name"
    host_wait_for_exec "$name"
  fi

  log "Installing Valkey inside ${name}."
  host_run_guest_action "$name" --install

  if [[ "$proxy" == true ]]; then
    host_configure_proxy "$name" "$proxy_listen" "$proxy_port" "$proxy_device" "$port"
  fi

  ip="$(lxc list "$name" --format csv -c 4 2>/dev/null | \
    tr ',' '\n' | awk '/^[0-9]+\./ { print; exit }' || true)"

  printf '\nValkey LXD container is ready.\n'
  printf 'Container: %s\n' "$name"
  [[ -n "$ip" ]] && printf 'IPv4 address: %s\n' "$ip"
  printf 'Default port: %s\n' "$port"
  if [[ "$proxy" == true ]]; then
    printf 'Host proxy: %s:%s\n' "$proxy_listen" "$proxy_port"
  fi
  printf 'Password: stored in container at %s\n' "$CREDS_FILE"
  printf 'Retrieve: lxc exec %s -- cat %s\n' "$name" "$CREDS_FILE"
}

host_update() {
  local name
  require_command lxc

  name=${LXD_CONTAINER:-valkey}
  validate_lxd_container_name "$name"
  host_start_existing_container "$name"
  log "Updating Valkey inside ${name}."
  host_run_guest_action "$name" --update
  log "Valkey update completed in ${name}."
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
      update_guest
      ;;
    --set-bind)
      set_bind "${2:-0.0.0.0}"
      ;;
    --status)
      [[ "$#" -eq 1 ]] || die '--status does not accept additional arguments.'
      require_root
      detect_os
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
