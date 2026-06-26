#!/usr/bin/env bash
# Ensure a PulseAudio daemon is up and the wispr virtual mic exists. Idempotent.
# wispr owns the pulse daemon (the system pulseaudio.service/socket are disabled to avoid
# the autospawn-vs-service pid-file race). Run by wispr-virtmic.service at boot.
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# 1) ensure a daemon is reachable
if ! pactl info >/dev/null 2>&1; then
  pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
fi
for i in $(seq 1 30); do pactl info >/dev/null 2>&1 && break; sleep 1; done
pactl info >/dev/null 2>&1 || { echo "pulseaudio not reachable" >&2; exit 1; }

PA_RATE="${WISPR_PULSE_RATE:-48000}"
PA_CHANNELS="${WISPR_PULSE_CHANNELS:-1}"
PA_CHANNEL_MAP="${WISPR_PULSE_CHANNEL_MAP:-mono}"
PA_SPEC="s16le ${PA_CHANNELS}ch ${PA_RATE}Hz"

module_ids_matching() {
  local regex="$1"
  pactl list short modules 2>/dev/null | awk -v pat="$regex" '$0 ~ pat { print $1 }'
}

unload_modules_matching() {
  local regex="$1"
  module_ids_matching "$regex" | sort -rn | while read -r id; do
    [ -n "$id" ] && pactl unload-module "$id" >/dev/null 2>&1 || true
  done
}

device_spec() {
  local kind="$1" name="$2"
  pactl list short "$kind" 2>/dev/null | awk -v name="$name" '$2 == name { print $4 " " $5 " " $6; exit }'
}

ensure_virtual_mic() {
  local sink="$1" source="$2" sink_desc="$3" source_desc="$4"
  local sink_re="sink_name=${sink}([[:space:]]|$)"
  local source_re="source_name=${source}([[:space:]]|$)"
  local sink_spec source_spec
  sink_spec="$(device_spec sinks "$sink")"
  source_spec="$(device_spec sources "$source")"

  if [ -n "$sink_spec" ] && [ "$sink_spec" != "$PA_SPEC" ]; then
    unload_modules_matching "$source_re"
    unload_modules_matching "$sink_re"
  elif [ -n "$source_spec" ] && [ "$source_spec" != "$PA_SPEC" ]; then
    unload_modules_matching "$source_re"
  fi

  module_ids_matching "$sink_re" | grep -q . || \
    pactl load-module module-null-sink \
      sink_name="$sink" rate="$PA_RATE" channels="$PA_CHANNELS" channel_map="$PA_CHANNEL_MAP" \
      sink_properties="device.description=${sink_desc}" >/dev/null
  module_ids_matching "$source_re" | grep -q . || \
    pactl load-module module-remap-source \
      master="${sink}.monitor" source_name="$source" channels="$PA_CHANNELS" channel_map="$PA_CHANNEL_MAP" \
      source_properties="device.description=${source_desc}" >/dev/null

  pactl set-sink-volume "$sink" 100% >/dev/null 2>&1 || true
  pactl set-source-volume "$source" 100% >/dev/null 2>&1 || true
}

# 2) virtual mic: null-sink "virtmic" + remap its monitor to a capture source "virtmic_in" (idempotent)
ensure_virtual_mic virtmic virtmic_in VirtualMicSink VirtualMic

pactl set-default-source virtmic_in
pactl set-default-sink virtmic >/dev/null 2>&1 || true

# 3) per-lane virtual mics for the internal batch pool: virtmic{k} (null-sink) -> virtmic{k}_in
#    (remap source). Each lane's Chromium reads its own one via PULSE_SOURCE. Idempotent.
HERE_SV="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE_SV/lanes.env" ] && source "$HERE_SV/lanes.env"
for k in $(seq 1 "${WISPR_LANES:-0}"); do
  ensure_virtual_mic "virtmic${k}" "virtmic${k}_in" "VirtualMicSink${k}" "VirtualMic_${k}"
done

echo "virtmic ready (default-source=$(pactl get-default-source), spec=${PA_SPEC}, lanes=${WISPR_LANES:-0})"
