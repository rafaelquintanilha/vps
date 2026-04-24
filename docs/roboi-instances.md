# Roboi Instances

Roboi runs as repeated single-tenant instances. Each instance serves one Ponta client, identified by the same client code used in `ROBOI_DEFAULT_CLIENT_CODE`.

The Roboi application code is shared. Instance isolation comes from separate Docker projects, runtime folders, SQLite databases, OpenCode state, hostnames, Basic Auth credentials, and data-lake credentials.

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

## Creating an Instance

```bash
/opt/apps/scripts/create-roboi-instance.sh <client-id> <host[,host2,...]>
```

Example:

```bash
/opt/apps/scripts/create-roboi-instance.sh 2E010C734C roboi.rafaelquintanilha.com,roboi.69.62.89.22.nip.io
```

Then fill the required values in:

```text
/opt/apps/runtime/roboi-instances/<client-id>/instance.env
```

Required per instance:

- `ROBOI_HOSTS`
- `ROBOI_DEFAULT_CLIENT_CODE`
- `ROBOI_DATALAKE_URL`
- `ROBOI_BASIC_AUTH_USER`
- `ROBOI_BASIC_AUTH_HASH`
- `ROBOI_OPENCODE_SERVER_PASSWORD`
- `ROBOI_ANTHROPIC_API_KEY`

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
8. validates and reloads Caddy

## Isolation Rules

- Do not commit `instance.env`, SQLite files, OpenCode state, or generated Caddy runtime files.
- Use one data-lake read-only credential per client when available.
- Do not put farm-specific documents or private client context in the shared Roboi image.
- Use mounted per-instance files for future client-specific knowledge.
