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
xcodebuild -project Kakeiro.xcodeproj -scheme Kakeiro \
  -configuration Debug -destination "$kakeiro_destination" \
  -derivedDataPath .derivedData -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test "$@"
