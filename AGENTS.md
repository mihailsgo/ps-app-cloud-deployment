# CLAUDE.md — PadSign Deployment (ps-app-cloud-deployment)

## What is this project?

Docker Compose deployment stack for [PadSign](C:\Repos\psapp) (psapp) — a web-based PDF document signing application by TrustLynx. This repo contains no *PadSign product* source code (ps-server/ps-client live in `psapp`); it orchestrates pre-built Docker images and their runtime configuration, and additionally contains the source for its own optional operator-facing deployment-wizard tool (`deployment-wizard/` — deployment tooling, not product code; see *Deployment Wizard* below). Supports configurable post-signing document routing (filesystem save, webhook delivery) via `DOCUMENT_ROUTING` in `config/config.js`.

The application source code lives in `C:\Repos\psapp`.

## Services deployed

```
nginx (reverse proxy, :443)
├── /portal/     → ps-client  (React SPA)
├── /api/        → ps-server  (Express, :3001)
├── /auth/       → Keycloak   (:8080)
├── /archive/api → dmss-archive-services (:86)
└── /container/api → dmss-container-and-signature-services (:84)
```

Plus `dmss-archive-services-fallback` (:93) as a filesystem-based archive backup, and — only when the `local-eseal` compose profile is active — `dmss-digital-stamping-service` (internal port 8084; no host port mapping by default) for **local e-sealing** (see *Local e-sealing* below). Also — only when the `wizard` compose profile is active — a `wizard` container (:8443) providing an optional browser UI for bootstrap/upgrade (see *Deployment Wizard* below).

## Directory structure

```
ps-app-cloud-deployment/
├── docker-compose.yml                # All service definitions, networking, volumes
├── config/
│   ├── config.js                     # PS Server runtime config (API URLs, Keycloak creds, feature flags)
│   ├── constants.json                # PS Client runtime config (UI, translations, Keycloak public client)
│   ├── keycloak.js                   # Keycloak JS adapter overrides
│   └── TLlogo.png                    # Branding logo
├── nginx/
│   ├── nginx.conf                    # Reverse proxy routes, TLS termination
│   ├── certs/                        # TLS certificates (git-ignored)
│   └── mkcert.exe                    # Local cert generation tool
├── installation-scripts/
│   ├── bootstrap.sh                  # One-shot setup: hostname + Keycloak + secrets
│   ├── configure-host.sh             # Rewrite config files for a new hostname
│   ├── keycloak-bootstrap.sh         # Idempotent Keycloak realm/client/role/user creation
│   ├── keycloak-bootstrap.ps1        # Windows PowerShell equivalent
│   ├── verify-keycloak.sh            # Verify Keycloak setup
│   └── certs/                        # Place PEM certs here for bootstrap
├── dmss-archive-services/            # Spring config for document archive
├── dmss-archive-services-fallback/   # Spring config for filesystem fallback archive
├── dmss-container-and-signature-services/  # Spring config for signing service
│   └── documentsigningprofiles.json  # profile catalog; LocalDemo is the demo profile
├── dmss-digital-stamping-service/    # Local e-sealing stamping service config (opt-in)
│   ├── application.yml               # stamping.companies → keystore mapping
│   ├── seal/seal.p12                 # demo PKCS12 keystore (NOT for production)
│   └── seal/README.md                # how to swap in a real cert
├── installation-scripts/assets/dmss-digital-stamping-service/  # pristine reference copies upgrade.sh uses to seed existing deployments
├── deployment-wizard/                 # Source for the optional browser deployment wizard (its own Docker image)
│   ├── server.js / app.js            # Express entrypoint + wiring (self-signed TLS, session, routes)
│   ├── lib/                          # scriptRunner, outputParser, cert/config validators, state detection
│   ├── routes/ , views/ , public/     # Express routes, EJS templates, static assets
│   └── Dockerfile                    # node:18-bookworm-slim (NOT alpine — scripts need grep -oP)
├── .env                              # contains COMPOSE_PROFILES=local-eseal when local mode is active
└── docs/                             # Signed documents output (fallback archive)
```

## How to deploy

Prefer a browser over the CLI? `docker compose --profile wizard up -d wizard` starts an optional guided UI wrapping the same scripts below — see *Deployment Wizard* further down. Everything in this section still works unchanged whether or not the wizard is ever used.

### First-time setup (fully automated)

```bash
./installation-scripts/bootstrap.sh \
  --host padsign.client.com \
  --company-role "ClientName" \
  --admin-pass "StrongPassword" \
  --cert-crt ./installation-scripts/certs/padsign.client.com.crt \
  --cert-key ./installation-scripts/certs/padsign.client.com.key
```

