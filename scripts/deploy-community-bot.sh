#!/bin/bash

set -euo pipefail

REPO_DIR="/opt/apps/apps/community-bot"
REPO_URL="git@github.com:rafaelquintanilha/community-bot.git"
COMPOSE_DIR="/opt/apps"
LOG_FILE="/opt/apps/runtime/logs/community-bot-deploy.log"
RUN_DB_PUSH="${RUN_DB_PUSH:-false}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$REPO_DIR")"

if [ ! -d "${REPO_DIR}/.git" ]; then
  log "Cloning community-bot..."
  git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

log "Fetching latest code..."
git fetch origin master

TARGET_COMMIT="$(git rev-parse origin/master)"
git reset --hard "$TARGET_COMMIT"
git clean -fd

log "Provisioning database..."
"${COMPOSE_DIR}/scripts/provision-community-bot-db.sh"

cd "$COMPOSE_DIR"

if [ "$RUN_DB_PUSH" = "true" ]; then
  log "Applying database schema..."
  docker compose run --rm --build --no-deps community-bot bun run db:push
fi

log "Rebuilding and restarting community-bot..."
docker compose up -d --build community-bot

log "Registering guild-scoped Discord commands..."
docker compose run --rm community-bot bun run register-commands

log "Validating and reloading Caddy..."
docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile

log "Verifying readiness endpoint..."
for attempt in $(seq 1 30); do
  HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' https://community.rafaelquintanilha.com/readyz || true)"
  if [ "$HTTP_CODE" = "200" ]; then
    log "Readiness check passed"
    log "Deployment completed successfully"
    exit 0
  fi

  log "Readiness attempt $attempt/30 failed (HTTP $HTTP_CODE)"
  sleep 5
done

log "ERROR: Readiness check failed after 30 attempts"
docker compose logs --tail=120 community-bot | tee -a "$LOG_FILE"
exit 1
