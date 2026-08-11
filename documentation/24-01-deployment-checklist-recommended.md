# 24.1 Deployment Checklist (Recommended)

Run these steps in order on a clean target host:

1. Prepare runtime files
   - Set hostname values in:
     - `config/constants.json`
     - `config/config.js`
   - Ensure `config/keycloak.js` exists and points to your current host (or uses `window.location.origin` as provided).
   - Place TLS files for your host:
     - `installation-scripts/certs/<host>.crt`
     - `installation-scripts/certs/<host>.key`

2. Bootstrap and start
```bash
chmod +x ./installation-scripts/*.sh
./installation-scripts/bootstrap.sh --host <host> --company-role "<CompanyRole>"
docker compose up -d
```

3. Verify runtime overrides and auth wiring
```bash
curl -kI https://<host>/portal/keycloak.js
curl -k https://<host>/portal/keycloak.js
curl -kI https://<host>/portal/
curl -kI https://<host>/auth/
```
- `/portal/keycloak.js` must return `200` and `Content-Type: application/javascript`.
- If browser still shows old host in console, do a hard refresh (`Ctrl+F5`) or open in Incognito.

4. If bootstrap fails
   - Follow manual fallback steps in `Keycloak Setup` section (client names, roles, test user, backend secret copy to `config/config.js`).

