#!/usr/bin/env bash
#
# Self-contained Metabase installer for LXD containers.
#
# This is an independent LXD adaptation informed by the Community Scripts
# Metabase installer. The upstream project is MIT-licensed:
# https://github.com/community-scripts/ProxmoxVE/blob/main/LICENSE
# Source reference:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/metabase.sh
#
# Host usage:
#   ./metabase-lxd.sh --create
#   LXD_CONTAINER=metabase ./metabase-lxd.sh --update-container
#
# Guest usage:
#   lxc exec metabase -- bash -s -- --install < metabase-lxd.sh
#   lxc exec metabase -- bash -s -- --update  < metabase-lxd.sh
#   lxc exec metabase -- bash -s -- --status  < metabase-lxd.sh

set -Eeuo pipefail

readonly INSTALL_DIR="/opt/metabase"
readonly ENV_FILE="${INSTALL_DIR}/.env"
readonly JAR_FILE="${INSTALL_DIR}/metabase.jar"
readonly VERSION_FILE="${HOME}/.metabase"
readonly SYSTEMD_UNIT="/etc/systemd/system/metabase.service"
readonly SERVICE_NAME="metabase"
readonly METABASE_REPO="metabase/metabase"

readonly PG_DB_NAME="metabase_db"
readonly PG_DB_USER="metabase"

log() {
  printf '[metabase] %s\n' "$*"
}

warn() {
  printf '[metabase] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[metabase] ERROR: %s\n' "$*" >&2
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
Metabase LXD installer

Host operations:
  --create                    Launch/start an LXD container and install Metabase.
  --update-container          Update Metabase inside an existing LXD container.

Guest operations:
  --install                   Install Metabase with Java 21 and PostgreSQL 17.
  --update                    Update Metabase jar to the latest (or pinned) release.
  --status                    Show the service status and installation information.
  --help                      Show this help.

Host environment variables:
  LXD_CONTAINER=metabase      Existing or new container name.
  LXD_IMAGE=images:debian/13  LXD image to launch with --create only.
  LXD_PROXY=false             Set true/1 to add an LXD proxy device with --create only.
  LXD_PROXY_LISTEN=0.0.0.0   Host address used by the proxy device.
  LXD_PROXY_PORT=3000         Host port used by the proxy device.
  LXD_PROXY_DEVICE=metabase-proxy
                              Name of the proxy device.

Guest/application environment variables:
  METABASE_PORT=3000          Metabase listening port (informational; Metabase binds 3000 by default).
  METABASE_VERSION=           Optional release version (e.g. 0.63.14), otherwise latest.

Examples:
  LXD_CONTAINER=metabase LXD_PROXY=true ./metabase-lxd.sh --create
  LXD_CONTAINER=metabase ./metabase-lxd.sh --update-container
  METABASE_VERSION=0.63.14 \
    lxc exec metabase -- bash -s -- --update < metabase-lxd.sh
  lxc exec metabase -- bash -s -- --status < metabase-lxd.sh
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

# --- Release resolution ---

resolve_metabase_version() {
  local requested=$1 tag version
  if [[ -n "$requested" ]]; then
    version="${requested#v}"
  else
    require_command curl
    tag="$(curl --fail --silent --show-error --location --head --retry 3 \
      --proto '=https' --tlsv1.2 --output /dev/null --write-out '%{url_effective}' \
      "https://github.com/${METABASE_REPO}/releases/latest")" \
      || die "Unable to resolve the latest Metabase release."
    tag="${tag%%\?*}"
    tag="${tag##*/}"
    [[ -n "$tag" ]] || die "Could not determine the latest Metabase release tag."
    version="${tag#v}"
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid Metabase version: ${version}"
  printf '%s\n' "$version"
}

# --- Password generation ---

generate_password() {
  local pass
  pass="$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c24)"
  [[ -n "$pass" ]] || die "Unable to generate a random password."
  printf '%s\n' "$pass"
}

# --- Java installation ---

install_java() {
  local java_version=${1:-21}
  if java -version 2>&1 | grep -q "openjdk version \"${java_version}"; then
    log "Java ${java_version} is already installed."
    return 0
  fi
  log "Installing OpenJDK ${java_version}."
  apt-get install -y --no-install-recommends "openjdk-${java_version}-jre-headless" \
    || die "Unable to install OpenJDK ${java_version}."
}

# --- PostgreSQL installation ---

install_postgresql() {
  local pg_version=${1:-17}
  if command -v psql >/dev/null 2>&1; then
    log "PostgreSQL is already installed."
  else
    log "Installing PostgreSQL ${pg_version}."
    # Add official PostgreSQL APT repo if the version isn't available
    if ! apt-cache show "postgresql-${pg_version}" >/dev/null 2>&1; then
      apt-get install -y --no-install-recommends curl ca-certificates gnupg
      curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
        gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] \
        http://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "${VERSION_CODENAME}")-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
      apt-get update
    fi
    apt-get install -y --no-install-recommends "postgresql-${pg_version}" \
      || die "Unable to install PostgreSQL ${pg_version}."
  fi

  # Ensure PostgreSQL is running
  systemctl enable --now postgresql
  if ! systemctl is-active --quiet postgresql; then
    die 'PostgreSQL service is not active.'
  fi
}

