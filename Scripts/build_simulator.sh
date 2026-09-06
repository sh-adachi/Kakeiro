#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A generic destination builds without starting or modifying any simulator.
xcodebuild -project Kakeiro.xcodeproj -scheme Kakeiro \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build "$@"
