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

exec "$CHROME" \
  --user-data-dir=~/.wispr/profiles/service \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9223 \
  --no-first-run --no-default-browser-check --disable-dev-shm-usage \
  --use-fake-ui-for-media-stream \
  --window-position=0,0 --window-size=470,530 \
  about:blank
