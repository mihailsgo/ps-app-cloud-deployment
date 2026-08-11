# 3.1 What bootstrap does (step by step)

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

