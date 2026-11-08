#!/bin/bash
# Baut die App und startet sie im eigenen Simulator, angemeldet über die Startumgebung (kein Passwort-Tippen).
# Token aus der gitignorten Datei .test-tokens (python3 tools/test-tokens.py).
#   ./sim-run.sh [THREAD_OPEN=<Chat>] …      zusätzliche Variablen werden an die App weitergereicht
set -euo pipefail
cd "$(dirname "$0")"
SIM=${SIM:-$(cat .sim-udid)}
set -a; source .test-tokens; set +a
xcodegen generate -q
xcodebuild -project HomeThread.xcodeproj -scheme HomeThread -destination "id=$SIM" -derivedDataPath build -quiet build 2>&1 \
  | grep -E "error:" || true
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl install "$SIM" build/Build/Products/Debug-iphonesimulator/HomeThread.app
ENVS=(SIMCTL_CHILD_THREAD_SERVER="$THREAD_SERVER" SIMCTL_CHILD_THREAD_TOKEN="${TOKEN:-$THREAD_TOKEN}")
for kv in "$@"; do ENVS+=("SIMCTL_CHILD_$kv"); done
env "${ENVS[@]}" xcrun simctl launch --terminate-running-process "$SIM" org.homeroll.thread >/dev/null
echo "gestartet"
