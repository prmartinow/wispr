#!/usr/bin/env bash
# Shared Chromium resolver for wispr browser services. Playwright cache versions change
# over time (chromium-1217, chromium-1223, ...), so services must not pin one version.

resolve_wispr_chrome() {
  local candidate root

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
    for root in ${WISPR_PLAYWRIGHT_BROWSERS_ROOTS:-"$HOME/.cache/ms-playwright"}; do
      [ -d "$root" ] && find "$root" -type f -path '*/chromium-*/chrome-linux*/chrome' 2>/dev/null
    done | sort -Vr
  )

  candidate="$(node -e '
const mod = process.env.WISPR_PLAYWRIGHT_CORE_PATH || "playwright-core";
const p = require(mod);
console.log(p.chromium.executablePath());
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
