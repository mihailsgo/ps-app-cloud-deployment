# 9. Operations

Day-2 tasks on a running PadSign deployment: changing the hostname,
renewing the certificate, switching features on and off, upgrading and
rolling back, and keeping the stack healthy, monitored, backed up and
started at boot.

Every task is a script in `installation-scripts/`, run from the
deployment directory (`/opt/padsign`). Pass `--help` to any of them for
its full usage. The hostname, certificate and feature tasks are also in the
Deployment Wizard's **Settings** page, upgrading is on its **Dashboard**, and
its **Monitoring** page shows service state, logs and signing activity and
restarts a service. The wizard runs the same scripts, so both routes give the
same result.

| Task | Script | Wizard | Page |
|---|---|---|---|
| Change the public hostname | `update-hostname.sh` | Settings → Hostname | [9.1](09-01-changing-hostname.md) |
| Replace the TLS certificate | `renew-cert.sh` | Settings → TLS Certificate | [9.2](09-02-renewing-the-tls-certificate.md) |
| Check the certificate nginx actually serves | `verify-served-cert.sh` | - | [9.3](09-03-monitoring-the-served-certificate.md) |
| Turn document routing, demo mode or local e-sealing on or off | `toggle-features.sh` | Settings → Feature Toggles | [9.4](09-04-toggling-features.md) |
| Upgrade to a new release | `upgrade.sh` | Dashboard → Upgrade | [9.5](09-05-upgrading.md) |
| Undo an upgrade | `rollback.sh` | - | [9.8](09-08-rollback.md) |
| Check health and service state | `docker compose ps`, `postdeploy-check.sh` | Dashboard, Monitoring | [9.9](09-09-health-checks-and-startup.md) |
| Alert on problems | `monitor-status.sh --alert` | - | [9.10](09-10-monitoring-and-alerting.md) |
| Watch services and logs | `docker compose ps`, `docker compose logs`, `monitor-status.sh` | Monitoring → Overview, Logs | [9.12](09-12-monitoring-from-the-wizard.md) |
| Restart one service | `restart-service.sh` | Monitoring → Overview → Restart | [9.12](09-12-monitoring-from-the-wizard.md#restarting-a-service) |
| Collect a support bundle | `support-bundle.sh` | Monitoring → Diagnostics | [9.12](09-12-monitoring-from-the-wizard.md#support-bundles) |
| Review signing activity | the audit log files under `signed-output/.padsign-audit/` | Monitoring → Signing activity | [9.13](09-13-signing-activity-log.md) |

Rotating the Keycloak admin password is not one of these scripts. See
[8.3 Admin password and break-glass recovery](08-03-admin-password-and-break-glass.md).

Monitoring is described in [9.12 Monitoring from the wizard](09-12-monitoring-from-the-wizard.md).

## Using the Settings page

Settings appears in the wizard's top bar next to **Dashboard** once the
first setup has completed ([3.1 Starting the wizard](03-01-starting-the-wizard.md)
shows how to reach the wizard). Every value it shows (hostname, certificate
expiry, feature states) is read from the files on disk and from Docker each
time the page loads.

Its buttons are coloured by consequence:

| Appearance | Meaning | Examples |
|---|---|---|
| Outlined, white | Changes nothing | **Validate certificate** |
| Gold | The normal action for that card | **Apply changes** |
| Red | Restarts a live service; users see a short interruption | **Update Hostname**, **Renew Certificate** |

Every red action, and **Apply changes** when the change needs a restart,
opens a confirmation dialog that names what will restart. Press `Esc`,
click outside the dialog or click **Cancel** to back out. The wizard runs
one script at a time: while one runs, the other actions are disabled. A
failed run offers **Retry** (the same script with the same arguments),
**Back to Settings** and **Copy log**.

## Sub-sections

- [9.1 Changing the hostname](09-01-changing-hostname.md)
- [9.2 Renewing the TLS certificate](09-02-renewing-the-tls-certificate.md)
- [9.3 Monitoring the served certificate](09-03-monitoring-the-served-certificate.md)
- [9.4 Toggling features](09-04-toggling-features.md)
- [9.5 Upgrading](09-05-upgrading.md)
- [9.6 What upgrade does](09-06-what-upgrade-does.md)
- [9.7 Previewing upgrade changes](09-07-previewing-upgrade-changes.md)
- [9.8 Rollback](09-08-rollback.md)
- [9.9 Health checks and startup](09-09-health-checks-and-startup.md)
- [9.10 Monitoring and alerting](09-10-monitoring-and-alerting.md)
- [9.11 Start at boot, backups and customized hosts](09-11-start-at-boot-backups-and-customized-hosts.md)
- [9.12 Monitoring from the wizard](09-12-monitoring-from-the-wizard.md)
- [9.13 Signing activity log](09-13-signing-activity-log.md)
