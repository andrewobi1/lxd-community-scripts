#!/usr/bin/env bash
#
# Self-contained PostgreSQL installer for LXD containers.
#
# This is an independent LXD adaptation informed by the Community Scripts
# PostgreSQL installer. The upstream project is MIT-licensed:
# https://github.com/community-scripts/ProxmoxVE/blob/main/LICENSE
# Source reference:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/postgresql.sh
#
# Host usage:
#   ./postgresql-lxd.sh --create
#   LXD_CONTAINER=postgresql ./postgresql-lxd.sh --update-container
#
# Guest usage:
#   lxc exec postgresql -- bash -s -- --install < postgresql-lxd.sh
#   lxc exec postgresql -- bash -s -- --update  < postgresql-lxd.sh
#   lxc exec postgresql -- bash -s -- --status  < postgresql-lxd.sh

set -Eeuo pipefail

readonly SERVICE_NAME_DEBIAN="postgresql"
readonly SERVICE_NAME_ALPINE="postgresql"
readonly DEFAULT_PG_VERSION="17"
readonly CREDS_FILE="/root/postgresql.creds"

OS_FAMILY=""

log() {
  printf '[postgresql] %s\n' "$*"
}

warn() {
  printf '[postgresql] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[postgresql] ERROR: %s\n' "$*" >&2
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
PostgreSQL LXD installer

Host operations:
  --create                    Launch/start an LXD container and install PostgreSQL.
  --update-container          Update PostgreSQL packages inside an existing LXD container.

Guest operations:
  --install                   Install PostgreSQL in the current Debian/Ubuntu or Alpine guest.
  --update                    Update PostgreSQL packages while preserving data.
  --status                    Show the service status and connection information.
  --help                      Show this help.

Host environment variables:
  LXD_CONTAINER=postgresql    Existing or new container name.
  LXD_IMAGE=images:debian/13  LXD image to launch with --create only.
  LXD_PROXY=false             Set true/1 to add an LXD proxy device with --create only.
  LXD_PROXY_LISTEN=0.0.0.0   Host address used by the proxy device.
  LXD_PROXY_PORT=5432         Host port used by the proxy device.
  LXD_PROXY_DEVICE=postgresql-proxy
                              Name of the proxy device.

Guest/application environment variables:
  PG_VERSION=17               PostgreSQL major version (15, 16, 17, or 18).
  PG_PASSWORD=                Set a specific postgres superuser password; auto-generated if empty.
  PG_LISTEN=*                 listen_addresses value (default: * for all interfaces).
  PG_ADMINER=false            Install Adminer web UI (Debian: Apache, Alpine: lighttpd).

Examples:
  LXD_CONTAINER=postgresql LXD_PROXY=true ./postgresql-lxd.sh --create
  PG_VERSION=16 LXD_CONTAINER=pg16 ./postgresql-lxd.sh --create
  PG_ADMINER=true lxc exec postgresql -- bash -s -- --install < postgresql-lxd.sh
  lxc exec postgresql -- bash -s -- --status < postgresql-lxd.sh
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

validate_pg_version() {
  local ver=$1
  [[ "$ver" =~ ^(15|16|17|18)$ ]] || die "Invalid PostgreSQL version: ${ver}. Supported: 15, 16, 17, 18."
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
    pass="$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c24)"
  else
    pass="$(head -c 100 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c24)"
  fi
  [[ -n "$pass" ]] || die "Unable to generate a random password."
  printf '%s\n' "$pass"
}

# --- Debian install ---

install_debian() {
  local ver=${PG_VERSION:-$DEFAULT_PG_VERSION}
  local listen=${PG_LISTEN:-*}
  local password adminer
  validate_pg_version "$ver"
  adminer="$(normalize_boolean "${PG_ADMINER:-false}")"

  export DEBIAN_FRONTEND=noninteractive
  log "Installing PostgreSQL ${ver} (Debian/Ubuntu)."

  # Install prerequisites
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl

  # Add official PostgreSQL APT repository
  if ! apt-cache show "postgresql-${ver}" >/dev/null 2>&1; then
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
      gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] \
      http://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "${VERSION_CODENAME}")-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
    apt-get update
  fi

  apt-get install -y --no-install-recommends \
    "postgresql-${ver}" "postgresql-contrib-${ver}" ssl-cert

  # Generate or use provided password
  if [[ -n "${PG_PASSWORD:-}" ]]; then
    password="$PG_PASSWORD"
  else
    password="$(generate_password)"
  fi

  # Set postgres superuser password
  su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${password}';\"" \
    || die "Unable to set postgres password."

  # Save credentials
  cat > "$CREDS_FILE" <<EOF
PostgreSQL superuser credentials
User: postgres
Password: ${password}
Port: 5432
EOF
  chmod 0600 "$CREDS_FILE"

  # Write pg_hba.conf
  local hba_file="/etc/postgresql/${ver}/main/pg_hba.conf"
  cat > "$hba_file" <<'EOF'
# PostgreSQL Client Authentication Configuration File
local   all             postgres                                peer
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     md5
# IPv4 local connections:
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             0.0.0.0/0               md5
# IPv6 local connections:
host    all             all             ::1/128                 scram-sha-256
host    all             all             ::/0                    md5
# Replication connections:
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256
EOF

  # Write postgresql.conf
  local conf_file="/etc/postgresql/${ver}/main/postgresql.conf"
  cat > "$conf_file" <<EOF
# PostgreSQL configuration - generated by postgresql-lxd.sh

#--- FILE LOCATIONS ---
data_directory = '/var/lib/postgresql/${ver}/main'
hba_file = '/etc/postgresql/${ver}/main/pg_hba.conf'
ident_file = '/etc/postgresql/${ver}/main/pg_ident.conf'
external_pid_file = '/var/run/postgresql/${ver}-main.pid'

#--- CONNECTIONS AND AUTHENTICATION ---
listen_addresses = '${listen}'
port = 5432
max_connections = 100
unix_socket_directories = '/var/run/postgresql'

# SSL
ssl = on
ssl_cert_file = '/etc/ssl/certs/ssl-cert-snakeoil.pem'
ssl_key_file = '/etc/ssl/private/ssl-cert-snakeoil.key'

#--- RESOURCE USAGE ---
shared_buffers = 128MB
dynamic_shared_memory_type = posix

#--- WRITE-AHEAD LOG ---
max_wal_size = 1GB
min_wal_size = 80MB

#--- REPORTING AND LOGGING ---
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'Etc/UTC'

#--- PROCESS TITLE ---
cluster_name = '${ver}/main'

#--- CLIENT CONNECTION DEFAULTS ---
datestyle = 'iso, mdy'
timezone = 'Etc/UTC'
lc_messages = 'C'
lc_monetary = 'C'
lc_numeric = 'C'
lc_time = 'C'
default_text_search_config = 'pg_catalog.english'

#--- CONFIG FILE INCLUDES ---
include_dir = 'conf.d'
EOF

  systemctl restart postgresql
  if ! systemctl is-active --quiet postgresql; then
    systemctl --no-pager --full status postgresql || true
    die 'PostgreSQL systemd service is not active.'
  fi
  log "PostgreSQL ${ver} is installed and running."
  log "Password saved to ${CREDS_FILE} (mode 0600)."

  # Adminer
  if [[ "$adminer" == true ]]; then
    install_adminer_debian
  fi
}

