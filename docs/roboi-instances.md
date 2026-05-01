# Roboi Instances

Roboi runs as repeated single-tenant instances. Each instance serves one Ponta client, identified by the same client code used in `ROBOI_DEFAULT_CLIENT_CODE`.

The Roboi application code is shared across all instances. Isolation comes from separate Docker projects, runtime folders, SQLite databases, OpenCode state, hostnames, data-lake credentials, and local app users. Caddy is only the TLS reverse proxy; Roboi access is protected by app-level login inside each instance.

## Runtime Layout

Instance state lives outside git:

```text
/opt/apps/runtime/roboi-instances/<client-id>/
  instance.env
  data/roboi.db
  opencode/admin/auth.json
  opencode/admin/opencode.db
  opencode/owner/auth.json
  opencode/owner/opencode.db
  opencode/operator/auth.json
  opencode/operator/opencode.db
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

## Data-Lake Provisioning

Use one PostgreSQL database per Roboi client instance. The database name and roles are derived from the client ID, so the process is deterministic and repeatable.

```bash
/opt/apps/scripts/provision-roboi-datalake-client.sh <client-id>
```

For client ID `BJVRB11LIH`, the script creates:

- database `roboi_bjvrb11lih`
- write-capable ingestion role `roboi_bjvrb11lih_ingest`
- read-only app roles `roboi_bjvrb11lih_admin_ro`, `roboi_bjvrb11lih_owner_ro`, and `roboi_bjvrb11lih_operator_ro`

The script prints generated passwords and connection URLs once. Store the host-side ingestion URL only in the ingestion runner configuration:

```text
ROBOI_INGEST_PG_URL='postgresql://...'
```

Store the app read-only URLs in the instance `instance.env`:

```text
ROBOI_DATALAKE_URL_ADMIN='postgresql://...'
ROBOI_DATALAKE_URL_OWNER='postgresql://...'
ROBOI_DATALAKE_URL_OPERATOR='postgresql://...'
```

The app and OpenCode containers must never receive the ingestion URL.

At bootstrap, all three app read roles can read base tables in `consume_zone` and `integration_zone`. Role-specific restricted views can be added later without changing the app routing model.

Then fill the required values in:

```text
/opt/apps/runtime/roboi-instances/<client-id>/instance.env
```

Required per instance:

- `ROBOI_HOSTS`
- `ROBOI_DEFAULT_CLIENT_CODE`
- `ROBOI_DATALAKE_URL_ADMIN`
- `ROBOI_DATALAKE_URL_OWNER`
- `ROBOI_DATALAKE_URL_OPERATOR`
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

Roles are `admin`, `owner`, and `operator`. Each role routes to its matching read-only data-lake credential for that instance.

`create` and `reset-password` print the generated password once. Users can change their password from the app after logging in.

## Adding a Client

1. Choose the client ID and a friendly hostname.
2. Point the hostname DNS to the VPS.
3. Run `provision-roboi-datalake-client.sh` with the client ID and save the printed URLs.
4. Run `create-roboi-instance.sh` with the client ID and hostname list.
5. Fill the instance data-lake URLs, OpenCode password, and Anthropic API key.
6. Run the ingestion job with the printed `ROBOI_INGEST_PG_URL`.
7. Run `deploy-roboi.sh`.
8. Create the initial app users with `roboi-user.sh`.
9. Verify the hostname loads the login page and unauthenticated `/v1/*` routes return `401`.

The same `deploy-roboi.sh` command deploys updates to every instance. New Roboi app releases build one shared image and restart all configured instances with their own runtime state.

## Isolation Rules

- Do not commit `instance.env`, SQLite files, OpenCode state, or generated Caddy runtime files.
- Use one data-lake read-only credential per app role in each client instance.
- Do not expose ingestion or write-capable data-lake credentials to the Roboi API, worker, or OpenCode containers.
- Do not put farm-specific documents or private client context in the shared Roboi image.
- Add each client-facing hostname only to the instance that owns that client ID.
- Keep Ponta-wide hostnames on the Ponta instance only.
