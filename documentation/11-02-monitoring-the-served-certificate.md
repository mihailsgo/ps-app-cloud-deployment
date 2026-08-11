# 11.2 Monitoring the Served Certificate

Renewing a certificate and *serving* a renewed certificate are two different things. This section covers the gap between them, why file-level checks cannot see it, and how to detect it.

## Why file checks are not enough

NGINX reads the files named by `ssl_certificate` and `ssl_certificate_key` **only at startup and on reload**. It then holds that certificate in memory for the life of the worker processes.

That means there are three distinct states, and they are easy to conflate:

1. ACME renewal succeeded
2. the renewed file is on disk at `nginx/certs/<host>.crt`
3. NGINX is actually serving it

States 1 and 2 can be green for months while state 3 is stale. Nothing about a fresh file on disk proves NGINX has read it.

## The failure mode

This is the part worth internalising, because every instinct points the wrong way.

A common renewal setup runs an ACME client on a schedule, copies the new fullchain into `nginx/certs/`, and then reloads NGINX. If that **reload step fails**, and its failure is discarded, you get:

- renewal logs reporting **zero failures**, indefinitely
- a perfectly valid, current certificate file on disk
- `validate-certs.sh` passing **every one of its checks**
- and NGINX still serving the certificate it loaded weeks or months ago

Nothing looks wrong until the certificate NGINX is holding in memory expires. At that moment TLS breaks completely and all at once — for browsers, for API clients, and for any backchannel call between services.

Two details make this especially good at hiding:

- **A swallowed error.** A reload step written as `... || true` reports success no matter what happened. The classic version of this is running the reload *inside* the ACME client container, where no `docker` binary exists — the command fails with `docker: not found` on every single run, and `|| true` erases it.
- **Accidental cover.** Any unrelated restart of NGINX — an upgrade, a host reboot, a config change — loads whatever is on disk at that moment and silently repairs the symptom. A deployment that is updated regularly can carry this defect for a long time without consequence, and only breaks once deployments pause for longer than the certificate's remaining life.

Renewal was never the problem. Delivery was.

## What actually proves it

Open a real TLS connection and compare what comes back against the file on disk:

```bash
echo | openssl s_client -connect localhost:443 -servername padsign.example.com 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
openssl x509 -in nginx/certs/padsign.example.com.crt -noout -fingerprint -sha256
```

If those two fingerprints differ, NGINX has not reloaded since the file changed.

## The script

`installation-scripts/verify-served-cert.sh` automates exactly that comparison, plus the surrounding checks.

```bash
./installation-scripts/verify-served-cert.sh
```

With no arguments it derives the hostname and certificate path from `nginx/nginx.conf`, so it stays correct after `configure-host.sh` rewrites them.

| Flag | Default | Purpose |
|------|---------|---------|
| `--host <fqdn>` | derived from `nginx.conf` `server_name` | hostname to send as SNI and check the certificate against |
| `--cert-crt <path>` | derived from `nginx.conf` `ssl_certificate` | the on-disk certificate to compare against |
| `--connect <host[:port]>` | `localhost:443` (`nginx:443` in a container) | endpoint to handshake with |
| `--connect-public` | off | shorthand for `<host>:443` |
| `--warn-days N` | `30` | WARN threshold for expiry |
| `--fail-days N` | `7` | FAIL threshold for expiry |
| `--retries N` | `3` | handshake attempts before declaring failure |
| `--retry-delay S` | `2` | seconds between attempts |
| `--timeout S` | `10` | per-attempt handshake timeout |
| `--quiet` | off | print nothing unless a check FAILs |

Checks, in order:

1. the on-disk certificate is readable and parses
2. the on-disk certificate is not expired or expiring imminently — if this fails, **renewal itself** is broken, which is a different root cause from a failed reload
3. the NGINX service is running (diagnostic only; never fails the run)
4. a TLS handshake against the endpoint succeeds, retried
5. **the served certificate matches the on-disk certificate** — the check this section exists for
6. the served certificate is not expired or expiring imminently
7. the served certificate is valid for the hostname
8. the served chain is as deep as the on-disk file — catches a missing intermediate that was appended to the file but never reloaded, where the leaf fingerprint is *identical* and check 5 cannot see it

