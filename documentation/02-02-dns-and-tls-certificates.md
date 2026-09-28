# 2.2 DNS and TLS certificates

PadSign is served on one hostname over HTTPS, for example `https://padsign.example.com/portal/`.
Before you install you need a DNS name for it and a TLS certificate for that name. This page covers
both, including a worked Let's Encrypt example.

## DNS

1. Pick the hostname users will open, for example `padsign.example.com`. PadSign uses the bare
   hostname on port 443; you cannot put it under a path or on another port.
2. Create an `A` record (and `AAAA` for IPv6) pointing at the host's address. For an internal-only
   deployment, an internal DNS record is enough.
3. Check it resolves, from a client machine and from the host itself:

   ```bash
   getent hosts padsign.example.com
   ```

The host must resolve its own name too: the post-install checks (`postdeploy-check.sh`,
`verify-served-cert.sh`) connect to `https://padsign.example.com/` from the host. Inside the Docker
network the name resolves to the `nginx` container without DNS.

## Certificate requirements

The installer runs `installation-scripts/validate-certs.sh` before it changes anything and stops if
any check fails. The certificate must be:

- **PEM, full chain.** The `.crt` file holds your server certificate first, followed by every
  intermediate CA certificate in chain order. nginx serves this file as it is. A file with only the
  server certificate breaks TLS verification for clients that do not already have the intermediate,
  including Keycloak's own back-channel calls, which breaks login even when a browser looks fine.
- **Issued for your hostname.** The hostname must be the certificate's CN or one of its DNS
  Subject Alternative Names. A wildcard such as `*.example.com` matches exactly one extra label
  (`padsign.example.com`, not `a.padsign.example.com`).
