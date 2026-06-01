# Deploying the wispr server (persistent)

Runs the backend as `systemctl --user` units. `ops` has **linger** enabled, so they start at boot
and `Restart=always` auto-recovers crashes.

Three units (boot order via `After`/`Wants`): `wispr-virtmic` → `wispr-browser` → `wispr-server`.
- **`wispr-virtmic.service`** — oneshot that runs `setup-virtmic.sh`: starts a PulseAudio daemon and
  loads the virtual mic (null-sink `virtmic` + capture source `virtmic_in`). wispr **owns** the pulse
  daemon; the system `pulseaudio.service`/`.socket` are **masked** (they race it → `pa_pid_file_create`).
  Revert with `systemctl --user unmask pulseaudio.socket pulseaudio.service`.
- **`wispr-browser.service`** — dedicated **dictation service-only** Chromium on `DISPLAY=:95`, CDP `:9223`,
  profile `~/wispr-service-profile` (logged into dictation service once; the session persists in the profile).
  Chromium runs with its setuid sandbox helper; heavier unit sandboxing is limited by that requirement.
- **`wispr-server.service`** — the Node server on HTTP `:8090` for the VPS bridge and LAN mTLS
  `:8443` for direct Mac access (`POST /transcribe` + WS `/v1/stream`).
- **`vnc-xvfb` / `vnc-x11vnc` / `vnc-novnc`** — persistent browser display. `x11vnc` is bound to
  localhost only; noVNC is served by websockify on `:6083` over HTTPS with required client cert.

## Install / refresh
```bash
./install.sh
```

## Operate
```bash
systemctl --user status wispr-virtmic wispr-browser wispr-server
systemctl --user restart wispr-server
journalctl --user -u wispr-server -f
```

## Notes
- If the dictation service session expires, re-login via noVNC at
  `https://wispr.local:6083/vnc.html?host=wispr.local&port=6083&encrypt=1` (display `:95`) —
  the fresh profile then persists the new session. This works from local LAN and from the Mac's
  WireGuard path to `wispr.local`; the browser must present the wispr client certificate.
- The chrome binary + `playwright-core` paths are pinned to this rpc host.
