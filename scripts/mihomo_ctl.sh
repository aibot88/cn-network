#!/usr/bin/env bash
# =============================================================================
# mihomo_ctl.sh — on-demand mihomo proxy manager (kept stopped by default).
# Works across Linux, macOS, WSL2, and Windows (Git Bash).
#
# Usage:
#   MIHOMO_DIR=/path/to/proxy ./mihomo_ctl.sh {start|stop|status|run <cmd...>}
# =============================================================================
set -euo pipefail

MIHOMO_DIR="${MIHOMO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mihomo}"
if [[ -z "${MIHOMO_BIN:-}" ]]; then
  if [[ -x "${MIHOMO_DIR}/mihomo.exe" ]]; then
    BIN="${MIHOMO_DIR}/mihomo.exe"
  else
    BIN="${MIHOMO_DIR}/mihomo"
  fi
else
  BIN="${MIHOMO_BIN}"
fi
CFG="${MIHOMO_CONFIG:-${MIHOMO_DIR}/config.yaml}"
PID_FILE="${MIHOMO_DIR}/mihomo.pid"
LOG_FILE="${MIHOMO_DIR}/mihomo.log"
PROXY_ADDR="${MIHOMO_PROXY_ADDR:-http://127.0.0.1:7890}"

# Extract host and port from PROXY_ADDR (e.g. http://127.0.0.1:7890 -> 127.0.0.1 & 7890)
PROXY_HOSTPORT="${PROXY_ADDR#*://}"
PROXY_HOSTPORT="${PROXY_HOSTPORT%%/*}"
PROXY_HOST="${PROXY_HOSTPORT%:*}"
PROXY_PORT="${PROXY_HOSTPORT##*:}"
[[ -z "$PROXY_HOST" ]] && PROXY_HOST="127.0.0.1"
[[ -z "$PROXY_PORT" || "$PROXY_PORT" == "$PROXY_HOST" ]] && PROXY_PORT="7890"

probe_tcp() {
  local host="$1" port="$2"
  local cand
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
      "$cand" -c "import socket,sys; s=socket.socket(); s.settimeout(0.5); s.connect((sys.argv[1], int(sys.argv[2]))); s.close()" "$host" "$port" 2>/dev/null
      return $?
    fi
  done
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 1 "$host" "$port" >/dev/null 2>&1
    return $?
  fi
  (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1
}

is_running() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
    rm -f "${PID_FILE}"
  fi
  return 1
}

cmd_start() {
  if is_running; then
    echo "mihomo already running (pid=$(cat "${PID_FILE}"))"
    return 0
  fi
  if [[ ! -x "${BIN}" && ! -f "${BIN}" ]]; then
    echo "ERROR: mihomo binary not found: ${BIN}" >&2
    exit 1
  fi
  if [[ ! -f "${CFG}" ]]; then
    echo "ERROR: mihomo config not found: ${CFG}" >&2
    exit 1
  fi
  if [[ ! -f "${MIHOMO_DIR}/Country.mmdb" ]]; then
    echo "WARN: ${MIHOMO_DIR}/Country.mmdb missing; rule mode may block waiting to download GeoIP DB." >&2
  fi
  nohup "${BIN}" -d "${MIHOMO_DIR}" -f "${CFG}" > "${LOG_FILE}" 2>&1 &
  local pid=$!
  echo "${pid}" > "${PID_FILE}"
  local i=0
  while [[ $i -lt 20 ]]; do
    if probe_tcp "$PROXY_HOST" "$PROXY_PORT"; then
      echo "mihomo started (pid=${pid}, proxy=${PROXY_ADDR})"
      return 0
    fi
    sleep 0.5
    i=$((i+1))
  done
  echo "ERROR: mihomo failed to bind ${PROXY_HOST}:${PROXY_PORT}; check ${LOG_FILE}" >&2
  cmd_stop || true
  exit 1
}

cmd_stop() {
  if is_running; then
    local pid
    pid="$(cat "${PID_FILE}")"
    kill "${pid}" 2>/dev/null || true
    local i=0
    while [[ $i -lt 10 ]]; do
      if ! kill -0 "${pid}" 2>/dev/null; then
        break
      fi
      sleep 0.3
      i=$((i+1))
    done
    kill -9 "${pid}" 2>/dev/null || true
    rm -f "${PID_FILE}"
    echo "mihomo stopped"
  else
    rm -f "${PID_FILE}"
    echo "mihomo stopped"
  fi
}

cmd_status() {
  if is_running; then
    echo "mihomo running (pid=$(cat "${PID_FILE}"), proxy=${PROXY_ADDR})"
  else
    echo "mihomo stopped"
  fi
}

cmd_run() {
  if [[ "$#" -lt 1 ]]; then
    echo "Usage: $0 run <command...>" >&2
    exit 2
  fi
  local was_running=0
  if is_running; then
    was_running=1
  else
    cmd_start
  fi
  local rc=0
  local np="127.0.0.1,localhost,::1,host.docker.internal"
  HTTP_PROXY="${PROXY_ADDR}" \
  HTTPS_PROXY="${PROXY_ADDR}" \
  http_proxy="${PROXY_ADDR}" \
  https_proxy="${PROXY_ADDR}" \
  NO_PROXY="${np}" \
  no_proxy="${np}" \
  "$@" || rc=$?
  if [[ "${was_running}" -eq 0 ]]; then
    cmd_stop
  fi
  return "${rc}"
}

case "${1:-status}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  run) shift; cmd_run "$@" ;;
  *)
    echo "Usage: $0 {start|stop|status|run <command...>}" >&2
    exit 2
    ;;
esac
