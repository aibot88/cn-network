#!/usr/bin/env bash
# =============================================================================
# maven-cn.sh — Maven settings.xml + Maven Wrapper distributionUrl to a
#               domestic mirror (macOS / Linux / WSL2 / Windows Git Bash).
#
# Usage:
#   ./maven-cn.sh                           # write ~/.m2/settings.xml only
#   ./maven-cn.sh /path/to/project          # also patch ./mvnw wrapper in repo
#   ./maven-cn.sh /path/to/project --settings-only
#
# Env:
#   MAVEN_MIRROR   default https://maven.aliyun.com/repository/public
#   M2_DIR         optional custom localRepository path (omitted by default so
#                  Maven natively uses ${user.home}/.m2/repository across OSes)
# =============================================================================
set -euo pipefail

MAVEN_MIRROR="${MAVEN_MIRROR:-https://maven.aliyun.com/repository/public}"
CUSTOM_M2_DIR="${M2_DIR:-}"
PROJECT="${1:-}"
MODE="${2:-}"

if [ "$PROJECT" = "--settings-only" ]; then
  MODE="--settings-only"
  PROJECT=""
fi

SETTINGS_DIR="${HOME}/.m2"
SETTINGS_FILE="${SETTINGS_DIR}/settings.xml"

mkdir -p "$SETTINGS_DIR" "${CUSTOM_M2_DIR:-${HOME}/.m2/repository}"

LOCAL_REPO_XML=""
if [ -n "$CUSTOM_M2_DIR" ]; then
  REPO_FOR_JAVA="$CUSTOM_M2_DIR"
  if command -v cygpath >/dev/null 2>&1; then
    REPO_FOR_JAVA="$(cygpath -m "$CUSTOM_M2_DIR")"
  fi
  LOCAL_REPO_XML="  <localRepository>${REPO_FOR_JAVA}</localRepository>"$'\n'
fi

if [ -f "$SETTINGS_FILE" ] && grep -q "aliyunmaven" "$SETTINGS_FILE" 2>/dev/null; then
  echo "[maven-cn] settings.xml already contains aliyun mirror, leaving untouched"
else
  if [ -f "$SETTINGS_FILE" ]; then
    [ -f "${SETTINGS_FILE}.cn-bak" ] || cp "$SETTINGS_FILE" "${SETTINGS_FILE}.cn-bak"
    echo "[maven-cn] backed up existing settings.xml -> settings.xml.cn-bak"
  fi
  cat > "$SETTINGS_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
${LOCAL_REPO_XML}  <mirrors>
    <mirror>
      <id>aliyunmaven</id>
      <mirrorOf>*</mirrorOf>
      <name>Aliyun Public Repository</name>
      <url>${MAVEN_MIRROR}</url>
    </mirror>
  </mirrors>
</settings>
EOF
  echo "[maven-cn] wrote $SETTINGS_FILE"
fi

if [ "$MODE" = "--settings-only" ] || [ -z "$PROJECT" ]; then
  echo "[maven-cn] done (settings only)"
  exit 0
fi

# --- Patch Maven Wrapper (portable across BSD sed on macOS & GNU sed) ----------
WRAPPER_PROPS=""
for p in "$PROJECT/.mvn/wrapper/maven-wrapper.properties" "$PROJECT/mvnw/maven-wrapper.properties"; do
  if [ -f "$p" ]; then WRAPPER_PROPS="$p"; break; fi
done

if [ -n "$WRAPPER_PROPS" ]; then
  [ -f "${WRAPPER_PROPS}.cn-bak" ] || cp "$WRAPPER_PROPS" "${WRAPPER_PROPS}.cn-bak" 2>/dev/null || true
  ver="$(sed -nE 's#.*apache-maven/([0-9]+\.[0-9]+(\.[0-9]+)?)/.*#\1#p' "$WRAPPER_PROPS" | tr -d '\r' | head -n1)"
  if [ -z "$ver" ]; then
    ver="$(sed -nE 's#.*maven-([0-9]+\.[0-9]+(\.[0-9]+)?)-bin.*#\1#p' "$WRAPPER_PROPS" | tr -d '\r' | head -n1)"
  fi
  if [ -n "$ver" ]; then
    TMP_WP="$(mktemp "${TMPDIR:-/tmp}/cn_mvnw.XXXXXX")"
    NEW_URL="${MAVEN_MIRROR%/}/org/apache/maven/apache-maven/${ver}/apache-maven-${ver}-bin.zip"
    awk -v url="$NEW_URL" '
      /^distributionUrl=/ { print "distributionUrl=" url; next }
      { print }
    ' "$WRAPPER_PROPS" > "$TMP_WP"
    mv "$TMP_WP" "$WRAPPER_PROPS"
    echo "[maven-cn] patched wrapper ($ver) in $WRAPPER_PROPS"
  else
    echo "[maven-cn] WARNING: could not determine Maven version from $WRAPPER_PROPS" >&2
  fi
else
  echo "[maven-cn] no mvnw wrapper found in $PROJECT (fine for plain mvn)"
fi

echo "[maven-cn] done"
