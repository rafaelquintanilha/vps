#!/bin/bash

# Pronto Deployment Script
# This script is triggered by the deployment webhook to update and restart the Pronto backend

# Add Node.js/pnpm to PATH (for cron environment)
export PATH="/root/.nvm/versions/node/v20.19.4/bin:$PATH"

# Configuration
REPO_DIR="/opt/apps/apps/pronto"
DOCKER_COMPOSE_DIR="/opt/apps"
LOG_FILE="/opt/apps/runtime/logs/pronto-deploy.log"
SERVICE_NAME="pronto-backend"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to get container name dynamically
get_container_name() {
    docker ps --format "{{.Names}}" | grep -E "pronto-backend|pronto_backend" | head -1
}

# Function to check if postgres is healthy
wait_for_postgres() {
    log "Waiting for postgres to be ready..."
    for i in $(seq 1 30); do
        if docker compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
            log "Postgres is ready"
            return 0
        fi
        log "Postgres not ready yet (attempt $i/30)"
        sleep 2
    done
    log "ERROR: Postgres failed to become ready"
    return 1
}

# Function to check backend health
check_backend_health() {
    local attempts=${1:-30}
    local delay=${2:-2}

    log "Waiting for backend to be healthy..."
    for i in $(seq 1 $attempts); do
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/healthz 2>/dev/null || echo "000")
        if [ "$RESPONSE" = "200" ]; then
            log "Backend is healthy!"
            return 0
        fi
        log "Health check attempt $i/$attempts: HTTP $RESPONSE"
        sleep $delay
    done
    log "ERROR: Backend failed to become healthy"
    return 1
}

# Function to safely restart backend
safe_restart_backend() {
    cd "$DOCKER_COMPOSE_DIR"

    # Ensure postgres is running first
    docker compose up -d postgres
    wait_for_postgres || return 1

    # Now start backend
    docker compose up -d "$SERVICE_NAME"
    check_backend_health 30 2 || return 1

    return 0
}

# Start deployment
log "========================================="
log "Starting Pronto deployment"
log "========================================="

cd "$DOCKER_COMPOSE_DIR"

# Step 1: Pull latest code from GitHub
log "Step 1: Pulling latest code from GitHub..."
cd "$REPO_DIR"

# Fetch latest changes
git fetch origin master
CURRENT_COMMIT=$(git rev-parse HEAD)
LATEST_COMMIT=$(git rev-parse origin/master)

if [ "$CURRENT_COMMIT" = "$LATEST_COMMIT" ]; then
    log "Already up to date. No deployment needed."
    exit 0
fi

# Store current commit for rollback
echo "$CURRENT_COMMIT" > /tmp/pronto-last-deploy-commit

# Pull latest changes
git pull origin master
NEW_COMMIT=$(git rev-parse HEAD)
log "Updated from $CURRENT_COMMIT to $NEW_COMMIT"

# Step 2: Build frontend
log "Step 2: Building frontend..."
cd "$REPO_DIR"
if ! pnpm install --frozen-lockfile 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: pnpm install failed"
    git reset --hard "$CURRENT_COMMIT"
    exit 1
fi

cd apps/client
if ! pnpm build 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: Frontend build failed"
    cd "$REPO_DIR"
    git reset --hard "$CURRENT_COMMIT"
    exit 1
fi
cd "$DOCKER_COMPOSE_DIR"

# Step 3: Build new Docker image (keep old image as backup)
log "Step 3: Building new Docker image..."
OLD_IMAGE=$(docker images --format "{{.ID}}" apps-pronto-backend:latest 2>/dev/null || echo "")
if [ -n "$OLD_IMAGE" ]; then
    docker tag apps-pronto-backend:latest apps-pronto-backend:rollback 2>/dev/null || true
    log "Tagged current image as rollback: $OLD_IMAGE"
fi

if ! docker compose build "$SERVICE_NAME" 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: Docker build failed"
    cd "$REPO_DIR"
    git reset --hard "$CURRENT_COMMIT"
    exit 1
fi

# Step 4: Ensure postgres is healthy before deployment
log "Step 4: Ensuring postgres is healthy..."
docker compose up -d postgres
if ! wait_for_postgres; then
    log "ERROR: Postgres is not healthy, aborting deployment"
    cd "$REPO_DIR"
    git reset --hard "$CURRENT_COMMIT"
    exit 1
fi

# Step 5: Deploy new container
log "Step 5: Deploying new container..."

# Get current container state
EXISTING_CONTAINER=$(get_container_name)
if [ -n "$EXISTING_CONTAINER" ]; then
    log "Current container: $EXISTING_CONTAINER"
fi

# Stop existing container
log "Stopping existing container..."
docker compose stop "$SERVICE_NAME" 2>/dev/null || true
docker compose rm -f "$SERVICE_NAME" 2>/dev/null || true
sleep 3

# Start new container
log "Starting new container..."
docker compose up -d "$SERVICE_NAME"

# Step 6: Verify deployment
log "Step 6: Verifying deployment..."
if ! check_backend_health 45 2; then
    log "ERROR: New container failed health checks"
    log "Attempting rollback..."

    # Stop failed container
    docker compose stop "$SERVICE_NAME" 2>/dev/null || true
    docker compose rm -f "$SERVICE_NAME" 2>/dev/null || true

    # Restore old image if available
    if docker image inspect apps-pronto-backend:rollback >/dev/null 2>&1; then
        log "Restoring rollback image..."
        docker tag apps-pronto-backend:rollback apps-pronto-backend:latest
    fi

    # Restore old code
    cd "$REPO_DIR"
    git reset --hard "$CURRENT_COMMIT"

    # Rebuild with old code (in case image rollback didn't work)
    cd "$DOCKER_COMPOSE_DIR"
    docker compose build "$SERVICE_NAME" 2>/dev/null || true

    # Start rollback container
    log "Starting rollback container..."
    if safe_restart_backend; then
        log "Rollback successful - site is back online with previous version"
    else
        log "CRITICAL: Rollback failed! Manual intervention required."
        # Last resort: just try to start anything
        docker compose up -d postgres "$SERVICE_NAME"
    fi

    exit 1
fi

log "Deployment verified successfully!"

# Step 7: Cleanup
log "Step 7: Cleaning up..."
docker image rm apps-pronto-backend:rollback 2>/dev/null || true
docker image prune -f >/dev/null 2>&1 || true

# Deployment complete
log "========================================="
log "Deployment completed successfully!"
log "New commit: $NEW_COMMIT"
log "========================================="

exit 0
