#!/bin/bash
# Unit- und UI-Tests im eigenen Simulator gegen den Test-Server (Testkonto, nie ein echtes Konto).
# Token aus der gitignorten Datei .test-tokens (python3 tools/test-tokens.py).
#   ./test.sh                                         alle Tests
#   ./test.sh -only-testing:HomeThreadTests/CoreTests
set -euo pipefail
cd "$(dirname "$0")"
SIM=${SIM:-$(cat .sim-udid)}
python3 tools/test-tokens.py >/dev/null
set -a; source .test-tokens; set +a
xcodegen generate -q
export TEST_RUNNER_THREAD_SERVER="$THREAD_SERVER" TEST_RUNNER_THREAD_TOKEN="$THREAD_TOKEN" \
  TEST_RUNNER_THREAD_TOKEN2="$THREAD_TOKEN2" TEST_RUNNER_THREAD_PUBLIC_SERVER="${THREAD_PUBLIC_SERVER:-}"
xcrun simctl privacy "$SIM" grant microphone org.homeroll.thread 2>/dev/null || true
xcodebuild test -project HomeThread.xcodeproj -scheme HomeThread -destination "id=$SIM" -derivedDataPath build "$@"
