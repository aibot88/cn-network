#!/usr/bin/env bash
# =============================================================================
# npm-cn.sh — npm / yarn / pnpm registry + ALL common binary-download mirrors
#             (macOS / Linux / WSL2 / Windows Git Bash).
#
# IMPORTANT: writes ~/.npmrc (and ./.npmrc with --project) DIRECTLY instead of
#   `npm config set disturl ...`, because npm v9+ rejects unknown option names
#   like `disturl` / `electron_mirror` via CLI while honoring them in `.npmrc`.
#
# Usage:
#   ./npm-cn.sh              # write ~/.npmrc
#   ./npm-cn.sh --project    # also write ./.npmrc for the current project
# =============================================================================
set -euo pipefail

REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
BIN_HOST="${NPM_BIN_HOST:-https://npmmirror.com/mirrors}"
PROJECT_MODE=0
[ "${1:-}" = "--project" ] && PROJECT_MODE=1

echo "[npm-cn] registry = $REGISTRY"
echo "[npm-cn] binaries = $BIN_HOST"

write_npmrc() {
  local target="$1"
  if [ -f "$target" ]; then
    [ -f "${target}.cn-bak" ] || cp "$target" "${target}.cn-bak" 2>/dev/null || true
    local tmp_rc
    tmp_rc="$(mktemp "${TMPDIR:-/tmp}/cn_npmrc.XXXXXX")"
    # Strip our managed block and any stray duplicate keys portably (BSD & GNU awk)
    awk '
      /# >>> cn-network-begin/ { skip=1; next }
      /# <<< cn-network-end/   { skip=0; next }
      !skip && $0 !~ /^[[:space:]]*(registry|disturl|electron_mirror|sass_binary_site)[[:space:]]*=/ { print }
    ' "$target" > "$tmp_rc"
    mv "$tmp_rc" "$target"
  fi
  cat >> "$target" <<EOF
# >>> cn-network-begin (managed by cn-network/scripts/pkg/npm-cn.sh)
registry=${REGISTRY}
disturl=${BIN_HOST}/node
electron_mirror=${BIN_HOST}/electron/
electron_builder_binaries_mirror=${BIN_HOST}/electron-builder-binaries/
sass_binary_site=${BIN_HOST}/node-sass
sharp_binary_host=${BIN_HOST}/sharp
sharp_libvips_binary_host=${BIN_HOST}/sharp-libvips
puppeteer_download_host=${BIN_HOST}
playwright_download_host=${BIN_HOST}/playwright
chromedriver_cdnurl=${BIN_HOST}/chromedriver
operadriver_cdnurl=${BIN_HOST}/operadriver
phantomjs_cdnurl=${BIN_HOST}/phantomjs
node_sqlite3_binary_host_mirror=${BIN_HOST}/node-sqlite3
profiler_binary_host_mirror=${BIN_HOST}/node-inspector
fund=false
audit=false
# <<< cn-network-end
EOF
  echo "[npm-cn] wrote $target"
}

# --- Step 1: let yarn / pnpm normalise their own configs FIRST ----------------
if command -v yarn >/dev/null 2>&1; then
  yarn config set registry "$REGISTRY" >/dev/null 2>&1 || true
  echo "[npm-cn] yarn registry set (best-effort)"
fi
if command -v pnpm >/dev/null 2>&1; then
  pnpm config set registry "$REGISTRY" >/dev/null 2>&1 || true
  echo "[npm-cn] pnpm registry set (best-effort)"
fi

for f in ".yarnrc.yml" "${HOME}/.yarnrc.yml"; do
  [ -f "$f" ] || continue
  grep -q 'npmRegistryServer' "$f" 2>/dev/null || echo "npmRegistryServer: \"${REGISTRY}\"" >> "$f"
  grep -q 'enableTelemetry' "$f" 2>/dev/null || echo "enableTelemetry: false" >> "$f"
  echo "[npm-cn] updated $f (yarn berry)"
done

# --- Step 2: write our managed npmrc block LAST so pnpm doesn't strip comments
write_npmrc "${HOME}/.npmrc"
[ "$PROJECT_MODE" -eq 1 ] && write_npmrc ".npmrc"

cat <<EOF

# --- copy into Dockerfile (ENV) ---
ENV NPM_CONFIG_REGISTRY=${REGISTRY} \\
    npm_config_disturl=${BIN_HOST}/node \\
    ELECTRON_MIRROR=${BIN_HOST}/electron/ \\
    ELECTRON_BUILDER_BINARIES_MIRROR=${BIN_HOST}/electron-builder-binaries/ \\
    SASS_BINARY_SITE=${BIN_HOST}/node-sass \\
    PUPPETEER_DOWNLOAD_HOST=${BIN_HOST} \\
    PLAYWRIGHT_DOWNLOAD_HOST=${BIN_HOST}/playwright \\
    SHARP_BINARY_HOST=${BIN_HOST}/sharp \\
    NEXT_TELEMETRY_DISABLED=1 \\
    DISABLE_OPENCOLLECTIVE=1 \\
    NPM_CONFIG_FUND=false \\
    NPM_CONFIG_AUDIT=false

# install with:
#   npm ci --no-audit --no-fund
EOF

echo "[npm-cn] done"