install_adminer_debian() {
  log "Installing Adminer."
  apt-get install -y --no-install-recommends adminer
  a2enconf adminer 2>/dev/null || true
  if command -v apache2ctl >/dev/null 2>&1; then
    systemctl reload apache2 2>/dev/null || systemctl restart apache2
    log "Adminer available at http://<container-ip>/adminer"
  else
    # If apache isn't installed, install it
    apt-get install -y --no-install-recommends apache2 libapache2-mod-php php-pgsql
    a2enconf adminer
    systemctl enable --now apache2
    systemctl reload apache2
    log "Adminer available at http://<container-ip>/adminer"
  fi
}

# --- Alpine install ---

install_alpine() {
  local ver=${PG_VERSION:-$DEFAULT_PG_VERSION}
  local listen=${PG_LISTEN:-*}
  local password adminer
  # Alpine supports 15-17 typically
  [[ "$ver" =~ ^(15|16|17)$ ]] || die "Invalid PostgreSQL version for Alpine: ${ver}. Supported: 15, 16, 17."
  adminer="$(normalize_boolean "${PG_ADMINER:-false}")"

  log "Installing PostgreSQL ${ver} (Alpine)."
  apk add --no-cache "postgresql${ver}" "postgresql${ver}-contrib" "postgresql${ver}-openrc" sudo openssl

  # Generate or use provided password
  if [[ -n "${PG_PASSWORD:-}" ]]; then
    password="$PG_PASSWORD"
  else
    password="$(generate_password)"
  fi

  # Enable and start to initialize cluster
  rc-update add postgresql default >/dev/null
  rc-service postgresql start 2>/dev/null || true

  # Set postgres superuser password
  su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${password}';\"" \
    || die "Unable to set postgres password."

  # Save credentials
  cat > "$CREDS_FILE" <<EOF
PostgreSQL superuser credentials
User: postgres
Password: ${password}
Port: 5432
EOF
  chmod 0600 "$CREDS_FILE"

  # Configure for external access
  local conf_file="/etc/postgresql${ver}/postgresql.conf"
  local hba_file="/etc/postgresql${ver}/pg_hba.conf"

  if [[ -f "$conf_file" ]]; then
    sed -i "s/^#listen_addresses =.*/listen_addresses = '${listen}'/" "$conf_file"
    sed -i "s/^listen_addresses =.*/listen_addresses = '${listen}'/" "$conf_file"
  fi

  if [[ -f "$hba_file" ]]; then
    if ! grep -q '0.0.0.0/0' "$hba_file"; then
      printf 'host all all 0.0.0.0/0 md5\n' >> "$hba_file"
    fi
  fi

  rc-service postgresql restart
  if ! rc-service postgresql status >/dev/null 2>&1; then
    die 'PostgreSQL OpenRC service is not active.'
  fi
  log "PostgreSQL ${ver} is installed and running."
  log "Password saved to ${CREDS_FILE} (mode 0600)."

  # Adminer
  if [[ "$adminer" == true ]]; then
    install_adminer_alpine
  fi
}

