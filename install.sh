#!/usr/bin/env bash
# install.sh — jt-ipam Docker Compose installer bootstrap
#
# Installs jt-ipam via a versioned runtime bundle published as a GitHub
# Release asset. The bootstrap script itself stays at the stable raw URL:
#   curl -fsSL https://raw.githubusercontent.com/tryweb/jt-ipam/main/install.sh | bash
#
# What this script does:
#   1. Checks system requirements (CPU, RAM, disk)
#   2. Checks Docker + Docker Compose are installed and running
#   3. Resolves the target release tag (latest by default)
#   4. Downloads the matching runtime bundle asset
#   5. Installs bundle-managed files into the target directory
#   6. Creates .env from .env.docker.example with generated secrets
#   7. Pulls pre-built images: docker compose pull
#   8. Starts services: docker compose up -d
#   9. Prints connection info, admin credentials, and maintenance tips
#
# Usage:
#   bash install.sh
#   bash install.sh --non-interactive
#   bash install.sh --dir /opt/jt-ipam
#   bash install.sh --tag v0.5.92
set -euo pipefail

RELEASE_REPO="${JT_IPAM_RELEASE_REPO:-tryweb/jt-ipam}"
INSTALL_DIR="${JT_IPAM_DIR:-$(pwd)}"
TARGET_TAG="${JT_IPAM_TAG:-}"
NON_INTERACTIVE=false
EXPLICIT_TAG=false

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
    echo -e "${BOLD} $1${NC}"
}

http_get() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url"
    else
        fail "curl is required for install bootstrap"
    fi
}

http_download() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url"
    else
        fail "curl is required for install bootstrap"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        --dir=*) INSTALL_DIR="${1#*=}"; shift ;;
        --tag) TARGET_TAG="$2"; EXPLICIT_TAG=true; shift 2 ;;
        --tag=*) TARGET_TAG="${1#*=}"; EXPLICIT_TAG=true; shift ;;
        -h|--help)
            echo "Usage: bash install.sh [--non-interactive] [--dir /path] [--tag vX.Y.Z]"
            exit 0
            ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

CURRENT_TAG=""
ADMIN_USERNAME="admin"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD=""
APP_PUBLIC_URL=""

set_env_value() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

set_online_install_channel() {
    local file="$1"
    set_env_value "INSTALL_CHANNEL" "online" "$file"
}

set_online_images_if_needed() {
    local file="$1"
    local backend_default="ghcr.io/tryweb/jt-ipam-backend:latest"
    local frontend_default="ghcr.io/tryweb/jt-ipam-frontend:latest"

    set_online_install_channel "$file"

    if [ "$EXPLICIT_TAG" = true ]; then
        set_env_value "BACKEND_IMAGE" "ghcr.io/tryweb/jt-ipam-backend:${CURRENT_TAG}" "$file"
        set_env_value "FRONTEND_IMAGE" "ghcr.io/tryweb/jt-ipam-frontend:${CURRENT_TAG}" "$file"
        return
    fi

    if ! grep -q '^BACKEND_IMAGE=' "$file"; then
        set_env_value "BACKEND_IMAGE" "$backend_default" "$file"
    fi
    if ! grep -q '^FRONTEND_IMAGE=' "$file"; then
        set_env_value "FRONTEND_IMAGE" "$frontend_default" "$file"
    fi
}

