#!/usr/bin/env bash
# =============================================================================
# setup_docker_cn.sh — safely merge Mainland-China DNS & registry-mirrors into
# Docker's daemon.json across Linux, macOS, WSL2, and Windows (Git Bash),
# preserving every existing daemon setting (runtimes, data-root, builder, ...).
#
# Usage:
#   # Linux (rootful /etc/docker/daemon.json):
#   sudo bash scripts/setup_docker_cn.sh --dry-run
#   sudo bash scripts/setup_docker_cn.sh
#
#   # macOS / Windows Git Bash / WSL2 Docker Desktop (~/.docker/daemon.json):
#   bash scripts/setup_docker_cn.sh --dry-run
#   bash scripts/setup_docker_cn.sh
#   bash scripts/setup_docker_cn.sh --restart
#
#   # Custom mirrors / DNS / target file:
#   MIRRORS="https://docker.1ms.run https://docker.m.ixdev.cn" bash scripts/setup_docker_cn.sh
#   DNS_SERVERS="223.5.5.5 119.29.29.29" bash scripts/setup_docker_cn.sh --file /path/to/daemon.json
# =============================================================================
set -euo pipefail

DRY=0
DO_RESTART="auto"
CUSTOM_FILE="${DAEMON_JSON:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --no-restart) DO_RESTART="no"; shift ;;
    --restart) DO_RESTART="yes"; shift ;;
    --file) CUSTOM_FILE="${2:-}"; shift 2 ;;
    --file=*) CUSTOM_FILE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

MIRRORS="${MIRRORS:-https://docker.1ms.run https://docker.1panel.live https://docker.m.daocloud.io}"
DNS_SERVERS="${DNS_SERVERS:-223.5.5.5 119.29.29.29}"

UNAME_S="$(uname -s 2>/dev/null || echo Linux)"
PLATFORM="linux"
case "$UNAME_S" in
  Darwin*) PLATFORM="macos" ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM="windows-gitbash" ;;
  Linux*)
    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; then
      PLATFORM="wsl"
    fi
    ;;
esac

detect_daemon_json() {
  if [[ -n "$CUSTOM_FILE" ]]; then
    echo "$CUSTOM_FILE"
    return
  fi
  case "$PLATFORM" in
    macos)
      if command -v orb >/dev/null 2>&1 && [[ -f "$HOME/.orbstack/config/docker.json" && ! -f "$HOME/.docker/daemon.json" ]]; then
        echo "$HOME/.orbstack/config/docker.json"
      else
        echo "$HOME/.docker/daemon.json"
      fi
      ;;
    windows-gitbash)
      echo "$HOME/.docker/daemon.json"
      ;;
    wsl)
      # If native dockerd runs inside WSL or /etc/docker/daemon.json exists, use Linux path;
      # otherwise target Docker Desktop's Windows-side ~/.docker/daemon.json if present.
      if [[ -f /etc/docker/daemon.json ]] || pgrep -x dockerd >/dev/null 2>&1; then
        echo "/etc/docker/daemon.json"
      elif command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
        local win_profile
        win_profile="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n' || true)"
        if [[ -n "$win_profile" ]]; then
          local wsl_home
          wsl_home="$(wslpath "$win_profile" 2>/dev/null || true)"
          if [[ -n "$wsl_home" && -d "$wsl_home/.docker" ]]; then
            echo "$wsl_home/.docker/daemon.json"
            return
          fi
        fi
        echo "/etc/docker/daemon.json"
      else
        echo "/etc/docker/daemon.json"
      fi
      ;;
    *)
      if [[ "${EUID:-$(id -u)}" -ne 0 ]] && { [[ "${DOCKER_HOST:-}" == *"/user/"* ]] || [[ -f "$HOME/.config/docker/daemon.json" ]]; }; then
        echo "$HOME/.config/docker/daemon.json"
      else
        echo "/etc/docker/daemon.json"
      fi
      ;;
  esac
}

find_python() {
  local cand
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import json,sys" >/dev/null 2>&1; then
      echo "$cand"
      return 0
    fi
  done
  if command -v py >/dev/null 2>&1 && py -3 -c "import json,sys" >/dev/null 2>&1; then
    echo "py -3"
    return 0
  fi
  return 1
}

