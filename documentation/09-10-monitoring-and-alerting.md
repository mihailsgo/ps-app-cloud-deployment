# 9.10 Monitoring and alerting

`installation-scripts/monitor-status.sh` checks the running stack and,
run from cron, sends an alert to a webhook (Slack, Microsoft Teams or any
HTTP receiver) when something needs attention: a service down, unhealthy
or restarting, a certificate close to expiry, sealing, archive or routing
failures, a full disk, or signed documents the Padsign Manager has not
collected.

## Modes

```bash
cd /opt/padsign
./installation-scripts/monitor-status.sh --host padsign.example.com   # report
./installation-scripts/monitor-status.sh --alert                       # alert
./installation-scripts/monitor-status.sh --test-webhook                # one test message
```

- **Report** (default): a read-only snapshot of container state, health and
  restart counts, certificate days to expiry, failure counts from the
  ps-server log, disk usage and the receive-back buffer. Always exits `0`.
  Useful for a handover or a support request.
- **Alert** (`--alert`): evaluates the same figures against thresholds,
  exits `1` when anything fired, and posts one message per run to
  `ALERT_WEBHOOK_URL`. This is what cron runs.
- **Webhook test** (`--test-webhook`): sends one harmless message to the
  webhook and prints the HTTP status. It checks nothing else and needs no
  running stack.

Other options: `--since 15m|<RFC3339 time>` (log window for failure
counts), `--log-lines N` (default 500), `--state-dir DIR` (default
`.monitor-state/` in the checkout), `--compose-dir DIR`.

## Setting up alerting

1. Put the receiver URL into `.env` in `/opt/padsign` (git-ignored; webhook
   URLs are secrets). Without it in your shell history:

   ```bash
   cd /opt/padsign
    read -rs ALERT_URL                                   # paste the URL, press Enter
   printf "ALERT_WEBHOOK_URL='%s'\n" "$ALERT_URL" >> .env; unset ALERT_URL
   chmod 600 .env
   ```

   Optional lines in the same file:

   ```bash
   ALERT_WEBHOOK_FORMAT=teams                           # json (default) or teams
   ALERT_WEBHOOK_AUTH_HEADER=Authorization: Bearer <token>   # for receivers that need auth
   ```

   An environment variable of the same name wins over `.env`. Docker
   Compose ignores these keys; only the script reads them. The script prints
   only the URL's scheme and host, and passes the URL and auth header to
   `curl` on standard input, so neither appears in `ps`.

2. Check delivery:

   ```bash
   ./installation-scripts/monitor-status.sh --test-webhook
   ```

   It must print `Result:    HTTP 2xx - delivered to ...`, and the message
   must appear in the receiver.

3. Check the alert run: `./installation-scripts/monitor-status.sh --alert`
   prints `No alerts.` and exits `0` on a healthy stack. To see a real alert
   delivered, use a threshold you are sure to cross:
   `ALERT_DISK_PCT=1 ./installation-scripts/monitor-status.sh --alert`.

4. Schedule it, every 10 minutes, as a user that may run `docker compose`:

   ```cron
   # /etc/cron.d/padsign-monitor
   */10 * * * * root cd /opt/padsign && ./installation-scripts/monitor-status.sh --alert >> /var/log/padsign-monitor.log 2>&1
   ```

   Run your manual `--alert` checks as the same user, since the state
   directory belongs to it.

Without `ALERT_WEBHOOK_URL`, alert mode still prints the alerts and exits
`1`, so cron's `MAILTO` or any wrapper that acts on the exit code still
works.