Exit codes: `0` no failures (warnings allowed), `1` one or more checks failed, `2` argument error or the hostname could not be derived.

A transient handshake blip cannot produce a failure on its own — the script retries, and reports a successful-but-retried handshake as a WARN. A genuinely dead listener always fails.

### localhost vs the public hostname

The default target is `localhost:443`, which isolates NGINX from DNS, firewalls, and anything upstream. That is the right default here, because the defect being hunted is inside this stack.

`--connect-public` targets `<host>:443` instead and additionally proves DNS, firewall, and routing. Use it as a *second* scheduled check rather than a replacement — and **only when NGINX itself terminates TLS**. If a CDN or load balancer re-terminates TLS in front of NGINX, the served certificate legitimately differs from the file on disk and the comparison would fail permanently.

## Scheduling it

Run it on a schedule so a failed reload is caught in hours rather than at expiry. Also chain it after your ACME client's deploy hook, so a broken reload surfaces within seconds of the renewal that exposed it.

systemd is the better choice:

```ini
# /etc/systemd/system/padsign-served-cert.service
[Unit]
Description=PadSign served-certificate check
[Service]
Type=oneshot
WorkingDirectory=/opt/psapp
ExecStart=/bin/bash /opt/psapp/installation-scripts/verify-served-cert.sh
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
sudo systemctl enable --now padsign-served-cert.timer
```

The cron equivalent, if systemd is unavailable:

```cron
# /etc/cron.d/padsign-served-cert
SHELL=/bin/bash
MAILTO=ops@example.com
17 * * * * root cd /opt/psapp && /bin/bash installation-scripts/verify-served-cert.sh --quiet
```

Note the deliberate asymmetry. **cron** gets `--quiet`, because cron mails any output and silence-unless-broken is the correct idiom there — but be aware that on a host with no configured MTA, cron's mail goes nowhere, which is the same silent-failure mode this section is about. **systemd** gets full output, because journald captures it unconditionally, a non-zero exit marks the unit failed, and `systemctl --failed` and `OnFailure=` give you real alerting surfaces.

Scripts in `installation-scripts/` are committed without the executable bit, so scheduled jobs should invoke `bash <script>` explicitly rather than relying on `./<script>`.

## When it reports drift

Reload NGINX from the project root **on the host**:

```bash
docker compose kill -s HUP nginx
```

Then re-run the script. The two fingerprints must become identical.

If they do **not** change, NGINX rejected the new files and kept its previous configuration. Check `docker compose logs nginx`, then validate the pair on disk:

```bash
./installation-scripts/validate-certs.sh --host padsign.example.com --cert-crt nginx/certs/padsign.example.com.crt --cert-key nginx/certs/padsign.example.com.key
```

## Preventing it

- **Run the reload where `docker` exists.** The ACME client container almost certainly has no Docker CLI. Mounting `/var/run/docker.sock` into it provides the transport but not a client — a socket with nothing to speak to it. Either run the reload on the host, or give the container both the socket and a way to use it.
- **Never end a reload hook with `|| true`.** That single idiom is what converts a loud, immediately-diagnosable failure into a silent multi-week outage.
- **Use your ACME client's deploy-hook mechanism** rather than an unconditional copy on a timer. A deploy hook runs only on an actual renewal and its failure is logged rather than discarded. Note that certbot specifically still exits `0` when a deploy hook fails — it prints the hook's error but does not fail the renewal — so a deploy hook alone is not an alerting mechanism. Pair it with the scheduled check above.
- **Verify over the wire, not on disk.** Any check that reads only the file will pass throughout this entire failure mode.

## Related

- [11.1 TLS Prerequisites (For Installation Scripts)](11-01-tls-prerequisites-for-installation-scripts.md) — file naming, fullchain requirements, and `validate-certs.sh`
- [25. Production Hardening](25-production-hardening.md) — managed TLS and rotation
- [37.3 Renewing the TLS certificate](37-03-renewing-the-tls-certificate.md) — the operator-driven certificate swap
