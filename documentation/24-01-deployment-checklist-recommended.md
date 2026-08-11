# 24.1 Deployment Checklist (Recommended)

Run these steps in order on a clean target host:

1. Prepare TLS files for your host (see [11.1 TLS Prerequisites](11-01-tls-prerequisites-for-installation-scripts.md)):
   - `installation-scripts/certs/<host>.crt` (full chain)
   - `installation-scripts/certs/<host>.key` (unencrypted)

2. Bootstrap and start — one command, as in [3. Quick Start](03-quick-start-new-deployment.md).
   Bootstrap rewrites all hostname values in `config/constants.json`, `config/config.js`
   and `nginx/nginx.conf` for you, sets up Keycloak, and starts the whole stack —
   do **not** hand-edit the config files first, and no separate `docker compose up -d`
   is needed afterwards:

```bash
chmod +x ./installation-scripts/*.sh
./installation-scripts/bootstrap.sh \
  --host <host> \
  --company-role "<CompanyRole>" \
  --admin-pass "<StrongKeycloakAdminPass>" \
  --cert-crt ./installation-scripts/certs/<host>.crt \
  --cert-key ./installation-scripts/certs/<host>.key
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
   - Follow manual fallback steps in [14. Keycloak Setup](14-keycloak-setup.md) (client names, roles, test user, backend secret copy to `config/config.js`).