- **Not expired.** It warns when fewer than 30 days remain.
- **Trusted.** The chain must verify against the host's system trust store. Use a certificate from a
  public CA (Let's Encrypt is free). Signers' tablets and browsers must trust it, and so must
  ps-server, which calls the archive and Keycloak through `https://<host>/` from inside its
  container and verifies the certificate like any other client.

The private key must be:

- **PEM and matching the certificate** (the check compares their public keys).
- **Unencrypted.** nginx cannot prompt for a passphrase at start-up. Remove the passphrase with
  `openssl pkey -in encrypted.key -out padsign.example.com.key` (it asks for the passphrase once).

If your CA gave you the server certificate and intermediates as separate files, concatenate them:

```bash
cat server.crt intermediate.crt > padsign.example.com.crt
```

## Where the files go

| Install path | What to do |
|---|---|
| Deployment Wizard | Upload the full-chain certificate and the key in the certificate step, as files or as pasted PEM text ([3.2 Walkthrough](03-02-walkthrough.md)). The wizard stores them as described below. |
| Command line | Copy them to `/opt/padsign/installation-scripts/certs/`, named after the hostname: `padsign.example.com.crt` and `padsign.example.com.key`. `bootstrap.sh` finds them there; `--cert-crt` and `--cert-key` override the paths ([4.2 Bootstrap parameters](04-02-bootstrap-parameters.md)). |

The installer copies them to `nginx/certs/<host>.crt` and `nginx/certs/<host>.key` (key mode 600),
and nginx reads them from `/etc/nginx/certs/` inside its container. Both `certs/` directories are
git-ignored. Keep the key readable by your operator account only:

```bash
chmod 600 /opt/padsign/installation-scripts/certs/padsign.example.com.key
```

You can run the same checks yourself before installing:

```bash
cd /opt/padsign
./installation-scripts/validate-certs.sh --host padsign.example.com \
  --cert-crt installation-scripts/certs/padsign.example.com.crt \
  --cert-key installation-scripts/certs/padsign.example.com.key
```

## Worked example: Let's Encrypt with certbot

This obtains a free certificate on the PadSign host itself, before PadSign is installed. It uses
certbot's standalone mode, which answers the Let's Encrypt HTTP challenge on port 80, so:

- `padsign.example.com` must already resolve publicly to this host;
- port 80 must be reachable from the internet and not in use (install PadSign afterwards).

For a host that is not reachable from the internet, use a DNS challenge plugin for your DNS provider
instead (<https://eff-certbot.readthedocs.io/en/stable/using.html#dns-plugins>), or a certificate
from your usual CA.

**1. Install certbot.** On Debian and Ubuntu: `sudo apt-get install -y certbot`. For other
distributions see <https://certbot.eff.org/instructions>.

**2. Request the certificate.**

```bash
sudo certbot certonly --standalone -d padsign.example.com -m ops@example.com --agree-tos
```

certbot writes the files under `/etc/letsencrypt/live/padsign.example.com/`: `fullchain.pem` is
already the full chain, and `privkey.pem` is an unencrypted key.

**3. Stage them for the installer.** `/etc/letsencrypt` is readable by root only, so copy with
`sudo` and give the copies to your operator account:

```bash
cd /opt/padsign
sudo cp /etc/letsencrypt/live/padsign.example.com/fullchain.pem installation-scripts/certs/padsign.example.com.crt
sudo cp /etc/letsencrypt/live/padsign.example.com/privkey.pem   installation-scripts/certs/padsign.example.com.key
sudo chown "$USER": installation-scripts/certs/padsign.example.com.*
chmod 600 installation-scripts/certs/padsign.example.com.key
```

For the wizard, upload these two files, or paste their contents (`cat` them in your SSH session).

**4. Install PadSign** with [3. the wizard](03-install-with-the-wizard.md) or
[4. the command line](04-install-from-the-command-line.md).

### Automatic renewal

Let's Encrypt certificates are valid for 90 days, and certbot's package installs a timer that runs
`certbot renew` twice a day. Once PadSign is running, nginx holds port 80, so the standalone
challenge needs nginx stopped for a few seconds, and the renewed files have to be installed into
PadSign. certbot runs the scripts in `/etc/letsencrypt/renewal-hooks/` as root, and only when a
certificate is actually due: `pre/` before the renewal, `deploy/` only after a successful one,
`post/` after.

Create the three hooks, replacing the hostname and `padsign-operator` (your operator account, [2.1](02-01-host-and-software.md#the-operator-account)):

```bash
sudo tee /etc/letsencrypt/renewal-hooks/pre/padsign-stop-nginx.sh >/dev/null <<'EOF'
#!/bin/bash
cd /opt/padsign && docker compose stop nginx
EOF

sudo tee /etc/letsencrypt/renewal-hooks/post/padsign-start-nginx.sh >/dev/null <<'EOF'
#!/bin/bash
cd /opt/padsign && docker compose start nginx
EOF

sudo tee /etc/letsencrypt/renewal-hooks/deploy/padsign-install-cert.sh >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
host=padsign.example.com
op=padsign-operator
dir=/opt/padsign
case " ${RENEWED_DOMAINS} " in *" ${host} "*) ;; *) exit 0;; esac
grp="$(id -gn "$op")"
install -o "$op" -g "$grp" -m 644 "${RENEWED_LINEAGE}/fullchain.pem" "${dir}/installation-scripts/certs/${host}.crt"
install -o "$op" -g "$grp" -m 600 "${RENEWED_LINEAGE}/privkey.pem"   "${dir}/installation-scripts/certs/${host}.key"
cd "$dir"
runuser -u "$op" -- ./installation-scripts/renew-cert.sh --host "$host" \
  --cert-crt "installation-scripts/certs/${host}.crt" \
  --cert-key "installation-scripts/certs/${host}.key"
EOF

sudo chmod 755 /etc/letsencrypt/renewal-hooks/{pre,post,deploy}/padsign-*.sh
```

The deploy hook installs the renewed files with `renew-cert.sh` as your operator account, which
copies them into `nginx/certs/`, restarts nginx and checks the certificate nginx now serves
([9.2 Renewing the TLS certificate](09-02-renewing-the-tls-certificate.md)).

Test the renewal path (this stops nginx for a few seconds; a dry run skips the deploy hook):

```bash
sudo certbot renew --dry-run
```

certbot still reports success when a deploy hook fails, so also monitor the certificate nginx
actually serves: [9.3 Monitoring the served certificate](09-03-monitoring-the-served-certificate.md).

## Test certificates

For a throwaway test stack without a public name you can use a self-signed certificate, for example:

```bash
cd /opt/padsign
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -subj "/CN=padsign.test" -addext "subjectAltName=DNS:padsign.test" \
  -keyout installation-scripts/certs/padsign.test.key \
  -out installation-scripts/certs/padsign.test.crt
```

Install with `bootstrap.sh --allow-self-signed` (or tick the self-signed option in the wizard). That
skips only the chain check; every other check still runs. Browsers show a warning, and ps-server does
not trust the certificate for its own calls through `https://<host>/`, so do not use this for a stack
anyone relies on. `mkcert` is not included in this package; if you use it, install it separately,
and note that its local CA is trusted only on the machine where you installed it.
