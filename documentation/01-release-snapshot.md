# 1. Release Snapshot

- `ps-server`: `mihailsgordijenko/ps-server:3.27` (adds the signed-PDF **receive-back** buffer + endpoints — `GET /api/signedPdf/pending`, `GET /api/signedPdf`, `POST /api/signedPdf/ack` — that the Padsign Manager polls to pull a signed PDF back onto the originating desktop; retains the `STAMP_MODE` local e-sealing dispatch from `:3.26`. The endpoints are always present but only return documents when `DOCUMENT_ROUTING.enabled` + the `filesystem` strategy are enabled. See `documentation/35-receive-back-deployment-runbook.md`.)
- `ps-client`: `mihailsgordijenko/ps-client:8.38` (downloads archive PDFs with the user's Keycloak Bearer token and feeds the viewer base64, so `GET /archive/api/document/{docid}/download` can be closed behind authentication at nginx — see `documentation/22-security-and-route-protection.md`; earlier tags fetch that URL anonymously and need it publicly reachable. Retains the automatic dark-mode support from `:8.37`.)
- Keycloak: `quay.io/keycloak/keycloak:26.3.2`
- DMSS Archive: `trustlynx/dmss-archive-services:24.2.0.8`
- DMSS Container/Signature: `trustlynx/container-signature-service:24.3.0.49`
- DMSS Archive fallback: `trustlynx/dmss-archive-services-fallback:24.0.5`

