# 14.2 Automated Setup (Recommended)

This repo includes an idempotent bootstrap script that creates the realm, clients, and required roles for you.

One-shot (Linux, recommended for new servers) — this is the same full bootstrap
described in [3. Quick Start](03-quick-start-new-deployment.md); it starts the
stack itself, so no separate `docker compose up -d` is needed:

```bash
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

The demo `test` account's password is generated fresh on every run but is
**only shown when this script is run at an interactive terminal** — it is
never written to stdout/stderr, so it never lands in a captured log (CI
output, a redirected file, or the deployment wizard's live progress view). If
you ran this non-interactively and need to log in as `test`, either re-run
interactively, or provision a disposable credential instead (see below).

Compatibility notes (important):
- `installation-scripts/keycloak-bootstrap.sh` in this package was updated for Keycloak 26 compatibility:
  - readiness check uses `http://localhost:8080/`
  - avoids shell reserved variable `UID`
  - strips quoted CSV IDs returned by `kcadm.sh`
  - sets client `name` fields for `padsign-client` and `padsign-backend` (same as client IDs)

If bootstrap still fails in your environment, perform these manual activities:
1. Bootstrap Keycloak manually in admin UI:
   - Realm: `padsign`
   - Roles: `padsign-admin`, `psapp-integration`, `<CompanyRole>`
   - User: `test` with role `<CompanyRole>` and a password of your choosing (the automated script generates a random password and shows it once, only when run at an interactive terminal)
   - Clients:
     - `padsign-client` (public), Name: `padsign-client`
     - `padsign-backend` (confidential + service accounts), Name: `padsign-backend`
2. Set these values for `padsign-client`:
   - Redirect URIs:
     - `https://<host>/portal/*`
     - `https://<host>/portal/`
     - `https://<host>/portal`
   - Web Origins:
     - `https://<host>/portal/`
     - `https://<host>/portal`
3. Copy backend client secret to:
   - `config/config.js` -> `KEYCLOAK_CONFIG.credentials.secret`

## Disposable smoke-test users

The `test` account above is fixed (always that username) and destructive to
regenerate — every re-run of `keycloak-bootstrap.sh` deletes and recreates it,
which is a live-stack side effect you might not want on demand. For a
one-off login check without touching `test`, use `smoke-user.sh` to mint a
uniquely-named, disposable user and delete it again when done:

```bash
./installation-scripts/smoke-user.sh create --host <host> --company-role "YourCompany"
# ... log in as the printed username, using the password shown once on screen ...
./installation-scripts/smoke-user.sh delete --host <host> --username <the printed username>
```

Requires the realm and the given `--company-role` to already exist (run
`keycloak-bootstrap.sh` first) — it only ever creates/deletes the one user it
names, assigns exactly the role you pass (never `padsign-admin`), and never
restarts Keycloak. Like the `test` account's password, the generated
password is shown once at an interactive terminal only.

Pass the Keycloak admin password through the environment
(`read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD`), not
`--admin-pass`: a command-line argument is visible to every local user in `ps`
and lands in shell history. The smoke user is created with a first and last
name because Keycloak 26's user profile requires both. Without them the first
browser login stops at an "Update your account information" form instead of
returning to the portal. The full twice-in-a-row smoke procedure, including
what to check in the browser, is
[42.2 K5](42-02-keycloak-admin-access-and-smoke-identity.md).

