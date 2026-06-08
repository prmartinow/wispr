#!/usr/bin/env bash
# Launch one internal transcription lane (Chromium). Each lane:
#   - reads its OWN virtual mic via PULSE_SOURCE=virtmic{k}_in (the isolation mechanism: with
#     --use-fake-ui-for-media-stream the browser always captures its default source, and PULSE_SOURCE
#     makes that default the lane's own virtmic, so concurrent lanes never cross-talk),
#   - exposes its own CDP port (9223+k),
#   - uses its own logged-in profile clone,
#   - is tiled non-overlapping in a 4-wide grid on :95.
# Called by wispr-lane@%i.service.
set -uo pipefail
k="${1:?usage: wispr-lane.sh <lane-index>}"
export DISPLAY="${DISPLAY:-:95}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PULSE_SOURCE="virtmic${k}_in"

CHROME=/mnt/data/takeout-browser-profile/ms-playwright/chromium-1217/chrome-linux64/chrome
export CHROME_DEVEL_SANDBOX=/mnt/data/takeout-browser-profile/ms-playwright/chromium-1217/chrome-linux64/chrome_sandbox
PROFILE="~/.wispr/profiles/lanes/${k}-profile"
PORT=$(( 9223 + k ))

# Tile in a 4-wide grid of 480x540 cells (470x530 windows + small gap) on the 1920x1080 display.
# Cell 0 is the frontend (lane 0); internal lanes take cells 1..N.
COLS=4; CW=480; CH=540
X=$(( (k % COLS) * CW )); Y=$(( (k / COLS) * CH ))

exec "$CHROME" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port="$PORT" \
  --no-first-run --no-default-browser-check --disable-dev-shm-usage \
  --use-fake-ui-for-media-stream \
  --window-position="${X},${Y}" --window-size=470,530 \
  about:blank
