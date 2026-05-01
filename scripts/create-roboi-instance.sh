#!/bin/bash

set -euo pipefail

INSTANCE_ROOT="${ROBOI_INSTANCE_ROOT:-/opt/apps/runtime/roboi-instances}"

usage() {
  echo "Usage: $0 <client-id> <host[,host2,...]>" >&2
}

quote_env_value() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

validate_instance_id() {
  local instance_id="$1"

  if [[ ! "$instance_id" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "ERROR: invalid client id for filesystem path: $instance_id" >&2
    exit 1
  fi
}

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi

CLIENT_ID="$1"
HOSTS="$2"

validate_instance_id "$CLIENT_ID"

if [ -z "$HOSTS" ]; then
  usage
  exit 1
fi

INSTANCE_DIR="${INSTANCE_ROOT}/${CLIENT_ID}"
ENV_FILE="${INSTANCE_DIR}/instance.env"

if [ -e "$ENV_FILE" ]; then
  echo "ERROR: Roboi instance already exists: $ENV_FILE" >&2
  exit 1
fi

mkdir -p \
  "${INSTANCE_DIR}/data" \
  "${INSTANCE_DIR}/opencode/admin" \
  "${INSTANCE_DIR}/opencode/owner" \
  "${INSTANCE_DIR}/opencode/operator"

cat > "$ENV_FILE" <<EOF
# Roboi instance runtime config. Keep this file out of git.
# Instance identity is the Ponta client id and must match the folder name.
ROBOI_HOSTS=$(quote_env_value "$HOSTS")
ROBOI_DEFAULT_CLIENT_CODE=$(quote_env_value "$CLIENT_ID")

# Required per instance.
ROBOI_DATALAKE_URL_ADMIN=''
ROBOI_DATALAKE_URL_OWNER=''
ROBOI_DATALAKE_URL_OPERATOR=''
ROBOI_OPENCODE_SERVER_USERNAME='opencode'
ROBOI_OPENCODE_SERVER_PASSWORD=''
ROBOI_ANTHROPIC_API_KEY=''

# Optional runtime tuning.
ROBOI_DATALAKE_DEFAULT_LIMIT='200'
ROBOI_DATALAKE_MAX_LIMIT='1000'
ROBOI_DATALAKE_STATEMENT_TIMEOUT_MS='15000'
ROBOI_POLL_INTERVAL_MS='2000'
ROBOI_WORKER_CONCURRENCY='3'
ROBOI_JOB_TIMEOUT_MS='600000'
EOF

chmod 600 "$ENV_FILE"

cat <<EOF
Created Roboi instance scaffold:
  $INSTANCE_DIR

Next steps:
  1. Provision data-lake roles with /opt/apps/scripts/provision-roboi-datalake-client.sh $CLIENT_ID
  2. Fill required secrets and credentials in $ENV_FILE
  3. Run /opt/apps/scripts/deploy-roboi.sh
EOF