This handles everything end-to-end: config rewrites, directory creation, Keycloak setup, Docker pull, service startup, and verification. Optional flags: `--enable-routing` (filesystem document routing), `--enable-demo` (demo mode), `--enable-local-eseal` (provision local e-sealing — see *Local e-sealing* below).

### Upgrade existing deployment

```bash
./installation-scripts/upgrade.sh --server-tag 3.22 --client-tag 8.34
# or to opt an existing deployment into local e-sealing without a tag bump:
./installation-scripts/upgrade.sh --enable-local-eseal
```

Backs up config, updates image tags, ensures latest config patterns (DOCUMENT_ROUTING, volume mounts), pulls images, restarts containers. With `--enable-local-eseal`: idempotent Step 4b stages the demo stamping artefacts, appends the gated `dmss-digital-stamping-service` compose service block, patches container-signature's `digital-stamping-service.baseUrl`, pins `SPRING_SECURITY_USER_*` env vars on container-signature, inserts `STAMP_MODE: "local"` + `STAMP_LOCAL` into `config/config.js`, and writes `COMPOSE_PROFILES=local-eseal` to `.env`. Safe to re-run; full operator playbook (incl. demo-cert verification, real-cert swap, and rollback levels) is in `documentation/04-enabling-local-e-sealing.md`.

### Validate configuration

```bash
./installation-scripts/validate-config.sh --host padsign.client.com
```

### Verify the certificate nginx is actually serving

```bash
./installation-scripts/verify-served-cert.sh --host padsign.client.com
```

Read-only wire check: opens a real TLS handshake and compares the SERVED
certificate against the one on disk. This is the only check that catches a
renewal which landed on disk but never reached nginx — nginx reads its
certificate files only at startup and on reload, so `validate-certs.sh` and
every other file-level check pass throughout that failure. See
`documentation/11-02-monitoring-the-served-certificate.md`.

### Deploy a new app version (from source)

1. In `C:\Repos\psapp`, build and push new Docker images for `ps-client` and/or `ps-server`
2. Run `upgrade.sh` with the new tags

## Key config files

| File | Mounted into | Purpose |
|------|-------------|---------|
| `config/config.js` | ps-server | API endpoints, Keycloak backend creds, feature flags, concurrency settings, `DOCUMENT_ROUTING` (post-signing actions), `CUSTOMER_DATA_*` (virtual-printer customer lookup) |
| `config/constants.json` | ps-client | UI config, translations (LV/EN), Keycloak public client, signing params |
| `config/keycloak.js` | ps-client | Keycloak JS adapter init overrides |
| `nginx/nginx.conf` | nginx | Reverse proxy routes, TLS, hostname |
| `dmss-archive-services/application.yml` | dmss-archive | DB config (HSQLDB default), archive connections |
| `dmss-container-and-signature-services/application.yml` | dmss-signing | Signing profiles, archive URLs, DigiDoc4j config. `digital-stamping-service.baseUrl` points at the host or in-network stamping; `--enable-local-eseal` rewrites it to `http://dmss-digital-stamping-service:8084/api`. |
| `dmss-container-and-signature-services/documentsigningprofiles.json` | dmss-signing | Profile catalog. Pre-existing `TrustLynx` / `TrustLynxLV` / `TrustLynxLV_ASICE` plus the new `LocalDemo` (B_BES, anchored to demo cert). |
| `dmss-digital-stamping-service/application.yml` | dmss-digital-stamping-service | `stamping.companies` mapping company name → keystore (when local e-sealing is active). |
| `dmss-digital-stamping-service/seal/seal.p12` | dmss-digital-stamping-service | The demo PKCS12 keystore (DEMO ONLY — replace before production). |
| `.env` | docker compose | Holds `COMPOSE_PROFILES=local-eseal` to make `docker compose up -d` auto-include the stamping service. |

## Authentication

- **Keycloak** realm: `padsign`
- Public client: `padsign-client` (used by React SPA)
- Backend client: `padsign-backend` (bearer-only, used by Express server)
- Roles: `padsign-admin`, `psapp-integration`
- Default admin: `admin/admin` — must change in production

## Local e-sealing

This deployment supports two e-sealing paths chosen at deploy time:

- **External (default).** ps-server calls a cloud e-sealing service configured via `STAMP_API_URL` / `STAMP_API_KEY` / `STAMP_COMPANY_ID` / `STAMP_COMPANY_SECRET` in `config/config.js`. This is the path historical deployments use; nothing about it has changed.
- **Local (opt-in).** ps-server calls an in-stack `dmss-container-and-signature-services` `/api/eseal/document/profile/<X>` endpoint, which delegates to a new `dmss-digital-stamping-service` container that holds the signing keystore. Nothing leaves the host.

