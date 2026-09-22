# 40.1 Health Checks and Startup Order

Every long-running service in `docker-compose.yml` now has a `healthcheck:` with a bounded `interval`/`timeout`/`retries`/`start_period`, and `depends_on:` uses `condition: service_healthy` throughout — so `docker compose up -d` genuinely waits for a dependency to be ready, not just started.

## Probe per service

Each probe was picked by exec-ing into the actual running container and testing what's really there — not assumed from documentation. Several images ship without `curl` or `wget`, so the probe uses whatever the image actually has.

| Service | Probe | Why |
|---|---|---|
| `keycloak` | `bash` + raw `/dev/tcp` request to `http://localhost:9000/auth/health/ready` | No `curl`/`wget` in this image. `KC_HEALTH_ENABLED=true` moves health checks to a separate management port (**9000**, confirmed empirically — not documented obviously), and `KC_HTTP_RELATIVE_PATH=/auth` turns out to prefix the management endpoints too (`9000/health/ready` is a 404; `9000/auth/health/ready` is 200). |
| `dmss-archive-services` | `curl` to `http://localhost:8090/actuator/health`, accepting `200` **or `403`** | This service's own request-auth filter blocks `/actuator/health` with a 403 — confirmed stable/consistent, not a startup race. A crashed or unreachable JVM gives connection-refused, not a clean 403, so 403 still proves the app booted and is routing HTTP. |
| `dmss-container-and-signature-services` | `curl` to `http://localhost:8092/actuator/health`, expecting `{"status":"UP"...}` | Actuator open here, no auth filter in front of it. |
| `dmss-archive-services-fallback` | `curl` to `http://localhost:8095/actuator/health`, expecting `{"status":"UP"...}` | Same as above. |
| `dmss-digital-stamping-service` (profile `local-eseal`) | `bash` + raw `/dev/tcp` to `http://localhost:8084/actuator/health` | Actuator is open and returns a clean `{"status":"UP"}`, but this image also has no `curl`/`wget`. |
| `ps-server` | `node -e '...'` hitting `http://localhost:3001/health`, accepting `200` **or `401`** | `/health` is a real, documented endpoint but Keycloak-Bearer-protected by design (`server/app.js` in `psapp`) — a bare TCP check can't distinguish "up" from "up but Express never finished wiring routes." 401 is the expected, correct response without a token; Node is guaranteed present since this is a Node app. |
| `nginx` | `curl -k` to `https://localhost/`, expecting `301` | The stock `nginx:latest` image does have `curl`. `-k` is checking nginx's own listener from inside its own container, not validating certificate trust for an external client — that's `verify-served-cert.sh`'s job. |
| `ps-client` | `curl` to `http://localhost/portal/`, expecting `200` | Root `/` is a 404 in this image (confirmed) — the SPA is actually served under `/portal/`, which is also what nginx proxies to. |

## Dependency graph

The previous `depends_on` was backwards for what startup ordering actually needs (`ps-server` depended on `nginx`; `nginx` depended only on `ps-client`) and covered none of the DMSS chain. It's now:

```
dmss-archive-services-fallback  (no deps)
        │
        ├──► dmss-archive-services
        │              │
        └──► dmss-container-and-signature-services ◄──┘

keycloak  (no deps)

dmss-archive-services, dmss-container-and-signature-services, keycloak
        │
        ▼
     ps-server
        │
        ▼
  ps-client ──► nginx ◄── ps-server
```

`ps-server` does not accept traffic before Keycloak, the archive service, and the container-signature service are all reporting healthy. `nginx` does not start before both `ps-client` and `ps-server` are healthy.

`dmss-digital-stamping-service` (the `local-eseal` profile-gated stamping backend) deliberately has **no** `depends_on` pointing at it from `dmss-container-and-signature-services` or `ps-server`: Compose treats a dependency edge as pulling a profile-gated service in regardless of whether that profile was requested, which would silently defeat the "only starts under `--enable-local-eseal`" design this compose file already documents. It still gets its own health check.

## Verified startup order (real run)

Bringing the stack down and back up from scratch (`docker compose --profile local-eseal down && docker compose --profile local-eseal up -d`) and watching Compose's own event stream shows the dependency graph actually being respected, e.g.:

```
Container ...-dmss-archive-services-fallback Started
Container ...-dmss-archive-services-fallback Waiting
Container ...-dmss-archive-services-fallback Healthy
Container ...-dmss-archive-services Starting        <- only starts after fallback is Healthy
```

Full `docker compose ps` output showing every service reach `healthy` is in the PR description.
