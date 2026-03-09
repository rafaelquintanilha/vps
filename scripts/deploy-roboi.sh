#!/bin/bash

set -euo pipefail

REPO_DIR="/opt/apps/apps/roboi"
REPO_URL="git@github.com:quantbrasil/roboi.git"
COMPOSE_DIR="/opt/apps"
LOG_FILE="/opt/apps/runtime/logs/roboi-deploy.log"

if [ -f /opt/apps/.env ]; then
  set -a
  source /opt/apps/.env
  set +a
fi

ROBOI_PORT="${ROBOI_PORT:-3003}"
OPENCODE_PORT="${ROBOI_OPENCODE_PORT:-4096}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

wait_for_api() {
  log "Waiting for Roboi API health check..."
  for attempt in $(seq 1 30); do
    HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ROBOI_PORT}/health" || true)"
    if [ "$HTTP_CODE" = "200" ]; then
      log "Roboi API is healthy"
      return 0
    fi

    log "API health check attempt $attempt/30 failed (HTTP $HTTP_CODE)"
    sleep 5
  done

  log "ERROR: Roboi API health check failed"
  return 1
}

wait_for_opencode() {
  local user="${ROBOI_OPENCODE_SERVER_USERNAME:-opencode}"
  local password="${ROBOI_OPENCODE_SERVER_PASSWORD:-}"

  if [ -z "$password" ]; then
    log "ERROR: ROBOI_OPENCODE_SERVER_PASSWORD is not set"
    return 1
  fi

  log "Waiting for OpenCode health check..."
  for attempt in $(seq 1 30); do
    HTTP_CODE="$(curl -sS -u "${user}:${password}" -o /dev/null -w '%{http_code}' "http://127.0.0.1:${OPENCODE_PORT}/session/status" || true)"
    if [ "$HTTP_CODE" = "200" ]; then
      log "OpenCode is healthy"
      return 0
    fi

    log "OpenCode health check attempt $attempt/30 failed (HTTP $HTTP_CODE)"
    sleep 5
  done

  log "ERROR: OpenCode health check failed"
  return 1
}

log "========================================="
log "Starting Roboi deployment"
log "========================================="

mkdir -p /opt/apps/runtime/logs
mkdir -p /opt/apps/runtime/roboi/data
mkdir -p /opt/apps/runtime/roboi/opencode
mkdir -p /opt/apps/apps

if [ ! -d "$REPO_DIR/.git" ]; then
  log "Cloning Roboi repository..."
  git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

log "Fetching latest code..."
git fetch origin master

CURRENT_COMMIT="$(git rev-parse HEAD)"
TARGET_COMMIT="$(git rev-parse origin/master)"

if ! git diff --quiet || ! git diff --cached --quiet; then
  log "Local tracked changes detected in Roboi checkout; resetting to origin/master"
fi

git reset --hard "$TARGET_COMMIT"
git clean -fd

if [ "$CURRENT_COMMIT" != "$TARGET_COMMIT" ]; then
  log "Updated from $CURRENT_COMMIT to $TARGET_COMMIT"
else
  log "Already up to date ($CURRENT_COMMIT)"
fi

cd "$COMPOSE_DIR"

log "Building Roboi services..."
docker compose build roboi-opencode roboi-api roboi-worker roboi-migrate

log "Running SQLite migrations..."
docker compose run --rm roboi-migrate

log "Restarting Roboi services..."
docker compose up -d roboi-opencode roboi-api roboi-worker

wait_for_opencode
wait_for_api

log "Deployment completed successfully"
log "========================================="
