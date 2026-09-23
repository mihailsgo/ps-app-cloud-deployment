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
7. **Authorized signing smoke test** — looks for `psapp`'s real authenticated-signing Playwright spec (tracked as [psapp-saas#9](https://github.com/mihailsgo/psapp-saas/issues/9)) and runs it via `npx playwright test` if present. **At the time this was written, #9 had not landed a real test** — `psapp/client/tests/e2e/sign-flow.spec.js` exists but mocks every API call (confirmed by reading it), so it is not a substitute and this script does not treat it as one. When the real spec is missing, `postdeploy-check.sh` prints `SKIPPED — depends on psapp-saas#9, not yet landed` and does **not** fail the run because of it. Point `PADSIGN_SIGNING_SMOKE_SPEC` at the real spec once #9 lands (or once you've adopted its output path).
8. **TLS** — `verify-served-cert.sh` (existing script, reused as-is).
9. **Evidence** — writes `deployment-evidence.json` (see [40.1](40-01-health-checks-and-startup-order.md) and the evidence file's own header comment).

## A check that was designed and then deliberately dropped

The original design for step 6 also included a positive case: use `smoke-user.sh create` to mint a real Keycloak login, obtain a token, and confirm an authenticated `/api/health` call succeeds. This turned out to be impossible to do safely: `smoke-user.sh`'s `print_secret()` (in `lib/kcadm.sh`) **only ever writes the generated password to `/dev/tty`**, specifically so it can never leak into a stream a script or log could capture — which is exactly the property a non-interactive validation script would need it to *not* have to consume the password programmatically. Building a workaround would have meant weakening a deliberate, already-reviewed security property of `smoke-user.sh` for a different script's convenience. The unauthenticated-rejection check (step 6 above) is what actually ships; a genuine authenticated-access check has to come from something with a real login flow — i.e. #9's browser test (step 7), not a shell script holding a password.
