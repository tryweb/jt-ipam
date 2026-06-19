#!/usr/bin/env bash
# =============================================================================
# build-docker-package.sh — Build images and package them into an offline tarball
#
# Run this script on a machine WITH internet access and docker installed.
# The resulting tarball can be transferred to an air-gapped machine and
# deployed using the included install.sh script.
#
# Usage:
#   ./scripts/build-docker-package.sh [OPTIONS]
#
# Options:
#   -t, --tag TAG         Image tag to use (default: offline)
#   -o, --output FILE     Output tarball path
#                         (default: jt-ipam-offline-<timestamp>.tar.gz)
#   -p, --prefix PREFIX   Local image name prefix (default: jt-ipam)
#   --no-cache            Pass --no-cache to docker build
#   --pull-from REGISTRY  Pull pre-built images from REGISTRY instead of
#                         building locally. Images are expected as:
#                         <REGISTRY>/<PREFIX>_<component>:<PULL_TAG>
#   --pull-tag TAG        Tag of images in the registry when using
#                         --pull-from (default: latest)
#   -h, --help            Show this help message
#
# Must be run from the repository root directory.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
IMAGE_TAG="offline"
IMAGE_PREFIX="jt-ipam"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="${REPO_ROOT}/jt-ipam-offline-${TIMESTAMP}.tar.gz"
BUILD_ARGS=""
PULL_FROM=""
PULL_TAG="latest"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tag)     IMAGE_TAG="$2";    shift 2 ;;
    -o|--output)  OUTPUT_FILE="$2";  shift 2 ;;
    -p|--prefix)  IMAGE_PREFIX="$2"; shift 2 ;;
    --no-cache)   BUILD_ARGS="--no-cache"; shift ;;
    --pull-from)  PULL_FROM="$2";       shift 2 ;;
    --pull-tag)   PULL_TAG="$2";        shift 2 ;;
    -h|--help)
      sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Image name mapping
# ---------------------------------------------------------------------------
IMG_FRONTEND="${IMAGE_PREFIX}_frontend:${IMAGE_TAG}"
IMG_BACKEND="${IMAGE_PREFIX}_backend:${IMAGE_TAG}"
IMG_POSTGRES="pgvector/pgvector:pg16"
IMG_REDIS="redis:7-alpine"

ALL_IMAGES=(
  "${IMG_FRONTEND}"
  "${IMG_BACKEND}"
  "${IMG_POSTGRES}"
  "${IMG_REDIS}"
)

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
step "Pre-flight checks"

if ! command -v docker &>/dev/null; then
  error "docker not found. Please install Docker first."
  exit 1
fi
success "docker found: $(docker --version | head -1)"

if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Please start it first."
  exit 1
fi
success "Docker daemon is running"

cd "${REPO_ROOT}"

if [[ -z "${PULL_FROM}" ]]; then
  for f in docker-compose.yml frontend/Dockerfile backend/Dockerfile; do
    if [[ ! -f "${f}" ]]; then
      error "Required file not found: ${f}"
      exit 1
    fi
  done
  success "Required Dockerfiles found"
else
  info "Skipping Dockerfile check (--pull-from mode)"
fi

# ---------------------------------------------------------------------------
# Step 1: Build or pull application images
# ---------------------------------------------------------------------------
if [[ -n "${PULL_FROM}" ]]; then
  step "Pulling images from ${PULL_FROM} (tag: ${PULL_TAG}) → local tag: ${IMAGE_TAG}"
  for name in frontend backend; do
    var_suffix=$(echo "${name}" | tr '[:lower:]-' '[:upper:]_')
    local_var="IMG_${var_suffix}"
    local_img="${!local_var}"
    remote_img="${PULL_FROM}/${IMAGE_PREFIX}_${name}:${PULL_TAG}"
    info "Pulling ${remote_img} ..."
    docker pull "${remote_img}"
    docker tag "${remote_img}" "${local_img}"
    docker image rm "${remote_img}"
    success "Pulled → tagged: ${local_img}"
  done
