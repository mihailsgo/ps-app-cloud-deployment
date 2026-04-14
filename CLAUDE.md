# CLAUDE.md — PadSign Deployment (ps-app-cloud-deployment)

## What is this project?

Docker Compose deployment stack for [PadSign](C:\Repos\psapp) (psapp) — a web-based PDF document signing application by TrustLynx. This repo contains no application source code; it orchestrates pre-built Docker images and their runtime configuration. Supports configurable post-signing document routing (filesystem save, webhook delivery) via `DOCUMENT_ROUTING` in `config/config.js`.

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

Plus `dmss-archive-services-fallback` (:93) as a filesystem-based archive backup.

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
└── docs/                             # Signed documents output (fallback archive)
```

## How to deploy

### First-time setup

```bash
./installation-scripts/bootstrap.sh --host example.com --company-role "CompanyName"
```

This runs `configure-host.sh` (rewrites hostnames in all config files) and `keycloak-bootstrap.sh` (creates realm, clients, roles, users).

### Start / update the stack

```bash
docker compose up -d
```

### Deploy a new app version

1. In `C:\Repos\psapp`, build and push new Docker images for `ps-client` and/or `ps-server`
2. Update image tags in `docker-compose.yml` here
3. `docker compose up -d`

## Key config files

| File | Mounted into | Purpose |
|------|-------------|---------|
| `config/config.js` | ps-server | API endpoints, Keycloak backend creds, feature flags, concurrency settings, `DOCUMENT_ROUTING` (post-signing actions) |
| `config/constants.json` | ps-client | UI config, translations (LV/EN), Keycloak public client, signing params |
| `config/keycloak.js` | ps-client | Keycloak JS adapter init overrides |
| `nginx/nginx.conf` | nginx | Reverse proxy routes, TLS, hostname |
| `dmss-archive-services/application.yml` | dmss-archive | DB config (HSQLDB default), archive connections |
| `dmss-container-and-signature-services/application.yml` | dmss-signing | Signing profiles, archive URLs, DigiDoc4j config |

## Authentication

- **Keycloak** realm: `padsign`
- Public client: `padsign-client` (used by React SPA)
- Backend client: `padsign-backend` (bearer-only, used by Express server)
- Roles: `padsign-admin`, `psapp-integration`
- Default admin: `admin/admin` — must change in production

## Environment management

No built-in dev/staging/prod separation. Per-environment config is managed by:
1. Running `configure-host.sh` with the target hostname
2. Editing config files (`config.js`, `constants.json`) for environment-specific endpoints
3. Placing appropriate TLS certificates in `nginx/certs/`

## No CI/CD

Deployment is manual via `docker compose`. No GitHub Actions, Jenkins, or other pipelines are configured.
