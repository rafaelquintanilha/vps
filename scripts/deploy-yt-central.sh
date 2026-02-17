#!/bin/bash

set -euo pipefail

REPO_DIR="/opt/apps/apps/yt-central"
COMPOSE_DIR="/opt/apps"
LOG_FILE="/opt/apps/runtime/logs/yt-central-deploy.log"
RUN_DB_PUSH="${RUN_DB_PUSH:-false}"

log() {
  echo "[$(date +%Y-%m-%d %H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

log "========================================="
log "Starting YT Central deployment"
log "========================================="

cd "$REPO_DIR"

log "Fetching latest code..."
git fetch origin master

CURRENT_COMMIT="$(git rev-parse HEAD)"
TARGET_COMMIT="$(git rev-parse origin/master)"

if ! git diff --quiet || ! git diff --cached --quiet; then
  log "Local tracked changes detected; resetting to origin/master"
fi

# Force working tree to exact remote master commit to avoid VPS-local drift
# breaking deploys (e.g. bun.lock mutation on server).
git reset --hard "$TARGET_COMMIT"
git clean -fd

if [ "$CURRENT_COMMIT" != "$TARGET_COMMIT" ]; then
  log "Updated from $CURRENT_COMMIT to $TARGET_COMMIT"
else
  log "Already up to date ($CURRENT_COMMIT)"
fi

if [ "$RUN_DB_PUSH" = "true" ]; then
  log "Running database schema push..."
  bun run db:push
fi

cd "$COMPOSE_DIR"

log "Rebuilding and restarting services..."
docker compose up -d --build yt-central yt-central-cron

log "Verifying health endpoint..."
for attempt in $(seq 1 30); do
  HTTP_CODE="$(curl -sS -o /dev/null -w %{http_code} https://yt.rafaelquintanilha.com/healthz || true)"
  if [ "$HTTP_CODE" = "200" ]; then
    log "Health check passed"
    log "Deployment completed successfully"
    exit 0
  fi

  log "Health check attempt $attempt/30 failed (HTTP $HTTP_CODE)"
  sleep 5
done

log "ERROR: Health check failed after 30 attempts"
exit 1
