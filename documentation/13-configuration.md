# 13. Configuration

Review and adjust these files before running:

- `docker-compose.yml`
  - `KC_HOSTNAME` (keycloak service) must match your hostname, and nginx's network
    alias should. `configure-host.sh` (and so `bootstrap.sh` and
    `update-hostname.sh`) sets both; `validate-config.sh --host` checks them. It is
    not cosmetic: Keycloak uses `KC_HOSTNAME` as its fixed frontend hostname, so it
    decides the token issuer and the login form's URLs. Edited by hand, it only
    takes effect after `docker compose up -d keycloak` (a restart keeps the old value).
  - Host ports 80/443 must be free. Keycloak (8080) and the DMSS archive/container
    services (86, 84) publish to `127.0.0.1` only, for local operator diagnostics;
    ps-server (3001) and the DMSS fallback service (93) have no host port at all.
    See [22. Security and Route Protection](22-security-and-route-protection.md).
  - Image versions should match the release snapshot (`ps-server:3.27`, `ps-client:8.38`).

- `nginx/nginx.conf`
  - Update `server_name` and TLS files.
  - Proxy targets reach every internal service by Docker service name and container
    port (`/archive/api` → `dmss-archive-services:8090`, `/container/api` →
    `dmss-container-and-signature-services:8092`, `/api` → `ps-server:3001`, `/auth`
    → `keycloak:8080`) — nginx never leaves the Docker network to reach them.

- `config/config.js` (PS Server)
  - Update all hardcoded URLs from `https://padsign.trustlynx.com/...` to your hostname.
  - Set `KEYCLOAK_CONFIG` for your realm and backend client secret.
  - Adjust CORS: `ALLOWED_ORIGINS` should include your portal origin(s).
  - Set directories: `DOCUMENT_OUTPUT_DIRECTORY`, `READONLY_PDF_DIRECTORY` to writable paths where required by your runtime.
  - Signed-PDF receive-back (Padsign Manager / virtual printer): to let the Manager poll the signed PDF back to the originating desktop, set `DOCUMENT_ROUTING.enabled: true` and enable the `"filesystem"` strategy (writing to the bind-mounted `/signed-output`). After editing the bind-mounted `config/config.js`, run `docker compose restart ps-server` (Node caches `config.js`, so `up -d` alone is a no-op for this file). See `documentation/18-04-server-configconfigjs.md` and psapp `docs/document-routing-spec.md`.

- `config/constants.json` (PS Client)
  - Change `KEYCLOAK_URL`, `KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID`, and redirect URIs to match your hostname and Keycloak setup.
  - Update `PS_DOWNLOAD_API` and any other absolute URLs.
  - Optional: Branding (logo, page title) and UX parameters.

- `config/keycloak.js` (PS Client runtime Keycloak override)
  - Keep this file mounted to `/portal/keycloak.js` in `ps-client`.
  - This prevents fallback to bundled default host values inside client assets.
  - Use hostname-based values (recommended):
    - `url: ${window.location.origin}/auth`
    - `redirectUri: ${window.location.origin}/portal/`
    - `postLogoutRedirectUri: ${window.location.origin}/portal/`

- `dmss-container-and-signature-services/application.yml`
  - `archive-services.baseUrl` and `fallbackUrl` point to internal service names and typically do not need changes.
  - Trust stores and certificate files referenced under `/confs` must exist in `dmss-container-and-signature-services/`.

- `dmss-archive-services/application.yml`
  - Default uses in-memory HSQL database. For persistence, configure Postgres (uncomment and set `spring.datasource.*`) and provide the DB instance.

- `dmss-archive-services-fallback/application.yml`
  - File paths point to `/docs` inside the container. The `./docs` folder on the host is bind-mounted; `bootstrap.sh` and `upgrade.sh` create it automatically (`mkdir -p docs && chmod 777 docs`) so the container can write signed PDFs into it. If you create it manually, ensure it is writable by the container's UID. If `bootstrap.sh`/`upgrade.sh` already ran but signing still fails with a permissions error, Docker likely auto-created the directory as root before the script ran — see [20.1 Common Issues, issue 8](20-01-common-issues.md) for the fix.

- Keycloak database persistence
  - A named Docker volume `keycloak_data` is created by compose and used for Keycloak; back it up for production.

Secrets and credentials

- Do not commit real client secrets, keystore passwords, or API keys.
- Replace placeholder values before going live and rotate any credentials found in this repo.

---

