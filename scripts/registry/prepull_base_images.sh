#!/usr/bin/env bash
# =============================================================================
# prepull_base_images.sh — pre-pull common web-stack base images
#                          (JDK/Maven, MySQL/Postgres/Redis, nginx/node/python/go/php)
#                          through the mainland mirror fallback chain, and
#                          re-tag to canonical names so Compose stays portable.
#
# Run ONCE on a fresh host (or after clearing images). Idempotent: already-cached
# images are skipped with zero network traffic.
#
# Usage:
#   bash scripts/registry/prepull_base_images.sh
#   bash scripts/registry/prepull_base_images.sh --java-only
#   bash scripts/registry/prepull_base_images.sh --dry-run
# =============================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULLER="${SCRIPT_DIR}/pull_with_fallback.sh"
[[ -f "$PULLER" ]] || { echo "ERROR: $PULLER not found" >&2; exit 1; }

DRY_RUN=0
JAVA_ONLY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --java-only) JAVA_ONLY=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# Common Java runtimes across LTS releases.
JAVA_IMAGES=(
  "eclipse-temurin:17-jre"
  "eclipse-temurin:21-jre"
  "maven:3.9-eclipse-temurin-17"
  "maven:3.9-eclipse-temurin-21"
)

# Mainstream databases / caches / message queues.
DATA_IMAGES=(
  "mysql:8.0"
  "mariadb:10.11"
  "postgres:16-alpine"
  "redis:7.2-alpine"
  "rabbitmq:3.13-management"
)

# Common web / language runtimes.
WEB_IMAGES=(
  "nginx:alpine"
  "node:20-bookworm-slim"
  "node:22-bookworm-slim"
  "python:3.11-slim"
  "python:3.12-slim"
  "golang:1.22-alpine"
  "php:8.2-fpm"
)

# Tiny utilities used in compose healthchecks / init containers.
UTIL_IMAGES=(
  "busybox:1.36"
  "alpine:3.20"
  "curlimages/curl:8.8.0"
)

pull_group() {
  local group_name="$1"; shift
  echo
  echo "=============================================================="
  echo " Group: $group_name  (${#@} images)"
  echo "=============================================================="
  local ok=0 skip=0 fail=0
  local failed_str=""
  for img in "$@"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      echo "[skip] $img (already present)"
      skip=$((skip+1)); continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry ] would pull: $img"
      continue
    fi
    if bash "$PULLER" "$img"; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
      failed_str="${failed_str} ${img}"
    fi
  done
  echo "--- $group_name: pulled=$ok skipped=$skip failed=$fail"
  if [[ "$fail" -gt 0 ]]; then
    echo "    FAILED:${failed_str}"
    return 1
  fi
  return 0
}

RC=0
if [[ "$JAVA_ONLY" -eq 1 ]]; then
  pull_group "JAVA" "${JAVA_IMAGES[@]}" || RC=1
else
  pull_group "JAVA" "${JAVA_IMAGES[@]}" || RC=1
  pull_group "DATA" "${DATA_IMAGES[@]}" || RC=1
  pull_group "WEB"  "${WEB_IMAGES[@]}"  || RC=1
  pull_group "UTIL" "${UTIL_IMAGES[@]}" || RC=1
fi

echo
echo "=============================================================="
echo " Summary"
echo "=============================================================="
docker images --format '{{.Repository}}:{{.Tag}}' | grep -vE '^<none>' | sort | head -60
echo
if [[ "$RC" -ne 0 ]]; then
  echo "Some images failed. Re-run, or pull the listed ones with:"
  echo "  mihomo_ctl.sh run docker pull <image>"
  exit 1
fi
echo "All base images ready."
