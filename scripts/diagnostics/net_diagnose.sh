#!/usr/bin/env bash
# =============================================================================
# net_diagnose.sh — one-shot Mainland-China network health check
#                   (Linux / macOS / WSL2 / Windows Git Bash).
#
# Covers every layer a build/container/dev pipeline depends on:
#   host DNS · host egress · Docker daemon config · registry mirrors ·
#   BuildKit DNS · container DNS · container egress · IPv6 · MTU ·
#   clock skew · language package indexes · git/GitHub · LLM API endpoint
#
# Usage:
#   bash scripts/diagnostics/net_diagnose.sh
#   bash scripts/diagnostics/net_diagnose.sh --json   (machine readable)
#   bash scripts/diagnostics/net_diagnose.sh --quick  (skip slow checks)
#
# Exit code: 0 = no FAIL, 1 = at least one FAIL
# =============================================================================
set -uo pipefail

# Prevent Git Bash / MSYS2 on Windows from mangling container paths like /dev/null
export MSYS_NO_PATHCONV=1

JSON=0
QUICK=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --quick) QUICK=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  esac
done

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

FAILS=0
WARNS=0
ROWS=()

pass() { ROWS+=("PASS|$1|$2"); [[ $JSON -eq 0 ]] && printf '  \033[32mPASS\033[0m %-32s %s\n' "$1" "$2"; }
warn() { WARNS=$((WARNS+1)); ROWS+=("WARN|$1|$2"); [[ $JSON -eq 0 ]] && printf '  \033[33mWARN\033[0m %-32s %s\n' "$1" "$2"; }
fail() { FAILS=$((FAILS+1)); ROWS+=("FAIL|$1|$2"); [[ $JSON -eq 0 ]] && printf '  \033[31mFAIL\033[0m %-32s %s\n' "$1" "$2"; }
info() { ROWS+=("INFO|$1|$2"); [[ $JSON -eq 0 ]] && printf '  \033[36mINFO\033[0m %-32s %s\n' "$1" "$2"; }
hdr()  { [[ $JSON -eq 0 ]] && printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

find_python() {
  local cand
  for cand in python3 python; do
    if have "$cand" && "$cand" -c "import sys" >/dev/null 2>&1; then
      echo "$cand"
      return 0
    fi
  done
  if have py && py -3 -c "import sys" >/dev/null 2>&1; then
    echo "py -3"
    return 0
  fi
  return 1
}

PY_CMD="$(find_python || true)"

to_native_path() {
  local p="$1"
  if [[ "$PLATFORM" == "windows-gitbash" ]] && have cygpath; then
    cygpath -w "$p"
  else
    echo "$p"
  fi
}

info "host:platform" "$PLATFORM ($UNAME_S)"

# ------------------------------------------------------------------ 1. host DNS
hdr "1. Host DNS"
resolve_host() {
  local h="$1" out=""
  if have getent; then
    out="$(getent hosts "$h" 2>/dev/null | head -n1 || true)"
    [[ -n "$out" ]] && { echo "$out"; return 0; }
  fi
  if have dscacheutil; then
    out="$(dscacheutil -q host -a name "$h" 2>/dev/null | awk '/ip_address:|ipv6_address:/{print $2; exit}' || true)"
    [[ -n "$out" ]] && { echo "$out (dscacheutil)"; return 0; }
  fi
  if [[ -n "$PY_CMD" ]]; then
    # shellcheck disable=SC2086
    out="$($PY_CMD -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$h" 2>/dev/null || true)"
    [[ -n "$out" ]] && { echo "$out (python)"; return 0; }
  fi
  if have nslookup; then
    out="$(nslookup "$h" 2>/dev/null | awk '/^Address: / && !/#/{print $2; exit}' || true)"
    [[ -n "$out" ]] && { echo "$out (nslookup)"; return 0; }
  fi
  return 1
}

for host in mirrors.aliyun.com registry-1.docker.io github.com; do
  if out="$(resolve_host "$host")"; then
    pass "dns:$host" "$out"
  else
    if [[ "$host" == "mirrors.aliyun.com" ]]; then
      fail "dns:$host" "cannot resolve"
    else
      warn "dns:$host" "cannot resolve (expected if blocked)"
    fi
  fi