to_native_path() {
  local p="$1"
  if [[ "$PLATFORM" == "windows-gitbash" ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p"
  else
    echo "$p"
  fi
}

TARGET_JSON="$(detect_daemon_json)"
TARGET_DIR="$(dirname "$TARGET_JSON")"
TMP_BASE="${TMPDIR:-/tmp}"
mkdir -p "$TMP_BASE"
TMP_JSON="$(mktemp "${TMP_BASE%/}/cn_daemon.XXXXXX")"
BACKUP_JSON="${TMP_BASE%/}/daemon.json.cn-bak.$(date +%Y%m%d_%H%M%S)"
trap 'rm -f "$TMP_JSON"' EXIT

if [[ $DRY -eq 0 ]]; then
  # Check write permission before touching anything
  if [[ -f "$TARGET_JSON" && ! -w "$TARGET_JSON" ]] || [[ ! -d "$TARGET_DIR" && ! -w "$(dirname "$TARGET_DIR")" ]] || [[ -d "$TARGET_DIR" && ! -w "$TARGET_DIR" ]]; then
    echo "ERROR: No write permission for ${TARGET_JSON}. Run with sudo (or pass --dry-run):" >&2
    echo "       sudo bash $0" >&2
    exit 1
  fi
fi

PY_CMD="$(find_python || true)"
if [[ -z "$PY_CMD" ]]; then
  echo "ERROR: Python 3 is required to safely parse and merge JSON (on Windows without Python, use setup_docker_cn.ps1)." >&2
  exit 1
fi

SRC_NATIVE="$(to_native_path "$TARGET_JSON")"
DST_NATIVE="$(to_native_path "$TMP_JSON")"

# shellcheck disable=SC2086
$PY_CMD - "$SRC_NATIVE" "$DST_NATIVE" "$MIRRORS" "$DNS_SERVERS" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
desired_mirrors = sys.argv[3].split()
desired_dns = sys.argv[4].split()

data = {}
if src.is_file():
    raw = src.read_text(encoding="utf-8-sig").strip()
    if raw:
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise SystemExit("Expected JSON object in %s, got %s" % (src, type(data).__name__))

existing_dns = [str(x) for x in (data.get("dns") or [])]
for ip in desired_dns:
    if ip not in existing_dns:
        existing_dns.append(ip)
data["dns"] = existing_dns

existing_mirrors = [str(x) for x in (data.get("registry-mirrors") or [])]
for m in desired_mirrors:
    if m not in existing_mirrors:
        existing_mirrors.append(m)
data["registry-mirrors"] = existing_mirrors

with open(str(dst), "w", encoding="utf-8", newline="\n") as fh:
    fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY

# Validate JSON strictly before touching target daemon.json
# shellcheck disable=SC2086
$PY_CMD -m json.tool "$DST_NATIVE" > /dev/null

if [[ $DRY -eq 1 ]]; then
  echo "[dry-run] platform=${PLATFORM} | target=${TARGET_JSON}"
  echo "[dry-run] merged daemon.json would be:"
  cat "$TMP_JSON"
  exit 0
fi

if [[ -f "$TARGET_JSON" ]]; then
  cp "$TARGET_JSON" "$BACKUP_JSON"
  echo "Backed up existing ${TARGET_JSON} -> ${BACKUP_JSON}"
fi

mkdir -p "$TARGET_DIR"
cp "$TMP_JSON" "$TARGET_JSON"
chmod 0644 "$TARGET_JSON" 2>/dev/null || true
echo "Updated ${TARGET_JSON} (platform=${PLATFORM}):"
cat "$TARGET_JSON"

if [[ "$DO_RESTART" == "no" ]]; then
  echo "Skipped Docker restart (--no-restart)."
  exit 0
fi

case "$PLATFORM" in
  macos)
    if [[ "$DO_RESTART" == "yes" ]]; then
      if command -v orb >/dev/null 2>&1 && orb status >/dev/null 2>&1; then
        orb restart docker
      elif command -v colima >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
        colima restart
      else
        osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
        sleep 2
        open -a Docker
        echo "Restarting Docker Desktop on macOS (allow ~15-30s for daemon readiness)..."
      fi
    else
      echo "NOTE: Restart Docker Desktop / OrbStack / Colima to apply changes (or re-run with --restart):"
      echo "      macOS Docker Desktop : osascript -e 'quit app \"Docker\"' && open -a Docker"
      echo "      OrbStack             : orb restart docker"
    fi
    ;;
  windows-gitbash|wsl)
    if [[ "$TARGET_JSON" == "/etc/docker/daemon.json" ]]; then
      if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl restart docker
      elif command -v service >/dev/null 2>&1; then
        service docker restart
      fi
    else
      echo "NOTE: Restart Docker Desktop on Windows to apply updated ${TARGET_JSON}."
      echo "      PowerShell: Restart-Service com.docker.service (or restart via Docker Desktop tray icon)"
    fi
    ;;
  *)
    if [[ "$TARGET_JSON" == *"/.config/docker/daemon.json" ]]; then
      systemctl --user daemon-reload 2>/dev/null || true
      systemctl --user restart docker 2>/dev/null || echo "NOTE: Restart rootless docker daemon to apply."
    elif command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
      systemctl daemon-reload
      systemctl restart docker
    elif command -v service >/dev/null 2>&1; then
      service docker restart
    else
      echo "NOTE: No systemd/service manager detected; restart dockerd manually to apply."
    fi
    ;;
esac

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker info --format 'Docker Server Version: {{.ServerVersion}} | Registry Mirrors: {{.RegistryConfig.Mirrors}}' || true
fi
