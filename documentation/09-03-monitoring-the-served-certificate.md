# 9.3 Monitoring the served certificate

A renewed certificate on disk is not the same as a renewed certificate
being served. nginx reads `nginx/certs/<host>.crt` and `.key` only when it
starts or reloads, and keeps that certificate in memory until the next
start or reload. `verify-served-cert.sh` checks what nginx actually serves.
Schedule it.

## Why file checks are not enough

There are three separate states:

1. the ACME client renewed the certificate;
2. the renewed file is at `nginx/certs/<host>.crt`;
3. nginx serves it.

If the reload after a renewal fails and the failure is discarded, states 1
and 2 stay green for months while nginx keeps serving the old certificate.
Renewal logs show no errors, the file on disk is valid and current, and
`validate-certs.sh` passes every check. Nothing looks wrong until the
certificate in nginx's memory expires, and then TLS fails everywhere at
once: browsers, API clients and the calls between services.

Two things hide it further:

- **A swallowed error.** A reload step written as `... || true` reports
  success whatever happened. A common case is running the reload inside the
  ACME client's container, which has no `docker` command: it fails with
  `docker: not found` on every run and `|| true` hides it.
- **Accidental repair.** Any unrelated nginx restart (an upgrade, a reboot,
  a configuration change) loads whatever is on disk and fixes the symptom.
  A regularly updated deployment can carry the fault unnoticed, until a
  quiet period is longer than the certificate's remaining life.

## Checking it by hand

Compare the served certificate with the file on disk:

```bash
echo | openssl s_client -connect localhost:443 -servername padsign.example.com 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
openssl x509 -in nginx/certs/padsign.example.com.crt -noout -fingerprint -sha256
```

Different fingerprints mean nginx has not reloaded since the file changed.

## The script

```bash
cd /opt/padsign
./installation-scripts/verify-served-cert.sh
```

With no arguments it reads the hostname and certificate path from
`nginx/nginx.conf`, so it stays correct after a hostname change.

| Flag | Default | Purpose |
|---|---|---|
| `--host <fqdn>` | `server_name` in `nginx.conf` | hostname sent as SNI and checked against the certificate |
| `--cert-crt <path>` | `ssl_certificate` in `nginx.conf` | the on-disk certificate to compare with |
| `--connect <host[:port]>` | `localhost:443` (`nginx:443` inside a container) | endpoint for the handshake |
| `--connect-public` | off | shorthand for `<host>:443` |
| `--warn-days N` | `30` | WARN when the certificate expires within N days |
| `--fail-days N` | `7` | FAIL when the certificate expires within N days |
| `--retries N` | `3` | handshake attempts before failing |
| `--retry-delay S` | `2` | seconds between attempts |
| `--timeout S` | `10` | timeout per attempt |
| `--quiet` | off | print nothing unless a check fails |

Checks, in order:

1. the on-disk certificate is readable and parses;
2. the on-disk certificate is not expired or about to expire. If this
   fails, the renewal itself is broken, which is a different problem from a
   failed reload;
3. the nginx service is running (information only, never fails the run);
4. a TLS handshake with the endpoint succeeds (retried);
5. **the served certificate is the on-disk certificate** (the check this
   page is about);
6. the served certificate is not expired or about to expire;
7. the served certificate is valid for the hostname;
8. the served chain is as long as the on-disk file's. This catches an
   intermediate that was added to the file but never loaded, where the leaf
   fingerprint is identical and check 5 cannot see it. A shorter served
   chain is a FAIL only on the default endpoint (`localhost:443`, or
   `nginx:443` inside a container). With `--connect` or `--connect-public`
   it is a WARN, because something in front of nginx may re-terminate TLS.
   A longer served chain, or one whose length cannot be read, is always a
   WARN. A WARN leaves the exit code at `0` and prints nothing under
   `--quiet`, so a scheduled `--quiet` run does not report it.

Exit codes: `0` no failures (warnings allowed), `1` a check failed, `2`
argument error or the hostname could not be read from `nginx.conf`.

A single handshake glitch does not fail the run: the script retries, and a
handshake that succeeded only on retry is a WARN. A listener that is really
down always fails.

### localhost or the public hostname

The default, `localhost:443`, tests nginx alone, without DNS, firewalls or
anything in front of the host. That is where this fault lives.

`--connect-public` tests `<host>:443` and so also proves DNS, firewall and
routing. Use it as a second scheduled check, not instead of the first, and
only when nginx itself terminates TLS. Behind a CDN or load balancer that
terminates TLS again, the served certificate is legitimately different from
the file and the comparison would always fail.

## Scheduling it

Run it on a schedule so a failed reload is caught within hours, and also
at the end of your ACME client's deploy hook (as in
[9.2](09-02-renewing-the-tls-certificate.md#automatic-renewal-lets-encrypt)).

With systemd:

```ini
# /etc/systemd/system/padsign-served-cert.service
[Unit]
Description=PadSign served-certificate check
[Service]
Type=oneshot
WorkingDirectory=/opt/padsign
ExecStart=/bin/bash /opt/padsign/installation-scripts/verify-served-cert.sh
SyslogIdentifier=padsign-served-cert
```

```ini
# /etc/systemd/system/padsign-served-cert.timer
[Timer]
OnCalendar=hourly
RandomizedDelaySec=5m
Persistent=true
[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now padsign-served-cert.timer
```

A failed run marks the unit failed: `systemctl --failed` lists it, and an
`OnFailure=` unit can alert on it. The full output is in the journal
(`journalctl -u padsign-served-cert`).

With cron, if systemd is not available:

```cron
# /etc/cron.d/padsign-served-cert
SHELL=/bin/bash
MAILTO=ops@example.com
17 * * * * root cd /opt/padsign && /bin/bash installation-scripts/verify-served-cert.sh --quiet
```

cron mails any output, so `--quiet` makes it mail only on failure. On a
host without a working mail setup, cron's mail goes nowhere, which is the
same silent failure this check exists to catch. Prefer the systemd timer,
or feed the result into [9.10 Monitoring and alerting](09-10-monitoring-and-alerting.md)
(its `certificate_risk` alert covers expiry of the file on disk).

## When it reports a mismatch

Reload nginx from the deployment directory on the host:

```bash
cd /opt/padsign
docker compose kill -s HUP nginx
./installation-scripts/verify-served-cert.sh
```

The fingerprints must now match. If they do not, nginx rejected the new
files and kept the old configuration. Read `docker compose logs nginx`,
then check the pair on disk:

```bash
./installation-scripts/validate-certs.sh --host padsign.example.com \
  --cert-crt nginx/certs/padsign.example.com.crt --cert-key nginx/certs/padsign.example.com.key
```

## Preventing it

- Run the reload where `docker` exists, which is the host. Mounting
  `/var/run/docker.sock` into the ACME container gives it the socket but no
  client to use it.
- Never end a reload hook with `|| true`.
- Use the ACME client's deploy-hook mechanism rather than copying files on
  a timer. certbot still exits `0` when a deploy hook fails, so pair the
  hook with the scheduled check above.
- Check over the wire, not on disk.
