#!/bin/bash
set -o pipefail

HOST_TAG="homeassistant"
OPTIONS=/data/options.json

# ---------- helpers ----------
cfg()  { jq -r ".${1} // empty" "$OPTIONS"; }
log()  { echo "[$(date '+%F %T')] INFO: $*"; }
warn() { echo "[$(date '+%F %T')] WARNING: $*"; }
err()  { echo "[$(date '+%F %T')] ERROR: $*" >&2; }

ha_post() {
  # ha_post <api path> <json payload>
  curl -sf -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$2" "http://supervisor/core/api/$1" >/dev/null
}

notify() {
  # notify_service: "script.benachrichtigung", "notify.mobile_app_x" or "mobile_app_x"
  local svc payload
  payload="$(jq -n --arg t "Restic-Backup" --arg m "$1" '{title:$t, message:$m}')"
  svc="$(cfg notify_service)"
  if [[ -n "$svc" ]]; then
    [[ "$svc" == *.* ]] || svc="notify.${svc}"
    ha_post "services/${svc%%.*}/${svc#*.}" "$payload" || warn "Could not send notification via ${svc}"
  else
    ha_post "services/persistent_notification/create" "$payload" || warn "Could not send notification"
  fi
}

report_success() {
  # Creates/updates sensor.restic_last_backup so HA can detect stale backups
  local payload
  payload="$(jq -n --arg s "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
    '{state:$s, attributes:{device_class:"timestamp", friendly_name:"Restic letztes Backup", icon:"mdi:cloud-check"}}')"
  ha_post "states/sensor.restic_last_backup" "$payload" || warn "Could not update sensor.restic_last_backup"
}

fail() {
  err "$1"
  notify "Fehlgeschlagen: $1"
  exit 1
}

# ---------- configuration ----------
export RESTIC_REPOSITORY="$(cfg repository)"
export RESTIC_PASSWORD="$(cfg password)"
export RESTIC_CACHE_DIR=/data/cache

[[ -n "$RESTIC_REPOSITORY" ]] || fail "No repository configured"
[[ -n "$RESTIC_PASSWORD"   ]] || fail "No password configured"

[[ -n "$(cfg rest_username)" ]] && export RESTIC_REST_USERNAME="$(cfg rest_username)"
[[ -n "$(cfg rest_password)" ]] && export RESTIC_REST_PASSWORD="$(cfg rest_password)"

mkdir -p /data/cache

# ---------- repository ----------
if ! restic cat config >/dev/null 2>&1; then
  log "Repository not found, initialising..."
  restic init || fail "Could not open or initialise repository (unreachable, wrong password, or bad credentials?)"
fi

restic unlock >/dev/null 2>&1 || true

# ---------- backup ----------
log "Backing up /backup ..."
restic backup /backup --host "$HOST_TAG" --tag homeassistant
rc=$?
if [[ $rc -eq 3 ]]; then
  warn "Some files could not be read, snapshot was still created"
elif [[ $rc -ne 0 ]]; then
  fail "restic backup exited with code $rc"
fi

# ---------- optional integrity check ----------
if [[ "$(cfg run_check)" == "true" ]]; then
  log "Checking repository..."
  restic check || fail "Repository check reported errors"
fi

log "Done."
report_success
