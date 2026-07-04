#!/usr/bin/env bash
# ==========================================================================
# install.sh — jt-ipam Docker Compose installer
#
# Installs jt-ipam via Docker Compose on a single host.  This is the
# **Docker Compose** path (root docker-compose.yml).  For the systemd + apt
# path, use:  sudo bash scripts/bootstrap.sh
#
# What this script does:
#   1. Checks system requirements (CPU, RAM, disk)
#   2. Checks Docker + Docker Compose are installed and running
#   3. Ensures the jt-ipam source is present (clones if needed)
#   4. Creates .env from .env.docker.example with generated secrets
#   5. Interactive prompt for APP_PUBLIC_URL / admin credentials
#   6. Pulls pre-built images:  docker compose pull
#   7. Starts services: docker compose up -d
#   8. Waits for all services to become healthy
#   9. Prints connection info, admin credentials, and maintenance tips
#
# For local development (build from source instead of pull):
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
#
# Usage:
#   bash install.sh
#   bash install.sh --non-interactive     # skip prompts, use defaults
#   bash install.sh --repo /path/to/jt-ipam   # use existing source
#
# Requirements:
#   - Docker Engine 24+ with compose v2 plugin
#   - 2 vCPU · 4 GB RAM · 20 GB disk (minimum)
#   - curl or wget (for git clone if source is missing)
#   - openssl (for secret generation)
# ==========================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────
# Repository configuration
# ──────────────────────────────────────────────────────────
REPO_URL="${JT_IPAM_REPO:-https://github.com/jasoncheng7115/jt-ipam.git}"
INSTALL_DIR="${JT_IPAM_DIR:-$(pwd)}"
NON_INTERACTIVE=false

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

# ──────────────────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --repo) INSTALL_DIR="$2"; shift 2 ;;
        --repo=*) INSTALL_DIR="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: bash install.sh [--non-interactive] [--repo /path]"
            exit 0
            ;;
        *) fail "Unknown argument: $1";;
    esac
done

# ──────────────────────────────────────────────────────────
# Step 0 — Parse CLI flags before changing directory
# ──────────────────────────────────────────────────────────
cd "$INSTALL_DIR"

# ──────────────────────────────────────────────────────────
# Step 1 — System requirements
# ──────────────────────────────────────────────────────────
check_system() {
    header "1. 檢查系統硬體規格 (System Requirements)"

    CPU_CORES=$(nproc 2>/dev/null || echo 0)
    RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    RAM_GB=$((RAM_KB / 1024 / 1024))
    DISK_KB=$(df -Pk . 2>/dev/null | tail -1 | awk '{print $4}' || echo 0)
    DISK_GB=$((DISK_KB / 1024 / 1024))

    echo "  CPU cores: $CPU_CORES  |  RAM: ${RAM_GB} GB  |  Disk available: ${DISK_GB} GB"

    if [ "$CPU_CORES" -lt 2 ]; then
        fail "Insufficient CPU cores (need ≥ 2, have $CPU_CORES)"
    fi
    if [ "$RAM_KB" -lt $((4 * 1024 * 1024)) ]; then
        fail "Insufficient RAM (need ≥ 4 GB, have ${RAM_GB} GB)"
    fi
    if [ "$DISK_GB" -lt 10 ]; then
        fail "Insufficient disk space (need ≥ 10 GB free, have ${DISK_GB} GB)"
    fi

    ok "System meets minimum requirements"
}

# ──────────────────────────────────────────────────────────
# Step 2 — Docker environment
# ──────────────────────────────────────────────────────────
check_docker() {
    header "2. 檢查 Docker 環境 (Docker Environment)"

    if ! command -v docker &>/dev/null; then
        fail "Docker is not installed. Install it first:
  curl -fsSL https://get.docker.com | sudo sh"
    fi
    ok "Docker: $(docker --version 2>/dev/null | head -1)"

    if command -v docker compose &>/dev/null; then
        ok "Docker Compose V2 (standalone binary)"
    elif docker compose version &>/dev/null 2>&1; then
        ok "Docker Compose V2 (plugin)"
    else
        fail "Docker Compose V2 is not installed"
    fi

    [ -S /var/run/docker.sock ] || fail "Docker socket (/var/run/docker.sock) not found"
    docker info &>/dev/null || fail "Cannot connect to Docker daemon"
    ok "Docker daemon is running"

    command -v openssl &>/dev/null || fail "openssl is required (for secret generation)"
    ok "openssl available"

    command -v git &>/dev/null || fail "git is required (for source management)"
    ok "git available"

    command -v curl &>/dev/null || command -v wget &>/dev/null || fail "curl or wget is required"
    ok "Network tools available"
}

