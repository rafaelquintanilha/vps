---
description: Update n8n to the latest version following Docker best practices
allowed-tools: Bash(*), TodoWrite
---

# Update n8n to Latest Version

Update the n8n installation to the latest version by:

1. Use TodoWrite to create a task list for tracking the update process
2. Stop the current n8n container: `docker compose stop n8n`
3. Pull the latest n8n base image: `docker pull n8nio/n8n:latest`
4. Rebuild the custom n8n image with Playwright support: `docker compose build n8n --no-cache`
5. Start the updated container: `docker compose up -d n8n`
6. Verify the update by checking:
   - Container logs: `docker logs apps-n8n-1 --tail 20`
   - Container status: `docker ps | grep n8n`
   - n8n version: `docker exec apps-n8n-1 n8n --version`

The system uses a custom Dockerfile at `./n8n-playwright/Dockerfile` that extends the official n8n image with Chromium, Puppeteer, and Playwright support for web automation workflows.

Important: This maintains all existing workflows, data, and configuration while updating to the latest n8n version.