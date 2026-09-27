# 5.4 Signing smoke test

`installation-scripts/signing-smoke.sh` signs one synthetic document on the live deployment, as a
real Keycloak user, and checks the result. It is safe to run on a production host: the test document
never reaches your routing destinations, webhooks or the Manager's receive-back buffer, and the run
removes everything it created. Use it after an install or upgrade to prove the stack actually signs.

## Before you run it

- An **interactive terminal** on the host. The temporary user's password is shown there once and
  nowhere else.
- A **browser** on any machine that can reach `https://<host>/`, for example your workstation. You
  approve the run there; the host needs no display.
- The **Keycloak admin password**. The script reads it from `KEYCLOAK_ADMIN_PASSWORD` or asks for it
  (hidden). It refuses `--admin-pass`, so the password never appears on a command line.
- About a minute of your time. The run cannot be unattended.

## Run it

```bash
cd /opt/padsign
read -rsp 'Keycloak admin password: ' KEYCLOAK_ADMIN_PASSWORD; echo
export KEYCLOAK_ADMIN_PASSWORD
./installation-scripts/signing-smoke.sh --host padsign.example.com
unset KEYCLOAK_ADMIN_PASSWORD
```

Or as step 7 of the post-deploy checks:
`./installation-scripts/postdeploy-check.sh --host padsign.example.com --signing-smoke`
([5.3](05-03-post-deploy-checks.md)).

The script creates a disposable `smoke-...` user, shows its password, and then prints a URL and a
code:

1. Open the URL in a **private** browser window. The code is already filled in, so you go straight
   to the Keycloak sign-in page.
2. Log in as the printed `smoke-...` user with the password from the terminal.
3. On **Grant Access to PadSign signing smoke test (temporary)**, choose **Yes**.
4. When the page reads **Device Login Successful**, close the window. The script continues by itself.

If you log in with any other account by mistake, the run stops before it calls the API, and cleans
up.

## Options

| Option | Meaning |
|---|---|
| `--host <host>` | Your PadSign hostname. Required. |
| `--realm <name>` | Keycloak realm (default `padsign`). |
| `--admin-user <name>` | Keycloak admin user (default `$KEYCLOAK_ADMIN` or `admin`). |
| `--username <smoke-...>` | Use an existing smoke user from `smoke-user.sh create` ([5.1](05-01-first-login.md)) instead of creating one. It is logged out afterwards, not deleted. This also lets the script run without a terminal. |
| `--with-seal` | Also e-seal the test document with the deployment's configured e-seal. Off by default, see below. |
| `--cacert <file>` | Trust this CA for the host's certificate, for test stacks with a private or self-signed certificate. TLS is always verified. |
| `--approve-timeout <seconds>` | How long to wait for your approval (default 300). |

Exit codes: `0` all checks passed, `1` a check failed, `2` usage or dependency error. Cleanup runs in
every case, including after Ctrl-C.

## What a passing run proves

The output is numbered like the steps below.

1. **Preflight**: reads ps-server's loaded routing summary and `STAMP_MODE` (no URLs or secrets).
2. **Temporary client and identity**: a Keycloak client `padsign-smoke-<run id>` that allows only the
   device login, and a `smoke-...` user with a dedicated `padsign-smoke` role, not your company role,
   so no signer's tablet or Manager ever sees the test document.
3. **Your approval**: a real user login through Keycloak's own page. The script only ever receives a
   5-minute access token.
4. **Identity guard**: the token belongs to the smoke user, carries no privileged role, and has
   `padsign-backend` in its audience.
5. **Authenticated API access**: `GET /api/health` with that token returns `200`.
6. **Upload**: a generated one-page PDF reading `PADSIGN SMOKE TEST - NOT A REAL DOCUMENT` goes in
   through the demo upload path. No customer data is involved.
7. **Visual signature**: applied through `PUT /api/visual-signature` with the portal's own placement
   settings. The script then removes the document's waiting-signer entry, so ps-server has nobody to
   route it for.
8. **E-seal**: skipped unless you pass `--with-seal`.
9. **Download and verify**: the signed PDF is downloaded the way the portal does it. It must differ
   from the input, still carry the run id, and contain at least one signature (two with
   `--with-seal`).
10. **Nothing routed**: no file in any routing folder or the receive-back buffer names or contains
    the document, and ps-server logged no routing event for it, so no webhook was called.

**Cleanup** then deletes the archive document, the temporary client, the smoke user (or logs out the
one you passed with `--username`) and the `padsign-smoke` role if the run created it. If the archive
refuses the delete, the run ends with a warning and exit code `1` and names the document id. What
remains is then a synthetic, clearly labelled document that nothing routes and no signer sees.

## What it does not prove

- **The e-seal**, unless you pass `--with-seal`. A seal from your production key on a test document
  is a real signature by your organisation, so only opt in when you mean it. With `--with-seal`, the
  script uses whatever the deployment is configured with: the external provider or the local keystore.
- **The portal's user interface.** The script calls the same endpoints in the same order as the
  portal, but does not click through it. Check the UI yourself as in [5.1](05-01-first-login.md).
- **Unattended health.** It needs a person. For continuous checks, see
  [9.10 Monitoring and alerting](09-10-monitoring-and-alerting.md).
