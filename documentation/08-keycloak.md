# 8. Keycloak

PadSign uses Keycloak for portal logins and API tokens. This section covers
what PadSign needs in Keycloak, how the scripts set it up, and how to manage
the admin account.

## Sub-sections

- [8.1 Automated setup](08-01-automated-setup.md)
- [8.2 Token audience for introspection](08-02-token-audience.md)
- [8.3 Admin password and break-glass recovery](08-03-admin-password-and-break-glass.md)
- [8.4 Manual setup (fallback only)](08-04-manual-setup.md)

## What PadSign needs in Keycloak

| Object | Name | Purpose |
|--------|------|---------|
| Realm | `padsign` | Everything PadSign uses lives here. |
| Public client | `padsign-client` | The portal (SPA) logs users in with it (Authorization Code flow). It carries the `padsign-backend-audience` mapper ([8.2](08-02-token-audience.md)). |
| Confidential client | `padsign-backend` | ps-server uses it to validate portal tokens (token introspection). In demo mode it also gets its own service-account token. Its secret goes into `config/config.js`. |
| Realm roles | `padsign-admin`, `psapp-integration`, `<CompanyRole>` | `<CompanyRole>` is the company name you pass as `--company-role`. ps-server reads a user's company from the first non-default realm role in the token. |
| Users | your portal users, each with their company role | The setup script also creates a demo user `test`. Delete it before go-live ([6](06-production-hardening.md#2-keycloak)). |

`bootstrap.sh` creates all of this in its step 5, and the wizard does the
same, because it runs `bootstrap.sh`. See [8.1](08-01-automated-setup.md).

## The Keycloak container

The `keycloak` service in `docker-compose.yml`:

- runs the image pinned in `docker-compose.yml` (see
  [14.3 Release snapshot](14-03-release-snapshot.md)) with
  `command: start-dev`;
- keeps its data, including the embedded H2 database, in the named volume
  `keycloak_data`;
- is served under `/auth` (`KC_HTTP_RELATIVE_PATH`) and reached from outside
  only through nginx at `https://padsign.example.com/auth/`;
- publishes port 8080 on `127.0.0.1` only, for diagnostics on the host. The
  scripts do not use that port: they run `kcadm.sh` inside the container with
  `docker compose exec`.

Development mode with H2 is not production-grade, and a production database
setup is on the PadSign roadmap: see
[6. Production hardening](06-production-hardening.md#2-keycloak). Back up
`keycloak_data` ([9.11](09-11-start-at-boot-backups-and-customized-hosts.md)).
It holds the realm, the clients, the users and the admin account.

Container environment variables are listed in
[7.6](07-06-environment-variables.md#keycloak-container).

## The admin console

Open `https://padsign.example.com/auth/admin/` and log in to the **master**
realm:

- **Username:** `admin`, or the value of `--admin-user`.
- **Password:** the value you gave `bootstrap.sh --admin-pass` (or the wizard).
  The demo default `admin` applies only to a Keycloak that first started
  without a password in `.env`. Change it before production.

Then switch to the `padsign` realm with the realm selector to manage clients
and users. To change the admin password, see
[8.3](08-03-admin-password-and-break-glass.md).

## Checking the setup

```bash
cd /opt/padsign
read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD
./installation-scripts/verify-keycloak.sh --host padsign.example.com --company-role "Acme"
unset KEYCLOAK_ADMIN_PASSWORD
```

`verify-keycloak.sh` checks the realm, `padsign-client` (URLs, redirect URIs,
post-logout URIs, web origins), the audience mapper, `padsign-backend`
(confidential, with service accounts), and that the `test` user, if still
present, has only the company role. It also runs a few stack checks: ps-server
running, nginx's redirect to `/portal/`, the Keycloak OIDC discovery endpoint,
`DOCUMENT_ROUTING` and the `signed-output` mount. It prints `OK` / `FAIL` per
check and exits non-zero on any failure.
