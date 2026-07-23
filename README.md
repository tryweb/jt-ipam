# jt-ipam (Docker Edition) · v0.5.108

[![License](https://img.shields.io/github/license/jasoncheng7115/jt-ipam?color=blue)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/jasoncheng7115/jt-ipam)](https://github.com/jasoncheng7115/jt-ipam/commits/main)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-async-009688?logo=fastapi&logoColor=white)
![Vue](https://img.shields.io/badge/Vue-3-42b883?logo=vuedotjs&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)

> **Docker-first** deployment of jt-ipam — a self-hosted, integration-focused IPAM with DNS, LibreNMS, firewall, and infrastructure integrations. Pull pre-built images from GitHub Container Registry and run in minutes.
>
> This is a Docker-first fork. For the upstream systemd-based version, see [UPSTREAM_README.md](UPSTREAM_README.md).
>
> By Jason Tools Co., Ltd. · License: Apache-2.0 · 繁體中文: [README_zh-TW.md](README_zh-TW.md)

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/tryweb/jt-ipam/main/install.sh | bash
```

The install script:

1. **Check** system requirements (2+ CPU cores, 4+ GB RAM, 10+ GB disk)
2. **Verify** Docker and Docker Compose are installed and running
3. **Resolve** the target online release (latest by default)
4. **Download** the matching runtime bundle release asset (no full repo checkout on production)
5. **Generate** `.env` with secure secrets (`SECRET_KEY`, `ENCRYPTION_KEY`, `POSTGRES_PASSWORD`)
6. **Prompt** for `APP_PUBLIC_URL` and admin credentials
7. **Pull** the configured pre-built images from GitHub Container Registry
8. **Start** all 5 services
9. **Wait** for health checks to pass and print maintenance tips

Wait 10–20 seconds for migrations and health checks, then visit **http://localhost:8080** (or your Docker host IP on port 8080).

> Re-running `install.sh` on an existing installation delegates to local `upgrade.sh`.

## Install channels

- **Online** — `curl -fsSL https://raw.githubusercontent.com/tryweb/jt-ipam/main/install.sh | bash`
  - uses GitHub Release runtime bundle assets
  - writes `INSTALL_CHANNEL=online` into `.env`
  - `bash upgrade.sh` performs online bundle upgrades
- **Offline** — built separately from `scripts/build-docker-package.sh`
  - loads images from `images.tar`
  - writes `INSTALL_CHANNEL=offline` into `.env`
  - `bash upgrade.sh --bundle /path/to/jt-ipam-offline-*.tar.gz` performs offline upgrades

Online and offline are intentionally separate flows.

## Upgrades

After installation, upgrade from the deployment directory:

```bash
bash upgrade.sh
```

- Online installs check the latest release runtime bundle by default.
- `bash upgrade.sh --tag vX.Y.Z` pins the environment to a specific release tag.
- Offline installs require a new offline package and `--bundle /path/to/jt-ipam-offline-*.tar.gz`.

## Local development

Build from source instead of pulling pre-built images:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

`docker-compose.dev.yml` is an overlay that adds `build:` sections for `backend`, `sync`, and `frontend`. Infrastructure services (postgres, redis) are unchanged.

## Services

| Service | Image | Role |
|---------|-------|------|
| `postgres` | `pgvector/pgvector:pg16` | PostgreSQL 16 + pgvector, extensions via init script |
| `redis` | `redis:7-alpine` | Session cache, rate limiting |
| `backend` | `ghcr.io/tryweb/jt-ipam-backend:latest` | FastAPI uvicorn (4 workers), Alembic on startup |
| `sync` | `ghcr.io/tryweb/jt-ipam-backend:latest` | Background integration loop (DNS, LibreNMS, …) |
| `frontend` | `ghcr.io/tryweb/jt-ipam-frontend:latest` | nginx:alpine serving SPA + reverse-proxying `/api/` to backend |

Override images via `BACKEND_IMAGE` / `FRONTEND_IMAGE` env vars.

- `.env.docker.example` defaults both to `:latest`.
- Online install/upgrade keeps `latest` unless you explicitly choose `--tag vX.Y.Z`.
- If you pin official images to a specific release tag, future online upgrades will keep managing those tag pins.
- Custom registries / custom image names are preserved and never overwritten automatically.

## Minimum host

**Minimum:** 2 vCPU · 4 GB RAM · 20 GB disk. **Recommended:** 4 vCPU · 8 GB RAM · 40 GB+ disk.

The optional local LLM (Ollama) is **not** included in these figures — run it on a separate host.

## Default credentials

| Field | Env variable | Default |
|-------|-------------|---------|
| Username | `BOOTSTRAP_ADMIN_USERNAME` | `admin` |
| Password | `BOOTSTRAP_ADMIN_PASSWORD` | see `.env` |
| Email | `BOOTSTRAP_ADMIN_EMAIL` | `admin@example.com` |

The entrypoint auto-seeds the admin on first start with `--force-update`; change the password in `.env` and `docker compose restart backend` to update it.

## Environment variables

Key variables in `.env` (see [`.env.docker.example`](.env.docker.example) for the full list):

| Variable | Required | Default | Notes |
|----------|----------|---------|-------|
| `POSTGRES_PASSWORD` | yes | — | Postgres superuser password |
| `SECRET_KEY` | yes | — | JWT signing key (`openssl rand -hex 32`) |
| `ENCRYPTION_KEY` | yes | — | AES-256-GCM key (`openssl rand -hex 32`) |
| `APP_ENV` | no | `development` | Set to `production` for stricter security |
| `APP_PUBLIC_URL` | no | — | Public-facing URL; needed for OIDC/CORS |
| `API_PUBLIC_URL` | no | — | Public-facing API URL |
| `BOOTSTRAP_ADMIN_USERNAME` | no | `admin` | Initial admin account |
| `BOOTSTRAP_ADMIN_PASSWORD` | yes* | — | *Required for auto-seed |
| `INSTALL_CHANNEL` | no | `online`/`offline` | Written by installer; selects upgrade flow |
| `BACKEND_TLS_MODE` | no | `docker-compose` | Locks to `docker-compose` for Compose deployments |
| `BACKEND_IMAGE` | no | `ghcr.io/tryweb/jt-ipam-backend:latest` | Backend & sync image (override for custom registry) |
| `FRONTEND_IMAGE` | no | `ghcr.io/tryweb/jt-ipam-frontend:latest` | Frontend image (override for custom registry) |

## TLS / HTTPS

The Compose stack uses `BACKEND_TLS_MODE=docker-compose` by default. The backend binds `0.0.0.0:8000` (HTTP) inside the Docker network; the frontend nginx container reverse-proxies `/api/` to it without TLS. All security headers (CSP, HSTS, X-Frame-Options) are applied at the nginx layer.

Terminate TLS at your edge reverse proxy (Traefik, haproxy, or another nginx in front of the Docker host) and set `APP_PUBLIC_URL` / `API_PUBLIC_URL` to `https://` URLs in `.env`. The `docker-compose` mode skips the HTTPS URL check (TLS is offloaded upstream).

For other TLS modes (host nginx reverse proxy, direct uvicorn, external reverse proxy), see [UPSTREAM_README.md](UPSTREAM_README.md).

## File layout

```
jt-ipam/
├── docker-compose.yml          # Production service definitions (pulls pre-built images)
├── docker-compose.dev.yml      # Dev overlay (build: sections for local development)
├── install.sh                  # Online bootstrap installer (downloads runtime release asset)
├── upgrade.sh                  # Online/offline-aware local upgrade entrypoint
├── .env.docker.example         # Env template
├── RELEASE                     # Installed release/channel metadata (generated at install time)
├── backend/
│   ├── Dockerfile              # Backend build (multi-stage)
│   └── scripts/docker-entrypoint.sh  # Startup: PG wait → alembic → seed → uvicorn
├── frontend/
│   └── Dockerfile              # Frontend build (pnpm + nginx:alpine)
├── deploy/
│   ├── nginx/jt-ipam-docker.conf     # nginx conf for Compose
│   └── postgres/init-docker.sh       # PG extension init
└── scripts/
    ├── docker-backup.sh        # Backup convenience script
    └── docker-restore.sh       # Restore convenience script
```

## Production considerations

- **TLS termination** — The Compose stack serves plain HTTP inside the Docker network. Terminate TLS at your edge (Traefik, haproxy, or another nginx). See [TLS / HTTPS](#tls--https) above.
- **Secrets** — Never commit `.env` to git. Rotate `SECRET_KEY` and `ENCRYPTION_KEY` periodically.
- **Resource limits** — Add `deploy.resources` limits to `docker-compose.override.yml` for production.
- **Release channel metadata** — `.env` + `RELEASE` identify whether this deployment is online or offline managed; do not remove them unless you are intentionally reinitializing the deployment model.

## Backup, verify & restore

Convenience scripts in [`scripts/`](scripts/) (recommended — handle bind-mount workaround, connection termination, and backend restart automatically):

```bash
bash scripts/docker-backup.sh                # create a backup
bash scripts/docker-restore.sh <timestamp>   # restore (omit <timestamp> to list; backend auto-restarted)
```

Underlying compose services (alternative, one-shot):

```bash
docker compose run --rm backup                # create a backup
docker compose run --rm backup-verify         # verify the latest backup
docker compose run --rm restore               # restore the latest backup (or -e BACKUP_FILE=<ts>)
docker compose restart backend                # pick up restored data
```

### Backup — `docker compose run --rm backup`

Captures three artifacts into `./backups/`:

| Artifact | Description | Example file |
|----------|-------------|-------------|
| `*.sql.gz` | PostgreSQL dump via `pg_dump \| gzip` | `jt-ipam-20260619_141141.sql.gz` |
| `*.env` | Copy of `.env` (secrets, keys) | `jt-ipam-20260619_141141.env` |
| `*.uploads.tar.gz` | Uploaded files (floorplans, rack diagrams) | `jt-ipam-20260619_141141.uploads.tar.gz` |

The entrypoint also runs a verification step — gzip integrity check + SQL header inspection — and prints the table list.

**Bind mount note:** On some Docker 29.x configurations, `docker compose run --rm` may not flush files written to bind mounts back to the host. The backup script handles this transparently by keeping the container and using `docker cp`. If running the compose service directly, use the manual workaround:

```bash
docker compose run --name backup-tmp backup            # keep container
docker cp backup-tmp:/backups/jt-ipam-<ts>.* ./backups/ # copy to host
docker rm backup-tmp                                    # clean up
```

### Verify — `docker compose run --rm backup-verify`

Runs 4 checks against the latest backup (or a specific file via `-e BACKUP_FILE=<basename>`):

1. **gzip integrity** — `gzip -t`
2. **SQL header** — confirms `pg_dump` format
3. **Table / index / sequence count**
4. **Trailing completeness** — checks for a clean dump footer

Output example:
```
1/4 gzip integrity:             PASS
2/4 SQL header:                 PASS (pg_dump format)
3/4 table & index count:        Tables: 79 | Indexes: 92 | Sequences: 2
4/4 trailing completeness:      PASS (clean dump footer)
VERDICT: VALID
```

### Restore — `docker compose run --rm restore`

> **Prerequisite:** The `jt_ipam` database must have no active connections, otherwise `DROP DATABASE` will fail. The restore script (`docker-restore.sh`) terminates connections automatically before restoring. When running the compose service directly, terminate connections first:
> ```bash
> docker compose exec postgres psql -U jt_ipam -d postgres \
>   -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='jt_ipam' AND pid <> pg_backend_pid();"
> ```

Performs a clean 5-step restore from the specified backup (or the latest if `BACKUP_FILE` is omitted):

1. **DROP DATABASE IF EXISTS** + **CREATE DATABASE** (same owner)
2. **`zcat \| psql`** import of the SQL dump
3. **Recreate PG extensions** (pgcrypto, citext, pg_trgm, btree_gist, vector) — lost after DROP
4. **Restore uploads** from `*.uploads.tar.gz`
5. **Verify** table count via `information_schema`

On completion, if a `*.env` backup exists, the service prints instructions to restore it on the host:

```bash
cp ./backups/jt-ipam-<ts>.env  .env
```

After restore, restart the backend to pick up the reimported data:

```bash
docker compose restart backend
```

> **Note:** The convenience script `scripts/docker-restore.sh` performs the backend restart and health check automatically.

### Cross-host migration

```bash
# On the source host
docker compose run --rm backup
# Adjust BACKUP_FILE=<ts> if you want a specific snapshot
scp ./backups/jt-ipam-<ts>.*  target-host:/opt/jt-ipam/backups/

# On the target host (Docker Compose must already be running)
cp /opt/jt-ipam/backups/jt-ipam-<ts>.env  .env
docker compose run --rm -e BACKUP_FILE=<ts> restore
docker compose restart backend
```

## Stack

| Layer | Choice |
|------|--------|
| Backend | Python 3.12 · FastAPI · SQLAlchemy 2.0 (async) · asyncpg · Alembic · Pydantic v2 |
| Database | PostgreSQL 16 (native `inet`/`cidr`/`macaddr`) + pgvector |
| Frontend | Vue 3 · TypeScript · Vite · Naive UI · Pinia · vue-i18n |
| Auth | argon2id · TOTP · short-lived JWT + refresh |
| AI | LLM Server (local) · pgvector · MCP server |
| Deploy | Docker Compose (5 containers, pre-built images from GHCR) |

## Upstream documentation

For the full upstream jt-ipam feature documentation, see [UPSTREAM_README.md](UPSTREAM_README.md). It covers:

- **Why jt-ipam?** — detailed feature overview with all integrations
- **Graylog DSV lookup** — live IP→hostname enrichment setup
- **BMC out-of-band console** — IPMI SOL troubleshooting guide
- **Core entities** — Section → Subnet → IPAddress, Devices, VLANs, etc.
- **RBAC** — object-level permissions, 5 built-in roles
- **Security (OWASP Top 10:2025)** — TLS enforcement, encryption, audit chain
- **Native (systemd) install** — Debian/Ubuntu without Docker
- **First login & admin password reset**
- **TLS modes A/B/C** — nginx reverse proxy, direct uvicorn, external proxy
- **Roadmap status** — phased feature delivery plan

## License

Apache-2.0. Commercial support: contact Jason Tools.
