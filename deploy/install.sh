#!/usr/bin/env bash
# Install/refresh the wispr service as persistent systemd --user units.
# ops has linger enabled, so these start at boot. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.config/systemd/user"
chmod +x "$HERE/setup-virtmic.sh"

cp "$HERE/wispr-virtmic.service" "$HERE/wispr-browser.service" "$HERE/wispr-server.service" \
   "$HERE/wispr-virtmic-check.service" "$HERE/wispr-virtmic-check.timer" \
   "$HERE/wispr-browser-restart.service" "$HERE/wispr-browser-restart.timer" \
   "$HOME/.config/systemd/user/"

# wispr owns the pulse daemon -> mask the system pulse units that race it (pa_pid_file_create).
# Revert with: systemctl --user unmask pulseaudio.socket pulseaudio.service
systemctl --user mask pulseaudio.socket pulseaudio.service 2>/dev/null || true
systemctl --user reset-failed pulseaudio.service 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now wispr-virtmic.service wispr-browser.service wispr-server.service
systemctl --user enable --now wispr-virtmic-check.timer wispr-browser-restart.timer

echo "installed. units:"
systemctl --user is-active wispr-virtmic.service wispr-browser.service wispr-server.service
echo "timers:"
systemctl --user is-active wispr-virtmic-check.timer wispr-browser-restart.timer
