# 3.1 What bootstrap does (step by step)

1. **Validates inputs** - checks required parameters (host, company-role, admin-pass) and verifies dependencies (docker, docker compose, python3, perl, curl)
2. **Backs up config files** - creates `.bak` copies of `config/config.js`, `config/constants.json`, `nginx/nginx.conf`, and `docker-compose.yml` for safe rollback
3. **Rewrites config for hostname** (`configure-host.sh`):
   - `nginx/nginx.conf`: sets `server_name`, TLS cert paths, and root→`/portal/` redirect
   - `config/constants.json`: sets Keycloak URL, redirect URIs, download API URL
   - `config/config.js`: sets all service URLs, `ALLOWED_ORIGINS`, Keycloak `auth-server-url`, `DEMO_COMPANY_ROLE`
   - `config/config.js`: replaces `REGISTER_PDF_API_KEY` and `SESSION_SECRET` with
     random values (`--generate-secrets`) if they still hold the values shipped in
     this public repository. A value already changed is kept, so a re-run changes
     nothing. Neither is printed; the Virtual Printer / Manager needs the API key,
     read it as in [18.5](18-05-cloud-flow-apiregisterpdf.md#reading-the-api-key)
   - `.env` (git-ignored, created mode 600): the Keycloak admin password, as
     `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD`. It is never written into the tracked
     `docker-compose.yml`, which only references it; an inline value left by an
     older bootstrap is replaced by that reference
     ([17.1](17-01-keycloak-container-environment-variables.md))
   - `docker-compose.yml`: ensures `signed-output` volume mount exists on ps-server;
     sets the keycloak service's `KC_HOSTNAME` and the nginx service's first network
     alias to the host; syncs `KEYCLOAK_ADMIN` (the user name). `KC_HOSTNAME`
     is Keycloak's fixed frontend hostname: it decides the token issuer and the login
     form's URLs, so a stale value sends browsers to another host at login
   - Copies TLS certificates to `nginx/certs/` (if provided)
   - Injects `DOCUMENT_ROUTING` config block if missing (disabled by default)
   - Validates JSON syntax of `constants.json` after editing
   - Gives `config/config.js` the group of the uid the pinned ps-server image runs
     as (1000 from 3.30) and mode 640, then reads it from inside that image to prove
     ps-server still can. Done only when you run bootstrap as root, as that uid or
     as a member of that group, because otherwise a later script edit would drop the
     group and lock ps-server out; the file is then left readable and
     `validate-config.sh` says what to run. See
     [22](22-security-and-route-protection.md#secrets-on-the-host)
   - Backups (`*.bak`) are made readable by their owner only
4. **Creates `signed-output/` (mode 750) and `docs/` (mode 770), each owned by
   the uid its container image actually runs as** (read from the pinned image:
   uid 1000 for the Node 24 ps-server image, root for older ones; 10001 for
   dmss-archive-services-fallback 24.1.x). Stops with the exact `sudo chown`
   fix if it can't. See
   [installation-scripts/lib/dir-permissions.sh](../installation-scripts/lib/dir-permissions.sh)
   for why ownership and not 777
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
10. **Records deployment evidence** - writes `deployment-evidence.json`
    (git-ignored) with this repo's git revision/dirty flag, the pinned image
    tags and their OCI revision labels, sha256 checksums of the four
    per-host-mutated config files, and which optional features are enabled.
    It also records, per service, the running image digest, the restart count,
    the restart delta against the previous `deployment-evidence.json` (kept as
    `deployment-evidence.json.previous`; `null` on a fresh host), and whether
    the service is `running`, `absent` (a profile-gated service -
    `dmss-digital-stamping-service`, `wizard` - whose profile is not active)
    or `not_running`. Written once per run, so the delta covers everything
    since the last recorded run.
11. **Prints summary** - portal URL, Keycloak admin URL, API URL, where the admin
    password is stored, the command that shows `REGISTER_PDF_API_KEY` (never the
    key itself), and the test user (its password only at an interactive terminal)

