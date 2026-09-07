#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Set SIMULATOR_ID to a simulator UUID from `xcrun simctl list devices available`.
# Tests use an isolated local store; each test explicitly resets only that store.
if [[ -n "${SIMULATOR_ID:-}" ]]; then
  kakeiro_destination="platform=iOS Simulator,id=$SIMULATOR_ID"
else
  kakeiro_destination="platform=iOS Simulator,name=${SIMULATOR_NAME:-iPhone 17 Pro}"
fi
python3 Scripts/sync_ui_fixture.py &
kakeiro_fixture_pid=$!
trap 'kill "$kakeiro_fixture_pid" 2>/dev/null || true' EXIT
# A port collision fails the fixture instead of silently testing against another service.
sleep 1
kill -0 "$kakeiro_fixture_pid"
xcodebuild -project Kakeiro.xcodeproj -scheme Kakeiro \
  -configuration Debug -destination "$kakeiro_destination" \
  -derivedDataPath .derivedData -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test "$@"
