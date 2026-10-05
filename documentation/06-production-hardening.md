# 6. Production hardening

Work through this checklist before real users sign real documents. PadSign
ships with demo credentials and relaxed defaults so a fresh install works
straight away. Some are replaced automatically by `bootstrap.sh` (and by the
wizard, which runs it for you). Others you have to change yourself.

Run the validator first and after every change. Its *Secret hygiene* section
lists every shipped credential that is still in place:

```bash
cd /opt/padsign
./installation-scripts/validate-config.sh --host padsign.example.com
```

See [5.2 Validating configuration](05-02-validating-configuration.md) for how
to read its output.

## Sub-sections

- [6.1 Route protection](06-01-route-protection.md)

## 1. Demo and default credentials

| # | Credential | Shipped value | Where it lives | What to do |
|---|------------|---------------|----------------|------------|
| 1 | Keycloak master-realm admin password | `admin` (fallback when `.env` sets nothing) | `.env`: `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD`, read by `docker-compose.yml` | `bootstrap.sh --admin-pass` writes it. Keycloak reads it **only on its first boot** against an empty `keycloak_data` volume. Editing `.env` later changes nothing. To change it later, see [8.3](08-03-admin-password-and-break-glass.md). |
| 2 | Backend client secret (`KEYCLOAK_CONFIG.credentials.secret`) | `CHANGE_ME` | `config/config.js` | `bootstrap.sh` writes the secret Keycloak issues (step 6 of 8). If it still says `CHANGE_ME`, see [8.1](08-01-automated-setup.md). |
| 3 | `REGISTER_PDF_API_KEY` | a public `tlx_pdf_...` value | `config/config.js` | `bootstrap.sh` replaces it with a random key and never prints it. If the validator still warns, run the fix below, then give the new key to every API client ([7.5](07-05-register-pdf-api.md#reading-the-api-key)). |
| 4 | `SESSION_SECRET` | `change-this-session-secret` | `config/config.js` | Replaced by `bootstrap.sh` like #3. Changing it only ends existing sessions. |
| 5 | `STAMP_API_KEY`, `STAMP_COMPANY_ID`, `STAMP_COMPANY_SECRET` | `CHANGE_ME` | `config/config.js` | For external e-sealing, put in the values your e-sealing provider issued for this deployment, then `docker compose restart ps-server`. They are not used when `STAMP_MODE` is `"local"`. |
| 6 | `STAMP_API_URL` | a TrustLynx demo endpoint (`https://eseal.trustlynx.com/.../DEMOCOMPANY`) | `config/config.js` | Not a secret, and not flagged as `CHANGE_ME`. For external e-sealing, set it to the URL your e-sealing provider gives you, together with #5. Not used when `STAMP_MODE` is `"local"`. |
| 7 | Visual-PDF signing CA (`dmssrootca.p12`, `cakeystorepassword`) | a labelled demo CA whose private key is public | `dmss-container-and-signature-services/` | `bootstrap.sh` generates one for this deployment (`configure-host.sh --generate-ca`). If the validator warns that it is the shipped CA, run the fix below. |
| 8 | Local e-sealing keystore password | `changeit` | `dmss-digital-stamping-service/seal/seal.p12` and `password:` under `providers:` in `dmss-digital-stamping-service/application.yml` (both must match) | Only with local e-sealing. Replace the demo keystore with your own key and certificate: [10.6](10-06-production-key-and-certificate.md). |
| 9 | container-signature Basic-auth password | `changeit` | `SPRING_SECURITY_USER_PASSWORD` on `dmss-container-and-signature-services` in `docker-compose.yml`, and `STAMP_LOCAL.password` in `config/config.js` (must match) | Only with local e-sealing. Use a different strong password from #8 (see *Rotating the local e-sealing password* below). |
| 10 | The `test` Keycloak user | random password, shown once at an interactive terminal | realm `padsign` | Delete it before go-live (see section 2). |
| 11 | `DEMO_COMPANY_ROLE` | `CHANGE_ME` | `config/config.js` | Not a secret. `bootstrap.sh --company-role` sets it. Only used in demo mode. |
| 12 | Per-company webhook example | `Bearer REPLACE_WITH_CUSTOMER_TOKEN` | `DOCUMENT_ROUTING` in `config/config.js` (disabled) | Put in a real token only if you enable that strategy ([11](11-document-routing-and-receive-back.md)). |

The Syncfusion viewer key `PDF_RENDER_SYNCFUSION_SECRET_KEY` in
`config/constants.json` is the licensed key PadSign ships with. You do not
need to change it.

Fixes for #3/#4 and #7. Each one changes only a value that still equals the
shipped one, so it is safe to re-run:

```bash
./installation-scripts/configure-host.sh --host padsign.example.com --generate-secrets
docker compose restart ps-server

./installation-scripts/configure-host.sh --host padsign.example.com --generate-ca
docker compose restart dmss-container-and-signature-services
```

After a CA change, signatures you make from then on chain to the new CA.
Documents you already signed keep the chain they were signed with.

### Rotating the local e-sealing password (#9)

1. Pick a new strong password. Do not reuse the keystore password.
2. Set it as `SPRING_SECURITY_USER_PASSWORD` on the
   `dmss-container-and-signature-services` service in `docker-compose.yml`.
3. Set the same value as `STAMP_LOCAL.password` in `config/config.js`.
4. Apply both changes:

   ```bash
   docker compose up -d dmss-container-and-signature-services   # recreates it with the new environment
   docker compose restart ps-server                             # re-reads config.js
   ```

`docker-compose.yml` and `config/config.js` are tracked files, so this value
shows up in `git diff` and in any `git stash` an upgrade takes. Keep the
checkout private (see section 5).

### Keep `API_PROTECT_LOGS_ENABLED` off

`API_PROTECT_LOGS_ENABLED` in `config/config.js` ships as `false`. With `true`,
ps-server writes raw bearer tokens to its log. Anyone who can read
`docker logs` could replay them until they expire. `validate-config.sh` fails
if it is `true`. Turn it on only for a short auth-debugging session.

## 2. Keycloak

- [ ] **Understand the Keycloak database limitation.** Keycloak runs in
  development mode (`command: start-dev` in `docker-compose.yml`). In this
  mode it keeps its data in an embedded H2 database inside the
  `keycloak_data` volume. **This setup is not production-grade.** Keycloak
  itself does not support dev mode or H2 for production: you get one node, no
  clustering and a file database. A production database setup for Keycloak
  is on the PadSign roadmap. Until then, back up `keycloak_data` regularly
  (see [9.11](09-11-start-at-boot-backups-and-customized-hosts.md)), and
  contact TrustLynx support if you need a production-grade Keycloak database.
- [ ] **Delete the `test` user.** `keycloak-bootstrap.sh` creates it in realm
  `padsign` with only the company role. In the admin console
  (`https://padsign.example.com/auth/admin/`), select realm `padsign`, go to
  **Users**, open `test` and choose **Delete**. Or delete it from the host
  with `KEYCLOAK_ADMIN_PASSWORD` exported as in
  [8.1](08-01-automated-setup.md#disposable-smoke-test-users):
  `./installation-scripts/smoke-user.sh delete --host padsign.example.com --username test --force`
  (the lookup matches the username exactly). For later smoke tests, create
  a disposable login with `installation-scripts/smoke-user.sh` instead
  ([8.1](08-01-automated-setup.md#disposable-smoke-test-users)). After you
  delete it, `verify-keycloak.sh` reports `no shared 'test' user`.
- [ ] **Store the Keycloak admin password in your secret manager** and record
  who owns it. If you lose it, recovery means a Keycloak restart
  ([8.3](08-03-admin-password-and-break-glass.md)).
- [ ] **Restrict the admin console.** `/auth/admin/` is reachable through
  nginx like the rest of `/auth/`. Limit it to trusted networks (VPN, IP
  allowlist in `nginx/nginx.conf`) if your policy requires it.
- [ ] **Give portal users only their company role.** ps-server takes the
  company from the user's first non-default realm role, so keep
  `padsign-admin` and other roles off ordinary portal users.

## 3. Network and TLS

- [ ] **Only ports 80 and 443 are reachable from outside.** In
  `docker-compose.yml`, Keycloak (8080) and the DMSS archive and
  container-signature services (86, 84) and the wizard (8443) are bound to
  `127.0.0.1`. ps-server, the fallback archive and the stamping service
  publish no host port.
  `validate-config.sh` fails if any internal service binds to a non-loopback
  interface. Still enforce this with a host or cloud firewall:
  [2.3 Network and firewall](02-03-network-and-firewall.md).
- [ ] **Use a certificate from a trusted CA** and plan its renewal
  ([9.2](09-02-renewing-the-tls-certificate.md)). Nginx loads the
  certificate only at startup and on reload. Check that the renewed
  certificate is the one actually *served*:
  [9.3](09-03-monitoring-the-served-certificate.md).
- [ ] **Close or protect `/archive/api/` and `/container/api/`.** By default
  nginx forwards them to the DMSS services without authentication:
  [6.1 Route protection](06-01-route-protection.md). If ps-server still calls
  the DMSS services through them (public addresses in `config.js`), switch it
  to the in-network addresses first with
  `./installation-scripts/upgrade.sh --use-internal-dmss-urls`
  ([7.4](07-04-server-config-js.md#how-ps-server-reaches-the-dmss-services)),
  then close the routes as
  [6.1](06-01-route-protection.md#closing-the-routes-after-switching-ps-server-to-in-network-addresses)
  describes.
- [ ] **Tighten CORS.** `ALLOWED_ORIGINS` in `config/config.js` contains
  `https://padsign.example.com` and a development origin
  `https://padsign.example.com:5173`. Remove the `:5173` entry unless you use
  it, then `docker compose restart ps-server`.
- [ ] **Keep `ALLOW_INSECURE_TLS` set to `false`** in `config/config.js`, and
  do not set the `ALLOW_INSECURE_TLS` environment variable on ps-server: set
  to `true`, it turns insecure TLS on whatever `config.js` says
  ([7.6](07-06-environment-variables.md#other-containers)).

## 4. Deployment wizard

The wizard container mounts `/var/run/docker.sock`, which gives it
root-equivalent access to the host. Details:
[3.3 How the wizard works](03-03-how-the-wizard-works.md).

- [ ] **Never expose port 8443 publicly.** Leave `WIZARD_BIND_ADDRESS` unset
  in `.env`, so the port stays on `127.0.0.1`, and reach the wizard through
  an SSH tunnel ([3.1](03-01-starting-the-wizard.md)). If you set it for a
  trusted admin network, restrict 8443 in a network firewall: Docker-published
  ports bypass `ufw`. `validate-config.sh` warns while it is set.
- [ ] **Stop it when you finish:** `docker compose stop wizard`. It has
  `restart: unless-stopped`, so otherwise it comes back after a host reboot.
  Stopping it also clears the credentials it keeps in memory for **Retry**.
- [ ] **Treat the access token in `docker logs padsign-wizard` as a
  credential.** Anyone who can read those logs can open the wizard.

## 5. Files and permissions

The installation scripts set these for you. `validate-config.sh` checks them.

| Path | Expected | Why |
|------|----------|-----|
| `config/config.js` | mode `640`, group = the gid the pinned ps-server image runs as | Holds the backend secret, API key, session secret and e-sealing credentials. ps-server must still read it. |
| `.env` | mode `600`, owned by the deployment directory's owner | Holds the Keycloak first-boot admin password and, if you set it, `ALERT_WEBHOOK_URL`. Only `docker compose` reads it. |
| `nginx/certs/*.key` | mode `600` | TLS private key. |
| `*.bak` (written by the scripts) | mode `600` | `config/config.js.bak` holds the same secrets as `config/config.js`. |
| `signed-output/` | mode `750`, owned by the ps-server image's uid | Signed documents (filesystem routing). |
| `docs/` | mode `770`, owned by the fallback archive image's uid | The fallback archive's document store. |

- **Never `chmod 777`** a data directory. If a container cannot write, re-run
  `upgrade.sh` (it re-owns the tree) or apply the exact `chown` that
  `validate-config.sh` prints.
- **Never run `chmod o-rwx config/config.js` on its own** on a root-owned
  file. ps-server runs as a non-root user and would then crash-loop with
  `EACCES`, and nginx, which waits for a healthy ps-server, never starts.
  The fix is the one `validate-config.sh` prints, for example
  `sudo chgrp 1000 config/config.js && sudo chmod 640 config/config.js`.
- **Keeping `config/config.js` restricted.** Run the scripts as the operator
  account described in [2.1 The operator account](02-01-host-and-software.md#the-operator-account):
  a regular account in the `docker` group. The scripts rewrite
  `config/config.js`, and they keep it at mode 640 with the ps-server group
  only when the account running them is root, has the ps-server uid, or is a
  member of the ps-server group; only those users may set that group on the
  rewritten file. For any other account the file stays readable by all users
  (so ps-server can always start), and `validate-config.sh` warns and prints
  the `chgrp`/`chmod` fix. To keep the restriction across later script runs,
  add the operator account to the group with that gid, or run the scripts as
  root.
- **Keep the checkout private.** `docker-compose.yml` and `config/config.js`
  are tracked files. Their contents appear in `git diff`, in the stashes an
  upgrade takes ([9.5](09-05-upgrading.md)) and in `.git/`. Do not make the
  checkout readable by other users, and drop old stashes you no longer need.
- **Never put a secret in `docker-compose.yml` by hand.** The Keycloak admin
  password belongs in `.env` ([7.6](07-06-environment-variables.md)).

## 6. Data, backups and updates

- [ ] **Back up** the `keycloak_data` volume, `config/`, `.env`, `nginx/certs/`,
  `docs/` and `signed-output/`, and test a restore:
  [9.11](09-11-start-at-boot-backups-and-customized-hosts.md).
- [ ] **Archive database.** `dmss-archive-services/application.yml` uses an
  in-memory HSQLDB by default. Contact TrustLynx support before go-live if you
  need a persistent archive database.
- [ ] **Archive JWT checking.** If you enable `authentication.jwt` in
  `dmss-archive-services/application.yml`, set your own `secret`.
  `validate-config.sh` fails on the shipped one.
- [ ] **Stay on the approved images.** Upgrade with `upgrade.sh`
  ([9.5](09-05-upgrading.md)). The current tags are listed in
  [14.3 Release snapshot](14-03-release-snapshot.md).
- [ ] **Monitor** the stack and the ps-server logs:
  [9.10](09-10-monitoring-and-alerting.md).
