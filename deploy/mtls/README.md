# Remote access: VPS Caddy bridge + mTLS

Remote (off-LAN) clients reach the server over the internet via the existing VPS + WireGuard edge:

```
client → https://wispr.p12w.xyz  (VPS Caddy: auto-TLS + REQUIRED client cert)
       → WireGuard (VPS vpn.local → home router → rpc)
       → http://wispr.local:8090  (wispr server)
```

- **rpc ufw:** only the VPS WG peer `vpn.local` may reach `8090` over WG (plus the LAN rules).
- **mTLS:** Caddy `client_auth mode require_and_verify` against `wispr-client-ca.crt`. No client
  cert ⇒ TLS handshake rejected before the request reaches wispr. IP-independent (roams on any
  wifi/SIM). The 192-bit bearer token still applies at the app layer (defense in depth).
- **LAN path:** `https://wispr.local:8443` direct to rpc with required client cert and pinned
  server trust. It stays on the LAN; it does not detour through the VPS.

## Files here (public, safe to commit)
- `wispr-client-ca.crt` — the client-auth CA's public cert (installed on the VPS at
  `/etc/caddy/wispr-clients-ca.crt`).
- `wispr.caddy` — the Caddy vhost block (appended to `/etc/caddy/Caddyfile`).

## Private material (OFF-repo, never commit)
- Mac/offline only: `ca.key`, Mac client key, P12, and P12 password.
- rpc runtime only: `ca.crt`, `rpc-server.crt`, and `rpc-server.key`.

The rpc must not retain the CA private key or Mac client private material.

## Issue a client cert for a new device
```bash
cd <offline-or-mac-only-ca-dir>
openssl genrsa -out DEVICE.key 2048
openssl req -new -key DEVICE.key -subj "/CN=DEVICE" -out DEVICE.csr
openssl x509 -req -in DEVICE.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 -sha256 -out DEVICE.crt
openssl pkcs12 -export -name DEVICE -out DEVICE.p12 \
  -inkey DEVICE.key -in DEVICE.crt -certfile ca.crt \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout pass:PASS
```
(The same CA is trusted by Caddy and by the rpc LAN mTLS listener.)

On macOS, import the client cert/key into the login Keychain without `-A`; the app pins the expected
subject/issuer/fingerprints and should prompt only when it first needs the private key.
