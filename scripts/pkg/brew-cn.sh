#!/usr/bin/env bash
# =============================================================================
# brew-cn.sh — configure Homebrew (macOS / Linuxbrew) domestic mirrors
#              (JSON API + Bottles + Git remotes, Homebrew 4.x+ ready).
#
# Usage:
#   ./brew-cn.sh                        # write managed block into ~/.zprofile (macOS) or ~/.bashrc (Linux)
#   ./brew-cn.sh --print                # only print export lines (no file changes)
#   ./brew-cn.sh --rc ~/.zshrc          # write into a specific shell profile
#   BREW_MIRROR=tuna ./brew-cn.sh       # preset: ustc (default) | tuna | aliyun
# =============================================================================
set -euo pipefail

PRESET="${BREW_MIRROR:-ustc}"
PRINT_ONLY=0
CUSTOM_RC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print) PRINT_ONLY=1; shift ;;
    --rc) CUSTOM_RC="${2:-}"; shift 2 ;;
    --rc=*) CUSTOM_RC="${1#*=}"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$PRESET" in
  ustc)
    API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
    BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
    BREW_GIT="https://mirrors.ustc.edu.cn/brew.git"
    CORE_GIT="https://mirrors.ustc.edu.cn/homebrew-core.git"
    ;;
  tuna)
    API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
    BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
    BREW_GIT="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git"
    CORE_GIT="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-core.git"
    ;;
  aliyun)
    API_DOMAIN="https://mirrors.aliyun.com/homebrew-bottles/api"
    BOTTLE_DOMAIN="https://mirrors.aliyun.com/homebrew/homebrew-bottles"
    BREW_GIT="https://mirrors.aliyun.com/homebrew/brew.git"
    CORE_GIT="https://mirrors.aliyun.com/homebrew/homebrew-core.git"
    ;;
  *)
    echo "ERROR: unknown BREW_MIRROR preset '$PRESET' (expected ustc|tuna|aliyun)" >&2
    exit 2
    ;;
esac

PIP_URL="${HOMEBREW_PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple}"

BLOCK="$(cat <<EOF
# >>> cn-network-brew-begin (managed by cn-network/scripts/pkg/brew-cn.sh)
export HOMEBREW_API_DOMAIN="${API_DOMAIN}"
export HOMEBREW_BOTTLE_DOMAIN="${BOTTLE_DOMAIN}"
export HOMEBREW_BREW_GIT_REMOTE="${BREW_GIT}"
export HOMEBREW_CORE_GIT_REMOTE="${CORE_GIT}"
export HOMEBREW_PIP_INDEX_URL="${PIP_URL}"
export HOMEBREW_NO_AUTO_UPDATE=1
# <<< cn-network-brew-end
EOF
)"

if [[ "$PRINT_ONLY" -eq 1 ]]; then
  printf '%s\n' "$BLOCK"
  exit 0
fi

if [[ -n "$CUSTOM_RC" ]]; then
  RC_FILE="$CUSTOM_RC"
elif [[ "$(uname -s 2>/dev/null || echo Linux)" == Darwin* ]]; then
  RC_FILE="${HOME}/.zprofile"
else
  RC_FILE="${HOME}/.bashrc"
fi

if [[ -f "$RC_FILE" ]]; then
  [[ -f "${RC_FILE}.cn-bak" ]] || cp "$RC_FILE" "${RC_FILE}.cn-bak" 2>/dev/null || true
  TMP_RC="$(mktemp "${TMPDIR:-/tmp}/cn_brew_rc.XXXXXX")"
  awk '
    /# >>> cn-network-brew-begin/ { skip=1; next }
    /# <<< cn-network-brew-end/   { skip=0; next }
    !skip { print }
  ' "$RC_FILE" > "$TMP_RC"
  mv "$TMP_RC" "$RC_FILE"
fi

printf '\n%s\n' "$BLOCK" >> "$RC_FILE"
echo "[brew-cn] wrote Homebrew mirror exports (${PRESET}) -> ${RC_FILE}"
echo "[brew-cn] apply in current shell: source \"${RC_FILE}\""
