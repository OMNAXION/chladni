#!/bin/zsh
# End-to-end user flows on the REAL core (network, mpv ao=audiounit at volume 0): scheme EncoreE2E.
#   SIM=<udid> scripts/e2e.sh                 every flow (~15 min)
#   SIM=<udid> scripts/e2e.sh <testMethod>…   just these (e.g. test07_QueuePlayNextAddClear)
# Prints one line per flow (PASS/FAIL + seconds); failure screenshots land in build/e2e/shots and
# the result bundle in build/e2e/E2E.xcresult. Report: docs/streams/ios-e2e.md.
set -u
cd "$(dirname "$0")/.."
SIM=${SIM:?set SIM=<udid>}
OUT=build/e2e; rm -rf "$OUT/E2E.xcresult" "$OUT/shots"; mkdir -p "$OUT/shots"
xcodegen generate -q
only=(); for t in "$@"; do only+=(-only-testing:EncoreE2ETests/FlowTests/$t); done
xcodebuild -scheme EncoreE2E -destination "id=$SIM" -derivedDataPath build/dd build-for-testing -quiet || exit 1
# YouTube's bot wall (403 on anonymous InnerTube calls from this IP) makes flows fail for reasons
# outside the app; say so up front and at the end, so a red run can be read correctly.
wall() { curl -s -o /dev/null -w '%{http_code}' -X POST 'https://music.youtube.com/youtubei/v1/search?prettyPrint=false' \
  -H 'Content-Type: application/json' -d '{"context":{"client":{"clientName":"WEB_REMIX","clientVersion":"1.20250101.01.00"}},"query":"daft punk"}'; }
echo "YouTube search from this IP before the run: HTTP $(wall)  (403 = bot wall active)"
# The Spotify import flow reads a synthetic export from the app's Documents ("Open in Encore").
python3 scripts/make-spotify-export.py "$OUT/e2e-export.zip" >/dev/null
xcrun simctl install "$SIM" build/dd/Build/Products/Debug-iphonesimulator/Encore.app
DOCS="$(xcrun simctl get_app_container "$SIM" studio.chladni.ios data)/Documents"; mkdir -p "$DOCS"
cp "$OUT/e2e-export.zip" "$DOCS/e2e-export.zip"
T0=$(date +%s)
TEST_RUNNER_E2E_SHOTS="$PWD/$OUT/shots" xcodebuild test-without-building -scheme EncoreE2E -destination "id=$SIM" \
  -derivedDataPath build/dd -resultBundlePath "$OUT/E2E.xcresult" ${only[@]+"${only[@]}"} 2>&1 | tee "$OUT/log.txt" \
  | grep -E "E2E_RESULT|E2E_NOTE|error:|XCTAssert|Executed|\*\* TEST" | sed -E "s/^.*(E2E_RESULT|E2E_NOTE) /  /"
echo "total $(( $(date +%s) - T0 )) s; YouTube search after the run: HTTP $(wall)"