### How it's enabled

Single source of truth is the `STAMP_MODE` field in `config/config.js`. The `dmss-digital-stamping-service` container has `profiles: ["local-eseal"]` in `docker-compose.yml`, so it does not start unless that profile is active. `.env` carries `COMPOSE_PROFILES=local-eseal` to make plain `docker compose up -d` include it automatically. The three pieces (config field, profile, .env) must be consistent.

### Fresh install

```bash
./installation-scripts/bootstrap.sh \
  --host padsign.client.com --company-role "..." --admin-pass "..." \
  --cert-crt ... --cert-key ... \
  --enable-local-eseal
```

### Existing deployment upgrade

```bash
cd /opt/psapp && git pull
./installation-scripts/upgrade.sh --enable-local-eseal
```

Idempotent. Either of those flag-bearing invocations stages the demo stamping artefacts, edits compose to add the gated stamping service block, patches the container-signature `application.yml`, pins `SPRING_SECURITY_USER_NAME=user` / `SPRING_SECURITY_USER_PASSWORD=changeit` on container-signature (so basic auth between ps-server and container-signature is stable), inserts `STAMP_MODE: "local"` and a `STAMP_LOCAL` block into `config/config.js`, and writes `COMPOSE_PROFILES=local-eseal` to `.env`.

### Default-behaviour invariant

A customer pulling the new repo version and running plain `docker compose up -d` (without `--enable-local-eseal`, without `COMPOSE_PROFILES=local-eseal`) sees ZERO behavioural change. The stamping container is profile-gated and never starts; `STAMP_MODE` defaults to `"external"`; container-signature env vars and `digital-stamping-service.baseUrl` are unchanged in the baseline files.

### Switching modes after install

