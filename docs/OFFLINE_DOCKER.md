# Offline Docker Deployment Guide

> 繁體中文版：[OFFLINE_DOCKER_zh-TW.md](OFFLINE_DOCKER_zh-TW.md)

This guide covers the complete lifecycle of an **offline (air-gapped) Docker deployment** of jt-ipam:
**Package → Install → Backup → Restore → Upgrade**.

Use the offline deployment when the target host has **no internet access** or when you want
**deterministic, pre-built images** for production.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Packaging (on a machine with internet)](#3-packaging-on-a-machine-with-internet)
4. [Installation (on the offline host)](#4-installation-on-the-offline-host)
5. [Backup](#5-backup)
6. [Restore](#6-restore)
7. [Upgrade](#7-upgrade)

---

## 1. Architecture Overview

The offline package is a self-contained tarball that includes everything needed to run jt-ipam
without internet access:

| Service | Role | Image source |
|---------|------|-------------|
| `postgres` | PostgreSQL 16 + pgvector | Pulled from Docker Hub during build |
| `redis` | Session cache, rate limiting | Pulled from Docker Hub during build |
| `backend` | FastAPI uvicorn (4 workers) | Built or pulled during build |
| `frontend` | nginx serving SPA + reverse proxy | Built or pulled during build |
| `sync` | Background integration loop | Same image as `backend` |

The package contains **5 services** managed via a single `docker-compose.yml` file.

### File layout of the package

```
jt-ipam-offline/
├── images.tar                    # All Docker images bundled together
├── docker-compose.yml            # Service definitions (local image refs)
├── .env.example                  # Environment variable template
├── install.sh                    # One-shot installer
├── deploy/
│   ├── postgres/
│   │   └── init-docker.sh        # PG extension init
│   └── nginx/
│       └── jt-ipam-docker.conf   # nginx config for Compose
├── scripts/
│   ├── docker-backup.sh          # Backup convenience script
│   └── docker-restore.sh         # Restore convenience script
└── MANIFEST.txt                  # Package contents listing
```

---

## 2. Prerequisites

### Build machine (internet access)

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Linux (any modern distro) | Ubuntu 22.04+ / Debian 12+ |
| Docker Engine | 24.x | 27.x+ with `docker compose` plugin |
| Disk space | 10 GB free | 20 GB free (images + build cache) |
| Network | Outbound to Docker Hub | Broadband |

### Target host (offline / air-gapped)

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Linux (any modern distro) | Ubuntu 22.04+ / Debian 12+ |
| Docker Engine | 24.x | 27.x+ with `docker compose` plugin |
| Disk space | 4 GB free | 8 GB free (database + uploads) |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |

---

## 3. Packaging (on a machine with internet)

Run the build script from the **repository root** on a machine with internet access.

### 3.1 Build from source (default)

```bash
# Clone the repository
git clone https://github.com/jasoncheng7115/jt-ipam.git
cd jt-ipam

# Build images and create the offline package
./scripts/build-docker-package.sh
```

The script:
1. Builds `backend` and `frontend` images from their Dockerfiles
2. Pulls `postgres` and `redis` images from Docker Hub
3. Generates a `docker-compose.yml` referencing local image tags
4. Generates `install.sh`, `MANIFEST.txt`
5. Packages everything into `jt-ipam-offline-<timestamp>.tar.gz`

### 3.2 Pull pre-built images from a registry

If you maintain a private registry:

```bash
./scripts/build-docker-package.sh \
  --pull-from registry.example.com/jt-ipam \
  --pull-tag v0.4.207
```

This pulls `registry.example.com/jt-ipam_jt-ipam_backend:v0.4.207` and
`registry.example.com/jt-ipam_jt-ipam_frontend:v0.4.207`, re-tags them to the
local tag, and bundles them.

### 3.3 Options reference

| Option | Default | Description |
|--------|---------|-------------|
| `-t, --tag TAG` | `offline` | Image tag suffix |
| `-o, --output FILE` | `jt-ipam-offline-<ts>.tar.gz` | Output tarball path |
| `-p, --prefix PREFIX` | `jt-ipam` | Local image name prefix |
| `--no-cache` | — | Pass `--no-cache` to `docker build` |
| `--pull-from REGISTRY` | — | Pull pre-built images from REGISTRY |
| `--pull-tag TAG` | `latest` | Tag of images in the registry |
| `-h, --help` | — | Show help |

### 3.4 Output

```
jt-ipam-offline-20260621-143000.tar.gz
```

Verify the package:

```bash
tar tzf jt-ipam-offline-20260621-143000.tar.gz
# Expect: jt-ipam-offline/images.tar, docker-compose.yml, install.sh, ...
```

---

## 4. Installation (on the offline host)

Transfer the tarball to the target host via USB drive, SCP, or any out-of-band method.

### 4.1 Extract and install

```bash
# Extract the package
tar xzf jt-ipam-offline-*.tar.gz
cd jt-ipam-offline

# Run the installer (interactive)
./install.sh
```

The installer (`install.sh`) performs these steps automatically:

| Step | What it does |
|------|-------------|
| Pre-flight | Checks `docker` and `docker compose` are available |
| Copy files | Copies all package files to the install directory |
| Load images | Runs `docker load -i images.tar` (loads all 4 images) |
| Configure | If `.env` does not exist, generates one with secure random secrets |
| Start | Prompts to start the stack via `docker compose up -d --wait` |

### 4.2 Non-interactive installation

```bash
# Specify install directory (skips the directory prompt)
./install.sh -d /opt/jt-ipam
```

### 4.3 Manual installation (without install.sh)

If you prefer full control:

```bash
# 1. Create install directory
mkdir -p /opt/jt-ipam/backups
cp images.tar docker-compose.yml .env.example /opt/jt-ipam/
cp -r deploy/ scripts/ /opt/jt-ipam/

# 2. Load images
docker load -i /opt/jt-ipam/images.tar

# 3. Create .env (edit with your secrets)
cp /opt/jt-ipam/.env.example /opt/jt-ipam/.env
# Edit .env — at minimum set:
#   POSTGRES_PASSWORD, SECRET_KEY, ENCRYPTION_KEY
#   BOOTSTRAP_ADMIN_PASSWORD (≥ 12 chars)

# 4. Start the stack
cd /opt/jt-ipam
docker compose up -d --wait
```

### 4.4 First login

After the stack starts (wait ~30s for migrations):

```
URL:      http://<host-ip>:8080
Username: admin
Password: <value set in BOOTSTRAP_ADMIN_PASSWORD in .env>
```

If the admin password was generated automatically by `install.sh`, check the install
output — it is printed once. You can also view the current `.env`:

```bash
grep BOOTSTRAP_ADMIN_PASSWORD /opt/jt-ipam/.env
```

---

## 5. Backup

Two methods: the convenience script (recommended) or the compose service directly.

### 5.1 Using the convenience script (recommended)

```bash
cd /opt/jt-ipam
bash scripts/docker-backup.sh
```

This script:
1. Runs the `backup` compose service (with `--name` to keep the container)
2. Copies backup artifacts from the container to `./backups/` via `docker cp`
3. Removes the temporary container

**Output** (in `./backups/`):

| Artifact | Description |
|----------|-------------|
| `jt-ipam-<YYYYMMDD_HHMMSS>.sql.gz` | PostgreSQL dump (pg_dump \| gzip) |
| `jt-ipam-<YYYYMMDD_HHMMSS>.uploads.tar.gz` | Uploaded files (floorplans, rack diagrams) |

It is recommended to also save the `.env` file alongside the backup:

```bash
cp .env backups/jt-ipam-<TIMESTAMP>.env
```

### 5.2 Using the compose service directly

```bash
cd /opt/jt-ipam

# Create backup (bind-mount workaround required on Docker 29.x)
docker compose run --name backup-tmp backup
docker cp backup-tmp:/backups/. ./backups/
docker rm backup-tmp

# Verify the latest backup
docker compose run --rm backup-verify
```

### 5.3 Scheduling regular backups

Add a cron job (as root or a user with docker access):

```cron
# Daily at 2 AM
0 2 * * * cd /opt/jt-ipam && bash scripts/docker-backup.sh >> /var/log/jt-ipam-backup.log 2>&1
```

### 5.4 Cross-host migration

```bash
# Source host: create a backup
bash scripts/docker-backup.sh

# Copy to target host
scp ./backups/jt-ipam-<ts>* target-host:/opt/jt-ipam/backups/

# Target host: restore (see §6)
cp /opt/jt-ipam/backups/jt-ipam-<ts>.env /opt/jt-ipam/.env
bash scripts/docker-restore.sh <ts>
```

---

## 6. Restore

### 6.1 Using the convenience script (recommended)

```bash
cd /opt/jt-ipam

# List available backups
bash scripts/docker-restore.sh

# Restore the latest backup
bash scripts/docker-restore.sh latest

# Restore a specific backup
bash scripts/docker-restore.sh 20260619_141141
```

The script:
1. Terminates active connections to the `jt_ipam` database
2. Runs the `restore` compose service (drops + recreates database, imports SQL, rebuilds extensions, restores uploads)
3. Restarts the backend container
4. Waits for the backend to become healthy

> **Warning:** Restore **drops** the current database and replaces it. The stack
> must be running (`docker compose up -d`) before restoring.

### 6.2 Using the compose service directly

```bash
cd /opt/jt-ipam

# Terminate database connections
docker compose exec -T postgres psql -U jt_ipam -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='jt_ipam' AND pid <> pg_backend_pid();"

# Run restore
docker compose run --rm -e BACKUP_FILE=20260619_141141 restore

# Restart backend
docker compose restart backend
```

### 6.3 Verify integrity of a backup

```bash
docker compose run --rm backup-verify

# Or verify a specific file
docker compose run --rm -e BACKUP_FILE=20260619_141141 backup-verify
```

---

## 7. Upgrade

Upgrading an existing offline installation means applying a **new offline package**
(containing updated images and possibly a new `docker-compose.yml`) to a running stack.

### 7.1 Upgrade process

```bash
# 1. (Optional but recommended) Backup first
cd /opt/jt-ipam
bash scripts/docker-backup.sh
cp .env backups/jt-ipam-$(date +%Y%m%d_%H%M%S).env

# 2. Extract the new package
tar xzf /path/to/new/jt-ipam-offline-*.tar.gz
cd jt-ipam-offline

# 3. Load updated images (overwrites existing tags)
docker load -i images.tar

# 4. Copy the new docker-compose.yml
cp docker-compose.yml /opt/jt-ipam/docker-compose.yml

# 5. (Optional) Update helper scripts if they changed
cp scripts/docker-backup.sh scripts/docker-restore.sh /opt/jt-ipam/scripts/

# 6. Recreate all services with the new images
cd /opt/jt-ipam
docker compose up -d --force-recreate

# 7. Verify
docker compose ps
docker compose logs --tail 10 sync
```

### 7.2 What `--force-recreate` does

| Service | Behavior |
|---------|----------|
| `postgres` | Recreated (data in volume `pgdata` is preserved) |
| `redis` | Recreated (data in volume `redis-data` is preserved) |
| `backend` | Recreated with new image, Alembic migrations run on startup |
| `frontend` | Recreated with new image |
| `sync` | Created if new to this version; otherwise recreated |

### 7.3 What is preserved

| Data | Location | Safe? |
|------|----------|-------|
| PostgreSQL data | `pgdata` volume (Docker) | ✅ Yes — volume is not removed |
| Redis data | `redis-data` volume (Docker) | ✅ Yes — volume is not removed |
| Uploaded files | `uploads` volume (Docker) | ✅ Yes — volume is not removed |
| `.env` secrets | File on host | ✅ Yes — not overwritten |
| Backup files | `./backups/` directory | ✅ Yes — not touched |

### 7.4 What to check after upgrade

1. **Migrations**: Check backend logs for Alembic migration output
   ```bash
   docker compose logs backend | grep -i alembic
   ```

2. **Sync service**: Confirm the sync loop is running
   ```bash
   docker compose logs --tail 5 sync
   # Expected: "[sync] cycle start: ..."
   ```

3. **Health**: All services should show `(healthy)` or `(started)`
   ```bash
   docker compose ps
   ```

4. **Functionality**: Log in to the web UI and verify core features

### 7.5 Using the new install.sh for upgrade

The `install.sh` from a new package can also serve as an upgrade tool, with caveats:

```bash
./install.sh -d /opt/jt-ipam
```

| What happens | OK? |
|-------------|-----|
| `docker-compose.yml` overwritten | ✅ Required to pick up new services |
| `images.tar` loaded | ✅ Tags overwrite old ones |
| `.env` preserved (already exists) | ✅ Secrets kept |
| `scripts/` overwritten | ✅ Unless customized |
| `docker compose up -d --wait` | ⚠️ — does **not** force-recreate; existing containers keep old images |

If using `install.sh` for upgrade, follow up with:

```bash
cd /opt/jt-ipam
docker compose up -d --force-recreate
```

---

## Appendix A: Environment variables

Key variables in `.env` (see [`.env.docker.example`](../.env.docker.example) for the full list):

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `POSTGRES_PASSWORD` | yes | — | Postgres superuser password |
| `SECRET_KEY` | yes | — | JWT signing key (`openssl rand -hex 32`) |
| `ENCRYPTION_KEY` | yes | — | AES-256-GCM key (`openssl rand -base64 32`) |
| `AUDIT_CHAIN_GENESIS` | yes | — | Audit chain genesis hash (`openssl rand -hex 64`) |
| `BOOTSTRAP_ADMIN_USERNAME` | no | `admin` | Initial admin account username |
| `BOOTSTRAP_ADMIN_PASSWORD` | yes* | — | *Required for auto-seed on first start |
| `BOOTSTRAP_ADMIN_EMAIL` | no | `admin@example.com` | Initial admin email |
| `APP_ENV` | no | `development` | Set to `production` for stricter security |
| `APP_PUBLIC_URL` | no | — | Public-facing URL (needed for OIDC/CORS) |
| `API_PUBLIC_URL` | no | — | Public-facing API URL |
| `FRONTEND_PORT` | no | `8080` | Host port for the frontend |
| `SYNC_INTERVAL_SECONDS` | no | `300` | Sync loop interval (seconds) |
| `BACKEND_TLS_MODE` | no | `docker-compose` | TLS mode; must be `docker-compose` for Compose |
| `RATE_LIMIT_ENABLED` | no | `true` | Enable rate limiting |
| `OUTBOUND_ALLOW_PRIVATE` | no | `true` | Allow private IP outbound (needed for integrations) |

## Appendix B: Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `docker compose up -d` fails | Port 8080 already in use | Change `FRONTEND_PORT` in `.env` |
| Backend not healthy after startup | Missing env vars | Check `.env` has all required values |
| Sync container exits immediately | Backend not ready | Check `depends_on` — sync waits for backend healthy |
| `docker load` fails | Corrupted images.tar | Rebuild the package with a fresh `docker build` |
| `ENCRYPTION_KEY` error | Invalid format | Regenerate with `openssl rand -base64 32` |
| `.env` changes not picked up | Docker Compose caches env | `docker compose up -d --force-recreate` |

## Appendix C: Quick reference

```bash
# Package
./scripts/build-docker-package.sh

# Install
tar xzf jt-ipam-offline-*.tar.gz && cd jt-ipam-offline && ./install.sh

# Backup
cd /opt/jt-ipam && bash scripts/docker-backup.sh

# Restore (list)
bash scripts/docker-restore.sh
# Restore (specific)
bash scripts/docker-restore.sh latest

# Upgrade
docker load -i /path/to/new/images.tar
cp /path/to/new/docker-compose.yml /opt/jt-ipam/
cd /opt/jt-ipam && docker compose up -d --force-recreate
```
