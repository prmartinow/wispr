#!/usr/bin/env bash
# Launch the frontend/live Wispr Chromium lane. This is lane 0: CDP 9223, mic virtmic_in,
# first tile on DISPLAY :95.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/chrome-paths.sh"
configure_wispr_chrome_env

export DISPLAY="${DISPLAY:-:95}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PULSE_SOURCE="${PULSE_SOURCE:-virtmic_in}"
WISPR_STATE_DIR="${WISPR_STATE_DIR:-$HOME/.wispr}"
WISPR_PROFILE_ROOT="${WISPR_PROFILE_ROOT:-$WISPR_STATE_DIR/profiles}"
WISPR_SERVICE_PROFILE="${WISPR_SERVICE_PROFILE:-$WISPR_PROFILE_ROOT/service}"
mkdir -p "$WISPR_SERVICE_PROFILE"
sanitize_wispr_profile_clean_exit "$WISPR_SERVICE_PROFILE"

exec "$CHROME" \
  --user-data-dir="$WISPR_SERVICE_PROFILE" \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9223 \
  --no-first-run --no-default-browser-check --disable-dev-shm-usage \
  --disable-session-crashed-bubble --hide-crash-restore-bubble --disable-infobars \
  --no-restore-session-state \
  --use-fake-ui-for-media-stream \
  --window-position=0,0 --window-size=470,530 \
  "${DICTATION_SERVICE_URL:-https://chatgpt.com/}"
