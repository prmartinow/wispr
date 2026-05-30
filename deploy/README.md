# Deploying the whisper server (persistent)

Runs the backend as `systemctl --user` units. `ops` has **linger** enabled, so they start at boot
and `Restart=always` auto-recovers crashes.

Three units (boot order via `After`/`Wants`): `whisper-virtmic` → `whisper-browser` → `whisper-server`.
- **`whisper-virtmic.service`** — oneshot that runs `setup-virtmic.sh`: starts a PulseAudio daemon and
  loads the virtual mic (null-sink `virtmic` + capture source `virtmic_in`). whisper **owns** the pulse
  daemon; the system `pulseaudio.service`/`.socket` are **masked** (they race it → `pa_pid_file_create`).
  Revert with `systemctl --user unmask pulseaudio.socket pulseaudio.service`.
- **`whisper-browser.service`** — dedicated **dictation service-only** Chromium on `DISPLAY=:95`, CDP `:9223`,
  profile `~/whisper-service-profile` (logged into dictation service once; the session persists in the profile).
- **`whisper-server.service`** — the Node server on `:8090` (`POST /transcribe` + WS `/v1/stream`).

## Install / refresh
```bash
./install.sh
```

## Operate
```bash
systemctl --user status whisper-virtmic whisper-browser whisper-server
systemctl --user restart whisper-server
journalctl --user -u whisper-server -f
```

## Notes
- If the dictation service session expires, re-login via noVNC at http://wispr.local:6083 (display `:95`) —
  the fresh profile then persists the new session.
- The chrome binary + `playwright-core` paths are pinned to this rpc host.
