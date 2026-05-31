# Remote access: VPS Caddy bridge + mTLS

Remote (off-LAN) clients reach the server over the internet via the existing VPS + WireGuard edge:

```
client → https://wispr.p12w.xyz  (VPS Caddy: auto-TLS + REQUIRED client cert)
       → WireGuard (VPS vpn.local → home router → rpc)
       → http://wispr.local:8090  (whisper server)
```

- **rpc ufw:** only the VPS WG peer `vpn.local` may reach `8090` over WG (plus the LAN rules).
- **mTLS:** Caddy `client_auth mode require_and_verify` against `whisper-client-ca.crt`. No client
  cert ⇒ TLS handshake rejected before the request reaches whisper. IP-independent (roams on any
  wifi/SIM). The 192-bit bearer token still applies at the app layer (defense in depth).
- **LAN path is unchanged** — `http://wispr.local:8090` direct, bypasses Caddy/mTLS (trusted LAN).

## Files here (public, safe to commit)
- `whisper-client-ca.crt` — the client-auth CA's public cert (installed on the VPS at
  `/etc/caddy/whisper-clients-ca.crt`).
- `whisper.caddy` — the Caddy vhost block (appended to `/etc/caddy/Caddyfile`).

## Private material (OFF-repo, on rpc at `~/.wispr/mtls/`, never commit)
`ca.key` (CA private key — issues new client certs), `mac-client.{key,crt,p12}`, `p12.pass`.

## Issue a client cert for a new device
```bash
cd ~/.wispr/mtls
openssl genrsa -out DEVICE.key 2048
openssl req -new -key DEVICE.key -subj "/CN=DEVICE" -out DEVICE.csr
openssl x509 -req -in DEVICE.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 -sha256 -out DEVICE.crt
openssl pkcs12 -export -out DEVICE.p12 -inkey DEVICE.key -in DEVICE.crt -certfile ca.crt -passout pass:PASS
```
(The same CA already trusted by Caddy — no VPS change needed for new devices.)
