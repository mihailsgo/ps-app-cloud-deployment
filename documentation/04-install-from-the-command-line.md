# 4. Install from the command line

This section installs PadSign with one script, `installation-scripts/bootstrap.sh`, run in a shell
on the host. It does the same work as the [Deployment Wizard](03-install-with-the-wizard.md), which
is the recommended path; use the command line when you prefer a terminal or need an option the
wizard does not offer (extra users with `--users`).

## Before you start

- A Linux host that meets [2. Prerequisites](02-prerequisites.md): Docker Engine with Compose v2,
  plus `bash`, `awk`, `perl`, `python3`, `curl` and `openssl`. Run the commands below as a user that
  can run `docker` without `sudo`.
- A DNS name for PadSign (for example `padsign.example.com`) and a TLS certificate (full chain)
  with its unencrypted private key ([2.2 DNS and TLS certificates](02-02-dns-and-tls-certificates.md)).
- Ports 80 and 443 free on the host ([2.3 Network and firewall](02-03-network-and-firewall.md)).

## 1. Get the deployment package into /opt/padsign

Clone the release: replace `<release-tag>` with the latest release tag TrustLynx gives you.

```bash
sudo mkdir -p /opt/padsign
sudo chown "$USER": /opt/padsign
git clone --branch <release-tag> https://gitlab.com/trustlynx-public/padsign-2.0.git /opt/padsign
cd /opt/padsign
```

If TrustLynx gave you a different repository URL, use that one.

## 2. Stage the certificate

Copy the certificate and key to `installation-scripts/certs/`, named after the hostname:

```bash
cp /path/to/fullchain.pem installation-scripts/certs/padsign.example.com.crt
cp /path/to/privkey.pem   installation-scripts/certs/padsign.example.com.key
```

`bootstrap.sh` looks for exactly these names. You can instead pass other paths with `--cert-crt`
and `--cert-key`. If no certificate is found, the script skips the certificate check and nginx
fails to start, so stage it first.

## 3. Run bootstrap

Put the Keycloak admin password in the environment rather than on the command line, where every
local user could see it in `ps`:

```bash
cd /opt/padsign
read -rsp 'Keycloak admin password: ' KEYCLOAK_ADMIN_PASSWORD; echo
export KEYCLOAK_ADMIN_PASSWORD
./installation-scripts/bootstrap.sh \
  --host padsign.example.com \
  --company-role "Example Corp"
unset KEYCLOAK_ADMIN_PASSWORD
```

Add feature flags as needed, for example `--enable-routing` or `--enable-local-eseal`. Every
option is listed in [4.2 Bootstrap parameters](04-02-bootstrap-parameters.md).

The script prints `Step 1/8` to `Step 8/8` as it goes ([4.1 What bootstrap does](04-01-what-bootstrap-does.md))
and ends with `Bootstrap complete!` and a summary:

- the portal URL `https://padsign.example.com/portal/` and the Keycloak admin console
  `https://padsign.example.com/auth/admin/`;
- where the admin password is stored (`.env`, mode 600);
- the command that shows `REGISTER_PDF_API_KEY`, which the Virtual Printer and Manager need
  ([7.5 Register PDF API](07-05-register-pdf-api.md)); the key itself is not printed;
- the demo `test` user. Its generated password is shown only when the script runs at an
  interactive terminal. If you did not see it, use `installation-scripts/smoke-user.sh`
  ([5.1 First login](05-01-first-login.md)).

If a step fails, the script stops with an error that says what to fix. Fix it and run
`bootstrap.sh` again with the same arguments.

## Run bootstrap once

`bootstrap.sh` is for the first install, or for re-running an install that failed. Running it
again on a live deployment rewrites the hostname fields in the configuration files, overwrites the
`*.bak` backups from the previous run, recreates the demo `test` user with a new password and
recreates every container whose configuration changed. For changes after go-live (hostname, certificate, features, versions) use
the scripts in [9. Operations](09-operations.md).

## Next

Continue with [5. First login and verification](05-first-login-and-verification.md), then
[6. Production hardening](06-production-hardening.md).

## Sub-sections

- [4.1 What bootstrap does](04-01-what-bootstrap-does.md)
- [4.2 Bootstrap parameters](04-02-bootstrap-parameters.md)
