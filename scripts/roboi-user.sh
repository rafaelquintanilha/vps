#!/bin/bash

set -euo pipefail

INSTANCE_ROOT="${ROBOI_INSTANCE_ROOT:-/opt/apps/runtime/roboi-instances}"

usage() {
  cat >&2 <<'EOF'
Usage: roboi-user.sh <client-id> <user-command> [args...]

Examples:
  roboi-user.sh BJVRB11LIH create --email admin@example.com --name "Admin" --role admin
  roboi-user.sh BJVRB11LIH list
  roboi-user.sh BJVRB11LIH reset-password --email admin@example.com
  roboi-user.sh BJVRB11LIH disable --email admin@example.com
EOF
}

validate_instance_id() {
  local instance_id="$1"

  if [[ ! "$instance_id" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "ERROR: invalid Roboi instance id: $instance_id" >&2
    exit 1
  fi
}

project_name_for_instance() {
  local instance_id="$1"
  local slug

  slug="$(printf "%s" "$instance_id" | tr "[:upper:]" "[:lower:]" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$slug" ]; then
    echo "ERROR: could not derive Docker project name for instance: $instance_id" >&2
    exit 1
  fi

  printf "roboi-%s" "$slug"
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

INSTANCE_ID="$1"
shift

validate_instance_id "$INSTANCE_ID"

ENV_FILE="${INSTANCE_ROOT}/${INSTANCE_ID}/instance.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: Roboi instance does not exist: $ENV_FILE" >&2
  exit 1
fi

API_CONTAINER="$(project_name_for_instance "$INSTANCE_ID")-api"
if ! docker ps --format "{{.Names}}" | grep -Fxq "$API_CONTAINER"; then
  echo "ERROR: Roboi API container is not running: $API_CONTAINER" >&2
  exit 1
fi

DOCKER_EXEC_ARGS=(-i)
if [ -t 0 ] && [ -t 1 ]; then
  DOCKER_EXEC_ARGS=(-it)
fi

exec docker exec "${DOCKER_EXEC_ARGS[@]}" "$API_CONTAINER" bun run user "$@"
