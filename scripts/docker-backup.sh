#!/usr/bin/env bash
# ==========================================================================
# docker-backup.sh — Backup jt-ipam database, config & uploads via Docker
#
# Workaround for Docker bind-mount sync issues with `docker compose run --rm`
# (files written to /backups/ inside the container may not flush to host before
# the container is removed). This script:
#   1. Runs the compose backup service (keeps the container)
#   2. Copies backup artifacts from the container to ./backups/ via docker cp
#   3. Removes the container
#
# Usage:
#   bash scripts/docker-backup.sh
#
# Output: files in ./backups/ — same format as the compose service:
#   jt-ipam-<YYYYMMDD_HHMMSS>.sql.gz         (PostgreSQL dump)
#   jt-ipam-<YYYYMMDD_HHMMSS>.uploads.tar.gz  (uploaded files)
#
# To also save the current .env (recommended before restore):
#   cp .env ./backups/jt-ipam-<TIMESTAMP>.env
# ==========================================================================
set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONTAINER_NAME="jt-ipam-backup"

# ── Header ─────────────────────────────────────────────────────────────
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      jt-ipam Docker Backup                 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Pre-flight checks ────────────────────────────────────────────────

if ! docker compose version >/dev/null 2>&1; then
    echo -e "${RED}Error: docker compose not available.${NC}" >&2
    exit 1
fi

if [ ! -f docker-compose.yml ]; then
    echo -e "${RED}Error: docker-compose.yml not found. Run from project root.${NC}" >&2
    exit 1
fi

# Clean up leftover container from a previous failed run
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${YELLOW}Removing leftover container from previous run...${NC}"
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
fi

# Ensure backups directory exists
mkdir -p backups

# ── Step 1: Run backup ──────────────────────────────────────────────
echo -e "${YELLOW}[1/3]${NC} Running database backup..."
echo ""

if ! docker compose run --name "${CONTAINER_NAME}" backup 2>/dev/null; then
    echo -e "${RED}Backup failed inside the container.${NC}" >&2
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Backup completed inside container"

# ── Step 2: Copy files to host ──────────────────────────────────────
echo ""
echo -e "${YELLOW}[2/3]${NC} Copying backup files to host..."
echo ""

if ! docker cp "${CONTAINER_NAME}:/backups/." ./backups/ 2>/dev/null; then
    echo -e "${RED}Failed to copy backup files from container.${NC}" >&2
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Files copied to ./backups/"

# ── Step 3: Remove container ────────────────────────────────────────
echo ""
echo -e "${YELLOW}[3/3]${NC} Cleaning up..."
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Temporary container removed"

# ── Show results ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Backup complete                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""

LATEST=$(ls -t backups/jt-ipam-*.sql.gz 2>/dev/null | head -1)
if [ -n "$LATEST" ]; then
    TIMESTAMP=$(echo "$LATEST" | sed 's|.*/jt-ipam-\(.*\)\.sql\.gz|\1|')
    echo -e "  ${CYAN}Timestamp:${NC}  $TIMESTAMP"
    echo -e "  ${CYAN}Database:${NC}   ${LATEST} ($(du -h "$LATEST" | cut -f1))"
    UPLOADS="backups/jt-ipam-${TIMESTAMP}.uploads.tar.gz"
    if [ -f "$UPLOADS" ]; then
        echo -e "  ${CYAN}Uploads:${NC}    ${UPLOADS} ($(du -h "$UPLOADS" | cut -f1))"
    fi
fi

echo ""
echo -e "${YELLOW}Recommended: back up your .env file too:${NC}"
echo -e "  ${CYAN}cp .env backups/jt-ipam-${TIMESTAMP:-<TIMESTAMP>}.env${NC}"
echo ""
