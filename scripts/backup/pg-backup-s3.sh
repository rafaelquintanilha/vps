#!/bin/bash
# Backup PostgreSQL databases using pg_dump and upload to S3.
# Backs up all specified databases from the Docker PostgreSQL container.
#
# Environment variables required (set in /opt/apps/.env):
# - POSTGRES_USER: PostgreSQL username
# - POSTGRES_PASSWORD: PostgreSQL password
# - AWS_ACCESS_KEY: AWS access key
# - AWS_SECRET_KEY: AWS secret key
# - AWS_REGION: AWS region (default: sa-east-1)
# - S3_BACKUP_BUCKET: S3 bucket name
# - S3_BACKUP_PREFIX: S3 prefix/folder path (default: postgres-backups)

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/opt/apps/runtime/logs/pg-backup.log"
BACKUP_DIR="/opt/apps/backups"
TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
DATE_FOLDER=$(date +'%Y/%m/%d')

# Databases to backup
DATABASES="postgres metabaseappdb pronto devqb_mc8b yt_central"

# Load environment variables
if [ -f /opt/apps/.env ]; then
    set -a
    source /opt/apps/.env
    set +a
fi

# Export AWS CLI environment variables
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_KEY}"
export AWS_DEFAULT_REGION="${AWS_REGION:-sa-east-1}"

# Set defaults
S3_BACKUP_PREFIX="${S3_BACKUP_PREFIX:-postgres-backups}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Ensure directories exist
mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

log "=========================================="
log "Starting PostgreSQL backup..."
log "=========================================="

# Validate required environment variables
if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || \
   [ -z "$AWS_ACCESS_KEY" ] || [ -z "$AWS_SECRET_KEY" ] || \
   [ -z "$S3_BACKUP_BUCKET" ]; then
    log "Error: Missing required environment variables"
    log "Required: POSTGRES_USER, POSTGRES_PASSWORD, AWS_ACCESS_KEY, AWS_SECRET_KEY, S3_BACKUP_BUCKET"
    exit 1
fi

# Check if AWS CLI is available
if ! command -v aws &> /dev/null; then
    log "Error: AWS CLI is not installed"
    exit 1
fi

# Track success/failure
FAILED_DBS=""
SUCCESS_COUNT=0

for DB_NAME in $DATABASES; do
    log "Backing up database: $DB_NAME"

    BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.sql.gz"
    S3_PATH="s3://${S3_BACKUP_BUCKET}/${S3_BACKUP_PREFIX}/${DATE_FOLDER}/${DB_NAME}_${TIMESTAMP}.sql.gz"

    # Create backup using docker compose exec
    if docker compose -f /opt/apps/docker-compose.yml exec -T postgres pg_dump -U "$POSTGRES_USER" "$DB_NAME" 2>/dev/null | gzip > "$BACKUP_FILE"; then
        # Check if backup file has content
        if [ -s "$BACKUP_FILE" ]; then
            log "  Created: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

            # Upload to S3
            if aws s3 cp "$BACKUP_FILE" "$S3_PATH" --quiet; then
                log "  Uploaded to: $S3_PATH"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                log "  Error: Failed to upload to S3"
                FAILED_DBS="$FAILED_DBS $DB_NAME"
            fi

            # Cleanup local backup
            rm -f "$BACKUP_FILE"
        else
            log "  Error: Backup file is empty"
            FAILED_DBS="$FAILED_DBS $DB_NAME"
            rm -f "$BACKUP_FILE"
        fi
    else
        log "  Error: pg_dump failed for $DB_NAME"
        FAILED_DBS="$FAILED_DBS $DB_NAME"
        rm -f "$BACKUP_FILE"
    fi
done

log "=========================================="
log "Backup completed: $SUCCESS_COUNT successful"

if [ -n "$FAILED_DBS" ]; then
    log "Failed databases:$FAILED_DBS"
    exit 1
fi

log "All backups completed successfully"
exit 0
