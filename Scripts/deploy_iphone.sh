#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: bash Scripts/deploy_iphone.sh <iPhone UDID>" >&2
    echo "Find a connected iPhone with: xcrun xctrace list devices" >&2
    exit 2
fi

kakeiro_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
kakeiro_device="$1"
kakeiro_build="$kakeiro_root/.build/device"

# Requires the configured Apple development team and a trusted connected iPhone.
# This is an explicit install command; the build/CI scripts never call it.
xcodebuild \
    -project "$kakeiro_root/Kakeiro.xcodeproj" \
    -scheme Kakeiro \
    -configuration Debug \
    -destination "id=$kakeiro_device" \
    -derivedDataPath "$kakeiro_build" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build

xcrun devicectl device install app \
    --device "$kakeiro_device" \
    "$kakeiro_build/Build/Products/Debug-iphoneos/Kakeiro.app"

xcrun devicectl device process launch \
    --device "$kakeiro_device" \
    dev.adachi.kakeiro
