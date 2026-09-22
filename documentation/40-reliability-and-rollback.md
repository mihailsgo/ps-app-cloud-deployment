# 40. Reliability: Health Checks, Post-Deploy Validation, Monitoring, Rollback

Covers the tooling that closes the gap described in [psapp-saas#12](https://github.com/mihailsgo/psapp-saas/issues/12): a container reporting `running` in Docker is not the same thing as a container that is actually ready to do its job, and until this set of changes nothing in the stack caught the difference automatically, and there was no automated way back out of a bad upgrade.

## Sub-sections

- [40.1 Health checks and startup order](40-01-health-checks-and-startup-order.md)
- [40.2 Post-deploy validation](40-02-post-deploy-validation.md)
- [40.3 Monitoring and alerting proposal](40-03-monitoring-and-alerting-proposal.md)
- [40.4 Rollback](40-04-rollback.md)

## What this closes, and what it doesn't

| Acceptance criterion (from psapp-saas#12) | Status |
|---|---|
| Each long-running service has a meaningful health check with bounded timeouts | Done — [40.1](40-01-health-checks-and-startup-order.md) |
| Deployment waits for required dependencies and fails when they remain unhealthy | Done — [40.1](40-01-health-checks-and-startup-order.md) |
| Post-deploy validation covers redirects, portal/runtime config, Keycloak discovery, protected API behavior, TLS, and an authorized signing smoke test | Mostly done — the first five are real and automated ([40.2](40-02-post-deploy-validation.md)); the authorized signing smoke test depends on [psapp-saas#9](https://github.com/mihailsgo/psapp-saas/issues/9), which had not landed a real authenticated test at the time this was written. `postdeploy-check.sh` has a slot for it and prints an explicit `SKIPPED` line rather than faking coverage. |
| Monitoring alerts on repeated restarts, unhealthy services, certificate risk, stamping/archive failures, disk pressure, and unacknowledged buffer growth | Partial by design — see [40.3](40-03-monitoring-and-alerting-proposal.md). Everything listed is now *observable* via `monitor-status.sh`; nothing *pages* anyone. Standing up a real alerting system was out of reach for the session that wrote this and is explicitly not attempted here. |
| Rollback is automated, idempotent, and tested from a failed client and failed server deployment | Done, tested against tag-based rollback — see [40.4](40-04-rollback.md). Digest-exact rollback depends on [psapp-saas#11](https://github.com/mihailsgo/psapp-saas/issues/11) (image digest pinning), not yet landed. |
| Validation evidence records exact image digests, configuration checksums, and restart deltas | Done — `installation-scripts/lib/deployment-evidence.sh`, called from `bootstrap.sh`, `upgrade.sh`, and `postdeploy-check.sh`. Schema mirrors, and is intended to be reconciled with, the evidence mechanism in the (at time of writing, still open) [psapp-saas#7](https://github.com/mihailsgo/psapp-saas/issues/7) PR — see the note at the top of that file. |
