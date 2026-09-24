# 40.3 Monitoring and Alerting

`installation-scripts/monitor-status.sh` has two modes:

- **Report mode** (default) is a read-only snapshot. It prints the numbers below and always exits `0`. Useful for a handoff or a support ticket.
- **Alert mode** (`--alert`) evaluates the same numbers against thresholds, exits `1` when anything fired, and POSTs one JSON message per run to `ALERT_WEBHOOK_URL`. This is what runs from cron.

```bash
./installation-scripts/monitor-status.sh --host padsign.client.com            # report
./installation-scripts/monitor-status.sh --alert                               # alert
```

## Setting up alerting

1. Add the receiver URL to `.env` next to `docker-compose.yml` (it is gitignored, and Slack/Teams webhook URLs are secrets):

   ```bash
   ALERT_WEBHOOK_URL=https://hooks.slack.com/services/T000/B000/XXXX
   # optional, for receivers that want auth:
   # ALERT_WEBHOOK_AUTH_HEADER=Authorization: Bearer <token>
   ```

   An environment variable of the same name wins over `.env`. Docker Compose ignores both; only the script reads them.

2. Run it from cron as the user that runs `docker compose`:

   ```cron
   */10 * * * * cd /opt/padsign && ./installation-scripts/monitor-status.sh --alert >> /var/log/padsign-monitor.log 2>&1
   ```

3. Check it once by hand. With no problems it prints `No alerts.` and exits `0`. To see a delivery end to end, run it with a threshold you are sure to cross, e.g. `ALERT_DISK_PCT=1 ./installation-scripts/monitor-status.sh --alert`.

Without `ALERT_WEBHOOK_URL`, alert mode still prints the alerts and exits `1`, so cron's own `MAILTO` or any wrapper that acts on a non-zero exit still works.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | No alerts (or report mode) |
| 1 | Alerts fired (and were delivered, if a webhook is configured) |
| 2 | Usage error |
| 3 | Alerts fired, but the webhook POST failed (non-2xx or unreachable) |

### Payload

One `POST` with `Content-Type: application/json` per run that has alerts:

```json
{
  "text": "PadSign ALERT on padsign.client.com: 1 alert(s)\n- routing_webhook_permanent_failure: webhook permanent failures: 1 since 2026-09-23T10:20:00Z\n    ps-server  | [documentRouting:webhook] PERMANENT FAILURE after retries {\"docid\":\"…\",\"url\":\"…\",\"status\":500,…}",
  "source": "padsign-monitor",
  "host": "padsign.client.com",
  "generated": "2026-09-23T10:30:00Z",
  "alerts": [
    { "key": "routing_webhook_permanent_failure", "message": "webhook permanent failures: 1 since …", "samples": ["ps-server  | [documentRouting:webhook] PERMANENT FAILURE …"] }
  ]
}
```

`text` carries everything, so Slack and Teams incoming webhooks display it without any mapping. Other receivers can use `alerts[].key` to route. `samples` holds up to three of the matching log lines (trimmed to 400 characters), so a routing alert names the document that failed. The script prints only the scheme and host of the webhook URL, never the path.

## What fires an alert

