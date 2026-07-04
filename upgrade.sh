#!/usr/bin/env bash
# ==========================================================================
# upgrade.sh — jt-ipam Docker Compose upgrade
#
# Upgrades an existing Docker Compose deployment to the latest source.
# Database migrations run automatically when the backend container starts
# (the entrypoint runs `alembic upgrade head`), so there is no manual
# migration step.
#
# What this script does:
#   1. Verifies an existing installation (docker-compose.yml must exist)
#   2. Checks system requirements
#   3. Backs up .env, docker-compose.yml, and scripts/ to backup_<timestamp>/
#   4. Runs git pull --ff-only to fetch the latest source
#   5. Pulls latest images: docker compose pull
#   6. Recreates containers: docker compose up -d --force-recreate
#   7. Waits for services to become healthy
#   8. Cleans up dangling Docker images
#   9. Prints upgrade summary
#
# For local development (build from source instead of pull):
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml pull
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --force-recreate
#
# Usage:
#   bash upgrade.sh
#   bash upgrade.sh --no-pull         # skip git pull (use local source)
#   bash upgrade.sh --no-backup       # skip backup step
#   bash upgrade.sh --no-cleanup      # skip dangling image cleanup
#
# Requirements:
#   - Existing jt-ipam Docker Compose installation
#   - Docker Engine 24+ with compose v2 plugin
#   - git (for pulling latest source)
# ==========================================================================
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NO_PULL=false
NO_BACKUP=false
NO_CLEANUP=false

# ──────────────────────────────────────────────────────────
# Color helpers (disabled if not terminal)
# ──────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info()  { echo -e "  ${CYAN}ℹ${NC}  $1"; }
ok()    { echo -e "  ${GREEN}✅${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠️${NC}  $1"; }
fail()  { echo -e "  ${RED}❌${NC} $1"; exit 1; }
header() {
    echo
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${BOLD}========================================${NC}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pull) NO_PULL=true; shift ;;
        --no-backup) NO_BACKUP=true; shift ;;
        --no-cleanup) NO_CLEANUP=true; shift ;;
        -h|--help)
            echo "Usage: bash upgrade.sh [--no-pull] [--no-backup] [--no-cleanup]"
            exit 0
            ;;
        *) fail "Unknown argument: $1";;
    esac
done

# ──────────────────────────────────────────────────────────
# Verify installation exists
# ──────────────────────────────────────────────────────────
verify_installed() {
    if [ ! -f "docker-compose.yml" ]; then
        fail "No installation found (docker-compose.yml missing).

upgrade.sh is for upgrading an existing Docker Compose deployment.
First-time install:  bash install.sh"
    fi

    if [ ! -d ".git" ]; then
        fail "Not a git repository. upgrade.sh requires the jt-ipam source.

If you cloned manually, run from the repository root.
Otherwise: git clone https://github.com/jasoncheng7115/jt-ipam.git"
    fi

    ok "Existing installation detected"
}

# ──────────────────────────────────────────────────────────
# Step 1 — System requirements
# ──────────────────────────────────────────────────────────
check_system() {
    header "1. 檢查系統規格 (System Requirements)"

    CPU_CORES=$(nproc 2>/dev/null || echo 0)
    RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    RAM_GB=$((RAM_KB / 1024 / 1024))
    DISK_KB=$(df -Pk . 2>/dev/null | tail -1 | awk '{print $4}' || echo 0)
    DISK_GB=$((DISK_KB / 1024 / 1024))

    echo "  CPU: $CPU_CORES cores  |  RAM: ${RAM_GB} GB  |  Disk free: ${DISK_GB} GB"

    if [ "$CPU_CORES" -lt 2 ]; then
        fail "Need ≥ 2 CPU cores (have $CPU_CORES)"
    fi
    if [ "$RAM_KB" -lt $((4 * 1024 * 1024)) ]; then
        fail "Need ≥ 4 GB RAM (have ${RAM_GB} GB)"
    fi
    if [ "$DISK_GB" -lt 5 ]; then
        fail "Need ≥ 5 GB free disk (have ${DISK_GB} GB) for upgrade"
    fi

    ok "System meets requirements"
}

