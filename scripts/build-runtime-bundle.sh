#!/usr/bin/env bash
# build-runtime-bundle.sh — Build the online runtime bundle release asset
#
# Usage:
#   ./scripts/build-runtime-bundle.sh --tag v0.5.92
#   ./scripts/build-runtime-bundle.sh --tag v0.5.92 --output /tmp/jt-ipam-runtime-v0.5.92.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TAG=""
OUTPUT=""
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --tag=*) TAG="${1#*=}"; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --output=*) OUTPUT="${1#*=}"; shift ;;
    -h|--help)
      echo "Usage: ./scripts/build-runtime-bundle.sh --tag vX.Y.Z [--output /path/file.tar.gz]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TAG" ]]; then
  if git -C "$REPO_ROOT" describe --tags --exact-match >/dev/null 2>&1; then
    TAG="$(git -C "$REPO_ROOT" describe --tags --exact-match)"
  else
    echo "--tag is required when HEAD is not exactly on a tag" >&2
    exit 1
  fi
fi

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="${REPO_ROOT}/jt-ipam-runtime-${TAG}.tar.gz"
fi

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
STAGING="$(mktemp -d /tmp/jt-ipam-runtime-XXXXXX)"
RUNTIME_DIR="${STAGING}/jt-ipam-runtime"

mkdir -p "${RUNTIME_DIR}/scripts" "${RUNTIME_DIR}/deploy/postgres"

cp "${REPO_ROOT}/install.sh" "${RUNTIME_DIR}/install.sh"
cp "${REPO_ROOT}/upgrade.sh" "${RUNTIME_DIR}/upgrade.sh"
cp "${REPO_ROOT}/docker-compose.yml" "${RUNTIME_DIR}/docker-compose.yml"
cp "${REPO_ROOT}/.env.docker.example" "${RUNTIME_DIR}/.env.docker.example"
cp "${REPO_ROOT}/deploy/postgres/init-docker.sh" "${RUNTIME_DIR}/deploy/postgres/init-docker.sh"
cp "${REPO_ROOT}/scripts/docker-backup.sh" "${RUNTIME_DIR}/scripts/docker-backup.sh"
cp "${REPO_ROOT}/scripts/docker-restore.sh" "${RUNTIME_DIR}/scripts/docker-restore.sh"

cat > "${RUNTIME_DIR}/RELEASE" <<EOF
INSTALL_CHANNEL=online
RELEASE_TAG=${TAG}
RELEASE_COMMIT=${COMMIT_SHA}
RELEASE_BUILT_AT=${TIMESTAMP}
EOF

cat > "${RUNTIME_DIR}/MANIFEST.txt" <<EOF
jt-ipam runtime bundle
Tag: ${TAG}
Commit: ${COMMIT_SHA}
Built at: ${TIMESTAMP}

Managed files:
  install.sh
  upgrade.sh
  docker-compose.yml
  .env.docker.example
  RELEASE
  deploy/postgres/init-docker.sh
  scripts/docker-backup.sh
  scripts/docker-restore.sh

Install (online):
  curl -fsSL https://raw.githubusercontent.com/tryweb/jt-ipam/main/install.sh | bash

Upgrade (local):
  bash upgrade.sh
EOF

chmod +x "${RUNTIME_DIR}/install.sh" "${RUNTIME_DIR}/upgrade.sh" "${RUNTIME_DIR}/scripts/"*.sh

tar czf "$OUTPUT" -C "$STAGING" jt-ipam-runtime
rm -rf "$STAGING"

echo "$OUTPUT"
