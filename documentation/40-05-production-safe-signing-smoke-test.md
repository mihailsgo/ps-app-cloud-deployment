# 40.5 Production-Safe Signing Smoke Test

`installation-scripts/signing-smoke.sh` signs one synthetic document on a live deployment, as a real Keycloak user, and proves the stack signed it. It is built to be safe to aim at a customer's production host. This page is the design note: the constraints, the options that were weighed, what was chosen and why, and what it deliberately does not do. How to run it is at the end.

It closes the last open item of the "authorized signing smoke test" criterion in [psapp-saas#12](https://github.com/mihailsgo/psapp-saas/issues/12). The older check, psapp's Playwright spec from [psapp-saas#9](https://github.com/mihailsgo/psapp-saas/issues/9) (see [40.2](40-02-post-deploy-validation.md)), stays what it was built for: a dev or staging stack you control.

## Constraints

| # | Constraint | Where it comes from |
|---|---|---|
| C1 | The smoke user's password is never handed to a script. | `smoke-user.sh` writes it to the controlling terminal only (`print_secret` in `lib/kcadm.sh`); [40.2](40-02-post-deploy-validation.md) explains why a script-held password was rejected; [42.2](42-02-keycloak-admin-access-and-smoke-identity.md) K5. |
| C2 | No real customer data. | Production host. |
| C3 | The test document must not reach the customer's routing destinations (filesystem folders, the receive-back buffer the Manager polls) or webhooks. | `DOCUMENT_ROUTING` in `config/config.js`. |
| C4 | Clean up afterwards: no receive-back buffer entry left, no Keycloak objects left, and the archive entry removed where possible. | Operations hygiene. |
| C5 | No stamping with the customer's production seal unless the operator explicitly opts in. | A production seal on a test document is a real signature by the customer's legal entity. |
| C6 | Secrets never go on a command line. | `AGENTS.md`. |

## How ps-server decides whether a document is routed

Read from ps-server 3.28 to 3.30 (`server/app.js`, `server/lib/documentRouting.js`, `server/lib/companyScope.js` in psapp). These facts decide the design:

- Routing runs from exactly two places: `POST /api/stamp` (after a successful seal) and `POST /api/finalize-signing` (when stamping is off). Error webhooks run from `POST /api/notify-signing-error`.
- `/api/stamp` routes only if `findUserByDoc(docid)` still finds the document's in-memory user entry. `/api/finalize-signing` returns 404 without it.
- `routeDocument()` returns early for a user entry flagged `demo` unless the customer set `DOCUMENT_ROUTING.skipDemo: false`. `POST /api/demo/upload` always creates a `demo` entry. It needs only a valid token, whatever the client's `DEMO_MODE` says.
- The receive-back buffer entry is written only by the filesystem strategy, inside `routeDocument()`. A document that is never routed never gets one.
- Company scoping does not isolate anything by itself: a strategy without a `company` is global and matches every document (`strategyMatchesCompany()`). A "smoke company" alone would not keep a document out of a global strategy.
- `PUT /api/visual-signature` applies the handwritten visual signature through container-signature. It never routes.

## Options considered

| Option | C1 password | Unattended? | What it proves | Standing risk on the production host | Verdict |
|---|---|---|---|---|---|
| **A. psapp's Playwright spec as-is** | Needs the password in a file or env var for the browser to type | Yes | Full browser UI flow | Needs Keycloak admin API from the test runner; reads psapp's own `config.js`; expects local e-seal and always stamps | Keep for dev/staging only |
| **B. Service-account smoke client** (client credentials, limited to a smoke role) | No password, but a long-lived client secret on disk that any script can read | Yes | API signing path, but not a user login | A standing credential that can upload and sign on production. Needs rotation and custody, and its token carries no real user email, which `/api/demo/upload` requires | Rejected |
| **C. Fully manual browser flow** (operator signs in the portal) | Operator types it | No | Everything the UI does | None | Safe, but it proves only what the operator happens to look at, and leaves the document and state behind |
| **D. Device authorization grant, script-verified** (chosen) | Operator types it into Keycloak's own page in their browser. The script only ever holds a 5-minute access token. | No, one human approval | Real user login, authenticated API access, upload, visual signature, optional seal, download, and structural checks on the result. Plus server-side proof that nothing was routed, and cleanup. | None after the run: the Keycloak client it uses exists only for the run | **Chosen** |

Option D is the OAuth 2.0 device authorization grant (RFC 8628), built into Keycloak. The script asks Keycloak for a one-time user code. The operator opens the verification page in any browser that can reach the host, such as their laptop (the server needs no display), and logs in as the smoke user. The script then receives the token. The password goes from the operator's keyboard to Keycloak and nowhere else, which is exactly C1. `smoke-user.sh`'s rule is kept as it is, not weakened.

Its costs: it needs a person for about a minute, so it cannot run unattended from cron. It needs the Keycloak admin credential (as `smoke-user.sh` already does) to create and remove its temporary client. It tests the API sequence the portal uses, not the portal's JavaScript. The portal UI is covered by the served-config and redirect checks in [40.2](40-02-post-deploy-validation.md) and by the Playwright spec on staging. A client-credentials variant (B) could be added later for unattended runs, but only as a deliberate product decision about keeping a signing-capable credential on customer hosts.

## The design

One run of `signing-smoke.sh`:

1. **Preflight, read-only.** It reads ps-server's loaded config inside the container, printing only the routing summary (enabled, `skipDemo`, strategy types) and `STAMP_MODE`, never URLs or secrets. It records the start time.
2. **Temporary Keycloak client** `padsign-smoke-<run id>`: public, **device grant only** (standard, implicit and direct-access grants off, so it can never accept a password), 5-minute access tokens and device codes, plus the `padsign-backend` audience mapper that ps-server's token introspection needs ([14.8](14-08-token-audience-for-introspection.md)).
3. **Smoke identity.** By default the script runs `smoke-user.sh create` with a dedicated realm role, `padsign-smoke`. It creates that role if it is missing, and removes it afterwards if it created it. The password appears once on the operator's terminal, from `smoke-user.sh` itself, never on the script's stdout. `--username` uses an existing `smoke-*` user instead.
4. **Device approval.** The script prints the verification URL and user code, then polls until the operator approves. If the operator denies (`access_denied`) or the code expires (`expired_token`), the run fails and cleans up.
5. **Identity guard, before any API call.** The token's `preferred_username` must be the smoke user (so `smoke-*`). It must carry none of `padsign-admin`, `psapp-integration`, or the deployment's other `PRIVILEGED_API_ROLES`, and its `aud` must contain `padsign-backend`. If an operator approves with their own account by mistake, the run stops here and creates nothing.
6. **Authenticated API:** `GET /api/health` with the token returns 200. This is the positive check [40.2](40-02-post-deploy-validation.md) had to drop.
7. **Synthetic document:** a one-page PDF generated on the spot, reading `PADSIGN SMOKE TEST - NOT A REAL DOCUMENT` plus the run id. A generated signature image. No customer data (C2).
8. **Upload through the demo path** (`POST /api/demo/upload`). The entry is `demo`, so routing skips it by default. The entry is keyed by the smoke user's email, so no customer tablet or Manager ever polls it.
9. **Visual signature** (`PUT /api/visual-signature`) with the placement the portal uses (`PDF_SIGNATURE_*` from the served `constants.json`).
10. **Drop the user entry** (`GET /api/cleanupUser?doc=<id>`) before anything that could route. With no user entry, `/api/stamp` has nobody to route for, and `/api/finalize-signing` is never called. The document therefore cannot reach any routing destination or webhook **even if the customer set `skipDemo: false`**. This is structural, not a config assumption (C3).
11. **Seal, opt-in only.** Only with `--with-seal`: `POST /api/stamp`, which uses whatever the deployment is configured with (its external provider or its local keystore). Without the flag the step is skipped and says so (C5).
12. **Download and verify.** The script fetches the signed document the way the portal does (`/archive/api/document/<id>/download`). It must be a PDF that differs from the input, still carries the run id, and contains a signature dictionary: at least one `/ByteRange`, and at least two with `--with-seal`.
13. **Prove nothing was routed.** No file under any enabled filesystem strategy's `basePath`/`bufferPath` changed during the run and contains the document id or run id. There is no receive-back buffer entry for the document, and no ps-server `documentRouting` log line names it.
14. **Clean up, always**, including after a failure or Ctrl-C (C4). It drops the user entry again (idempotent) and deletes the archive document where the archive supports it. It deletes the temporary client and the smoke user (or logs out an existing one's sessions), removes the `padsign-smoke` role if the run created it, removes the kcadm session file, and deletes the temporary directory that held the token.

Secrets (C6): the Keycloak admin password comes from `KEYCLOAK_ADMIN_PASSWORD` or a hidden prompt, never a flag, and reaches kcadm only as `KC_CLI_PASSWORD` (`kc_login` in `lib/kcadm.sh`), so it is on no command line, including kcadm's inside the container. The access token lives in a mode-600 file in a private temporary directory and reaches curl as `-H @file`, so it is never in a process argument list. It is never printed.

## What it does not do

- **It does not prove the production seal works unless you pass `--with-seal`.** Without it, the document is visually signed, but the seal step is skipped. Monitoring still catches seal failures in normal traffic (`stamping_failure` in [40.3](40-03-monitoring-and-alerting.md)).
- **It is not unattended.** The device approval needs a person. That is the price of C1.
- **It does not click through the portal UI.** It calls the same endpoints in the same order.
- **The archive entry is deleted where the archive allows it.** The pinned `dmss-archive-services` 24.3.0.3 exposes `DELETE /api/document/{id}`. The script calls it from inside ps-server (at `ARCHIVE_API_BASE_URL`, like ps-server's own archive calls) and then checks that the download no longer answers 200. That archive answers a deleted document with a 500 ("Cannot get info from document"), not a 404. If a different archive refuses the delete, the run ends with a WARN and exit 1, and names the document id. What remains is then a synthetic, clearly labelled document with no customer data, referenced by no routing destination and no user entry.

## How to run it

From the deployment directory, at an interactive terminal (the smoke user's password is shown there once):

```bash
read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD   # paste; nothing is echoed
./installation-scripts/signing-smoke.sh --host padsign.client.com
```

Or as part of the post-deploy pass: `postdeploy-check.sh --host padsign.client.com --signing-smoke` ([40.2](40-02-post-deploy-validation.md)).

The script prints a verification URL and a code. Open the URL in a **private** browser window. The code is already filled in, so you go straight to the sign-in page. Log in as the printed `smoke-*` user with the password from the terminal. On the page "Grant Access to PadSign signing smoke test (temporary)", choose **Yes**; Keycloak always asks this for a device login. When the page reads "Device Login Successful", you can close the window. The script continues by itself.

If you signed in with any other account by mistake, the run stops at step 4, before any API call, and cleans up.

Options:

| Option | Meaning |
|---|---|
| `--host <host[:port]>` | The deployment's public hostname (a port only for test stacks). Required. |
| `--realm <name>` | Keycloak realm (default `padsign`). |
| `--admin-user <name>` | Keycloak admin user (default `$KEYCLOAK_ADMIN` or `admin`). |
| `--username <smoke-...>` | Use an existing smoke user (from `smoke-user.sh create`) instead of creating one. It is logged out afterwards, not deleted. |
| `--with-seal` | Also seal the test document with the deployment's configured e-seal. Off by default; see C5. |
| `--cacert <file>` | Trust this CA for the host's certificate (test stacks with a private CA). TLS is always verified. |
| `--approve-timeout <sec>` | How long to wait for the device approval (default 300, Keycloak's device code lifetime). |

Exit codes: `0` all checks passed, `1` a check failed, `2` usage or dependency error. Cleanup runs in all three cases.

## Rehearsal evidence

Rehearsed on real Linux (WSL Ubuntu's own Docker engine, separate from every other stack on the machine) against this repository's `docker-compose.yml`, under compose project `smk12`. It had no fixed container names, only nginx published (on `127.0.0.1:38443`), and an override kept outside the checkout. The stack was set up by the real `bootstrap.sh --enable-routing --enable-local-eseal` with the pinned images (ps-server 3.28 and ps-client 8.39, Keycloak 26.7.4, archive 24.3.0.3, container-signature 24.3.0.29). Runs 7 and 8 repeated it after `main` moved to ps-server 3.30 and ps-client 8.40. Routing was then made the worst case for this test: `skipDemo: false`, a global filesystem strategy, a global webhook and a company-scoped webhook, both pointing at a live HTTP receiver. The operator's browser was a real headless Chromium in a Playwright container. It read the smoke user's password from the terminal log, as a person reads the screen; the script never had it.

| Run | Scenario | Result |
|---|---|---|
| control | Rehearsal-only user signs a demo document the portal's way: `finalize-signing`, user entry kept | Routed to the filesystem folder, the receive-back buffer (`.meta.json`) and **both** webhooks. The destinations are live, so the runs below are not vacuous. |
| 1, 3a | Approval never given | `expired_token` / `no approval within 300s`. The client, the smoke user and the `padsign-smoke` role were deleted. Exit 1. |
| 2 | Defaults | Pass, exit 0. Visually signed PDF (1 `/ByteRange`, run id present). Nothing routed. Archive document deleted. |
| 3 | `--with-seal`, stdout and stderr captured to files | Pass. 2 signature dictionaries, sealed with the stack's local demo seal. Nothing routed. The smoke user's password appeared once on the terminal and **0 times** in stdout or stderr. |
| 4 | Operator approves as a different (customer-role) user | Stopped at the identity guard. ps-server logged no upload after the run started. Everything was cleaned up. Exit 1. |
| 5 | Existing smoke user (`--username`), operator denies | `access_denied`. The client was deleted. The user was kept and logged out. Exit 1. |
| 6 | Existing smoke user holding the **customer's company role** | Pass. The company-scoped webhook for that company was not called. The user was kept, with 0 active sessions afterwards. |
| 7 | `--with-seal` on ps-server 3.30 / ps-client 8.40 | Pass, 2 signature dictionaries, nothing routed. The first attempt failed at step 5 with a 502: the images had been swapped by hand without restarting nginx, so nginx still pointed at ps-server's old address. Docker reported every service healthy. `upgrade.sh` restarts nginx, so a real upgrade does not hit this, but it is the kind of broken-yet-"healthy" stack this test exists to catch. |
| 8 | `postdeploy-check.sh --signing-smoke`, stdout to a file | Step 7 passed. The admin password reached the script only through the environment (0 occurrences in the output). The first attempt found a bug, now fixed: step 7 indented the smoke output through `sed`, which block-buffers when stdout is a file or a pipe (`postdeploy-check.sh \| tee log`). The device URL and code then stayed in the buffer until the approval had timed out. |

Checked independently after the runs, not through the script: the webhook receiver held only the control's two requests. `/signed-output` held only the control's files, with no file containing a smoke docid. The deleted smoke documents answered `Cannot get info from document`, while the control document still answered 200. Keycloak held no `padsign-smoke*` client, no `smoke-*` user created by the script and no `padsign-smoke` role. There was no kcadm session file in the Keycloak container and no temporary directory on the host. Two test-only accommodations were not shipped: `NODE_EXTRA_CA_CERTS` in ps-server and `--cacert` in the script, for the rehearsal's self-signed certificate. The stack was torn down and deleted afterwards.
