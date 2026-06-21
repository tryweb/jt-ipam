# jt-ipam backend — Docker image
#
# Multi-stage build:
#   1. builder — build wheel
#   2. runtime — slim Python with only runtime deps

# ── Builder ──
FROM python:3.12-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libffi-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY backend/pyproject.toml backend/README.md ./
COPY backend/app/ app/
COPY backend/alembic/ alembic/
COPY backend/alembic.ini .

RUN pip install --no-cache-dir build && \
    python -m build --wheel

# ── Runtime ──
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /build/dist/*.whl /tmp/
RUN pip install --no-cache-dir /tmp/*.whl 'uvicorn[standard]'

COPY --from=builder /build/alembic/ alembic/
COPY --from=builder /build/alembic.ini .

# agent 安裝腳本（供 /api/v1/scan-agents/installer.sh 等端點使用）
COPY agent/ /app/agent/

COPY scripts/ /app/scripts/

COPY backend/scripts/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4", "--proxy-headers", "--forwarded-allow-ips", "*", "--no-server-header"]
