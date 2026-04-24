#!/bin/bash

set -euo pipefail

REPO_DIR="/opt/apps/apps/roboi"
REPO_URL="git@github.com:quantbrasil/roboi.git"
COMPOSE_DIR="/opt/apps"
INSTANCE_ROOT="/opt/apps/runtime/roboi-instances"
INSTANCE_COMPOSE_FILE="/opt/apps/roboi/docker-compose.instance.yml"
CADDY_INSTANCE_DIR="/opt/apps/runtime/roboi-caddy"
CADDY_INSTANCE_FILE="${CADDY_INSTANCE_DIR}/roboi-instances.caddy"
LOG_FILE="/opt/apps/runtime/logs/roboi-deploy.log"
AUTH_RENDERER="/opt/apps/scripts/render-roboi-opencode-auth.sh"
LEGACY_RUNTIME_DIR="/opt/apps/runtime/roboi"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

load_env_file() {
  local env_file="$1"

  if [ -f "$env_file" ]; then
    set -a
    source "$env_file"
    set +a
  fi
}

env_file_has_key() {
  local env_file="$1"
  local key="$2"

  grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=" "$env_file"
}

quote_env_value() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

write_env_line() {
  local key="$1"
  local value="${!key:-}"

  if [ -n "$value" ]; then
    printf "%s=%s\n" "$key" "$(quote_env_value "$value")"
  fi
}

write_env_line_required() {
  local key="$1"
  local value="${!key:-}"

  printf "%s=%s\n" "$key" "$(quote_env_value "$value")"
}

reset_roboi_instance_env() {
  unset ROBOI_HOSTS
  unset ROBOI_DEFAULT_CLIENT_CODE
  unset ROBOI_DATALAKE_URL
  unset ROBOI_DATALAKE_DEFAULT_LIMIT
  unset ROBOI_DATALAKE_MAX_LIMIT
  unset ROBOI_DATALAKE_STATEMENT_TIMEOUT_MS
  unset ROBOI_BASIC_AUTH_USER
  unset ROBOI_BASIC_AUTH_HASH
  unset ROBOI_OPENCODE_SERVER_USERNAME
  unset ROBOI_OPENCODE_SERVER_PASSWORD
  unset ROBOI_POLL_INTERVAL_MS
  unset ROBOI_WORKER_CONCURRENCY
  unset ROBOI_JOB_TIMEOUT_MS
  unset ROBOI_ANTHROPIC_API_KEY
  unset ROBOI_INSTANCE_ID
  unset ROBOI_INSTANCE_DIR
  unset ROBOI_DOCKER_PROJECT
  unset ROBOI_OPENCODE_CONTAINER
  unset ROBOI_API_CONTAINER
  unset ROBOI_ENV_FILE
  unset ROBOI_AUTH_DIR
}