done

case "$PLATFORM" in
  macos)
    if have scutil; then
      ns="$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | awk '!seen[$0]++' | head -n4 | tr '\n' ' ')"
      [[ -n "$ns" ]] && info "host:dns-servers" "$ns"
    fi
    ;;
  windows-gitbash)
    if have ipconfig; then
      ns="$(ipconfig -all 2>/dev/null | tr -d '\r' | awk -F: '/DNS Servers/{gsub(/^[ \t]+/,"",$2); if($2!="") printf "%s ", $2}' | cut -c1-80)"
      [[ -n "$ns" ]] && info "host:dns-servers" "$ns"
    fi
    ;;
  *)
    if [[ -f /etc/resolv.conf ]]; then
      ns="$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)"
      if [[ "$ns" == *"127.0.0.53"* ]]; then
        warn "host:resolv.conf" "uses systemd-resolved stub 127.0.0.53 ($ns) -> containers may fail; set daemon dns"
      else
        info "host:resolv.conf" "$ns"
      fi
    fi
    ;;
esac

# ---------------------------------------------------------- 2. host egress
hdr "2. Host egress (HTTPS)"
check_https() {
  local name="$1" url="$2" maxtime="${3:-10}" sev="${4:-fail}"
  if have curl; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$maxtime" "$url" 2>/dev/null || echo 000)"
    case "$code" in
      2*|3*|4*) pass "https:$name" "HTTP $code" ;;
      000) case "$sev" in
             fail) fail "https:$name" "no response within ${maxtime}s" ;;
             *)    warn "https:$name" "no response (may be expected)" ;;
           esac ;;
      *) pass "https:$name" "HTTP $code" ;;
    esac
  else
    warn "https:$name" "curl not installed"
  fi
}
check_https "aliyun-mirror"   "https://mirrors.aliyun.com/" 8 fail
check_https "maven-aliyun"    "https://maven.aliyun.com/repository/public/" 8 fail
check_https "npm-npmmirror"   "https://registry.npmmirror.com/" 8 fail
check_https "pypi-aliyun"     "https://mirrors.aliyun.com/pypi/simple/" 8 fail
if [[ $QUICK -eq 0 ]]; then
  check_https "github"        "https://github.com/" 8 warn
  check_https "docker-hub"    "https://registry-1.docker.io/v2/" 8 warn
  check_https "ghcr"          "https://ghcr.io/v2/" 8 warn
fi

# ------------------------------------------------------------ 3. docker daemon
hdr "3. Docker daemon"
if have docker; then
  if docker info >/dev/null 2>&1; then
    pass "docker:daemon" "reachable"
    mirrors="$(docker info --format '{{join .RegistryConfig.Mirrors ","}}' 2>/dev/null || true)"
    if [[ -n "$mirrors" ]]; then pass "docker:mirrors" "$mirrors"; else warn "docker:mirrors" "none configured (run setup_docker_cn.sh / setup_docker_cn.ps1)"; fi
    ver="$(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo '?')"
    info "docker:version" "$ver"
    if docker info 2>/dev/null | grep -qi 'server version: *2[0-3]\.'; then
      info "docker:note" "older daemon: 'max-download-attempts' unsupported"
    fi
  else
    fail "docker:daemon" "cannot talk to daemon"
  fi
else
  warn "docker:cli" "docker CLI not installed"
fi

detect_daemon_json() {
  if [[ -n "${CN_DOCKER_DAEMON_JSON:-}" ]]; then echo "$CN_DOCKER_DAEMON_JSON"; return; fi
  case "$PLATFORM" in
    macos)
      if [[ -f "$HOME/.docker/daemon.json" ]]; then echo "$HOME/.docker/daemon.json"
      elif [[ -f "$HOME/.orbstack/config/docker.json" ]]; then echo "$HOME/.orbstack/config/docker.json"
      else echo "$HOME/.docker/daemon.json"; fi
      ;;
    windows-gitbash)
      echo "$HOME/.docker/daemon.json"
      ;;
    wsl)
      if [[ -f /etc/docker/daemon.json ]]; then echo "/etc/docker/daemon.json"
      elif have cmd.exe && have wslpath; then
        local wp wh
        wp="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n' || true)"
        wh="$(wslpath "$wp" 2>/dev/null || true)"
        if [[ -n "$wh" && -f "$wh/.docker/daemon.json" ]]; then echo "$wh/.docker/daemon.json"; return; fi
        echo "/etc/docker/daemon.json"
      else
        echo "/etc/docker/daemon.json"
      fi
      ;;
    *)
      if [[ -f /etc/docker/daemon.json ]]; then echo "/etc/docker/daemon.json"
      elif [[ -f "$HOME/.config/docker/daemon.json" ]]; then echo "$HOME/.config/docker/daemon.json"
      else echo "/etc/docker/daemon.json"; fi
      ;;
  esac
}

