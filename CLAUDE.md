# VPS Apps Configuration

## Docker Compose

**CRITICAL**: Always use `docker compose` (v2 plugin, with space), never `docker-compose` (v1 standalone, with hyphen).

```bash
# Correct
docker compose up -d
docker compose ps
docker compose logs

# WRONG - never use this
docker-compose up -d
```

The system has both versions installed and they use different project naming conventions. Mixing them causes containers to be orphaned or misnamed.

## Services

| Service | Port | Domain |
|---------|------|--------|
| pronto-backend | 3001 | pronto.rafaelquintanilha.com |
| postgres | 5432 | - |
| redis | 6380 | - |
| n8n | 5678 | n8n.quantbrasil.com.br |
| metabase | 3000 | metabase.quantbrasil.com.br |
| caddy | 80/443 | - |

## Pronto Deployment

Deployments are triggered automatically via GitHub webhook. The deploy script is at `/opt/apps/scripts/deploy-pronto.sh`.

Logs: `/opt/apps/runtime/logs/pronto-deploy.log`

## Database Backups

Daily PostgreSQL backups to S3 run at 3 AM via cron. Script: `/opt/apps/scripts/backup/pg-backup-s3.sh`
