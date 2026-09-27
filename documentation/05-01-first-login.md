# 5.1 First login

This page gets you into the PadSign portal and the Keycloak admin console for the first time, and
gives you a user to log in with. Replace `padsign.example.com` with your hostname.

## The URLs

| URL | What it is |
|---|---|
| `https://padsign.example.com/` | Redirects to the portal |
| `https://padsign.example.com/portal/` | The PadSign portal, for signers |
| `https://padsign.example.com/auth/admin/` | Keycloak admin console, for administrators |
| `https://padsign.example.com/auth/realms/padsign/account/` | Keycloak account console, where a user can change their own password |

`http://` addresses redirect to `https://`.

## Log in to the Keycloak admin console

Open `https://padsign.example.com/auth/admin/` and log in with:

- **Username:** `admin`, or the name you set with `--admin-user` / in the wizard.
- **Password:** the Keycloak admin password you set during install (`--admin-pass` or
  `KEYCLOAK_ADMIN_PASSWORD` for `bootstrap.sh`, or the wizard's host step). The installer also
  stores it in `/opt/padsign/.env` as `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD` (mode 600).

This account lives in Keycloak's `master` realm. Switch to the `padsign` realm (realm selector, top
left) to see what the installer created:

- clients `padsign-client` (the portal) and `padsign-backend` (ps-server);
- realm roles `padsign-admin`, `psapp-integration` and your company role, for example `Example Corp`;
- the demo user `test`, which has only the company role.

If you cannot log in at all, see [8.3 Admin password and break-glass](08-03-admin-password-and-break-glass.md).

## Get a user for the portal

A portal user is a user in the `padsign` realm who has your company role. Use one of these:

### The demo `test` user

The installer creates `test` (email `test@<company-role>.padsign`, lower-case with spaces turned
into dashes) with a random password. The password is printed once, and only when the installer runs
at an interactive terminal:

```
  Test user password (shown once, not logged): ...
```

It is never written to a log. After a wizard install you therefore never see it, because the wizard
does not run the installer at a terminal. Use a smoke-test user instead.

### A disposable smoke-test user (recommended)

`smoke-user.sh` creates a uniquely named user with only the company role, and shows its password
once on your terminal. Pass the Keycloak admin password through the environment, not as a flag,
where every local user could see it in `ps`:

```bash
cd /opt/padsign
read -rsp 'Keycloak admin password: ' KEYCLOAK_ADMIN_PASSWORD; echo
export KEYCLOAK_ADMIN_PASSWORD
./installation-scripts/smoke-user.sh create --host padsign.example.com --company-role "Example Corp"
```

It prints the username (`smoke-` plus 8 random characters), the role and the password, and the
command to delete the user again. `--company-role` must match the role exactly; you can see it under
**Realm roles** in the `padsign` realm, or as `DEMO_COMPANY_ROLE` in `config/config.js`. The script
refuses `padsign-admin`. If no terminal is attached, it does not print the password at all; delete
that user and run the command again interactively.

Delete the user when you are done:

```bash
./installation-scripts/smoke-user.sh delete --host padsign.example.com --username smoke-a1b2c3d4
unset KEYCLOAK_ADMIN_PASSWORD
```

### A real user

In the admin console, `padsign` realm:

1. **Users > Add user.** Fill in username, email, **first name and last name**. Keycloak requires
   all three profile fields; a user without them is stopped at an "Update your account information"
   form on first login.
2. **Credentials > Set password.**
3. **Role mapping > Assign role**, filter by realm roles, and assign your company role only. Do not
   give ordinary portal users `padsign-admin` or `psapp-integration`: ps-server takes the signer's
   company from their realm role, and those two are privileged API roles.

## Log in to the portal

1. Open `https://padsign.example.com/portal/`. You are redirected to the Keycloak login page.
2. Log in with the user from above. You are redirected back to `/portal/`.
3. The portal then waits for a document registered for you. It checks every few seconds; nothing is
   shown until an integration registers a PDF for this user (or, with demo mode enabled, you upload
   one yourself). To test a complete signing without an integration, run the
   [5.4 Signing smoke test](05-04-signing-smoke-test.md).
4. Log out and check that you return to the login page.

If the login page does not appear, you are sent to another hostname, or you land back on the login
page in a loop, see [12. Troubleshooting](12-troubleshooting.md).

## Before production

- **Delete the `test` user** (`padsign` realm > Users > `test` > Action > Delete). It is a shared
  login with a known role. A later run of `bootstrap.sh` or `keycloak-bootstrap.sh` recreates it, so
delete it again after any such run.
- **Delete leftover smoke users** with `smoke-user.sh delete`.
- **Change the Keycloak admin password** if you installed with a temporary or weak one. Changing
  `.env` does not change it: Keycloak reads that value only on its very first start. Use the admin
  console or the procedure in [8.3 Admin password and break-glass](08-03-admin-password-and-break-glass.md).

The full list is in [6. Production hardening](06-production-hardening.md).
