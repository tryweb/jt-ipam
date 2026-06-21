# Docker Compose: Adding a Service That Shares the Backend Image

## Context

jt-ipam uses a Python wheel build for the backend (`backend/Dockerfile`). The wheel installs the `app` package into Python site-packages, not into a working directory. The compose file has multiple services that share this image (`backend` and `sync`). Adding a new service that reuses the same image requires awareness of how the image is structured and what runtime configuration the app enforces.

## Problem

Several non-obvious issues surface when adding a second service that uses the same backend image:

1. **No `/app/backend/` directory.** The wheel installs the app to site-packages (e.g. `/usr/local/lib/python3.12/site-packages/app/`). The WORKDIR is `/app`, which contains `alembic/`, `alembic.ini`, `agent/`, and `scripts/` — but no `backend/` subdirectory.

2. **TLS-mode enforcement.** The `pydantic-settings` validator in `app/core/config.py` rejects `APP_PUBLIC_URL` / `API_PUBLIC_URL` that use `http://` unless `BACKEND_TLS_MODE=docker-compose` is set. A new service reading the same `.env` file will fail at import time if this variable is absent.

3. **Environment variables are baked at container creation.** `docker compose restart` does NOT re-read `.env` or `environment:` blocks — only `docker compose up -d --force-recreate <service>` does. If `.env` secrets change, old containers continue using stale values.

4. **`|| true` in while-loop entrypoints silently swallows errors.** Python's stderr is line-buffered, but when stdout/stderr is a pipe (Docker), output may not flush. The logging output disappears into the container log sink with no visible trace unless Python runs unbuffered (`-u` or `PYTHONUNBUFFERED=1`).

## Solution

### Entrypoint command for a looping service

```yaml
sync:
  image: jt-ipam-backend:local   # same build as backend
  entrypoint: ["/bin/sh", "-c"]
  command:
    - |
      echo "[sync] starting — interval $${INTERVAL_VAR:-300}s"
      while true; do
        echo "[sync] cycle start: $$(date -Iseconds)"
        python -u /app/scripts/your-script.py || true
        echo "[sync] cycle end, sleeping $${INTERVAL_VAR:-300}s"
        sleep "$${INTERVAL_VAR:-300}"
      done
```

Key points:
- `$$` escapes to `$` in docker-compose YAML (shell variable, not compose variable)
- `python -u` ensures unbuffered output visible in `docker compose logs`
- `|| true` prevents a script failure from killing the loop
- Heartbeat `echo` lines make the loop observable even when the script produces no output

### Required environment for backend-image services

```yaml
environment:
  BACKEND_TLS_MODE: docker-compose    # required — bypasses https:// URL check
  APP_ENV: "${APP_ENV:-development}"
  # Also needs POSTGRES_*, REDIS_*, SECRET_KEY, ENCRYPTION_KEY, etc.
  # See the backend service for the full list.
```

### File layout inside the image

```
/app/
├── alembic/
├── alembic.ini
├── agent/
└── scripts/          # jt-ipam-sync.py and other scripts live here
```

Python package (`app.*`) is installed to site-packages — importable anywhere.

### Forcing env refresh

```bash
docker compose up -d --force-recreate <service>
```

`docker compose restart` is insufficient when `.env` or `environment:` values have changed.

## Why It Works

- **Same image, different entrypoint**: The backend image contains everything needed. A different `entrypoint`/`command` in the compose file selects a different runtime mode without a separate Dockerfile or build stage.
- **`python -u` ensures observability**: Without it, Python buffers stdout when not connected to a TTY, and logging output may never reach `docker compose logs`.
- **`BACKEND_TLS_MODE=docker-compose` matches the deployment model**: TLS is offloaded to an edge proxy (or absent in dev). No cert files or HTTPS URLs are needed inside the Docker network.

## Side Effects / Tradeoffs

- **Image coupling**: Sharing the same image means all services get the same dependencies and updates simultaneously. If one service needs a different Python version or pip deps, it needs its own Dockerfile.
- **`--force-recreate` is easy to forget**: A developer who only runs `docker compose restart` after changing `.env` will see inexplicable failures. Document this in team workflows or add a Makefile target.
- **Heartbeat spam in logs**: The `echo` lines add noise. On a busy sync service running every 30s, the logs fill quickly. Mitigate by using a higher interval in production or redirecting heartbeats to a separate log channel.

## Evidence

- `docker compose exec sync python -u /app/scripts/jt-ipam-sync.py` → exit 0, runs in <1s on a fresh DB
- `docker compose logs sync` shows timestamps:
  ```
  sync-1  | [sync] starting — interval 30s
  sync-1  | [sync] cycle start: 2026-06-21T07:10:21+00:00
  sync-1  | [sync] cycle end, sleeping 30s
  ```
- Without `BACKEND_TLS_MODE=docker-compose`: `ValidationError: APP_PUBLIC_URL must use https://`
- Without `--force-recreate` after .env change: stale `ENCRYPTION_KEY` causes `ValueError: non-hexadecimal number found in fromhex()`
- Without `python -u`: script runs successfully but no output visible in docker logs

## Related Files

- `docker-compose.yml` — sync service definition (lines 140–185)
- `backend/Dockerfile` — image structure showing WORKDIR /app and COPY destinations
- `backend/app/core/config.py` — `BACKEND_TLS_MODE` validation logic
- `scripts/jt-ipam-sync.py` — the sync script run by the service

## Tags

`docker-compose` `service-pattern` `backend-image` `entrypoint` `environment-variables` `tls-mode` `buffering`
