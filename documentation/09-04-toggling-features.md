# 9.4 Toggling features

Use this to turn any of the three optional features on or off on a
running deployment, in any combination, with one restart:

| Feature | What it controls | Details |
|---|---|---|
| Document routing | What ps-server does with a signed PDF (save to disk, webhook) | [11. Document routing and receive-back](11-document-routing-and-receive-back.md) |
| Demo mode | The demo upload flow in the portal (`DEMO_MODE` in `config/constants.json`) | [7.3 Client constants.json](07-03-client-constants-json.md) |
| Local e-sealing | Sealing in this stack instead of the external e-sealing service | [10.5 Switching modes](10-05-switching-modes.md) |

## Using the wizard

1. Open **Settings**. The **Feature Toggles** card shows the current state
   of each feature, read from `config/config.js`, `config/constants.json`
   and `.env`.
2. Flip the switches you want. **Apply changes** becomes active only when
   something differs from the current state.
3. Click **Apply changes**. The dialog names what changes and what
   restarts. Confirm and watch the progress.

Flipping several switches before **Apply changes** costs one restart, not
one per switch.

## Using the command line

```bash
cd /opt/padsign
./installation-scripts/toggle-features.sh --enable-routing --disable-demo
```

Flags, at least one required:

- `--enable-routing` / `--disable-routing`
- `--enable-demo` / `--disable-demo`
- `--enable-local-eseal` / `--disable-local-eseal`
- `--host <hostname>` (optional; read from `nginx/nginx.conf` when left out)

The script prints three steps:

1. **Configures the flags** with `configure-host.sh`.
2. **Restarts only what needs it:**
   - demo mode needs no restart. The script rewrites `constants.json` in
     place, so ps-client serves the new value at once and browsers pick it
     up on their next page load. After editing the file by hand, restart
     ps-client ([7.2](07-02-how-configuration-is-loaded.md#when-a-change-takes-effect));
   - document routing and local e-sealing restart ps-server, which reads
     `config.js` only at start;
   - turning local e-sealing **on** also starts or recreates
     `dmss-container-and-signature-services` and
     `dmss-digital-stamping-service`. The first time, it provisions the
     stamping service's demo files, compose entry and configuration;
   - turning local e-sealing **off** also stops
     `dmss-digital-stamping-service`.
3. **Verifies** each changed flag by reading it back from disk, and prints
   `OK` or a `WARNING`.

Turning local e-sealing on needs a ps-server image at or above the
`local-eseal` minimum in `release/capabilities.json`
(`python3 -m json.tool release/capabilities.json`). Before it changes
anything, the script compares that minimum with the image tag pinned in
`docker-compose.yml`, not with the container that is running, and refuses
with the reason (exit 2) if the pinned tag is older. If you edited the tag in
`docker-compose.yml` but have not recreated ps-server yet, the check passes
while the old image still runs; run `docker compose up -d` first so the
pinned tags are the ones running.
To raise the tag, upgrade first ([9.5](09-05-upgrading.md)).

### What each flag changes

| Flag | File edit |
|---|---|
| `--enable-routing` | `DOCUMENT_ROUTING.enabled` and the `filesystem` strategy's `enabled` set to `true` in `config/config.js`. Adds a `DOCUMENT_ROUTING` block first if there is none |
| `--disable-routing` | `DOCUMENT_ROUTING.enabled` set to `false` only. Every strategy's settings (for example a webhook URL) stay as they are, so turning routing back on restores them |
| `--enable-demo` / `--disable-demo` | `DEMO_MODE` in `config/constants.json` set to `"ENABLE"` / `"DISABLE"` |
| `--enable-local-eseal` / `--disable-local-eseal` | `STAMP_MODE` in `config/config.js` (`"local"` / `"external"`) and `COMPOSE_PROFILES=local-eseal` in `.env`, plus the provisioning described in [10.5](10-05-switching-modes.md) |

Webhooks, per-company strategies and path templates are not switched here:
edit `config/config.js` and restart ps-server
([11](11-document-routing-and-receive-back.md)).

`configure-host.sh` accepts the same `--enable-*` / `--disable-*` flags,
but only edits files and restarts nothing. Use `toggle-features.sh` unless
you restart the services yourself.

## Verifying it worked

```bash
docker compose logs ps-server --tail 20
docker compose ps dmss-digital-stamping-service     # local e-sealing only
./installation-scripts/validate-config.sh --host padsign.example.com
```
