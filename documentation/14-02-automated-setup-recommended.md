# 14.2 Automated Setup (Recommended)

This repo includes an idempotent bootstrap script that creates the realm, clients, and required roles for you.

One-shot (Linux, recommended for new servers) — this is the same full bootstrap
described in [3. Quick Start](03-quick-start-new-deployment.md); it starts the
stack itself, so no separate `docker compose up -d` is needed:

```bash
chmod +x ./installation-scripts/*.sh
./installation-scripts/bootstrap.sh --host <host> --company-role "YourCompany" --admin-pass "StrongKeycloakAdminPass"
./installation-scripts/verify-keycloak.sh --host <host> --company-role "YourCompany"
```

Keycloak-only (stack already running, Linux):

```bash
docker compose up -d
./installation-scripts/keycloak-bootstrap.sh --host <host> --company-role "YourCompany"
```

Keycloak-only (Windows PowerShell):

```powershell
docker compose up -d
.\installation-scripts\keycloak-bootstrap.ps1 -PublicHost <host> -CompanyRole "YourCompany"
```

The script prints the backend client secret; set it in `config/config.js` under `KEYCLOAK_CONFIG.credentials.secret`.

Compatibility notes (important):
- `installation-scripts/keycloak-bootstrap.sh` in this package was updated for Keycloak 26 compatibility:
  - readiness check uses `http://localhost:8080/`
  - avoids shell reserved variable `UID`
  - strips quoted CSV IDs returned by `kcadm.sh`
  - sets client `name` fields for `padsign-client` and `padsign-backend` (same as client IDs)

If bootstrap still fails in your environment, perform these manual activities:
1. Ensure scripts are executable:
   - `chmod +x ./installation-scripts/*.sh`
2. Bootstrap Keycloak manually in admin UI:
   - Realm: `padsign`
   - Roles: `padsign-admin`, `psapp-integration`, `<CompanyRole>`
   - User: `test` with role `<CompanyRole>` and a password of your choosing (the automated script generates a random password and prints it at the end of its run)
   - Clients:
     - `padsign-client` (public), Name: `padsign-client`
     - `padsign-backend` (confidential + service accounts), Name: `padsign-backend`
3. Set these values for `padsign-client`:
   - Redirect URIs:
     - `https://<host>/portal/*`
     - `https://<host>/portal/`
     - `https://<host>/portal`
   - Web Origins:
     - `https://<host>/portal/`
     - `https://<host>/portal`
4. Copy backend client secret to:
   - `config/config.js` -> `KEYCLOAK_CONFIG.credentials.secret`

