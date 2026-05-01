#!/bin/bash

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/apps}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgres}"
POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"
ROBOI_DATALAKE_APP_HOST="${ROBOI_DATALAKE_APP_HOST:-${ROBOI_DATALAKE_HOST:-postgres}}"
ROBOI_DATALAKE_APP_PORT="${ROBOI_DATALAKE_APP_PORT:-${ROBOI_DATALAKE_PORT:-5432}}"
ROBOI_INGEST_HOST="${ROBOI_INGEST_HOST:-127.0.0.1}"
ROBOI_INGEST_PORT="${ROBOI_INGEST_PORT:-${POSTGRES_EXTERNAL_PORT:-5432}}"

usage() {
  echo "Usage: $0 <client-id>" >&2
}

slug_for_client() {
  printf "%s" "$1" \
    | tr "[:upper:]" "[:lower:]" \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

validate_identifier() {
  local value="$1"
  local label="$2"

  if [[ ! "$value" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "ERROR: invalid ${label}: ${value}" >&2
    exit 1
  fi

  if [ "${#value}" -gt 63 ]; then
    echo "ERROR: ${label} is longer than PostgreSQL's 63-byte identifier limit: ${value}" >&2
    exit 1
  fi
}

generate_password() {
  openssl rand -hex 24
}

quote_env_value() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

connection_url() {
  local role="$1"
  local password="$2"
  local database="$3"
  local host="$4"
  local port="$5"

  printf "postgresql://%s:%s@%s:%s/%s" \
    "$role" \
    "$password" \
    "$host" \
    "$port" \
    "$database"
}

run_psql() {
  cd "$COMPOSE_DIR"
  docker compose exec -T "$POSTGRES_SERVICE" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER"
}

if [ "$#" -ne 1 ]; then
  usage
  exit 1
fi

CLIENT_ID="$1"
CLIENT_SLUG="$(slug_for_client "$CLIENT_ID")"

if [ -z "$CLIENT_SLUG" ]; then
  echo "ERROR: could not derive a PostgreSQL-safe slug from client id: $CLIENT_ID" >&2
  exit 1
fi

DATABASE_NAME="roboi_${CLIENT_SLUG}"
INGEST_ROLE="roboi_${CLIENT_SLUG}_ingest"
ADMIN_ROLE="roboi_${CLIENT_SLUG}_admin_ro"
OWNER_ROLE="roboi_${CLIENT_SLUG}_owner_ro"
OPERATOR_ROLE="roboi_${CLIENT_SLUG}_operator_ro"

validate_identifier "$DATABASE_NAME" "database name"
validate_identifier "$INGEST_ROLE" "ingest role"
validate_identifier "$ADMIN_ROLE" "admin role"
validate_identifier "$OWNER_ROLE" "owner role"
validate_identifier "$OPERATOR_ROLE" "operator role"

INGEST_PASSWORD="$(generate_password)"
ADMIN_PASSWORD="$(generate_password)"
OWNER_PASSWORD="$(generate_password)"
OPERATOR_PASSWORD="$(generate_password)"

run_psql <<SQL
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DATABASE_NAME}') THEN
    RAISE EXCEPTION 'database already exists: ${DATABASE_NAME}';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname IN (
      '${INGEST_ROLE}',
      '${ADMIN_ROLE}',
      '${OWNER_ROLE}',
      '${OPERATOR_ROLE}'
    )
  ) THEN
    RAISE EXCEPTION 'one or more Roboi data-lake roles already exist for client: ${CLIENT_ID}';
  END IF;
END
\$\$;

CREATE ROLE "${INGEST_ROLE}"
  LOGIN
  PASSWORD '${INGEST_PASSWORD}'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION;

CREATE ROLE "${ADMIN_ROLE}"
  LOGIN
  PASSWORD '${ADMIN_PASSWORD}'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION;

CREATE ROLE "${OWNER_ROLE}"
  LOGIN
  PASSWORD '${OWNER_PASSWORD}'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION;

CREATE ROLE "${OPERATOR_ROLE}"
  LOGIN
  PASSWORD '${OPERATOR_PASSWORD}'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION;

CREATE DATABASE "${DATABASE_NAME}" OWNER "${INGEST_ROLE}";
REVOKE ALL ON DATABASE "${DATABASE_NAME}" FROM PUBLIC;
GRANT CONNECT ON DATABASE "${DATABASE_NAME}" TO "${ADMIN_ROLE}", "${OWNER_ROLE}", "${OPERATOR_ROLE}";

\\connect ${DATABASE_NAME}

REVOKE ALL ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA IF NOT EXISTS consume_zone AUTHORIZATION "${INGEST_ROLE}";
CREATE SCHEMA IF NOT EXISTS integration_zone AUTHORIZATION "${INGEST_ROLE}";
CREATE SCHEMA IF NOT EXISTS ingestion_meta AUTHORIZATION "${INGEST_ROLE}";

GRANT USAGE ON SCHEMA consume_zone, integration_zone
  TO "${ADMIN_ROLE}", "${OWNER_ROLE}", "${OPERATOR_ROLE}";
GRANT SELECT ON ALL TABLES IN SCHEMA consume_zone, integration_zone
  TO "${ADMIN_ROLE}", "${OWNER_ROLE}", "${OPERATOR_ROLE}";
ALTER DEFAULT PRIVILEGES FOR ROLE "${INGEST_ROLE}" IN SCHEMA consume_zone
  GRANT SELECT ON TABLES TO "${ADMIN_ROLE}", "${OWNER_ROLE}", "${OPERATOR_ROLE}";
ALTER DEFAULT PRIVILEGES FOR ROLE "${INGEST_ROLE}" IN SCHEMA integration_zone
  GRANT SELECT ON TABLES TO "${ADMIN_ROLE}", "${OWNER_ROLE}", "${OPERATOR_ROLE}";
SQL

cat <<EOF
Provisioned Roboi data-lake database for client ${CLIENT_ID}.

Use this host-side URL only for ingestion jobs:
ROBOI_INGEST_PG_URL=$(quote_env_value "$(connection_url "$INGEST_ROLE" "$INGEST_PASSWORD" "$DATABASE_NAME" "$ROBOI_INGEST_HOST" "$ROBOI_INGEST_PORT")")

Add these read-only URLs to the Roboi instance.env:
ROBOI_DATALAKE_URL_ADMIN=$(quote_env_value "$(connection_url "$ADMIN_ROLE" "$ADMIN_PASSWORD" "$DATABASE_NAME" "$ROBOI_DATALAKE_APP_HOST" "$ROBOI_DATALAKE_APP_PORT")")
ROBOI_DATALAKE_URL_OWNER=$(quote_env_value "$(connection_url "$OWNER_ROLE" "$OWNER_PASSWORD" "$DATABASE_NAME" "$ROBOI_DATALAKE_APP_HOST" "$ROBOI_DATALAKE_APP_PORT")")
ROBOI_DATALAKE_URL_OPERATOR=$(quote_env_value "$(connection_url "$OPERATOR_ROLE" "$OPERATOR_PASSWORD" "$DATABASE_NAME" "$ROBOI_DATALAKE_APP_HOST" "$ROBOI_DATALAKE_APP_PORT")")
EOF
