# 9.9 Health checks and startup

Every long-running service in `docker-compose.yml` has a health check, and
services wait for their dependencies to be **healthy**, not just started.
This page lists what each check tests, how long a service may take to start,
the start order, and what to do when a start fails.

## Seeing the state

```bash
cd /opt/padsign
docker compose ps                   # STATUS shows (healthy), (unhealthy) or (health: starting)
docker inspect --format '{{json .State.Health}}' ps-server | python3 -m json.tool   # last probe results
```

A container that is `Up` but `unhealthy` is not ready to do its job.

## What each health check tests

| Service | Probe | Healthy when |
|---|---|---|
| `keycloak` | HTTP request to `localhost:9000/auth/health/ready` (the management port) | `200` |
| `dmss-archive-services` | `curl http://localhost:8090/actuator/health` | `200` or `403` (the service's own auth filter answers `403`; a JVM that is down refuses the connection) |
| `dmss-container-and-signature-services` | `curl http://localhost:8092/actuator/health` | body contains `"status":"UP"` |
| `dmss-archive-services-fallback` | `curl http://localhost:8095/actuator/health` | body contains `"status":"UP"` |
| `dmss-digital-stamping-service` (profile `local-eseal`) | HTTP request to `localhost:8084/actuator/health` | body contains `"status":"UP"` |
| `ps-server` | `node` request to `http://localhost:3001/health` | `200` or `401` (the endpoint requires a Keycloak token, so `401` proves the server is up and routing) |
| `ps-client` | `curl http://localhost:80/portal/` | `200` |
| `nginx` | `curl -k https://localhost:443/` | `301` (the redirect to `/portal/`) |
| `wizard` (profile `wizard`) | `curl -k https://localhost:8443/login` | `200` |

The nginx probe does not check the certificate; that is
`verify-served-cert.sh`'s job ([9.3](09-03-monitoring-the-served-certificate.md)).
All probes run inside the container, so they test the service itself, not
the network in front of it.

## Start-up windows

Docker marks a container `unhealthy` only after its `start_period` plus
`retries` failed probes, `interval` apart. Failed probes during
`start_period` do not count, and the first probe that passes marks the
container `healthy` at once. A long `start_period` therefore does not slow
a normal start; it only delays the verdict on a container that runs but
never passes. A container that crashes is noticed at once, because it exits
or restarts.

| Service | `start_period` | `interval` / `retries` | Unhealthy after at most |
|---|---|---|---|
| DMSS services (archive, fallback, container-signature, stamping) | 300 s | 10 s / 10 | about 450 s |
| `keycloak` | 90 s | 10 s / 10 | about 240 s |
| `ps-server` | 30 s | 10 s / 10 | about 180 s |
| `nginx` | 20 s | 10 s / 10 | about 170 s |
| `ps-client` | 15 s | 10 s / 10 | about 165 s |
| `wizard` | 15 s | 30 s / 3 | about 120 s |

The DMSS services are Java applications that download trust lists when
they start. On a cold boot, when they all start at once on a small host,
they can need several minutes.

The scripts wait at least as long as the longest window: `upgrade.sh` and
`rollback.sh` wait up to 480 s (`--health-timeout`), `bootstrap.sh` up to
600 s. They fail as soon as a restarted service reports `unhealthy`, exits,
or restarts twice while waiting, and print its last probe output and its
last 15 log lines.

## Start order

```
dmss-archive-services-fallback
   ├──► dmss-archive-services
   │         │
   └──► dmss-container-and-signature-services ◄──┘

keycloak

keycloak + dmss-archive-services + dmss-container-and-signature-services
   └──► ps-server

ps-client + ps-server
   └──► nginx
```

ps-server starts only when Keycloak, the archive service and the
container-signature service are healthy. nginx starts only when ps-client
and ps-server are healthy, so the site is unreachable until the whole chain
is up.

`dmss-digital-stamping-service` has no dependency edge pointing at it:
Compose would otherwise start the profile-gated service even when local
e-sealing is off. It still has its own health check.

## When `docker compose up -d` fails

```
dependency failed to start: container dmss-container-and-signature-services is unhealthy
```

A service took longer than its window, usually a DMSS service on a slow or
busy host, and everything after it in the chain, nginx last, was not
started. nginx is then created but not running, and `docker compose ps`
does not list it.

1. Wait until `docker compose ps` shows the service `healthy`.
2. Run `docker compose up -d` again. It starts the rest of the chain.
3. If the service never becomes healthy, read its log:
   `docker compose logs --tail 100 <service>`.

`docker compose up -d` itself waits for each dependency without a time
limit of its own, so these windows also decide how long it waits. The boot
unit in [9.11](09-11-start-at-boot-backups-and-customized-hosts.md#starting-the-stack-at-boot)
retries `up -d` for this reason.

## After a reboot

Every service uses `restart: unless-stopped`: it comes back with Docker,
unless it was stopped with `docker compose stop` before the reboot, in which
case it stays down. Docker also restarts containers in no particular order,
without the dependency waits. Install the boot unit so the stack starts with
`docker compose up -d` in the right order:
[9.11, Starting the stack at boot](09-11-start-at-boot-backups-and-customized-hosts.md#starting-the-stack-at-boot).

## Related checks

- [5.3 Post-deploy checks](05-03-post-deploy-checks.md): `postdeploy-check.sh`
  checks the stack from outside (redirects, portal config, Keycloak
  discovery, API protection, TLS).
- [9.10 Monitoring and alerting](09-10-monitoring-and-alerting.md): alerts on
  down, unhealthy or restarting services.
