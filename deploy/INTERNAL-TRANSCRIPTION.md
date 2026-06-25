# Internal Transcription Calls

Internal callers should use the authenticated batch endpoint over HTTPS/mTLS.
The endpoint, token, and certificate paths are deployment configuration, not
repo state.

Example:

```bash
curl --cacert "$WISPR_MTLS_DIR/ca.crt" \
     --cert  "$WISPR_MTLS_DIR/wispr-internal-client.crt" \
     --key   "$WISPR_MTLS_DIR/wispr-internal-client.key" \
     -H "Authorization: Bearer $WISPR_BEARER_TOKEN" \
     -F "audio=@clip.wav;type=audio/wav;filename=audio.wav" \
     "$WISPR_SERVER_URL/transcribe"
```

Use the same WAV format as the public contract: mono, 16-bit PCM, 48 kHz.
Keep tokens, private keys, generated certs, uploaded clips, and transcripts out
of Git.
