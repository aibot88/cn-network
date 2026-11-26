#!/usr/bin/env bash
# =============================================================================
# go-cn.sh — Go module proxy + checksum DB mirror (macOS / Linux / Windows).
#
# Note on GOENV file locations (`go env GOENV`):
#   * macOS   : ~/Library/Application Support/go/env
#   * Linux   : ~/.config/go/env
#   * Windows : %APPDATA%\go\env
#   To avoid modifying user-level GOENV, pass --print for Dockerfile/shell lines.
#
# Usage:
#   ./go-cn.sh            # apply with `go env -w` (global, idempotent)
#   ./go-cn.sh --print    # only print Dockerfile ENV lines (no side effects)
# =============================================================================
set -euo pipefail

GOPROXY_CN="${GOPROXY_CN:-https://goproxy.cn,direct}"
GOSUMDB_CN="${GOSUMDB_CN:-sum.golang.google.cn}"
PRINT_ONLY=0
[ "${1:-}" = "--print" ] && PRINT_ONLY=1

if [ "$PRINT_ONLY" -eq 0 ]; then
  if ! command -v go >/dev/null 2>&1; then
    echo "[go-cn] go not found; printing hints only" >&2
  else
    go env -w GOPROXY="$GOPROXY_CN"
    go env -w GOSUMDB="$GOSUMDB_CN"
    go env -w GOFLAGS="-mod=mod"
    go env -w GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
    echo "[go-cn] configured (file: $(go env GOENV))"
    go env GOPROXY GOSUMDB GOFLAGS GOTOOLCHAIN
  fi
fi

cat <<EOF

# --- copy into Dockerfile (ENV) ---
ENV GOPROXY=${GOPROXY_CN} \\
    GOSUMDB=${GOSUMDB_CN} \\
    GOFLAGS=-mod=mod \\
    GOTOOLCHAIN=local
EOF
echo "[go-cn] done"
