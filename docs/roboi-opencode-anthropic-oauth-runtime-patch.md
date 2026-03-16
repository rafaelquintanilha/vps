# Roboi OpenCode Anthropic OAuth Runtime Patch

## Why this exists

Roboi uses the `opencode-anthropic-auth@0.0.13` runtime plugin inside the `roboi-opencode` container. Anthropic access tokens currently expire after about 8 hours, so the system depends on the plugin's refresh flow staying healthy.

The stock plugin is not robust enough for Roboi's traffic pattern:

- it refreshes without any cross-request lock
- it persists refreshed auth state to storage, but only updates `auth.access` in memory
- it does not keep `auth.refresh` or `auth.expires` in sync in memory

In practice that led to repeated `Token refresh failed: 400` errors on the first real request after the token crossed its expiry boundary.

## What is patched

Runtime target inside the live `roboi-opencode` container:

- `/root/.cache/opencode/node_modules/opencode-anthropic-auth/index.mjs`

The patch does three things:

1. serializes refresh calls with a filesystem lock in `/tmp`
2. re-reads current auth state after taking the lock so one request can reuse another request's successful refresh
3. updates in-memory `access`, `refresh`, and `expires` after a successful refresh

Patch artifact:

- `/opt/apps/scripts/runtime-patches/opencode-anthropic-auth-refresh.patch`

Patch helper:

- `/opt/apps/scripts/apply-roboi-opencode-auth-patch.sh`

## How deploy keeps it durable

`/opt/apps/scripts/deploy-roboi.sh` now:

1. rebuilds and starts the Roboi services
2. applies the runtime patch to the fresh `roboi-opencode` container
3. restarts `roboi-opencode` and `roboi-worker`
4. runs the normal health checks

This is needed because the plugin lives in the container filesystem, so a container recreate removes any prior live edit.

## Operational notes

- The helper is idempotent. It checks for the marker comment before patching.
- If the upstream plugin changes enough that the patch no longer applies cleanly, deploy will fail loudly instead of silently shipping the broken stock plugin.
- If the plugin version changes in the future, review and update the patch before removing this mechanism.
