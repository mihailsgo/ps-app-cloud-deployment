# 14.2 Automated Setup (Recommended)

This repo includes an idempotent bootstrap script that creates the realm, clients, and required roles for you.

One-shot (Linux, recommended for new servers):

```bash
chmod +x ./installation-scripts/*.sh
./installation-scripts/bootstrap.sh --host padsign.trustlynx.com --company-role "YourCompany"
docker compose up -d
./installation-scripts/verify-keycloak.sh --host padsign.trustlynx.com --company-role "YourCompany"
```

Run (Linux):

```bash
docker compose up -d
./installation-scripts/keycloak-bootstrap.sh --host padsign.trustlynx.com --company-role "YourCompany"
```

Run (Windows PowerShell):

```powershell
docker compose up -d
.\installation-scripts\keycloak-bootstrap.ps1 -PublicHost padsign.trustlynx.com -CompanyRole "YourCompany"
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
   - User: `test` with password `<company role lowercased>` and role `<CompanyRole>`
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