DAEMON_JSON_PATH="$(detect_daemon_json)"
if [[ -f "$DAEMON_JSON_PATH" ]]; then
  if [[ -n "$PY_CMD" ]]; then
    NATIVE_DJ="$(to_native_path "$DAEMON_JSON_PATH")"
    # shellcheck disable=SC2086
    if $PY_CMD -m json.tool "$NATIVE_DJ" >/dev/null 2>&1; then
      pass "daemon.json:valid" "$DAEMON_JSON_PATH parses"
      # shellcheck disable=SC2086
      if $PY_CMD - "$NATIVE_DJ" <<'PY' >/dev/null 2>&1
import json, sys
with open(sys.argv[1], "r", encoding="utf-8-sig") as fh:
    d = json.load(fh)
p = d.get("proxies") or {}
np = str(p.get("no-proxy") or "")
sys.exit(0 if ("127.0.0.1" in np or not p) else 1)
PY
      then pass "daemon.json:no-proxy" "loopback not proxied"
      else fail "daemon.json:no-proxy" "proxies set WITHOUT 127.0.0.1 in no-proxy -> local calls will break"; fi
    else
      fail "daemon.json:valid" "$DAEMON_JSON_PATH is INVALID JSON -> daemon will not start"
    fi
  else
    info "daemon.json" "present at $DAEMON_JSON_PATH (python unavailable to validate)"
  fi
else
  warn "daemon.json" "absent at $DAEMON_JSON_PATH (run setup_docker_cn.sh / setup_docker_cn.ps1)"
fi

if [[ "$PLATFORM" == "linux" ]]; then
  if [[ -f /etc/buildkit/buildkitd.toml ]]; then
    if grep -q 'nameservers' /etc/buildkit/buildkitd.toml; then
      pass "buildkitd:dns" "nameservers configured"
    else
      warn "buildkitd:dns" "no [dns] nameservers -> RUN steps may fail to resolve"
    fi
  else
    info "buildkitd" "/etc/buildkit/buildkitd.toml absent (configure if BuildKit RUN fails DNS)"
  fi
fi

# ------------------------------------------------------- 4. container runtime
hdr "4. Container DNS / egress / IPv6 / MTU"
if have docker && docker info >/dev/null 2>&1; then
  IMG="busybox:1.36"
  if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    docker pull -q "$IMG" >/dev/null 2>&1 || IMG=""
  fi
  if [[ -n "$IMG" ]]; then
    if out="$(docker run --rm "$IMG" nslookup mirrors.aliyun.com 2>&1)"; then
      pass "container:dns" "busybox resolved mirrors.aliyun.com"
    else
      fail "container:dns" "resolution failed: $(echo "$out" | tr '\n' ' ' | cut -c1-100)"
    fi
    if out="$(docker run --rm "$IMG" sh -c 'wget -q -T 8 -O /dev/null https://mirrors.aliyun.com/ && echo ok' 2>&1)"; then
      [[ "$out" == *ok* ]] && pass "container:egress" "https to aliyun OK" || warn "container:egress" "$(echo "$out"|tr '\n' ' '|cut -c1-90)"
    else
      warn "container:egress" "wget failed (busybox TLS limits?) - check manually"
    fi
    if out="$(docker run --rm "$IMG" sh -c 'ip -6 addr show default 2>/dev/null | head -n2' 2>&1)"; then
      info "container:ipv6" "$(echo "$out" | tr '\n' ' ' | cut -c1-80)"
    fi
  else
    warn "container:image" "could not obtain busybox to probe container networking"
  fi

  if [[ "$PLATFORM" == "linux" || "$PLATFORM" == "wsl" ]] && have ip; then
    mtu="$(ip link show docker0 2>/dev/null | sed -nE 's/.*mtu ([0-9]+).*/\1/p' | head -n1)"
    if [[ -n "$mtu" ]]; then
      if [[ "$mtu" -gt 1450 ]]; then warn "host:docker0-mtu" "$mtu (VPN/overlay? consider 1400 if large responses stall)"; else pass "host:docker0-mtu" "$mtu"; fi
    fi
  elif [[ "$PLATFORM" == "macos" ]] && have ifconfig; then
    mtu="$(ifconfig en0 2>/dev/null | awk '/mtu/{print $NF; exit}' || true)"
    [[ -n "$mtu" ]] && info "host:en0-mtu" "$mtu"
  fi
