#!/usr/bin/env bash
# =============================================================================
# gem-cn.sh — RubyGems / Bundler domestic mirror.
#
# Note: gems declared as `gem 'x', git: 'https://github.com/...'` still need the
#       Git proxy (see git-cn.sh). A rubygems mirror only covers released gems.
# =============================================================================
set -euo pipefail

GEM_MIRROR="${GEM_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/rubygems}"
RUBYGEMS_SOURCE="${RUBYGEMS_SOURCE:-https://mirrors.aliyun.com/rubygems/}"

if command -v gem >/dev/null 2>&1; then
  gem sources --add "$RUBYGEMS_SOURCE" --remove https://rubygems.org/ 2>/dev/null || true
  echo "[gem-cn] gem sources:"
  gem sources -l || true
fi

if command -v bundle >/dev/null 2>&1; then
  bundle config mirror.https://rubygems.org "$GEM_MIRROR" 2>/dev/null || true
  echo "[gem-cn] bundle mirror -> $GEM_MIRROR"
fi

cat <<EOF

# --- copy into Dockerfile (ENV / RUN) ---
# RUN gem sources --add ${RUBYGEMS_SOURCE} --remove https://rubygems.org/ && \\
#     bundle config mirror.https://rubygems.org ${GEM_MIRROR} && \\
#     bundle install --jobs 4 --retry 3
EOF
echo "[gem-cn] done"
