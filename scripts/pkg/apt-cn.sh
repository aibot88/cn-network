#!/usr/bin/env bash
# =============================================================================
# apt-cn.sh — switch Debian/Ubuntu APT to a domestic mirror (deb822 + legacy),
#             non-interactive, retry-tolerant, CA-bootstrap aware.
#
# Usage (inside Dockerfile RUN, or on a Debian/Ubuntu/WSL host):
#   ./apt-cn.sh                      # default mirrors.aliyun.com
#   APT_MIRROR=mirrors.ustc.edu.cn ./apt-cn.sh
#   ./apt-cn.sh --no-update          # only rewrite sources
# =============================================================================
set -euo pipefail

APT_MIRROR="${APT_MIRROR:-mirrors.aliyun.com}"
DO_UPDATE=1
for a in "$@"; do
  case "$a" in
    --no-update) DO_UPDATE=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

export DEBIAN_FRONTEND=noninteractive

if [ ! -d /etc/apt ]; then
  echo "No /etc/apt (not a Debian/Ubuntu environment); nothing to do."
  exit 0
fi

UPSTREAM_RE='deb\.debian\.org|security\.debian\.org|archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|ftp\.debian\.org'

changed=0

# --- deb822 (.sources) --------------------------------------------------------
shopt -s nullglob
for f in /etc/apt/sources.list.d/*.sources; do
  if grep -Eq "$UPSTREAM_RE" "$f"; then
    [ -f "${f}.cn-bak" ] || cp "$f" "${f}.cn-bak" 2>/dev/null || true
    sed -i -E "s#($UPSTREAM_RE)#${APT_MIRROR}#g" "$f"
    echo "[apt-cn] rewrote $f"
    changed=1
  fi
done

# --- legacy one-line ----------------------------------------------------------
if [ -f /etc/apt/sources.list ] && grep -Eq "$UPSTREAM_RE" /etc/apt/sources.list; then
  [ -f /etc/apt/sources.list.cn-bak ] || cp /etc/apt/sources.list /etc/apt/sources.list.cn-bak 2>/dev/null || true
  sed -i -E "s#($UPSTREAM_RE)#${APT_MIRROR}#g" /etc/apt/sources.list
  echo "[apt-cn] rewrote /etc/apt/sources.list"
  changed=1
fi

if [ "$changed" -eq 0 ]; then
  echo "[apt-cn] no upstream sources found (already switched?)."
fi

# --- CA bootstrap: minimal images may lack ca-certificates --------------------
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  echo "[apt-cn] bootstrapping ca-certificates (http fallback)"
  apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=20 update || true
  apt-get -y -o Acquire::Retries=5 --no-install-recommends install ca-certificates || true
fi

if [ "$DO_UPDATE" -eq 1 ]; then
  echo "[apt-cn] apt-get update (Retries=5)"
  apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 update
fi

echo "[apt-cn] done (mirror=${APT_MIRROR})"
