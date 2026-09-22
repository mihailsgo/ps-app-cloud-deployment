# 40.3 Monitoring and Alerting Proposal

`installation-scripts/monitor-status.sh` is a **read-only observability report**, not an alerting system. Nothing it does pages anyone. Run it ad hoc, or on a cron:

```bash
./installation-scripts/monitor-status.sh --host padsign.client.com
```

It reports, per service: health state and Docker's own restart count; on-disk-vs-served-adjacent certificate days-to-expiry; stamping/archive/routing failure counts grepped from recent `ps-server` logs against the concrete error markers that actually exist in that code today (`ARCHIVE_ERROR`, `ARCHIVE_TIMEOUT`, `STAMP_UPSTREAM_UNAVAILABLE`, `[circuit:open]`, `documentRouting` failure log lines); disk usage for `signed-output/`, `docs/`, and the `keycloak_data` volume; and the signed-PDF receive-back buffer situation (see the caveat below — this one is a real, stated gap, not a solved problem).

## Why this stops short of alerting

Standing up and verifying a real alerting stack (Prometheus + Alertmanager, Grafana alerting, Datadog, a cloud provider's native alarms, or anything else) needs infrastructure — a place to run it, credentials, retention, on-call routing — that this session had no way to provision or verify. Faking one (a docker-compose Prometheus container nobody's on-call rotation actually watches) would be worse than saying plainly that this part is unfinished. **It is unfinished.** What follows is a proposal for wiring the numbers above into whatever the organization already runs, or decides to adopt — not a recommendation of a specific product.

## What already exists to scrape, if a real metrics stack goes in

- `dmss-digital-stamping-service`'s `application.yml` already exposes `/actuator/prometheus` (explicit actuator config, confirmed by reading the file) — a Prometheus scrape target with zero extra work.
- `dmss-archive-services`, `dmss-container-and-signature-services`, and `dmss-archive-services-fallback` have `management.health.probes.enabled: true` but do **not** currently expose `/actuator/prometheus` — adding it is the same one-line `management.endpoints.web.exposure.include` change `dmss-digital-stamping-service`'s config already demonstrates.
- Docker itself already tracks health state and restart count per container (`docker inspect`) — `monitor-status.sh` and `deployment-evidence.json` both already read this; a metrics agent (`cadvisor`, Docker's own metrics endpoint, or a compose-aware exporter) would expose the same numbers to a real time-series store without new application code.
- `verify-served-cert.sh` and `monitor-status.sh` both already compute certificate days-to-expiry in a script-friendly way — a cron calling either and alerting on a non-zero/low-days exit is a same-day integration with anything that can run a script and act on its result (a simple webhook-on-failure wrapper, a scheduled CI job, a NOC tool that already runs health-check scripts).

## Per-criterion mapping (from psapp-saas#12's acceptance criteria)

| Wanted | Feeds from | Real today? |
|---|---|---|
| Repeated restarts | `docker inspect .RestartCount`, and `deployment-evidence.json`'s `restart_deltas` (diffed between two evidence snapshots) | Observable, not alerting |
| Unhealthy services | Compose health state (`40.1`) | Observable, not alerting |
| Certificate risk | `verify-served-cert.sh` / `monitor-status.sh` expiry calculation | Observable, not alerting |
| Stamping/archive failures | Log-line grep (concrete markers exist, listed above) | Observable, not alerting |
| Disk pressure | `monitor-status.sh`'s disk-usage section | Observable, not alerting |
| Unacknowledged buffer growth | **Not fully observable yet** — see below | Partial gap |

## The one real gap: signed-PDF receive-back buffer growth

`psapp/server/lib/signedPdfBuffer.js` was read in full while building this. It exposes exactly six functions (`register`, `listPending`, `getEntry`, `latestForPair`, `acknowledge`, `rebuildFromDisk`) and **no stats getter**. The only numeric signal is `rebuildFromDisk()`'s return value (`byDocid.size`), and that only fires at boot or an explicit rescan — not something a live monitor can poll continuously.

`monitor-status.sh` reports the closest available proxy: the last `index rebuilt from disk` log line (has a count, but stale after boot) and counts of `buffered signed document` / `acknowledged + removed from buffer` log lines within the scanned window (relative activity, not an absolute buffer size). That is a real, honest signal, but it is not the same thing as "how many documents are sitting in the buffer right now, unacknowledged."

Closing this fully needs a small `psapp` change — out of scope for this repo/PR, but concretely: add a `getStats()` (or similarly named) export to `signedPdfBuffer.js` returning `{ size: byDocid.size, oldestEntryAge }`, and expose it through an internal, protected endpoint (or push it into a log line on an interval) that `monitor-status.sh` can read. Flagging this precisely rather than declaring it solved.
