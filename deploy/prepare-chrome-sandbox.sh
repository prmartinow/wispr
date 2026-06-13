#!/usr/bin/env bash
# Ensure the Playwright Chromium setuid sandbox is usable before systemd launches Chrome.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/chrome-paths.sh"

CHROME="$(resolve_wispr_chrome)" || {
  echo "wispr: no executable Chromium/Chrome found" >&2
  exit 127
}

SANDBOX="${WISPR_CHROME_SANDBOX:-$(dirname "$CHROME")/chrome_sandbox}"
[ -e "$SANDBOX" ] || exit 0

current="$(stat -c '%u:%a' "$SANDBOX")"
if [ "$current" = "0:4755" ]; then
  exit 0
fi

if ! sudo -n true 2>/dev/null; then
  echo "wispr: $SANDBOX is $current; need root:4755 and sudo -n is unavailable" >&2
  exit 1
fi

sudo chown root:root "$SANDBOX"
sudo chmod 4755 "$SANDBOX"
echo "wispr: configured Chromium sandbox $SANDBOX" >&2
