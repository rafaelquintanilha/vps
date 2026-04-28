# Roboi Instances

Roboi runs as repeated single-tenant instances. Each instance serves one Ponta client, identified by the same client code used in `ROBOI_DEFAULT_CLIENT_CODE`.

The Roboi application code is shared across all instances. Isolation comes from separate Docker projects, runtime folders, SQLite databases, OpenCode state, hostnames, data-lake credentials, and local app users. Caddy is only the TLS reverse proxy; Roboi access is protected by app-level login inside each instance.

## Runtime Layout

Instance state lives outside git:

```text
/opt/apps/runtime/roboi-instances/<client-id>/
  instance.env
  data/roboi.db
  opencode/auth.json
  opencode/opencode.db
```

The `<client-id>` directory name must match `ROBOI_DEFAULT_CLIENT_CODE` in `instance.env`.

Generated Caddy routes also live outside git:

```text
/opt/apps/runtime/roboi-caddy/roboi-instances.caddy
```

## Creating an Instance

```bash
/opt/apps/scripts/create-roboi-instance.sh <client-id> <host[,host2,...]>
```

Example:

```bash
/opt/apps/scripts/create-roboi-instance.sh BJVRB11LIH fazenda-exemplo.roboi.rafaelquintanilha.com
```

Use a friendly hostname or internal alias. Do not put the raw client ID in public hostnames unless the hostname is intentionally internal and temporary.

Then fill the required values in:

```text
/opt/apps/runtime/roboi-instances/<client-id>/instance.env
```

Required per instance:

- `ROBOI_HOSTS`
- `ROBOI_DEFAULT_CLIENT_CODE`
- `ROBOI_DATALAKE_URL`
- `ROBOI_OPENCODE_SERVER_PASSWORD`
- `ROBOI_ANTHROPIC_API_KEY`

Optional per-instance tuning:

- `ROBOI_DATALAKE_DEFAULT_LIMIT`
- `ROBOI_DATALAKE_MAX_LIMIT`
- `ROBOI_DATALAKE_STATEMENT_TIMEOUT_MS`
- `ROBOI_POLL_INTERVAL_MS`
- `ROBOI_WORKER_CONCURRENCY`
- `ROBOI_JOB_TIMEOUT_MS`

## Deploying

```bash
/opt/apps/scripts/deploy-roboi.sh
```

The deploy script:

1. pulls `quantbrasil/roboi` from `master`
2. builds one shared Roboi Docker image for the current commit
3. discovers every `instance.env` under `/opt/apps/runtime/roboi-instances`
4. renders OpenCode auth for each instance
5. runs SQLite migrations for each instance
6. restarts each instance
7. generates Caddy routes for all instances
8. validates and applies the Caddy routes

If no instance exists yet, the deploy script creates the first instance from the legacy `/opt/apps/.env` Roboi values and copies `/opt/apps/runtime/roboi` into the matching instance folder before starting the instance.

## User Management

Users are local to each instance database.

```bash
/opt/apps/scripts/roboi-user.sh <client-id> create --email admin@example.com --name "Admin" --role admin
/opt/apps/scripts/roboi-user.sh <client-id> list
/opt/apps/scripts/roboi-user.sh <client-id> reset-password --email admin@example.com
/opt/apps/scripts/roboi-user.sh <client-id> disable --email admin@example.com
```

Roles are `admin`, `owner`, and `operator`. In the current app, roles are stored for future permission work but all authenticated users can use the instance.

`create` and `reset-password` print the generated password once. Users can change their password from the app after logging in.

## Adding a Client

1. Choose the client ID and a friendly hostname.
2. Point the hostname DNS to the VPS.
3. Run `create-roboi-instance.sh` with the client ID and hostname list.
4. Fill the instance `ROBOI_DATALAKE_URL`, OpenCode password, and Anthropic API key.
5. Run `deploy-roboi.sh`.
6. Create the initial app users with `roboi-user.sh`.
7. Verify the hostname loads the login page and unauthenticated `/v1/*` routes return `401`.

The same `deploy-roboi.sh` command deploys updates to every instance. New Roboi app releases build one shared image and restart all configured instances with their own runtime state.

## Isolation Rules

- Do not commit `instance.env`, SQLite files, OpenCode state, or generated Caddy runtime files.
- Use one data-lake read-only credential per client when available.
- Do not put farm-specific documents or private client context in the shared Roboi image.
- Add each client-facing hostname only to the instance that owns that client ID.
- Keep Ponta-wide hostnames on the Ponta instance only.
