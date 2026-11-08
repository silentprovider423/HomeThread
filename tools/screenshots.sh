#!/bin/bash
# Englische Demo-Screenshots (iPhone-Simulator + Mac) mit dem Demokonto. Vorher: tools/test-tokens.py demo + tools/demo-data.py
set -euo pipefail
cd "$(dirname "$0")/.."
SIM=${SIM:-$(cat .sim-udid)}
OUT=docs/screenshots
set -a; source .test-tokens; set +a
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
shot() { # name, Wartezeit, weitere Variablen …
  local name=$1 wait=$2; shift 2
  local envs=(SIMCTL_CHILD_THREAD_SERVER="$THREAD_SERVER" SIMCTL_CHILD_THREAD_TOKEN="$THREAD_DEMO_TOKEN")
  for kv in "$@"; do envs+=("SIMCTL_CHILD_$kv"); done
  env "${envs[@]}" xcrun simctl launch --terminate-running-process "$SIM" org.homeroll.thread -AppleLanguages "(en)" -AppleLocale en_US >/dev/null
  sleep "$wait"
  xcrun simctl io "$SIM" screenshot "$OUT/$name.png" >/dev/null 2>&1
}
shot ios-1-chats 9 THREAD_RESET=1 THREAD_APPEARANCE=1
shot ios-2-chat 7 THREAD_OPEN="Trip to Lisbon" THREAD_APPEARANCE=1
shot ios-3-checklist 7 THREAD_OPEN="Groceries" THREAD_APPEARANCE=1
shot ios-4-dark 7 THREAD_OPEN="Garden" THREAD_APPEARANCE=2
xcrun simctl status_bar "$SIM" clear
# Mac: Fenster rendert sich selbst in eine PNG (nur Debug)
MAC=build/Build/Products/Debug/HomeThread.app/Contents/MacOS/HomeThread
for m in "mac-1-light:1:info" "mac-2-dark:2:"; do
  n=${m%%:*}; r=${m#*:}; a=${r%%:*}; show=${r#*:}
  THREAD_SERVER="$THREAD_SERVER" THREAD_TOKEN="$THREAD_DEMO_TOKEN2" THREAD_RESET=1 THREAD_OPEN="Trip to Lisbon" THREAD_APPEARANCE=$a THREAD_SHOW=$show \
    THREAD_SNAPSHOT="$PWD/$OUT/$n.png" "$MAC" -AppleLanguages "(en)" -AppleLocale en_US >/dev/null 2>&1 || true
done
xcrun simctl shutdown "$SIM"
python3 tools/strip-meta.py $OUT/*.png
ls -la $OUT
