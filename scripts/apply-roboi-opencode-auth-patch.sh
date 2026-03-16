#!/bin/bash

set -euo pipefail

COMPOSE_DIR="/opt/apps"
SERVICE_NAME="roboi-opencode"
TARGET_FILE="/root/.cache/opencode/node_modules/opencode-anthropic-auth/index.mjs"
PATCH_FILE="/opt/apps/scripts/runtime-patches/opencode-anthropic-auth-refresh.patch"
PATCH_MARKER="Roboi runtime patch: serialize Anthropic OAuth refresh"

TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

cd "$COMPOSE_DIR"

CONTAINER_ID="$(docker compose ps -q "$SERVICE_NAME")"
if [ -z "$CONTAINER_ID" ]; then
  echo "ERROR: could not find running container for $SERVICE_NAME" >&2
  exit 1
fi

if [ ! -f "$PATCH_FILE" ]; then
  echo "ERROR: patch file not found at $PATCH_FILE" >&2
  exit 1
fi

if docker exec "$CONTAINER_ID" sh -lc "grep -Fq \"$PATCH_MARKER\" \"$TARGET_FILE\""; then
  echo "Roboi Anthropic auth runtime patch already applied"
  exit 0
fi

docker cp "$CONTAINER_ID:$TARGET_FILE" "$TMP_DIR/index.mjs"
patch "$TMP_DIR/index.mjs" < "$PATCH_FILE"

if ! grep -Fq "$PATCH_MARKER" "$TMP_DIR/index.mjs"; then
  echo "ERROR: patched plugin is missing runtime patch marker" >&2
  exit 1
fi

docker cp "$TMP_DIR/index.mjs" "$CONTAINER_ID:$TARGET_FILE"

if ! docker exec "$CONTAINER_ID" sh -lc "grep -Fq \"$PATCH_MARKER\" \"$TARGET_FILE\""; then
  echo "ERROR: failed to verify patched plugin in $SERVICE_NAME container" >&2
  exit 1
fi

echo "Roboi Anthropic auth runtime patch applied successfully"
