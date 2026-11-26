#!/usr/bin/env sh
# =============================================================================
# apk-cn.sh — switch Alpine APK repositories to a domestic mirror.
#
# Usage:
#   ./apk-cn.sh                      # mirrors.aliyun.com
#   APK_MIRROR=mirrors.ustc.edu.cn ./apk-cn.sh
#   ./apk-cn.sh --no-update
# =============================================================================
set -eu

APK_MIRROR="${APK_MIRROR:-mirrors.aliyun.com}"
DO_UPDATE=1
for a in "$@"; do
  case "$a" in
    --no-update) DO_UPDATE=0 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

if [ ! -f /etc/apk/repositories ]; then
  echo "No /etc/apk/repositories (not Alpine); nothing to do."
  exit 0
fi

[ -f /etc/apk/repositories.cn-bak ] || cp /etc/apk/repositories /etc/apk/repositories.cn-bak 2>/dev/null || true

sed -i "s#https\?://dl-cdn\.alpinelinux\.org#https://${APK_MIRROR}/alpine#g" /etc/apk/repositories
sed -i "s#/alpine/alpine#/alpine#g" /etc/apk/repositories

echo "[apk-cn] /etc/apk/repositories:"
cat /etc/apk/repositories

if [ "$DO_UPDATE" -eq 1 ]; then
  apk update
fi
echo "[apk-cn] done (mirror=${APK_MIRROR})"
