# Docker Compose Deployment Architecture

## Context

jt-ipam was originally designed for systemd/native deployment (Debian/Ubuntu VM) with nginx as reverse proxy, uvicorn on loopback, and Postgres/Redis installed via apt. The project had no Dockerfile or docker-compose.yml.

A Docker Compose deployment was needed for: CI/CD pipelines, staging environments, developers who prefer containerized workflows, and production deployments that already use Docker orchestration.

## Problem

1. **Config.py TLS enforcement** — The pydantic-settings `_tls_guards` validator required `https://` on APP_PUBLIC_URL/API_PUBLIC_URL, `BACKEND_TLS_MODE=nginx` with loopback binding, or `BACKEND_TLS_MODE=direct` with cert files. None of these fit Docker Compose where nginx serves HTTP inside the Docker network and TLS is terminated externally (or not at all in dev).

2. **Entrypoint sequencing** — The backend needs Postgres ready *and* Alembic migrations run *before* uvicorn starts. The native deployment uses systemd unit ordering; Docker needed an equivalent.

3. **Multi-service build context** — The frontend Dockerfile needs the project root as build context (for `deploy/nginx/*.conf`), while the backend Dockerfile uses `backend/` as context. Docker Compose handles this with per-service `build.context`.

## Solution

### TLS mode: `docker-compose`

Added a third TLS mode to `Settings`:

```python
TlsMode = Literal["nginx", "direct", "docker-compose"]
```

In `docker-compose` mode:
- Backend binds `0.0.0.0:8000` (HTTP, no loopback restriction)
- `https://` URL enforcement is skipped (TLS may be offloaded upstream)
- No cert files required
- A05 production checks (CORS HTTPS, debug mode, secure cookies) still apply when `APP_ENV=production`

### Entrypoint pattern

`docker-entrypoint.sh` implements a linear startup sequence:
1. Wait for Postgres (via `pg_isready` loop)
2. Run `alembic upgrade head`
3. Seed admin user (optional, via bootstrap script)
4. `exec uvicorn` with 4 workers

### Nginx reverse-proxy pattern

```nginx
location /api/ {
    proxy_pass http://backend:8000;
}
location / {
    try_files $uri $uri/ /index.html;  # SPA fallback
}
```

Security headers (CSP, HSTS, X-Frame-Options, etc.) are applied at the nginx layer, matching the existing deploy/nginx/ templates.

## Why It Works

- **Separation of concerns**: nginx container handles HTTP → backend routing + security headers; backend container handles business logic; both can be scaled independently.
- **No config duplication**: The existing `deploy/nginx/` conf templates and `alembic/` migrations are reused as-is.
- **Environment parity**: The same `pyproject.toml` wheel build and same `alembic upgrade head` process work identically in Docker and native deployment.
- **Idempotent seeding**: The entrypoint's bootstrap-admin step uses `get-or-create` logic; `docker compose restart` won't duplicate the admin user.

## Side Effects / Tradeoffs

- **Port 80 on host**: The nginx container binds `:80` by default. Changed to `:8080` for environments where `:80` is restricted (non-root docker-proxy).
- **No built-in TLS**: Users who need HTTPS must add a reverse proxy (haproxy, Traefik, or another nginx) in front of the Docker host. This is by design — Docker TLS termination is a separate concern.
- **Larger image**: `python:3.12-slim` runtime + all pip dependencies = ~450MB. The native install uses system Python with fewer deps duplicated. Mitigated by multi-stage build (builder image is discarded).
- **Celery omitted**: No Celery worker service was added because the backend has no Celery app — all background tasks use `asyncio.create_task`.

## Evidence

- `docker compose build backend` → exit 0
- `docker compose build frontend` → exit 0 (pnpm build + vue-tsc type check)
- `docker compose up -d` → all 4 containers `(healthy)`
- `curl /healthz` → `ok` (via nginx → backend)
- `curl /api/v1/addresses` → `{"detail":"Authentication required"}` (API routing works)
- `curl /` → SPA HTML 200 with security headers
- Backend logs: `Alembic migrations complete` → `Application startup complete`

## Related Files

- `docker-compose.yml` — service definitions
- `backend/Dockerfile` — multi-stage, pip wheel + python:3.12-slim
- `backend/scripts/docker-entrypoint.sh` — startup sequence
- `frontend/Dockerfile` — pnpm build + nginx:alpine
- `deploy/nginx/jt-ipam-docker.conf` — nginx config for Docker
- `deploy/postgres/init-docker.sh` — PG extensions init for Docker
- `.env.docker.example` — environment variable template

## Tags

`docker-compose` `deployment` `architecture` `tls` `nginx` `fastapi` `vue`
