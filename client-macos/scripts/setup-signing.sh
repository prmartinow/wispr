#!/usr/bin/env bash
# Create a dedicated, local code-signing identity so rebuilds keep a STABLE signature.
# macOS TCC (Accessibility, Microphone) grants are keyed to the code identity; ad-hoc
# signatures change identity on every build, so the grants reset each time. With a fixed
# self-signed cert, you grant once and it sticks across rebuilds.
#
# Self-signed and local-only. The keychain password below guards nothing but this dev cert,
# so it's intentionally not a secret. Idempotent: safe to re-run.
set -euo pipefail
CN="Whisper Local Signing"
PW="whisper-local"
KC="$HOME/Library/Keychains/whisper-signing.keychain-db"

if security find-certificate -c "$CN" "$KC" >/dev/null 2>&1; then
  echo "signing identity already present: $CN"
  exit 0
fi

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p "$PW" "$KC"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=%s\n[v3]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$CN" > "$tmp/o.cnf"
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/k.pem" -out "$tmp/c.pem" -days 3650 -nodes -config "$tmp/o.cnf"
security import "$tmp/k.pem" -k "$KC" -A -T /usr/bin/codesign
security import "$tmp/c.pem" -k "$KC" -A -T /usr/bin/codesign
# Let codesign use the key without a GUI prompt (works because WE own this keychain's password).
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
# Keep it on the user keychain search list so codesign can resolve the identity.
security list-keychains -d user -s login.keychain-db "$KC" >/dev/null
echo "created stable signing identity: $CN"