install_adminer_alpine() {
  log "Installing Adminer with lighttpd."
  apk add --no-cache \
    lighttpd lighttpd-openrc \
    php83 php83-cgi php83-common php83-curl php83-gd \
    php83-mbstring php83-pdo php83-pgsql php83-openssl \
    php83-zip php83-session curl jq

  sed -i 's|# *include "mod_fastcgi.conf"|include "mod_fastcgi.conf"|' /etc/lighttpd/lighttpd.conf
  sed -i 's|/usr/bin/php-cgi|/usr/bin/php-cgi83|g' /etc/lighttpd/mod_fastcgi.conf

  mkdir -p /var/www/localhost/htdocs
  local adminer_version
  adminer_version="$(curl -fsSL https://api.github.com/repos/vrana/adminer/releases/latest | jq -r '.tag_name' | sed 's/^v//')" \
    || die "Unable to resolve Adminer version."
  curl -fsSL "https://github.com/vrana/adminer/releases/download/v${adminer_version}/adminer-${adminer_version}.php" \
    -o /var/www/localhost/htdocs/adminer.php \
    || die "Unable to download Adminer."
  chown lighttpd:lighttpd /var/www/localhost/htdocs/adminer.php
  chmod 0755 /var/www/localhost/htdocs/adminer.php

  rc-update add lighttpd default >/dev/null
  rc-service lighttpd restart
  log "Adminer available at http://<container-ip>/adminer.php"
}

# --- Guest update ---

