#!/usr/bin/env bash
# Provision a dedicated internal mTLS identity for on-host services: a separate CA + client cert,
# trusted alongside the existing client CA (so the mac client keeps working) and pinned by
# fingerprint. Internal identity stays separate from the mac client (independently revocable).
# Idempotent. After running: restart wispr-server.
set -euo pipefail
DIR=~/.wispr/mtls
ENVF=~/dev/wispr/server/.env
cd "$DIR"

# 1) internal CA (separate from the existing client CA)
if [ ! -f wispr-internal-ca.crt ]; then
  openssl genrsa -out wispr-internal-ca.key 2048
  openssl req -x509 -new -nodes -key wispr-internal-ca.key -sha256 -days 3650 \
    -subj "/CN=wispr-internal-ca" -out wispr-internal-ca.crt
fi
# 2) internal client cert signed by it
if [ ! -f wispr-internal-client.crt ]; then
  openssl genrsa -out wispr-internal-client.key 2048
  openssl req -new -key wispr-internal-client.key -subj "/CN=wispr-internal-client" -out /tmp/wic.csr
  openssl x509 -req -in /tmp/wic.csr -CA wispr-internal-ca.crt -CAkey wispr-internal-ca.key \
    -CAcreateserial -days 3650 -sha256 -out wispr-internal-client.crt
  rm -f /tmp/wic.csr
fi
chmod 600 wispr-internal-ca.key wispr-internal-client.key

# 3) client-trust bundle = original client CA (mac) + internal CA. LAN_TLS_CA points here.
cat ca.crt wispr-internal-ca.crt > client-ca-bundle.crt

# 4) pin the internal client cert fingerprint (append; keep the mac client's)
FP=$(openssl x509 -in wispr-internal-client.crt -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'a-z' 'A-Z')
echo "internal client cert SHA-256: $FP"
cur=$(grep -E '^MTLS_CLIENT_CERT_SHA256=' "$ENVF" | cut -d= -f2- || true)
if echo "$cur" | tr 'a-z' 'A-Z' | grep -q "$FP"; then
  echo "fingerprint already pinned"
elif grep -qE '^MTLS_CLIENT_CERT_SHA256=' "$ENVF"; then
  sed -i "s|^MTLS_CLIENT_CERT_SHA256=.*|MTLS_CLIENT_CERT_SHA256=${cur:+$cur,}$FP|" "$ENVF"
  echo "appended internal fingerprint to MTLS_CLIENT_CERT_SHA256"
else
  echo "MTLS_CLIENT_CERT_SHA256=$FP" >> "$ENVF"
  echo "added MTLS_CLIENT_CERT_SHA256 with internal fingerprint"
fi

echo "done. Internal callers present:"
echo "  --cert $DIR/wispr-internal-client.crt --key $DIR/wispr-internal-client.key  (server CA: $DIR/ca.crt)"
echo "Restart the server to apply: systemctl --user restart wispr-server"