| Key | Fires when | Threshold (env var, default) |
|---|---|---|
| `service_down` | A service active under the current compose profiles has no container, or its container is not `running` (exited, restarting, …) | - |
| `service_unhealthy` | A container's health check reports `unhealthy` ([40.1](40-01-health-checks-and-startup-order.md)) | - |
| `repeated_restarts` | A container restarted N+ times since the previous check (same container id; a recreated container starts a new count) | `ALERT_RESTART_DELTA`, 2 |
| `certificate_risk` | `nginx/certs/<host>.crt` expires within N days, or is missing/unreadable. Evaluated with `openssl x509 -checkend` | `ALERT_CERT_DAYS`, 14 |
| `archive_failure` | ps-server logged an archive upload/download failure | `ALERT_FAILURE_MIN`, 1 |
| `stamping_failure` | ps-server logged a stamping failure, including the 5xx graceful skip (`[stamp] upstream unavailable, continuing without stamp`) where the document continues **without a seal** | `ALERT_FAILURE_MIN`, 1 |
| `routing_webhook_permanent_failure` | `[documentRouting:webhook] PERMANENT FAILURE after retries` - a webhook gave up after all retries | `ALERT_FAILURE_MIN`, 1 |
| `routing_failure` | Any other routing or receive-back buffer failure (filesystem strategy error, buffer copy/sidecar failure, error webhook failure). Individual retry attempts are not counted - a later attempt may still succeed | `ALERT_FAILURE_MIN`, 1 |
| `circuit_open` | ps-server opened a dependency circuit breaker | `ALERT_FAILURE_MIN`, 1 |
| `disk_pressure` | The filesystem holding the deployment (and, on Linux, Docker's root dir) is N% full or more | `ALERT_DISK_PCT`, 85 |
| `buffer_growth` | N or more signed PDFs are waiting for Manager acknowledgement | `ALERT_BUFFER_MAX`, 100 |
| `buffer_stale` | The oldest unacknowledged signed PDF is older than N hours - a Manager desktop may be offline | `ALERT_BUFFER_MAX_AGE_HOURS`, 72 |

The buffer has no time expiry by design (a document stays until the Manager acknowledges it), so `buffer_growth` and `buffer_stale` are the only thing that notices an offline desktop or a broken Manager. Tune both to the customer's usage.

### Log window and state

The failure counts come from `docker compose logs ps-server`. In alert mode the script remembers when it last ran (`.monitor-state/state`, gitignored) and scans only logs written since then, so a failure alerts once, on the next run after it happened, and then drops out. The first run scans the last `--log-lines` (500) lines. Pass `--since 30m` (or an RFC3339 time) to override. The same state file holds per-container restart counts (for `repeated_restarts`) and the previous buffer size (printed as "Change since previous check").

Conditions that describe the current state (down, unhealthy, certificate, disk, buffer) alert on every run until fixed.

### How the failure signals are matched

Each category matches lines ps-server actually writes to its log, not the `errorCode` strings it returns in HTTP response bodies (`ARCHIVE_TIMEOUT`, `STAMP_UPSTREAM_UNAVAILABLE`, …), which never reach the log. The first version of this script grepped for those error codes, so archive failures and the stamping graceful skip always counted `0`. The patterns live at the top of the "Failure signals" section of the script.

The routing sample lines carry the docid, URL and final status only with ps-server images that include the psapp-saas#15 `logError` fix. Older images log that line as `message: '[object Object]'`; the alert still fires, it just cannot say which document failed.

### Receive-back buffer count

The script runs a short `node` snippet inside the ps-server container (`docker compose exec`) that walks every enabled filesystem strategy's `basePath` (and `bufferPath`) and counts `<file>.meta.json` sidecars whose PDF still exists. That is the same rule `signedPdfBuffer.rebuildFromDisk()` uses, so the count equals the pending index size, and it works with any ps-server image; no endpoint or image change is needed. It also reports the age of the oldest entry.

## Verified

- psapp-saas's integration suite (`server/test/integration/`, scenario 7) runs `monitor-status.sh --alert` against a live stack after forcing a webhook permanent failure, with `ALERT_WEBHOOK_URL` pointed at a local receiver. It asserts the receiver gets exactly one JSON POST containing a `routing_webhook_permanent_failure` alert whose samples and `text` name the failed docid, and that a webhook which fails twice and then recovers raises no such alert.
- A standalone `--alert` run against the same stack fired `routing_webhook_permanent_failure`, `routing_failure` and `disk_pressure` (the dev machine's disk really was 96% full) in about 16 seconds.

## What this does not do

- It is not a metrics store or a paging system. It posts to one webhook; escalation, on-call routing and de-duplication across hosts belong to whatever receives it.
- It watches one host. Several deployments each need their own cron entry.
- `dmss-digital-stamping-service` exposes `/actuator/prometheus`, and the other DMSS services could with a one-line `management.endpoints.web.exposure.include` change, if the organisation later adopts Prometheus. Nothing here depends on that.
