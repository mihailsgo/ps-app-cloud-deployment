# 9.2 Renewing the TLS certificate

Use this to replace the certificate and key for the current hostname, for
example before the old certificate expires. The hostname does not change.
nginx reads its certificate only when it starts or reloads, so the new
files must be installed **and** nginx restarted; `renew-cert.sh` does both.
To change the hostname as well, use [9.1](09-01-changing-hostname.md)
instead.

The certificate file must be the full chain (leaf first, then the
intermediates) and the key must not be encrypted. See
[2.2 DNS and TLS certificates](02-02-dns-and-tls-certificates.md).

## Using the wizard

1. Open **Settings**. The **TLS Certificate** card shows the status of the
   certificate that is deployed now: readable, valid PEM, key matches, not
   expired, hostname matches.
2. Upload or paste the new certificate and its private key.
3. Click **Validate certificate**. This only checks the files. When it
   passes, **Renew Certificate** becomes available.
4. Click **Renew Certificate**, confirm, and watch the progress. nginx
   restarts, which is a short interruption.

## Using the command line

Check the new files first (this changes nothing):

```bash
cd /opt/padsign
./installation-scripts/validate-certs.sh --host padsign.example.com \
  --cert-crt /path/to/renewed.crt --cert-key /path/to/renewed.key
```

Then install them:

```bash
./installation-scripts/renew-cert.sh \
  --host padsign.example.com \
  --cert-crt /path/to/renewed.crt \
  --cert-key /path/to/renewed.key
```

`--host` is the current hostname. Pass the new files from where they are
(for example `installation-scripts/certs/`), not `nginx/certs/<host>.crt`
itself, which is where they are copied to. `--allow-encrypted-key` accepts an
encrypted key, which nginx cannot use without a passphrase; only use it if
you decrypt the key another way before nginx starts.

The script prints two steps:

1. **Installs the certificate** with `configure-host.sh` into
   `nginx/certs/<host>.crt` / `.key`. The hostname is unchanged, so no other
   file changes. It prints the new file's expiry date.
2. **Restarts nginx and checks** that the container runs and, over a real
   TLS handshake to `localhost:443`, which expiry date nginx now serves.

## Verifying it worked

```bash
./installation-scripts/verify-served-cert.sh --host padsign.example.com
```

This compares the certificate nginx serves with the file on disk and
exits non-zero if they differ. See
[9.3 Monitoring the served certificate](09-03-monitoring-the-served-certificate.md).
To look at the served expiry by hand:

```bash
openssl s_client -connect padsign.example.com:443 -servername padsign.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -enddate
```

## Automatic renewal (Let's Encrypt)

With certbot on the host, a deploy hook runs `renew-cert.sh` after each
renewal, so the new certificate is installed and nginx restarted. Set up the
hooks as described in
[2.2, Automatic renewal](02-02-dns-and-tls-certificates.md#automatic-renewal);
that page has the complete set of hooks to use.

Rules that keep an automated renewal from failing silently:

- Run the hook on the host, where the `docker` command exists, not inside
  a container.
- Never end a reload or restart step with `|| true`. That turns a failed
  reload into weeks of nginx serving the old certificate.
- certbot exits `0` even when a deploy hook fails, so a hook is not an
  alert. Schedule `verify-served-cert.sh` as well
  ([9.3](09-03-monitoring-the-served-certificate.md)).

On a customized (overlay-managed) host, also refresh the overlay after a
renewal, or the next `overlay.sh apply` reinstalls the old certificate:
[9.11, Certificate renewal on a customized host](09-11-start-at-boot-backups-and-customized-hosts.md#certificate-renewal-on-a-customized-host).
