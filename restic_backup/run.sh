#!/usr/bin/env bashio
# shellcheck shell=bash
set -o pipefail

HOST_TAG="homeassistant"

# ---------- helpers ----------
notify() {
  local msg="$1" url payload
  payload="$(jq -n --arg t "Restic backup" --arg m "$msg" '{title:$t, message:$m}')"
  if bashio::config.has_value 'notify_service'; then
    local svc
    svc="$(bashio::config 'notify_service')"
    url="http://supervisor/core/api/services/notify/${svc#notify.}"
  else
    url="http://supervisor/core/api/services/persistent_notification/create"
  fi
  curl -sf -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" "$url" >/dev/null \
    || bashio::log.warning "Could not send notification"
}

fail() {
  bashio::log.error "$1"
  notify "Backup FAILED: $1"
  exit 1
}

# ---------- configuration ----------
export RESTIC_REPOSITORY="$(bashio::config 'repository')"
export RESTIC_PASSWORD="$(bashio::config 'password')"
export RESTIC_CACHE_DIR=/data/cache
export RCLONE_CONFIG=/config/rclone/rclone.conf

bashio::config.has_value 'repository' || fail "No repository configured"
bashio::config.has_value 'password'   || fail "No password configured"

# Extra environment variables, e.g. B2_ACCOUNT_ID=..., AWS_ACCESS_KEY_ID=...
if bashio::config.has_value 'env'; then
  while IFS= read -r kv; do
    [[ "$kv" == *=* ]] && export "${kv?}"
  done <<< "$(bashio::config 'env')"
fi

mkdir -p /data/cache /config/ssh /config/rclone /root/.ssh

# ---------- SFTP: key handling ----------
if [[ "$RESTIC_REPOSITORY" == sftp:* ]]; then
  if [[ ! -f /config/ssh/id_ed25519 ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "homeassistant-restic" -f /config/ssh/id_ed25519
    PUB="$(cat /config/ssh/id_ed25519.pub)"
    bashio::log.warning "Generated a new SSH key. Add this line to authorized_keys on the remote server:"
    bashio::log.warning "$PUB"
    notify "New SSH key generated. Add it to authorized_keys on the server, then run again: ${PUB}"
    exit 0
  fi
  chmod 600 /config/ssh/id_ed25519
  cat > /root/.ssh/config <<EOF
Host *
  IdentityFile /config/ssh/id_ed25519
  UserKnownHostsFile /config/ssh/known_hosts
  StrictHostKeyChecking accept-new
  ServerAliveInterval 60
EOF
fi

# ---------- repository ----------
if ! restic cat config >/dev/null 2>&1; then
  bashio::log.info "Repository not found, initialising..."
  restic init || fail "Could not open or initialise repository (unreachable, wrong password, or bad credentials?)"
fi

restic unlock >/dev/null 2>&1 || true

# ---------- backup ----------
bashio::log.info "Backing up /backup ..."
restic backup /backup --host "$HOST_TAG" --tag homeassistant
rc=$?
if [[ $rc -eq 3 ]]; then
  bashio::log.warning "Some files could not be read, snapshot was still created"
elif [[ $rc -ne 0 ]]; then
  fail "restic backup exited with code $rc"
fi

# ---------- retention ----------
bashio::log.info "Applying retention policy and pruning..."
restic forget --host "$HOST_TAG" --tag homeassistant \
  --keep-daily  "$(bashio::config 'keep_daily')" \
  --keep-weekly "$(bashio::config 'keep_weekly')" \
  --keep-monthly "$(bashio::config 'keep_monthly')" \
  --prune || fail "forget/prune failed"

# ---------- optional integrity check ----------
if bashio::config.true 'run_check'; then
  bashio::log.info "Checking repository..."
  restic check || fail "Repository check reported errors"
fi

bashio::log.info "Done."
restic stats --mode raw-data 2>/dev/null | tail -n 3 || true
