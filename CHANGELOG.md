# Changelog

## v1.0.7

- Barcode extraction is now position-independent (content-based pairing of plain-digit text with barcode-font renderings) and returns both `customerId` (5-digit) and `documentNumber` (6-digit) from Amit work-order PDFs. Survives future template layout changes.
- `documentNumber` is exposed in `/latestUser` alongside `signerName`, `source`, and `customerId`.
- Filesystem routing `pathTemplate` gains new tokens (`{documentNumber}`, `{signerName}`, `{customerId}`) and a `ss` (seconds) date-format token. `{date:...}` output is sanitized so `HH:mm:ss` produces `HH_mm_ss` on disk.
- Default pathTemplate changed to `{company}/{date:YYYY-MM}/{documentNumber}_{date:YYYY.MM.DD_HH:mm:ss}.pdf` (per client request).
- Consolidated single-line info log on `/registerPDF` for virtual-printer uploads (`docId`, `source`, `customerId`, `documentNumber`, `signerName`, `customerLookup`).
- Debug-level cache hit/miss logging in the CustomerData client (silent in production).
- Added standalone verification script `server/test/test-barcode-extraction.js` in the psapp repo — run with `node server/test/test-barcode-extraction.js`.
- Bumped deployment image tag to `ps-server:3.24` (no client-side change).

## v1.0.6

- Added `CUSTOMER_DATA_*` configuration keys for the virtual-printer customer-barcode lookup feature. When enabled, uploads arriving via `POST /api/registerPDF` with `source=virtual-printer` trigger a server-side CustomerId barcode extraction and external CustomerData API lookup; the resolved customer name becomes the "Signed by" label in the final visual signature. Disabled by default (empty API key).
- Bumped deployment image tags to `ps-server:3.23` and `ps-client:8.35`.

## v1.0.5

- Overhauled `bootstrap.sh`: fully automated end-to-end deployment — config rewrites, directory creation, Keycloak setup, Docker pull, service startup, and verification in one command.
- Improved `configure-host.sh`: added config backups before edits, JSON validation, nginx root→/portal/ redirect, `--enable-routing` and `--enable-demo` flags, `--company-role` for DEMO_COMPANY_ROLE, ensures DOCUMENT_ROUTING and signed-output volume mount.
- Improved `keycloak-bootstrap.sh`: fixed IFS variable pollution, improved readiness check (uses health endpoint), random test user password, test user email, production warning.
- Enhanced `verify-keycloak.sh`: added service health checks (ps-server, nginx redirect, Keycloak OIDC), config validation (DOCUMENT_ROUTING, volume mounts).
- New `upgrade.sh`: automated upgrade for existing deployments — updates image tags, ensures latest config patterns, pulls images, restarts containers.
- New `validate-config.sh`: validates syntax and consistency of all config files, checks hostname consistency, compares running containers against docker-compose.yml.
- Updated README.md with Quick Start, Upgrade, and Validation sections.

## v1.0.4

- Added `DOCUMENT_ROUTING` configuration to `config/config.js` for server-side post-signing document routing (filesystem save with structured folders, webhook delivery with retries).
- Deprecated client-side `PDF_SIGNING_STATUS_CALLBACK` / `PDF_SIGNING_STATUS_CALLBACK_ENABLED` in favor of server-side `DOCUMENT_ROUTING` webhook strategy.
- Updated README.md: added `DOCUMENT_ROUTING` to Cloud Essentials, server config example, and Configuration Constants Reference. Updated Data Flow FAQ.
- Updated deployment image tags to `ps-client:8.34` and `ps-server:3.21`.
- Redirect `https://host/` to `https://host/portal/` in nginx config.
- Added `signed-output` volume mount to ps-server for filesystem routing strategy.
- Updated filesystem strategy `basePath` to `/signed-output` (matches volume mount).

## v1.0.3

- Updated deployment image tag to `ps-client:8.33` in `docker-compose.yml`.
- Updated `README.md` release snapshot references to `ps-client:8.33`.

## v1.0.2

- Updated deployment docs to use `ps-client:8.23`.
- Aligned release snapshot references in `README.md` with `docker-compose.yml`.

## v1.0.1

- Updated release snapshot and compose image references to:
- `ps-server:3.8`
- `ps-client:8.8`
- Updated documentation for newly added client translation/config keys in `config/constants.json`:
- Workflow popup labels and countdown text (`WF_*`, `WF_REFRESH_COUNTDOWN`)
- Stage-specific signing errors (`ERROR_VISUAL_SIGNATURE`, `ERROR_STAMP_RESPONSE`)
- Localized signature payload labels (`SIGNATURE_LABEL_SIGNER`, `SIGNATURE_LABEL_DATE`)

## v1.0.0

- Initial public repository setup
- Comprehensive deployment guide in `README.md`
- Added Security & Route Protection and Data Flow diagrams
- Docker Compose stack: NGINX, Keycloak, PS client/server, DMSS services
- Sensible `.gitignore` to avoid committing certs/keystores and temp data
