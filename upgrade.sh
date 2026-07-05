#!/usr/bin/env bash
# upgrade.sh — jt-ipam Docker Compose runtime-bundle upgrade
#
# Upgrades an existing Docker Compose deployment to the latest runtime bundle
# published as a GitHub Release asset.
#
# What this script does:
#   1. Verifies an existing installation (docker-compose.yml must exist)
#   2. Checks system requirements
#   3. Resolves the target release tag (latest by default)
#   4. Backs up bundle-managed files
#   5. Downloads and applies the runtime bundle
#   6. Pulls latest images: docker compose pull
#   7. Recreates containers: docker compose up -d --force-recreate
#   8. Waits for services to become healthy
#   9. Cleans up dangling Docker images
#  10. Prints upgrade summary
#
# Usage:
#   bash upgrade.sh
#   bash upgrade.sh --tag v0.5.92
#   bash upgrade.sh --no-pull         # skip bundle download; use current local files
#   bash upgrade.sh --no-backup
#   bash upgrade.sh --no-cleanup
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RELEASE_REPO="${JT_IPAM_RELEASE_REPO:-tryweb/jt-ipam}"
TARGET_TAG="${JT_IPAM_TAG:-}"
NO_PULL=false
NO_BACKUP=false
NO_CLEANUP=false
BUNDLE_PATH=""
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
        fail "curl or wget is required"
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
        fail "curl or wget is required"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) TARGET_TAG="$2"; EXPLICIT_TAG=true; shift 2 ;;
        --tag=*) TARGET_TAG="${1#*=}"; EXPLICIT_TAG=true; shift ;;
        --no-pull) NO_PULL=true; shift ;;
        --no-backup) NO_BACKUP=true; shift ;;
        --no-cleanup) NO_CLEANUP=true; shift ;;
        --bundle) BUNDLE_PATH="$2"; shift 2 ;;
        --bundle=*) BUNDLE_PATH="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: bash upgrade.sh [--tag vX.Y.Z] [--bundle /path/to/offline.tar.gz] [--no-pull] [--no-backup] [--no-cleanup]"
            exit 0
            ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

CURRENT_TAG=""
CURRENT_CHANNEL="online"
LEGACY_GIT_INSTALL=false

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

get_env_value() {
    local key="$1"
    local file="$2"
    sed -n "s/^${key}=//p" "$file" | head -1
}

asset_name() {
    printf 'jt-ipam-runtime-%s.tar.gz' "$1"
}

asset_url() {
    local tag="$1"
    printf 'https://github.com/%s/releases/download/%s/%s' "$RELEASE_REPO" "$tag" "$(asset_name "$tag")"
}

load_current_release() {
    if [ -f RELEASE ]; then
        # shellcheck disable=SC1091
        . ./RELEASE
        CURRENT_TAG="${RELEASE_TAG:-}"
        CURRENT_CHANNEL="${INSTALL_CHANNEL:-$CURRENT_CHANNEL}"
    fi

    if [ -f .env ]; then
        local env_channel
        env_channel="$(get_env_value INSTALL_CHANNEL .env)"
        if [ -n "$env_channel" ]; then
            CURRENT_CHANNEL="$env_channel"
        fi
    fi

    if [ -z "$CURRENT_TAG" ]; then
        CURRENT_TAG="legacy"
    fi
}

