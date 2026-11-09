#!/bin/bash
# Time-Profiler-Messung (100 s) im eigenen Simulator während „bis zum ersten Eintrag hochscrollen“ (Auto-Scroll) (synthetische Daten).
#   tools/profile.sh <ausgabe.trace>
set -uo pipefail
cd "$(dirname "$0")/.."
SIM=${SIM:-$(cat .sim-udid)}
TRACE=${1:-build/scroll.trace}
LOG=$TRACE.log
rm -rf "$TRACE"
xcrun simctl boot "$SIM" 2>/dev/null || true
./test.sh -only-testing:HomeThreadUITests/PerfTests/testScrollToBeginningWithLoading > "$LOG" 2>&1 &
TP=$!
until grep -q "PERF Verlauf\|testScrollToBeginningWithLoading\]' started" "$LOG" 2>/dev/null; do sleep 1; kill -0 $TP 2>/dev/null || break; done
sleep 12
xcrun xctrace record --template 'Time Profiler' --device "$SIM" --attach HomeThread --time-limit 100s --output "$TRACE" >/dev/null 2>&1
wait $TP
xcrun simctl shutdown "$SIM"
echo "Trace: $TRACE"
