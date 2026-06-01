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
  Its mount namespace hides wispr mTLS/runtime secrets.
- **`wispr-server.service`** — the Node server on HTTP `:8090` for the VPS bridge and LAN mTLS
  `:8443` for direct Mac access (`POST /transcribe` + WS `/v1/stream`).

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
- If the dictation service session expires, re-login via noVNC at http://wispr.local:6083 (display `:95`) —
  the fresh profile then persists the new session.
- VNC/noVNC access is intentionally unchanged in this pass; the replacement access design is deferred.
- The chrome binary + `playwright-core` paths are pinned to this rpc host.
