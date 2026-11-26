#!/usr/bin/env bash
# =============================================================================
# retag_mirrored_images.sh — re-tag already-pulled mirrored images back to their
#                            canonical names, so Compose files can use clean
#                            names (`mysql:8.0`) and stay portable.
#
# Pure local operation: ZERO network, ZERO registry access.
# Works across Linux, macOS, WSL2, and Windows (Git Bash).
#
# Usage:
#   bash scripts/registry/retag_mirrored_images.sh
#   bash scripts/registry/retag_mirrored_images.sh --dry-run
# =============================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1

DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

MIRROR_HOSTS="${MIRRORS:-docker.1ms.run docker.1panel.live docker.m.daocloud.io}"

created=0
skipped=0
examined=0

echo "Scanning local images for mirror-prefixed names..."
IMG_LIST="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -vE '^<none>' | sort -u || true)"

while IFS= read -r full; do
  full="${full%$'\r'}"
  [[ -z "$full" ]] && continue
  examined=$((examined+1))

  canonical=""
  for host in $MIRROR_HOSTS; do
    host="${host#https://}"
    host="${host#http://}"
    case "$full" in
      "${host}/library/"*)
        canonical="${full#${host}/library/}"
        break
        ;;
      "${host}/"*)
        canonical="${full#${host}/}"
        break
        ;;
    esac
  done

  [[ -z "$canonical" ]] && continue

  case "$canonical" in
    *":<none>"|"<none>:"*) skipped=$((skipped+1)); continue ;;
  esac

  if docker image inspect "$canonical" >/dev/null 2>&1; then
    skipped=$((skipped+1))
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry ] $full  ->  $canonical"
    continue
  fi

  if docker tag "$full" "$canonical" 2>/dev/null; then
    echo "[tag ] $full  ->  $canonical"
    created=$((created+1))
  else
    echo "[FAIL] could not tag $full -> $canonical" >&2
  fi
done <<EOF
$IMG_LIST
EOF

echo
echo "=============================================================="
echo " examined=$examined  newly_tagged=$created  already_present=$skipped"
echo "=============================================================="
