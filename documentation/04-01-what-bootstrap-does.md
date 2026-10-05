# 4.1 What bootstrap does

`installation-scripts/bootstrap.sh` runs eight steps and prints `Step N/8` as each one starts. The
wizard's Deploy screen shows the same eight steps. Use this page to know what a step changes and
where to look when one fails.

## Before step 1: input and dependency checks

- Stops (exit 2) if `--host`, `--company-role` or the admin password (`--admin-pass` or
  `KEYCLOAK_ADMIN_PASSWORD`) is missing, or if it gets an unknown option. Warns if the admin
  password is `admin`.
- Stops (exit 1) if `docker`, `awk`, `perl`, `python3`, `curl`, `openssl` or `docker compose`
  (Compose v2) is missing.
- Prints a banner with the host, company, realm and the three feature flags.

## Step 1/8: Backing up config files

Copies `config/config.js`, `config/constants.json`, `nginx/nginx.conf` and `docker-compose.yml` to
`*.bak` next to each file, readable by the owner only. These are the files to restore if a later
step fails. Each run overwrites the previous run's backups.

## Step 2/8: Validating TLS certificate

Runs `validate-certs.sh` on the certificate and key: `--cert-crt`/`--cert-key` if given, otherwise
`installation-scripts/certs/<host>.crt` and `.key`. It checks the PEM format, that the key matches the
certificate, expiry, that the hostname is covered and that the chain is complete (the chain check is
skipped with `--allow-self-signed`). A failed check stops the script.

If no certificate is found at all, the step prints `INFO: No certs found ... skipping pre-flight
validation` and continues; nginx then fails to start until certificates are in `nginx/certs/`.

## Step 3/8: Configuring files for hostname

Runs `configure-host.sh`, which edits the deployment for your hostname:

- **`nginx/nginx.conf`**: `server_name`, the certificate file names, and the redirect from `/` to
  `/portal/`.
- **`config/constants.json`** (browser app): Keycloak URL, redirect URIs, download API URL. The file
  is checked to still be valid JSON.
- **`config/config.js`** (ps-server): service URLs, `ALLOWED_ORIGINS`, the Keycloak server URL and
  `DEMO_COMPANY_ROLE`. The shipped file already has a `DOCUMENT_ROUTING` block with routing on,
  which is left as it is. Only a `config.js` without that block gets one added, switched off.
- **Secrets**: replaces `REGISTER_PDF_API_KEY` with a random value if it still holds the value
  shipped in this public package. A value you already changed is kept. The key is not printed;
  read it as shown in [7.5 Register PDF API](07-05-register-pdf-api.md). (`SESSION_SECRET` in
  `config.js` is kept as-is; ps-server 3.33+ does not read it.)
- **Visual-signature CA**: replaces the shipped demo CA
  (`dmss-container-and-signature-services/dmssrootca.p12`) with one generated for this deployment,
  with a random keystore password. A CA that is already your own is kept.
- **`.env`** (git-ignored, mode 600): stores the Keycloak admin password as
  `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD`. The tracked `docker-compose.yml` only references it
  ([7.6 Environment variables](07-06-environment-variables.md)).
- **`docker-compose.yml`**: makes sure ps-server has its `signed-output` mount, sets the keycloak
  service's `KC_HOSTNAME` and nginx's network alias to your hostname, and sets the admin user name
  (`KEYCLOAK_ADMIN`). `KC_HOSTNAME` decides the token issuer and the login page URLs, so it must match
  the hostname users open.
- **Certificates**: copies the certificate and key to `nginx/certs/<host>.crt` and `.key` (key mode
  600). Stops if the key is encrypted, because nginx cannot start with it; decrypt it with
  `openssl pkey -in encrypted.key -out installation-scripts/certs/<host>.key`.
- **Feature flags**: applies `--enable-routing`, `--enable-demo` and `--enable-local-eseal`.
  Leaving a flag out never switches a feature off; routing stays as `config.js` has it.
  Local e-sealing stages the demo stamping-service files (never overwriting existing ones), adds the
  `dmss-digital-stamping-service` block to `docker-compose.yml`, sets the container-signature
  service's basic-auth user and its stamping URL, sets `STAMP_MODE: "local"` in `config/config.js`,
  and writes `COMPOSE_PROFILES=local-eseal` to `.env` ([10. Local e-sealing](10-local-e-sealing.md)).
- **`config/config.js` permissions**: gives the file the group of the user the ps-server image runs
  as and mode 640, then checks that ps-server can still read it. This happens only when you run
  bootstrap as root, as that user or as a member of that group; otherwise the file stays readable and
  `validate-config.sh` tells you what to run.

## Step 4/8: Setting up signed-output and docs directories

Creates `signed-output/` (mode 750, for ps-server) and `docs/` (mode 770, for the fallback archive
service), each owned by the user its container image runs as, read from the image itself. If the
script cannot set the owner, it stops and prints the exact `sudo chown` / `sudo chmod` command to
run. It never makes the directories world-writable.

## Step 5/8: Bootstrapping Keycloak

Runs `keycloak-bootstrap.sh`. The step prints nothing until it finishes (up to a minute or two),
because the script's output is captured and the backend client secret is filtered out before it
is shown. It:

- starts the Keycloak container and waits until it is ready;
- creates the realm (default `padsign`) if it does not exist;
- creates the roles `padsign-admin`, `psapp-integration` and your company role;
- creates or updates the public client `padsign-client` with redirect URIs for
  `https://<host>/portal/`, and adds the `padsign-backend` audience to its tokens
  ([8.2 Token audience](08-02-token-audience.md));
- creates the confidential client `padsign-backend` (service account enabled, no browser login);
- recreates the demo user `test` with the company role and a random password, shown only at an
  interactive terminal;
- creates the extra users from `--users`, if given.

If this step fails, the script stops and prints the command that restores the four `*.bak` files.
Details: [8.1 Automated setup](08-01-automated-setup.md).

## Step 6/8: Writing backend client secret into config

Writes the `padsign-backend` client secret from step 5 into `config/config.js`. The secret is passed
through the environment and is not printed.

## Step 7/8: Pulling Docker images and starting services

Runs `docker compose pull` and `docker compose up -d` from the deployment directory, then waits up
to 600 seconds for every service to report healthy (the wizard service is not included). The first
Keycloak start is the slow part. If a service does not become healthy, the script prints
`docker compose ps` and stops; fix that service and run bootstrap again. Health checks are described
in [9.9 Health checks and startup](09-09-health-checks-and-startup.md).

## Step 8/8: Verifying deployment

- Waits for `PadSign Server listening` in the ps-server log (`ps-server: OK`).
- Checks that `https://localhost/` answers with a 301 redirect to `/portal/`.
- Lists the running containers and their images.
- Writes `deployment-evidence.json` (git-ignored): the package's git revision, image tags and
  digests, checksums of the per-host configuration files, enabled features, and each service's state
  and restart count.

It then prints `Bootstrap complete!` and the summary described in
[4. Install from the command line](04-install-from-the-command-line.md#3-run-bootstrap). Warnings
in this step do not stop the script; run the checks in
[5. First login and verification](05-first-login-and-verification.md) next.
