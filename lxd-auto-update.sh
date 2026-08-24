#!/usr/bin/env bash
#
# Auto-update script for LXD containers managed by the *-lxd.sh installers.
#
# This script runs --update-container for each configured service, logging
# results and optionally sending notifications on failure.
#
# Usage:
#   ./lxd-auto-update.sh                  # Update all configured services
#   ./lxd-auto-update.sh --install-timer  # Install a systemd timer to run daily
#   ./lxd-auto-update.sh --install-cron   # Install a daily cron job instead
#   ./lxd-auto-update.sh --remove-timer   # Remove the systemd timer
#   ./lxd-auto-update.sh --remove-cron    # Remove the cron job
#   ./lxd-auto-update.sh --status         # Show timer/cron status
#   ./lxd-auto-update.sh --help           # Show this help
#
# Configuration:
#   Edit the SERVICES array below to control which containers are updated.
#   Each entry is: "SCRIPT_PATH:CONTAINER_NAME"
#
# Environment variables:
#   AUTO_UPDATE_LOG=/var/log/lxd-auto-update.log   Log file path.
#   AUTO_UPDATE_ON_FAILURE=                        Command to run on failure (e.g. a notification script).
#   AUTO_UPDATE_HOUR=3                             Hour (0-23) for the systemd timer / cron schedule.
#   AUTO_UPDATE_MINUTE=30                          Minute (0-59) for the schedule.

set -Eeuo pipefail

# --- Configuration ---
# Each entry: "path/to/script.sh:container_name"
# Adjust paths to match your installation.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVICES=(
  "${SCRIPT_DIR}/vaultwarden-lxd.sh:vaultwarden"
  "${SCRIPT_DIR}/forgejo-lxd.sh:forgejo"
  "${SCRIPT_DIR}/forgejo-runner-lxd.sh:forgejo-runner"
)

readonly LOG_FILE="${AUTO_UPDATE_LOG:-/var/log/lxd-auto-update.log}"
readonly ON_FAILURE="${AUTO_UPDATE_ON_FAILURE:-}"
readonly TIMER_HOUR="${AUTO_UPDATE_HOUR:-3}"
readonly TIMER_MINUTE="${AUTO_UPDATE_MINUTE:-30}"
readonly TIMER_NAME="lxd-auto-update"
readonly TIMER_UNIT="/etc/systemd/system/${TIMER_NAME}.timer"
readonly SERVICE_UNIT="/etc/systemd/system/${TIMER_NAME}.service"
readonly CRON_ID="# lxd-auto-update"
readonly SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

