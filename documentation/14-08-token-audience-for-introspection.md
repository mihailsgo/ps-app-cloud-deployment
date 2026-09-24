# 14.8 Token audience for introspection (Keycloak 26.4.12+ / 26.6.2+)

## What changed in Keycloak

ps-server checks every authenticated portal API call by sending the user's
`padsign-client` access token to Keycloak's token-introspection endpoint,
authenticating as the confidential `padsign-backend` client.

Keycloak 26.4.12, 26.6.2, 26.7.0 and every later release only answer that
introspection if the calling client is in the token's `aud` (audience) claim.
This is the upstream fix for CVE-2026-37979. A stock `padsign-client` token
carries only `aud: "account"`, so on these versions Keycloak answers
`{"active": false}` and ps-server returns **401 on every authenticated API
call**, even though the portal login itself succeeds. Keycloak 26.3.x and older
never checked the audience.

## Symptoms

- Login to the portal works, then every API call (signing, stamping, `/api/health`
  with a token) returns `401 Unauthorized`.
- The Keycloak log shows:

  ```
  type="INTROSPECT_TOKEN_ERROR" ... clientId="padsign-backend" ... error="invalid_token",
  reason="Client 'padsign-backend' is not in the token audience", token_issued_for="padsign-client"
  ```

## The fix: an audience mapper on padsign-client

An `oidc-audience-mapper` on `padsign-client`, named `padsign-backend-audience`,
adds `padsign-backend` to the access token's audience
(`aud: ["padsign-backend", "account"]`). This is harmless on older Keycloak
versions. Already logged-in users pick it up on their next token refresh, so
nobody needs to log out.

You normally do not need to do anything by hand:

- **New deployments:** `bootstrap.sh` → `keycloak-bootstrap.sh` creates the mapper.
- **Existing deployments:** `upgrade.sh` runs the `keycloak-backend-audience`
  migration on every run (see [5.1](05-01-what-upgrade-does-step-by-step.md),
  step 7). Preview it with `--plan-only`. It needs the Keycloak admin
  credentials. They come from `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` if
  those are set in your shell, otherwise from the keycloak container's own
  environment (the values in `docker-compose.yml`). If you changed the admin
  password in the admin console since then (see
  [37.5](37-05-known-gaps-keycloak-admin-password-rotation.md)), pass it
  explicitly:

  ```bash
  KEYCLOAK_ADMIN_PASSWORD='<current admin password>' ./installation-scripts/upgrade.sh --server-tag <tag> --plan-only
  ```

  If Keycloak cannot be reached, `upgrade.sh` prints a `WARNING` naming the
  reason and carries on with the rest of the upgrade.

- **Check an existing realm:** `verify-keycloak.sh` reports
  `padsign-client access tokens carry padsign-backend in aud` as `OK` or `FAIL`.

## Adding the mapper by hand

### Admin console

1. Realm `padsign` → **Clients** → `padsign-client` → **Client scopes** tab →
   `padsign-client-dedicated`.
2. **Configure a new mapper** (or **Add mapper → By configuration**) → **Audience**.
3. Set:
   - **Name**: `padsign-backend-audience`
   - **Included Client Audience**: `padsign-backend`
   - **Add to access token**: On
   - **Add to token introspection**: On
   - **Add to ID token**: Off
4. **Save**.

### Command line (from the deployment directory)

```bash
docker compose exec -T keycloak sh -c '
  A="--no-config --server http://localhost:8080/auth --realm master --user admin --password <admin password>"
  CID=$(/opt/keycloak/bin/kcadm.sh get clients -r padsign -q clientId=padsign-client --fields id --format csv --noquotes $A | tail -1)
  /opt/keycloak/bin/kcadm.sh create clients/$CID/protocol-mappers/models -r padsign $A \
    -s name=padsign-backend-audience -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.client.audience\"=padsign-backend" \
    -s "config.\"access.token.claim\"=true" \
    -s "config.\"introspection.token.claim\"=true" \
    -s "config.\"id.token.claim\"=false"'
```

No restart is needed. ps-server does not cache the result, and Keycloak applies
the mapper to the next token it issues.

## If you pin an older Keycloak instead

Staying on Keycloak 26.3.x also avoids the 401s, but it leaves the deployment
exposed to CVE-2026-37979 and the other CVEs fixed in 26.6.2. The audience
mapper is the supported fix.
