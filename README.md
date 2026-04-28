# VPS Infrastructure

This repository contains the infrastructure configuration for the VPS hosting multiple applications.

## Structure

- `scripts/` - Deployment and monitoring scripts
- `runtime/` - Runtime files (gitignored)
- `apps/` - Application deployments (gitignored)
- `docker-compose.yml` - Main infrastructure configuration

## Deployment

Webhook-triggered deployment pipeline with cron monitoring.

## Roboi

Roboi runs as isolated per-client instances. See [docs/roboi-instances.md](docs/roboi-instances.md) for instance creation, deployment, and local user management.