setup_postgresql_db() {
  local db_name=$1 db_user=$2 db_pass
  db_pass="$(generate_password)"

  # Create user if not exists
  if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${db_user}'\"" | grep -q 1; then
    su - postgres -c "psql -c \"CREATE USER ${db_user} WITH PASSWORD '${db_pass}';\""
    log "Created PostgreSQL user: ${db_user}"
  else
    # Update password for existing user
    su - postgres -c "psql -c \"ALTER USER ${db_user} WITH PASSWORD '${db_pass}';\""
    log "Updated password for PostgreSQL user: ${db_user}"
  fi

  # Create database if not exists
  if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${db_name}'\"" | grep -q 1; then
    su - postgres -c "psql -c \"CREATE DATABASE ${db_name} OWNER ${db_user};\""
    log "Created PostgreSQL database: ${db_name}"
  else
    log "PostgreSQL database already exists: ${db_name}"
  fi

  # Return the password via a global
  PG_DB_PASS="$db_pass"
}

# --- Download Metabase jar ---

download_metabase_jar() {
  local version=$1 url tmp_file
  # Metabase download URLs append .x to the version
  url="https://downloads.metabase.com/v${version}.x/metabase.jar"
  tmp_file="$(mktemp /var/tmp/metabase.jar.XXXXXX)"

  log "Downloading Metabase v${version}."
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output "$tmp_file" "$url" \
    || {
      rm -f "$tmp_file"
      die "Unable to download Metabase v${version} from ${url}."
    }

  # Verify it's a valid jar (zip format)
  if ! file "$tmp_file" 2>/dev/null | grep -qi 'zip\|java'; then
    # Fallback: check the first bytes for PK zip magic
    local magic
    magic="$(head -c2 "$tmp_file" | xxd -p 2>/dev/null || true)"
    if [[ "$magic" != "504b" ]]; then
      rm -f "$tmp_file"
      die "Downloaded file does not appear to be a valid jar/zip archive."
    fi
  fi

  mv -f "$tmp_file" "$JAR_FILE"
  chmod 0644 "$JAR_FILE"
  printf '%s\n' "$version" > "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE"
  log "Installed Metabase jar: ${JAR_FILE}"
}

# --- Write environment file ---

write_env_file() {
  local db_pass=$1
  # Only create if it doesn't exist (preserve on re-runs)
  if [[ -f "$ENV_FILE" ]]; then
    log "Environment file already exists; preserving: ${ENV_FILE}"
    return 0
  fi
  cat > "$ENV_FILE" <<EOF
MB_DB_TYPE=postgres
MB_DB_DBNAME=${PG_DB_NAME}
MB_DB_PORT=5432
MB_DB_USER=${PG_DB_USER}
MB_DB_PASS=${db_pass}
MB_DB_HOST=localhost
EOF
  chmod 0600 "$ENV_FILE"
  log "Environment file created: ${ENV_FILE}"
}

# --- Service management ---

write_systemd_unit() {
  if [[ -e "$SYSTEMD_UNIT" ]]; then
    return 0
  fi
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Metabase Service
After=network.target postgresql.service
Wants=postgresql.service

[Service]
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/java --add-opens java.base/java.nio=ALL-UNNAMED -jar metabase.jar
Restart=always
SuccessExitStatus=143
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SYSTEMD_UNIT"
}

start_systemd_service() {
  require_command systemctl
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  # Metabase takes a while to start; don't fail immediately
  sleep 3
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    warn "Metabase service may still be starting. Check: systemctl status metabase"
  else
    log "Metabase service is active."
  fi
}

# --- Guest install ---

