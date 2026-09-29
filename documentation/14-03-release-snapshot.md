# 14.3 Release snapshot

The images this release of the deployment package runs. Every image in `docker-compose.yml` is
pinned by tag and `sha256` digest, and `installation-scripts/validate-config.sh` fails if a pin
differs from the approved one in [`release/approved-digests.json`](../release/approved-digests.json).
That file is the authority; if this table and the file ever disagree, the file is right. How approval
and digest pinning work: [14.6 Image approval and digest pinning](14-06-image-approval-and-digest-pinning.md).

| Component | Compose service | Image | Tag |
|---|---|---|---|
| PadSign server (API) | `ps-server` | `mihailsgordijenko/ps-server` | `3.32` |
| PadSign client (web app) | `ps-client` | `mihailsgordijenko/ps-client` | `8.40` |
| Keycloak (identity provider) | `keycloak` | `quay.io/keycloak/keycloak` | `26.7.4` |
| Reverse proxy | `nginx` | `nginx` | `1.30.5` (stable line) |
| DMSS archive | `dmss-archive-services` | `trustlynx/dmss-archive-services` | `24.3.0.3` |
| DMSS container and signature | `dmss-container-and-signature-services` | `trustlynx/container-signature-service` | `24.3.0.29` |
| DMSS fallback archive | `dmss-archive-services-fallback` | `trustlynx/dmss-archive-services-fallback` | `24.1.7` |
| DMSS digital stamping (local e-sealing only, profile `local-eseal`) | `dmss-digital-stamping-service` | `trustlynx/digital-stamping-service` | `24.0.3.1` |
| Deployment Wizard (profile `wizard`) | `wizard` | `mihailsgordijenko/padsign-wizard` | `0.1.1` |

To see what your host actually runs:

```bash
cd /opt/padsign
docker compose images
```

`deployment-evidence.json`, written by every install and upgrade, records the running tag and digest
of each service as well.

## Minimum versions for features

Some features need at least a given image tag. The minimums are in
[`release/capabilities.json`](../release/capabilities.json), which `upgrade.sh` and
`toggle-features.sh` read and enforce; look the numbers up there. The images above meet every
minimum in that file, so this only matters on a host that still runs older images:

| Capability in `capabilities.json` | Feature |
|---|---|
| `local-eseal` | Local e-sealing (`STAMP_MODE`), [10](10-local-e-sealing.md) |
| `receive-back` | Receive-back of signed PDFs to the Virtual Printer / Manager, [11](11-document-routing-and-receive-back.md) |
| `closable-download-route` | Archive PDF download with the user's token, so the download route can be closed at nginx, [6.1](06-01-route-protection.md) |
| `per-company-api-keys` | Per-company API keys (`REGISTER_PDF_API_KEYS`), [7.5](07-05-register-pdf-api.md) |
| `durable-routing-archive` | Signed PDFs stay in `signed-output/` after the Manager acknowledges them, [11](11-document-routing-and-receive-back.md) |
| `signing-audit` | Signing audit log (`AUDIT_LOG`) and the wizard's Signing activity tab, [9.13](09-13-signing-activity-log.md) |

What changed between releases is in [`CHANGELOG.md`](../CHANGELOG.md).