# ──────────────────────────────────────────────────────────
# Step 2 — Docker environment
# ──────────────────────────────────────────────────────────
check_docker() {
    header "2. 檢查 Docker 環境 (Docker Environment)"

    command -v docker &>/dev/null || fail "Docker is not installed"
    ok "Docker: $(docker --version 2>/dev/null | head -1)"

    if command -v docker compose &>/dev/null; then
        ok "Docker Compose V2 (standalone)"
    elif docker compose version &>/dev/null 2>&1; then
        ok "Docker Compose V2 (plugin)"
    else
        fail "Docker Compose V2 not found"
    fi

    [ -S /var/run/docker.sock ] || fail "Docker socket not found"
    docker info &>/dev/null || fail "Cannot connect to Docker daemon"
    ok "Docker daemon is running"
}

# ──────────────────────────────────────────────────────────
# Step 3 — Backup existing files
# ──────────────────────────────────────────────────────────
backup_files() {
    if [ "$NO_BACKUP" = true ]; then
        info "Backup skipped (--no-backup)"
        return
    fi

    header "3. 備份設定檔 (Backup Configuration)"

    local backup_dir="backup_${TIMESTAMP}"
    mkdir -p "$backup_dir"

    for f in docker-compose.yml .env; do
        if [ -f "$f" ]; then
            cp "$f" "${backup_dir}/${f}"
            ok "${f} → ${backup_dir}/${f}"
        fi
    done

    if [ -d "scripts" ]; then
        cp -r scripts "${backup_dir}/scripts" 2>/dev/null && ok "scripts/ → ${backup_dir}/scripts/"
    fi

    info "Backup saved to: ${backup_dir}/"
}

# ──────────────────────────────────────────────────────────
# Step 4 — Pull latest source
# ──────────────────────────────────────────────────────────
pull_source() {
    if [ "$NO_PULL" = true ]; then
        info "git pull skipped (--no-pull)"
        return
    fi

    header "4. 拉取最新原始碼 (Pulling Latest Source)"

    local old_sha
    old_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo "  Current: ${old_sha}"

    if git pull --ff-only 2>&1; then
        local new_sha
        new_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        ok "Updated: ${old_sha} → ${new_sha}"
    else
        warn "git pull failed (local changes may be present)."
        warn "Continuing with current source. To force update:"
        warn "  git stash && git pull --ff-only"
    fi
}

# ──────────────────────────────────────────────────────────
# Step 5 — Pull latest images
# ──────────────────────────────────────────────────────────
pull_images() {
    header "5. 拉取最新 Docker 映像 (Pulling Images)"

    local old_backend
    old_backend=$(docker images --filter "reference=ghcr.io/tryweb/jt-ipam-backend" -q 2>/dev/null | head -1 || true)
    if [ -n "$old_backend" ]; then
        echo "  Current backend image ID: ${old_backend:0:12}"
    else
        info "No local GHCR backend image found — will pull fresh"
    fi

    echo "  Pulling latest images from GitHub Container Registry..."
    if docker compose pull 2>&1; then
        ok "Images pulled successfully"
    else
        warn "Pull failed (network?). Using local cache if available."
        warn "Local build alternative:"
        warn "  docker compose -f docker-compose.yml -f docker-compose.dev.yml build"
    fi

    local new_backend
    new_backend=$(docker images --filter "reference=ghcr.io/tryweb/jt-ipam-backend" -q 2>/dev/null | head -1 || true)
    if [ -n "$new_backend" ] && [ "$new_backend" != "$old_backend" ] && [ -n "$old_backend" ]; then
        echo "  New backend image ID: ${new_backend:0:12}"
    fi
}

