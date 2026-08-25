# LXD Container Installers

Self-contained Bash scripts for deploying and managing applications inside LXD containers. Each script handles host-side orchestration (launching containers, proxy devices) and guest-side operations (installing, updating, configuring services).

These are independent LXD adaptations informed by the [Community Scripts](https://github.com/community-scripts/ProxmoxVE) Proxmox installers (MIT-licensed).

## Scripts

| Script | Application | Default Port | Guest OS |
|--------|-------------|--------------|----------|
| `vaultwarden-lxd.sh` | [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | 8000 | Debian/Ubuntu, Alpine |
| `forgejo-lxd.sh` | [Forgejo](https://forgejo.org/) | 3000 | Debian/Ubuntu, Alpine |
| `forgejo-runner-lxd.sh` | [Forgejo Runner](https://code.forgejo.org/forgejo/runner) | N/A | Debian/Ubuntu |
| `pocketbase-lxd.sh` | [PocketBase](https://pocketbase.io/) | 8080 | Debian/Ubuntu, Alpine |
| `metabase-lxd.sh` | [Metabase](https://www.metabase.com/) | 3000 | Debian/Ubuntu |
| `valkey-lxd.sh` | [Valkey](https://valkey.io/) | 6379 | Debian/Ubuntu, Alpine |
| `postgresql-lxd.sh` | [PostgreSQL](https://www.postgresql.org/) | 5432 | Debian/Ubuntu, Alpine |
| `lxd-auto-update.sh` | Auto-updater | N/A | LXD host only |

## Requirements

- An LXD host with `lxc` CLI available
- Bash 4.4+ on the host
- Internet access for downloading releases

## Supported Guest Operating Systems

- **Ubuntu 26.04** (default)
- **Debian 13** (use `LXD_IMAGE=images:debian/13`)
- **Alpine** (where noted per script; use `LXD_IMAGE=images:alpine/3.24`)

## Quick Start

```bash
# Make scripts executable
chmod +x *.sh

# Create a Vaultwarden container with a host proxy
LXD_PROXY=true ./vaultwarden-lxd.sh --create

# Create a Forgejo container
./forgejo-lxd.sh --create

# Create a Forgejo Runner (requires registration params)
FORGEJO_INSTANCE=https://codeberg.org \
  FORGEJO_RUNNER_UUID=your-uuid \
  FORGEJO_RUNNER_TOKEN=your-token \
  ./forgejo-runner-lxd.sh --create

# Create a PocketBase container
./pocketbase-lxd.sh --create

# Create a Metabase container
./metabase-lxd.sh --create

# Create a Valkey container
LXD_PROXY=true ./valkey-lxd.sh --create

# Create a PostgreSQL container
PG_VERSION=17 LXD_PROXY=true ./postgresql-lxd.sh --create
```

## Common Commands

Each script supports the same interface pattern:

### Host Operations (run on the LXD host)

```bash
# Create and install
./script-lxd.sh --create

# Update an existing container
LXD_CONTAINER=name ./script-lxd.sh --update-container
```

### Guest Operations (run inside the container)

```bash
# Install (piped into the container)
lxc exec container -- bash -s -- --install < script-lxd.sh

# Update
lxc exec container -- bash -s -- --update < script-lxd.sh

# Check status
lxc exec container -- bash -s -- --status < script-lxd.sh

# Show help
lxc exec container -- bash -s -- --help < script-lxd.sh
```

## Auto-Updates

The `lxd-auto-update.sh` script provides automatic daily updates for configured containers.

```bash
# Install a systemd timer (runs daily at 03:30)
sudo ./lxd-auto-update.sh --install-timer

# Or use cron instead
sudo ./lxd-auto-update.sh --install-cron

# Run updates immediately
./lxd-auto-update.sh

# Check schedule status
./lxd-auto-update.sh --status

# Remove the timer
sudo ./lxd-auto-update.sh --remove-timer
```

### Configuration

Edit the `SERVICES` array at the top of `lxd-auto-update.sh`:

```bash
SERVICES=(
  "${SCRIPT_DIR}/vaultwarden-lxd.sh:vaultwarden"
  "${SCRIPT_DIR}/forgejo-lxd.sh:forgejo"
  "${SCRIPT_DIR}/forgejo-runner-lxd.sh:forgejo-runner"
)
```

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_UPDATE_HOUR` | `3` | Hour for scheduled updates |
| `AUTO_UPDATE_MINUTE` | `30` | Minute for scheduled updates |
| `AUTO_UPDATE_LOG` | `/var/log/lxd-auto-update.log` | Log file path |
| `AUTO_UPDATE_ON_FAILURE` | (empty) | Command to run on failure |

## Environment Variables

### Host Variables (shared across scripts)

| Variable | Default | Description |
|----------|---------|-------------|
| `LXD_CONTAINER` | (per script) | Container name |
| `LXD_IMAGE` | `images:ubuntu/26.04` | LXD image for `--create` (also supports `images:debian/13`, `images:alpine/3.24`) |
| `LXD_STATIC_IP` | `true` | Convert DHCP-assigned IP to a static configuration on new containers |
| `LXD_PROXY` | `false` | Add an LXD proxy device |
| `LXD_PROXY_LISTEN` | `0.0.0.0` | Proxy listen address |
| `LXD_PROXY_PORT` | (per script) | Proxy host port |
| `LXD_PROXY_DEVICE` | (per script) | Proxy device name |

### Per-Script Variables

See each script's `--help` output for application-specific variables (ports, versions, credentials, TLS options, etc.).

## Script Details

### vaultwarden-lxd.sh

- Compiles Vaultwarden from source on Debian (sqlite+mysql+postgresql features)
- Uses Alpine packages on Alpine guests
- Self-signed TLS by default (configurable via `VAULTWARDEN_TLS`)
- Admin token stored as Argon2id hash only (`--set-admin-token`)
- Data preserved in `/opt/vaultwarden/data` across updates

### forgejo-lxd.sh

- Debian: downloads prebuilt binary from Codeberg releases
- Alpine: installs via `apk`
- Creates `git` system user; repos stored in `/var/lib/forgejo`
- Configuration at `/etc/forgejo/app.ini` (generated on first web access)
- Handles legacy `GITEA_WORK_DIR` migration automatically

### forgejo-runner-lxd.sh

- Requires registration parameters: `FORGEJO_INSTANCE`, `FORGEJO_RUNNER_UUID`, `FORGEJO_RUNNER_TOKEN`
- Installs Podman for container-based CI jobs
- Container launched with `security.nesting=true` for Podman support
- Configuration at `/etc/forgejo-runner/config.yaml` (token stored mode 0600)

### pocketbase-lxd.sh

- Downloads prebuilt Go binary from GitHub releases
- Auto-detects amd64/arm64 architecture
- Data in `/opt/pocketbase/pb_data` preserved across updates
- Skips update if already at target version

### metabase-lxd.sh

- Installs OpenJDK 21 and PostgreSQL 17
- Creates `metabase_db` database automatically
- Credentials stored in `/opt/metabase/.env` (mode 0600)
- Updates replace only the jar file; database and config preserved
- Metabase may take 1-2 minutes to start on first boot

### valkey-lxd.sh

- Installs via apt (Debian) or apk (Alpine)
- Auto-generates random password stored in `/root/valkey.creds`
- Memory tuned to 75% of container RAM with `allkeys-lru` eviction
- Optional TLS with self-signed cert (`VALKEY_TLS=true`)
- Bind address configurable via `--set-bind`

### postgresql-lxd.sh

- Installs from official PGDG repository (Debian) or apk (Alpine)
- Version selectable: `PG_VERSION=15|16|17|18` (Alpine: 15-17)
- Auto-generates random superuser password stored in `/root/postgresql.creds`
- Configured for remote access out of the box (`listen_addresses='*'`, md5 auth)
- SSL enabled by default (Debian snakeoil cert)
- `shared_buffers=128MB`, `max_connections=100`, WAL tuned
- Optional Adminer web UI via `PG_ADMINER=true` (Apache on Debian, lighttpd on Alpine)
- Data preserved across updates (`/var/lib/postgresql` untouched)

## Design Principles

- **Self-contained**: Each script is a single file with no external dependencies beyond standard system tools.
- **Idempotent**: Safe to re-run. Existing data and configuration are preserved.
- **Updateable**: `--update` / `--update-container` replaces only application artifacts, never touching user data.
- **Stable IPs**: On `--create`, the DHCP-assigned IP is automatically converted to a static configuration so the container address never changes after a reboot. Disable with `LXD_STATIC_IP=false`.
- **Secure defaults**: Credentials are never logged, tokens are hashed, config files are mode 0600, TLS is enabled where applicable.
- **Dual-use**: Each script works both from the LXD host (orchestration) and inside a guest (direct installation).

## License

MIT License. See [LICENSE](LICENSE) for details.

These scripts are independently written. The upstream Community Scripts project that inspired them is MIT-licensed: https://github.com/community-scripts/ProxmoxVE/blob/main/LICENSE
