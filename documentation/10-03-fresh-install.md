# 10.3 Fresh install

This page covers installing a new deployment with local e-sealing switched on
from the start, using the demo keystore. Replace the keystore with your own
before production ([10.6](10-06-production-key-and-certificate.md)).

## With the Deployment Wizard

On the **Features** step, turn on **Local e-sealing**. The wizard then runs
`bootstrap.sh --enable-local-eseal` for you. See
[3.2 Walkthrough](03-02-walkthrough.md).

## From the command line

Add `--enable-local-eseal` to your `bootstrap.sh` command:

```bash
cd /opt/padsign
./installation-scripts/bootstrap.sh \
    --host padsign.example.com \
    --company-role "ExampleCo" \
    --admin-pass "<strong Keycloak admin password>" \
    --cert-crt ./installation-scripts/certs/padsign.example.com.crt \
    --cert-key ./installation-scripts/certs/padsign.example.com.key \
    --enable-local-eseal
```

For the other flags, see [4.2 Bootstrap parameters](04-02-bootstrap-parameters.md).

## What the flag changes

`bootstrap.sh` passes the flag to `configure-host.sh`, which makes these
changes during Step 3/8. Each change is skipped if it has already been made,
so running the script again is safe.

| File | Change |
|---|---|
| `dmss-digital-stamping-service/` | Copies the demo `application.yml`, `seal/seal.p12` and `seal/README.md` from `installation-scripts/assets/dmss-digital-stamping-service/`. It uses `cp -n`, so a file already in place, such as your own keystore, is never overwritten. |
| `docker-compose.yml` | The shipped file already defines `dmss-digital-stamping-service`, gated by `profiles: ["local-eseal"]`. It stays unchanged. The script inserts the service only if a customised compose file does not have it, with the release's approved, digest-pinned image from `release/approved-digests.json` ([14.6](14-06-image-approval-and-digest-pinning.md)). |
| `docker-compose.yml` | Adds `SPRING_SECURITY_USER_NAME=user` and `SPRING_SECURITY_USER_PASSWORD=changeit` to the `environment:` list of `dmss-container-and-signature-services`. `ps-server` then has a fixed Basic-auth login for it. Without these, the service creates a random password every time it starts. |
| `dmss-container-and-signature-services/application.yml` | Changes `digital-stamping-service.baseUrl` from `http://host.docker.internal:8084/api` to `http://dmss-digital-stamping-service:8084/api`. |
| `config/config.js` | Inserts `STAMP_MODE: "local"` and a `STAMP_LOCAL` block (`url` ending in `/profile/LocalDemo`, `username: "user"`, `password: "changeit"`, `timeoutMs: 30000`). If `STAMP_MODE` is already there, it only changes the value to `"local"`. |
| `.env` | Sets `COMPOSE_PROFILES=local-eseal`, or adds `local-eseal` to an existing `COMPOSE_PROFILES` list. From then on, `docker compose up -d` includes the stamping service. |

In Step 7/8, `bootstrap.sh` pulls and starts every service, including
`dmss-digital-stamping-service`, because `.env` now activates its profile.

## After bootstrap

1. **Make the portal request the seal.** In `config/constants.json`, set
   `"RUN_STAMPING_REQUEST": true`. Then run `docker compose restart ps-client`
   and reload the portal in the browser.
2. **Check the seal works**, following [10.9 Verifying it works](10-09-verifying-it-works.md).
3. **Before production**, replace the demo keystore and rotate the three
   `changeit` passwords. See
   [10.6 Production key and certificate](10-06-production-key-and-certificate.md).
