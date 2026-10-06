# Changelog

Release notes for the PadSign deployment package, newest first; versions follow this repository's git tags (`vX.Y.Z`).

## Unreleased

### Fixed

- `nginx/nginx.conf` sets `client_max_body_size 15m` in the `/api/` location. Without it nginx's 1 MB default answered `413` to any `POST /api/registerPDF` above 1 MB, although ps-server accepts PDFs of up to 10 MB ([7.5](documentation/07-05-register-pdf-api.md)). Found on the AMIT host, which had carried this setting by hand. `test-boot-and-timeouts.sh` now checks it.

## v1.0.52 - 2026-10-05

### Fixed

- The Deployment Wizard works on a host managed through an overlay. When `.env` names a compose file outside the checkout (`COMPOSE_FILE`), `overlay.sh apply` now also writes `.overlay-wizard.yml`, which mounts the overlay directory read-only, at the same path, into the wizard only. Before, the wizard could not run `docker compose` there: Monitoring showed no services, Logs had an empty picker, the receive-back buffer could not be read and the Dashboard reported `docker-compose.yml has errors`. When `docker compose` fails for any reason, Monitoring and Logs now show the first line of its error instead of an empty list. See [9.12](documentation/09-12-monitoring-from-the-wizard.md).
- The signed-output and docs checks (`validate-config.sh`, `monitor-status.sh`, the wizard's Dashboard, Disk card and Signing activity page) read the storage location from the rendered compose model. A store the caller cannot see is reported as `INFO ... cannot inspect`, no longer as `FAIL` with an `upgrade.sh` or `mkdir` fix. A store mounted from outside the checkout that is missing on the host still fails, and says to restore the mount. See [9.11](documentation/09-11-start-at-boot-backups-and-customized-hosts.md).
- `validate-config.sh` no longer warns that `SESSION_SECRET` is still the shipped value: `ps-server` 3.33 and later do not read it. The key stays in `config/config.js` so a rollback to 3.32 still works.
- Settings > TLS Certificate no longer shows `chain verification skipped (--allow-self-signed)` for the deployed certificate. The live certificate is checked with chain verification; only an uploaded certificate honours the self-signed checkbox. A self-signed certificate gets an honest `WARN` from `validate-certs.sh`.

### Changed

- The Deployment Wizard is read-only on an overlay-managed checkout (one with `.overlay-applied.json`). Deploy, upgrade and every Settings change are refused with HTTP 409 and a banner points to [9.11](documentation/09-11-start-at-boot-backups-and-customized-hosts.md); the Dashboard health checklist, Monitoring and Diagnostics keep working. Nothing changes on a host without an overlay.
- The release pins `padsign-wizard` 0.2.1 (from 0.2.0). `ps-server` 3.35, `ps-client` 8.42 and every other image are unchanged from v1.0.51.

**Upgrade impact (overlay hosts):** run `overlay.sh apply --force` from this release, then `docker compose --profile wizard up -d wizard` to recreate the wizard container; a `docker compose restart` does not pick up the new mount.

## v1.0.51 - 2026-10-05

### Added

- `upgrade.sh --use-internal-dmss-urls` switches the five DMSS addresses in `config/config.js` (`ARCHIVE_API_BASE_URL`, `CREATE_DOCUMENT_API_URL`, `DOCUMENT_DOWNLOAD_API_URL`, `VISUAL_SIGNATURE_API_TEMPLATE`, `FORM_FILL_API_URL`) from `https://<host>/archive/api/...` and `/container/api/...` to the in-network addresses (`http://dmss-archive-services:8090/api/...`, `http://dmss-container-and-signature-services:8092/api/...`), adds `ARCHIVE_PUBLIC_BASE_URL` with the public archive address you had, and recreates ps-server. `--use-public-dmss-urls` reverses it. Both are idempotent, preview with `--plan-only`, leave an address of your own alone, and are never part of a plain upgrade. See [7.4](documentation/07-04-server-config-js.md#how-ps-server-reaches-the-dmss-services).
- Two capabilities in `release/capabilities.json`: `dmss-internal-urls` (ps-server 3.35: `ARCHIVE_PUBLIC_BASE_URL`, the public archive address in webhook payloads) and `client-origin-defaults` (ps-client 8.42: `constants.json` without the Keycloak URL keys). `upgrade.sh --use-internal-dmss-urls` and `--require-capability dmss-internal-urls` refuse on a ps-server older than 3.35, with a message saying so.
- [6.1](documentation/06-01-route-protection.md#closing-the-routes-after-switching-ps-server-to-in-network-addresses): how to close `/archive/api/` and `/container/api/` at nginx once ps-server uses the in-network addresses, leaving only the browser's token-authenticated PDF download.

### Changed

- The release pins `ps-server` 3.35 (from 3.34) and `ps-client` 8.42 (from 8.41); `release/approved-digests.json` has the digests. `ps-server` 3.35 adds HMAC-signed webhook deliveries (`X-Padsign-Signature`, `X-Padsign-Timestamp` for a strategy with a `secret`) and `ARCHIVE_PUBLIC_BASE_URL`, and splits `app.js` into modules with no change in behaviour. `ps-client` 8.42 signs with one `POST /api/sign` and follows its status, moves the form-fill and new-version routes off `/demo/`, translates the remaining UI strings, and no longer ships absolute demo-host values in `constants.json`.
- `dmss-container-and-signature-services` moves from `24.3.0.29` to `24.3.0.36` (`trustlynx/container-signature-service`), after `dmss-seal-smoke.sh` passed on it: it boots and seals the `LocalDemo` profile repeatedly. `release/approved-digests.json` has the digest.
- `config/config.js` ships the in-network DMSS addresses and `ARCHIVE_PUBLIC_BASE_URL`, so a fresh install has ps-server call the DMSS services directly instead of through nginx and the public hostname. An existing host keeps what it has; nothing changes until you run the switch above. The in-network addresses work with every ps-server image; only the webhook `archiveUrl` needs the `dmss-internal-urls` capability.
- `validate-config.sh` accepts both address forms, fails a key that holds the other service's address or a public address on another host, and warns about a mix, about an `ARCHIVE_PUBLIC_BASE_URL` on another host, and about an enabled webhook that would send an in-network `archiveUrl`. It also accepts a `constants.json` that leaves out `KEYCLOAK_URL`, `KEYCLOAK_REDIRECT_URI` and `KEYCLOAK_POST_LOGOUT_REDIRECT_URI` when the ps-client defaults them to its own origin, and fails one that does so on a ps-client that does not.
- `configure-host.sh` writes the three Keycloak URLs into `constants.json` only where the file has them, and keeps a relative `PS_DOWNLOAD_API` / `PDF_TEST_PATH`. `postdeploy-check.sh` counts a key left out of both the on-disk and the served `constants.json` as a match. `diff-baseline-overlay.sh` treats either DMSS address form and `ARCHIVE_PUBLIC_BASE_URL` as expected overlay values.

**Upgrade impact (ps-client 8.42):** `ps-client` 8.42 signs through `POST /api/sign` and `GET /api/sign/status`, which only `ps-server` 3.35 and later serve. Run them as a pair, as this release pins them. `ps-server` 3.35 keeps the old `/demo/fill-by-docid` and `/demo/upload/version` routes as aliases, so a 3.35 server works with an older client, but a 8.42 client against an older server cannot sign.

**Upgrade impact:** when you `git stash pop` after pulling a release with this change, `config/config.js` conflicts on the five DMSS address lines: keep your own lines (that keeps ps-server on the public addresses until you switch) and drop the release's new `ARCHIVE_PUBLIC_BASE_URL` key, as [9.5](documentation/09-05-upgrading.md#when-git-stash-pop-reports-a-conflict) describes.

## v1.0.50 - 2026-09-29

### Security

- The visual-PDF signing CA is now generated per deployment. Releases up to v1.0.48 shipped `dmss-container-and-signature-services/dmssrootca.p12` with its private key, so any copy of this repository could issue certificates under it. `bootstrap.sh` now replaces it on every fresh install (`configure-host.sh --generate-ca`). The shipped file is now a CA labelled `PadSign DEMO Visual PDF CA - NOT FOR PRODUCTION`, with the same keystore password, so an existing `application.yml` keeps working.
- E-sealing credentials and the Keycloak backend client secret are no longer shipped. `config/config.js` carries `CHANGE_ME` for `STAMP_API_KEY`, `STAMP_COMPANY_ID`, `STAMP_COMPANY_SECRET` and `KEYCLOAK_CONFIG.credentials.secret`. `bootstrap.sh` still writes the backend secret Keycloak issues; the e-sealing credentials come from your e-sealing provider. `validate-config.sh` reports each placeholder as not set, and still recognises the values earlier releases shipped.
- `validate-config.sh` fails a deployment that turns on `dmss-archive-services` JWT checking with the secret shipped in this repository.
- Unused vendor redirect URLs and an SMS-provider account host in the container-signature `application.yml` were replaced with neutral values.
- `.gitignore` allows exactly the two keystores the release ships instead of every `*.p12`.
- The Deployment Wizard's port 8443 is published on `127.0.0.1` only, so it is reachable only through the SSH tunnel. Set `WIZARD_BIND_ADDRESS=0.0.0.0` in `.env` to open it on all interfaces, on a trusted admin network only: Docker-published ports bypass host firewalls such as `ufw`. `validate-config.sh` warns while the wizard is bound to a non-loopback address. See [3.1](documentation/03-01-starting-the-wizard.md).
- `validate-config.sh` also reports `STAMP_COMPANY_ID` when it still holds the `CHANGE_ME` placeholder or the value earlier releases shipped.

### Added

- `LICENSE` and `SECURITY.md` (how to report a vulnerability: support@trustlynx.com).
- A **Monitoring** page in the Deployment Wizard, in the top bar once setup has completed: **Overview** (state, health, uptime, restarts, version, CPU and memory of every service, with a per-service restart), **Logs** (tail, since, live follow, filter, download), **Signing activity** (history of documents with filters, tiles and CSV export) and **Diagnostics** (the read-only configuration, certificate, Keycloak and alert-threshold checks, and a support bundle). It needs a wizard image that includes it. See [9.12](documentation/09-12-monitoring-from-the-wizard.md).
- `installation-scripts/restart-service.sh` restarts one service and waits until it is healthy; the wizard's Restart button runs it. See [9.12](documentation/09-12-monitoring-from-the-wizard.md#restarting-a-service).
- `installation-scripts/support-bundle.sh` writes a redacted archive of configuration, reports and service logs for TrustLynx support (`support-bundles/`, mode 600). `installation-scripts/lib/redact.py` gained `--filter` and `--log` for this. See [9.12](documentation/09-12-monitoring-from-the-wizard.md#support-bundles).
- `monitor-status.sh --format json` prints the report as JSON, read-only and without a state file or webhook.
- A signing audit log: ps-server writes one JSON line per signing event to its output and, with the new `AUDIT_LOG` block in `config/config.js`, to monthly files under `signed-output/.padsign-audit/` (12 months kept by default). It needs the ps-server version named by the `signing-audit` capability in `release/capabilities.json`; an older ps-server ignores the block. `upgrade.sh` adds the block to existing deployments, enabled. The log records signers' e-mail addresses, so set `retentionMonths` to your policy. See [9.13](documentation/09-13-signing-activity-log.md).

### Changed

- The release pins `ps-server` 3.34 (from 3.32), `ps-client` 8.41 (from 8.40) and `padsign-wizard` 0.2.0 (from 0.1.1); `release/approved-digests.json` has the digests. `ps-server` 3.34 is the first image that writes the signing audit log: 3.33 was tagged before that work merged, so the `signing-audit` minimum in `release/capabilities.json` is 3.34.
- `ps-server` 3.33 and later verify access tokens locally against Keycloak's signing keys instead of asking Keycloak to introspect each one, so a Keycloak outage no longer ends API access. `keycloak-connect`, `express-session` and the session cookie are gone: `SESSION_SECRET` is no longer read or required. `GET /save`, `GET /registerUser` and `GET /registerUserPDF` are removed. `POST /demo/upload` answers 404 unless `DEMO_MODE_ENABLED` is true in `config/config.js`; this repository's `config.js` does not set it and `DEMO_MODE` is `DISABLE`, so nothing changes here. `SESSION_SECRET`, `DOCUMENT_OUTPUT_DIRECTORY`, `READONLY_PDF_DIRECTORY` and `ENABLE_PERSONAL_CODE_VALIDATION` may stay in your `config.js`: 3.33 and later ignore them, and a rollback to 3.32 still reads them. ps-server now stops at start-up, with one clear line, when no `config.js` is mounted or when the Keycloak backend secret or `REGISTER_PDF_API_KEY` is empty.
- `ps-client` 8.41 runs the Syncfusion 34 PDF viewer and needs the new licence key this release ships in `config/constants.json` (see **Upgrade impact** below). It loads the PDF engine from `/portal/` instead of `cdn.syncfusion.com`, and its nginx sends an enforced Content-Security-Policy and the usual security headers (the wildcard CORS headers are gone).
- `padsign-wizard` 0.2.0 carries the Monitoring pages described under **Added**.
- The install instructions clone from `https://gitlab.com/trustlynx-public/padsign-2.0.git`.
- Documentation reorganised into 14 sections in installation order; see [README.md](README.md) for the new map (old section numbers no longer apply).
- Release tags are read from `release/approved-digests.json` instead of a documentation page.
- `.env.example` lists every variable `docker-compose.yml` reads from `.env`. `WIZARD_TLS_SANS` is set in `.env`; there is no longer a commented line to uncomment in `docker-compose.yml`. See [7.6](documentation/07-06-environment-variables.md).
- Every service uses `restart: unless-stopped` (the DMSS services and ps-server used `always`), and every container's log is rotated (5 files of 20 MB each), so container logs no longer fill the disk.
- container-signature logs at `info` instead of `debug` (its own `ee.digitalmind` messages stay at `debug`), which cuts its log volume.
- Keycloak no longer gets `KC_PROXY` and `KC_HOSTNAME_STRICT_HTTPS`, which Keycloak 26 does not have. `KC_PROXY_HEADERS=xforwarded` and `KC_HOSTNAME_STRICT=false` stay.
- `upgrade.sh --enable-local-eseal` always recreates container-signature and ps-server, so both read their updated configuration without a manual restart.
- When `--enable-local-eseal` has to add the stamping service to a customised `docker-compose.yml`, it uses the release's approved, digest-pinned image instead of a fixed older tag.

### Fixed

- `verify-keycloak.sh` (and so `postdeploy-check.sh`) logs in with the password the Keycloak container was started with when `KEYCLOAK_ADMIN_PASSWORD` is not set, instead of the demo default `admin`, which failed on every deployment `bootstrap.sh` set up.
- `upgrade.sh` recreates nginx (and the stamping service when it runs) instead of only restarting nginx, so a release's change to their compose definition - such as log rotation - reaches them.
- The Deployment Wizard's sign-in accepts an access token pasted with surrounding spaces or a line break, instead of reporting it invalid. Takes effect with the next wizard image.
- The Keycloak scripts (`keycloak-bootstrap.sh`, `smoke-user.sh`, `verify-keycloak.sh`) look users up by exact username. Before, a lookup for `test` could match another user whose name contains `test`. `smoke-user.sh delete --username test --force` removes the demo user.
- `configure-host.sh` and `renew-cert.sh` accept the deployed certificate files (`nginx/certs/<host>.crt` / `.key`) as `--cert-crt` / `--cert-key` instead of stopping with a copy error.

**Upgrade impact:** when you `git stash pop` after pulling this release (documentation/09-05-upgrading.md), `config/config.js` conflicts on the `"secret"` line of `KEYCLOAK_CONFIG` (your deployment's secret against the release's new `CHANGE_ME`): keep your value, as 9.5 describes. existing deployments keep their visual-PDF CA until you run `./installation-scripts/configure-host.sh --host <host> --generate-ca` and `docker compose restart dmss-container-and-signature-services` (`validate-config.sh` warns until then). Signatures made afterwards chain to the new CA; documents signed before keep their chain. If you imported the old CA into a PDF reader's trust store, import the new one. A deployment that used the shared demo e-sealing credentials must put its own in `config/config.js` (the demo credentials were public and can be withdrawn at any time), then `docker compose restart ps-server`. Deployments on local e-sealing (`STAMP_MODE: "local"`) are unaffected by the e-sealing change. After the upgrade the Deployment Wizard is reachable only through the SSH tunnel (`ssh -L 8443:localhost:8443 <user>@<host>`) unless you set `WIZARD_BIND_ADDRESS` in `.env`; if you set `WIZARD_TLS_SANS` in `docker-compose.yml`, move it to `.env`.

**Upgrade impact (ps-client 8.41):** this release replaces the Syncfusion licence key in `config/constants.json`, so `git stash pop` after the pull conflicts on `PDF_RENDER_SYNCFUSION_SECRET_KEY` (it sits next to `PDF_TEST_PATH`, which your host set): keep the upper key line and the lower `PDF_TEST_PATH` line, as [9.5](documentation/09-05-upgrading.md#new-syncfusion-key-for-ps-client-841) describes. Without the new key the 8.41 viewer shows a licence banner across every document. Rolling `ps-client` back to 8.40 or older needs the old key back: [9.8](documentation/09-08-rollback.md#rolling-ps-client-back-across-the-syncfusion-34-boundary).

## v1.0.49 - 2026-09-27

### Added

- Upgrade guidance for moving `ps-client` to `8.41` or later, whose PDF viewer (Syncfusion 34) needs a new licence key in `config/constants.json`: how to resolve the `git stash pop` conflict on it, the overlay case, and putting the old key back on a rollback to `8.40` or older ([9.5](documentation/09-05-upgrading.md#new-syncfusion-key-for-ps-client-841), [9.8](documentation/09-08-rollback.md#rolling-ps-client-back-across-the-syncfusion-34-boundary)).

### Fixed

- The test suites under `installation-scripts/tests/` stop themselves with exit 124 when they run far longer than expected, and print what is still running, instead of hanging a terminal or CI job. No script a deployment runs changed.

## v1.0.48 - 2026-09-27

### Security

- On a customized host, `overlay.sh apply` now gives the DMSS `application.yml` files and `nginx/certs/htpasswd` the same treatment as `config/config.js`: mode 640, group set to the service that reads them, and a read check from inside that service's image. Before, they could end up readable by every local user.
- `overlay.sh verify` reports each of these files under *Secret-bearing file modes*: a warning when world-readable, a failure when its service cannot read it.

## v1.0.47 - 2026-09-26

### Added

- A systemd boot unit example, `installation-scripts/assets/padsign.service.example`, that starts the stack after a reboot, retries while the Java services start, and never runs `docker compose down`. See [9.11](documentation/09-11-start-at-boot-backups-and-customized-hosts.md).
- `overlay.sh capture` and `verify` now list host boot and cron hooks that point at the old checkout or run `docker compose`, so a stale hook cannot start the old stack at the next reboot.

### Fixed

- After a cold boot nginx could stay down because the DMSS services took longer to become healthy than their health-check window allowed. The window is now 300 s, and `upgrade.sh` / `rollback.sh` wait up to 480 s by default.
- The browser no longer gets nginx's `504` while ps-server is still retrying e-sealing or archiving: `/api/` now allows 180 s.

**Upgrade impact:** if the host starts PadSign at boot with its own unit or cron job, check it against the example in [9.11](documentation/09-11-start-at-boot-backups-and-customized-hosts.md). A customized host whose overlay replaces `nginx/nginx.conf` must add the new `/api/` `proxy_read_timeout` itself.

## v1.0.46 - 2026-09-26

### Added

- `monitor-status.sh --alert` can post to Microsoft Teams Workflows (`ALERT_WEBHOOK_FORMAT=teams`), and `--test-webhook` sends a test message. See [9.10](documentation/09-10-monitoring-and-alerting.md).

### Fixed

- The alert webhook URL and authorization header no longer appear in the host process list.
- An alert whose log sample was cut in the middle of a non-ASCII letter is no longer rejected as invalid UTF-8.
- The Disk usage report on a customized host now measures the document storage it actually mounts.

## v1.0.45 - 2026-09-25

### Changed

- Pinned `ps-server:3.32`, signed and built with an SBOM and provenance. Acknowledging a receive-back document that was pending when the host upgraded from 3.28 or older no longer deletes its archive copy under `signed-output/`.
- The `durable-routing-archive` capability now requires `ps-server` 3.32.

## v1.0.44 - 2026-09-25

### Added

- `overlay.sh drop` removes a file from a customized host's overlay without hand-editing its manifest.

### Fixed

- `upgrade.sh` now refuses, before changing anything, to restart ps-server into an image that cannot read `config/config.js`, and prints the `chgrp`/`chmod` fix.
- `upgrade.sh` re-applies the `config.js` ownership model after its own edits, and its `.bak` copies are owner-only.
- `upgrade.sh --plan-only` on a customized host no longer always reports that it will create `signed-output`.

## v1.0.43 - 2026-09-25

### Fixed

- `verify-keycloak.sh` (and so `postdeploy-check.sh`) could report a healthy ps-server as not running.
- `bootstrap.sh` run from a heredoc or script no longer swallows the rest of the calling script's input.
- `keycloak-bootstrap.sh --users` with more than one entry now creates every user, not only the first.

## v1.0.42 - 2026-09-25

### Security

- A fresh install now replaces the `REGISTER_PDF_API_KEY` and `SESSION_SECRET` shipped in this repository with random values (a value you changed is never touched).
- The Keycloak admin password is no longer written into the tracked `docker-compose.yml`; `bootstrap.sh` writes it to the git-ignored `.env` as `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD` (mode 600).
- `.bak` files written by `bootstrap.sh` and `configure-host.sh` are owner-only.

### Fixed

- `config/config.js` now gets the group of the user ps-server runs as and mode 640, so ps-server 3.30+ (non-root) can read it. The old `validate-config.sh` hint could crash-loop ps-server.
- `validate-config.sh` checks storage ownership against the images the host actually runs, including a customized host's compose overlay.

**Upgrade impact:** a deployment bootstrapped earlier keeps its inline admin password in `docker-compose.yml`, which `git pull` may conflict with. Move it to `.env` as described in [7.6](documentation/07-06-environment-variables.md) before pulling.

## v1.0.41 - 2026-09-25

### Fixed

- `rollback.sh` now restores the images that were actually running before the upgrade and checks each restored container runs that exact digest. Before, after the documented `git pull` it could report success while leaving the new release running.
- Rollback snapshots (which include a copy of `config/config.js`) are now readable only by their owner.
- `validate-config.sh` after a verified rollback reports the restored, previously approved images as a warning instead of a failure. See [9.8](documentation/09-08-rollback.md).

## v1.0.40 - 2026-09-24

### Security

- Keycloak passwords no longer appear in the host process list during `keycloak-bootstrap.sh`, `verify-keycloak.sh` and `smoke-user.sh`, or while scripts and the deployment wizard call each other. They are passed through the environment (`KEYCLOAK_ADMIN_PASSWORD`).

## v1.0.39 - 2026-09-24

### Changed

- Removed the Windows-only `keycloak-bootstrap.ps1`, which no longer worked. On a Windows development machine, run `keycloak-bootstrap.sh` from Git Bash or WSL; Linux remains the only supported deployment target.

## v1.0.38 - 2026-09-24

### Fixed

- `deployment-evidence.json` now covers the profile-gated services (local e-sealing, wizard) and records real restart counts after `bootstrap.sh`.

## v1.0.37 - 2026-09-24

### Added

- `signing-smoke.sh`, a signing smoke test that is safe to run on a production host; `postdeploy-check.sh --signing-smoke` runs it.
- The deployment wizard container now has a health check.

## v1.0.36 - 2026-09-24

### Security

- `upgrade.sh` (including `--plan-only`) no longer puts the Keycloak admin password in the host process list when it checks the token-audience mapper.

## v1.0.35 - 2026-09-24

### Security

- The image digest gate now checks every image the host would actually run, including a compose overlay; a customized host can approve its own images in its overlay.
- `upgrade.sh` refuses a tag that `release/approved-digests.json` does not approve.

## v1.0.34 - 2026-09-24

### Security

- `validate-config.sh` and `upgrade.sh` verify the cosign signatures of the ps-server and ps-client images against `release/cosign.pub`. `upgrade.sh` checks before it changes anything. Missing cosign (or cosign older than v3) is a warning, or a failure with `PADSIGN_REQUIRE_SIGNATURES=1`. The two releases from before signing (`ps-server:3.28`, `ps-client:8.39`) are exempt by digest.

## v1.0.33 - 2026-09-24

### Changed

- Documentation only: the guidance for customized hosts no longer tells operators to stay off the pinned Keycloak, and explains how to check and add the token-audience mapper before a cut-over.

## v1.0.32 - 2026-09-24

### Changed

- Pinned `ps-server:3.30` and `ps-client:8.40`, the first releases built by CI with an SBOM and provenance.
- `ps-server:3.30` runs on Node 24 as uid 1000 instead of root; `upgrade.sh` re-owns `signed-output/` accordingly. Filesystem routing is now a durable archive by default, receive-back endpoints check document ownership, and webhook permanent failures name the document.
- New capabilities `per-company-api-keys` and `durable-routing-archive` in `release/capabilities.json`.

**Upgrade impact:** a deployment that uses receive-back with the shared `REGISTER_PDF_API_KEY` must give each company its own `REGISTER_PDF_API_KEYS` entry, or the current Padsign Manager's download and acknowledge calls return `404`. See [7.5](documentation/07-05-register-pdf-api.md).

## v1.0.31 - 2026-09-24

### Changed

- Documentation only: release procedure notes for versions released before the current tagging scheme.

## v1.0.30 - 2026-09-24

### Fixed

- `keycloak-bootstrap.sh` re-checks before treating a failed realm or user creation as fatal, so a Keycloak that is still starting no longer aborts a bootstrap.

## v1.0.29 - 2026-09-24

### Security

- `update-hostname.sh` (and the wizard's Settings hostname change) no longer prints the Keycloak backend client secret.

## v1.0.28 - 2026-09-24

### Fixed

- `configure-host.sh` now also rewrites Keycloak's `KC_HOSTNAME` and nginx's network alias to the deployment's hostname. Before, they kept the shipped default, so tokens carried the wrong issuer. `update-hostname.sh` recreates nginx and Keycloak so the change takes effect.
- `validate-config.sh --host` fails when `KC_HOSTNAME` names another host, and `upgrade.sh` corrects an existing deployment automatically. Changing it changes the token issuer, so users sign in again.

## v1.0.27 - 2026-09-24

### Fixed

- Maintenance release for the deployment wizard's own tests; no change to a deployment.

## v1.0.26 - 2026-09-24

### Added

- `overlay.sh` (`capture` / `apply` / `verify` / `rebase` / `rehash`) turns a customized host into a clean release checkout plus an explicit overlay directory, so upgrades keep its customizations. See [9.11](documentation/09-11-start-at-boot-backups-and-customized-hosts.md).
- `validate-config.sh` reads the effective compose model (`.env`'s `COMPOSE_FILE` and profiles) and gains *Secret hygiene* checks: shipped credentials still in use, default admin password, world-readable `config.js`, `.env` or TLS key.

### Fixed

- Users created by `smoke-user.sh` and the bootstrap `test` user can complete a browser login on Keycloak 26.
- `verify-keycloak.sh` no longer fails its role check on every fresh realm.

### Security

- Keycloak passwords are no longer passed on the `docker compose exec` command line, and admin CLI sessions are removed after use. `diff-baseline-overlay.sh` redacts secrets in its output.

## v1.0.25 - 2026-09-24

### Added

- `monitor-status.sh --alert` raises alerts (down or unhealthy services, restarts, certificate expiry, archive, e-sealing and routing failures, disk pressure, receive-back backlog) and can post them to a webhook (`ALERT_WEBHOOK_URL`).
- `upgrade.sh --rollback-on-failure` rolls back automatically when services do not come up healthy.

### Changed

- `bootstrap.sh`, `upgrade.sh` and `rollback.sh` now exit with an error when services do not become healthy, instead of reporting success. The signing smoke test in `postdeploy-check.sh` is opt-in (`--signing-smoke`).

## v1.0.24 - 2026-09-24

### Fixed

- `upgrade.sh --server-tag/--client-tag` pins the approved digest when the release approves that tag, and `validate-config.sh` flags any image in `docker-compose.yml` without an approved digest.
- `rollback.sh` no longer restores an unpullable image reference on hosts using Docker's classic image store.

## v1.0.23 - 2026-09-24

### Fixed

- On Keycloak 26.7.4 every authenticated API call returned `401`, because newer Keycloak refuses token introspection by a client not in the token's audience. `keycloak-bootstrap.sh` now adds an audience mapper to new realms, and `upgrade.sh` adds it to existing ones. See [8.2](documentation/08-02-token-audience.md).

**Upgrade impact:** if `upgrade.sh` warns that it could not add the audience mapper (for example, Keycloak not reachable), add it by hand as described in [8.2](documentation/08-02-token-audience.md).

## v1.0.22 - 2026-09-24

### Fixed

- Pinned the container-signature service back to 24.3.0.29: 24.3.3.9 did not start with this configuration, and 24.3.0.49 changed the signature level after the first local e-seal.
- The container-signature `application.yml` sets a local mail host and disables the mail health check, so newer container-signature versions can start and stay healthy.

### Added

- `dmss-seal-smoke.sh` boots the container-signature and stamping images in a throwaway project and checks three consecutive local e-seals.

## v1.0.21 - 2026-09-23

### Fixed

- `signed-output/` and `docs/` are no longer created world-writable (`chmod 777`); they are owned by the user of the service that writes them.

### Added

- `diff-baseline-overlay.sh` compares a host's configuration against a release baseline and reports unexpected drift.
- `.gitignore` excludes `*.bak` files and the contents of `signed-output/`.

## v1.0.20 - 2026-09-23

### Security

- Every image in `docker-compose.yml` is pinned to an immutable `sha256` digest, recorded in `release/approved-digests.json`; `validate-config.sh` fails a missing or unapproved digest. nginx moved from `latest` to an explicit stable version. See [14.6](documentation/14-06-image-approval-and-digest-pinning.md).
- `check-digest-drift.sh` reports, read-only, when a registry serves a different digest for a pinned tag.

### Fixed

- `upgrade.sh` and `rollback.sh` no longer leave the old digest attached to a new or rolled-back tag.

## v1.0.19 - 2026-09-23

### Added

- Health checks on every long-running service, with start-up ordered on healthy dependencies.
- `postdeploy-check.sh` (one post-deployment check chaining the validators), `monitor-status.sh` (read-only status report) and `rollback.sh`, backed by a snapshot `upgrade.sh` takes before every change. See [9.8](documentation/09-08-rollback.md).
- `deployment-evidence.json` records image digests, configuration checksums and restart counts after each deployment.

## v1.0.18 - 2026-09-22

### Security

- Internal services no longer listen on all host interfaces. Keycloak (8080), archive (86) and container-signature (84) are bound to `127.0.0.1`; ps-server (3001) and the fallback archive (93) have no host port. nginx reaches all of them over the Docker network.

**Upgrade impact:** anything that reached ports 8080, 84, 86, 3001 or 93 directly from another machine must now go through nginx, or through the host (for example an SSH tunnel).

## v1.0.17 - 2026-09-22

### Added

- `smoke-user.sh create|delete` provisions and removes a short-lived test login with a single company role.
- Break-glass procedure for recovering Keycloak admin access. See [8.3](documentation/08-03-admin-password-and-break-glass.md).

### Fixed

- `keycloak-bootstrap.sh` no longer prints the demo `test` user's password, and `verify-keycloak.sh`'s JSON checks actually run.

## v1.0.16 - 2026-09-22

### Fixed

- `bootstrap.sh` and `upgrade.sh` warn, with the fix, when they cannot set permissions on the document storage directories, instead of reporting success.

## v1.0.15 - 2026-09-22

### Added

- `release/capabilities.json` lists the minimum image tag each feature needs, and `upgrade.sh --require-capability NAME` refuses an upgrade that would not provide it.

## v1.0.14 - 2026-08-11

### Added

- Guidance for AI coding assistants: an updated `AGENTS.md` and the `padsign-deploy` skill. See [14.4](documentation/14-04-ai-agent-deployment-skill.md).

## v1.0.13 - 2026-07-24

### Added

- The Deployment Wizard, an optional browser UI for installing and upgrading (`docker compose --profile wizard up -d wizard`), with a Settings page for changing hostname, renewing the TLS certificate and toggling features after go-live. See [3](documentation/03-install-with-the-wizard.md).
- `update-hostname.sh`, `renew-cert.sh` and `toggle-features.sh` for the same changes from the command line, and `verify-served-cert.sh` to check the certificate nginx is actually serving.

### Fixed

- `bootstrap.sh --admin-pass` now sets Keycloak's admin password; before, any value other than the default broke the bootstrap.
- Multi-word company roles (for example `"Acme Corp"`) work in `keycloak-bootstrap.sh` and `configure-host.sh --company-role`.
- The installation scripts are shipped executable, so no `chmod +x` is needed after cloning.

## Earlier releases

v1.0.0 (2025-09-09) through v1.0.12 (2026-07-20) established the stack: the Docker Compose deployment (nginx, Keycloak, ps-server, ps-client, DMSS services), the one-command `bootstrap.sh`, `upgrade.sh` and `validate-config.sh`, pre-flight TLS chain validation (`validate-certs.sh`), server-side post-signing document routing (`DOCUMENT_ROUTING`, filesystem and webhook) with its `signed-output` volume, the virtual-printer customer-data lookup (`CUSTOMER_DATA_*`) and barcode document numbers, the `SHOW_SIGNER_NAME` flag, receive-back (`ps-server:3.27`), dark mode (`ps-client:8.37`), and authenticated PDF download with route-protection guidance (`ps-client:8.38`).