resolve_latest_tag() {
    local json latest_tag
    json=$(http_get "https://api.github.com/repos/${RELEASE_REPO}/releases/latest") || \
        fail "Failed to query latest release from ${RELEASE_REPO}"

    latest_tag=$(printf '%s\n' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$latest_tag" ] || fail "Could not parse latest release tag from GitHub API"
    printf '%s' "$latest_tag"
}

resolve_target_tag() {
    header "3. 解析版本 (Release Resolution)"

    if [ "$CURRENT_CHANNEL" = "offline" ]; then
        info "Offline installation detected"
        return
    fi

    if [ "$NO_PULL" = true ]; then
        info "Bundle download skipped (--no-pull)"
        return
    fi

    if [ -n "$TARGET_TAG" ]; then
        TARGET_TAG="$TARGET_TAG"
        info "Using requested release tag: ${TARGET_TAG}"
    else
        TARGET_TAG="$(resolve_latest_tag)"
        info "Using latest release tag: ${TARGET_TAG}"
    fi

    if [ "$CURRENT_TAG" = "$TARGET_TAG" ]; then
        info "Already on release ${CURRENT_TAG}; files will be refreshed in-place"
    else
        info "Upgrade target: ${CURRENT_TAG} → ${TARGET_TAG}"
    fi

    ok "Release target resolved: ${TARGET_TAG}"
}

verify_installed() {
    if [ ! -f "docker-compose.yml" ]; then
        fail "No installation found (docker-compose.yml missing).\n\nupgrade.sh is for upgrading an existing Docker Compose deployment.\nFirst-time install: bash install.sh"
    fi

    if [ -d ".git" ] && [ ! -f "RELEASE" ]; then
        LEGACY_GIT_INSTALL=true
        warn "Legacy git-managed install detected — this run will migrate it to release-bundle management"
    fi

    ok "Existing installation detected"
}

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

check_docker() {
    header "2. 檢查 Docker 環境 (Docker Environment)"

    command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
    ok "Docker: $(docker --version 2>/dev/null | head -1)"

    docker compose version >/dev/null 2>&1 || fail "Docker Compose V2 not found"
    ok "Docker Compose V2 available"

    [ -S /var/run/docker.sock ] || fail "Docker socket not found"
    docker info >/dev/null 2>&1 || fail "Cannot connect to Docker daemon"
    ok "Docker daemon is running"

    if [ "$CURRENT_CHANNEL" = "online" ] && [ "$NO_PULL" = false ]; then
        command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fail "curl or wget is required for bundle downloads"
        ok "Network download tool available"
    fi

    command -v tar >/dev/null 2>&1 || fail "tar is required"
}

backup_files() {
    if [ "$NO_BACKUP" = true ]; then
        info "Backup skipped (--no-backup)"
        return
    fi

    header "4. 備份設定檔 (Backup Configuration)"

    local backup_dir="backup_${TIMESTAMP}"
    mkdir -p "$backup_dir"

    for f in docker-compose.yml .env .env.docker.example install.sh upgrade.sh RELEASE MANIFEST.txt; do
        if [ -f "$f" ]; then
            cp "$f" "${backup_dir}/${f}"
            ok "${f} → ${backup_dir}/${f}"
        fi
    done

    if [ -d "scripts" ]; then
        cp -r scripts "${backup_dir}/scripts" 2>/dev/null && ok "scripts/ → ${backup_dir}/scripts/"
    fi
    if [ -d "deploy" ]; then
        cp -r deploy "${backup_dir}/deploy" 2>/dev/null && ok "deploy/ → ${backup_dir}/deploy/"
    fi

    info "Backup saved to: ${backup_dir}/"
}

download_runtime_bundle() {
    local output="$1"
    header "5. 下載 Runtime Bundle (Downloading Runtime Bundle)"
    info "Asset: $(asset_name "$TARGET_TAG")"
    info "Source: $(asset_url "$TARGET_TAG")"
    http_download "$(asset_url "$TARGET_TAG")" "$output" || fail "Failed to download runtime bundle"
    ok "Runtime bundle downloaded"
}

download_offline_bundle() {
    local output="$1"
    header "5. 準備 Offline Bundle (Preparing Offline Bundle)"
    [ -n "$BUNDLE_PATH" ] || fail "Offline installs require --bundle /path/to/jt-ipam-offline-*.tar.gz"
    [ -f "$BUNDLE_PATH" ] || fail "Offline bundle not found: $BUNDLE_PATH"
    cp "$BUNDLE_PATH" "$output"
    ok "Offline bundle copied from $BUNDLE_PATH"
}

apply_runtime_bundle() {
    local archive="$1"
    local tmpdir runtime_dir
    header "6. 套用 Runtime Bundle (Applying Runtime Bundle)"

    if [ "$NO_PULL" = true ]; then
        info "Skipping bundle apply (--no-pull); using current local files"
        return
    fi

    tmpdir=$(mktemp -d)
    tar xzf "$archive" -C "$tmpdir" || fail "Failed to extract runtime bundle"
    runtime_dir="${tmpdir}/jt-ipam-runtime"

    [ -d "$runtime_dir" ] || fail "Runtime bundle missing jt-ipam-runtime/ root"

    mkdir -p ./scripts ./deploy
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
        cp -a "${runtime_dir}/deploy/." ./deploy/
    fi

    chmod +x ./install.sh ./upgrade.sh ./scripts/*.sh 2>/dev/null || true
    rm -rf "$tmpdir" "$archive"
    ok "Runtime bundle applied"
}

apply_offline_bundle() {
    local archive="$1"
    local tmpdir offline_dir

    header "6. 套用 Offline Bundle (Applying Offline Bundle)"

    if [ "$NO_PULL" = true ]; then
        info "Skipping offline bundle apply (--no-pull); using current local files"
        return
    fi

    tmpdir=$(mktemp -d)
    tar xzf "$archive" -C "$tmpdir" || fail "Failed to extract offline bundle"
    offline_dir="${tmpdir}/jt-ipam-offline"

    [ -d "$offline_dir" ] || fail "Offline bundle missing jt-ipam-offline/ root"
    [ -f "${offline_dir}/images.tar" ] || fail "Offline bundle missing images.tar"
    [ -f "${offline_dir}/docker-compose.yml" ] || fail "Offline bundle missing docker-compose.yml"
    [ -f "${offline_dir}/upgrade.sh" ] || fail "Offline bundle missing upgrade.sh"
    [ -f "${offline_dir}/RELEASE" ] || fail "Offline bundle missing RELEASE"

    cp "${offline_dir}/images.tar" ./images.tar
    cp "${offline_dir}/docker-compose.yml" ./docker-compose.yml
    cp "${offline_dir}/.env.example" ./.env.docker.example
    cp "${offline_dir}/install.sh" ./install.sh
    cp "${offline_dir}/upgrade.sh" ./upgrade.sh
    cp "${offline_dir}/RELEASE" ./RELEASE

    if [ -f "${offline_dir}/MANIFEST.txt" ]; then
        cp "${offline_dir}/MANIFEST.txt" ./MANIFEST.txt
    fi
    if [ -d "${offline_dir}/scripts" ]; then
        mkdir -p ./scripts
        cp -a "${offline_dir}/scripts/." ./scripts/
    fi
    if [ -d "${offline_dir}/deploy" ]; then
        mkdir -p ./deploy
        cp -a "${offline_dir}/deploy/." ./deploy/
    fi

    chmod +x ./install.sh ./upgrade.sh ./scripts/*.sh 2>/dev/null || true
    rm -rf "$tmpdir" "$archive"
    ok "Offline bundle files refreshed"

    if [ -f ./images.tar ]; then
        header "7. 載入 Offline Images (Loading Offline Images)"
        docker load -i ./images.tar >/dev/null || fail "Failed to load images.tar"
        ok "Offline images loaded"
    fi
}

update_online_images_in_env() {
    local desired_backend desired_frontend current_backend current_frontend
    local managed_prefix_backend='ghcr.io/tryweb/jt-ipam-backend:'
    local managed_prefix_frontend='ghcr.io/tryweb/jt-ipam-frontend:'

    [ -f .env ] || return

    current_backend="$(get_env_value BACKEND_IMAGE .env)"
    current_frontend="$(get_env_value FRONTEND_IMAGE .env)"

    if [ "$EXPLICIT_TAG" = true ]; then
        desired_backend="${managed_prefix_backend}${TARGET_TAG}"
        desired_frontend="${managed_prefix_frontend}${TARGET_TAG}"
    elif [[ "$current_backend" = ${managed_prefix_backend}latest && "$current_frontend" = ${managed_prefix_frontend}latest ]]; then
        set_env_value INSTALL_CHANNEL online .env
        return
    elif [[ "$current_backend" = ${managed_prefix_backend}* && "$current_frontend" = ${managed_prefix_frontend}* ]]; then
        desired_backend="${managed_prefix_backend}${TARGET_TAG}"
        desired_frontend="${managed_prefix_frontend}${TARGET_TAG}"
    else
        set_env_value INSTALL_CHANNEL online .env
        return
    fi

    set_env_value BACKEND_IMAGE "$desired_backend" .env
    set_env_value FRONTEND_IMAGE "$desired_frontend" .env
    set_env_value INSTALL_CHANNEL online .env
}

update_offline_channel_in_env() {
    [ -f .env ] || return
    set_env_value INSTALL_CHANNEL offline .env
}

pull_images() {
    if [ "$CURRENT_CHANNEL" = "offline" ]; then
        return
    fi

    header "7. 拉取最新 Docker 映像 (Pulling Images)"

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
    fi
}

recreate_containers() {
    if [ "$CURRENT_CHANNEL" = "offline" ]; then
        header "8. 重建容器 (Applying Offline Containers)"
    else
        header "8. 重建容器 (Recreating Containers)"
    fi

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
        ok "All services verified"
    else
        warn "${failed} service(s) not healthy — check: docker compose logs"
    fi
}

cleanup_images() {
    if [ "$NO_CLEANUP" = true ]; then
        info "Cleanup skipped (--no-cleanup)"
        return
    fi

    header "10. 清理舊映像 (Cleanup)"

    local pruned
    pruned=$(docker image prune -f 2>&1 | sed -n 's/.*Total reclaimed space: \(.*\)/\1/p' || true)
    if [ -n "$pruned" ]; then
        ok "Reclaimed: ${pruned}"
    else
        info "Nothing to clean up"
    fi
}

show_info() {
    header "11. 升級完成 (Upgrade Complete)"

    local host_ip=""
    if command -v ip >/dev/null 2>&1; then
        host_ip=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([^ ]*\).*/\1/p' | head -1 || true)
    elif command -v hostname >/dev/null 2>&1; then
        host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' | grep -v '^fe80\|^::' || true)
    fi
    host_ip="${host_ip:-localhost}"

    load_current_release

    echo
    echo -e "  ${CYAN}🏷${NC}  Release:  ${CURRENT_TAG}"
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
        echo "     cp backup_${TIMESTAMP}/upgrade.sh upgrade.sh 2>/dev/null || true"
        echo "     docker compose up -d"
        echo
    fi

    if [ "$LEGACY_GIT_INSTALL" = true ]; then
        warn "Legacy git checkout migrated to release-bundle management. Old source files remain on disk until you clean them up manually."
        echo
    fi

    echo -e "${BOLD}  Upgrade complete!${NC}"
}

main() {
    local bundle_archive=""

    cd "$(dirname "$0")"

    echo
    echo -e "${BOLD}║   jt-ipam Docker Compose Upgrade     ║${NC}"

    verify_installed
    load_current_release
    check_system
    check_docker
    resolve_target_tag
    backup_files

    if [ "$CURRENT_CHANNEL" = "offline" ]; then
        if [ "$NO_PULL" = false ]; then
            bundle_archive=$(mktemp /tmp/jt-ipam-offline-XXXXXX.tar.gz)
            download_offline_bundle "$bundle_archive"
            apply_offline_bundle "$bundle_archive"
            load_current_release
            update_offline_channel_in_env
        fi
    elif [ "$NO_PULL" = false ]; then
        bundle_archive=$(mktemp /tmp/jt-ipam-runtime-XXXXXX.tar.gz)
        download_runtime_bundle "$bundle_archive"
        apply_runtime_bundle "$bundle_archive"
        load_current_release
        update_online_images_in_env
    else
        apply_runtime_bundle ""
    fi

    pull_images
    recreate_containers
    run_verification
    cleanup_images
    show_info
}

main "$@"
