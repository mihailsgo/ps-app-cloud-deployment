# 37.4 Toggling features after go-live

Before this feature, only [local e-sealing](04-05-switching-modes-after-install.md)
had a documented, reversible on/off recipe — document routing and demo mode
could only ever be turned *on* by `bootstrap.sh`/`configure-host.sh`; there
was no supported way to turn either back off short of hand-editing
`config.js`. Settings' Feature Toggles card brings all three flags to the
same standard: full on/off, restart only what's actually needed.

## Using the wizard

1. Open **Settings** — the **Feature Toggles** card shows each flag's
   *live* current state (read straight from `config.js`/`constants.json`/
   `.env`, not a guess).
2. Flip any combination of switches. **Apply changes** only becomes
   active once something has actually changed — if you flip a switch and
   flip it back, it greys out again.
3. Click it, confirm in the dialog (which names exactly what's changing
   and what it will restart), and watch the live progress. If the run
   fails, **Retry** re-runs it with the identical arguments; see
   [36.6](36-06-troubleshooting-the-wizard.md).

Flipping several switches before clicking Apply costs **one** restart, not
one per switch.

## What actually runs

`toggle-features.sh [--enable-routing|--disable-routing] [--enable-demo|--disable-demo] [--enable-local-eseal|--disable-local-eseal]`:

1. **`configure-host.sh`** with whichever `--enable-*`/`--disable-*` flags
   were requested (new complementary `--disable-*` flags added for this
   feature — see below).
2. **Restart only what changed actually needs**:
   - **Demo mode needs no restart at all.** `constants.json` is served
     directly from a bind mount; the browser picks up a new value on next
     page load.
   - **Document routing and local e-sealing both need `ps-server`
     restarted** — `config.js` is `require()`-cached, exactly as
     [18.6](18-06-changing-values-safely.md) already documents.
   - **Turning local e-sealing ON** additionally starts/recreates
     `dmss-container-and-signature-services` and
     `dmss-digital-stamping-service` (first-time provisioning is handled
     the same idempotent way `upgrade.sh --enable-local-eseal` already
     does — nothing new to provision by hand).
   - **Turning local e-sealing OFF** additionally stops
     `dmss-digital-stamping-service`, so "off" means the container isn't
     running, not just profile-gated.
3. **Verify** — reads each touched flag back from disk and reports
   OK/WARNING against what was requested.

Enabling local e-sealing for the first time still requires
`mihailsgordijenko/ps-server:3.26` or newer (the same version gate
`upgrade.sh --enable-local-eseal` already enforces) — `toggle-features.sh`
checks this before making any change and refuses with a clear message
(pointing at Dashboard → Upgrade) if the running tag predates it.

### `--disable-routing` only flips the master switch

Turning document routing off sets only `DOCUMENT_ROUTING.enabled` to
`false`; any per-strategy configuration underneath (a customer's webhook
URL, for instance) is left exactly as it was. Turning it back on later
restores that configuration rather than resetting it to blank defaults.

## Running it without the wizard

```bash
# Any combination in one call:
./installation-scripts/toggle-features.sh \
  --enable-routing --disable-demo --host padsign.client.com

# --host is optional — it defaults to a live read of nginx.conf.
```

`configure-host.sh` itself also gained the three new flags directly, if
you're scripting around it rather than going through
`toggle-features.sh`: `--disable-routing`, `--disable-demo`,
`--disable-local-eseal`. These are pure file edits with no restart of
their own — `toggle-features.sh` (or the wizard) is what adds the
restart step on top.

## Verifying it worked

```bash
docker compose logs ps-server --tail 20 | grep -i 'routing\|stamp'
docker compose ps dmss-digital-stamping-service   # only relevant to local e-sealing
```
