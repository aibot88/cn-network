#!/usr/bin/env bash
# =============================================================================
# pull_with_fallback.sh — pull a Docker image through mainland mirror chain,
#                        verify the manifest/tag really exists, verify platform,
#                        then re-tag it back to the canonical name.
#
# Works across Linux, macOS, WSL2, and Windows (Git Bash).
#
# Usage:
#   ./pull_with_fallback.sh redis:6-alpine
#   ./pull_with_fallback.sh ghcr.io/org/img:v1 --platform linux/amd64
#   MIRRORS="docker.1ms.run docker.1panel.live" ./pull_with_fallback.sh nginx:alpine
#
# Exit codes: 0 success, 1 all mirrors failed, 2 bad usage
# =============================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1

DEFAULT_MIRRORS="docker.1ms.run docker.1panel.live docker.m.daocloud.io"
MIRRORS="${MIRRORS:-$DEFAULT_MIRRORS}"
PLATFORM=""
REF=""

die() { echo "ERROR: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --platform=*) PLATFORM="${1#*=}"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) REF="$1"; shift ;;
  esac
done

[[ -n "$REF" ]] || die "missing image reference (e.g. redis:6-alpine)"
command -v docker >/dev/null 2>&1 || die "docker CLI not found"

# --- Split canonical reference -------------------------------------------------
first="${REF%%/*}"
if [[ "$REF" == */* ]] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [[ "$first" == "localhost" ]]; }; then
  ORIGIN_HOST="$first"
  REST="${REF#*/}"
  BARE_REF="$REF"
  CANONICAL="$REF"
else
  ORIGIN_HOST="docker.io"
  REST="$REF"
  if [[ "$REF" == */* ]]; then
    CANONICAL="docker.io/$REF"
  else
    CANONICAL="docker.io/library/$REF"
  fi
  BARE_REF="$REF"
fi

if [[ "$REST" == *:* && "${REST##*:}" != */* ]]; then
  : # tag present
else
  REST="$REST:latest"
fi

echo "[pull] target      : $REF"
echo "[pull] canonical   : $CANONICAL"
echo "[pull] origin host : $ORIGIN_HOST"
[[ -n "$PLATFORM" ]] && echo "[pull] platform    : $PLATFORM"

# --- Build candidate list ------------------------------------------------------
candidates=()

if [[ "$ORIGIN_HOST" == "docker.io" ]]; then
  if docker image inspect "$CANONICAL" >/dev/null 2>&1 || docker image inspect "$BARE_REF" >/dev/null 2>&1; then
    echo "[pull] already present locally, nothing to do"
    exit 0
  fi
  for m in $MIRRORS; do
    if [[ "$REST" == */* ]]; then
      candidates+=("$m/$REST")
    else
      candidates+=("$m/library/$REST")
    fi
  done
  candidates+=("$CANONICAL")
else
  if [[ -n "${NONHUB_PREFIXES:-}" ]]; then
    for p in $NONHUB_PREFIXES; do
      candidates+=("$p/$REST")
    done
  fi
  candidates+=("$CANONICAL")
fi

# --- Try each candidate --------------------------------------------------------
pulled=""
for cand in "${candidates[@]}"; do
  echo "[pull] trying: $cand"
  if [[ -n "$PLATFORM" ]]; then
    if docker pull --platform "$PLATFORM" "$cand"; then pulled="$cand"; break; fi
  else
    if docker pull "$cand"; then pulled="$cand"; break; fi
  fi
  echo "[pull]   -> failed, next"
done

if [[ -z "$pulled" ]]; then
  echo "[pull] ALL CANDIDATES FAILED for $REF" >&2
  echo "[pull] hints:" >&2
  echo "       - configure daemon.json registry-mirrors (setup_docker_cn.sh / setup_docker_cn.ps1)" >&2
  echo "       - for ghcr.io/quay.io/gcr.io/mcr: set NONHUB_PREFIXES to a verified mirror" >&2
  echo "       - last resort: mihomo_ctl.sh run docker pull $CANONICAL" >&2
  exit 1
fi

# --- Verify architecture -------------------------------------------------------
arch="$(docker image inspect --format '{{.Architecture}}' "$pulled" 2>/dev/null || echo unknown)"
echo "[pull] pulled arch: $arch"
if [[ -n "$PLATFORM" ]]; then
  want="${PLATFORM#linux/}"
  if [[ "$arch" != "unknown" && "$arch" != "$want" ]]; then
    echo "[pull] WARNING: expected $want but image arch is $arch" >&2
  fi
fi

# --- Re-tag back to canonical name so Compose stays portable -------------------
if [[ "$pulled" != "$CANONICAL" ]]; then
  docker tag "$pulled" "$CANONICAL"
  echo "[pull] tagged $pulled -> $CANONICAL"
fi
if [[ "$CANONICAL" != "$REF" ]]; then
  docker tag "$pulled" "$REF" 2>/dev/null || true
fi

echo "[pull] OK: $REF  (from $pulled)"
