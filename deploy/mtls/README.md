# Remote Access With mTLS

Wispr can be placed behind an HTTPS reverse proxy that requires client
certificates before forwarding requests to the backend.

This directory contains only templates. Real client CAs, private keys, issued
client certificates, hostnames, private IPs, and proxy target addresses belong
in deployment configuration outside Git.

## Template Inputs

- `WISPR_PUBLIC_HOST` - public HTTPS host.
- `WISPR_CLIENT_CA_FILE` - client-auth CA certificate on the proxy host.
- `WISPR_UPSTREAM_URL` - private backend URL reachable by the proxy.

## Client Certs

Issue device certificates from an offline or private CA and install only the
public CA certificate on the proxy. Keep CA private keys and device private
keys out of this repo.
