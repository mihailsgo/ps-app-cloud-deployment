# 37.2 Changing hostname after go-live

Changing a live deployment's hostname touches two systems that don't know
about each other: the config files nginx/ps-server/ps-client read, and
Keycloak's own client configuration (redirect URIs, web origins). Missing
either half produces a real failure mode — files-only leaves Keycloak
rejecting logins with "Invalid redirect URI"; Keycloak-only leaves nginx
serving the old hostname. Settings' Hostname card runs both in one action
so that failure mode isn't reachable through the UI.

## Using the wizard

1. Open **Settings** from the wizard's top bar, or `/settings` directly.
2. Under **Hostname**, enter the new hostname.
3. Provide a certificate for the *new* hostname — either:
   - Check **"the current certificate already covers the new hostname"**
     if it's a wildcard/multi-SAN cert. The wizard re-validates the
     existing certificate against the new hostname before proceeding and
     refuses if it doesn't actually match.
   - Or upload/paste a new certificate + key and click **Validate
     certificate**.
4. Enter the **current** Keycloak admin username/password (used to log in
   to Keycloak and sync its client config — never stored anywhere, exactly
   like onboarding's own admin-password field).
5. Click **Update Hostname** — shown in red, because it restarts live
   services. Confirm in the dialog and watch the live progress. nginx and
   ps-server both restart as part of this — expect a brief interruption.
   If the run fails, **Retry** re-runs it with the identical arguments; see
   [36.6](36-06-troubleshooting-the-wizard.md).

## What actually runs

`update-hostname.sh --host <new> --admin-pass <...> [--cert-crt/--cert-key]`:

1. **Backup** — `.bak` copies of `config.js`, `constants.json`,
   `nginx.conf`, `docker-compose.yml`, same convention as `bootstrap.sh`.
2. **`configure-host.sh --host <new>`** — the same file-rewriting engine
   [3.1](03-01-what-bootstrap-does-step-by-step.md) already uses, minus the
   Keycloak-admin-credential and feature-flag arguments (a hostname change
   doesn't touch either). The company/role name is read live from
   `config/config.js`'s `DEMO_COMPANY_ROLE` and passed straight through
   unchanged.

   > **Why a cert is always required here, even for "just" a hostname
   > change**: `configure-host.sh` unconditionally points `nginx.conf` at
   > `/etc/nginx/certs/<new-host>.{crt,key}`, regardless of whether that
   > file exists yet. A hostname change with no matching cert leaves nginx
   > unable to start. `update-hostname.sh` checks for a resolvable cert
   > *before* touching anything and refuses early if none is found.

3. **`keycloak-bootstrap.sh --host <new> --skip-test-user`** — updates the
   `padsign-client` Keycloak client's `redirectUris`/`webOrigins`/
   `rootUrl`/`baseUrl`/`adminUrl` for the new hostname. `--skip-test-user`
   is new (added for this feature) — without it, this step would silently
   delete and recreate the demo `test` Keycloak user with a fresh random
   password on every hostname change, which is fine during first bootstrap
   but a surprising side effect on an already-live deployment.
4. **Restart & verify** — `docker compose restart nginx ps-server`, then
   confirms ps-server actually came back up and the new hostname's root
   redirect responds.

## Running it without the wizard

```bash
./installation-scripts/update-hostname.sh \
  --host padsign.newclient.com \
  --admin-pass "CurrentKeycloakAdminPassword" \
  --cert-crt ./installation-scripts/certs/padsign.newclient.com.crt \
  --cert-key ./installation-scripts/certs/padsign.newclient.com.key
```

Omit `--cert-crt`/`--cert-key` if a cert for the new hostname is already
staged at `installation-scripts/certs/<new-host>.{crt,key}` (the same
default location `configure-host.sh`/`bootstrap.sh` already use).

## Verifying it worked

```bash
curl -kI https://padsign.newclient.com/          # expect a 301 to /portal/
docker compose logs ps-server --tail 20          # confirm it restarted cleanly
```

In Keycloak's admin console (`https://<host>/auth/admin/`), open the
`padsign-client` client under the `padsign` realm and confirm
**Valid redirect URIs** / **Web origins** reflect the new hostname.
