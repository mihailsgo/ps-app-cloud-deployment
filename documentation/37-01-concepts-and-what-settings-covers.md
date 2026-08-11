# 37.1 Concepts and what Settings covers

## What it covers

Settings manages exactly the three things onboarding collects once and
never lets you touch again:

| Card | What it changes | New script(s) behind it |
|------|------------------|--------------------------|
| Hostname | The deployment's public hostname, plus the TLS cert and Keycloak client redirect URIs that go with it | `update-hostname.sh` |
| TLS Certificate | Swaps the certificate/key for the *current* hostname (no hostname change) | `renew-cert.sh` |
| Feature Toggles | Document routing, demo mode, local e-sealing — on or off, any combination | `toggle-features.sh` |

**Explicitly not covered**: rotating the Keycloak admin password. See
[37.5](37-05-known-gaps-keycloak-admin-password-rotation.md) for why, and
the manual workaround.

## Reading the buttons

Settings is the one screen where a mis-click interrupts a live deployment,
so its buttons are colour-coded by consequence:

| Appearance | Meaning | Examples |
|---|---|---|
| Outlined, white | Changes nothing — safe to click while you're still deciding | **Validate certificate** |
| Solid gold | The ordinary forward action for that card | **Apply changes** |
| Solid red | Restarts a live service; users will see a brief interruption | **Update Hostname**, **Renew Certificate** |

Every red action opens a confirmation dialog naming exactly what will
restart before anything happens. Press `Esc`, click outside the dialog, or
click Cancel to back out.

**Apply changes** is gold rather than red because a demo-mode-only change
restarts nothing at all; when the combination you've selected *does* need a
restart, its confirmation dialog says so explicitly.

## Where it lives

Once a deployment has completed setup at least once, the wizard's top bar
shows `Dashboard` and `Settings` side by side. Settings is reachable at
`/settings` directly; both links (and every action button on the page)
disable themselves while any Deploy/Upgrade/Settings action is already
running — the wizard only ever runs one script at a time
([36.7](36-07-relationship-to-the-cli-scripts.md)).

## Live state, not session state

Every value Settings displays — the current hostname, the deployed
certificate's expiry, whether document routing is on — is read straight
off disk/Docker on every page load, never from the onboarding wizard's
session. This matters because an operator managing Settings may be doing
so weeks after onboarding finished, in a session that has no memory of
that original run (sessions expire after 2 hours and are wiped on every
wizard-container restart). Settings reads the same live files the
Dashboard already does (`docker-compose.yml`, `nginx/nginx.conf`,
`config/config.js`, `config/constants.json`, `.env`) rather than trusting
anything left over from onboarding.

## Wrap, don't reimplement

Every mutating action in Settings is a new (small) bash script, invoked
through the exact same live-streamed-progress mechanism the Dashboard's
Upgrade button already uses — the same `Step N/M:` progress markers, the
same pass/fail checklist UI, the same "only one script runs at a time"
rule, and the same **Retry / Back to Settings / Copy log** actions if a run
fails ([36.6](36-06-troubleshooting-the-wizard.md)). Retry re-runs the
identical script with the identical arguments, so a retried hostname change
can't quietly differ from the one that just failed. Three new scripts do
the actual work:

- `update-hostname.sh` — chains `configure-host.sh` (file rewrites) and
  `keycloak-bootstrap.sh` (Keycloak client sync) the same way `bootstrap.sh`
  already does internally, then restarts nginx + ps-server. See
  [37.2](37-02-changing-hostname-after-go-live.md).
- `renew-cert.sh` — calls `configure-host.sh` with the hostname unchanged
  (a pure cert swap) then restarts nginx. See
  [37.3](37-03-renewing-the-tls-certificate.md).
- `toggle-features.sh` — calls `configure-host.sh`'s new
  `--enable-*`/`--disable-*` flags for any combination of the three
  features in one pass, then restarts only what actually needs it. See
  [37.4](37-04-toggling-features-after-go-live.md).

All three are safe to invoke directly from the command line too, without
the wizard — pass `--help` to any of them for usage.
