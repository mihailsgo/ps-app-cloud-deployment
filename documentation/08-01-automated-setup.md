# 8.1 Automated setup

`installation-scripts/keycloak-bootstrap.sh` creates everything PadSign
needs in Keycloak. It is idempotent, so you can re-run it safely. You normally
never run it yourself: `bootstrap.sh` runs it in step 5 of 8 and writes the
backend client secret into `config/config.js` in step 6. The wizard runs
`bootstrap.sh`, so it does the same.

## What the script does

1. Starts the keycloak container (`docker compose up -d keycloak`) and waits
   up to 120 seconds for it to accept connections.
2. Logs in to the master realm with `kcadm.sh` inside the container. The
   password is passed through the environment, never on a command line. The
   kcadm session file is removed when the script exits.
3. Creates realm `padsign` (or `--realm`) if it does not exist.
4. Creates the realm roles `padsign-admin`, `psapp-integration` and your
   `--company-role` if they are missing.
5. Deletes and re-creates the demo user `test` with a new random 12-character
   password, email `test@<company-role, lower case, spaces as hyphens>.padsign`,
   first and last name `Test User`, and only the company role. With
   `--skip-test-user` it leaves the `test` user alone.
6. Creates `padsign-client` if missing, then always sets its URLs:
   - Root URL, Home URL, Admin URL: `https://<host>/portal/`
   - Valid redirect URIs: `https://<host>/portal/*`, `https://<host>/portal/`,
     `https://<host>/portal`
   - Valid post logout redirect URIs: the same three
   - Web origins: `https://<host>/portal/`, `https://<host>/portal`
   - Public client, Standard flow on, Direct access grants and Implicit flow off
7. Adds the `padsign-backend-audience` mapper to `padsign-client` unless a
   mapper that adds `padsign-backend` to the audience already exists
   ([8.2](08-02-token-audience.md)).
8. Creates `padsign-backend` if missing: confidential, service accounts on,
   all login flows off.
9. Creates any `--users` you passed and sets their passwords and roles.
10. Prints a summary and, last, `BACKEND_CLIENT_SECRET=<secret>` on standard
    output.

The script reads the secret of an existing `padsign-backend`. It never
rotates it, so re-running it returns the same secret.

## Running it on its own

Use this to repair or re-sync a realm on a running stack, for example after
restoring Keycloak or when `verify-keycloak.sh` reports a `FAIL`:

```bash
cd /opt/padsign
read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD   # current admin password, not echoed

out="$(./installation-scripts/keycloak-bootstrap.sh --host padsign.example.com --company-role "Acme" --skip-test-user)"
printf '%s\n' "$out" | grep -v '^BACKEND_CLIENT_SECRET='

# Write the backend secret into config/config.js and load it:
CONFIGURE_HOST_BACKEND_SECRET="$(printf '%s\n' "$out" | sed -n 's/^BACKEND_CLIENT_SECRET=//p')" \
  ./installation-scripts/configure-host.sh --host padsign.example.com
docker compose restart ps-server

unset out KEYCLOAK_ADMIN_PASSWORD
```

`configure-host.sh --host` also rewrites every hostname setting and the certificate paths for
that host, and copies `installation-scripts/certs/<host>.crt`/`.key` into `nginx/certs/` if they
exist. Use exactly the hostname already deployed, so those stay as they are.

Leave out `--skip-test-user` only if you want the `test` user re-created.

Options (`keycloak-bootstrap.sh --help`):

| Option | Default | Meaning |
|--------|---------|---------|
| `--host` | `$KC_HOSTNAME` | Deployment hostname (required). |
| `--company-role` | none | Company realm role (required). |
| `--realm` | `padsign` | Realm name. |
| `--admin-user` | `$KEYCLOAK_ADMIN` or `admin` | Master-realm admin. |
| `--admin-pass` | `$KEYCLOAK_ADMIN_PASSWORD` or `admin` | Admin password. Prefer the environment variable: a flag is visible in `ps`. |
| `--users` | none | Extra users, `"alice:Passw0rd!:padsign-admin,bob:Passw0rd!"` (`user:password[:role]`). These passwords are on the command line too, so for real users prefer the admin console. |
| `--skip-test-user` | off | Do not touch the `test` user. `update-hostname.sh` uses this. |

`Invalid user credentials` at login means the admin password is wrong. On an
existing Keycloak, the password in `.env` is not necessarily the current one
([8.3](08-03-admin-password-and-break-glass.md)).

## The test user's password

The `test` password is printed **only when the script runs at an interactive
terminal**. It is written straight to the terminal, never to standard output
or standard error, so it never lands in a captured log, the wizard's progress
view or CI output. After a wizard install, or any non-interactive run, you
therefore never see it. Use a disposable smoke-test user instead (below).
Delete `test` before go-live ([6](06-production-hardening.md#2-keycloak)).

## Disposable smoke-test users

`smoke-user.sh` creates a uniquely named login (`smoke-<random>`) with only
the company role you give it (never `padsign-admin`), and deletes it again. It
does not touch the realm, the clients, the roles or `test`, and it never
restarts Keycloak:

```bash
read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD
./installation-scripts/smoke-user.sh create --host padsign.example.com --company-role "Acme"
# log in at https://padsign.example.com/portal/ with the printed username and the password shown once
./installation-scripts/smoke-user.sh delete --host padsign.example.com --username smoke-a1b2c3d4
unset KEYCLOAK_ADMIN_PASSWORD
```

- The realm and the company role must already exist.
- The password is shown once, at an interactive terminal only. Without a
  terminal it cannot be recovered: delete the user and run `create` again
  interactively.
- `delete` refuses usernames that do not start with `smoke-` unless you add
  `--force`. Deleting a user that does not exist counts as success.
- The user gets a first and last name, as Keycloak 26's user profile
  requires. Without them the first browser login would stop at an "Update
  your account information" form.

## Rotating the backend client secret

1. In the admin console, open realm `padsign`, then **Clients** →
   `padsign-backend` → **Credentials** → **Regenerate**, and copy the new
   secret.
2. Write it into `config/config.js` and restart ps-server:

   ```bash
   read -rs CONFIGURE_HOST_BACKEND_SECRET && export CONFIGURE_HOST_BACKEND_SECRET
   ./installation-scripts/configure-host.sh --host padsign.example.com
   unset CONFIGURE_HOST_BACKEND_SECRET
   docker compose restart ps-server
   ```

   `configure-host.sh --host` also rewrites every hostname setting and the certificate paths for
   that host, and copies `installation-scripts/certs/<host>.crt`/`.key` into `nginx/certs/` if they
   exist. Use exactly the hostname already deployed, so those stay as they are.

Portal API calls fail with `401` between steps 1 and 2.

## Verifying

```bash
./installation-scripts/verify-keycloak.sh --host padsign.example.com --company-role "Acme"
```

See [8. Keycloak](08-keycloak.md#checking-the-setup) for what it checks. If
the automated setup cannot complete in your environment, the manual steps
are in [8.4](08-04-manual-setup.md).
