#!/usr/bin/env bash
# Install/refresh the whisper service as persistent systemd --user units.
# ops has linger enabled, so these start at boot. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.config/systemd/user"
chmod +x "$HERE/setup-virtmic.sh"

cp "$HERE/whisper-virtmic.service" "$HERE/whisper-browser.service" "$HERE/whisper-server.service" \
   "$HERE/whisper-virtmic-check.service" "$HERE/whisper-virtmic-check.timer" \
   "$HERE/whisper-browser-restart.service" "$HERE/whisper-browser-restart.timer" \
   "$HOME/.config/systemd/user/"

# whisper owns the pulse daemon -> mask the system pulse units that race it (pa_pid_file_create).
# Revert with: systemctl --user unmask pulseaudio.socket pulseaudio.service
systemctl --user mask pulseaudio.socket pulseaudio.service 2>/dev/null || true
systemctl --user reset-failed pulseaudio.service 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now whisper-virtmic.service whisper-browser.service whisper-server.service
systemctl --user enable --now whisper-virtmic-check.timer whisper-browser-restart.timer

echo "installed. units:"
systemctl --user is-active whisper-virtmic.service whisper-browser.service whisper-server.service
echo "timers:"
systemctl --user is-active whisper-virtmic-check.timer whisper-browser-restart.timer
