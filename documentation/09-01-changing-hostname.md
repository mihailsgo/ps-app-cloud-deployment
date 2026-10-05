# 9.1 Changing the hostname

Use this to move a live deployment to a new public hostname, for example
from `padsign.example.com` to `sign.example.com`. One run updates both
places the hostname lives: the configuration files that nginx, ps-server
and ps-client read, and Keycloak's client settings (redirect URIs, web
origins). Changing only one of them breaks login: files only gives
"Invalid redirect URI" from Keycloak, Keycloak only leaves nginx serving
the old name.

## Before you start

- Point DNS for the new hostname at this host (see
  [2.2 DNS and TLS certificates](02-02-dns-and-tls-certificates.md)).
- Have a certificate and key for the **new** hostname, or a wildcard or
  multi-SAN certificate that already covers it. A certificate is always
  required: nginx is pointed at `<new-host>.crt` / `<new-host>.key` and does
  not start without them. The script checks for one before it changes
  anything.
- Have the **current** Keycloak admin username and password. They are used
  to log in to Keycloak and update its client; they are not changed.
- Plan a short interruption. Keycloak and nginx are recreated and ps-server
  restarts. Every user has to sign in again afterwards, because Keycloak's
  token issuer contains the hostname and tokens issued for the old one stop
  validating.

## Using the wizard

1. Open **Settings** and go to the **Hostname** card.
2. Enter the new hostname.
3. Provide the certificate: either tick **the current certificate already
   covers the new hostname** (the wizard re-checks it against the new name
   and refuses if it does not match), or upload or paste a new certificate
   and key and click **Validate certificate**.
4. Enter the current Keycloak admin username and password. They are used
   for this run only and never stored.
5. Click **Update Hostname**, confirm, and watch the progress.

## Using the command line

```bash
cd /opt/padsign
 read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD   # the CURRENT admin password; nothing is echoed
./installation-scripts/update-hostname.sh \
  --host sign.example.com \
  --cert-crt ./installation-scripts/certs/sign.example.com.crt \
  --cert-key ./installation-scripts/certs/sign.example.com.key
unset KEYCLOAK_ADMIN_PASSWORD
```

The leading space keeps the `read` line out of the shell history (with
`HISTCONTROL=ignorespace`). `--admin-pass "<password>"` also works, but puts
the password on the command line, where every local user can see it in
`ps` while the script runs.

Leave out `--cert-crt` / `--cert-key` when the certificate is already
staged as `installation-scripts/certs/<new-host>.crt` and `.key`. For a
wildcard or multi-SAN certificate that covers the new name, pass the
current files, for example `--cert-crt nginx/certs/<old-host>.crt --cert-key nginx/certs/<old-host>.key`;
they are copied to `nginx/certs/<new-host>.crt` / `.key`.

Other options: `--admin-user` (default `admin`) and `--realm` (default
`padsign`).

## What it does

The script prints four steps:

1. **Backs up** `config/config.js`, `config/constants.json`,
   `nginx/nginx.conf` and `docker-compose.yml` as owner-only `.bak` files.
2. **Rewrites the files for the new hostname** with `configure-host.sh`:
   nginx `server_name` and certificate paths, the URLs in `config.js` and
   `constants.json`, and in `docker-compose.yml` Keycloak's `KC_HOSTNAME`
   and nginx's network alias. The certificate is installed into
   `nginx/certs/`. Feature settings and the company role are not changed.
3. **Updates the Keycloak client** `padsign-client` (redirect URIs, web
   origins, root, base and admin URLs) with `keycloak-bootstrap.sh
   --skip-test-user`. This recreates the Keycloak container so it picks up
   the new `KC_HOSTNAME`. The demo `test` user is left alone, and the
   backend client secret is not rotated or printed.
4. **Recreates nginx, restarts ps-server and checks** that ps-server logged
   `PadSign Server listening` and that `https://localhost/` answers `301`.

If step 3 fails, the script prints the command that restores the `.bak`
files.

## After the change

Update everything outside this host that names the old hostname:

- the API URL (`https://<new-host>/api/registerPDF`) in every Padsign
  Manager / Virtual Printer installation and third-party uploader;
- webhook receivers or firewall rules that expect the old name;
- monitoring checks and bookmarks.

## Verifying it worked

```bash
curl -kI https://sign.example.com/                # expect 301 to /portal/
docker compose logs ps-server --tail 20           # clean start
curl -s https://sign.example.com/auth/realms/padsign/.well-known/openid-configuration \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])'
                                                  # expect https://sign.example.com/auth/realms/padsign
./installation-scripts/validate-config.sh --host sign.example.com
./installation-scripts/verify-served-cert.sh
```

In the Keycloak admin console (`https://<new-host>/auth/admin/`), open the
`padsign` realm, then **Clients** → `padsign-client`, and check that
**Valid redirect URIs** and **Web origins** name the new hostname.
