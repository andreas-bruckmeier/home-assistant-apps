#!/bin/bash
set -o pipefail

HOST_TAG="homeassistant"
OPTIONS=/data/options.json

# ---------- helpers ----------
cfg()  { jq -r ".${1} // empty" "$OPTIONS"; }
log()  { echo "[$(date '+%F %T')] INFO: $*"; }
warn() { echo "[$(date '+%F %T')] WARNING: $*"; }
err()  { echo "[$(date '+%F %T')] ERROR: $*" >&2; }

notify() {
  local msg="$1" url payload svc
  payload="$(jq -n --arg t "Restic backup" --arg m "$msg" '{title:$t, message:$m}')"
  svc="$(cfg notify_service)"
  if [[ -n "$svc" ]]; then
    url="http://supervisor/core/api/services/notify/${svc#notify.}"
  else
    url="http://supervisor/core/api/services/persistent_notification/create"
  fi
  curl -sf -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" "$url" >/dev/null \
    || warn "Could not send notification"
}

fail() {
  err "$1"
  notify "Backup FAILED: $1"
  exit 1
}

# ---------- configuration ----------
export RESTIC_REPOSITORY="$(cfg repository)"
export RESTIC_PASSWORD="$(cfg password)"
export RESTIC_CACHE_DIR=/data/cache
export RCLONE_CONFIG=/config/rclone/rclone.conf

[[ -n "$RESTIC_REPOSITORY" ]] || fail "No repository configured"
[[ -n "$RESTIC_PASSWORD"   ]] || fail "No password configured"

# Login for a REST server (rest-server / rclone serve restic)
[[ -n "$(cfg rest_username)" ]] && export RESTIC_REST_USERNAME="$(cfg rest_username)"
[[ -n "$(cfg rest_password)" ]] && export RESTIC_REST_PASSWORD="$(cfg rest_password)"

# Extra environment variables, e.g. B2_ACCOUNT_ID=..., AWS_ACCESS_KEY_ID=...
while IFS= read -r kv; do
  [[ "$kv" == *=* ]] && export "${kv?}"
done < <(jq -r '.env[]? // empty' "$OPTIONS")

mkdir -p /data/cache /config/ssh /config/rclone /root/.ssh

# ---------- SFTP: key handling ----------
if [[ "$RESTIC_REPOSITORY" == sftp:* ]]; then
  if [[ ! -f /config/ssh/id_ed25519 ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "homeassistant-restic" -f /config/ssh/id_ed25519
    PUB="$(cat /config/ssh/id_ed25519.pub)"
    warn "Generated a new SSH key. Add this line to authorized_keys on the remote server:"
    warn "$PUB"
    notify "New SSH key generated. Add it to authorized_keys on the server, then run again: ${PUB}"
    exit 0
  fi
  chmod 600 /config/ssh/id_ed25519
  cat > /root/.ssh/config <<SSHCFG
Host *
  IdentityFile /config/ssh/id_ed25519
  UserKnownHostsFile /config/ssh/known_hosts
  StrictHostKeyChecking accept-new
  ServerAliveInterval 60
SSHCFG
fi

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

# ---------- retention ----------
log "Applying retention policy and pruning..."
restic forget --host "$HOST_TAG" --tag homeassistant \
  --keep-daily   "$(cfg keep_daily)" \
  --keep-weekly  "$(cfg keep_weekly)" \
  --keep-monthly "$(cfg keep_monthly)" \
  --prune || fail "forget/prune failed"

# ---------- optional integrity check ----------
if [[ "$(cfg run_check)" == "true" ]]; then
  log "Checking repository..."
  restic check || fail "Repository check reported errors"
fi

log "Done."
restic stats --mode raw-data 2>/dev/null | tail -n 3 || true
