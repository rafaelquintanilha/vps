#!/bin/bash

set -euo pipefail

if [ -f /opt/apps/.env ]; then
  set -a
  source /opt/apps/.env
  set +a
fi

if [ -n "${ROBOI_ENV_FILE:-}" ] && [ -f "$ROBOI_ENV_FILE" ]; then
  set -a
  source "$ROBOI_ENV_FILE"
  set +a
fi

AUTH_DIR="${ROBOI_AUTH_DIR:-/opt/apps/runtime/roboi/opencode}"
AUTH_FILE="${AUTH_DIR}/auth.json"

if [ -z "${ROBOI_ANTHROPIC_API_KEY:-}" ]; then
  echo "ERROR: ROBOI_ANTHROPIC_API_KEY is not set" >&2
  exit 1
fi

mkdir -p "$AUTH_DIR"

AUTH_FILE="$AUTH_FILE" ROBOI_ANTHROPIC_API_KEY="$ROBOI_ANTHROPIC_API_KEY" python3 <<'PY'
import json
import os
from pathlib import Path

auth_file = Path(os.environ["AUTH_FILE"])
key = os.environ["ROBOI_ANTHROPIC_API_KEY"]

data = {}
if auth_file.exists():
    try:
        loaded = json.loads(auth_file.read_text())
        if isinstance(loaded, dict):
            data = loaded
    except Exception:
        data = {}

data["anthropic"] = {
    "type": "api",
    "key": key,
}

tmp_path = auth_file.with_suffix(auth_file.suffix + ".tmp")
tmp_path.write_text(json.dumps(data))
os.chmod(tmp_path, 0o600)
tmp_path.replace(auth_file)
os.chmod(auth_file, 0o600)
PY

echo "Roboi OpenCode auth rendered successfully"