On a customized (overlay-managed) host, `.env` is rewritten by
`overlay.sh apply`. Put the lines into the overlay's `env` file instead, as
a new overlay version ([9.11, Changing a value in the overlay](09-11-start-at-boot-backups-and-customized-hosts.md#changing-a-value-in-the-overlay)),
or into a root-only file outside the checkout that the cron job loads
(`set -a; . /etc/padsign/alert.env; set +a` before the script).

### Microsoft Teams

A Teams channel webhook is created with the **Workflows** app, and its
standard template only accepts a message carrying an Adaptive Card. Sent
the plain `json` payload, the URL still answers `202 Accepted`, then the
flow fails and nothing appears. Use `ALERT_WEBHOOK_FORMAT=teams`.

1. In the channel, open **...** (More options) next to the channel name
   and choose **Workflows**.
2. Pick the template **Send webhook alerts to a channel**.
3. Name the workflow (for example `PadSign alerts padsign.example.com`),
   click **Next**, confirm the connection if asked, check **Team** and
   **Channel**, and click **Add workflow**.
4. Copy the URL from the last screen and click **Done**. Anyone with the
   URL can post into the channel.

The cards are posted through the connection of the person who created the
workflow; create it with an account that stays.

Keep the URL in single quotes in `.env` (it contains `&`):

```bash
ALERT_WEBHOOK_URL='https://prod-00.westeurope.logic.azure.com:443/workflows/.../triggers/manual/paths/invoke?api-version=...&sig=...'
ALERT_WEBHOOK_FORMAT=teams
```

When `ALERT_WEBHOOK_FORMAT` is not set and the URL's host ends with
`.logic.azure.com` or contains `.powerplatform.com`, the script uses `teams`
and says so. An explicit value always wins. A value other than `json` or
`teams` stops the script with exit code `2`.

Teams answers `202` before its flow runs, so a `2xx` from `--test-webhook`
does not prove the card was posted. If it is not in the channel within a
minute, open the flow's run history in Power Automate.

## What fires an alert

| Key | Fires when | Threshold (environment variable, default) |
|---|---|---|
| `service_down` | a service of the active compose profiles has no container, or it is not `running` | - |
| `service_unhealthy` | a container's health check reports `unhealthy` ([9.9](09-09-health-checks-and-startup.md)) | - |
| `repeated_restarts` | a container restarted N or more times since the previous run | `ALERT_RESTART_DELTA`, 2 |
| `certificate_risk` | `nginx/certs/<host>.crt` expires within N days, or is missing or unreadable | `ALERT_CERT_DAYS`, 14 |
| `archive_failure` | ps-server logged an archive upload or download failure | `ALERT_FAILURE_MIN`, 1 |
| `stamping_failure` | ps-server logged a sealing failure, including `[stamp] upstream unavailable, continuing without stamp` (the document continued **without a seal**) | `ALERT_FAILURE_MIN`, 1 |
| `routing_webhook_permanent_failure` | a routing webhook gave up after all retries | `ALERT_FAILURE_MIN`, 1 |
| `routing_failure` | any other routing or receive-back buffer failure. Single retry attempts do not count | `ALERT_FAILURE_MIN`, 1 |
| `circuit_open` | ps-server opened a dependency circuit breaker | `ALERT_FAILURE_MIN`, 1 |
| `disk_pressure` | the filesystem holding the deployment, a signed-document store, or Docker's data directory is N% full or more | `ALERT_DISK_PCT`, 85 |
| `buffer_growth` | N or more signed PDFs are waiting for a Padsign Manager to collect them | `ALERT_BUFFER_MAX`, 100 |
| `buffer_stale` | the oldest uncollected signed PDF is older than N hours; a Manager desktop may be offline | `ALERT_BUFFER_MAX_AGE_HOURS`, 72 |

Set a threshold as an environment variable on the cron line, for example
`ALERT_CERT_DAYS=21 ./installation-scripts/monitor-status.sh --alert`.

The receive-back buffer never expires entries: a document stays until a
Manager collects it. `buffer_growth` and `buffer_stale` are therefore the
only signals that a desktop is offline or a Manager is broken. Tune them to
how the customer works.

## How often an alert repeats

Failure counts come from `docker compose logs ps-server`. In alert mode
the script remembers when it last ran and scans only the log since then, so
a failure alerts once, on the next run after it happened. The first run
scans the last `--log-lines` lines. Conditions that describe the current
state (down, unhealthy, certificate, disk, buffer) alert on every run until
they are fixed.

The disk figures cover the two signed-document stores (ps-server's
`/signed-output` and the fallback archive's `/docs`) wherever the effective
compose model mounts them from, so an overlay's storage on its own volume
is covered.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | No alerts (or report mode). `--test-webhook`: delivered |
| `1` | Alerts fired (and were delivered, if a webhook is configured) |
| `2` | Usage error, including an unsupported `ALERT_WEBHOOK_FORMAT`. `--test-webhook`: `ALERT_WEBHOOK_URL` not set |
| `3` | Alerts fired, but the webhook delivery failed. `--test-webhook`: not delivered |

## The message

With `ALERT_WEBHOOK_FORMAT=json` (the default), one `POST` per run that
has alerts:

```json
{
  "text": "PadSign ALERT on padsign.example.com: 1 alert(s)\n- routing_webhook_permanent_failure: webhook permanent failures: 1 since 2026-09-23T10:20:00Z\n    ps-server  | [documentRouting:webhook] PERMANENT FAILURE after retries {...}",
  "source": "padsign-monitor",
  "host": "padsign.example.com",
  "generated": "2026-09-23T10:30:00Z",
  "alerts": [
    { "key": "routing_webhook_permanent_failure", "message": "webhook permanent failures: 1 since ...", "samples": ["ps-server  | [documentRouting:webhook] PERMANENT FAILURE ..."] }
  ]
}
```

`text` carries everything, so a Slack incoming webhook shows it as is.
Other receivers can route on `alerts[].key`. `samples` holds up to three of
the matching log lines, so a routing alert names the document that failed.
With `teams`, the same content is sent as an Adaptive Card.

## What this does not do

It is not a metrics store or a paging system: it posts to one webhook, and
escalation and de-duplication belong to the receiver. It watches one host;
each deployment needs its own cron entry.
