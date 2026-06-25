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
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/chrome-paths.sh"
configure_wispr_chrome_env

export DISPLAY="${DISPLAY:-:95}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PULSE_SOURCE="virtmic${k}_in"
WISPR_STATE_DIR="${WISPR_STATE_DIR:-$HOME/.wispr}"
WISPR_PROFILE_ROOT="${WISPR_PROFILE_ROOT:-$WISPR_STATE_DIR/profiles}"
WISPR_LANE_PROFILE_ROOT="${WISPR_LANE_PROFILE_ROOT:-$WISPR_PROFILE_ROOT/lanes}"

PROFILE="$WISPR_LANE_PROFILE_ROOT/$k"
PORT=$(( 9223 + k ))
mkdir -p "$PROFILE"

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
