# 12.1 Common issues

Each entry gives the symptom, the usual cause and the fix. Commands run
from the deployment directory, `/opt/padsign`.

## 1. `Failed to load module script` for `/portal/keycloak.js`

**Cause:** `/portal/keycloak.js` is missing from ps-client, so nginx serves
`index.html` (`text/html`) instead of JavaScript.

**Fix:**

1. Check that `config/keycloak.js` exists.
2. Check that ps-client mounts it in `docker-compose.yml`:
   `./config/keycloak.js:/usr/share/nginx/html/portal/keycloak.js:ro`.
3. Recreate ps-client: `docker compose up -d ps-client`.
4. Reload the page without the cache (`Ctrl+F5`) or try a private window.

## 2. "Invalid redirect URI" or CORS errors at login

**Cause:** the hostname the portal uses (`config/constants.json`) is not in
the Keycloak client `padsign-client`'s **Valid redirect URIs** or **Web
origins**, usually after a hostname was changed in the files only.

**Fix:**

1. Show what differs:

   ```bash
    read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD
   ./installation-scripts/verify-keycloak.sh --host padsign.example.com --company-role "<company role>"
   ```

2. If the files already name the right hostname, sync the Keycloak client
   to them (idempotent; the demo test user is left alone):

   ```bash
   ./installation-scripts/keycloak-bootstrap.sh --host padsign.example.com \
     --company-role "<company role>" --skip-test-user 2>&1 | grep -v '^BACKEND_CLIENT_SECRET='
   unset KEYCLOAK_ADMIN_PASSWORD
   ```

3. To move to another hostname, use `update-hostname.sh`, which changes
   files and Keycloak together ([9.1](09-01-changing-hostname.md)).

## 3. Every portal API call returns `401`

The login works and the portal loads, but documents do not appear and the
browser's network tab shows `401` for `/api/...` calls.

**Cause 1: `padsign-backend` is missing from the access-token audience.**
ps-server checks each token with Keycloak (introspection) as the
`padsign-backend` client, and current Keycloak versions refuse that unless
`padsign-backend` is in the token's audience. `verify-keycloak.sh` reports
it as a failed `padsign-client access tokens carry padsign-backend in their
audience` check.

**Fix:** add the audience mapper, see
[8.2 Token audience](08-02-token-audience.md). `upgrade.sh` adds it in its
step 4c when it can log in to Keycloak.

**Cause 2: the backend client secret does not match.**
`KEYCLOAK_CONFIG.credentials.secret` in `config/config.js` must be the
secret of the `padsign-backend` client in Keycloak (realm `padsign`).
`validate-config.sh` reports it when it still holds the shipped `CHANGE_ME`.

**Fix:** copy the secret from the Keycloak admin console (`padsign` realm →
**Clients** → `padsign-backend` → **Credentials**) into `config.js`, then
`docker compose restart ps-server`.

## 4. Login redirects to another hostname

**Cause:** `KC_HOSTNAME` of the keycloak service in `docker-compose.yml`
names another host than the one nginx serves, for example the hostname the
repository ships with. Keycloak uses `KC_HOSTNAME` for its login pages and
token issuer, so browsers are sent there.

**Fix:** rewrite it to the served hostname and recreate Keycloak and nginx:

```bash
grep -n 'KC_HOSTNAME=' docker-compose.yml
./installation-scripts/configure-host.sh --host padsign.example.com
docker compose up -d keycloak
docker compose up -d --no-deps --force-recreate nginx
```

`upgrade.sh` corrects this too (its `compose-hostname` migration). Users
sign in again afterwards.

## 5. A port is already in use

**Cause:** another process holds a host port the stack binds: `80` and
`443` on all interfaces, `8080` (Keycloak), `84` (container-signature) and
`86` (archive) on `127.0.0.1` only, and `8443` (on `127.0.0.1` unless
`WIZARD_BIND_ADDRESS` is set) while the wizard runs.
ps-server, ps-client, the fallback archive and the stamping service bind no
host port.

