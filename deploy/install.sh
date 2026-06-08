#!/usr/bin/env bash
# Install/refresh the wispr service as persistent systemd --user units.
# ops has linger enabled, so these start at boot. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.config/systemd/user"
chmod +x "$HERE/setup-virtmic.sh" "$HERE/setup-lanes.sh" "$HERE/wispr-lane.sh"
# shellcheck disable=SC1091
source "$HERE/lanes.env"

CHROME_SANDBOX="/mnt/data/takeout-browser-profile/ms-playwright/chromium-1217/chrome-linux64/chrome_sandbox"
if [ -e "$CHROME_SANDBOX" ]; then
  if sudo -n true 2>/dev/null; then
    sudo chown root:root "$CHROME_SANDBOX"
    sudo chmod 4755 "$CHROME_SANDBOX"
  else
    echo "warn: cannot configure Chromium setuid sandbox (sudo unavailable): $CHROME_SANDBOX" >&2
  fi
fi

cp "$HERE/wispr-virtmic.service" "$HERE/wispr-browser.service" "$HERE/wispr-server.service" \
   "$HERE/wispr-lane@.service" \
   "$HERE/wispr-virtmic-check.service" "$HERE/wispr-virtmic-check.timer" \
   "$HERE/wispr-browser-restart.service" "$HERE/wispr-browser-restart.timer" \
   "$HERE/vnc-xvfb.service" "$HERE/vnc-x11vnc.service" "$HERE/vnc-novnc.service" \
   "$HOME/.config/systemd/user/"

# wispr owns the pulse daemon -> mask the system pulse units that race it (pa_pid_file_create).
# Revert with: systemctl --user unmask pulseaudio.socket pulseaudio.service
systemctl --user mask pulseaudio.socket pulseaudio.service 2>/dev/null || true
systemctl --user reset-failed pulseaudio.service 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now vnc-xvfb.service vnc-x11vnc.service vnc-novnc.service
systemctl --user enable --now wispr-virtmic.service wispr-browser.service wispr-server.service
systemctl --user enable --now wispr-virtmic-check.timer wispr-browser-restart.timer

# Internal batch lanes: re-run the (idempotent) virtmic setup so the per-lane mics exist, clone the
# logged-in profile per lane, then bring up one tiled, mic-isolated Chromium per lane. Count = WISPR_LANES.
systemctl --user restart wispr-virtmic.service
"$HERE/setup-lanes.sh"
for k in $(seq 1 "${WISPR_LANES:-0}"); do
  systemctl --user enable --now "wispr-lane@$k.service"
done

echo "installed. units:"
systemctl --user is-active wispr-virtmic.service wispr-browser.service wispr-server.service
echo "vnc:"
systemctl --user is-active vnc-xvfb.service vnc-x11vnc.service vnc-novnc.service
echo "timers:"
systemctl --user is-active wispr-virtmic-check.timer wispr-browser-restart.timer
