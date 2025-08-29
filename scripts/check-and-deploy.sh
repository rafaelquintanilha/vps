#!/bin/bash

# Pronto Deployment Monitor Script
# This script checks for deployment triggers and executes deployments

# Configuration
TRIGGER_DIR="/opt/apps/runtime/deploy-triggers"
TRIGGER_FILE="$TRIGGER_DIR/deploy-request.json"
DEPLOY_SCRIPT="/opt/apps/scripts/deploy-pronto.sh"
LOG_FILE="/opt/apps/runtime/logs/pronto-deploy.log"
LOCK_FILE="/tmp/pronto-deploy.lock"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR: $1" | tee -a "$LOG_FILE"
}

# Check if deployment is already running
if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE")
    if ps -p $PID > /dev/null 2>&1; then
        # Process is still running
        exit 0
    else
        # Process died, remove stale lock
        rm -f "$LOCK_FILE"
    fi
fi

# Check for deployment trigger
if [ ! -f "$TRIGGER_FILE" ]; then
    # No deployment requested
    exit 0
fi

# Create lock file
echo $$ > "$LOCK_FILE"

# Read deployment request
if [ -f "$TRIGGER_FILE" ]; then
    log "Found deployment trigger: $TRIGGER_FILE"
    
    # Extract commit info
    COMMIT=$(jq -r '.commit' "$TRIGGER_FILE" 2>/dev/null || echo "unknown")
    PUSHER=$(jq -r '.pusher' "$TRIGGER_FILE" 2>/dev/null || echo "unknown")
    TIMESTAMP=$(jq -r '.timestamp' "$TRIGGER_FILE" 2>/dev/null || echo "unknown")
    
    log "Deployment request: commit=$COMMIT, pusher=$PUSHER, timestamp=$TIMESTAMP"
    
    # Remove trigger file to prevent re-processing
    rm -f "$TRIGGER_FILE"
    
    # Execute deployment
    log "Executing deployment script..."
    if bash "$DEPLOY_SCRIPT"; then
        log "Deployment completed successfully"
    else
        log "Deployment failed with exit code: $?"
    fi
else
    log "Trigger file disappeared before processing"
fi

# Clean up lock file
rm -f "$LOCK_FILE"

exit 0