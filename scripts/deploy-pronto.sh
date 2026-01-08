#!/bin/bash

# Pronto Deployment Script
# This script is triggered by the deployment webhook to update and restart the Pronto backend

set -e

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

# Function to check health using docker-compose
check_health_compose() {
    cd "$DOCKER_COMPOSE_DIR"
    docker-compose exec -T "$SERVICE_NAME" wget --spider -q http://localhost:3000/healthz 2>/dev/null
    return $?
}

# Error handling
handle_error() {
    log "ERROR: Deployment failed at line $1"
    log "Rolling back..."
    cd "$DOCKER_COMPOSE_DIR"
    
    # Clean up any problematic containers before rollback
    docker-compose stop "$SERVICE_NAME" || true
    docker-compose rm -f "$SERVICE_NAME" || true
    sleep 2
    
    docker-compose up -d "$SERVICE_NAME"
    exit 1
}

trap 'handle_error $LINENO' ERR

# Start deployment
log "========================================="
log "Starting Pronto deployment"
log "========================================="

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
pnpm install --frozen-lockfile
cd apps/client
pnpm build
cd "$DOCKER_COMPOSE_DIR"

# Step 3: Build new Docker image
log "Step 3: Building new Docker image..."
docker-compose build "$SERVICE_NAME"

# Step 4: Health check current container
log "Step 4: Checking current container health..."
CONTAINER_NAME=$(get_container_name)
if [ -n "$CONTAINER_NAME" ]; then
    CURRENT_HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    log "Current container ($CONTAINER_NAME) health: $CURRENT_HEALTH"
else
    log "No running container found, proceeding with deployment"
fi

# Step 5: Deploy with zero downtime
log "Step 5: Deploying new container..."

# Stop and remove existing container to avoid ContainerConfig errors
EXISTING_CONTAINER=$(get_container_name)
if [ -n "$EXISTING_CONTAINER" ]; then
    log "Stopping existing container: $EXISTING_CONTAINER"
    docker-compose stop "$SERVICE_NAME" || true
    docker-compose rm -f "$SERVICE_NAME" || true
    
    # Wait a moment for cleanup
    sleep 2
fi

# Start new container
log "Starting new container..."
docker-compose up -d "$SERVICE_NAME"

# Wait for new container to be healthy
log "Waiting for new container to be healthy..."
HEALTH_CHECK_ATTEMPTS=30
HEALTH_CHECK_DELAY=2

for i in $(seq 1 $HEALTH_CHECK_ATTEMPTS); do
    # Get the current container name (it might have changed)
    CONTAINER_NAME=$(get_container_name)
    
    if [ -z "$CONTAINER_NAME" ]; then
        log "Health check attempt $i/$HEALTH_CHECK_ATTEMPTS: Container not found yet"
        sleep $HEALTH_CHECK_DELAY
        continue
    fi
    
    # Check health using docker inspect
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "starting")
    
    # Also try using docker-compose exec as backup
    if [ "$HEALTH" != "healthy" ] && check_health_compose; then
        log "Container is responding to health checks!"
        break
    fi
    
    if [ "$HEALTH" = "healthy" ]; then
        log "Container ($CONTAINER_NAME) is healthy!"
        break
    fi
    
    if [ $i -eq $HEALTH_CHECK_ATTEMPTS ]; then
        log "ERROR: Health check failed after $HEALTH_CHECK_ATTEMPTS attempts"
        log "Container health status: $HEALTH"
        
        # Rollback
        log "Rolling back to previous version..."
        cd "$REPO_DIR"
        git reset --hard "$CURRENT_COMMIT"
        cd "$DOCKER_COMPOSE_DIR"
        docker-compose build "$SERVICE_NAME"
        
        # Clean up failed container before rollback
        docker-compose stop "$SERVICE_NAME" || true
        docker-compose rm -f "$SERVICE_NAME" || true
        sleep 2
        
        docker-compose up -d "$SERVICE_NAME"
        
        exit 1
    fi
    
    log "Health check attempt $i/$HEALTH_CHECK_ATTEMPTS: $HEALTH"
    sleep $HEALTH_CHECK_DELAY
done

# Step 6: Verify deployment
log "Step 6: Verifying deployment..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/healthz)

if [ "$RESPONSE" = "200" ]; then
    log "Deployment successful! Health check returned: $RESPONSE"
else
    log "ERROR: Health check failed with response: $RESPONSE"
    exit 1
fi

# Step 7: Cleanup old images
log "Step 7: Cleaning up old Docker images..."
docker image prune -f

# Deployment complete
log "========================================="
log "Deployment completed successfully!"
log "New commit: $NEW_COMMIT"
log "========================================="

exit 0