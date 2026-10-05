# 5.3 Post-deploy checks

`installation-scripts/postdeploy-check.sh` runs the configuration check from
[5.2](05-02-validating-configuration.md) and then checks the running stack over the network: Keycloak's
realm and clients, the redirect, the configuration the portal is actually served, token discovery,
API protection and the served TLS certificate. Run it after every install and every upgrade.

```bash
cd /opt/padsign
read -rsp 'Keycloak admin password: ' KEYCLOAK_ADMIN_PASSWORD; echo
export KEYCLOAK_ADMIN_PASSWORD
./installation-scripts/postdeploy-check.sh --host padsign.example.com --company-role "Example Corp"
unset KEYCLOAK_ADMIN_PASSWORD
```

| Option | Meaning |
|---|---|
| `--host <host>` | Your PadSign hostname. Required. |
| `--company-role <role>` | Your company role. Enables step 2; without it step 2 is skipped. |
| `--realm <name>` | Keycloak realm (default `padsign`). |
| `--admin-user <name>` | Keycloak admin user (default `$KEYCLOAK_ADMIN` or `admin`). |
| `--admin-pass <password>` | Keycloak admin password. Prefer `KEYCLOAK_ADMIN_PASSWORD` in the environment, as above: a command-line argument is visible to every local user in `ps` and lands in shell history. |
| `--signing-smoke` | Also run the signing smoke test as step 7 ([5.4](05-04-signing-smoke-test.md)). Needs an interactive terminal. |
| `--signing-smoke-with-seal` | The same, and also e-seal the test document. |

The script connects to `https://<host>/` from the host itself, so the host must resolve its own
hostname ([2.2 DNS](02-02-dns-and-tls-certificates.md#dns)).

## What it checks

| Step | Check | Passes when |
|---|---|---|
| 1 | Configuration | `validate-config.sh --host <host>` passes ([5.2](05-02-validating-configuration.md)). |
| 2 | Keycloak (with `--company-role`) | `verify-keycloak.sh` passes, see below. |
| 3 | Redirect | `https://<host>/` answers `301` to `/portal/`. |
| 4 | Served portal configuration | The `/portal/constants.json` the portal is served has the same `KEYCLOAK_URL`, `KEYCLOAK_REDIRECT_URI`, `KEYCLOAK_POST_LOGOUT_REDIRECT_URI`, `PS_DOWNLOAD_API` and `PDF_TEST_PATH` as `config/constants.json` on disk. A key left out of both counts as a match. Catches a file that was changed but never reached the container. |
| 5 | Keycloak discovery | `https://<host>/auth/realms/<realm>/.well-known/openid-configuration` returns a document with an `issuer`. |
| 6 | API protection | An unauthenticated `GET https://<host>/api/health` is rejected with `401` or `403`. A `200` is a FAIL. |
| 7 | Signing smoke test | Only with `--signing-smoke`; otherwise `SKIP`. See [5.4](05-04-signing-smoke-test.md). |
| 8 | Served TLS certificate | `verify-served-cert.sh` passes: a real TLS handshake shows nginx serves the certificate on disk, and it is not about to expire ([9.3](09-03-monitoring-the-served-certificate.md)). |
| 9 | Evidence | Writes `deployment-evidence.json` (see below). |

Each line is `OK`, `FAIL` or `SKIP`. The run ends with `All post-deploy checks passed (SKIPs are
informational, not failures).` and exit code `0`, or `Some post-deploy checks FAILED. Review above.`
and exit code `1`. Exit code `2` means a wrong argument.

## Step 2: verify-keycloak.sh

You can also run it on its own:

```bash
./installation-scripts/verify-keycloak.sh --host padsign.example.com --company-role "Example Corp"
```

It logs in to Keycloak as the admin (password from `KEYCLOAK_ADMIN_PASSWORD`) and checks:

- the realm exists;
- `padsign-client` has the right root, home and admin URLs, redirect URIs, post-logout redirect URIs
  and web origins for `https://<host>/portal`;
- `padsign-client` access tokens carry `padsign-backend` in their audience. Without it, ps-server's
  token introspection fails and every portal API call answers `401`
  ([8.2 Token audience](08-02-token-audience.md));
- `padsign-backend` is confidential with service accounts enabled;
- the demo `test` user, if it still exists, has only the company role. It reports the user's presence
  as a reminder to delete it before production;
- ps-server is running, the root redirect works, OIDC discovery answers, and `DOCUMENT_ROUTING` and
  the `signed-output` mount are present.

## deployment-evidence.json

Step 9 of this script, and the end of `bootstrap.sh` and `upgrade.sh`, write
`/opt/padsign/deployment-evidence.json`. It records the checkout's git revision, the pinned image tags
and the digests actually running, checksums of the per-host configuration files, which optional
features are enabled, and per-service status and restart counts, with the change since the previous
run (a rising restart count means a service is crash-looping). It never contains secrets or the
arguments the scripts were called with. The previous copy is kept as
`deployment-evidence.json.previous`. Keep it with your change records; TrustLynx support may ask for
it.

## When a check fails

Every FAIL line says what was expected and what was found. Fix that, then run the script again.
Common causes and fixes: [12.1 Common issues](12-01-common-issues.md).
