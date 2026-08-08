# OPENCLAW_API

The localhost REST API v1 is a general-purpose local entry point; OpenClaw is
one optional client. Full usage docs + curl examples + JSON schema + skill
example: [extras/openclaw/](../../extras/openclaw/README.md).

## Summary

- Server: `LocalAPIServer` (port 8421), started at app launch only when the
  `localAPIv1` feature flag is enabled. GUI never depends on it.
- Bind: `127.0.0.1` enforced via `NWParameters.requiredLocalEndpoint`.
- Auth: installation token (`~/Library/Application Support/LTXVideoGenerator/api_token`,
  mode 0600), constant-time compare, required on every endpoint.
- No CORS headers at all (no wildcard CORS).
- Request cap 48 MB; asset cap 32 MB; PNG/JPEG magic-byte check.
- Asset indirection: `POST /v1/assets` → server-issued UUID; job requests may
  only reference `input.assetID`. Traversal/absolute/non-UUID IDs rejected via
  canonicalized sandbox check (unit-tested).
- `variations` capped at 20; all generation flows through the single-flight
  GenerationService (concurrency 1).
- Adult policy: `adultMode` in a job is honored only when the app's Adult
  Content Mode is also ON; unverified/unknown/blocked models rejected (403).

## Endpoints

POST /v1/assets · POST /v1/jobs · GET /v1/jobs/{id} · DELETE /v1/jobs/{id} ·
GET /v1/models · GET /v1/system · GET /v1/history

The legacy APIServer (port 8420, /generate) is untouched for backward
compatibility; v1 is the recommended surface.
