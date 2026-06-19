#!/usr/bin/env bash
# ==========================================================================
# docker-restore.sh — Restore jt-ipam database & uploads from a backup
#
# Lists available backups in ./backups/ and restores one via the compose
# restore service.  The compose service mounts ./backups/ as a directory,
# so bind-mount issues that affect the backup service do NOT apply here.
#
# Usage:
#   bash scripts/docker-restore.sh               # show available backups
#   bash scripts/docker-restore.sh <timestamp>   # restore specific backup
#   bash scripts/docker-restore.sh -l            # list only
#   bash scripts/docker-restore.sh latest        # restore latest
#
# Example:
#   bash scripts/docker-restore.sh 20260619_141141
#
# After a successful restore, the backend is restarted automatically.
# ==========================================================================
set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Header ─────────────────────────────────────────────────────────────
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      jt-ipam Docker Restore                ║${NC}"
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

if [ ! -d backups ] || [ -z "$(ls backups/jt-ipam-*.sql.gz 2>/dev/null)" ]; then
    echo -e "${RED}Error: no backup files found in ./backups/.${NC}" >&2
    echo "Make sure backup files (jt-ipam-*.sql.gz) exist in the backups/ directory." >&2
    exit 1
fi

# ── List available backups ──────────────────────────────────────────
BACKUPS=()
while IFS= read -r f; do
    ts=$(echo "$f" | sed 's|.*/jt-ipam-\(.*\)\.sql\.gz|\1|')
    BACKUPS+=("$ts")
done < <(ls -t backups/jt-ipam-*.sql.gz)

echo -e "${CYAN}Available backups:${NC}"
echo ""
SELECTED=""
for i in "${!BACKUPS[@]}"; do
    ts="${BACKUPS[$i]}"
    size=$(du -h "backups/jt-ipam-${ts}.sql.gz" 2>/dev/null | cut -f1)
    has_uploads="no"
    [ -f "backups/jt-ipam-${ts}.uploads.tar.gz" ] && has_uploads="yes"
    has_env="no"
    [ -f "backups/jt-ipam-${ts}.env" ] && has_env="yes"
    printf "  %3d  %s  (db: %s, uploads: %s, .env: %s)\n" \
        $((i+1)) "$ts" "$size" "$has_uploads" "$has_env"
done
echo ""

# ── Determine which backup to restore ──────────────────────────────

if [ "${1:-}" = "-l" ]; then
    exit 0
fi

REQUESTED="${1:-}"

if [ -z "$REQUESTED" ]; then
    # No argument — show usage and exit
    LATEST="${BACKUPS[0]}"
    echo -e "${YELLOW}Usage:${NC}"
    echo "  bash scripts/docker-restore.sh <timestamp>    Restore specific backup"
    echo "  bash scripts/docker-restore.sh latest         Restore latest ($LATEST)"
    echo ""
    echo -e "${YELLOW}Example:${NC}"
    echo "  bash scripts/docker-restore.sh $LATEST"
    echo ""
    exit 0
elif [ "$REQUESTED" = "latest" ]; then
    SELECTED="${BACKUPS[0]}"
    echo -e "${YELLOW}Selected latest:${NC} $SELECTED"
else
    # Check if the requested timestamp exists
    FOUND=""
    for ts in "${BACKUPS[@]}"; do
        if [ "$ts" = "$REQUESTED" ]; then
            FOUND="$ts"
            break
        fi
    done
    if [ -z "$FOUND" ]; then
        echo -e "${RED}Error: backup '$REQUESTED' not found.${NC}" >&2
        echo "Use one of the timestamps listed above, or 'latest'." >&2
        exit 1
    fi
    SELECTED="$FOUND"
fi

# Check postgres service health
echo ""
echo -e "${YELLOW}Checking postgres status...${NC}"
if ! docker compose ps postgres --format '{{.Status}}' 2>/dev/null | grep -q "(healthy)"; then
    echo -e "${RED}Error: postgres service is not running or not healthy.${NC}" >&2
    echo "Start the stack first:  docker compose up -d postgres" >&2
    exit 1
fi
echo -e "  ${GREEN}✓${NC} postgres is healthy"

# ── Confirm ──────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}About to restore:${NC}"
echo -e "  ${CYAN}Backup:${NC}     $SELECTED"
echo -e "  ${CYAN}Database:${NC}   backups/jt-ipam-${SELECTED}.sql.gz"
if [ -f "backups/jt-ipam-${SELECTED}.uploads.tar.gz" ]; then
    echo -e "  ${CYAN}Uploads:${NC}    backups/jt-ipam-${SELECTED}.uploads.tar.gz"
fi
echo ""
echo -e "${RED}⚠ WARNING: This will DROP the current database and replace it.${NC}"
read -r -p "Continue? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# ── Terminate DB connections ──────────────────────────────────────
echo ""
echo -e "${YELLOW}Terminating existing connections to jt_ipam database...${NC}"
if ! docker compose exec -T postgres psql -U jt_ipam -d postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='jt_ipam' AND pid <> pg_backend_pid();" 2>/dev/null; then
    echo -e "  ${YELLOW}⚠ Could not terminate connections (maybe none active).${NC}"
fi
echo -e "  ${GREEN}✓${NC} Connections terminated"

# ── Run restore ────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Restoring backup: $SELECTED...${NC}"
echo ""

if ! docker compose run --rm -e BACKUP_FILE="$SELECTED" restore; then
    echo ""
    echo -e "${RED}Restore failed. Check the output above for details.${NC}" >&2
    exit 1
fi

# ── Post-restore instructions ──────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Restore complete                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Check if .env backup exists
if [ -f "backups/jt-ipam-${SELECTED}.env" ]; then
    echo -e "${YELLOW}⚠ .env backup found.${NC}"
    echo "  If you need to restore it:"
    echo -e "  ${CYAN}cp backups/jt-ipam-${SELECTED}.env .env${NC}"
    echo ""
fi

# ── Restart backend ────────────────────────────────────────────────
echo -e "${YELLOW}Restarting backend to pick up restored data...${NC}"
if ! docker compose restart backend >/dev/null 2>&1; then
    echo -e "  ${RED}⚠ Backend restart command failed. Restart manually: docker compose restart backend${NC}"
    exit 1
fi

echo -e "  ${YELLOW}Waiting for backend to become healthy...${NC}"
for i in $(seq 1 30); do
    sleep 1
    if docker compose ps backend --format '{{.Status}}' 2>/dev/null | grep -q "(healthy)"; then
        echo -e "  ${GREEN}✓${NC} Backend is healthy"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo -e "  ${YELLOW}⚠ Backend started but not yet healthy. Check later: docker compose ps${NC}"
    fi
done

echo ""
echo -e "${GREEN}Restore complete — ${SELECTED} is now live.${NC}"
echo ""