resolve_latest_tag() {
    local json
    json=$(http_get "https://api.github.com/repos/${RELEASE_REPO}/releases/latest") || \
        fail "Failed to query latest release from ${RELEASE_REPO}"

    CURRENT_TAG=$(printf '%s\n' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$CURRENT_TAG" ] || fail "Could not parse latest release tag from GitHub API"
}

resolve_target_tag() {
    header "3. 解析版本 (Release Resolution)"

    if [ -n "$TARGET_TAG" ]; then
        CURRENT_TAG="$TARGET_TAG"
        info "Using requested release tag: ${CURRENT_TAG}"
    else
        resolve_latest_tag
        info "Using latest release tag: ${CURRENT_TAG}"
    fi

    ok "Release tag resolved: ${CURRENT_TAG}"
}

asset_name() {
    printf 'jt-ipam-runtime-%s.tar.gz' "$1"
}

asset_url() {
    local tag="$1"
    printf 'https://github.com/%s/releases/download/%s/%s' "$RELEASE_REPO" "$tag" "$(asset_name "$tag")"
}

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

check_docker() {
    header "2. 檢查 Docker 環境 (Docker Environment)"

    if ! command -v docker >/dev/null 2>&1; then
        fail "Docker is not installed. Install it first:\n  curl -fsSL https://get.docker.com | sudo sh"
    fi
    ok "Docker: $(docker --version 2>/dev/null | head -1)"

    if docker compose version >/dev/null 2>&1; then
        ok "Docker Compose V2 available"
    else
        fail "Docker Compose V2 is not installed"
    fi

    [ -S /var/run/docker.sock ] || fail "Docker socket (/var/run/docker.sock) not found"
    docker info >/dev/null 2>&1 || fail "Cannot connect to Docker daemon"
    ok "Docker daemon is running"

    command -v openssl >/dev/null 2>&1 || fail "openssl is required (for secret generation)"
    ok "openssl available"

    command -v tar >/dev/null 2>&1 || fail "tar is required"
    ok "tar available"

    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fail "curl is required"
    ok "Network download tool available"
}

refresh_upgrade_script_from_bundle() {
    local tmpdir bundle archive runtime_dir
    tmpdir=$(mktemp -d)
    archive="${tmpdir}/bundle.tar.gz"

    info "Refreshing local upgrade.sh from release ${CURRENT_TAG}"
    http_download "$(asset_url "$CURRENT_TAG")" "$archive" || fail "Failed to download runtime bundle"
    tar xzf "$archive" -C "$tmpdir" || fail "Failed to extract runtime bundle"

    runtime_dir="${tmpdir}/jt-ipam-runtime"
    [ -f "${runtime_dir}/upgrade.sh" ] || fail "Runtime bundle missing upgrade.sh"
    cp "${runtime_dir}/upgrade.sh" ./upgrade.sh
    chmod +x ./upgrade.sh
    rm -rf "$tmpdir"
    ok "Local upgrade.sh refreshed"
}

delegate_to_upgrade_if_installed() {
    if [ ! -f "docker-compose.yml" ] || [ ! -f ".env" ]; then
        return 0
    fi

    echo
    echo "  Existing installation detected"
    echo "  docker-compose.yml and .env already exist in $(pwd)"
    echo

    if [ -d ".git" ] || [ ! -f "RELEASE" ]; then
        warn "Detected legacy git-managed install — bootstrapping bundle-based upgrade"
        resolve_target_tag
        refresh_upgrade_script_from_bundle
    elif [ ! -f "upgrade.sh" ]; then
        warn "Local upgrade.sh missing — refreshing from release asset"
        resolve_target_tag
        refresh_upgrade_script_from_bundle
    fi

    echo "  Delegating to upgrade flow..."
    echo
    if [ -n "$TARGET_TAG" ]; then
        exec bash ./upgrade.sh --tag "$TARGET_TAG"
    fi
    exec bash ./upgrade.sh
}

download_runtime_bundle() {
    local output="$1"
    header "4. 下載 Runtime Bundle (Downloading Runtime Bundle)"
    info "Asset: $(asset_name "$CURRENT_TAG")"
    info "Source: $(asset_url "$CURRENT_TAG")"
    http_download "$(asset_url "$CURRENT_TAG")" "$output" || fail "Failed to download runtime bundle"
    ok "Runtime bundle downloaded"
}

install_runtime_bundle() {
    local archive="$1"
    local tmpdir runtime_dir
    header "5. 安裝 Runtime Bundle (Installing Runtime Bundle)"

    tmpdir=$(mktemp -d)
    tar xzf "$archive" -C "$tmpdir" || fail "Failed to extract runtime bundle"
    runtime_dir="${tmpdir}/jt-ipam-runtime"

    [ -d "$runtime_dir" ] || fail "Runtime bundle missing jt-ipam-runtime/ root"
    [ -f "${runtime_dir}/docker-compose.yml" ] || fail "Runtime bundle missing docker-compose.yml"
    [ -f "${runtime_dir}/.env.docker.example" ] || fail "Runtime bundle missing .env.docker.example"
    [ -f "${runtime_dir}/upgrade.sh" ] || fail "Runtime bundle missing upgrade.sh"

    mkdir -p ./scripts ./deploy/postgres

    cp "${runtime_dir}/docker-compose.yml" ./docker-compose.yml
    cp "${runtime_dir}/.env.docker.example" ./.env.docker.example
    cp "${runtime_dir}/install.sh" ./install.sh
    cp "${runtime_dir}/upgrade.sh" ./upgrade.sh
    cp "${runtime_dir}/RELEASE" ./RELEASE

    if [ -f "${runtime_dir}/MANIFEST.txt" ]; then
        cp "${runtime_dir}/MANIFEST.txt" ./MANIFEST.txt
    fi
    if [ -d "${runtime_dir}/scripts" ]; then
        cp -a "${runtime_dir}/scripts/." ./scripts/
    fi
    if [ -d "${runtime_dir}/deploy" ]; then
        mkdir -p ./deploy
        cp -a "${runtime_dir}/deploy/." ./deploy/
    fi

    chmod +x ./install.sh ./upgrade.sh ./scripts/*.sh 2>/dev/null || true
    rm -rf "$tmpdir" "$archive"
    ok "Runtime bundle installed into $(pwd)"
}

generate_env() {
    header "6. 建立 .env (Environment Configuration)"

    if [ -f ".env" ]; then
        warn ".env already exists — skipping generation"
        info "Remove .env and re-run for fresh secrets (this invalidates encrypted data)"
        return
    fi

    if [ ! -f ".env.docker.example" ]; then
        fail ".env.docker.example not found — runtime bundle incomplete"
    fi

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
    set_online_images_if_needed .env

    ok ".env created with random secrets (chmod 600)"

    if [ "$NON_INTERACTIVE" = false ]; then
        echo
        echo "  Configure public URLs (press Enter to accept defaults):"

        local default_url="https://localhost"
        read -r -p "  APP_PUBLIC_URL [${default_url}]: " input_url
        APP_PUBLIC_URL="${input_url:-$default_url}"
        sed -i "s|^APP_PUBLIC_URL=.*|APP_PUBLIC_URL=${APP_PUBLIC_URL}|" .env
        sed -i "s|^API_PUBLIC_URL=.*|API_PUBLIC_URL=${APP_PUBLIC_URL}|" .env
        sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=${APP_PUBLIC_URL}|" .env

        local default_admin="admin"
        read -r -p "  Admin username [${default_admin}]: " input_admin
        ADMIN_USERNAME="${input_admin:-$default_admin}"
        sed -i "s|^BOOTSTRAP_ADMIN_USERNAME=.*|BOOTSTRAP_ADMIN_USERNAME=${ADMIN_USERNAME}|" .env

        read -r -p "  Admin email [admin@example.com]: " input_email
        ADMIN_EMAIL="${input_email:-admin@example.com}"
        sed -i "s|^BOOTSTRAP_ADMIN_EMAIL=.*|BOOTSTRAP_ADMIN_EMAIL=${ADMIN_EMAIL}|" .env

        ok "Environment configured"
    else
        info "Non-interactive mode — using default URLs (https://localhost)"
        APP_PUBLIC_URL="https://localhost"
        sed -i "s|^APP_PUBLIC_URL=.*|APP_PUBLIC_URL=${APP_PUBLIC_URL}|" .env
        sed -i "s|^API_PUBLIC_URL=.*|API_PUBLIC_URL=${APP_PUBLIC_URL}|" .env
        sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=${APP_PUBLIC_URL}|" .env
    fi

    ADMIN_PASSWORD="$admin_password"
}

pull_images() {
    header "7. 拉取 Docker 映像 (Pulling Images)"

    echo "  Pulling pre-built images from GitHub Container Registry..."
    echo
    if docker compose pull 2>&1; then
        ok "Images pulled successfully"
    else
        warn "Image pull failed (network issue?). Falling back to local cache."
    fi
}

start_services() {
    header "8. 啟動服務 (Starting Services)"

    echo "  Starting all services..."
    docker compose up -d 2>&1 || fail "Failed to start services"

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
        warn "Some services may not be healthy yet. Check with: docker compose ps"
        warn "View logs: docker compose logs -f"
    fi

    echo "  Waiting for backend migrations (first startup)..."
    sleep 5
}

run_verification() {
    header "9. 驗證服務 (Verification)"

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
        ok "All checks passed"
    else
        warn "${failed} check(s) failed — review with: docker compose logs"
    fi
}

show_info() {
    header "10. 安裝完成 (Installation Complete)"

    local host_ip=""
    if command -v ip >/dev/null 2>&1; then
        host_ip=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([^ ]*\).*/\1/p' | head -1 || true)
    elif command -v hostname >/dev/null 2>&1; then
        host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' | grep -v '^fe80\|^::' || true)
    fi
    host_ip="${host_ip:-localhost}"

    echo
    echo -e "  ${CYAN}🏷${NC}  Release: ${CURRENT_TAG}"
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
    echo -e "  ${YELLOW}🔄${NC}  Upgrade:   bash upgrade.sh"
    echo
    echo -e "${BOLD}  Installation complete!${NC}"
}

main() {
    local bundle_archive

    echo
    echo -e "${BOLD}║   jt-ipam Docker Compose Installer   ║${NC}"
    echo

    check_system
    check_docker
    delegate_to_upgrade_if_installed
    resolve_target_tag

    bundle_archive=$(mktemp /tmp/jt-ipam-runtime-XXXXXX.tar.gz)
    download_runtime_bundle "$bundle_archive"
    install_runtime_bundle "$bundle_archive"
    generate_env
    pull_images
    start_services
    run_verification
    show_info
}

main "$@"