# ──────────────────────────────────────────────────────────
# Step 6 — Recreate containers
# ──────────────────────────────────────────────────────────
recreate_containers() {
    header "6. 重建容器 (Recreating Containers)"

    echo "  Recreating containers with --force-recreate..."
    docker compose up -d --force-recreate 2>&1 || fail "Failed to recreate containers"

    echo
    echo -n "  Waiting for services to become healthy"
    local services="postgres redis backend frontend"
    local all_healthy=false

    for _ in $(seq 1 120); do
        all_healthy=true
        for svc in $services; do
            local status
            status=$(docker compose ps "$svc" --format '{{.Status}}' 2>/dev/null || echo "")
            if ! echo "$status" | grep -q "(healthy)"; then
                all_healthy=false
                break
            fi
        done
        if [ "$all_healthy" = true ]; then
            echo
            ok "All services are healthy"
            break
        fi
        echo -n "."
        sleep 2
    done

    if [ "$all_healthy" = false ]; then
        echo
        warn "Some services may not be healthy yet."
        warn "Check: docker compose ps"
        warn "Logs:  docker compose logs -f"
    fi

    echo
    docker compose ps
}

# ──────────────────────────────────────────────────────────
# Step 7 — Verification
# ──────────────────────────────────────────────────────────
run_verification() {
    header "7. 驗證服務 (Verification)"

    local passed=0 failed=0
    local services="postgres redis backend frontend"

    for svc in $services; do
        local status
        status=$(docker compose ps "$svc" --format '{{.Status}}' 2>/dev/null || echo "not found")
        if echo "$status" | grep -qE "(Up|healthy)"; then
            echo -e "  ${GREEN}✓${NC} $svc is running"
            passed=$((passed + 1))
        else
            echo -e "  ${RED}✗${NC} $svc: $status"
            failed=$((failed + 1))
        fi
    done

    echo
    if [ "$failed" -eq 0 ]; then
        ok "All services verified"
    else
        warn "${failed} service(s) not healthy — check: docker compose logs"
    fi
}

# ──────────────────────────────────────────────────────────
# Step 8 — Cleanup dangling images
# ──────────────────────────────────────────────────────────
cleanup_images() {
    if [ "$NO_CLEANUP" = true ]; then
        info "Cleanup skipped (--no-cleanup)"
        return
    fi

    header "8. 清理舊映像 (Cleanup)"

    local pruned
    pruned=$(docker image prune -f 2>&1 | sed -n 's/.*Total reclaimed space: \(.*\)/\1/p' || true)
    if [ -n "$pruned" ]; then
        ok "Reclaimed: ${pruned}"
    else
        info "Nothing to clean up"
    fi
}

# ──────────────────────────────────────────────────────────
# Step 9 — Show summary
# ──────────────────────────────────────────────────────────
show_info() {
    header "9. 升級完成 (Upgrade Complete)"

    local host_ip=""
    if command -v ip &>/dev/null; then
        host_ip=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([^ ]*\).*/\1/p' | head -1 || true)
    elif command -v hostname &>/dev/null; then
        host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' | grep -v '^fe80\|^::' || true)
    fi
    host_ip="${host_ip:-localhost}"

    local revision
    revision=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    echo
    echo -e "  ${CYAN}🔢${NC}  Revision: ${revision}"
    echo -e "  ${CYAN}🌐${NC}  Web UI:   http://${host_ip}:8080"
    echo

    if [ "$NO_BACKUP" = false ]; then
        echo -e "  ${YELLOW}ℹ${NC}  Backup:  backup_${TIMESTAMP}/"
        echo "     (configuration files from before the upgrade)"
        echo
        echo -e "  ${YELLOW}ℹ${NC}  Rollback instructions:"
        echo "     docker compose down"
        echo "     cp backup_${TIMESTAMP}/docker-compose.yml docker-compose.yml"
        echo "     cp backup_${TIMESTAMP}/.env .env"
        echo "     docker compose up -d"
        echo
    fi

    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Upgrade complete!${NC}"
    echo -e "${BOLD}========================================${NC}"
}

# ──────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────
main() {
    cd "$(dirname "$0")"

    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   jt-ipam Docker Compose Upgrade     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"

    verify_installed
    check_system
    check_docker
    backup_files
    pull_source
    pull_images
    recreate_containers
    run_verification
    cleanup_images
    show_info
}

main "$@"
