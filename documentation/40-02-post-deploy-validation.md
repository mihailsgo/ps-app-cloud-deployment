# 40.2 Post-Deploy Validation

`installation-scripts/postdeploy-check.sh` is a new orchestrator that chains the existing standalone verify/validate scripts plus new checks it owns directly, into one pass — nothing in this repo previously ran them together. Run it right after `bootstrap.sh` or `upgrade.sh`:

```bash
./installation-scripts/postdeploy-check.sh --host padsign.client.com --company-role "ClientName"
```

`--company-role` is optional; it only gates the `verify-keycloak.sh` step (it needs a role to check the demo `test` user against). Everything else runs regardless.

## What it checks, in order

1. **Config validation** — `validate-config.sh --host <host>` (existing script, reused as-is).
2. **Keycloak realm/client checks** — `verify-keycloak.sh --host <host> --company-role <role>` (existing script, reused as-is; skipped with a note if `--company-role` isn't given).
3. **Redirect** — `https://<host>/` returns `301` to a `/portal/` location.
4. **Portal/runtime config** — fetches `https://<host>/portal/constants.json` over the wire and diffs the five hostname-dependent fields (`KEYCLOAK_URL`, `KEYCLOAK_REDIRECT_URI`, `KEYCLOAK_POST_LOGOUT_REDIRECT_URI`, `PS_DOWNLOAD_API`, `PDF_TEST_PATH`) against the local `config/constants.json` — the same class of "file is right but nginx/the container never picked it up" bug `verify-served-cert.sh` exists to catch for TLS, applied to runtime config.
5. **Keycloak discovery** — `https://<host>/auth/realms/<realm>/.well-known/openid-configuration` returns `200` with a valid `issuer`.
6. **Protected API behavior** — an *unauthenticated* `GET /api/health` is rejected (`401`/`403`), not `200`.
7. **Authorized signing smoke test** (opt-in, needs an interactive terminal): `--signing-smoke` runs `signing-smoke.sh`, the production-safe test designed in [40.5](40-05-production-safe-signing-smoke-test.md). A disposable smoke user approves in the operator's browser, one synthetic document is signed and verified, nothing is routed, and everything it created is removed. The Keycloak admin password (`--admin-pass` or `KEYCLOAK_ADMIN_PASSWORD`) is handed to it through the environment, not the command line. `--signing-smoke-with-seal` also applies the deployment's configured e-seal. Without either flag the step prints `SKIP`.

   **Dev/staging only:** setting `PADSIGN_SIGNING_SMOKE_SPEC=<path to the spec>` (and not passing `--signing-smoke`) instead runs psapp's real authenticated Playwright spec from [psapp-saas#9](https://github.com/mihailsgo/psapp-saas/issues/9), `client/tests/e2e/authenticated-sign-flow.spec.js`, from psapp's `client/` directory with `--config=playwright.auth.config.js` and `PADSIGN_STACK_URL=https://<host>`. It needs a psapp checkout (default `../psapp`) with `client/node_modules` and Playwright's Chromium installed, and `KEYCLOAK_ADMIN_URL` pointing at a Keycloak admin API it can reach. The spec was written for the local-eseal development stack: its preflight reads psapp's own `config/config.js` (expects `STAMP_MODE: "local"`) and it bootstraps a test client and user through the admin API, so it is a fit for a staging stack you control, not a check to aim at a customer's production host. When the variable is set but the spec or its config is missing, the step FAILs. The variable no longer defaults to `../psapp/...`, and `--signing-smoke` no longer runs this spec.

   Before this change the step ran automatically whenever `../psapp/client/tests/e2e/authenticated-sign-flow.spec.js` existed, with `npx playwright test <spec>` from the psapp root. psapp's default `client/playwright.config.js` lists that spec under `testIgnore`, so on any machine with psapp checked out next to this repo the step could only report "no tests found" and FAIL.
8. **TLS** — `verify-served-cert.sh` (existing script, reused as-is).
9. **Evidence** — writes `deployment-evidence.json` (see [40.1](40-01-health-checks-and-startup-order.md) and the evidence file's own header comment).

## A check that was designed and then deliberately dropped

The original design for step 6 also included a positive case: use `smoke-user.sh create` to mint a real Keycloak login, obtain a token, and confirm an authenticated `/api/health` call succeeds. This turned out to be impossible to do safely: `smoke-user.sh`'s `print_secret()` (in `lib/kcadm.sh`) **only ever writes the generated password to `/dev/tty`**, specifically so it can never leak into a stream a script or log could capture, which is exactly the property a non-interactive validation script would need it to *not* have to consume the password programmatically. Building a workaround would have meant weakening a deliberate, already-reviewed security property of `smoke-user.sh` for a different script's convenience. The unauthenticated-rejection check (step 6 above) is what actually ships; a genuine authenticated-access check has to come from something with a real login flow, not a shell script holding a password. [40.5](40-05-production-safe-signing-smoke-test.md) now provides one without weakening that property: the operator types the password into Keycloak's own device-login page in a browser, and `signing-smoke.sh` only ever receives a 5-minute access token (its step 5 is exactly this positive `/api/health` check).
