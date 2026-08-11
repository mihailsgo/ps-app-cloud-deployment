# 14.3 Access Keycloak Admin Panel (Manual / Verification)

1. Start the containers:
   ```bash
   docker compose up -d
   ```

2. Access Keycloak admin panel:
   ```
   https://<host>/auth/
   ```
   - Username: `admin`
   - Password: the value you passed to `bootstrap.sh --admin-pass`. The compose
     default `admin` applies only if you never ran bootstrap — a demo value
     that must be changed before production
     (see [25. Production Hardening](25-production-hardening.md)).
