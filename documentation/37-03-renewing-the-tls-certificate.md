# 37.3 Renewing the TLS certificate

Before this feature, there was no dedicated way to renew a certificate on a
live deployment — `configure-host.sh` would copy a new cert into place if
you called it directly, but it never restarted nginx to actually pick it
up, and no documentation covered the recipe. Settings' TLS Certificate
card closes that gap.

## Using the wizard

1. Open **Settings** — the **TLS Certificate** card shows the currently
   deployed certificate's status (the same OK/WARN checks
   [validate-certs.sh](11-01-tls-prerequisites-for-installation-scripts.md)
   always runs: readable, valid PEM, keypair match, not expired, hostname
   match), read live with no upload needed.
2. Upload or paste the renewed certificate + matching private key.
3. Click **Validate certificate** — this only checks the files and changes
   nothing. Once it passes, **Renew Certificate** becomes available.
4. Click **Renew Certificate** — shown in red, because it restarts a live
   service. Confirm in the dialog and watch the live progress. nginx
   restarts to load the new certificate — expect a brief interruption.
   If the run fails, **Retry** re-runs it with the identical arguments; see
   [36.6](36-06-troubleshooting-the-wizard.md).

## What actually runs

`renew-cert.sh --host <current> --cert-crt <path> --cert-key <path>`:

1. **`configure-host.sh --host <current, unchanged> --cert-crt ... --cert-key ...`**
   — because the hostname argument is unchanged, every *other* rewrite
   `configure-host.sh` makes (nginx `server_name`, the various URLs in
   `config.js`/`constants.json`) is a byte-for-byte no-op. Only the
   certificate files actually change.
2. **Restart nginx and verify** — `docker compose restart nginx`, then
   confirms the container is running and reports, over an actual TLS
   handshake to `localhost:443`, the expiry date of the certificate nginx
   is now *serving*.

   Note this reports the served expiry; it does not compare the served
   certificate against the one on disk. For that — the check that catches a
   renewal which landed on disk but never reached nginx — see
   [11.2 Monitoring the Served Certificate](11-02-monitoring-the-served-certificate.md).

## Running it without the wizard

```bash
./installation-scripts/renew-cert.sh \
  --host padsign.client.com \
  --cert-crt /path/to/renewed.crt \
  --cert-key /path/to/renewed.key
```

## Verifying it worked

```bash
openssl s_client -connect padsign.client.com:443 -servername padsign.client.com </dev/null 2>/dev/null \
  | openssl x509 -noout -enddate
# expect the renewed certificate's notAfter date
```

Or, to assert it rather than eyeball it — this compares the served
certificate against the file on disk and exits non-zero if they differ:

```bash
./installation-scripts/verify-served-cert.sh --host padsign.client.com
```