**Fix:**

```bash
sudo ss -ltnp | grep -E ':(80|443|8080|84|86|8443)\b'
```

Stop the other process, or change the published port in
`docker-compose.yml`. Ports and firewall rules:
[2.3 Network and firewall](02-03-network-and-firewall.md).

## 6. `dependency failed to start`, or nginx not running

**Symptom:** `docker compose up -d` stops with
`dependency failed to start: container dmss-container-and-signature-services is unhealthy`,
or the site is down after a reboot while most containers run.

**Cause:** a service, usually a DMSS Java service on a busy or small host,
took longer than its health-check window. Everything after it in the start
chain was not started, and nginx is last.

**Fix:** wait until `docker compose ps` shows the service `healthy`, then
run `docker compose up -d` again. If it never becomes healthy, read
`docker compose logs --tail 100 <service>`. Install the boot unit so this
is retried at boot ([9.11](09-11-start-at-boot-backups-and-customized-hosts.md#starting-the-stack-at-boot)).
Details: [9.9 Health checks and startup](09-09-health-checks-and-startup.md).

## 7. ps-server restarts with `EACCES` on `config.js`

**Symptom:** ps-server restarts in a loop with
`EACCES: permission denied, open '/usr/src/app/config.js'`, and nginx never
starts.

**Cause:** ps-server runs as a non-root user and cannot read
`config/config.js`, typically because the file was restricted to
`root:root` with mode 640.

**Fix:**

1. `./installation-scripts/validate-config.sh` prints
   `FAIL config/config.js cannot be read by <uid>:<gid> ...` with the exact
   command, for example `sudo chgrp 1000 config/config.js && sudo chmod 640 config/config.js`.
2. `docker compose up -d`. nginx starts once ps-server is healthy.

`upgrade.sh` checks this before it changes anything and stops with the same
fix ([9.6](09-06-what-upgrade-does.md)).

## 8. Permission errors in `docs/` or `signed-output/`

**Symptom:** uploads fail with an archive error, or routing logs a write
failure, and the fallback archive or ps-server log shows `permission denied`.

**Cause:** part of the directory tree belongs to another user than the one
the container image runs as, for example files an older image wrote as
root. `docs/` (fallback archive, mode 770) and `signed-output/` (ps-server,
mode 750) must be owned, all the way down, by their image's user.

**Fix:** `validate-config.sh` names the first file with the wrong owner and
the fix:

```
FAIL docs directory: docs/ab/cd/ef is not owned by 10001, the user trustlynx/dmss-archive-services-fallback:... runs as, so that container cannot write there. Fix: re-run upgrade.sh (it re-owns the tree), or sudo chown -R 10001:10001 /opt/padsign/docs
```

Run the `sudo chown -R` it prints, then check again. Never `chmod 777`
these directories: they hold signed customer documents, and
`validate-config.sh` fails a world-writable one.

## 9. TLS warning or hostname mismatch

**Cause:** nginx's `server_name`, the certificate's names (CN/SAN) and the
application URLs do not all name the same host, or the certificate is
self-signed.

**Fix:**

1. `./installation-scripts/validate-config.sh --host padsign.example.com`
   checks hostname consistency across nginx, `constants.json` and
   `config.js`.
2. Check the certificate files:
   `./installation-scripts/validate-certs.sh --host padsign.example.com --cert-crt nginx/certs/padsign.example.com.crt --cert-key nginx/certs/padsign.example.com.key`.
3. Install a certificate for the right name
   ([9.2](09-02-renewing-the-tls-certificate.md)), or change the hostname
   ([9.1](09-01-changing-hostname.md)). For test certificates see
   [2.2 DNS and TLS certificates](02-02-dns-and-tls-certificates.md).
4. Certificate renewed but the browser still gets the old one:
   [9.3](09-03-monitoring-the-served-certificate.md).

## 10. Login broken although the certificate looks fine

**Cause:** `nginx/certs/<host>.crt` holds only the leaf certificate, not
the full chain. A browser that already has the intermediate shows no
warning, but Keycloak's and ps-server's own HTTPS calls fail to verify the
chain and login breaks.

**Fix:**

1. `./installation-scripts/validate-certs.sh --host <host> --cert-crt <path> --cert-key <path>`
   counts the certificates in the file and verifies the chain, and says
   when intermediates are missing.
2. Build a full-chain file (leaf first, then the intermediates):
   `cat leaf.crt intermediate.crt > fullchain.crt`. Let's Encrypt's
   `fullchain.pem` already is one.
3. Install it with `renew-cert.sh` ([9.2](09-02-renewing-the-tls-certificate.md)).

## 11. Services cannot reach each other

**Cause:** usually the target is down, still starting, or misconfigured;
real Docker network faults are rare.

**Fix:**

1. `docker compose ps`: every service should be `Up` and `healthy`.
2. Read the logs of both sides of the failing call:
   `docker compose logs -f <service>`.
3. For DMSS, check `dmss-container-and-signature-services/application.yml`
   (endpoints, TEST or PROD mode) and that the truststores and files it
   names exist in that directory.

## 12. Routing or receive-back does not deliver

Check in this order ([11. Document routing and receive-back](11-document-routing-and-receive-back.md)):

1. **Is routing on?** `DOCUMENT_ROUTING.enabled` and the strategy's
   `enabled` are `true` in `config/config.js`, and ps-server was restarted
   after the last edit.
2. **Was it a demo document?** Demo documents are not routed
   (`skipDemo: true`).
3. **Did routing run?** `docker compose logs ps-server | grep documentRouting`.
   No line at all for the document usually means its session had expired
   before signing finished, or ps-server was restarted in between.
4. **Filesystem write failed?** See issue 8.
5. **Webhook failed?** Look for `[documentRouting:webhook] PERMANENT FAILURE after retries`
   with the final status. A `4xx` is not retried: check the URL and the
   auth header.
6. **Padsign Manager gets `404` on download or ack**: the company still
   uses the shared `REGISTER_PDF_API_KEY`. Give it a per-company key
   ([11, Per-company API keys](11-document-routing-and-receive-back.md#per-company-api-keys)).
   A `401` means the key in the Manager is wrong; a `403` on `pending` means
   the Manager's **Company** differs from the key's company.
7. **Documents pile up?** `monitor-status.sh` shows the number of pending
   documents and the age of the oldest ([9.10](09-10-monitoring-and-alerting.md)).

## 13. Upgrade refused or failed

- `Refusing to upgrade to a tag release/approved-digests.json does not approve`:
  the tag is not the one this checkout approves. Update the checkout first
  and pass the tags its `docker-compose.yml` pins
  ([9.5](09-05-upgrading.md)).
- `Upgrade refused before any change: an image signature could not be verified`:
  do not continue; contact TrustLynx support.
- `requires mihailsgordijenko/ps-server:<tag> or newer`: a capability gate
  (for example `--enable-local-eseal`); add the tag bump to the same run.
- `UPGRADE FAILED: services did not become healthy`: the output names the
  service with its last probe and log lines. Roll back with the printed
  `rollback.sh` command ([9.8](09-08-rollback.md)), then investigate.
- A `WARNING` in step 4c about the token audience: see issue 3.

## General commands

```bash
docker compose ps
docker compose logs --tail 100 keycloak
docker compose logs --tail 100 ps-server
docker compose logs --tail 100 nginx
curl -s https://padsign.example.com/auth/realms/padsign/.well-known/openid-configuration | python3 -m json.tool | head
./installation-scripts/monitor-status.sh --host padsign.example.com
```

Container logs are rotated (at most 5 files of 20 MB per container), so
`docker compose logs` shows only the most recent part of a long-running
service's log. Copy a log out with
`docker compose logs --no-color <service> > <service>.log` soon after a
problem if you need it for support.
