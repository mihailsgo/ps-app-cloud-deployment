# 1. Release Snapshot

> This file describes what each released tag *contains*. The minimum tag a given
> capability *requires* lives in `release/capabilities.json`, which `upgrade.sh`
> and `toggle-features.sh` read at run time - cite that file rather than copying
> a number out of it. The exact `sha256` digest approved for each tag below lives
> in `release/approved-digests.json` - cite that file rather than copying a
> digest out of it. See [39. Release Procedure](39-release-procedure.md).

Every image `docker-compose.yml` references is pinned `tag@sha256:digest`, not
by tag alone; `installation-scripts/validate-config.sh` fails a deployment
whose pin doesn't match `release/approved-digests.json`.

- `ps-server`: `mihailsgordijenko/ps-server:3.28` (first `ps-server` image built and stamped with `scripts/build-image.sh` — carries `org.opencontainers.image.{version,revision,source,created}` labels, so `docker inspect` recovers the exact source commit; earlier tags predate the stamping and carry no labels. Also fixes three receive-back correctness bugs: `GET /signedPdf` now returns `410` instead of a misnamed archive-fallback copy once a document's buffer sidecar is gone, rather than landing an unidentifiable file on the desktop (#21); restart recovery (`rebuildFromDisk`) now walks every *enabled* filesystem routing strategy instead of only the first, so a per-company deployment with more than one filesystem strategy no longer silently loses pending entries under the second and later base paths on restart (#19); and a signed filename containing non-ASCII characters (e.g. Latvian diacritics) no longer 500s `GET /signedPdf` and gets stuck undeliverable forever — the response is now ASCII-safe (`Content-Disposition` `filename=` plus an RFC 5987 `filename*` carrying the true name) and streamed with `Content-Length` instead of buffered (#16, #22). Retains the signed-PDF **receive-back** buffer + endpoints from `:3.27` — `GET /api/signedPdf/pending`, `GET /api/signedPdf`, `POST /api/signedPdf/ack`, only returning documents when `DOCUMENT_ROUTING.enabled` + the `filesystem` strategy are enabled — and the `STAMP_MODE` local e-sealing dispatch from `:3.26`. See `documentation/35-receive-back-deployment-runbook.md`.)
- `ps-client`: `mihailsgordijenko/ps-client:8.39` (first `ps-client` image built and stamped with `scripts/build-image.sh`, so `docker inspect` recovers the source commit; earlier tags predate the stamping and carry no labels. Also carries an internal refactor — de-duplicated `ServerOffline` component/CSS and a `documentData` → `documentSource` rename in `PdfRenderComponent` — with no user-facing behaviour change. Retains the Keycloak-Bearer-token archive-PDF download from `:8.38`, which downloads archive PDFs with the user's Bearer token and feeds the viewer base64 so `GET /archive/api/document/{docid}/download` can be closed behind authentication at nginx (see `documentation/22-security-and-route-protection.md`; capability `closable-download-route`, `release/capabilities.json`) — and the automatic dark-mode support from `:8.37`.)
- Keycloak: `quay.io/keycloak/keycloak:26.7.4`
- DMSS Archive: `trustlynx/dmss-archive-services:24.3.0.3`
- DMSS Container/Signature: `trustlynx/container-signature-service:24.3.0.29`, reverted from 24.3.3.9. Newer tags either needed `spring.mail.*` just to start (24.3.3.9; `application.yml` now sets a placeholder, which gets it to UP but not to sealing), can't reach the stamping company (24.3.0.35, 24.3.0.37-24.3.0.40), or seal the B_BES `LocalDemo` profile once and then treat it as LT, which needs a TSA (24.3.0.43-24.3.3.9, including 24.3.0.49, which earlier releases pinned). 24.3.0.30, 24.3.0.34 and 24.3.0.36 also pass `installation-scripts/dmss-seal-smoke.sh`, but 24.3.0.29 is the build psapp's dev stack already runs with an otherwise-identical config. Details: `release/approved-digests.json`'s `why`.
- DMSS Archive fallback: `trustlynx/dmss-archive-services-fallback:24.1.7`
- DMSS Digital Stamping (local e-sealing only, `local-eseal` compose profile): `trustlynx/digital-stamping-service:24.0.3.1`
- Nginx: `nginx:1.30.5` — pinned to the `stable` release line, not `latest`/`mainline` (which tracks new features, not what nginx recommends for production).
- Deployment wizard (`wizard` compose profile): `mihailsgordijenko/padsign-wizard:0.1.1`

