#!/bin/bash

set -euo pipefail

COMPOSE_DIR="/opt/apps"
ENV_FILE="${COMPOSE_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: ${ENV_FILE} does not exist." >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

required_vars=(
  POSTGRES_USER
  COMMUNITY_BOT_DB_USER
  COMMUNITY_BOT_DB_PASS
  COMMUNITY_BOT_DB_NAME
)

for key in "${required_vars[@]}"; do
  if [ -z "${!key:-}" ]; then
    echo "ERROR: ${key} must be set in ${ENV_FILE}." >&2
    exit 1
  fi
done

cd "$COMPOSE_DIR"
docker compose up -d postgres

for attempt in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
    break
  fi

  if [ "$attempt" -eq 30 ]; then
    echo "ERROR: Postgres did not become ready." >&2
    exit 1
  fi

  sleep 2
done

docker compose exec -T postgres psql \
  -v ON_ERROR_STOP=1 \
  -v db_user="$COMMUNITY_BOT_DB_USER" \
  -v db_pass="$COMMUNITY_BOT_DB_PASS" \
  -v db_name="$COMMUNITY_BOT_DB_NAME" \
  -U "$POSTGRES_USER" \
  -d postgres <<'EOSQL'
SELECT format('CREATE ROLE %I LOGIN', :'db_user')
WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = :'db_user')\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_pass')\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db_name')\gexec

SELECT format('ALTER DATABASE %I OWNER TO %I', :'db_name', :'db_user')\gexec
EOSQL

docker compose exec -T postgres psql \
  -v ON_ERROR_STOP=1 \
  -v db_user="$COMMUNITY_BOT_DB_USER" \
  -U "$POSTGRES_USER" \
  -d "$COMMUNITY_BOT_DB_NAME" <<'EOSQL'
SELECT format('GRANT ALL ON SCHEMA public TO %I', :'db_user')\gexec
EOSQL

echo "Community bot database is provisioned."
