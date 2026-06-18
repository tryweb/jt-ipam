#!/bin/bash
# jt-ipam backend — Docker entrypoint
#
# 1. Wait for PostgreSQL to be ready
# 2. Run Alembic migrations (idempotent)
# 3. Seed admin if not exists (optional, controlled by env var)
# 4. Execute the CMD (uvicorn)
set -euo pipefail

# ── Wait for PostgreSQL ──
echo "[entrypoint] Waiting for PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT}..."
until pg_isready -h "${POSTGRES_HOST}" -U "${POSTGRES_USER:-jt_ipam}" -d "${POSTGRES_DB:-jt_ipam}" -t 5 2>/dev/null; do
    echo "[entrypoint] PostgreSQL is unavailable — sleeping"
    sleep 2
done
echo "[entrypoint] PostgreSQL is ready."

# ── Run Alembic migrations ──
echo "[entrypoint] Running Alembic migrations..."
alembic upgrade head
echo "[entrypoint] Alembic migrations complete."

# ── Seed initial admin (optional) ──
if [[ -n "${BOOTSTRAP_ADMIN_USERNAME:-}" && -n "${BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
    echo "[entrypoint] Seeding admin user '${BOOTSTRAP_ADMIN_USERNAME}'..."
    python -m app.cli.bootstrap create-admin \
        --username "${BOOTSTRAP_ADMIN_USERNAME}" \
        --email "${BOOTSTRAP_ADMIN_EMAIL:-admin@example.com}" \
        --password-stdin \
        --force-update <<< "${BOOTSTRAP_ADMIN_PASSWORD}" 2>&1 || \
        echo "[entrypoint] Admin seed skipped (already exists or bootstrap not available)"
fi

# ── Execute CMD ──
echo "[entrypoint] Starting uvicorn..."
exec "$@"
