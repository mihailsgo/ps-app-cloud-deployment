# 40. Reliability: Health Checks, Post-Deploy Validation, Monitoring, Rollback

Covers the tooling that closes the gap described in [psapp-saas#12](https://github.com/mihailsgo/psapp-saas/issues/12): a container reporting `running` in Docker is not the same thing as a container that is actually ready to do its job, and until this set of changes nothing in the stack caught the difference automatically, and there was no automated way back out of a bad upgrade.

## Sub-sections

- [40.1 Health checks and startup order](40-01-health-checks-and-startup-order.md)
- [40.2 Post-deploy validation](40-02-post-deploy-validation.md)
- [40.3 Monitoring and alerting](40-03-monitoring-and-alerting.md)
- [40.4 Rollback](40-04-rollback.md)
- [40.5 Production-safe signing smoke test](40-05-production-safe-signing-smoke-test.md)

## What this closes, and what it doesn't

| Acceptance criterion (from psapp-saas#12) | Status |
|---|---|
| Each long-running service has a meaningful health check with bounded timeouts | Done — [40.1](40-01-health-checks-and-startup-order.md) |
| Deployment waits for required dependencies and fails when they remain unhealthy | Done. `depends_on: condition: service_healthy` orders dependencies ([40.1](40-01-health-checks-and-startup-order.md)); `bootstrap.sh`, `upgrade.sh` and `rollback.sh` additionally wait for the services they (re)started via `lib/health-wait.sh` and exit `1` when one turns unhealthy, exits, crash-loops or times out. Before that, `docker compose up -d` returned as soon as the recreated service was *created*, and a pullable-but-broken image produced `Upgrade complete!` with exit `0`. |
| Post-deploy validation covers redirects, portal/runtime config, Keycloak discovery, protected API behavior, TLS, and an authorized signing smoke test | Done. The first five are real and automated ([40.2](40-02-post-deploy-validation.md)). The authorized signing smoke test is `signing-smoke.sh` (`postdeploy-check.sh --signing-smoke`), designed to be safe on a customer's production host: the smoke user's password never reaches a script, the synthetic document cannot be routed, the production seal is opt-in, and it cleans up after itself ([40.5](40-05-production-safe-signing-smoke-test.md)). It needs one person to approve the login in a browser, so it is not a cron check. psapp-saas#9's Playwright spec remains for dev/staging stacks. |
| Monitoring alerts on repeated restarts, unhealthy services, certificate risk, stamping/archive failures, disk pressure, and unacknowledged buffer growth | Done - `monitor-status.sh --alert` from cron, delivering to `ALERT_WEBHOOK_URL` (Slack/Teams/any HTTP receiver). See [40.3](40-03-monitoring-and-alerting.md). Each deployment still has to set the URL and install the cron entry. |
| Rollback is automated, idempotent, and tested from a failed client and failed server deployment | Done - see [40.4](40-04-rollback.md). Digest-exact since [psapp-saas#11](https://github.com/mihailsgo/psapp-saas/issues/11): `rollback.sh` restores the `tag@digest` of the image that was running when `upgrade.sh` took its snapshot (also after a `git pull` ahead of the upgrade, which already moves `docker-compose.yml`'s pins), and exits `1` if the restored containers run anything else. |
| Validation evidence records exact image digests, configuration checksums, and restart deltas | Done — `installation-scripts/lib/deployment-evidence.sh`, called from `bootstrap.sh`, `upgrade.sh`, and `postdeploy-check.sh`. Covers every compose service, including the profile-gated `dmss-digital-stamping-service` and `wizard` (recorded as `absent` in `service_status` when their profile is not active). Schema mirrors, and is intended to be reconciled with, the evidence mechanism in the (at time of writing, still open) [psapp-saas#7](https://github.com/mihailsgo/psapp-saas/issues/7) PR — see the note at the top of that file. |
