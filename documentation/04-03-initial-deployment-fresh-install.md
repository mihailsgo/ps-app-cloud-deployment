# 4.3 Initial deployment (fresh install)

Pass `--enable-local-eseal` to `bootstrap.sh` and the stack comes up with
local e-sealing ready to use:

```bash
./installation-scripts/bootstrap.sh \
    --host padsign.client.com \
    --company-role "ClientName" \
    --admin-pass "StrongKeycloakAdminPass" \
    --cert-crt ./installation-scripts/certs/padsign.client.com.crt \
    --cert-key ./installation-scripts/certs/padsign.client.com.key \
    --enable-local-eseal
```

What happens additionally when the flag is set:

- `dmss-digital-stamping-service/` is staged with the demo `application.yml`,
  `seal/seal.p12`, and a `seal/README.md` explaining the demo cert.
- The new service block (gated by `profiles: ["local-eseal"]`) is appended
  to `docker-compose.yml` if not already present.
- `dmss-container-and-signature-services/application.yml` is patched so its
  `digital-stamping-service.baseUrl` resolves to the in-network container.
- `SPRING_SECURITY_USER_NAME=user` / `SPRING_SECURITY_USER_PASSWORD=changeit`
  are pinned on container-signature so basic auth from ps-server is stable.
- `STAMP_MODE: "local"` and a `STAMP_LOCAL` block are inserted into
  `config/config.js` (or `STAMP_MODE` is flipped if it already existed).
- `COMPOSE_PROFILES=local-eseal` is appended to `.env` so every subsequent
  `docker compose up -d` includes the new service automatically.

---

