#!/usr/bin/env bash
# Provision internal lane profiles by cloning the logged-in service profile WITHOUT its caches, so
# each clone is ~tens of MB instead of ~1.6 GB. Idempotent: re-running refreshes login/cookie state.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lanes.env"
SRC=~/.wispr/profiles/service
N="${WISPR_LANES:-0}"

[ -d "$SRC" ] || { echo "source profile $SRC missing" >&2; exit 1; }

# Cache / ephemeral dirs Chromium rebuilds on its own — excluded to keep clones tiny.
EXCLUDES=(
  --exclude='Singleton*' --exclude='*/Singleton*'
  --exclude='Default/Cache' --exclude='Default/Code Cache' --exclude='Default/GPUCache'
  --exclude='Default/DawnGraphiteCache' --exclude='Default/DawnWebGPUCache'
  --exclude='Default/Service Worker/CacheStorage' --exclude='Default/Service Worker/ScriptCache'
  --exclude='GraphiteDawnCache' --exclude='GPUPersistentCache' --exclude='ShaderCache'
  --exclude='GrShaderCache' --exclude='component_crx_cache' --exclude='extensions_crx_cache'
  --exclude='Safe Browsing' --exclude='*/Cache' --exclude='*/Code Cache' --exclude='*/GPUCache'
)
for k in $(seq 1 "$N"); do
  DST="~/.wispr/profiles/lanes/${k}-profile"
  mkdir -p "$DST"
  rsync -a --delete "${EXCLUDES[@]}" "$SRC"/ "$DST"/
  rm -f "$DST"/Singleton* "$DST"/Default/Singleton* 2>/dev/null || true
  echo "lane $k profile: $(du -sh "$DST" 2>/dev/null | cut -f1) ($DST)"
done
echo "provisioned $N lane profile(s) from $SRC"
