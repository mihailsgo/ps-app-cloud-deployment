# PS-APP Cloud Deployment

This repository contains infrastructure and runtime configuration for deploying PS-APP without application source code.

## Current Container Versions

- `mihailsgordijenko/ps-server:3.4`
- `mihailsgordijenko/ps-client:8.4`
- `quay.io/keycloak/keycloak:26.3.2`
- `trustlynx/dmss-archive-services:24.2.0.8`
- `trustlynx/container-signature-service:24.3.0.29`
- `trustlynx/dmss-archive-services-fallback:24.0.5`

## Architecture

- `nginx` is the public entry point (`80/443`).
- `ps-client` serves the SPA at `/portal`.
- `ps-server` provides `/api/*` endpoints.
- `keycloak` handles interactive user authentication.
- DMSS services provide archive/signature backend integration.

## Runtime Configuration Files

- `config/config.js` -> mounted to `ps-server`.
- `config/constants.json` -> mounted to `ps-client`.
- `config/TLlogo.png` -> client branding logo.
- `nginx/nginx.conf` and `nginx/certs/*` -> TLS and reverse proxy config.

## Auth Model (Important)

### External 3rd-party integration (API key)
Uses `Authorization: Bearer <REGISTER_PDF_API_KEY>` from `config/config.js`:

- `GET /api/registerUser`
- `GET /api/registerUserPDF`
- `POST /api/registerPDF`
- `GET /api/removeUser`

### Internal app flow (Keycloak token)
Used by logged-in device manager session:

- `GET /api/latestUser`
- `POST /api/fillPDF`
- `POST /api/fillPDFDemo`
- `PUT /api/visual-signature`
- `POST /api/stamp`
- `GET /api/cleanupUser`
- `POST /api/demo/upload`
- `POST /api/demo/upload/version`

`cleanupUser` is for internal session cleanup. `removeUser` is for external integration cleanup.

## Reliability and Hardening (already included in server 3.4)

- Bounded in-memory queue for `registerPDF`.
- Configurable concurrency/timeouts/retries for upstream archive calls.
- Circuit breaker protection for unstable dependencies.
- Per-document lock + idempotency support for sign/stamp operations.
- In-memory user state TTL cleanup (no external DB required).
- Correlation ID propagation for troubleshooting (`X-Correlation-Id`).

## DEMO Mode

Configured in `config/constants.json`:

- `DEMO_MODE`: `ENABLE` or `DISABLE`
- `PS_API_DEMO_UPLOAD`
- `PS_API_DEMO_UPLOAD_VERSION`
- `PS_API_DEMO_FILL_BY_DOCID`

When enabled, DEMO upload/sign flow is available for testing and behaves differently from production registration flow.

## Deployment

From this folder:

```bash
docker compose pull
docker compose up -d
```

Validate compose:

```bash
docker compose config
```

Check status:

```bash
docker compose ps
```

## Smoke Tests

### 1) External registerPDF flow

```bash
curl -X POST "https://padsign.trustlynx.com/api/registerPDF" \
  -H "Authorization: Bearer <REGISTER_PDF_API_KEY>" \
  -H "Accept: application/json" \
  --fail-with-body \
  -F "file=@1.pdf;type=application/pdf" \
  -F "email=user@example.com" \
  -F "company=Trustlynx" \
  -F "clientName=John Average"
```

Expected: `201` and `docId` in response.

### 2) Internal latest user lookup

From logged-in app session, call `GET /api/latestUser?email=user@example.com&company=Trustlynx`.
Expected: entry with matching `doc` and optional `clientName`.

### 3) External cleanup for next patient

Call `GET /api/removeUser?...` with API key to clean integration-side user state.

## Notes

- User/session state is intentionally in-memory and will be lost on restart.
- `PRIVILEGED_API_ROLES` is only needed if specific Keycloak roles should bypass strict ownership checks on internal cleanup.
- Keep secrets in `config/config.js` controlled and rotated by your deployment process.