update_guest() {
  require_root
  detect_os
  case "$OS_FAMILY" in
    debian)
      command -v psql >/dev/null 2>&1 || die "No PostgreSQL installation found."
      export DEBIAN_FRONTEND=noninteractive
      log 'Updating PostgreSQL packages (Debian/Ubuntu).'
      apt-get update
      apt-get -y upgrade
      systemctl restart postgresql 2>/dev/null || true
      log 'PostgreSQL updated successfully.'
      ;;
    alpine)
      log 'Updating PostgreSQL packages (Alpine).'
      apk update
      apk upgrade postgresql*
      rc-service postgresql restart
      log 'PostgreSQL updated successfully.'
      ;;
  esac
}

# --- Guest status ---

status_guest() {
  detect_os
  printf 'Platform: %s\n' "$OS_FAMILY"
  if command -v psql >/dev/null 2>&1; then
    printf 'psql version: %s\n' "$(psql --version 2>/dev/null)"
  fi
  if [[ -r "$CREDS_FILE" ]]; then
    printf 'Credentials file: %s\n' "$CREDS_FILE"
  fi
  case "$OS_FAMILY" in
    debian)
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status postgresql || true
      fi
      # Show listening port
      if command -v ss >/dev/null 2>&1; then
        printf '\nListening on:\n'
        ss -tlnp | grep -i postgres || true
      fi
      ;;
    alpine)
      if command -v rc-service >/dev/null 2>&1; then
        rc-service postgresql status || true
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
  if [[ -v PG_VERSION ]]; then
    guest_env+=("PG_VERSION=${PG_VERSION}")
  fi
  if [[ -v PG_PASSWORD ]]; then
    guest_env+=("PG_PASSWORD=${PG_PASSWORD}")
  fi
  if [[ -v PG_LISTEN ]]; then
    guest_env+=("PG_LISTEN=${PG_LISTEN}")
  fi
  if [[ -v PG_ADMINER ]]; then
    guest_env+=("PG_ADMINER=${PG_ADMINER}")
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
  ' postgresql-lxd "$action" < "$script_path"
}

host_create() {
  local name image port proxy proxy_port proxy_listen proxy_device ip
  require_command lxc

  name=${LXD_CONTAINER:-postgresql}
  image=${LXD_IMAGE:-images:debian/13}
  port=5432
  proxy="$(normalize_boolean "${LXD_PROXY:-false}")"
  proxy_port=${LXD_PROXY_PORT:-$port}
  proxy_listen=${LXD_PROXY_LISTEN:-0.0.0.0}
  proxy_device=${LXD_PROXY_DEVICE:-postgresql-proxy}
  validate_lxd_container_name "$name"

  if host_container_exists "$name"; then
    host_start_existing_container "$name"
  else
    log "Launching ${name} from ${image}."
    lxc launch "$image" "$name"
    host_wait_for_exec "$name"
  fi

  log "Installing PostgreSQL inside ${name}."
  host_run_guest_action "$name" --install

  if [[ "$proxy" == true ]]; then
    host_configure_proxy "$name" "$proxy_listen" "$proxy_port" "$proxy_device" "$port"
  fi

  ip="$(lxc list "$name" --format csv -c 4 2>/dev/null | \
    tr ',' '\n' | awk '/^[0-9]+\./ { print; exit }' || true)"

  printf '\nPostgreSQL LXD container is ready.\n'
  printf 'Container: %s\n' "$name"
  [[ -n "$ip" ]] && printf 'IPv4 address: %s\n' "$ip"
  printf 'Port: 5432\n'
  if [[ "$proxy" == true ]]; then
    printf 'Host proxy: %s:%s\n' "$proxy_listen" "$proxy_port"
  fi
  printf 'Credentials: stored in container at %s\n' "$CREDS_FILE"
  printf 'Retrieve: lxc exec %s -- cat %s\n' "$name" "$CREDS_FILE"
}

host_update() {
  local name
  require_command lxc

  name=${LXD_CONTAINER:-postgresql}
  validate_lxd_container_name "$name"
  host_start_existing_container "$name"
  log "Updating PostgreSQL inside ${name}."
  host_run_guest_action "$name" --update
  log "PostgreSQL update completed in ${name}."
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
    --status)
      [[ "$#" -eq 1 ]] || die '--status does not accept additional arguments.'
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