else
  step "Building application images (tag: ${IMAGE_TAG})"

  info "Building ${IMG_BACKEND} ..."
  # shellcheck disable=SC2086
  docker build ${BUILD_ARGS} \
    -t "${IMG_BACKEND}" \
    -f backend/Dockerfile \
    .
  success "Built: ${IMG_BACKEND}"

  info "Building ${IMG_FRONTEND} ..."
  # shellcheck disable=SC2086
  docker build ${BUILD_ARGS} \
    -t "${IMG_FRONTEND}" \
    -f frontend/Dockerfile \
    .
  success "Built: ${IMG_FRONTEND}"
fi

# ---------------------------------------------------------------------------
# Step 2: Pull third-party images
# ---------------------------------------------------------------------------
step "Pulling third-party images"

for img in "${IMG_POSTGRES}" "${IMG_REDIS}"; do
  info "Pulling ${img} ..."
  docker pull "${img}"
  success "Pulled: ${img}"
done

# ---------------------------------------------------------------------------
# Step 3: Generate offline docker-compose.yml
# ---------------------------------------------------------------------------
step "Generating offline docker-compose.yml"

COMPOSE_OUT_FILE="${REPO_ROOT}/docker-compose.offline.yml"

cat > "${COMPOSE_OUT_FILE}" << EOF
# =============================================================================
# docker-compose.offline.yml — Generated by build-docker-package.sh
# Generated at: ${TIMESTAMP}
# Image tag:    ${IMAGE_TAG}
# Image prefix: ${IMAGE_PREFIX}
#
# Usage (on the offline target machine after running install.sh):
#   docker compose -f docker-compose.offline.yml up -d
# =============================================================================

volumes:
  pgdata:
  redis-data:
  uploads:

networks:
  default:
    name: jt-ipam

