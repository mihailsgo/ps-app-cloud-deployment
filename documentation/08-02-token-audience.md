# 8.2 Token audience for introspection

ps-server checks every authenticated portal API call by sending the user's
`padsign-client` access token to Keycloak's token-introspection endpoint,
authenticated as the confidential `padsign-backend` client. For that to
work, `padsign-backend` must be in the token's audience (`aud` claim). This
page explains the mapper that puts it there and how to check or add it.

## Why the mapper is needed

Keycloak 26.4.12, 26.6.2, 26.7.0 and every later release answer an
introspection request only if the calling client is in the token's audience.
This is Keycloak's fix for CVE-2026-37979. A plain `padsign-client` token
carries only `aud: "account"`, so without the mapper Keycloak answers
`{"active": false}` and ps-server returns `401` on every authenticated API
call, even though the portal login itself succeeds.

The mapper is an `oidc-audience-mapper` named `padsign-backend-audience` on
`padsign-client`. It adds `padsign-backend` to the access token
(`aud: ["padsign-backend", "account"]`). It is harmless on Keycloak versions
that do not check the audience. Users who are already logged in pick it up on
their next token refresh, so nobody has to log out.

## Symptoms when it is missing

- Portal login works, then every API call (signing, stamping, `/api/health`
  with a token) returns `401 Unauthorized`.
- The Keycloak log (`docker compose logs keycloak`) shows:

  ```
  type="INTROSPECT_TOKEN_ERROR" ... clientId="padsign-backend" ... error="invalid_token",
  reason="Client 'padsign-backend' is not in the token audience", token_issued_for="padsign-client"
  ```

## Who creates it

- **New deployments:** `bootstrap.sh` runs `keycloak-bootstrap.sh`, which
  creates the mapper ([8.1](08-01-automated-setup.md)).
- **Existing deployments:** `upgrade.sh` checks for it on every run (step
  4c of 6, the `keycloak-backend-audience` migration) and adds it when it is
  missing. Preview it with `--plan-only` ([9.7](09-07-previewing-upgrade-changes.md)).
  Any mapper that already adds `padsign-backend` to the audience counts,
  including one you added by hand, and is left alone.

`upgrade.sh` needs the Keycloak admin credentials for this. It takes
`KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` from your shell if set, and
otherwise the keycloak container's own environment, which holds the
first-boot password from `.env`. If you changed the admin password since
Keycloak first started ([8.3](08-03-admin-password-and-break-glass.md)),
export the current one:

```bash
read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD
./installation-scripts/upgrade.sh --plan-only
unset KEYCLOAK_ADMIN_PASSWORD
```

If Keycloak is not running or the login fails, `upgrade.sh` prints a
`WARNING` with the reason and carries on with the rest of the upgrade.
Re-run it once Keycloak is up, or add the mapper by hand (below).

## Checking a realm

`verify-keycloak.sh` reports
`padsign-client access tokens carry padsign-backend in aud (token introspection)`
as `OK` or `FAIL` ([8. Keycloak](08-keycloak.md#checking-the-setup)).

## Adding the mapper by hand

### Admin console

1. Realm `padsign` → **Clients** → `padsign-client` → **Client scopes** tab →
   `padsign-client-dedicated`.
2. **Configure a new mapper** (or **Add mapper** → **By configuration**) →
   **Audience**.
3. Set:
   - **Name:** `padsign-backend-audience`
   - **Included Client Audience:** `padsign-backend`
   - **Add to access token:** On
   - **Add to token introspection:** On
   - **Add to ID token:** Off
4. **Save**.

### Command line

Run from the deployment directory. The admin password reaches `kcadm.sh` as
`KC_CLI_PASSWORD`, which kcadm reads when `--password` is absent, so it is
on no command line:

```bash
cd /opt/padsign
read -rs KC_CLI_PASSWORD && export KC_CLI_PASSWORD   # the Keycloak admin password
docker compose exec -T -e KC_CLI_PASSWORD keycloak sh -c '
  K=/opt/keycloak/bin/kcadm.sh
  A="--no-config --server http://localhost:8080/auth --realm master --user admin"
  CID=$($K get clients -r padsign -q clientId=padsign-client --fields id --format csv --noquotes $A | tail -n 1 | tr -d "\r")
  $K create clients/$CID/protocol-mappers/models -r padsign $A \
    -s name=padsign-backend-audience -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.client.audience\"=padsign-backend" \
    -s "config.\"access.token.claim\"=true" \
    -s "config.\"introspection.token.claim\"=true" \
    -s "config.\"id.token.claim\"=false"' </dev/null
unset KC_CLI_PASSWORD
```

Replace `--user admin` if your admin has another name. No restart is needed.
Keycloak applies the mapper to the next token it issues, and ps-server does
not cache introspection results.

## Pinning an older Keycloak instead

Staying on a Keycloak release that does not check the audience also avoids
the `401`s, but leaves the deployment exposed to CVE-2026-37979 and the other
fixes in those releases. The audience mapper is the supported fix. Keep the
Keycloak image the release pins ([14.3](14-03-release-snapshot.md)).
