# Offline Docker Upgrade

## Context

The offline package (`jt-ipam-offline-*.tar.gz`) bundles Docker images and a
`docker-compose.yml` for air-gapped deployment. Upgrading means applying a new
package to a running stack without data loss.

## Recommended Upgrade (manual)

```bash
# 1. Backup first
cd /opt/jt-ipam
bash scripts/docker-backup.sh
cp .env backups/jt-ipam-$(date +%Y%m%d_%H%M%S).env

# 2. Load new images (overwrites old :offline tags)
docker load -i /path/to/new/jt-ipam-offline/images.tar

# 3. Update compose & scripts
cp /path/to/new/jt-ipam-offline/docker-compose.yml /opt/jt-ipam/
cp /path/to/new/jt-ipam-offline/scripts/docker-backup.sh /opt/jt-ipam/scripts/
cp /path/to/new/jt-ipam-offline/scripts/docker-restore.sh /opt/jt-ipam/scripts/

# 4. Force-recreate containers with new images
cd /opt/jt-ipam
docker compose up -d --force-recreate

# 5. Verify
docker compose ps
docker compose logs --tail 5 sync
```

## Using install.sh for Upgrade (not recommended)

`install.sh -d /opt/jt-ipam` preserves `.env` and loads images, but:

- **Does NOT `--force-recreate`** — existing containers keep old images.
- **Prompts interactively** — "Start the stack now?" even with `-d`.

If you use it, follow up with:
```bash
cd /opt/jt-ipam
docker compose up -d --force-recreate
```

## Key Facts

- `.env` is never overwritten by either method.
- Docker volumes (`pgdata`, `redis-data`, `uploads`) persist across
  `--force-recreate`.
- `docker compose up -d` without `--force-recreate` does NOT detect new
  images with the same tag — the underlying image ID change is invisible to
  Compose.
