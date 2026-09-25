# 22. Security and Route Protection

- TLS termination: All external traffic enters via NGINX on 443; HTTP 80 redirects to HTTPS.
- Public routes:
  - `/portal/*` serves the SPA. The SPA itself gates features by user auth state.
  - `/auth/*` proxies to Keycloak for login, tokens, and account management.
  - `/api/*` proxies to the backend (ps-server). Authentication depends on endpoint:
    - external integration endpoints accept API key bearer token (`REGISTER_PDF_API_KEY`)
    - internal operator endpoints require Keycloak bearer token
  - `/container/api/*` and `/archive/api/*` proxy to DMSS services. For production, restrict these (IP allowlist, mTLS) or enforce JWT on the services.
- SPA authentication (frontend): Uses Keycloak (public client). Recommended flow is Authorization Code with PKCE. The SPA obtains an access token and attaches it as `Authorization: Bearer <token>` to API calls.
- Backend enforcement (ps-server): applies auth by endpoint, including API-key protection for external registration endpoints and Keycloak JWT validation for internal operator endpoints. CORS should be restricted to known origins in `config/config.js`.
- Header forwarding (DMSS): `dmss-container-and-signature-services` is configured to forward `Authorization` and other headers to the archive service. Align DMSS auth to your policy.
- Enabling JWT on DMSS Archive (recommended for prod): In `dmss-archive-services/application.yml` set `authentication.jwt.enabled: true` and configure either `useCert: true` with a public key/cert or a shared `secret`, and set `validation: true`.
- NGINX hardening: If DMSS endpoints should not be directly reachable from the internet, remove or restrict the `/container/api` and `/archive/api` locations, or protect them with allowlists or client certificates.
- Keycloak admin: Limit admin console access (IP allowlist/VPN) and change the default admin password immediately.

## Secrets on the host

- **`docker-compose.yml` is tracked and world-readable: no secret belongs in
  it.** Anything in it shows up in `git diff` and in the git objects of every
  `git stash` an upgrade takes. The Keycloak admin password therefore lives in
  `.env` as `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD`, which compose passes to
  Keycloak ([17.1](17-01-keycloak-container-environment-variables.md), with
  the move for deployments bootstrapped before v1.0.42).
- **`.env`** is git-ignored and mode 600. Only `docker compose` reads it, as
  the user who runs it; no container does. When bootstrap runs as root, the
  file is given to the owner of the deployment directory, so that user can
  still run `docker compose`.
- **Values shipped in this public repository.** A fresh `bootstrap.sh`
  replaces `REGISTER_PDF_API_KEY` and `SESSION_SECRET` with random values,
  once: a value anyone already changed is kept. The backend client secret
  comes from Keycloak. The demo e-sealing `STAMP_API_KEY` /
  `STAMP_COMPANY_SECRET` come from your provider and cannot be generated;
  `validate-config.sh` keeps warning until they are yours (or `STAMP_MODE` is
  `"local"`). Reading the API key for the Virtual Printer:
  [18.5](18-05-cloud-flow-apiregisterpdf.md#reading-the-api-key).
- **`config/config.js`** holds the backend client secret, the API key, the
  session secret and the e-sealing credentials, so other users should not
  read it. ps-server must: from 3.30 it runs as uid 1000 (`node`), not root.
  The model (`installation-scripts/lib/dir-permissions.sh`): the file keeps
  its owner, gets the gid the pinned ps-server image runs as, and mode 640.
  `configure-host.sh` (so also `bootstrap.sh`, `update-hostname.sh`,
  `renew-cert.sh`, `toggle-features.sh`) applies it at the end of every run
  and then reads the file from inside the image to prove ps-server still can.
  `overlay.sh apply` does the same and fails rather than widen the mode.
  `validate-config.sh` and `overlay.sh verify` check it.
  - Never `chmod o-rwx config/config.js` alone on a root-owned file. With
    ps-server 3.30 that crash-loops it with `EACCES: permission denied, open
    '/usr/src/app/config.js'`, and nginx never starts, because it waits for a
    healthy ps-server. The fix `validate-config.sh` prints is
    `sudo chgrp 1000 config/config.js && sudo chmod 640 config/config.js`
    (1000 being the gid it read from the image).
  - Run the installation scripts as root, as that uid, or as a member of that
    group. `perl -i` / `sed -i` write a new file as the user running them and
    keep the group only if that user may set it. For anyone else,
    `configure-host.sh` leaves the file readable instead of locking ps-server
    out, and says so. `upgrade.sh` rewrites `config.js` only for a config
    migration (for example `--enable-local-eseal`) and does not re-apply the
    model: run `validate-config.sh` after it.
- **Backups** (`*.bak`) that `bootstrap.sh` and `configure-host.sh` write are
  readable by their owner only: `config/config.js.bak` holds the same secrets
  as `config/config.js`.
- `config/config.js` itself is still a tracked file, so its secrets are in
  `git diff` and in upgrade stashes. Keep the checkout's `.git` as private as
  the file, or run the host as release baseline + overlay
  ([42](42-host-reconciliation-runbook.md)), where they live outside the
  checkout.

## Protecting `/archive/api` and `/container/api` with an Authorization header

The recommended pattern needs no application changes and is enforced entirely at nginx:

- Add `satisfy any; allow <docker-subnet>; deny all; auth_basic ...;` to both locations. Internal ps-server traffic reaches nginx through the Docker network alias and passes on source IP alone; every outside caller must send `Authorization: Basic ...`. Credentials live in an `htpasswd` file dropped into the already-mounted `nginx/certs` folder.
- Keycloak (8080) and the DMSS archive/container services (86, 84) are bound to
  `127.0.0.1` only by default in `docker-compose.yml`; ps-server (3001) and the DMSS
  fallback service (93) have no host port at all — nginx reaches all of them over the
  internal Docker network. This means a permissive AWS security group alone can no
  longer expose them; `installation-scripts/validate-config.sh` fails if any of
  these bind to a non-loopback interface without an explicit allow-list entry. Treat
  this as defense-in-depth alongside the security group, not a replacement for it.

### The document download route

`GET /archive/api/document/{docid}/download` accepts either credential, so it works for both callers:

- the pad browser (`ps-client` at or above the `closable-download-route` minimum in `release/capabilities.json`) sends the user's Keycloak Bearer token
- a 3rd-party system sends the same `Authorization: Basic ...` credential used for `/archive/api` and `/container/api`

Keep the Docker-subnet `allow` (ps-server's own internal downloads send no credential at all) and add both `auth_basic` and an `auth_request` check against Keycloak's userinfo endpoint to the same location; `satisfy any` grants access if either one passes.

Copy-paste instructions with the exact nginx blocks: https://github.com/mihailsgo/tl-service-route-protection

**Check the client is new enough before you close the route.** An older `ps-client` fetches that URL anonymously, so closing it breaks the PDF viewer. The minimum tag is recorded in `release/capabilities.json` as `closable-download-route`; assert it and the upgrade refuses rather than leaving you to find out from a broken viewer:

```bash
./installation-scripts/upgrade.sh --client-tag 8.38 \
  --require-capability closable-download-route
```

Add `--plan-only` to check the current pin without changing anything.

