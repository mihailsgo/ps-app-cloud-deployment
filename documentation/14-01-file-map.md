# 14.1 File map

Where everything lives in the deployment directory (`/opt/padsign`) and what it is for. Paths are
relative to that directory.

## Stack definition

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Every service, its image (pinned by tag and digest), ports, volumes, health checks and compose profiles. Tracked in git and readable by everyone on the host, so the Keycloak admin password is kept out of it (in `.env`). One exception: with local e-sealing it holds container-signature's Basic-auth password (`SPRING_SECURITY_USER_PASSWORD`), which you rotate as described in [6. Production hardening](06-production-hardening.md#rotating-the-local-e-sealing-password-9). |
| `.env` | Git-ignored, mode 600. `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD`, `COMPOSE_PROFILES` (for example `local-eseal`) and optional alerting settings ([7.6 Environment variables](07-06-environment-variables.md)). |

## Service configuration

| Path | Mounted into | Purpose |
|---|---|---|
| `nginx/nginx.conf` | nginx | Hostname (`server_name`), TLS certificate paths, reverse-proxy routes, `/` -> `/portal/` redirect. |
| `nginx/certs/<host>.crt`, `<host>.key` | nginx | The TLS certificate nginx serves. Git-ignored. Copied here from `installation-scripts/certs/` by the scripts. |
| `config/config.js` | ps-server | Server configuration: service URLs, Keycloak backend client and secret, `ALLOWED_ORIGINS`, `REGISTER_PDF_API_KEY`, e-sealing (`STAMP_MODE`, `STAMP_*`), `DOCUMENT_ROUTING`, `CUSTOMER_DATA_*` ([7.4 Server config.js](07-04-server-config-js.md)). Holds secrets: group-readable by ps-server only, mode 640. |
| `config/constants.json` | ps-client | Browser app configuration: Keycloak URL and client, redirect URIs, download URLs, UI texts and translations ([7.3 Client constants.json](07-03-client-constants-json.md)). |
| `config/keycloak.js` | ps-client | Keycloak JavaScript adapter settings, derived from the page's own origin. |
| `config/TLlogo.png` | ps-client | Logo shown in the portal (served as `/portal/logo.png`). |
| `dmss-archive-services/application.yml` | dmss-archive-services | Archive service settings (database, archive connections, fallback). |
| `dmss-archive-services/mappings.json` | dmss-archive-services | Document types and their archive path layout. |
| `dmss-archive-services/cacerts/` | dmss-archive-services | Java trust store. |
| `dmss-container-and-signature-services/application.yml` | dmss-container-and-signature-services | Signing service settings: archive URLs, stamping-service URL, DigiDoc4j settings. |
| `dmss-container-and-signature-services/documentsigningprofiles.json` | dmss-container-and-signature-services | Signing profile catalogue, including the `LocalDemo` profile for local e-sealing ([10.7](10-07-adding-a-signing-profile.md)). |
| `dmss-container-and-signature-services/dmssrootca.p12` | dmss-container-and-signature-services | CA used for visual PDF signatures. The shipped one is a demo CA; `bootstrap.sh` replaces it with one generated for your deployment. |
| `dmss-container-and-signature-services/digidoc4j-custom.yaml`, `ssl_tsl_truststore.p12`, `https___sr_riik_ee_tsl_estonian_tsl_xml` | dmss-container-and-signature-services | Trust list, TSA/OCSP and trust store settings for signature validation ([10.8](10-08-tsa-and-ocsp-for-lt-and-lta.md)). |
| `dmss-archive-services-fallback/application.yml` | dmss-archive-services-fallback | Filesystem fallback archive; stores documents under `/docs` in the container. |
| `dmss-digital-stamping-service/application.yml` | dmss-digital-stamping-service | Local e-sealing only: maps company names to seal keystores. |
| `dmss-digital-stamping-service/seal/seal.p12` | dmss-digital-stamping-service | Local e-sealing only: the seal keystore. The shipped one is a demo; replace it before production ([10.6](10-06-production-key-and-certificate.md)). |

