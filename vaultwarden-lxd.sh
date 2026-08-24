#!/usr/bin/env bash
#
# Self-contained Vaultwarden installer for LXD containers.
#
# This is an independent LXD adaptation informed by the Community Scripts
# Vaultwarden installer. The upstream project is MIT-licensed:
# https://github.com/community-scripts/ProxmoxVE/blob/main/LICENSE
# Source reference:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/vaultwarden.sh
#
# Host usage:
#   ./vaultwarden-lxd.sh --create
#   LXD_CONTAINER=vaultwarden ./vaultwarden-lxd.sh --update-container
#
# Guest usage:
#   lxc exec vaultwarden -- bash -s -- --install < vaultwarden-lxd.sh
#   lxc exec vaultwarden -- bash -s -- --update < vaultwarden-lxd.sh
#   lxc exec vaultwarden -- bash -s -- --status < vaultwarden-lxd.sh
#   lxc exec vaultwarden -- bash -s -- --set-admin-token < vaultwarden-lxd.sh

set -Eeuo pipefail

readonly INSTALL_DIR="/opt/vaultwarden"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly ENV_FILE="${INSTALL_DIR}/.env"
readonly WEB_VAULT_DIR="${INSTALL_DIR}/web-vault"
readonly TLS_DIR="${INSTALL_DIR}/ssl"
readonly VERSION_FILE="${INSTALL_DIR}/.versions"
readonly SYSTEMD_UNIT="/etc/systemd/system/vaultwarden.service"
readonly ALPINE_CONF="/etc/conf.d/vaultwarden"
readonly SERVICE_NAME="vaultwarden"

OS_FAMILY=""
BUILD_DIR=""

log() {
  printf '[vaultwarden] %s\n' "$*"
}

warn() {
  printf '[vaultwarden] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[vaultwarden] ERROR: %s\n' "$*" >&2
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
Vaultwarden LXD installer

Host operations:
  --create                    Launch/start an LXD container and install Vaultwarden.
  --update-container          Update Vaultwarden inside an existing LXD container.

Guest operations:
  --install                   Install Vaultwarden in the current Debian/Ubuntu or Alpine guest.
  --update                    Update the application and web vault while preserving configuration/data.
  --set-admin-token           Prompt for an admin token and store only its Argon2id hash.
  --status                    Show the service status and non-secret installation information.
  --help                      Show this help.

Host environment variables:
  LXD_CONTAINER=vaultwarden   Existing or new container name.
  LXD_IMAGE=images:debian/13 LXD image to launch with --create only.
  LXD_PROXY=false             Set true/1 to add an LXD proxy device with --create only.
  LXD_PROXY_LISTEN=0.0.0.0   Host address used by the proxy device.
  LXD_PROXY_PORT=8000        Host port used by the proxy device.
  LXD_PROXY_DEVICE=vaultwarden-proxy
                              Name of the proxy device.

Guest/application environment variables:
  VAULTWARDEN_PORT=8000       Initial Rocket listening port.
  VAULTWARDEN_TLS=true        Enable self-signed HTTPS on a fresh configuration.
  VAULTWARDEN_DOMAIN=         Optional DOMAIN value, for example https://vault.example.
  VAULTWARDEN_VERSION=        Optional Vaultwarden release tag, otherwise latest.
  WEB_VAULT_VERSION=          Optional web-vault release tag, otherwise latest.
  VAULTWARDEN_ADMIN_TOKEN=    Non-interactive token input for --set-admin-token only.

Examples:
  LXD_CONTAINER=vaultwarden LXD_PROXY=true ./vaultwarden-lxd.sh --create
  LXD_CONTAINER=vaultwarden ./vaultwarden-lxd.sh --update-container
  VAULTWARDEN_VERSION=1.37.2 WEB_VAULT_VERSION=v2026.6.4 \
    LXD_CONTAINER=vaultwarden ./vaultwarden-lxd.sh --update-container
  VAULTWARDEN_PORT=8080 VAULTWARDEN_TLS=false \
    lxc exec vaultwarden -- bash -s -- --install < vaultwarden-lxd.sh
  lxc exec vaultwarden -- bash -s -- --update < vaultwarden-lxd.sh
  lxc exec vaultwarden -- bash -s -- --set-admin-token < vaultwarden-lxd.sh
EOF
}