validate_instance_id() {
  local instance_id="$1"

  if [[ ! "$instance_id" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    log "ERROR: invalid Roboi instance id: $instance_id"
    exit 1
  fi
}

project_name_for_instance() {
  local instance_id="$1"
  local slug

  slug="$(printf "%s" "$instance_id" | tr "[:upper:]" "[:lower:]" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$slug" ]; then
    log "ERROR: could not derive Docker project name for instance: $instance_id"
    exit 1
  fi

  printf "roboi-%s" "$slug"
}

stop_legacy_containers() {
  local names=(
    "apps-roboi-worker-1"
    "apps-roboi-api-1"
    "apps-roboi-opencode-1"
  )

  for name in "${names[@]}"; do
    if docker ps -a --format "{{.Names}}" | grep -Fxq "$name"; then
      log "Stopping legacy container $name before first instance migration..."
      docker stop "$name" >/dev/null || true
    fi
  done
}

instance_env_files() {
  if [ ! -d "$INSTANCE_ROOT" ]; then
    return 0
  fi

  find "$INSTANCE_ROOT" -mindepth 2 -maxdepth 2 -type f -name "instance.env" | sort
}

instance_count() {
  instance_env_files | wc -l | tr -d " "
}

ensure_legacy_instance_if_needed() {
  local count
  count="$(instance_count)"

  if [ "$count" != "0" ]; then
    return
  fi

  if [ -z "${ROBOI_DEFAULT_CLIENT_CODE:-}" ]; then
    log "ERROR: no Roboi instances found in $INSTANCE_ROOT and ROBOI_DEFAULT_CLIENT_CODE is not set."
    log "Create one with: /opt/apps/scripts/create-roboi-instance.sh <client-id> <host[,host2]>"
    exit 1
  fi

  local instance_id="$ROBOI_DEFAULT_CLIENT_CODE"
  validate_instance_id "$instance_id"

  local instance_dir="${INSTANCE_ROOT}/${instance_id}"
  local env_file="${instance_dir}/instance.env"
  local legacy_hosts="${ROBOI_HOSTS:-roboi.rafaelquintanilha.com,roboi.69.62.89.22.nip.io}"
  local backup_dir="${LEGACY_RUNTIME_DIR}.backup.$(date '+%Y%m%d%H%M%S')"

  log "No Roboi instance folders found; creating initial instance for client ${instance_id}."

  mkdir -p "$instance_dir/data" "$instance_dir/opencode"

  if [ -d "$LEGACY_RUNTIME_DIR" ]; then
    stop_legacy_containers
    log "Backing up legacy Roboi runtime to ${backup_dir}."
    cp -a "$LEGACY_RUNTIME_DIR" "$backup_dir"

    if [ -d "${LEGACY_RUNTIME_DIR}/data" ]; then
      cp -a "${LEGACY_RUNTIME_DIR}/data/." "${instance_dir}/data/"
    fi

    if [ -d "${LEGACY_RUNTIME_DIR}/opencode" ]; then
      cp -a "${LEGACY_RUNTIME_DIR}/opencode/." "${instance_dir}/opencode/"
    fi
  fi

  if [ ! -f "$env_file" ]; then
    {
      printf "# Roboi instance runtime config. Keep this file out of git.\n"
      printf "ROBOI_HOSTS=%s\n" "$(quote_env_value "$legacy_hosts")"
      printf "ROBOI_DEFAULT_CLIENT_CODE=%s\n" "$(quote_env_value "$instance_id")"
      write_env_line_required "ROBOI_DATALAKE_URL"
      write_env_line "ROBOI_DATALAKE_DEFAULT_LIMIT"
      write_env_line "ROBOI_DATALAKE_MAX_LIMIT"
      write_env_line "ROBOI_DATALAKE_STATEMENT_TIMEOUT_MS"
      write_env_line_required "ROBOI_BASIC_AUTH_USER"
      write_env_line_required "ROBOI_BASIC_AUTH_HASH"
      write_env_line "ROBOI_OPENCODE_SERVER_USERNAME"
      write_env_line_required "ROBOI_OPENCODE_SERVER_PASSWORD"
      write_env_line "ROBOI_POLL_INTERVAL_MS"
      write_env_line "ROBOI_WORKER_CONCURRENCY"
      write_env_line "ROBOI_JOB_TIMEOUT_MS"
      write_env_line_required "ROBOI_ANTHROPIC_API_KEY"
    } > "$env_file"
    chmod 600 "$env_file"
  fi
}

prepare_repo() {
  if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning Roboi repository..."
    git clone "$REPO_URL" "$REPO_DIR"
  fi

  cd "$REPO_DIR"

  log "Fetching latest Roboi code..."
  git fetch origin master

  local current_commit
  local target_commit
  current_commit="$(git rev-parse HEAD)"
  target_commit="$(git rev-parse origin/master)"

  if ! git diff --quiet || ! git diff --cached --quiet; then
    log "Local tracked changes detected in Roboi checkout; resetting to origin/master"
  fi

  git reset --hard "$target_commit"
  git clean -fd

  if [ "$current_commit" != "$target_commit" ]; then
    log "Updated Roboi from $current_commit to $target_commit"
  else
    log "Roboi already up to date ($current_commit)"
  fi
}

build_image() {
  cd "$REPO_DIR"

  local short_commit
  short_commit="$(git rev-parse --short=12 HEAD)"
  ROBOI_IMAGE="roboi:${short_commit}"
  export ROBOI_IMAGE

  log "Building shared Roboi image ${ROBOI_IMAGE}..."
  docker build -t "$ROBOI_IMAGE" -t "roboi:latest" .
}

require_instance_key() {
  local env_file="$1"
  local key="$2"

  if ! env_file_has_key "$env_file" "$key"; then
    log "ERROR: ${env_file} must define ${key}."
    exit 1
  fi
}

require_non_empty_instance_value() {
  local env_file="$1"
  local key="$2"
  local value="${!key:-}"

  if [ -z "$value" ]; then
    log "ERROR: ${env_file} must define a non-empty ${key}."
    exit 1
  fi
}

load_instance_env() {
  local env_file="$1"
  local instance_dir
  local instance_id
  local project_name

  instance_dir="$(dirname "$env_file")"
  instance_id="$(basename "$instance_dir")"
  validate_instance_id "$instance_id"

  reset_roboi_instance_env
  load_env_file "/opt/apps/.env"
  reset_roboi_instance_env

  require_instance_key "$env_file" "ROBOI_HOSTS"
  require_instance_key "$env_file" "ROBOI_DEFAULT_CLIENT_CODE"
  require_instance_key "$env_file" "ROBOI_DATALAKE_URL"
  require_instance_key "$env_file" "ROBOI_BASIC_AUTH_USER"
  require_instance_key "$env_file" "ROBOI_BASIC_AUTH_HASH"
  require_instance_key "$env_file" "ROBOI_OPENCODE_SERVER_PASSWORD"
  require_instance_key "$env_file" "ROBOI_ANTHROPIC_API_KEY"

  load_env_file "$env_file"

  if [ "${ROBOI_DEFAULT_CLIENT_CODE:-}" != "$instance_id" ]; then
    log "ERROR: ${env_file} has ROBOI_DEFAULT_CLIENT_CODE=${ROBOI_DEFAULT_CLIENT_CODE:-<empty>}, expected folder name ${instance_id}."
    exit 1
  fi

  require_non_empty_instance_value "$env_file" "ROBOI_HOSTS"
  require_non_empty_instance_value "$env_file" "ROBOI_DEFAULT_CLIENT_CODE"
  require_non_empty_instance_value "$env_file" "ROBOI_DATALAKE_URL"
  require_non_empty_instance_value "$env_file" "ROBOI_BASIC_AUTH_USER"
  require_non_empty_instance_value "$env_file" "ROBOI_BASIC_AUTH_HASH"
  require_non_empty_instance_value "$env_file" "ROBOI_OPENCODE_SERVER_PASSWORD"
  require_non_empty_instance_value "$env_file" "ROBOI_ANTHROPIC_API_KEY"

  project_name="$(project_name_for_instance "$instance_id")"

  ROBOI_INSTANCE_ID="$instance_id"
  ROBOI_INSTANCE_DIR="$instance_dir"
  ROBOI_DOCKER_PROJECT="$project_name"
  ROBOI_OPENCODE_CONTAINER="${project_name}-opencode"
  ROBOI_API_CONTAINER="${project_name}-api"

  export ROBOI_INSTANCE_ID
  export ROBOI_INSTANCE_DIR
  export ROBOI_DOCKER_PROJECT
  export ROBOI_OPENCODE_CONTAINER
  export ROBOI_API_CONTAINER
}

compose_for_instance() {
  docker compose -p "$ROBOI_DOCKER_PROJECT" -f "$INSTANCE_COMPOSE_FILE" "$@"
}

wait_for_service_health() {
  local service="$1"
  local label="$2"

  log "Waiting for ${ROBOI_INSTANCE_ID} ${label} health check..."

  for attempt in $(seq 1 30); do
    local container_id
    local status

    container_id="$(compose_for_instance ps -q "$service")"
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"

    if [ "$status" = "healthy" ]; then
      log "${ROBOI_INSTANCE_ID} ${label} is healthy"
      return 0
    fi

    log "${ROBOI_INSTANCE_ID} ${label} health check attempt $attempt/30 failed (status: ${status:-unknown})"
    sleep 5
  done

  log "ERROR: ${ROBOI_INSTANCE_ID} ${label} health check failed"
  return 1
}

render_instance_auth() {
  local env_file="$1"

  if [ ! -x "$AUTH_RENDERER" ]; then
    log "ERROR: auth renderer is missing or not executable: $AUTH_RENDERER"
    exit 1
  fi

  log "Rendering OpenCode auth for Roboi instance ${ROBOI_INSTANCE_ID}..."
  ROBOI_ENV_FILE="$env_file" ROBOI_AUTH_DIR="${ROBOI_INSTANCE_DIR}/opencode" "$AUTH_RENDERER"
}

deploy_instance() {
  local env_file="$1"

  load_instance_env "$env_file"
  mkdir -p "${ROBOI_INSTANCE_DIR}/data" "${ROBOI_INSTANCE_DIR}/opencode"

  render_instance_auth "$env_file"

  log "Running SQLite migrations for Roboi instance ${ROBOI_INSTANCE_ID}..."
  compose_for_instance --profile manual run --rm migrate

  log "Restarting Roboi instance ${ROBOI_INSTANCE_ID}..."
  compose_for_instance up -d opencode api worker

  wait_for_service_health "opencode" "OpenCode"
  wait_for_service_health "api" "API"
}

render_caddy_instances() {
  mkdir -p "$CADDY_INSTANCE_DIR"

  local tmp_file
  tmp_file="$(mktemp "${CADDY_INSTANCE_DIR}/roboi-instances.XXXXXX")"
  chmod 600 "$tmp_file"

  {
    printf "# Generated by /opt/apps/scripts/deploy-roboi.sh. Do not edit by hand.\n\n"
  } > "$tmp_file"

  while IFS= read -r env_file; do
    [ -n "$env_file" ] || continue
    load_instance_env "$env_file"

    cat >> "$tmp_file" <<EOF
${ROBOI_HOSTS} {
  header X-Robots-Tag "noindex, nofollow"

  @health path /health

  handle @health {
    reverse_proxy ${ROBOI_API_CONTAINER}:3000
  }

  handle {
    basic_auth {
      ${ROBOI_BASIC_AUTH_USER} ${ROBOI_BASIC_AUTH_HASH}
    }
    reverse_proxy ${ROBOI_API_CONTAINER}:3000
  }
}

EOF
  done < <(instance_env_files)

  mv "$tmp_file" "$CADDY_INSTANCE_FILE"
  chmod 600 "$CADDY_INSTANCE_FILE"
}

reload_caddy() {
  cd "$COMPOSE_DIR"

  log "Validating candidate Caddy config..."
  docker run --rm \
    -v "${COMPOSE_DIR}/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "${CADDY_INSTANCE_DIR}:/etc/caddy/roboi-instances:ro" \
    caddy:2 caddy validate --config /etc/caddy/Caddyfile

  log "Ensuring Caddy has the generated Roboi route mount..."
  docker compose up -d caddy

  log "Validating live Caddy config..."
  docker exec apps-caddy-1 caddy validate --config /etc/caddy/Caddyfile

  log "Reloading Caddy config..."
  docker exec apps-caddy-1 caddy reload --config /etc/caddy/Caddyfile
}

main() {
  mkdir -p /opt/apps/runtime/logs
  mkdir -p "$INSTANCE_ROOT"
  mkdir -p "$CADDY_INSTANCE_DIR"
  mkdir -p /opt/apps/apps

  load_env_file "/opt/apps/.env"

  log "========================================="
  log "Starting Roboi multi-instance deployment"
  log "========================================="

  ensure_legacy_instance_if_needed
  prepare_repo
  build_image

  while IFS= read -r env_file; do
    [ -n "$env_file" ] || continue
    deploy_instance "$env_file"
  done < <(instance_env_files)

  render_caddy_instances
  reload_caddy

  log "Roboi deployment completed successfully"
  log "========================================="
}

main "$@"