## Data on the host

| Path | Purpose |
|---|---|
| `docs/` | Documents stored by the fallback archive service (this is document content, not documentation). Mode 770, owned by the fallback service's user. Never delete or commit it. |
| `signed-output/` | Signed documents written by document routing, and the receive-back buffer ([11](11-document-routing-and-receive-back.md)). Mode 750, owned by ps-server's user. |
| Docker volume `keycloak_data` | Keycloak's database (realm, clients, users). Back it up; `docker compose down -v` deletes it. |

## Scripts and their inputs

| Path | Purpose |
|---|---|
| `installation-scripts/` | All install, upgrade, validation and operations scripts. Each prints its options with `--help`. |
| `installation-scripts/certs/` | Where you stage `<host>.crt` and `<host>.key` before an install or certificate change. Git-ignored. |
| `installation-scripts/lib/` | Helpers used by the scripts. Not run directly. |
| `installation-scripts/assets/dmss-digital-stamping-service/` | Pristine demo files that local e-sealing copies into `dmss-digital-stamping-service/` (never overwriting yours). |
| `installation-scripts/assets/padsign.service.example` | Example systemd unit to start the stack at boot ([9.11](09-11-start-at-boot-backups-and-customized-hosts.md)). |

Which script to use for which task: [4](04-install-from-the-command-line.md) (install),
[5](05-first-login-and-verification.md) (checks) and [9](09-operations.md) (everything after go-live).

## Files the scripts write

All git-ignored.

| Path | Written by | Purpose |
|---|---|---|
| `*.bak` next to `config/config.js`, `config/constants.json`, `nginx/nginx.conf`, `docker-compose.yml` | `bootstrap.sh`, `configure-host.sh`, `upgrade.sh` | Copy of the file from before the last run, owner-readable only. Holds the same secrets as the file itself. |
| `.rollback-snapshots/` | `upgrade.sh` | Snapshots that `rollback.sh` restores ([9.8 Rollback](09-08-rollback.md)). |
| `deployment-evidence.json`, `deployment-evidence.json.previous` | `bootstrap.sh`, `upgrade.sh`, `postdeploy-check.sh` | Record of what is deployed: git revision, image tags and digests, config checksums, service state and restart counts. |
| `.monitor-state/` | `monitor-status.sh` | State kept between monitoring runs ([9.10](09-10-monitoring-and-alerting.md)). |
| `.wizard-saved-progress.json` | Deployment Wizard | Answers saved with **Save & Exit** (no password), mode 600. |

## Release metadata

| Path | Purpose |
|---|---|
| `release/approved-digests.json` | The approved tag and `sha256` digest of every image. `validate-config.sh` fails if `docker-compose.yml` pins anything else ([14.3](14-03-release-snapshot.md), [14.6](14-06-image-approval-and-digest-pinning.md)). |
| `release/capabilities.json` | Minimum image tags for features that depend on a version. Read by `upgrade.sh` and `toggle-features.sh`. |
| `release/cosign.pub`, `release/unsigned-legacy-images.json` | Public key for verifying PadSign image signatures, and the closed list of older images released before signing. |
| `CHANGELOG.md` | What changed in each release. |

## Other

| Path | Purpose |
|---|---|
| `deployment-wizard/` | Source of the Deployment Wizard image. You run the published image, not this source ([3](03-install-with-the-wizard.md)). |
| `documentation/` | This documentation. `README.md` lists every section. |
| `AGENTS.md`, `.claude/skills/`, `.agents/skills/` | Guidance for AI coding assistants ([14.4](14-04-ai-agent-deployment-skill.md)). |
| `LICENSE`, `SECURITY.md` | Licence terms, and how to report a security vulnerability. |
| `installation-scripts/tests/` | Automated checks for the scripts, the documentation and the wizard. `run-all.sh` runs them all. |
| `.github/`, `renovate.json` | TrustLynx's own CI and dependency-update automation for this repository. Nothing on your host uses them. |