Pure config edits, no scripts required. The bind-mounted `config.js` change requires `docker compose restart ps-server` to be re-read (Node's `require()` caches it). See `documentation/04-enabling-local-e-sealing.md` -> *4.5 Switching modes after install* for the exact recipes.

### Demo credentials shipped (must rotate before production)

Three `changeit` defaults so the demo "just works":
1. `dmss-digital-stamping-service/seal/seal.p12` keystore password
2. `dmss-digital-stamping-service/application.yml` → `password:` under `providers` (must equal #1)
3. `SPRING_SECURITY_USER_PASSWORD` on container-signature in `docker-compose.yml` — and the matching `STAMP_LOCAL.password` in `config/config.js`

The keystore password (rows 1-2) unlocks the signing key; the Spring Security password (row 3 + `STAMP_LOCAL.password`) gates the HTTP endpoint container-signature exposes on host port 84.

### Operator playbook locations

The customer-facing playbook lives in `documentation/04-enabling-local-e-sealing.md` (sections 4.1 Concepts and glossary -> 4.2 Architecture deep-dive -> 4.3 Initial deployment -> 4.4 Existing-deployment walkthrough -> 4.5 Switching modes -> 4.6 Production setup with your own key+cert -> 4.7 Adding a new signing profile -> 4.8 Wiring TSA+OCSP -> 4.9 Verifying it works -> 4.10 Verifying signatures end-to-end). The root `README.md` is now a content map only - it lists every section as a link into the `documentation/` folder. Always defer to those files for customer questions; this CLAUDE.md is the AI-agent crib sheet.

### Code references (when assisting development)

- ps-server source: `C:\Repos\psapp\server\app.js` — `STAMP_STRATEGIES` table (lines ~1170-1248) is the only mode-dispatch code. `server/test-strategies.js` is a 27-case unit test.
- This repo's scripts that touch local-eseal: `installation-scripts/bootstrap.sh` (flag passthrough), `installation-scripts/configure-host.sh` (provisioning block at end of script), `installation-scripts/upgrade.sh` (Step 4b — idempotent provisioning + restart of `dmss-container-and-signature-services` + `ps-server`).
- Pristine demo artefacts: `installation-scripts/assets/dmss-digital-stamping-service/` — `upgrade.sh` copies these via `cp -n` (non-destructive: never overwrites customer modifications).

## Deployment Wizard (optional GUI)

An optional browser UI (`deployment-wizard/`, its own Docker image `mihailsgordijenko/padsign-wizard`) that guides an operator through the same `bootstrap.sh`/`upgrade.sh` work above, with inline TLS-cert validation and live per-step progress instead of raw terminal output. It **wraps** the existing scripts as child processes and parses their stdout — it never reimplements config rewriting, Keycloak setup, or `docker compose` orchestration. Ignoring it and running the scripts by hand behaves identically; nothing about its presence changes default behaviour (same invariant as local e-sealing above).

### How it's enabled

Gated behind the `wizard` compose profile — never starts on a plain `docker compose up -d`. Unlike local e-sealing, this is NOT meant to persist via `.env`'s `COMPOSE_PROFILES` — it's a tool you start on demand:

```bash
cd /opt/psapp   # MUST run from the project root — see below
docker compose --profile wizard up -d wizard
docker logs padsign-wizard   # prints the access token + URL
```

### Why the project-root requirement matters

The wizard mounts `/var/run/docker.sock` (the first and only service in this compose file to do so — see *Security* note below) plus the project directory at the identical absolute path on both sides (`${PWD}:${PWD}` / `working_dir: ${PWD}`). When the wizard later runs `docker compose` on the operator's behalf, that command actually executes against the **host's** daemon via the socket — which needs the project directory at a path it recognizes to resolve the stack's own relative bind mounts. Running the initial `up` command from anywhere but the project root breaks this alignment.

### Security note

`/var/run/docker.sock` access is root-equivalent host access — a meaningfully more privileged container than anything else in this stack. The mitigation is controlling who can reach it: HTTPS-only (self-signed, regenerated every start, independent of the real PadSign hostname cert), a random access token printed to `docker logs padsign-wizard` on every start (no user/password DB), 2-hour session idle timeout. Full detail in `documentation/36-05-security-considerations.md`.

### Code references (when assisting development)

- Wizard source: `deployment-wizard/` — `lib/scriptRunner.js` (the only module that spawns `bootstrap.sh`/`upgrade.sh`), `lib/outputParser.js` (parses their existing stdout — `Step N/M:` markers, ad hoc `<name>: OK` checks, and the cleaner `OK`/`FAIL`/`WARN` helper convention `validate-certs.sh`/`validate-config.sh` already use), `lib/stateDetector.js` (derives FRESH/DEPLOYED/DEPLOYED_STOPPED/UNKNOWN from `.bak` files + live `docker compose ps` — no wizard-side database anywhere).
- Test fixtures: `deployment-wizard/test/fixtures/` — real captured script output. If wording changes in any `installation-scripts/*.sh` echo/printf, refresh these fixtures and re-run `deployment-wizard/test/*.test.js` (`npm test` inside `deployment-wizard/`) or the wizard's live-progress parsing can quietly degrade.
- Operator playbook: `documentation/36-deployment-wizard.md` (sections 36.1 Concepts and access model -> 36.2 Starting the wizard -> 36.3 Fresh-install walkthrough -> 36.4 Upgrade walkthrough -> 36.5 Security considerations -> 36.6 Troubleshooting -> 36.7 Relationship to the CLI scripts).

## Environment management

No built-in dev/staging/prod separation. Per-environment config is managed by:
1. Running `configure-host.sh` with the target hostname
2. Editing config files (`config.js`, `constants.json`) for environment-specific endpoints
3. Placing appropriate TLS certificates in `nginx/certs/`

## No CI/CD

Deployment is manual via `docker compose`. No GitHub Actions, Jenkins, or other pipelines are configured. The wizard image is built/published the same manual way as `ps-server`/`ps-client`: `docker build -t mihailsgordijenko/padsign-wizard:<version> deployment-wizard && docker push mihailsgordijenko/padsign-wizard:<version>`, then bump the tag in `docker-compose.yml`.

## Documentation conventions

- Root `README.md` is a content map only - 1 entry per H2 section linking into `documentation/`. No prose, no embedded section content.
- **Exception**: README.md may carry one short "Quick Start" pointer above the numbered list, recommending the Deployment Wizard (section 36) as the easy/guided path and cross-linking the CLI Quick Start (section 3) as the alternative. Wayfinding only — no embedded technical details, version tags, or examples that could drift out of sync with `documentation/`. Added 2026-07-21.
- Every H2 section has its own file `documentation/NN-<slug>.md`. Every H3 sub-section has its own file `documentation/NN-MM-<slug>.md`. Operator can hand a client a direct URL: section X.Y -> `documentation/0X-0Y-<slug>.md`.
- Section headers carry their hierarchical number (`# 4.5 Switching modes after install`) so a client can locate "section 4.5" both via the ToC link and by reading the page title.
- **Do NOT add Change history / Changelog / dated What's new sections** to README.md or any documentation file. Git history is the source of truth for what changed and when. Stated explicitly by the user on 2026-05-13.
