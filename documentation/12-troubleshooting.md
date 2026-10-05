# 12. Troubleshooting

Start from the symptom. Most problems show up in `validate-config.sh`,
`docker compose ps` or a service's log, so run those first:

```bash
cd /opt/padsign
./installation-scripts/validate-config.sh --host padsign.example.com
docker compose ps
docker compose logs --tail 100 <service>      # keycloak, ps-server, nginx, ps-client, dmss-...
```

| Symptom | Where to look |
|---|---|
| Browser: `Failed to load module script` for `/portal/keycloak.js` | [12.1](12-01-common-issues.md#1-failed-to-load-module-script-for-portalkeycloakjs) |
| Login fails with "Invalid redirect URI", or CORS errors | [12.1](12-01-common-issues.md#2-invalid-redirect-uri-or-cors-errors-at-login) |
| Logged in, but every portal action fails with `401` | [12.1](12-01-common-issues.md#3-every-portal-api-call-returns-401) |
| Browser is sent to another hostname at login | [12.1](12-01-common-issues.md#4-login-redirects-to-another-hostname) |
| Containers do not start, a port is already in use | [12.1](12-01-common-issues.md#5-a-port-is-already-in-use) |
| `dependency failed to start: container ... is unhealthy`, site down after a reboot | [12.1](12-01-common-issues.md#6-dependency-failed-to-start-or-nginx-not-running) |
| ps-server restarts in a loop with `EACCES` on `config.js` | [12.1](12-01-common-issues.md#7-ps-server-restarts-with-eacces-on-configjs) |
| Permission errors writing to `docs/` or `signed-output/` | [12.1](12-01-common-issues.md#8-permission-errors-in-docs-or-signed-output) |
| Browser TLS warning, wrong name on the certificate | [12.1](12-01-common-issues.md#9-tls-warning-or-hostname-mismatch) |
| Keycloak errors or broken login although the certificate looks fine in the browser | [12.1](12-01-common-issues.md#10-login-broken-although-the-certificate-looks-fine) |
| Certificate renewed on disk, but the old one is still served | [9.3 Monitoring the served certificate](09-03-monitoring-the-served-certificate.md) |
| A service cannot reach another (for example ps-server to DMSS) | [12.1](12-01-common-issues.md#11-services-cannot-reach-each-other) |
| Signed documents are not saved, webhooks not received, or the Padsign Manager gets `404` | [12.1](12-01-common-issues.md#12-routing-or-receive-back-does-not-deliver) |
| E-seal skipped (`stampStatus: "skipped"`) | [10.9 Verifying it works](10-09-verifying-it-works.md) and [10.2 Architecture](10-02-architecture.md) |
| `upgrade.sh` refuses a tag, or prints `UPGRADE FAILED` | [12.1](12-01-common-issues.md#13-upgrade-refused-or-failed) |
| No Keycloak admin credential works | [8.3 Admin password and break-glass recovery](08-03-admin-password-and-break-glass.md) |
| Deployment Wizard problems (access token, port 8443, stuck progress) | [3.4 Troubleshooting the wizard](03-04-troubleshooting-the-wizard.md) |

If the issue is not listed, collect a support bundle and contact TrustLynx
support ([14.5 Support](14-05-support.md)):

```bash
cd /opt/padsign
./installation-scripts/support-bundle.sh --since 24h
```

or use **Monitoring > Diagnostics** in the wizard
([9.12](09-12-monitoring-from-the-wizard.md#support-bundles)). The bundle holds
the `validate-config.sh` and `monitor-status.sh` reports
([9.10](09-10-monitoring-and-alerting.md)), redacted configuration and the
service logs, with secrets removed. Logs can still contain signers' names and
e-mail addresses, so check the bundle before you send it.

## Sub-sections

- [12.1 Common issues](12-01-common-issues.md)
