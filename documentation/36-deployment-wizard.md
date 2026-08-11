# 36. Deployment Wizard (Optional Browser UI)

An optional, self-contained browser UI that guides an operator through a
first-time PadSign install or a later upgrade — the same work
[bootstrap.sh](03-quick-start-new-deployment.md) and
[upgrade.sh](05-upgrading-an-existing-deployment.md) already do, with
prerequisite validation surfaced inline (TLS cert format, hostname/cert
match) instead of failing mid-script, and live step-by-step progress instead
of a wall of terminal output.

It **wraps** the existing scripts — `bootstrap.sh`, `upgrade.sh`,
`validate-config.sh`, `validate-certs.sh` — as the tested source of truth. It
never reimplements config rewriting, Keycloak setup, or `docker compose`
orchestration itself. A client who ignores the wizard entirely and runs the
scripts by hand loses nothing; the wizard is optional tooling on top, never a
requirement.

It ships as its own Docker image (`mihailsgordijenko/padsign-wizard`), added
to `docker-compose.yml` as a `profiles: ["wizard"]` service — the same
mechanism already used for [local e-sealing](04-enabling-local-e-sealing.md)'s
`dmss-digital-stamping-service`. Plain `docker compose up -d` never starts it.

## Sub-sections

- [36.1 Concepts and access model](36-01-concepts-and-access-model.md)
- [36.2 Starting the wizard](36-02-starting-the-wizard.md)
- [36.3 Fresh-install walkthrough](36-03-fresh-install-walkthrough.md)
- [36.4 Upgrade walkthrough](36-04-upgrade-walkthrough.md)
- [36.5 Security considerations](36-05-security-considerations.md)
- [36.6 Troubleshooting the wizard](36-06-troubleshooting-the-wizard.md)
- [36.7 Relationship to the CLI scripts](36-07-relationship-to-the-cli-scripts.md)
- [36.8 Visual walkthrough (screenshots)](36-08-visual-walkthrough.md)
- [36.9 Previewing configuration changes](36-09-previewing-configuration-changes.md)

Need to change something *after* go-live — hostname, TLS certificate, or a
feature flag? That's covered separately in
[37. Settings (Post-Go-Live Changes)](37-settings-post-go-live-changes.md),
reachable from the same wizard's top bar once initial setup has completed.
