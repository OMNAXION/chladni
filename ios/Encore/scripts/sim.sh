#!/bin/zsh
# Build, install and drive the shell in the simulator; screenshots for docs/compare/ios.
#   scripts/sim.sh build                 build + install + launch
#   scripts/sim.sh shot <name> [url] [wait]  open an encore:// link, wait, screenshot
# SIM=<udid> picks the simulator (default: booted). MOCK=1: the devmock-fixture core (-mock).
set -e
cd "$(dirname "$0")/.."
SIM=${SIM:-booted}
OUT=${OUT:-$HOME/music-app/docs/compare/ios}
case "$1" in
  build)
    xcodegen generate -q
    xcodebuild -scheme Encore -destination "id=$SIM" -derivedDataPath build/dd build -quiet
    xcrun simctl install "$SIM" build/dd/Build/Products/Debug-iphonesimulator/Encore.app
    xcrun simctl terminate "$SIM" studio.chladni.ios 2>/dev/null || true
    xcrun simctl launch "$SIM" studio.chladni.ios ;;
  shot)
    mkdir -p "$OUT"
    # Relaunch with the link(s) as a launch argument (space-separated encore:// links run in order).
    xcrun simctl terminate "$SIM" studio.chladni.ios 2>/dev/null || true
    extra=(); [[ -n "$MOCK" ]] && extra=(-mock)
    if [[ -n "$3" ]]; then xcrun simctl launch "$SIM" studio.chladni.ios "${extra[@]}" -deeplink "$3" >/dev/null
    else xcrun simctl launch "$SIM" studio.chladni.ios "${extra[@]}" >/dev/null; fi
    sleep ${4:-2}
    xcrun simctl io "$SIM" screenshot "$OUT/$2.png" >/dev/null 2>&1 && echo "$OUT/$2.png" ;;
esac
