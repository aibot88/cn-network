#!/usr/bin/env bash
# =============================================================================
# composer-cn.sh — PHP Composer mirror (packagist metadata + GitHub dist proxy).
#
# Why it matters:
#   Default `composer install` hits repo.packagist.org (metadata) and then
#   api.github.com / codeload.github.com for dist zips. Both are frequently
#   blocked or rate-limited. The Aliyun composer mirror proxies BOTH, so
#   `--prefer-dist` works without any GitHub access.
#
# Usage:
#   ./composer-cn.sh                  # global config
#   ./composer-cn.sh --project        # also write ./composer.json repositories? (no)
# =============================================================================
set -euo pipefail

COMPOSER_MIRROR="${COMPOSER_MIRROR:-https://mirrors.aliyun.com/composer/}"

if ! command -v composer >/dev/null 2>&1; then
  echo "[composer-cn] composer not found; nothing to do" >&2
  exit 0
fi

export COMPOSER_ALLOW_SUPERUSER=1
composer config -g repos.packagist composer "$COMPOSER_MIRROR"
composer config -g process-timeout 900
composer config -g secure-http true

echo "[composer-cn] global repo.packagist -> $COMPOSER_MIRROR"

cat <<EOF

# --- copy into Dockerfile (ENV) ---
ENV COMPOSER_ALLOW_SUPERUSER=1 \\
    COMPOSER_PROCESS_TIMEOUT=900 \\
    COMPOSER_NO_INTERACTION=1

# install with:
#   composer install --no-dev --prefer-dist --no-interaction --no-progress --no-scripts
EOF
echo "[composer-cn] done"
