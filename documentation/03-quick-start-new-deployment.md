# 3. Quick Start (New Deployment)

One command to deploy PadSign on a new server:

```bash
./installation-scripts/bootstrap.sh \
  --host padsign.client.com \
  --company-role "ClientName" \
  --admin-pass "StrongKeycloakAdminPass" \
  --cert-crt ./installation-scripts/certs/padsign.client.com.crt \
  --cert-key ./installation-scripts/certs/padsign.client.com.key
```

## 3.1 What bootstrap does (step by step)

1. **Validates inputs** - checks required parameters (host, company-role, admin-pass) and verifies dependencies (docker, docker compose, python3, perl, curl)
2. **Backs up config files** - creates `.bak` copies of `config/config.js`, `config/constants.json`, `nginx/nginx.conf`, and `docker-compose.yml` for safe rollback
3. **Rewrites config for hostname** (`configure-host.sh`):
   - `nginx/nginx.conf`: sets `server_name`, TLS cert paths, and root→`/portal/` redirect
   - `config/constants.json`: sets Keycloak URL, redirect URIs, download API URL
   - `config/config.js`: sets all service URLs, `ALLOWED_ORIGINS`, Keycloak `auth-server-url`, `DEMO_COMPANY_ROLE`
   - `docker-compose.yml`: ensures `signed-output` volume mount exists on ps-server
   - Copies TLS certificates to `nginx/certs/` (if provided)
   - Injects `DOCUMENT_ROUTING` config block if missing (disabled by default)
   - Validates JSON syntax of `constants.json` after editing
4. **Creates `signed-output/` directory** - writable directory for filesystem document routing
5. **Bootstraps Keycloak** (`keycloak-bootstrap.sh`):
   - Starts Keycloak container and waits for health endpoint
   - Creates realm (`padsign`) if not exists
   - Creates roles: `padsign-admin`, `psapp-integration`, and the company role
   - Creates frontend client (`padsign-client`) - public, OIDC, with correct redirect URIs
   - Creates backend client (`padsign-backend`) - confidential, bearer-only, service accounts enabled
   - Creates test user with the company role assigned and a random password
   - Optionally creates additional users from `--users` parameter
6. **Writes backend client secret** - captures the auto-generated Keycloak client secret and writes it into `config/config.js`
7. **Pulls Docker images** - `docker compose pull` for all services
8. **Starts all services** - `docker compose up -d`
9. **Verifies deployment**:
   - Checks ps-server logs for successful startup
   - Tests root redirect (expects 301 → `/portal/`)
   - Lists all running containers with image versions
10. **Prints summary** - portal URL, Keycloak admin URL, API URL, test user credentials

## 3.2 Bootstrap parameters

| Parameter | Required | Description |
|---|---|---|
| `--host` | Yes | Hostname for the deployment (e.g., `padsign.client.com`) |
| `--company-role` | Yes | Company name / Keycloak realm role (e.g., `"Acme"`) |
| `--admin-pass` | Yes | Keycloak admin password (must be strong for production) |
| `--cert-crt` / `--cert-key` | No | TLS certificate files (or place in `installation-scripts/certs/`) |
| `--realm` | No | Keycloak realm name (default: `padsign`) |
| `--admin-user` | No | Keycloak admin username (default: `admin`) |
| `--users` | No | Additional users: `"user1:pass1:role,user2:pass2:role"` |
| `--enable-routing` | No | Enable filesystem document routing after signing |
| `--enable-demo` | No | Enable DEMO mode in client |
| `--enable-local-eseal` | No | Provision local e-sealing (stamping container + demo PKCS12) and set `STAMP_MODE=local`. External e-sealing remains the default when this flag is omitted. See [Enabling local e-sealing](04-enabling-local-e-sealing.md#4-enabling-local-e-sealing). |