services:

  # ── PostgreSQL 16 + pgvector ──
  postgres:
    image: ${IMG_POSTGRES}
    restart: unless-stopped
    environment:
      POSTGRES_USER: jt_ipam
      POSTGRES_DB: jt_ipam
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:?required}
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./deploy/postgres/init-docker.sh:/docker-entrypoint-initdb.d/01-init.sh:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U jt_ipam -d jt_ipam"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s
    ports:
      - "127.0.0.1:5432:5432"
    shm_size: 256mb

  # ── Redis 7 ──
  redis:
    image: ${IMG_REDIS}
    restart: unless-stopped
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
    ports:
      - "127.0.0.1:6379:6379"

  # ── Backend (FastAPI) ──
  backend:
    image: ${IMG_BACKEND}
    restart: unless-stopped
    environment:
      APP_ENV: "\${APP_ENV:-development}"
      APP_DEBUG: "\${APP_DEBUG:-false}"
      APP_LOG_LEVEL: "\${APP_LOG_LEVEL:-INFO}"
      APP_TIMEZONE: "\${APP_TIMEZONE:-Asia/Taipei}"
      APP_PUBLIC_URL: "\${APP_PUBLIC_URL:?required}"
      API_PUBLIC_URL: "\${API_PUBLIC_URL:?required}"
      CORS_ORIGINS: "\${CORS_ORIGINS:?required}"
      BACKEND_TLS_MODE: docker-compose
      BACKEND_BIND_HOST: 0.0.0.0
      BACKEND_BIND_PORT: 8000
      AGENT_SCRIPTS_DIR: /app/agent
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_DB: jt_ipam
      POSTGRES_USER: jt_ipam
      POSTGRES_PASSWORD: "\${POSTGRES_PASSWORD:?required}"
      REDIS_HOST: redis
      REDIS_PORT: 6379
      SECRET_KEY: "\${SECRET_KEY:?required}"
      ENCRYPTION_KEY: "\${ENCRYPTION_KEY:?required}"
      AUDIT_CHAIN_GENESIS: "\${AUDIT_CHAIN_GENESIS:?required}"
      RATE_LIMIT_ENABLED: "true"
      RATE_LIMIT_DEFAULT: 100/minute
      RATE_LIMIT_AUTH: 10/minute
      OUTBOUND_ALLOW_PRIVATE: "true"
      BOOTSTRAP_ADMIN_USERNAME: "\${BOOTSTRAP_ADMIN_USERNAME:-}"
      BOOTSTRAP_ADMIN_PASSWORD: "\${BOOTSTRAP_ADMIN_PASSWORD:-}"
      BOOTSTRAP_ADMIN_EMAIL: "\${BOOTSTRAP_ADMIN_EMAIL:-admin@example.com}"
    volumes:
      - uploads:/var/lib/jt-ipam/uploads
      - /var/run/docker.sock:/var/run/docker.sock:ro
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    expose:
      - "8000"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8000/healthz"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s

  # ── Frontend (nginx serving Vue 3 SPA + reverse proxy) ──
  frontend:
    image: ${IMG_FRONTEND}
    restart: unless-stopped
    ports:
      - "\${FRONTEND_PORT:-8080}:80"
    depends_on:
      backend:
        condition: service_healthy

  # ── Backup (one-shot: docker compose run --rm backup) ──
  backup:
    profiles: ["manual"]
    image: ${IMG_POSTGRES}
    restart: "no"
    environment:
      POSTGRES_USER: jt_ipam
      POSTGRES_DB: jt_ipam
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:?required}
      PGPASSWORD: \${POSTGRES_PASSWORD:?required}
    volumes:
      - ./backups:/backups
      - ./.env:/tmp/.env:ro
      - uploads:/tmp/uploads:ro
    entrypoint:
      - /bin/sh
      - -c
      - |
        set -e
        ts=\$(date +%Y%m%d_%H%M%S)
        base=/backups/jt-ipam-\$ts
        echo "[backup] starting — \$base.*"

        # ── 1. Database ──
        pg_dump -h postgres -U jt_ipam jt_ipam | gzip > "\$base.sql.gz"
        gzip -t "\$base.sql.gz"
        sz="\$(stat -c%s "\$base.sql.gz")"
        printf "[backup]   database: %s.sql.gz  (%s bytes)\n" "\$base" "\$sz"

        # ── 2. Configuration (.env) ──
        if [ -f /tmp/.env ]; then
          cp /tmp/.env "\$base.env"
          chmod 600 "\$base.env"
          sz="\$(stat -c%s "\$base.env")"
          printf "[backup]   config:   %s.env  (%s bytes)\n" "\$base" "\$sz"
        else
          echo "[backup]   config:   SKIPPED (.env not found)"
        fi

        # ── 3. Uploads ──
        if [ -d /tmp/uploads ] && ls -A /tmp/uploads >/dev/null 2>&1; then
          tar czf "\$base.uploads.tar.gz" -C /tmp/uploads .
          sz="\$(stat -c%s "\$base.uploads.tar.gz")"
          printf "[backup]   uploads:  %s.uploads.tar.gz  (%s bytes)\n" "\$base" "\$sz"
        else
          echo "[backup]   uploads:  SKIPPED (empty or not mounted)"
        fi

        # ── 4. Verify SQL structure ──
        echo "[backup] verifying..."
        header=\$(zcat "\$base.sql.gz" | head -c 200)
        case "\$header" in
          *"pg_dump"*|*"PostgreSQL database dump"*) ;;
          *) echo "[backup] FAIL: unexpected SQL header" >&2; exit 1 ;;
        esac
        echo "[backup]   SQL header: OK"
        echo "[backup]   tables:"
        zcat "\$base.sql.gz" | grep -E '^CREATE (TABLE|INDEX|SEQUENCE|VIEW)' | head -10
        echo ""
        echo "[backup] manifest:"
        ls -lh "\$base."*
        echo "[backup] OK — \$ts"
    depends_on:
      postgres:
        condition: service_healthy

  # ── Backup Verify (one-shot: docker compose run --rm backup-verify) ──
  backup-verify:
    profiles: ["manual"]
    image: ${IMG_POSTGRES}
    restart: "no"
    environment:
      BACKUP_FILE: ""
    volumes:
      - ./backups:/backups:ro
    entrypoint:
      - /bin/sh
      - -c
      - |
        set -e
        if [ -n "\$BACKUP_FILE" ]; then
          f="/backups/\$BACKUP_FILE"
        else
          f=\$(ls -t /backups/jt-ipam-*.sql.gz 2>/dev/null | head -1) || {
            echo "[verify] no backup file found in /backups/" >&2
            echo "[verify] specify one: docker compose run --rm -e BACKUP_FILE=<name> backup-verify" >&2
            exit 1
          }
        fi
        if [ ! -f "\$f" ]; then
          echo "[verify] file not found: \$f" >&2; exit 1
        fi
        echo "[verify] file: \$f (\$(stat -c%s "\$f") bytes)"
        echo ""
        echo "[verify] 1/4 gzip integrity..."
        gzip -t "\$f" && echo "  PASS"
        echo ""
        echo "[verify] 2/4 SQL header..."
        header=\$(zcat "\$f" | head -c 300)
        if echo "\$header" | grep -qE 'pg_dump|PostgreSQL database dump'; then
          echo "  PASS (pg_dump format)"
        else
          echo "  FAIL — unexpected header (not a pg_dump output)" >&2
          exit 1
        fi
        echo ""
        echo "[verify] 3/4 table & index count..."
        tbl=\$(zcat "\$f" | grep -cE '^CREATE TABLE' || true)
        idx=\$(zcat "\$f" | grep -cE '^CREATE INDEX' || true)
        seq=\$(zcat "\$f" | grep -cE '^CREATE SEQUENCE' || true)
        echo "  Tables: \$tbl | Indexes: \$idx | Sequences: \$seq"
        echo ""
        echo "[verify] 4/4 trailing completeness..."
        tail=\$(zcat "\$f" | tail -c 200)
        if echo "\$tail" | grep -q '^-- Completed on'; then
          echo "  PASS (clean dump footer)"
        else
          echo "  WARN — missing clean footer (dump may be truncated)" >&2
        fi
        echo ""
        echo "[verify] VERDICT: VALID"
    depends_on:
      postgres:
        condition: service_healthy

  # ── Restore (one-shot: docker compose run --rm restore) ──
  restore:
    profiles: ["manual"]
    image: ${IMG_POSTGRES}
    restart: "no"
    environment:
      BACKUP_FILE: ""
      POSTGRES_USER: jt_ipam
      POSTGRES_DB: jt_ipam
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:?required}
      PGPASSWORD: \${POSTGRES_PASSWORD:?required}
    volumes:
      - ./backups:/backups:ro
      - uploads:/tmp/uploads
    entrypoint:
      - /bin/sh
      - -c
      - |
        set -e

        # ── Select backup ──
        if [ -n "\$BACKUP_FILE" ]; then
          ts="\$BACKUP_FILE"
        else
          ts=\$(ls -t /backups/jt-ipam-*.sql.gz 2>/dev/null | head -1 | sed 's|.*/jt-ipam-\\(.*\\)\\.sql\\.gz|\\1|') || {
            echo "[restore] no backup found in /backups/" >&2
            exit 1
          }
        fi
        base="/backups/jt-ipam-\$ts"
        echo "[restore] restoring backup: \$ts"

        # ── 1. Drop + recreate database ──
        echo "[restore] 1/5 recreating database..."
        psql -h postgres -U jt_ipam -d postgres \
          -c "DROP DATABASE IF EXISTS jt_ipam;" \
          -c "CREATE DATABASE jt_ipam OWNER jt_ipam;"

        # ── 2. Import SQL ──
        echo "[restore] 2/5 importing SQL..."
        zcat "\$base.sql.gz" | psql -h postgres -U jt_ipam -d jt_ipam -q
        echo "[restore]   SQL import complete"

        # ── 3. Recreate PG extensions ──
        echo "[restore] 3/5 recreating PG extensions..."
        psql -h postgres -U jt_ipam -d jt_ipam \
          -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
        psql -h postgres -U jt_ipam -d jt_ipam \
          -c "CREATE EXTENSION IF NOT EXISTS citext;"
        psql -h postgres -U jt_ipam -d jt_ipam \
          -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
        psql -h postgres -U jt_ipam -d jt_ipam \
          -c "CREATE EXTENSION IF NOT EXISTS btree_gist;"
        psql -h postgres -U jt_ipam -d jt_ipam \
          -c "CREATE EXTENSION IF NOT EXISTS vector;"

        # ── 4. Restore uploads ──
        echo "[restore] 4/5 restoring uploads..."
        if [ -f "\$base.uploads.tar.gz" ]; then
          rm -rf /tmp/uploads/* 2>/dev/null || true
          tar xzf "\$base.uploads.tar.gz" -C /tmp/uploads
          echo "[restore]   uploads restored"
        else
          echo "[restore]   uploads: none found, skipped"
        fi

        # ── 5. Verify ──
        echo "[restore] 5/5 verifying..."
        tbl=\$(psql -h postgres -U jt_ipam -d jt_ipam -t -c \
          "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d ' ')
        echo "[restore]   tables in database: \$tbl"
        echo ""
        echo "[restore] DONE — \$ts"

        if [ -f "\$base.env" ]; then
          echo ""
          echo "  ============================================================"
          echo "  IMPORTANT: Restore the .env file on the HOST:"
          echo "    cp ./backups/jt-ipam-\$ts.env  .env"
          echo "  ============================================================"
          echo ""
        fi
        echo "Next: docker compose -f docker-compose.offline.yml restart backend"
    depends_on:
      postgres:
        condition: service_healthy
EOF

success "Generated: docker-compose.offline.yml"

# ---------------------------------------------------------------------------
# Step 4: Save images to tar
# ---------------------------------------------------------------------------
step "Saving Docker images (this may take several minutes...)"

TMP_IMAGES_TAR="$(mktemp /tmp/jt-ipam-images-XXXXXX.tar)"
info "Saving images to temporary file: ${TMP_IMAGES_TAR}"

# shellcheck disable=SC2068
docker save ${ALL_IMAGES[@]} -o "${TMP_IMAGES_TAR}"
success "Images saved ($(du -sh "${TMP_IMAGES_TAR}" | cut -f1))"

# ---------------------------------------------------------------------------
# Step 5: Assemble the offline tarball
# ---------------------------------------------------------------------------
step "Assembling offline package"

TMP_STAGING="$(mktemp -d /tmp/jt-ipam-staging-XXXXXX)"
info "Staging directory: ${TMP_STAGING}"

STAGE="${TMP_STAGING}/jt-ipam-offline"
mkdir -p "${STAGE}/scripts"
mkdir -p "${STAGE}/deploy/postgres"
mkdir -p "${STAGE}/backups"

# ── Core artifacts ──
cp "${TMP_IMAGES_TAR}"      "${STAGE}/images.tar"
cp "${COMPOSE_OUT_FILE}"     "${STAGE}/docker-compose.offline.yml"
cp "${REPO_ROOT}/.env.docker.example" "${STAGE}/.env.example"

# ── PG init script (needed by postgres container) ──
if [[ -f "${REPO_ROOT}/deploy/postgres/init-docker.sh" ]]; then
  cp "${REPO_ROOT}/deploy/postgres/init-docker.sh" "${STAGE}/deploy/postgres/init-docker.sh"
  success "Included: deploy/postgres/init-docker.sh"
else
  warn "deploy/postgres/init-docker.sh not found — postgres may not initialise extensions"
fi

# ── nginx config (reference) ──
if [[ -f "${REPO_ROOT}/deploy/nginx/jt-ipam-docker.conf" ]]; then
  mkdir -p "${STAGE}/deploy/nginx"
  cp "${REPO_ROOT}/deploy/nginx/jt-ipam-docker.conf" "${STAGE}/deploy/nginx/jt-ipam-docker.conf"
  success "Included: deploy/nginx/jt-ipam-docker.conf"
fi

# ── Maintenance scripts ──
for s in docker-backup.sh docker-restore.sh; do
  if [[ -f "${SCRIPT_DIR}/${s}" ]]; then
    cp "${SCRIPT_DIR}/${s}" "${STAGE}/scripts/${s}"
    chmod +x "${STAGE}/scripts/${s}"
    success "Included script: ${s}"
  else
    warn "Script not found, skipping: ${s}"
  fi
done

# ── Installer (generated inline) ──
cat > "${STAGE}/install.sh" << 'INSTALL_EOF'
#!/usr/bin/env bash
# =============================================================================
# install.sh — Offline installer for jt-ipam Docker stack
#
# Usage:
#   ./install.sh [OPTIONS]
#
# Options:
#   -d, --directory DIR   Installation directory (default: ./jt-ipam)
#   -p, --port PORT       Host port for the frontend (default: 8080)
#   -h, --help            Show this help message
#
# This script:
#   1. Checks prerequisites (docker, docker compose)
#   2. Loads Docker images from images.tar
#   3. Prompts for required configuration if .env does not exist
#   4. Starts all services via docker-compose.offline.yml
# =============================================================================
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALL_DIR="$(pwd)/jt-ipam"
FRONTEND_PORT=8080

# ── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--directory) INSTALL_DIR="$2"; shift 2 ;;
    -p|--port)      FRONTEND_PORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Pre-flight ──────────────────────────────────────────────────────────────
step "Pre-flight checks"

cd "$(dirname "$0")"
PKG_DIR="$(pwd)"

if ! command -v docker &>/dev/null; then
  error "docker not found. Please install Docker first." >&2
  exit 1
fi
success "docker found: $(docker --version | head -1)"

if ! docker info &>/dev/null; then
  error "Docker daemon is not running." >&2
  exit 1
fi
success "Docker daemon is running"

if ! docker compose version &>/dev/null; then
  error "docker compose plugin not found." >&2
  exit 1
fi
success "docker compose found: $(docker compose version --short 2>/dev/null || docker compose version)"

# ── Create install directory ────────────────────────────────────────────────
step "Setting up installation at: ${INSTALL_DIR}"

mkdir -p "${INSTALL_DIR}/backups"
cd "${INSTALL_DIR}"

# Copy all package files
info "Copying package files..."
cp "${PKG_DIR}/images.tar"               "${INSTALL_DIR}/"
cp "${PKG_DIR}/docker-compose.offline.yml" "${INSTALL_DIR}/"
cp "${PKG_DIR}/.env.example"             "${INSTALL_DIR}/"

# Copy deploy/ structure
if [[ -d "${PKG_DIR}/deploy" ]]; then
  cp -r "${PKG_DIR}/deploy" "${INSTALL_DIR}/"
fi

# Copy scripts/
if [[ -d "${PKG_DIR}/scripts" ]]; then
  cp -r "${PKG_DIR}/scripts" "${INSTALL_DIR}/"
  chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true
fi

success "Package files copied"

# ── Load Docker images ──────────────────────────────────────────────────────
step "Loading Docker images"

if [[ ! -f "images.tar" ]]; then
  error "images.tar not found in ${INSTALL_DIR}" >&2
  exit 1
fi

LOAD_OUTPUT="$(docker load -i images.tar 2>&1)"
echo "${LOAD_OUTPUT}"
LOAD_COUNT="$(echo "${LOAD_OUTPUT}" | grep -c '^Loaded image' || true)"
success "Loaded ${LOAD_COUNT} images"

# ── Configure environment ───────────────────────────────────────────────────
step "Configuration"

if [[ -f ".env" ]]; then
  info "Found existing .env — using it"
else
  warn "No .env file found. Creating one from .env.example..."
  cp .env.example .env
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║  Edit .env with your settings before starting the stack:   ║"
  echo "  ║                                                             ║"
  echo "  ║  Required changes:                                          ║"
  echo "  ║    POSTGRES_PASSWORD    (random, ≥ 16 chars)                ║"
  echo "  ║    SECRET_KEY           (openssl rand -hex 64)              ║"
  echo "  ║    ENCRYPTION_KEY       (openssl rand -base64 32)           ║"
  echo "  ║    AUDIT_CHAIN_GENESIS  (openssl rand -hex 64)              ║"
  echo "  ║    BOOTSTRAP_ADMIN_PASSWORD  (≥ 12 chars)                   ║"
  echo "  ║    APP_PUBLIC_URL / API_PUBLIC_URL / CORS_ORIGINS           ║"
  echo "  ║                                                             ║"
  echo "  ║  After editing, run:                                        ║"
  echo "  ║    docker compose -f docker-compose.offline.yml up -d       ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo ""
fi

# Make sure env file permissions are restrictive
if [[ -f ".env" ]]; then
  chmod 600 .env 2>/dev/null || true
fi

# ── Summary ─────────────────────────────────────────────────────────────────
step "Installation complete"

echo ""
echo "  ${BOLD}Install directory:${NC}  ${INSTALL_DIR}"
echo "  ${BOLD}Frontend port:${NC}     ${FRONTEND_PORT}"
echo ""
echo "  To start the stack:"
echo ""
echo "    cd ${INSTALL_DIR}"
echo "    docker compose -f docker-compose.offline.yml up -d"
echo ""
echo "  After starting, visit:  http://localhost:${FRONTEND_PORT}"
echo ""
echo "  To stop:"
echo "    docker compose -f docker-compose.offline.yml down"
echo ""
echo "  To backup (regularly!):"
echo "    bash scripts/docker-backup.sh"
echo ""
echo "  To restore:"
echo "    bash scripts/docker-restore.sh <timestamp>"
echo ""
INSTALL_EOF

chmod +x "${STAGE}/install.sh"
success "Generated: install.sh"

# ── MANIFEST ──
cat > "${STAGE}/MANIFEST.txt" << EOF
jt-ipam — Offline Docker Package
=================================
Built at:     ${TIMESTAMP}
Image tag:    ${IMAGE_TAG}
Image prefix: ${IMAGE_PREFIX}

Included images:
$(for img in "${ALL_IMAGES[@]}"; do echo "  - ${img}"; done)

Files:
  images.tar                  — Docker images (load with: docker load)
  docker-compose.offline.yml  — Compose file referencing local images
  .env.example                — Environment variable template
  install.sh                  — Offline installer script
  deploy/                     — Supporting deployment files
  scripts/docker-backup.sh    — Backup database, config & uploads
  scripts/docker-restore.sh   — Restore from a backup

Quick start:
  1. tar xzf jt-ipam-offline-*.tar.gz
  2. cd jt-ipam-offline
  3. ./install.sh
  4. Edit .env with your secrets
  5. docker compose -f docker-compose.offline.yml up -d
EOF

# ── Compress ──
info "Compressing package to: ${OUTPUT_FILE}"
tar czf "${OUTPUT_FILE}" -C "${TMP_STAGING}" "jt-ipam-offline"

# Cleanup temp files
rm -rf "${TMP_STAGING}" "${TMP_IMAGES_TAR}"
info "docker-compose.offline.yml retained at: ${COMPOSE_OUT_FILE}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Package complete"

PKG_SIZE="$(du -sh "${OUTPUT_FILE}" | cut -f1)"
echo ""
echo -e "  ${BOLD}Output:${NC}  ${OUTPUT_FILE}"
echo -e "  ${BOLD}Size:${NC}    ${PKG_SIZE}"
echo ""
echo "Transfer this file to the offline machine and run:"
echo ""
echo "  tar xzf $(basename "${OUTPUT_FILE}")"
echo "  cd jt-ipam-offline"
echo "  ./install.sh"
echo ""
