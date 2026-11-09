#!/bin/bash
# Leistungsmessung (synthetische Daten, nur lokal im eigenen Simulator) und Auswertung der Hänger je Test.
#   tools/perf.sh [Ausgabedatei] [Test, z. B. PerfTests/testScrollUpHitches]
set -uo pipefail
cd "$(dirname "$0")/.."
SIM=${SIM:-$(cat .sim-udid)}
OUT=${1:-build/perf.log}
ONLY=${2:-PerfTests}
mkdir -p "$(dirname "$OUT")"
xcrun simctl boot "$SIM" 2>/dev/null || true
C=$(xcrun simctl get_app_container "$SIM" org.homeroll.thread data 2>/dev/null) && rm -f "$C/Documents/perf-hitches.txt" "$C/Documents/perf-events.txt"
./test.sh -only-testing:HomeThreadUITests/$ONLY > "$OUT" 2>&1
C=$(xcrun simctl get_app_container "$SIM" org.homeroll.thread data)
cp "$C/Documents/perf-hitches.txt" "$OUT.hitches" 2>/dev/null
cp "$C/Documents/perf-events.txt" "$OUT.events" 2>/dev/null
xcrun simctl shutdown "$SIM"
grep -E "measured \[|PERF|Test Case.*(passed|failed)|error:" "$OUT" | sed -E 's/, performanceMetricID.*//'
echo "--- Hänger je Test (Hitch Time Ratio = Hitch-ms je Scroll-Sekunde) ---"
awk '{for (i=2;i<=NF;i++){split($i,kv,"="); V[$1,kv[1]]+=kv[2]; if (kv[1] ~ /worst|longest/ && kv[2]>M[$1,kv[1]]) M[$1,kv[1]]=kv[2]} N[$1]++; T[$1]=1}
     END {for (k in T) printf "%-34s Vorgänge=%3d Scroll=%6.1fs | 60Hz-Hitch %5.1f ms/s (schlimmstes Bild %5.1f ms) | Main-Thread über 8,3ms-Budget %6.1f ms/s (längster Block %5.1f ms, Last %4.0f%%)\n",
          k, N[k], V[k,"dur"], V[k,"hitch_ms"]/V[k,"dur"], M[k,"worst_ms"], V[k,"over120_ms"]/V[k,"dur"], M[k,"longest_ms"], V[k,"busy_ms"]/V[k,"dur"]/10}' "$OUT.hitches" 2>/dev/null
