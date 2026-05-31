#!/usr/bin/env bash
# Ensure a PulseAudio daemon is up and the wispr virtual mic exists. Idempotent.
# wispr owns the pulse daemon (the system pulseaudio.service/socket are disabled to avoid
# the autospawn-vs-service pid-file race). Run by wispr-virtmic.service at boot.
set -uo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# 1) ensure a daemon is reachable
if ! pactl info >/dev/null 2>&1; then
  pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
fi
for i in $(seq 1 30); do pactl info >/dev/null 2>&1 && break; sleep 1; done
pactl info >/dev/null 2>&1 || { echo "pulseaudio not reachable" >&2; exit 1; }

# 2) virtual mic: null-sink "virtmic" + remap its monitor to a capture source "virtmic_in" (idempotent)
pactl list short modules 2>/dev/null | grep -q 'sink_name=virtmic' || \
  pactl load-module module-null-sink sink_name=virtmic sink_properties=device.description=VirtualMicSink >/dev/null
pactl list short modules 2>/dev/null | grep -q 'source_name=virtmic_in' || \
  pactl load-module module-remap-source master=virtmic.monitor source_name=virtmic_in source_properties=device.description=VirtualMic >/dev/null

pactl set-default-source virtmic_in
pactl set-sink-volume virtmic 100% >/dev/null 2>&1 || true
pactl set-source-volume virtmic_in 100% >/dev/null 2>&1 || true
echo "virtmic ready (default-source=$(pactl get-default-source))"
