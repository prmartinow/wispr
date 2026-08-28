#!/usr/bin/env bash
# Shared Chromium resolver for wispr browser services. Playwright cache versions change
# over time (chromium-1217, chromium-1223, ...), so services must not pin one version.

resolve_wispr_chrome() {
  local candidate root roots

  if [ -n "${WISPR_CHROME:-}" ] && [ -x "$WISPR_CHROME" ]; then
    printf '%s\n' "$WISPR_CHROME"
    return 0
  fi

  while IFS= read -r candidate; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(
    roots="${WISPR_PLAYWRIGHT_BROWSERS_ROOTS:-"$HOME/.cache/ms-playwright"}"
    roots="${roots//:/ }"
    for root in $roots; do
      [ -d "$root" ] && find "$root" -type f -path '*/chromium-*/chrome-linux*/chrome' 2>/dev/null
    done | sort -Vr
  )

  candidate="$(node -e '
const candidates = [
  process.env.WISPR_PLAYWRIGHT_CORE_PATH,
  process.env.WISPR_PLAYWRIGHT_PACKAGE,
  "rebrowser-playwright-core",
  "playwright-core",
].filter(Boolean);
for (const mod of candidates) {
  try {
    const p = require(mod);
    console.log(p.chromium.executablePath());
    process.exit(0);
  } catch (_) {}
}
process.exit(1);
' 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in chromium chromium-browser google-chrome google-chrome-stable chrome; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done

  return 1
}

configure_wispr_chrome_env() {
  CHROME="$(resolve_wispr_chrome)" || {
    echo "wispr: no executable Chromium/Chrome found" >&2
    return 127
  }
  export CHROME

  local sandbox="${WISPR_CHROME_SANDBOX:-$(dirname "$CHROME")/chrome_sandbox}"
  if [ -x "$sandbox" ]; then
    export CHROME_DEVEL_SANDBOX="$sandbox"
  else
    unset CHROME_DEVEL_SANDBOX
  fi

  echo "wispr: using Chromium at $CHROME" >&2
}

sanitize_wispr_profile_clean_exit() {
  local prof="${1:-}"
  [ -n "$prof" ] || return 0
  local pref="$prof/Default/Preferences"
  if [ -f "$pref" ]; then
    python3 -c "
import json, sys
pref_path = sys.argv[1]
try:
    with open(pref_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    changed = False
    if 'profile' in data and isinstance(data['profile'], dict):
        if data['profile'].get('exit_type') != 'Normal' or data['profile'].get('exited_cleanly') is not True:
            data['profile']['exit_type'] = 'Normal'
            data['profile']['exited_cleanly'] = True
            changed = True
    if changed:
        with open(pref_path, 'w', encoding='utf-8') as f:
            json.dump(data, f)
except Exception:
    pass
" "$pref" 2>/dev/null || true
  fi
}