else
  warn "container:probe" "skipped (docker unavailable)"
fi

# --------------------------------------------------------------- 5. clock skew
hdr "5. Clock (TLS validity window)"
if have curl && [[ -n "$PY_CMD" ]]; then
  skew=""
  skew_src=""
  for probe in "https://www.baidu.com/" "https://registry.npmmirror.com/" "https://mirrors.aliyun.com/"; do
    remote_date="$(curl -sSI --max-time 6 "$probe" 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r' | head -n1)"
    [[ -n "$remote_date" ]] || continue
    # shellcheck disable=SC2086
    cand="$(REMOTE_DATE="$remote_date" $PY_CMD - <<'PY' 2>/dev/null || true
import email.utils, os, sys, time
raw = os.environ.get("REMOTE_DATE", "")
try:
    dt = email.utils.parsedate_to_datetime(raw)
except Exception:
    sys.exit(1)
if dt is None:
    sys.exit(1)
print(abs(int(time.time()) - int(dt.timestamp())))
PY
)"
    [[ -n "$cand" ]] || continue
    if [[ -z "$skew" ]] || [[ "$cand" -lt "$skew" ]]; then
      skew="$cand"
      skew_src="$probe"
    fi
  done
  if [[ -n "$skew" ]]; then
    if [[ "$skew" -le 60 ]]; then
      pass "clock:skew" "${skew}s (best of 3 peers, via ${skew_src})"
    else
      case "$PLATFORM" in
        macos) sync_hint="run 'sudo sntp -sS time.apple.com' or enable automatic time in System Settings" ;;
        windows-gitbash) sync_hint="run 'w32tm /resync' in elevated CMD/PowerShell" ;;
        wsl) sync_hint="run 'sudo hwclock -s' or 'wsl --shutdown' to resync WSL2 clock" ;;
        *) sync_hint="enable chronyd/systemd-timesyncd" ;;
      esac
      fail "clock:skew" "${skew}s -> ${sync_hint} or TLS will fail"
    fi
  else
    warn "clock:skew" "no reliable Date header from any probe host"
  fi
fi

# --------------------------------------------------------- 6. language indices
if [[ $QUICK -eq 0 ]]; then
  hdr "6. Language package indices (domestic mirrors)"
  if have curl; then
    for pair in \
        "apt|https://mirrors.aliyun.com/debian/dists/bookworm/Release" \
        "alpine|https://mirrors.aliyun.com/alpine/v3.20/main/x86_64/APKINDEX.tar.gz" \
        "maven|https://maven.aliyun.com/repository/public/org/apache/maven/maven-core/maven-metadata.xml" \
        "npm|https://registry.npmmirror.com/lodash" \
        "pypi|https://mirrors.aliyun.com/pypi/simple/requests/" \
        "composer|https://mirrors.aliyun.com/composer/packages.json" \
        "goproxy|https://goproxy.cn/github.com/gin-gonic/gin/@v/list" \
        "crates|https://rsproxy.cn/index/config.json" ; do
      name="${pair%%|*}"; url="${pair#*|}"
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || echo 000)"
      case "$code" in
        2*|3*) pass "pkg:$name" "HTTP $code" ;;
        *)     warn "pkg:$name" "HTTP $code" ;;
      esac
    done
  fi
fi