install_guest() {
  require_root

  local version
  version="$(resolve_metabase_version "${METABASE_VERSION:-}")"

  export DEBIAN_FRONTEND=noninteractive
  log 'Installing system dependencies.'
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl file openssl gnupg

  install_java 21
  install_postgresql 17

  local PG_DB_PASS=""
  setup_postgresql_db "$PG_DB_NAME" "$PG_DB_USER"

  mkdir -p "$INSTALL_DIR"
  download_metabase_jar "$version"
  write_env_file "$PG_DB_PASS"
  write_systemd_unit
  start_systemd_service

  log "Metabase v${version} is installed."
  log "Access: http://<container-ip>:3000"
  log "PostgreSQL credentials stored in: ${ENV_FILE}"
}

# --- Guest update ---

update_guest() {
  require_root

  [[ -d "$INSTALL_DIR" ]] || die "No Metabase installation found at ${INSTALL_DIR}."
  [[ -f "$JAR_FILE" ]] || die "No Metabase jar found at ${JAR_FILE}."

  local version
  version="$(resolve_metabase_version "${METABASE_VERSION:-}")"

  if [[ -r "$VERSION_FILE" ]]; then
    local current
    current="$(cat "$VERSION_FILE")"
    if [[ "$current" == "$version" ]]; then
      log "Metabase is already at v${version}; nothing to do."
      return 0
    fi
  fi

  log "Stopping Metabase service."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  # Backup env file (safety measure matching upstream behavior)
  if [[ -f "$ENV_FILE" ]]; then
    cp -a "$ENV_FILE" "/opt/.metabase-env.bak.$$"
  fi

  download_metabase_jar "$version"

  # Restore env file if somehow removed
  if [[ ! -f "$ENV_FILE" && -f "/opt/.metabase-env.bak.$$" ]]; then
    mv "/opt/.metabase-env.bak.$$" "$ENV_FILE"
  else
    rm -f "/opt/.metabase-env.bak.$$"
  fi

  log "Starting Metabase service."
  start_systemd_service
  log "Metabase updated to v${version}."
}

# --- Guest status ---

status_guest() {
  printf 'Installation directory: %s\n' "$INSTALL_DIR"
  if [[ -r "$VERSION_FILE" ]]; then
    printf 'Installed version: v%s\n' "$(cat "$VERSION_FILE")"
  else
    printf 'Installed version: unknown\n'
  fi
  if [[ -f "$ENV_FILE" ]]; then
    printf 'Environment file: %s\n' "$ENV_FILE"
    printf 'Database: %s (user: %s)\n' "$PG_DB_NAME" "$PG_DB_USER"
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
  if [[ -v METABASE_VERSION ]]; then
    guest_env+=("METABASE_VERSION=${METABASE_VERSION}")
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
  ' metabase-lxd "$action" < "$script_path"
}

host_create() {
  local name image port proxy proxy_port proxy_listen proxy_device ip url
  require_command lxc

  name=${LXD_CONTAINER:-metabase}
  image=${LXD_IMAGE:-images:debian/13}
  port=${METABASE_PORT:-3000}
  validate_port "$port" METABASE_PORT
  proxy="$(normalize_boolean "${LXD_PROXY:-false}")"
  proxy_port=${LXD_PROXY_PORT:-$port}
  proxy_listen=${LXD_PROXY_LISTEN:-0.0.0.0}
  proxy_device=${LXD_PROXY_DEVICE:-metabase-proxy}
  validate_lxd_container_name "$name"

  if host_container_exists "$name"; then
    host_start_existing_container "$name"
  else
    log "Launching ${name} from ${image}."
    lxc launch "$image" "$name"
    host_wait_for_exec "$name"
  fi

  log "Installing Metabase inside ${name}."
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

  printf '\nMetabase LXD container is ready.\n'
  printf 'Container: %s\n' "$name"
  [[ -n "$ip" ]] && printf 'IPv4 address: %s\n' "$ip"
  printf 'URL: %s\n' "$url"
  printf 'Note: Metabase may take 1-2 minutes to fully start on first boot.\n'
}

host_update() {
  local name
  require_command lxc

  name=${LXD_CONTAINER:-metabase}
  validate_lxd_container_name "$name"
  host_start_existing_container "$name"
  log "Updating Metabase inside ${name}."
  host_run_guest_action "$name" --update
  log "Metabase update completed in ${name}."
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
      install_guest
      ;;
    --update)
      [[ "$#" -eq 1 ]] || die '--update does not accept additional arguments.'
      update_guest
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
