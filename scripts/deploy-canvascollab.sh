#!/bin/bash

set -euo pipefail

REPO_DIR="/opt/apps/apps/canvascollab"
COMPOSE_DIR="/opt/apps"
LOG_FILE="/opt/apps/runtime/logs/canvascollab-deploy.log"
REPO_URL="https://github.com/rafaelquintanilha/canvascollab.git"
BRANCH="${CANVASCOLLAB_BRANCH:-main}"
HOST_PORT="${CANVASCOLLAB_PORT:-3004}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

mkdir -p "$(dirname "$LOG_FILE")" /opt/apps/apps

log "========================================="
log "Starting Canvascollab deployment"
log "========================================="

if [ ! -d "$REPO_DIR/.git" ]; then
  log "Cloning Canvascollab repository..."
  git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

log "Fetching latest code..."
git fetch origin "$BRANCH"

CURRENT_COMMIT="$(git rev-parse HEAD)"
TARGET_COMMIT="$(git rev-parse "origin/$BRANCH")"

if ! git diff --quiet || ! git diff --cached --quiet; then
  log "Local tracked changes detected; resetting to origin/$BRANCH"
fi

git reset --hard "$TARGET_COMMIT"
git clean -fd

if [ "$CURRENT_COMMIT" != "$TARGET_COMMIT" ]; then
  log "Updated from $CURRENT_COMMIT to $TARGET_COMMIT"
else
  log "Already up to date ($CURRENT_COMMIT)"
fi

cd "$COMPOSE_DIR"

log "Rebuilding and restarting Canvascollab..."
docker compose up -d --build canvascollab

log "Reloading Caddy..."
docker compose up -d caddy
docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile

log "Verifying local health endpoint..."
for attempt in $(seq 1 30); do
  HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/healthz" || true)"
  if [ "$HTTP_CODE" = "200" ]; then
    log "Health check passed"
    log "Deployment completed successfully"
    exit 0
  fi

  log "Health check attempt $attempt/30 failed (HTTP $HTTP_CODE)"
  sleep 5
done

log "ERROR: Health check failed after 30 attempts"
docker compose logs --tail=120 canvascollab | tee -a "$LOG_FILE"
exit 1
