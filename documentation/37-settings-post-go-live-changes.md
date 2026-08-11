# 37. Settings (Post-Go-Live Changes)

The onboarding flow ([bootstrap.sh](03-quick-start-new-deployment.md) or the
[Deployment Wizard](36-deployment-wizard.md)'s guided steps) sets the
hostname, TLS certificate, and feature flags exactly once. Until now there
was no supported way to revisit any of that afterward — changing the
hostname, renewing an expiring certificate, or flipping a feature on/off
meant chaining raw scripts by hand (in the right order, with no automation
gluing them together) or hand-editing `config.js`/`constants.json` directly
on the host.

**Settings** is a new section of the [Deployment Wizard](36-deployment-wizard.md)
that turns those three operations into guided, live-streamed actions —
`Dashboard` and `Settings` sit side by side in the wizard's top bar once
initial setup has completed. Like every other part of the wizard, it
**wraps** `installation-scripts/*.sh` as the tested source of truth; it
never reimplements config-rewriting logic in JavaScript.

## Sub-sections

- [37.1 Concepts and what Settings covers](37-01-concepts-and-what-settings-covers.md)
- [37.2 Changing hostname after go-live](37-02-changing-hostname-after-go-live.md)
- [37.3 Renewing the TLS certificate](37-03-renewing-the-tls-certificate.md)
- [37.4 Toggling features after go-live](37-04-toggling-features-after-go-live.md)
- [37.5 Known gap: Keycloak admin password rotation](37-05-known-gaps-keycloak-admin-password-rotation.md)