# ──────────────────────────────────────────────────────────
# Step 3 — Check if already installed → delegate to upgrade
# ──────────────────────────────────────────────────────────
delegate_to_upgrade_if_installed() {
    if [ ! -f "docker-compose.yml" ]; then
        return 0
    fi

    # Check if .env exists with real secrets (not the template placeholders)
    if [ -f ".env" ]; then
        echo
        echo "========================================"
        echo "  Existing installation detected"
        echo "========================================"
        echo "  docker-compose.yml and .env already exist in $(pwd)"
        echo "  install.sh is for first-time installation only."
        echo

        if [ ! -f "upgrade.sh" ]; then
            echo "  This script will download upgrade.sh..."
            # Can't download — it's local, but we can warn
            warn "upgrade.sh not found in current directory"
        fi

        echo "  Delegating to upgrade flow..."
        echo
        if [ -f "upgrade.sh" ]; then
            exec bash upgrade.sh "$@"
        else
            warn "No upgrade.sh found. Run manually:"
            echo "    git pull"
            echo "    docker compose pull"
            echo "    docker compose up -d"
            exit 0
        fi
    fi
}

# ──────────────────────────────────────────────────────────
# Step 4 — Ensure source code
# ──────────────────────────────────────────────────────────
ensure_source() {
    header "3. 取得原始碼 (Acquiring Source)"

    if [ -d ".git" ]; then
        ok "Git repository already present: $(git rev-parse --short HEAD 2>/dev/null)"
        # Ensure we're on main
        local branch
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        echo "  Branch: $branch"
        if [ "$branch" != "main" ]; then
            warn "You are on branch '$branch', not 'main'. Continuing anyway."
        fi
    else
        echo "  Cloning jt-ipam from $REPO_URL ..."
        local tmpdir
        tmpdir=$(mktemp -d)
        git clone --depth 1 "$REPO_URL" "$tmpdir" || fail "git clone failed"
        # Move contents to current directory
        shopt -s dotglob
        mv "$tmpdir"/* . 2>/dev/null || true
        shopt -u dotglob
        rmdir "$tmpdir" 2>/dev/null || true
        ok "Source cloned to $(pwd)"
    fi
}

# ──────────────────────────────────────────────────────────
# Step 5 — Generate .env
# ──────────────────────────────────────────────────────────
generate_env() {
    header "4. 建立 .env (Environment Configuration)"

    if [ -f ".env" ]; then
        warn ".env already exists — skipping generation"
        info "Remove .env and re-run for fresh secrets (this invalidates encrypted data)"
        return
    fi

    if [ ! -f ".env.docker.example" ]; then
        fail ".env.docker.example not found — is this the jt-ipam repository root?"
    fi

    # Generate fresh secrets
    local secret_key encryption_key audit_genesis pg_password admin_password
    secret_key="$(openssl rand -hex 64)"
    encryption_key="$(openssl rand -base64 32)"
    audit_genesis="$(openssl rand -hex 64)"
    pg_password="$(openssl rand -hex 24)"
    admin_password="$(openssl rand -hex 16)"

    cp .env.docker.example .env
    chmod 600 .env

    sed -i "s|^SECRET_KEY=.*|SECRET_KEY=${secret_key}|" .env
    sed -i "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=${encryption_key}|" .env
    sed -i "s|^AUDIT_CHAIN_GENESIS=.*|AUDIT_CHAIN_GENESIS=${audit_genesis}|" .env
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pg_password}|" .env
    sed -i "s|^BOOTSTRAP_ADMIN_PASSWORD=.*|BOOTSTRAP_ADMIN_PASSWORD=${admin_password}|" .env

    ok ".env created with random secrets (chmod 600)"

    # ── Interactive configuration ──
    if [ "$NON_INTERACTIVE" = false ]; then
        echo
        echo "  Configure public URLs (press Enter to accept defaults):"

        # APP_PUBLIC_URL
        local default_url="https://localhost"
        read -r -p "  APP_PUBLIC_URL [${default_url}]: " input_url
        APP_PUBLIC_URL="${input_url:-$default_url}"
        sed -i "s|^APP_PUBLIC_URL=.*|APP_PUBLIC_URL=${APP_PUBLIC_URL}|" .env
        sed -i "s|^API_PUBLIC_URL=.*|API_PUBLIC_URL=${APP_PUBLIC_URL}|" .env
        sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=${APP_PUBLIC_URL}|" .env

        # Admin credentials
        local default_admin="admin"
        read -r -p "  Admin username [${default_admin}]: " input_admin
        BOOTSTRAP_ADMIN_USERNAME="${input_admin:-$default_admin}"
        sed -i "s|^BOOTSTRAP_ADMIN_USERNAME=.*|BOOTSTRAP_ADMIN_USERNAME=${BOOTSTRAP_ADMIN_USERNAME}|" .env

        read -r -p "  Admin email [admin@example.com]: " input_email
        BOOTSTRAP_ADMIN_EMAIL="${input_email:-admin@example.com}"
        sed -i "s|^BOOTSTRAP_ADMIN_EMAIL=.*|BOOTSTRAP_ADMIN_EMAIL=${BOOTSTRAP_ADMIN_EMAIL}|" .env

        ok "Environment configured"
    else
        # Non-interactive: keep defaults but ensure APP_PUBLIC_URL is set
        info "Non-interactive mode — using default URLs (https://localhost)"
        info "Edit .env to change APP_PUBLIC_URL / API_PUBLIC_URL / CORS_ORIGINS"
        APP_PUBLIC_URL="https://localhost"
    fi

    # Store admin password for display (after install)
    ADMIN_USERNAME="${BOOTSTRAP_ADMIN_USERNAME:-admin}"
    ADMIN_EMAIL="${BOOTSTRAP_ADMIN_EMAIL:-admin@example.com}"
    ADMIN_PASSWORD="${admin_password}"
}

# ──────────────────────────────────────────────────────────
# Step 6 — Pull images
# ──────────────────────────────────────────────────────────
pull_images() {
    header "5. 拉取 Docker 映像 (Pulling Images)"

    echo "  Pulling pre-built images from GitHub Container Registry..."
    echo "  (Use docker-compose.dev.yml to build locally instead)"
    echo
    if docker compose pull 2>&1; then
        ok "Images pulled successfully"
    else
        warn "Image pull failed (network issue?). Falling back to local cache."
        warn "If you need to build locally:"
        warn "  docker compose -f docker-compose.yml -f docker-compose.dev.yml build"
    fi
}

# ──────────────────────────────────────────────────────────
# Step 7 — Start services
# ──────────────────────────────────────────────────────────
start_services() {
    header "6. 啟動服務 (Starting Services)"

    echo "  Starting all services..."
    docker compose up -d 2>&1 || fail "Failed to start services"

    echo
    echo -n "  Waiting for services to become healthy"

    # Total timeout: 120 seconds
    local services
    services="postgres redis backend frontend"
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
        warn "Some services may not be healthy yet. Check with: docker compose ps"
        warn "View logs: docker compose logs -f"
    fi

    # Extra wait for migrations to complete on fresh DB
    echo "  Waiting for backend migrations (first startup)..."
    sleep 5
}

# ──────────────────────────────────────────────────────────
# Step 8 — Verification
# ──────────────────────────────────────────────────────────
run_verification() {
    header "7. 驗證服務 (Verification)"

    local passed=0
    local failed=0

    # 1. Check all services are running
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

    # 2. Check health endpoint
    echo
    echo "  Testing backend health endpoint..."
    local health_status
    health_status=$(curl -sf http://localhost:8000/healthz 2>/dev/null || true)
    if [ -n "$health_status" ]; then
        echo -e "  ${GREEN}✓${NC} Backend health endpoint: $health_status"
        passed=$((passed + 1))
    else
        # Backend is not directly exposed; check via frontend proxy
        health_status=$(curl -sf http://localhost:8080/api/v1/healthz 2>/dev/null || true)
        if [ -n "$health_status" ]; then
            echo -e "  ${GREEN}✓${NC} Frontend proxy health endpoint: $health_status"
            passed=$((passed + 1))
        else
            warn "Health endpoint not reachable (this is normal if TLS is not configured yet)"
        fi
    fi

    echo
    if [ "$failed" -eq 0 ]; then
        ok "All checks passed"
    else
        warn "${failed} check(s) failed — review with: docker compose logs"
    fi
}

# ──────────────────────────────────────────────────────────
# Step 9 — Show info
# ──────────────────────────────────────────────────────────
show_info() {
    header "8. 安裝完成 (Installation Complete)"

    # Determine host IP
    local host_ip=""
    if command -v ip &>/dev/null; then
        host_ip=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([^ ]*\).*/\1/p' | head -1 || true)
    elif command -v hostname &>/dev/null; then
        host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' | grep -v '^fe80\|^::' || true)
    fi
    host_ip="${host_ip:-localhost}"

    echo
    echo -e "  ${CYAN}🌐${NC}  Web UI:  http://${host_ip}:8080"
    echo -e "  ${CYAN}💻${NC}  API:     http://${host_ip}:8080/api/v1/"
    echo
    echo -e "  ${YELLOW}👤${NC}  Admin login:"
    echo -e "       Username: ${ADMIN_USERNAME}"
    echo -e "       Password: ${ADMIN_PASSWORD}"
    echo -e "       Email:    ${ADMIN_EMAIL}"
    echo
    echo -e "  ${RED}⚠${NC}  CHANGE the admin password immediately after first login."
    echo "       The initial password is stored in .env (mode 600)."
    echo

    # Maintenance scripts info
    echo -e "${BOLD}── Maintenance ──${NC}"
    echo
    if [ -f "scripts/docker-backup.sh" ]; then
        echo -e "  ${CYAN}📦${NC} Backup:    bash scripts/docker-backup.sh"
    fi
    if [ -f "scripts/docker-restore.sh" ]; then
        echo -e "  ${CYAN}♻${NC}  Restore:   bash scripts/docker-restore.sh <timestamp>"
    fi
    echo -e "  ${CYAN}📋${NC}  Logs:      docker compose logs -f"
    echo -e "  ${CYAN}⏹${NC}  Stop:      docker compose down"
    echo

    # Upgrade info
    if [ -f "upgrade.sh" ]; then
        echo -e "  ${YELLOW}🔄${NC}  Upgrade:   bash upgrade.sh"
    else
        echo -e "  ${YELLOW}🔄${NC}  Upgrade:   git pull && docker compose pull && docker compose up -d"
    fi
    echo

    echo -e "${BOLD}── Local Development ──${NC}"
    echo
    echo -e "  To build from source instead of using pre-built images:"
    echo -e "  ${CYAN}docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build${NC}"
    echo

    # For public URL setups
    if [ "${APP_PUBLIC_URL:-}" != "https://localhost" ] && [ -n "${APP_PUBLIC_URL:-}" ]; then
        echo -e "${BOLD}── External Access ──${NC}"
        echo
        echo -e "  Public URL: ${APP_PUBLIC_URL}"
        echo -e "  Make sure DNS resolves to this host and ports 80/443 are reachable."
        echo
    fi

    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Installation complete!${NC}"
    echo -e "${BOLD}========================================${NC}"
}

# ──────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────
main() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   jt-ipam Docker Compose Installer   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    check_system
    check_docker
    delegate_to_upgrade_if_installed "$@"
    ensure_source
    generate_env
    pull_images
    start_services
    run_verification
    show_info
}

main "$@"
