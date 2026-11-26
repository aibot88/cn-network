#!/usr/bin/env bash
# =============================================================================
# git-cn.sh — make git usable for github.com-hosted sources without a
#             system-wide proxy (macOS / Linux / WSL2 / Windows Git Bash).
#
# Usage:
#   ./git-cn.sh gh-clone  https://github.com/org/repo.git  [dest]
#   ./git-cn.sh gh-tar    https://github.com/org/repo/archive/v1.2.3.tar.gz  [out]
#   ./git-cn.sh lfs-skip                       # print GIT_LFS_SKIP_SMUDGE=1 hint
#   ./git-cn.sh tune                           # http.postBuffer / lowSpeed
# =============================================================================
set -uo pipefail

GH_PROXY_PREFIX="${GH_PROXY_PREFIX:-https://ghfast.top/}"
LFS_ENV_HINT='export GIT_LFS_SKIP_SMUDGE=1   # PowerShell: $env:GIT_LFS_SKIP_SMUDGE="1"'

usage() { sed -n '2,11p' "$0"; }

tune() {
  git config --global http.postBuffer 524288000
  git config --global http.lowSpeedLimit 1000
  git config --global http.lowSpeedTime 60
  git config --global core.compression 0
  git config --global http.version HTTP/1.1
  echo "[git-cn] tuned global git http settings (postBuffer=500MB, HTTP/1.1)"
}

gh_clone() {
  local url="${1:-}"; local dest="${2:-}"
  [ -n "$url" ] || { usage; exit 2; }
  case "$url" in
    https://github.com/*)
      local proxied="${GH_PROXY_PREFIX}${url}"
      echo "[git-cn] try direct first (fast if reachable): git clone $url"
      if git clone --depth 1 "$url" ${dest:+"$dest"} 2>/dev/null; then
        echo "[git-cn] direct clone OK"; return 0
      fi
      echo "[git-cn] direct failed, retry via prefix: $proxied"
      git clone --depth 1 "$proxied" ${dest:+"$dest"} && return 0
      echo "[git-cn] prefix clone failed. Last resort:" >&2
      echo "          mihomo_ctl.sh run git clone $url ${dest:-}" >&2
      echo "          (Windows PowerShell: .\\scripts\\mihomo_ctl.ps1 run git clone $url ${dest:-})" >&2
      return 1
      ;;
    *)
      echo "[git-cn] non-github URL, plain clone: $url"
      git clone --depth 1 "$url" ${dest:+"$dest"}
      ;;
  esac
}

gh_tar() {
  local url="${1:-}"; local out="${2:-}"
  [ -n "$url" ] || { usage; exit 2; }
  local proxied="${GH_PROXY_PREFIX}${url}"
  echo "[git-cn] download via prefix: $proxied" >&2
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$out" ]; then
      curl -fL --retry 5 --retry-delay 2 -o "$out" "$proxied"
    else
      curl -fL --retry 5 --retry-delay 2 "$proxied"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "$out" ]; then
      wget -O "$out" "$proxied"
    else
      wget -qO- "$proxied"
    fi
  else
    echo "[git-cn] need curl or wget" >&2; return 2
  fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  gh-clone) gh_clone "${1:-}" "${2:-}" ;;
  gh-tar)   gh_tar   "${1:-}" "${2:-}" ;;
  lfs-skip) echo "$LFS_ENV_HINT" ;;
  tune)     tune ;;
  -h|--help|"") usage ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
esac