validate_port() {
  local value=$1 label=${2:-port}
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || die "Invalid ${label}: ${value}"
  (( 10#${value} >= 1 && 10#${value} <= 65535 )) || die "Invalid ${label}: ${value}"
}

validate_release_tag() {
  local value=$1 label=$2
  [[ "$value" =~ ^v?[0-9][0-9A-Za-z._-]*$ ]] || die "Invalid ${label} release tag: ${value}"
}

validate_no_newline() {
  local value=$1 label=$2
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "${label} must not contain a newline."
  [[ "$value" != *"'"* ]] || die "${label} must not contain a single quote."
}

normalize_boolean() {
  local value=${1,,}
  case "$value" in
    true|yes|1|on) printf 'true\n' ;;
    false|no|0|off) printf 'false\n' ;;
    *) die "Expected a boolean value, got: ${1}" ;;
  esac
}

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

ensure_regular_file() {
  local file=$1 mode=${2:-0600}
  [[ ! -L "$file" ]] || die "Refusing to modify symlink: ${file}"
  if [[ ! -e "$file" ]]; then
    install -m "$mode" /dev/null "$file"
  else
    chmod "$mode" "$file"
  fi
}

config_has_key() {
  local file=$1 key=$2
  [[ -f "$file" ]] || return 1
  awk -v key="$key" '
    BEGIN { pattern = "^[[:space:]]*" key "[[:space:]]*=" }
    $0 ~ pattern { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

upsert_config_key() {
  local file=$1 key=$2 value=$3 replacement tmp
  validate_no_newline "$value" "$key"
  replacement="${key}='${value}'"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  awk -v key="$key" -v replacement="$replacement" '
    BEGIN {
      pattern = "^[[:space:]]*" key "[[:space:]]*="
      found = 0
    }
    $0 ~ pattern {
      if (!found) {
        print replacement
        found = 1
      }
      next
    }
    { print }
    END {
      if (!found) print replacement
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    die "Unable to update ${file}."
  }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

remove_config_key() {
  local file=$1 key=$2 tmp
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  awk -v key="$key" '
    BEGIN { pattern = "^[[:space:]]*" key "[[:space:]]*=" }
    $0 !~ pattern { print }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    die "Unable to update ${file}."
  }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

ensure_config_key() {
  local file=$1 key=$2 value=$3
  if ! config_has_key "$file" "$key"; then
    upsert_config_key "$file" "$key" "$value"
  fi
}

config_value() {
  local file=$1 key=$2 line value first last
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if (( ${#value} >= 2 )); then
      first=${value:0:1}
      last=${value: -1}
      if [[ ( "$first" == "'" && "$last" == "'" ) || ( "$first" == '"' && "$last" == '"' ) ]]; then
        value=${value:1:${#value}-2}
      fi
    fi
    printf '%s\n' "$value"
    return 0
  done < "$file"
  return 1
}

cleanup_build() {
  if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR"
  fi
}

trap cleanup_build EXIT

prepare_build_dir() {
  require_command mktemp
  BUILD_DIR="$(mktemp -d /var/tmp/vaultwarden-build.XXXXXX)"
  chmod 0700 "$BUILD_DIR"
}

install_rust_toolchain() {
  local rustup_init
  export PATH="/root/.cargo/bin:${PATH}"
  if [[ -f /root/.cargo/env ]]; then
    # shellcheck disable=SC1091
    . /root/.cargo/env
  fi
  if ! command -v rustup >/dev/null 2>&1; then
    rustup_init="${BUILD_DIR}/rustup-init.sh"
    curl --fail --silent --show-error --location --retry 3 \
      --proto '=https' --tlsv1.2 \
      --output "$rustup_init" https://sh.rustup.rs \
      || die 'Unable to download the official rustup installer.'
    chmod 0700 "$rustup_init"
    "$rustup_init" -y --profile minimal --default-toolchain stable --no-modify-path \
      || die 'rustup installation failed.'
  fi
  export PATH="/root/.cargo/bin:${PATH}"
  command -v rustup >/dev/null 2>&1 || die 'rustup is not available after installation.'
  rustup toolchain install stable --profile minimal --no-self-update \
    || die 'Unable to install the stable Rust toolchain.'
  rustup default stable >/dev/null \
    || die 'Unable to select the stable Rust toolchain.'
}

download_and_build_debian() {
  local vaultwarden_tag=$1 web_tag=$2 source_archive web_archive source_dir web_extract web_root
  source_archive="${BUILD_DIR}/vaultwarden.tar.gz"
  web_archive="${BUILD_DIR}/web-vault.tar.gz"
  source_dir="${BUILD_DIR}/source"
  web_extract="${BUILD_DIR}/web-extract"

  mkdir -p "$source_dir" "$web_extract"
  log "Downloading Vaultwarden ${vaultwarden_tag}." >&2
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output "$source_archive" \
    "https://github.com/dani-garcia/vaultwarden/archive/refs/tags/${vaultwarden_tag}.tar.gz" \
    || die "Unable to download Vaultwarden ${vaultwarden_tag}."

  log "Downloading web vault ${web_tag}." >&2
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    --output "$web_archive" \
    "https://github.com/dani-garcia/bw_web_builds/releases/download/${web_tag}/bw_web_${web_tag}.tar.gz" \
    || die "Unable to download web vault ${web_tag}."

  tar -xzf "$source_archive" --strip-components=1 -C "$source_dir" \
    || die 'Unable to extract the Vaultwarden source archive.'
  tar -xzf "$web_archive" -C "$web_extract" \
    || die 'Unable to extract the web-vault archive.'

  web_root="$web_extract"
  if [[ ! -f "${web_root}/index.html" ]]; then
    local candidate
    for candidate in "$web_extract"/*; do
      if [[ -d "$candidate" && -f "${candidate}/index.html" ]]; then
        web_root="$candidate"
        break
      fi
    done
  fi
  [[ -f "${web_root}/index.html" ]] || die 'The web-vault archive does not contain index.html.'

  log "Compiling Vaultwarden from source." >&2
  install_rust_toolchain >&2
  (
    cd "$source_dir"
    export PATH="/root/.cargo/bin:${PATH}"
    cargo build --locked --features 'sqlite,mysql,postgresql' --release >&2
  ) || die 'Vaultwarden compilation failed.'

  [[ -x "${source_dir}/target/release/vaultwarden" ]] \
    || die 'The Vaultwarden build did not produce target/release/vaultwarden.'
  printf '%s\n' "$web_root"
}

create_tls_certificate() {
  local common_name=${VAULTWARDEN_TLS_COMMON_NAME:-vaultwarden}
  local cert_file="${TLS_DIR}/cert.pem" key_file="${TLS_DIR}/key.pem"
  local tmp_dir
  validate_no_newline "$common_name" VAULTWARDEN_TLS_COMMON_NAME
  require_command openssl

  if [[ -s "$cert_file" && -s "$key_file" ]]; then
    return 0
  fi
  [[ ! -e "$cert_file" && ! -e "$key_file" ]] \
    || die "Only one Vaultwarden TLS file exists; refusing to replace it automatically."

  tmp_dir="$(mktemp -d "${TLS_DIR}/.tls.XXXXXX")"
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
    -subj "/CN=${common_name}" \
    -addext "subjectAltName=DNS:${common_name}" \
    -keyout "${tmp_dir}/key.pem" -out "${tmp_dir}/cert.pem" \
    >/dev/null 2>&1 \
    || {
      rm -rf "$tmp_dir"
      die 'Unable to generate a self-signed TLS certificate.'
    }
  mv "$tmp_dir/cert.pem" "$cert_file"
  mv "$tmp_dir/key.pem" "$key_file"
  rmdir "$tmp_dir"
  chmod 0644 "$cert_file"
  chmod 0600 "$key_file"
  chown root:vaultwarden "$cert_file" "$key_file"
}

ensure_debian_user() {
  if ! getent group vaultwarden >/dev/null 2>&1; then
    groupadd --system vaultwarden
  fi
  if ! id -u vaultwarden >/dev/null 2>&1; then
    useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin \
      --gid vaultwarden vaultwarden
  fi
}

write_systemd_unit() {
  if [[ -e "$SYSTEMD_UNIT" ]]; then
    return 0
  fi
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Vaultwarden password server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vaultwarden
Group=vaultwarden
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-${ENV_FILE}
ExecStart=${INSTALL_DIR}/vaultwarden
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SYSTEMD_UNIT"
}

configure_debian() {
  local port=$1 tls_enabled=$2 port_override=$3 tls_override=$4
  ensure_regular_file "$ENV_FILE" 0600
  install -d -o vaultwarden -g vaultwarden -m 0750 "$DATA_DIR"
  install -d -o root -g vaultwarden -m 0750 "$TLS_DIR"

  if [[ "$port_override" == true ]]; then
    upsert_config_key "$ENV_FILE" ROCKET_PORT "$port"
  else
    ensure_config_key "$ENV_FILE" ROCKET_PORT "$port"
  fi
  ensure_config_key "$ENV_FILE" ROCKET_ADDRESS '0.0.0.0'
  ensure_config_key "$ENV_FILE" DATA_FOLDER "$DATA_DIR"
  ensure_config_key "$ENV_FILE" WEB_VAULT_FOLDER "$WEB_VAULT_DIR"

  if [[ -n "${VAULTWARDEN_DOMAIN:-}" ]]; then
    validate_no_newline "$VAULTWARDEN_DOMAIN" VAULTWARDEN_DOMAIN
    ensure_config_key "$ENV_FILE" DOMAIN "$VAULTWARDEN_DOMAIN"
  fi

  if [[ "$tls_enabled" == true ]]; then
    if ! config_has_key "$ENV_FILE" ROCKET_TLS; then
      create_tls_certificate
      upsert_config_key "$ENV_FILE" ROCKET_TLS \
        '{certs="/opt/vaultwarden/ssl/cert.pem",key="/opt/vaultwarden/ssl/key.pem"}'
    fi
  elif [[ "$tls_override" == true ]]; then
    remove_config_key "$ENV_FILE" ROCKET_TLS
  fi

  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  chown -R vaultwarden:vaultwarden "$DATA_DIR"
  chown root:root "$WEB_VAULT_DIR" 2>/dev/null || true
}

deploy_debian_artifacts() {
  local source_dir=$1 web_root=$2 vaultwarden_tag=$3 web_tag=$4
  local binary_tmp web_tmp web_backup

  binary_tmp="${INSTALL_DIR}/.vaultwarden.new.$$"
  install -m 0755 "$source_dir/target/release/vaultwarden" "$binary_tmp"
  chown root:root "$binary_tmp"
  mv -f "$binary_tmp" "${INSTALL_DIR}/vaultwarden"

  web_tmp="$(mktemp -d "${INSTALL_DIR}/.web-vault.new.XXXXXX")"
  cp -a "${web_root}/." "$web_tmp/"
  chown -R root:root "$web_tmp"
  find "$web_tmp" -type d -exec chmod 0755 {} +
  find "$web_tmp" -type f -exec chmod 0644 {} +

  web_backup="${INSTALL_DIR}/.web-vault.previous.$$"
  if [[ -e "$WEB_VAULT_DIR" || -L "$WEB_VAULT_DIR" ]]; then
    mv "$WEB_VAULT_DIR" "$web_backup"
  fi
  if ! mv "$web_tmp" "$WEB_VAULT_DIR"; then
    if [[ -e "$web_backup" || -L "$web_backup" ]]; then
      mv "$web_backup" "$WEB_VAULT_DIR"
    fi
    rm -rf "$web_tmp"
    die 'Unable to install the web-vault files.'
  fi
  rm -rf "$web_backup"

  printf "VAULTWARDEN_VERSION='%s'\nWEB_VAULT_VERSION='%s'\n" \
    "$vaultwarden_tag" "$web_tag" > "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE"
  chown root:root "$VERSION_FILE"
}

start_systemd_service() {
  require_command systemctl
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    die 'Vaultwarden systemd service is not active.'
  fi
}

resolve_tls_enabled() {
  local config_file=$1
  if [[ -v VAULTWARDEN_TLS ]]; then
    normalize_boolean "$VAULTWARDEN_TLS"
  elif [[ -f "$config_file" ]]; then
    if config_has_key "$config_file" ROCKET_TLS; then
      printf 'true\n'
    else
      printf 'false\n'
    fi
  else
    printf 'true\n'
  fi
}

install_debian() {
  local mode=$1
  local port_override tls_override port tls_enabled vaultwarden_tag web_tag web_root source_dir
  port_override=false
  tls_override=false
  [[ -v VAULTWARDEN_PORT ]] && port_override=true
  [[ -v VAULTWARDEN_TLS ]] && tls_override=true
  port=${VAULTWARDEN_PORT:-8000}
  tls_enabled="$(resolve_tls_enabled "$ENV_FILE")"
  validate_port "$port" VAULTWARDEN_PORT

  export DEBIAN_FRONTEND=noninteractive
  log 'Installing Debian/Ubuntu build and runtime dependencies.'
  apt-get update
  apt-get install -y --no-install-recommends \
    argon2 build-essential ca-certificates curl gzip libmariadb-dev libpq-dev \
    libsqlite3-dev libssl-dev openssl pkg-config tar

  ensure_debian_user
  install -d -o root -g root -m 0755 "$INSTALL_DIR"
  prepare_build_dir
  vaultwarden_tag="$(resolve_release_tag "${VAULTWARDEN_VERSION:-}" \
    dani-garcia/vaultwarden Vaultwarden)"
  web_tag="$(resolve_release_tag "${WEB_VAULT_VERSION:-}" \
    dani-garcia/bw_web_builds web-vault)"
  web_root="$(download_and_build_debian "$vaultwarden_tag" "$web_tag")"
  source_dir="${BUILD_DIR}/source"

  if [[ "$mode" == update ]]; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fi
  deploy_debian_artifacts "$source_dir" "$web_root" "$vaultwarden_tag" "$web_tag"
  configure_debian "$port" "$tls_enabled" "$port_override" "$tls_override"
  write_systemd_unit
  start_systemd_service
  log "Vaultwarden ${vaultwarden_tag} is installed."
  log "Web vault ${web_tag} is installed in ${WEB_VAULT_DIR}."
  if [[ "$tls_enabled" == true ]]; then
    log "HTTPS is enabled by default with a self-signed certificate; use a reverse proxy for trusted TLS."
  else
    log 'HTTPS is disabled by configuration; place Vaultwarden behind a TLS reverse proxy.'
  fi
}

ensure_alpine_user() {
  if ! id -u vaultwarden >/dev/null 2>&1; then
    addgroup -S vaultwarden 2>/dev/null || true
    adduser -S -D -H -s /sbin/nologin -G vaultwarden vaultwarden
  fi
}

find_alpine_web_vault() {
  local candidate path found=''
  for candidate in \
    /usr/share/webapps/vaultwarden \
    /usr/share/vaultwarden/web-vault \
    /usr/share/vaultwarden/web-vaults; do
    if [[ -f "${candidate}/index.html" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  while IFS= read -r path; do
    case "$path" in
      */index.html)
        candidate=${path%/index.html}
        if [[ -f "$path" ]]; then
          found=$candidate
          break
        fi
        ;;
    esac
  done < <(apk info -L vaultwarden-web-vault 2>/dev/null || true)

  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

ensure_alpine_argon2() {
  if ! command -v argon2 >/dev/null 2>&1; then
    apk add --no-cache argon2 \
      || die 'The Alpine argon2 package could not be installed.'
  fi
}

configure_alpine() {
  local port=$1 tls_enabled=$2 port_override=$3 tls_override=$4 web_dir
  ensure_regular_file "$ALPINE_CONF" 0600
  install -d -o vaultwarden -g vaultwarden -m 0750 /var/lib/vaultwarden
  install -d -o root -g vaultwarden -m 0750 "$TLS_DIR"

  if [[ "$port_override" == true ]]; then
    upsert_config_key "$ALPINE_CONF" ROCKET_PORT "$port"
  else
    ensure_config_key "$ALPINE_CONF" ROCKET_PORT "$port"
  fi
  ensure_config_key "$ALPINE_CONF" ROCKET_ADDRESS '0.0.0.0'
  ensure_config_key "$ALPINE_CONF" DATA_FOLDER '/var/lib/vaultwarden'

  if web_dir="$(find_alpine_web_vault)"; then
    ensure_config_key "$ALPINE_CONF" WEB_VAULT_FOLDER "$web_dir"
  else
    warn 'Could not locate the Alpine web-vault package files; the package service default will be used.'
  fi

  if [[ -n "${VAULTWARDEN_DOMAIN:-}" ]]; then
    validate_no_newline "$VAULTWARDEN_DOMAIN" VAULTWARDEN_DOMAIN
    ensure_config_key "$ALPINE_CONF" DOMAIN "$VAULTWARDEN_DOMAIN"
  fi

  if [[ "$tls_enabled" == true ]]; then
    if ! config_has_key "$ALPINE_CONF" ROCKET_TLS; then
      create_tls_certificate
      upsert_config_key "$ALPINE_CONF" ROCKET_TLS \
        '{certs="/opt/vaultwarden/ssl/cert.pem",key="/opt/vaultwarden/ssl/key.pem"}'
    fi
  elif [[ "$tls_override" == true ]]; then
    remove_config_key "$ALPINE_CONF" ROCKET_TLS
  fi

  chmod 0600 "$ALPINE_CONF"
  chown root:root "$ALPINE_CONF"
  chown -R vaultwarden:vaultwarden /var/lib/vaultwarden
}

start_alpine_service() {
  require_command rc-update
  require_command rc-service
  rc-update add vaultwarden default >/dev/null
  if ! rc-service vaultwarden restart; then
    rc-service vaultwarden start
  fi
  if ! rc-service vaultwarden status; then
    die 'Vaultwarden OpenRC service is not active.'
  fi
}

install_alpine() {
  local mode=$1
  local port_override tls_override port tls_enabled
  port_override=false
  tls_override=false
  [[ -v VAULTWARDEN_PORT ]] && port_override=true
  [[ -v VAULTWARDEN_TLS ]] && tls_override=true
  port=${VAULTWARDEN_PORT:-8000}
  tls_enabled="$(resolve_tls_enabled "$ALPINE_CONF")"
  validate_port "$port" VAULTWARDEN_PORT

  log 'Installing Alpine Vaultwarden packages.'
  if [[ "$mode" == update ]]; then
    apk add --no-cache --upgrade vaultwarden vaultwarden-web-vault openssl ca-certificates curl
  else
    apk add --no-cache vaultwarden vaultwarden-web-vault openssl ca-certificates curl
  fi
  ensure_alpine_argon2
  ensure_alpine_user
  configure_alpine "$port" "$tls_enabled" "$port_override" "$tls_override"
  start_alpine_service
  log 'Vaultwarden is installed using the Alpine package and OpenRC service.'
  if [[ "$tls_enabled" == true ]]; then
    log 'HTTPS is enabled by default with a self-signed certificate; use a reverse proxy for trusted TLS.'
  else
    log 'HTTPS is disabled by configuration; place Vaultwarden behind a TLS reverse proxy.'
  fi
}

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
        die "Unsupported guest OS: ${id:-unknown}. Supported families are Debian/Ubuntu and Alpine."
      fi
      ;;
  esac
}

ensure_argon2() {
  if command -v argon2 >/dev/null 2>&1; then
    return 0
  fi
  case "$OS_FAMILY" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends argon2
      ;;
    alpine)
      apk add --no-cache argon2
      ;;
  esac
  command -v argon2 >/dev/null 2>&1 || die 'The argon2 command is unavailable.'
}

read_secret() {
  local prompt=$1 result_name=$2 value
  if [[ -r /dev/tty ]]; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r -s value </dev/tty || die 'Unable to read the admin token from the terminal.'
    printf '\n' >/dev/tty
  else
    [[ -t 0 ]] || die 'No interactive terminal is available; set VAULTWARDEN_ADMIN_TOKEN for non-interactive use.'
    IFS= read -r -s -p "$prompt" value || die 'Unable to read the admin token.'
    printf '\n' >&2
  fi
  printf -v "$result_name" '%s' "$value"
}

hash_admin_token() {
  local token=$1 salt hash
  salt="$(openssl rand -hex 16)" || die 'Unable to generate an Argon2 salt.'
  hash="$(
    printf '%s' "$token" |
      argon2 "$salt" -id -t 3 -m 16 -p 2 -l 32 -e |
      awk '/^\$argon2/ { print; found = 1; exit } END { exit(found ? 0 : 1) }'
  )" || die 'Unable to hash the admin token with Argon2id.'
  [[ "$hash" == '$argon2'* ]] || die 'The Argon2 command returned an invalid hash.'
  printf '%s\n' "$hash"
}

set_admin_token() {
  local token confirmation hash config_file
  require_root
  detect_os
  ensure_argon2
  require_command openssl

  if [[ -n "${VAULTWARDEN_ADMIN_TOKEN:-}" ]]; then
    token=$VAULTWARDEN_ADMIN_TOKEN
    unset VAULTWARDEN_ADMIN_TOKEN
  else
    read_secret 'New Vaultwarden admin token: ' token
    read_secret 'Repeat Vaultwarden admin token: ' confirmation
    [[ "$token" == "$confirmation" ]] || die 'The admin tokens do not match.'
    unset confirmation
  fi
  [[ -n "$token" ]] || die 'The admin token must not be empty.'
  hash="$(hash_admin_token "$token")"
  unset token

  case "$OS_FAMILY" in
    debian)
      config_file=$ENV_FILE
      [[ -f "$config_file" ]] || die 'Vaultwarden is not installed in this Debian/Ubuntu guest.'
      upsert_config_key "$config_file" ADMIN_TOKEN "$hash"
      systemctl restart "$SERVICE_NAME"
      ;;
    alpine)
      config_file=$ALPINE_CONF
      [[ -f "$config_file" ]] || die 'Vaultwarden is not installed in this Alpine guest.'
      upsert_config_key "$config_file" ADMIN_TOKEN "$hash"
      rc-service vaultwarden restart
      ;;
  esac
  log 'The admin token was updated; only its Argon2id hash was written to the configuration.'
}

status_guest() {
  local config_file port tls_state version_file
  detect_os
  case "$OS_FAMILY" in
    debian)
      config_file=$ENV_FILE
      if [[ -f "$config_file" ]]; then
        port="$(config_value "$config_file" ROCKET_PORT)" || port=8000
        if config_has_key "$config_file" ROCKET_TLS; then tls_state=enabled; else tls_state=disabled; fi
      else
        port=8000
        tls_state=unknown
      fi
      printf 'Platform: Debian/Ubuntu\n'
      printf 'Configured port: %s\n' "$port"
      printf 'Configured TLS: %s\n' "$tls_state"
      printf 'Installation directory: %s\n' "$INSTALL_DIR"
      if [[ -r "$VERSION_FILE" ]]; then
        grep -E '^(VAULTWARDEN_VERSION|WEB_VAULT_VERSION)=' "$VERSION_FILE" || true
      fi
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status "$SERVICE_NAME" || true
      fi
      ;;
    alpine)
      config_file=$ALPINE_CONF
      if [[ -f "$config_file" ]]; then
        port="$(config_value "$config_file" ROCKET_PORT)" || port=8000
        if config_has_key "$config_file" ROCKET_TLS; then tls_state=enabled; else tls_state=disabled; fi
      else
        port=8000
        tls_state=unknown
      fi
      printf 'Platform: Alpine\n'
      printf 'Configured port: %s\n' "$port"
      printf 'Configured TLS: %s\n' "$tls_state"
      printf 'Data directory: /var/lib/vaultwarden\n'
      if command -v rc-service >/dev/null 2>&1; then
        rc-service vaultwarden status || true
      fi
      ;;
  esac
}

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
  if [[ -v VAULTWARDEN_PORT ]]; then
    guest_env+=("VAULTWARDEN_PORT=${VAULTWARDEN_PORT}")
  fi
  if [[ -v VAULTWARDEN_TLS ]]; then
    guest_env+=("VAULTWARDEN_TLS=${VAULTWARDEN_TLS}")
  fi
  if [[ -v VAULTWARDEN_TLS_COMMON_NAME ]]; then
    guest_env+=("VAULTWARDEN_TLS_COMMON_NAME=${VAULTWARDEN_TLS_COMMON_NAME}")
  fi
  if [[ -v VAULTWARDEN_DOMAIN ]]; then
    guest_env+=("VAULTWARDEN_DOMAIN=${VAULTWARDEN_DOMAIN}")
  fi
  if [[ -v VAULTWARDEN_VERSION ]]; then
    guest_env+=("VAULTWARDEN_VERSION=${VAULTWARDEN_VERSION}")
  fi
  if [[ -v WEB_VAULT_VERSION ]]; then
    guest_env+=("WEB_VAULT_VERSION=${WEB_VAULT_VERSION}")
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
  ' vaultwarden-lxd "$action" < "$script_path"
}