# ---------------------------------------------------------------- 7. git/GitHub
if [[ $QUICK -eq 0 ]]; then
  hdr "7. Git / GitHub reachability"
  if have curl; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 https://github.com/ 2>/dev/null || echo 000)"
    case "$code" in 2*|3*|4*) pass "git:github" "HTTP $code";; *) warn "git:github" "unreachable -> use ghfast prefix or mihomo_ctl run";; esac
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 https://ghfast.top/https://github.com/ 2>/dev/null || echo 000)"
    case "$code" in 2*|3*) pass "git:ghfast-prefix" "HTTP $code";; *) info "git:ghfast-prefix" "HTTP $code (may still work for real asset paths)";; esac
  fi
fi

# ------------------------------------------------------------ 8. LLM endpoint
hdr "8. LLM API endpoint"
LLM_BASE="${CN_LLM_BASE_URL:-${OPENAI_BASE_URL:-${LLM_BASE_URL:-}}}"
if [[ -z "$LLM_BASE" ]]; then
  for f in "${PWD}/.env" "${PWD}/../.env"; do
    if [[ -f "$f" ]] && grep -qE '^(CN_LLM_BASE_URL|OPENAI_BASE_URL|LLM_BASE_URL)=' "$f" 2>/dev/null; then
      LLM_BASE="$(grep -E '^(CN_LLM_BASE_URL|OPENAI_BASE_URL|LLM_BASE_URL)=' "$f" | head -n1 | cut -d= -f2- | tr -d '"'"'"' \r')"
      info "llm:source" "$f"; break
    fi
  done
fi
if [[ -n "$LLM_BASE" ]]; then
  if have curl; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${LLM_BASE%/}/models" 2>/dev/null || echo 000)"
    case "$code" in
      2*|3*|401) pass "llm:reachable" "HTTP $code (401 = reachable, auth needed)" ;;
      000) fail "llm:unreachable" "$LLM_BASE (timeout) - check proxy/TLS" ;;
      *) warn "llm:status" "HTTP $code" ;;
    esac
    TMP_ERR="$(mktemp "${TMPDIR:-/tmp}/cn_curl_err.XXXXXX")"
    if ! curl -sS -o /dev/null --max-time 10 "${LLM_BASE%/}/models" 2>"$TMP_ERR"; then
      if grep -qi 'certificate' "$TMP_ERR"; then
        warn "llm:tls-chain" "TLS cert verify failed -> check system CA bundle or server intermediate certificate chain"
      fi
    fi
    rm -f "$TMP_ERR"
  fi
else
  info "llm:endpoint" "CN_LLM_BASE_URL / OPENAI_BASE_URL not set (skipped)"
fi

# ------------------------------------------------------------------- summary
hdr "Summary"
if [[ $JSON -eq 1 ]]; then
  if [[ -n "$PY_CMD" ]]; then
    # shellcheck disable=SC2086
    $PY_CMD - "$FAILS" "$WARNS" ${ROWS[@]+"${ROWS[@]}"} <<'PY'
import json, sys
fails = int(sys.argv[1]); warns = int(sys.argv[2])
rows = []
for r in sys.argv[3:]:
    parts = r.split("|", 2)
    if len(parts) == 3:
        rows.append({"status": parts[0], "check": parts[1], "detail": parts[2]})
print(json.dumps({"fails": fails, "warns": warns, "checks": rows}, ensure_ascii=False, indent=2))
PY
  else
    printf '{"fails":%d,"warns":%d}\n' "$FAILS" "$WARNS"
  fi
else
  printf '  FAIL=%d  WARN=%d  total=%d\n' "$FAILS" "$WARNS" "${#ROWS[@]}"
  if [[ $FAILS -gt 0 ]]; then
    printf '\n  \033[31mAction required:\033[0m fix FAIL items above (see references/troubleshooting.md for the layer-by-layer order).\n'
  elif [[ $WARNS -gt 0 ]]; then
    printf '\n  \033[33mMostly healthy.\033[0m WARN items are usually non-blocking (blocked foreign hosts are expected).\n'
  else
    printf '\n  \033[32mAll checks passed.\033[0m\n'
  fi
fi
exit $(( FAILS > 0 ? 1 : 0 ))
