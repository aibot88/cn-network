#!/usr/bin/env bash
# =============================================================================
# pip-cn.sh — configure pip / uv / poetry + HuggingFace domestic mirrors
#             across Linux, macOS, WSL2, and Windows (Git Bash).
#
# Usage:
#   ./pip-cn.sh                 # global pip config + Dockerfile/shell hints
#   ./pip-cn.sh --project       # also write ./pip.conf
# =============================================================================
set -euo pipefail

INDEX="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
TRUSTED="${PIP_TRUSTED_HOST:-mirrors.aliyun.com}"
PROJECT_MODE=0
[ "${1:-}" = "--project" ] && PROJECT_MODE=1

echo "[pip-cn] index = $INDEX"

write_pip_ini() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    [ -f "${target}.cn-bak" ] || cp "$target" "${target}.cn-bak" 2>/dev/null || true
  fi
  cat > "$target" <<EOF
[global]
index-url = ${INDEX}
trusted-host = ${TRUSTED}
timeout = 60
retries = 5
EOF
  echo "[pip-cn] wrote $target"
}

PIP_BIN=""
for cand in pip3 pip; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then
    PIP_BIN="$cand"
    break
  fi
done

if [ -n "$PIP_BIN" ]; then
  "$PIP_BIN" config set global.index-url "$INDEX"
  "$PIP_BIN" config set global.trusted-host "$TRUSTED"
  "$PIP_BIN" config set global.timeout 60
  "$PIP_BIN" config set global.retries 5
  echo "[pip-cn] pip configured via $PIP_BIN"
else
  # Write OS-standard global pip config directly (works even in uv-only setups)
  UNAME_S="$(uname -s 2>/dev/null || echo Linux)"
  case "$UNAME_S" in
    MINGW*|MSYS*|CYGWIN*)
      APPDATA_DIR="${APPDATA:-${HOME}/AppData/Roaming}"
      write_pip_ini "${APPDATA_DIR}/pip/pip.ini"
      ;;
    Darwin*)
      write_pip_ini "${HOME}/.config/pip/pip.conf"
      ;;
    *)
      write_pip_ini "${HOME}/.config/pip/pip.conf"
      ;;
  esac
fi

if [ "$PROJECT_MODE" -eq 1 ]; then
  write_pip_ini "pip.conf"
fi

cat <<EOF

# --- copy into Dockerfile (ENV) ---
ENV PIP_INDEX_URL=${INDEX} \\
    PIP_TRUSTED_HOST=${TRUSTED} \\
    PIP_DISABLE_PIP_VERSION_CHECK=1 \\
    PIP_DEFAULT_TIMEOUT=60 \\
    UV_INDEX_URL=${INDEX} \\
    POETRY_REPOSITORIES_CN_URL=${INDEX} \\
    HF_ENDPOINT=https://hf-mirror.com \\
    HF_HUB_DOWNLOAD_TIMEOUT=60

# --- poetry: add a source (run once) ---
# poetry source add --priority=primary cn ${INDEX}
EOF

echo "[pip-cn] done"