host_create() {
  local name image port tls_value proxy proxy_port proxy_listen proxy_device ip scheme url
  require_command lxc

  name=${LXD_CONTAINER:-vaultwarden}
  image=${LXD_IMAGE:-images:debian/13}
  port=${VAULTWARDEN_PORT:-8000}
  validate_port "$port" VAULTWARDEN_PORT
  proxy="$(normalize_boolean "${LXD_PROXY:-false}")"
  proxy_port=${LXD_PROXY_PORT:-$port}
  proxy_listen=${LXD_PROXY_LISTEN:-0.0.0.0}
  proxy_device=${LXD_PROXY_DEVICE:-vaultwarden-proxy}
  tls_value="$(normalize_boolean "${VAULTWARDEN_TLS:-true}")"
  validate_lxd_container_name "$name"

  if host_container_exists "$name"; then
    host_start_existing_container "$name"
  else
    log "Launching ${name} from ${image}."
    lxc launch "$image" "$name"
    host_wait_for_exec "$name"
  fi

  log "Installing Vaultwarden inside ${name}."
  host_run_guest_action "$name" --install

  if [[ "$proxy" == true ]]; then
    host_configure_proxy "$name" "$proxy_listen" "$proxy_port" "$proxy_device" "$port"
  fi

  ip="$(lxc list "$name" --format csv -c 4 2>/dev/null | \
    tr ',' '\n' | awk '/^[0-9]+\./ { print; exit }' || true)"
  scheme=http
  [[ "$tls_value" == true ]] && scheme=https
  if [[ "$proxy" == true ]]; then
    url="${scheme}://127.0.0.1:${proxy_port}"
  elif [[ -n "$ip" ]]; then
    url="${scheme}://${ip}:${port}"
  else
    url="${scheme}://${name}:${port}"
  fi

  printf '\nVaultwarden LXD container is ready.\n'
  printf 'Container: %s\n' "$name"
  [[ -n "$ip" ]] && printf 'IPv4 address: %s\n' "$ip"
  printf 'URL: %s\n' "$url"
  if [[ "$tls_value" == true ]]; then
    printf 'TLS note: the default certificate is self-signed.\n'
  fi
}

host_update() {
  local name
  require_command lxc

  name=${LXD_CONTAINER:-vaultwarden}
  validate_lxd_container_name "$name"
  host_start_existing_container "$name"
  log "Updating Vaultwarden inside ${name}."
  host_run_guest_action "$name" --update
  log "Vaultwarden update completed in ${name}."
}

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
      require_root
      detect_os
      case "$OS_FAMILY" in
        debian) install_debian "${action#--}" ;;
        alpine) install_alpine "${action#--}" ;;
      esac
      ;;
    --set-admin-token)
      [[ "$#" -eq 1 ]] || die '--set-admin-token does not accept additional arguments.'
      set_admin_token
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
