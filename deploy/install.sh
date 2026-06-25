#!/usr/bin/env bash
# Install/refresh the wispr service as persistent systemd --user units.
# ops has linger enabled, so these start at boot. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WISPR_STATE_DIR="${WISPR_STATE_DIR:-$HOME/.wispr}"
mkdir -p "$WISPR_STATE_DIR/env" "$WISPR_STATE_DIR/mtls" \
         "$WISPR_STATE_DIR/profiles/service" "$WISPR_STATE_DIR/profiles/lanes" \
         "$WISPR_STATE_DIR/vnc/auth" "$WISPR_STATE_DIR/logs"
chmod 700 "$WISPR_STATE_DIR" "$WISPR_STATE_DIR/env" "$WISPR_STATE_DIR/mtls" \
          "$WISPR_STATE_DIR/profiles" "$WISPR_STATE_DIR/profiles/service" \
          "$WISPR_STATE_DIR/profiles/lanes" "$WISPR_STATE_DIR/vnc" \
          "$WISPR_STATE_DIR/vnc/auth" "$WISPR_STATE_DIR/logs"
if [ -f "$WISPR_STATE_DIR/env/server.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$WISPR_STATE_DIR/env/server.env"
  set +a
fi
mkdir -p "$HOME/.config/systemd/user"
chmod +x "$HERE/setup-virtmic.sh" "$HERE/setup-lanes.sh" "$HERE/wispr-lane.sh" \
         "$HERE/wispr-browser.sh" "$HERE/chrome-paths.sh" "$HERE/prepare-chrome-sandbox.sh" \
         "$HERE/setup-internal-mtls.sh"
# shellcheck disable=SC1091
source "$HERE/lanes.env"
# shellcheck disable=SC1091
source "$HERE/chrome-paths.sh"

"$HERE/prepare-chrome-sandbox.sh" || echo "warn: Chromium setuid sandbox is not ready; browser service may fail" >&2

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

# Internal mTLS identity + client-trust bundle MUST exist before the server starts (LAN_TLS_CA points
# at the bundle and REQUIRE_LAN_MTLS=1 makes a missing file fatal). Idempotent.
"$HERE/setup-internal-mtls.sh"

systemctl --user enable --now vnc-xvfb.service vnc-x11vnc.service vnc-novnc.service
systemctl --user enable --now wispr-virtmic.service wispr-browser.service wispr-server.service
systemctl --user enable --now wispr-virtmic-check.timer wispr-browser-restart.timer

# Internal batch lanes: re-run the (idempotent) virtmic setup so the per-lane mics exist. Browser
# units are PartOf=wispr-virtmic.service so they restart after a mic rebuild and re-enumerate devices.
systemctl --user restart wispr-virtmic.service
"$HERE/setup-lanes.sh"
for k in $(seq 1 "${WISPR_LANES:-0}"); do
  systemctl --user enable --now "wispr-lane@$k.service"
done
systemctl --user restart wispr-server.service

echo "installed. units:"
systemctl --user is-active wispr-virtmic.service wispr-browser.service wispr-server.service
echo "vnc:"
systemctl --user is-active vnc-xvfb.service vnc-x11vnc.service vnc-novnc.service
echo "timers:"
systemctl --user is-active wispr-virtmic-check.timer wispr-browser-restart.timer
