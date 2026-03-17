# Roboi OpenCode Anthropic OAuth Runtime Patch

## Why this exists

Roboi uses the `opencode-anthropic-auth@0.0.13` runtime plugin inside the `roboi-opencode` container. Anthropic access tokens currently expire after about 8 hours, so the system depends on the plugin's refresh flow staying healthy.

The stock plugin is not robust enough for Roboi's traffic pattern:

- it refreshes without any cross-request lock
- it may overwrite the stored `refresh_token` with `null` or fail to preserve the previous one when Anthropic omits a new token in the refresh response
- it persists refreshed auth state to storage, but only updates `auth.access` in memory
- it does not keep `auth.refresh` or `auth.expires` in sync in memory
- it does not emit enough refresh diagnostics to explain whether Anthropic returned a new refresh token or omitted it
- after a successful refresh, the next request may still read stale auth from `getAuth()` instead of reusing the refreshed state
- it appears to trust OpenCode's internal auth setter even when the durable on-disk `auth.json` record does not advance with the refreshed token pair

In practice that led to repeated `Token refresh failed: 400` errors on the first real request after the token crossed its expiry boundary.

## What is patched

Runtime target inside the live `roboi-opencode` container:

- `/root/.cache/opencode/node_modules/opencode-anthropic-auth/index.mjs`

The patch does seven things:

1. serializes refresh calls with a filesystem lock in `/tmp`
2. re-reads current auth state after taking the lock so one request can reuse another request's successful refresh
3. preserves the previous `refresh_token` when Anthropic omits a replacement in the refresh response
4. updates in-memory `access`, `refresh`, and `expires` after a successful refresh
5. maintains a process-local OAuth cache so the next request can reuse freshly refreshed auth without waiting on storage propagation
6. writes refreshed Anthropic credentials directly to `~/.local/share/opencode/auth.json` with an atomic temp-file rename, instead of relying only on OpenCode's internal auth setter
7. emits sanitized refresh logs that show status, whether a refresh token was returned, whether the old token had to be preserved, and when cache or the auth file were preferred over stale storage

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
- Refresh diagnostics appear in the `roboi-opencode` container logs with the prefix `[roboi-anthropic-auth]`.
- Cache reuse is logged as `auth_resolved_from_cache` when the process has fresher auth than the stored record returned by `getAuth()`.
- Direct file reuse is logged as `auth_resolved_from_file` when `auth.json` is fresher than the auth returned by `getAuth()`.
