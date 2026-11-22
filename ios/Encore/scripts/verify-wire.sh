#!/bin/zsh
# Real-core playback check on a simulator (docs/streams/ios-wire.md). No speakers: mpv's real
# AudioUnit output at volume 0 (a null output would let iOS suspend the app in the background).
#   SIM=<udid> scripts/verify-wire.sh [query]
# Steps: search → play → position advances → gapless advance into the next track → Settings in front
# (background) and the clock keeps going → synthetic interruption pauses / resumes → headphones-out
# route change pauses. Prints PASS/FAIL per step; the full console log is in build/verify-wire/.
set -u
cd "$(dirname "$0")/.."
SIM=${SIM:?set SIM=<udid>}
Q=${1:-Daft Punk Get Lucky}
OUT=build/verify-wire; mkdir -p "$OUT"; LOG="$OUT/console.log"; : > "$LOG"
APP=build/dd/Build/Products/Debug-iphonesimulator/Encore.app
note() { xcrun simctl spawn "$SIM" notifyutil -p "app.encore.debug.$1"; }
pos() { grep "ENCORE_AUDIO POS" "$LOG" | tail -1 | sed -E 's/.*pos=([0-9.]+).*/\1/'; }
field() { grep "ENCORE_AUDIO POS" "$LOG" | tail -1 | sed -E "s/.* $1=([^ ]+).*/\1/"; }
ok=0; fail=0
check() { if eval "$2"; then echo "PASS  $1"; ok=$((ok+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }

# A fresh install: no restored queue, first-run bootstrap included in the timing.
xcrun simctl terminate "$SIM" studio.chladni.ios 2>/dev/null
xcrun simctl uninstall "$SIM" studio.chladni.ios 2>/dev/null
xcrun simctl install "$SIM" "$APP"
T0=$(date +%s)
xcrun simctl launch --console-pty "$SIM" studio.chladni.ios -volume 0 -traceAudio YES \
  -deeplink "encore://playsearch?q=${Q// /%20}" >> "$LOG" 2>&1 &
LPID=$!
for i in {1..60}; do grep -q "paused=0" "$LOG" && break; sleep 1; done
echo "      launch → audio playing: $(( $(date +%s) - T0 )) s"
sleep 2
check "core started" 'grep -q "ENCORE_CORE started" "$LOG"'
check "Now Playing set (title, artist, duration)" 'grep -q "NOWPLAYING reason=track" "$LOG" && grep "NOWPLAYING" "$LOG" | grep -q "duration=[1-9]"'
check "artwork on the lock screen info" 'grep "NOWPLAYING" "$LOG" | grep -q "artwork=yes"'
p1=$(pos); sleep 6; p2=$(pos)
check "position advances in the foreground ($p1 → $p2)" 'gt $(( p2 - p1 )) 3.5'

id1=$(field id); note seek-near-end; sleep 16; id2=$(field id); p3=$(pos)
check "gapless advance to the next track ($id1 → $id2, pos $p3)" '[[ "$id1" != "$id2" && "$id2" != "-" ]] && [[ "$(field paused)" == 0 ]]'
grep "NOWPLAYING reason=track" "$LOG" | tail -1

xcrun simctl launch "$SIM" com.apple.Preferences >/dev/null; sleep 4
b1=$(pos); sleep 16; b2=$(pos)
check "background playback with Settings in front ($b1 → $b2, app=$(field app))" '[[ "$(field app)" == background ]] && gt $(( b2 - b1 )) 12'

note interruption-began; sleep 4; i1=$(pos); sleep 4; i2=$(pos)
check "interruption began → paused ($i1 = $i2)" '[[ "$(field paused)" == 1 ]] && ! gt $(( i2 - i1 )) 0.3'
note interruption-ended-resume; sleep 4; r1=$(pos); sleep 4; r2=$(pos)
check "interruption ended (shouldResume) → resumed ($r1 → $r2)" '[[ "$(field paused)" == 0 ]] && gt $(( r2 - r1 )) 3'
note route-old-unavailable; sleep 3
check "headphones out (oldDeviceUnavailable) → paused" '[[ "$(field paused)" == 1 ]]'
note remote-toggle; sleep 4
check "remote play command → playing" '[[ "$(field paused)" == 0 ]]'
note media-reset; sleep 5; m1=$(pos); sleep 4; m2=$(pos)
check "media services reset → rebuilt, still playing ($m1 → $m2)" 'gt $(( m2 - m1 )) 3'

xcrun simctl launch "$SIM" studio.chladni.ios >/dev/null 2>&1; sleep 2
grep -E "ENCORE_AUDIO (route|interruption|remote|resumed|paused|media|debug|session)" "$LOG" | sed 's/^/  /'
kill $LPID 2>/dev/null
echo "$ok passed, $fail failed (log: $LOG)"
[[ $fail == 0 ]]
