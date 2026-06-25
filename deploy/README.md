# Deploying Wispr

The RPC deployment runs as `systemctl --user` units. The code lives in the repo;
runtime state lives outside the repo.

Default runtime layout:

```text
$HOME/.wispr/
  env/server.env
  mtls/
  profiles/service/
  profiles/lanes/
  vnc/auth/
  logs/
```

## Services

- `wispr-virtmic.service` creates the PulseAudio virtual microphone.
- `wispr-browser.service` runs the main dictation-service Chromium lane on
  `DISPLAY=:95`, CDP `127.0.0.1:9223`.
- `wispr-lane@N.service` runs internal batch lanes on CDP `9223+N`.
- `wispr-server.service` exposes batch `POST /transcribe`, streaming
  `/v1/stream`, and health endpoints.
- `vnc-xvfb`, `vnc-x11vnc`, and `vnc-novnc` provide the browser display. Raw
  VNC stays localhost-only; noVNC uses HTTPS with required client certs.

## Install / Refresh

```bash
./install.sh
```

`install.sh` creates the runtime directories with private permissions, installs
the user units, prepares the Chromium sandbox, provisions internal mTLS
material, and enables the services.

## Required Private Configuration

`$HOME/.wispr/env/server.env` should define at least:

```bash
WISPR_BEARER_TOKEN=replace-me
DICTATION_SERVICE_URL=https://dictation.example.com/
WISPR_PLAYWRIGHT_CORE_PATH=/absolute/path/to/playwright-core
WISPR_PLAYWRIGHT_BROWSERS_ROOTS=/absolute/path/to/ms-playwright
```

Deployment-specific hostnames, private IPs, tokens, browser profiles, VNC
passwords, and mTLS private keys stay outside Git.
