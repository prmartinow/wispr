#!/usr/bin/env bash
# Contract test — the "running system is the source of truth" check from COORDINATION.md.
# Runs from the Mac against the live server and fails loudly if the two halves have drifted:
# wrong audio format, missing/!200 healthz, missing auth, or a response that doesn't match
# CONTRACT.md (must contain a "text" field).
#
# Bonus: it generates a REAL spoken 48 kHz/mono/s16 WAV using macOS `say`+`afconvert`, i.e.
# exactly the external recording the server agent needs to validate dictation service dictation.
#
# Usage:
#   WHISPER_SERVER_URL=http://wispr.local:8080 WHISPER_TOKEN=... ./scripts/contract-test.sh
#   ./scripts/contract-test.sh --keep-wav /tmp/rpc-dictation-test.wav   # also save the clip
set -euo pipefail

URL="${WHISPER_SERVER_URL:-http://wispr.local:8090}"
TOKEN="${WHISPER_TOKEN:-}"
PHRASE="${WHISPER_TEST_PHRASE:-rpc dictation test successful}"
OUT_WAV=""
[ "${1:-}" = "--keep-wav" ] && OUT_WAV="${2:?path required after --keep-wav}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
wav="${OUT_WAV:-$tmp/clip.wav}"

echo "▸ generating spoken WAV (48k/mono/s16): \"$PHRASE\""
say -o "$tmp/clip.aiff" "$PHRASE"
afconvert -f WAVE -d LEI16@48000 -c 1 "$tmp/clip.aiff" "$wav"
echo "  $(afinfo "$wav" | awk -F': ' '/Data format/{print $2}')"
[ -n "$OUT_WAV" ] && echo "  saved clip → $OUT_WAV"

echo "▸ GET $URL/healthz"
code="$(curl -sS -o "$tmp/health.json" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" "$URL/healthz" || echo 000)"
echo "  HTTP $code  $(cat "$tmp/health.json" 2>/dev/null)"
[ "$code" = "200" ] || { echo "✗ healthz not 200 (server up? token? bound to LAN?)"; exit 1; }

echo "▸ POST $URL/transcribe  (multipart audio=$wav)"
code="$(curl -sS -o "$tmp/resp.json" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  -F "audio=@$wav;type=audio/wav;filename=audio.wav" \
  "$URL/transcribe" || echo 000)"
echo "  HTTP $code"
cat "$tmp/resp.json"; echo
[ "$code" = "200" ] || { echo "✗ transcribe not 200"; exit 1; }

if command -v jq >/dev/null 2>&1; then
  jq -e 'has("text") and (.text|type=="string")' "$tmp/resp.json" >/dev/null \
    || { echo "✗ response missing string \"text\" field (see contract/transcribe.md)"; exit 1; }
  echo "✓ contract OK — transcript: $(jq -r '.text' "$tmp/resp.json")"
else
  grep -q '"text"' "$tmp/resp.json" \
    || { echo "✗ response missing \"text\" field (see contract/transcribe.md)"; exit 1; }
  echo "✓ contract OK (install jq for full validation)"
fi