log() {
  local msg
  msg="$(date '+%Y-%m-%d %H:%M:%S') [auto-update] $*"
  printf '%s\n' "$msg"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

die() {
  printf '[auto-update] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
LXD Auto-Update Script

Commands:
  (no arguments)              Run updates for all configured services now.
  --install-timer             Install a systemd timer for daily automatic updates.
  --install-cron              Install a daily cron job for automatic updates.
  --remove-timer              Remove the systemd timer.
  --remove-cron               Remove the cron job.
  --status                    Show the current auto-update schedule status.
  --help                      Show this help.

Configuration:
  Edit the SERVICES array at the top of this script to add/remove containers.
  Each entry format: "path/to/installer-script.sh:container-name"

Environment:
  AUTO_UPDATE_LOG             Log file (default: /var/log/lxd-auto-update.log)
  AUTO_UPDATE_ON_FAILURE      Command to run if any update fails
  AUTO_UPDATE_HOUR            Hour for scheduled updates (default: 3)
  AUTO_UPDATE_MINUTE          Minute for scheduled updates (default: 30)
EOF
}

# --- Update logic ---

run_updates() {
  local entry script container failures=0 total=0

  log "Starting auto-update run."

  for entry in "${SERVICES[@]}"; do
    script="${entry%%:*}"
    container="${entry##*:}"
    total=$((total + 1))

    if [[ ! -x "$script" ]]; then
      if [[ -f "$script" ]]; then
        chmod +x "$script"
      else
        log "SKIP: Script not found: ${script}"
        failures=$((failures + 1))
        continue
      fi
    fi

    log "Updating ${container} via ${script}."
    if LXD_CONTAINER="$container" "$script" --update-container >> "$LOG_FILE" 2>&1; then
      log "SUCCESS: ${container} updated."
    else
      log "FAILED: ${container} update returned non-zero."
      failures=$((failures + 1))
    fi
  done

  if (( failures > 0 )); then
    log "Completed with ${failures}/${total} failure(s)."
    if [[ -n "$ON_FAILURE" ]]; then
      eval "$ON_FAILURE" || true
    fi
    return 1
  else
    log "All ${total} service(s) updated successfully."
    return 0
  fi
}

# --- Timer installation ---

install_timer() {
  [[ "${EUID}" -eq 0 ]] || die "Installing a systemd timer requires root."

  cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=LXD container auto-update

[Service]
Type=oneshot
ExecStart=${SELF_PATH}
Environment=AUTO_UPDATE_LOG=${LOG_FILE}
EOF

  cat > "$TIMER_UNIT" <<EOF
[Unit]
Description=Daily LXD container auto-update

[Timer]
OnCalendar=*-*-* ${TIMER_HOUR}:${TIMER_MINUTE}:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  chmod 0644 "$SERVICE_UNIT" "$TIMER_UNIT"
  systemctl daemon-reload
  systemctl enable --now "${TIMER_NAME}.timer"
  log "Systemd timer installed: daily at ${TIMER_HOUR}:${TIMER_MINUTE} (with up to 5 min jitter)."
  systemctl --no-pager status "${TIMER_NAME}.timer" || true
}

remove_timer() {
  [[ "${EUID}" -eq 0 ]] || die "Removing a systemd timer requires root."
  systemctl disable --now "${TIMER_NAME}.timer" 2>/dev/null || true
  rm -f "$TIMER_UNIT" "$SERVICE_UNIT"
  systemctl daemon-reload
  log "Systemd timer removed."
}

# --- Cron installation ---

install_cron() {
  [[ "${EUID}" -eq 0 ]] || die "Installing a cron job requires root."
  local cron_line="${TIMER_MINUTE} ${TIMER_HOUR} * * * root ${SELF_PATH} >> ${LOG_FILE} 2>&1 ${CRON_ID}"
  local cron_file="/etc/cron.d/lxd-auto-update"

  cat > "$cron_file" <<EOF
# LXD container auto-update - managed by lxd-auto-update.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${cron_line}
EOF
  chmod 0644 "$cron_file"
  log "Cron job installed: daily at ${TIMER_HOUR}:${TIMER_MINUTE}."
  log "Cron file: ${cron_file}"
}

remove_cron() {
  [[ "${EUID}" -eq 0 ]] || die "Removing a cron job requires root."
  rm -f /etc/cron.d/lxd-auto-update
  log "Cron job removed."
}

# --- Status ---

show_status() {
  printf 'Configured services:\n'
  local entry script container
  for entry in "${SERVICES[@]}"; do
    script="${entry%%:*}"
    container="${entry##*:}"
    local exists="missing"
    [[ -f "$script" ]] && exists="found"
    printf '  %-20s  script: %s (%s)\n' "$container" "$script" "$exists"
  done
  printf '\n'

  if [[ -f "$TIMER_UNIT" ]] && systemctl is-enabled "${TIMER_NAME}.timer" >/dev/null 2>&1; then
    printf 'Systemd timer: active\n'
    systemctl --no-pager list-timers "${TIMER_NAME}.timer" 2>/dev/null || true
  elif [[ -f /etc/cron.d/lxd-auto-update ]]; then
    printf 'Cron job: active\n'
    cat /etc/cron.d/lxd-auto-update
  else
    printf 'Schedule: not installed (run --install-timer or --install-cron)\n'
  fi

  if [[ -f "$LOG_FILE" ]]; then
    printf '\nLast 10 log entries:\n'
    tail -10 "$LOG_FILE"
  fi
}

# --- Main ---

main() {
  local action=${1:-run}
  case "$action" in
    run|"")
      run_updates
      ;;
    --install-timer)
      install_timer
      ;;
    --install-cron)
      install_cron
      ;;
    --remove-timer)
      remove_timer
      ;;
    --remove-cron)
      remove_cron
      ;;
    --status)
      show_status
      ;;
    --help|-h)
      usage
      ;;
    *)
      die "Unknown option: ${action}. Use --help for usage."
      ;;
  esac
}

main "$@"
