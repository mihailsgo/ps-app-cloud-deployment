# Changelog

## v1.0.13

- Fixed `bootstrap.sh --admin-pass` being silently ignored for Keycloak's actual admin account: `configure-host.sh` never wrote the operator-supplied `--admin-user`/`--admin-pass` into `docker-compose.yml`'s `keycloak` service, which hardcodes `KEYCLOAK_ADMIN=admin` / `KEYCLOAK_ADMIN_PASSWORD=admin`. `keycloak-bootstrap.sh`'s `kcadm.sh` login then always failed with `Invalid user credentials` for any admin password other than the literal default — meaning following the script's own security warning ("using default admin password 'admin' is insecure") broke the deployment. `configure-host.sh` now accepts `--admin-user`/`--admin-pass` and syncs both lines in `docker-compose.yml` before Keycloak first starts; `bootstrap.sh` passes its own `--admin-user`/`--admin-pass` through automatically. Found by running a full bootstrap end-to-end against an isolated copy of the repo.
- Fixed `keycloak-bootstrap.sh` failing on any multi-word `--company-role` (e.g. `"Acme Corp"`, the wizard's own example value): `ensure_role()` interpolated the role name unquoted inside a nested `sh -lc` command string, so a space split it into a bogus extra `kcadm` argument (`Unmatched argument at index 6: 'Corp'`). The value is now single-quoted inside that nested string, matching the convention already used elsewhere in the same file (e.g. `--rolename '${company_role}'`). Found the same way, immediately after the fix above.
- Added [36. Deployment Wizard](documentation/36-deployment-wizard.md) — an optional browser UI (`deployment-wizard/`, its own Docker image, gated behind the `wizard` compose profile) that wraps `bootstrap.sh`/`upgrade.sh`/`validate-config.sh`/`validate-certs.sh` with inline TLS-cert validation, live per-step deploy progress, and a persistent dashboard. Wrapping only — the underlying scripts are unmodified in behavior and remain fully usable standalone.
- Added [37. Settings (Post-Go-Live Changes)](documentation/37-settings-post-go-live-changes.md) — a new wizard section (`/settings`, topbar link next to Dashboard) letting an operator change hostname, renew the TLS certificate, or toggle document routing/demo mode/local e-sealing on an *already-deployed* stack, none of which was previously possible without hand-chaining scripts. Three new orchestrator scripts wrap the existing engines: `update-hostname.sh` (chains `configure-host.sh` + `keycloak-bootstrap.sh` + restarts nginx/ps-server), `renew-cert.sh` (cert swap + nginx restart), `toggle-features.sh` (any combination of the 3 flags in one pass, restarting only what's needed). `configure-host.sh` gained symmetric `--disable-routing`/`--disable-demo`/`--disable-local-eseal` flags; `keycloak-bootstrap.sh` gained `--skip-test-user` so a live hostname change never resets the demo `test` account.
- Fixed `configure-host.sh --company-role` silently never updating `config.js`'s `DEMO_COMPANY_ROLE`: the replacement regex anchored `$` immediately after the closing quote, but the real field has a trailing comma, so the anchor never matched and the field stayed at its `"CHANGE_ME"` template default regardless of what was passed. Found live while building the Settings hostname-change feature, which reads this field back to avoid re-asking the operator for it.
- Fixed `keycloak-bootstrap.sh`'s `ensure_role()` throwing `Illegal character in path` for any multi-word role name (e.g. `"Acme Corp"`) once it already existed: the existence check did `kcadm get roles/<name>`, a raw URL path segment that Keycloak's admin CLI rejects outright when it contains a space, so it always fell through to `create`, which then failed on a duplicate-name conflict. Replaced with a full-list-plus-exact-match check (`get roles --fields name` filtered client-side), the same technique already used for clients/users elsewhere in the file. This was dormant until the `DEMO_COMPANY_ROLE` fix above made the role name reach this code path correctly for the first time.
- Fixed a `set -euo pipefail` robustness gap across `update-hostname.sh`/`renew-cert.sh`/`toggle-features.sh`: several post-action verification checks (a live TLS handshake, a config-file readback) were best-effort/informational by design, but a transient failure or simple no-match in their pipeline (a real `grep`/`openssl` exit code, not a script bug) silently aborted the *entire* script under `pipefail` before reaching the intended graceful-WARNING fallback — meaning an otherwise fully successful certificate renewal or feature toggle could report as a hard failure. Every such check now ends in `|| true`. Found via a live E2E run where a successful cert renewal reported `success:false`.
- Fixed a live-state bug in the wizard's Settings page: `readConfiguredFeatures()`'s `localEsealProvisioned` field (meant to distinguish "never enabled" from "enabled once, now off") checked `docker-compose.yml` for the `dmss-digital-stamping-service` block — but that block, and the demo `seal.p12`/`application.yml` under `dmss-digital-stamping-service/`, ship pre-committed in every checkout rather than being inserted on first `--enable-local-eseal` as assumed, so the field was always `true` and the Feature Toggles card's "(not yet provisioned)" hint could never render. Removed the dead field and its hint; `localEseal` itself (`STAMP_MODE`'s presence in `config.js`) was already the correct live signal.
- Added `installation-scripts/verify-served-cert.sh` and [11.2 Monitoring the Served Certificate](documentation/11-02-monitoring-the-served-certificate.md) — an over-the-wire check that opens a real TLS handshake and compares the certificate nginx is **serving** against the one on disk. This closes a detection gap that no existing check could see: nginx reads its `ssl_certificate` files only at startup and on reload, so an ACME renewal that copies a new fullchain into `nginx/certs/` but whose reload step fails leaves nginx serving a months-old certificate until it expires — while renewal logs report zero failures, the file on disk is current, and `validate-certs.sh` passes every one of its checks. Found live on a deployment whose renewal hook ran `docker kill -s HUP nginx || true` inside the ACME client container, which ships no `docker` binary: the reload failed on all 335 iterations with `sh: docker: not found`, `|| true` erased the error, and unrelated upgrade restarts accidentally masked it until deployments paused for longer than the certificate's remaining life. The script is detection-only — it never reloads or mutates anything — and `validate-certs.sh`'s header now states that it is file-level only and points here. The wizard's Settings TLS card gained a second, read-only "What nginx is actually serving" checklist backed by `certValidator.js`'s new `checkServedCert()` (published as `padsign-wizard:0.1.1`); it passes `--connect nginx:443` explicitly, because the wizard runs these scripts inside its own container where `localhost:443` is nothing, and unlike `runValidateCerts()` it never rethrows on a non-1 exit — `GET /settings` does `next(err)`, so a missing script or a timed-out handshake must degrade one card rather than blank the whole page.
- Fixed all `installation-scripts/*.sh` shipping without the executable bit (git mode `100644`): on a fresh Linux clone every documented `./installation-scripts/bootstrap.sh ...` invocation failed with `Permission denied` until the operator ran `chmod +x ./installation-scripts/*.sh` — and since `bootstrap.sh` invokes its child scripts directly (`configure-host.sh`, `validate-certs.sh`, `keycloak-bootstrap.sh`), the bit was needed on every script, not just the entry point. The scripts are now committed with mode `100755` (`keycloak-bootstrap.ps1` is unaffected), the `chmod +x` workaround step is gone from [3. Quick Start](documentation/03-quick-start-new-deployment.md), [14.2 Automated Setup](documentation/14-02-automated-setup-recommended.md), and [24.1 Deployment Checklist](documentation/24-01-deployment-checklist-recommended.md), and the scheduling note in [11.2 Monitoring the Served Certificate](documentation/11-02-monitoring-the-served-certificate.md) no longer claims the scripts ship non-executable.

## v1.0.12

- Bumped deployment image tag to `ps-client:8.38` (published to Docker Hub). The pad browser now downloads archive PDFs with the user's Keycloak Bearer token (`fetchPdfAsBase64` feeds the Syncfusion viewer a base64 document instead of an anonymous URL load; the demo download uses an authenticated fetch + blob). This makes `GET /archive/api/document/{docid}/download` closable behind authentication at the reverse proxy. The image is drop-in compatible: on fetch failure the client falls back to the plain URL, so deployments with the route open see no behaviour change. Retains automatic dark-mode support from `:8.37`.
- Documented the Authorization-header protection pattern for `/archive/api` and `/container/api` (nginx `satisfy any` + Docker-subnet allow + Basic auth, per-version handling of the download route, firewalling the published host ports) in `documentation/22-security-and-route-protection.md`, with copy-paste nginx blocks in https://github.com/mihailsgo/tl-service-route-protection.
- `validate-config.sh` image-tag consistency check now reads `documentation/01-release-snapshot.md` (the tags moved there when the README became an index; the old README check matched nothing and silently passed).

## v1.0.11

- Bumped deployment image tag to `ps-server:3.27` (published to Docker Hub). This image adds the signed-PDF **receive-back** feature: a server-side ack-driven buffer (populated by the `filesystem` document-routing strategy) plus three API-key-protected endpoints — `GET /api/signedPdf/pending`, `GET /api/signedPdf`, `POST /api/signedPdf/ack` — that the Padsign Manager (virtual printer, `v1.2.0`+) polls to pull the signed PDF back onto the originating desktop, then acks (the server deletes its buffered copy). Retains the `STAMP_MODE` local e-sealing dispatch from `:3.26`. The endpoints are always registered but only return documents when `DOCUMENT_ROUTING.enabled` + the `filesystem` strategy are enabled — this deployment's `config/config.js` enables them. Full procedure in `documentation/35-receive-back-deployment-runbook.md`.

## v1.0.10

- Added pre-flight TLS certificate validation. `bootstrap.sh` now runs `installation-scripts/validate-certs.sh` before deploying and hard-fails when the supplied `.crt` is leaf-only (no intermediates), encrypted, mismatched against the key, expired, hostname-incorrect, or unverifiable against the system trust store. Each failure mode emits a distinct, actionable message — including the exact `cat leaf.crt intermediate.crt > fullchain.crt` recipe when intermediates are missing. Pass `--allow-self-signed` to bypass the chain check only (other checks still run). Motivated by a customer deploy where a leaf-only cert silently broke Keycloak's backchannel TLS validation and prevented login.
- `bootstrap.sh` and `upgrade.sh` now auto-create the `docs/` directory used by `dmss-archive-services-fallback` (`mkdir -p docs && chmod 777 docs`), mirroring the existing `signed-output` provisioning. `validate-config.sh` additionally checks that `docs/` exists and is writable.

## v1.0.9

- Bumped deployment image tag to `ps-client:8.37`. The new client supports automatic dark mode: when the visitor's browser is set to `prefers-color-scheme: dark`, the SPA chrome (header demo bar, signing workflow panel, signature pad surround, loading spinners, error screens) renders with dark surfaces and matching text contrast. Earlier client tags showed broken contrast and reduced viewport width under dark mode because the global `#root { width: 100% }` rule lived inside a light-only media query. No operator action and no `constants.json` change required; the toggle is purely the browser's color-scheme preference. The Syncfusion PDF viewer body keeps its light theme by design - a paper-feel reading surface inside the dark chrome.

## v1.0.8

- Barcode extractor now supports 3- to 7-digit document numbers (was 5/6 only). Previously the extractor lost the document number when a customer template printed a 3-digit reference inside the Code128 barcode (filename fell back to `unknown_<date>.pdf`). Tested against three template variants in `server/test/test-barcode-extraction.js`.
- New client-side feature flag `SHOW_SIGNER_NAME` in `config/constants.json` (default `false`). When `true`, the SPA renders `Signer: <resolved name>` above the signature canvas before the user signs, so signers (especially when they are a contact person of a company) can verify identity. Combine with the existing CustomerData lookup so the displayed name comes from the live database.
- Bumped deployment image tags to `ps-server:3.25` and `ps-client:8.36`.

## v1.0.7

- Barcode extraction is now position-independent (content-based pairing of plain-digit text with barcode-font renderings) and returns both `customerId` (5-digit) and `documentNumber` (6-digit) from customer work-order PDFs. Survives future template layout changes.
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
