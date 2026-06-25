# wispr

Wispr is a macOS dictation client plus a small Node backend. The Mac records
audio, sends it to the backend over HTTPS/mTLS, and inserts the returned text
into the focused app.

## Layout

- `client-macos/` - Swift/AppKit menu bar and Dock app.
- `server/` - Node HTTP/WebSocket service and dictation-service browser driver.
- `contract/` - batch and streaming API contracts.
- `deploy/` - systemd user-unit templates and RPC deployment helpers.
- `docs/` - implementation notes that are safe to keep with the source.

Runtime state does not belong in this repo. On the RPC host, production state
uses an app-owned root such as `$HOME/.wispr` for env files, browser profiles,
mTLS material, VNC auth, and logs. On macOS, app data lives under
`~/Library/Application Support/wispr` and logs under `~/Library/Logs/wispr`.

## Configuration

Copy `server/.env.example` to a private env file and fill in the deployment
values:

```bash
install -d -m 700 "$HOME/.wispr/env"
cp server/.env.example "$HOME/.wispr/env/server.env"
chmod 600 "$HOME/.wispr/env/server.env"
```

The production systemd templates read `%h/.wispr/env/server.env`. Local
development may still use `server/.env`, which is gitignored.

The macOS client reads the server URL from Settings or from `WISPR_SERVER_URL`
on first launch. The bearer token and client mTLS files are stored outside the
repo with private permissions.
