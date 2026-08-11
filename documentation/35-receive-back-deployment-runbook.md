# 35. Receive-back — production deployment runbook

How to roll the signed-PDF **receive-back** feature (and the supporting
config changes) onto a real PadSign deployment safely. Execute on a host where
you have SSH + Docker + registry push access. **Do staging first, then prod.**

> Scope of the change: ps-server gains `/api/signedPdf`, `/api/signedPdf/pending`,
> `/api/signedPdf/ack` + an ack-driven signed-PDF buffer; the filesystem routing
> strategy populates that buffer; per-company webhook scoping; config knobs
> (`USER_ENTRY_TTL_MS`=600000, `PAD_ARRIVAL_TIMEOUT_MS`, routing enabled, `{email}`
> path token). The Padsign Manager (desktop) gains the polling client. Full
> design: `psapp/docs/document-routing-spec.md` → *Receive-back buffer & per-company delivery*.

---

## 0. Prerequisites

- SSH/console access to the target host and permission to restart `ps-server`.
- Docker Hub push rights for `mihailsgordijenko/ps-server` (or your registry).
- A **maintenance window** for prod — `docker compose up -d ps-server` recreates
  the container (seconds of signing downtime).
- The working-tree changes **committed** (next step) so the image is built from a
  known commit, not a dirty tree.

---

## 1. Commit the changes (per repo, on a branch)

The work was done edit-only. Commit it so it's reviewable and the image is
reproducible. Changed files:

**`psapp`** (build source):
- new: `server/lib/signedPdfBuffer.js`, `server/test/test-signed-pdf-buffer.js`, `server/.dockerignore`
- modified: `server/app.js`, `server/lib/documentRouting.js`, `config/config.js` (`{email}` token)
- docs: `README.md`, `CLAUDE.md`, `docs/document-routing-spec.md`

**`ps-app-cloud-deployment`** (runtime config):
- modified: `config/config.js` (TTL=600000, `PAD_ARRIVAL_TIMEOUT_MS`, `DOCUMENT_ROUTING.enabled=true` + filesystem strategy on, `{email}` template, example per-company webhook)
- docs: `documentation/13-configuration.md`, `documentation/18-04-server-configconfigjs.md`, this runbook

**`virtual printer`** (Manager/Listener):
- new: `src/Padsign.Listener/SignedPdfReceiver.cs`, `tests/Padsign.Listener.ReceiveBackTests/`
- modified: `src/Padsign.Listener/Program.cs`, `src/Padsign.Manager/ManagerConfig.cs`, `MainWindow.xaml`, `MainWindow.xaml.cs`, `config/padsign.sample.json`
- docs: `README.md`, `CLAUDE.md`

> `virtual printer` has a git dubious-ownership block; `git config --global --add safe.directory 'C:/Repos/virtual printer'` before committing there.

Run the tests before tagging:
```bash
# psapp
node server/test/test-signed-pdf-buffer.js          # -> PASS
# virtual printer
dotnet run --project tests/Padsign.Listener.ReceiveBackTests/Padsign.Listener.ReceiveBackTests.csproj -c Release   # -> 22 passed
```

---

## 2. Build + push the ps-server image

> **Already done:** `mihailsgordijenko/ps-server:3.27` is built and published to
> Docker Hub, and `docker-compose.yml` already pins it. You can skip to step 3/4
> and just `docker compose pull ps-server`. Rebuild only if you changed server code.

From `psapp/server` (the `.dockerignore` added in this change keeps Windows
`node_modules` out of the image):

```bash
cd /path/to/psapp/server
NEW_TAG=mihailsgordijenko/ps-server:3.27        # bump from :3.26
docker build -t "$NEW_TAG" .
docker push "$NEW_TAG"
```

Sanity-check the image actually contains the feature before shipping:
```bash
docker run --rm "$NEW_TAG" sh -lc 'grep -c signedPdf app.js; ls lib | grep signedPdfBuffer.js'
# expect a non-zero count and signedPdfBuffer.js present
```

---

## 3. Apply config + compose changes on the target

On the deployment host's checkout of `ps-app-cloud-deployment`:

1. **Image tag** — `docker-compose.yml`, `ps-server.image`: `…:3.26` → `…:3.27`.
2. **Config** — `config/config.js` must contain (already in this repo's copy):
   - `USER_ENTRY_TTL_MS: 600000`, `PAD_ARRIVAL_TIMEOUT_MS: 600000`
   - `DOCUMENT_ROUTING.enabled: true` and the `filesystem` strategy `enabled: true`
     with `basePath: "/signed-output"` and
     `pathTemplate: "{company}/{email}/{date:YYYY-MM}/{documentNumber}_{date:YYYY.MM.DD_HH:mm:ss}.pdf"`
   - (optional) the per-company `webhook` strategy for any direct-API customer.
3. **Volume** — confirm `ps-server` still mounts `./signed-output:/signed-output`
   (already in compose). Ensure `./signed-output` exists and is writable.

> ps-server `require()`-caches `config.js`. After editing the bind-mounted file
> you MUST recreate/restart ps-server (step 4) — `up -d` without an image/config
> change is a no-op for it.

---

## 4. Deploy — STAGING first

```bash
docker compose pull ps-server          # fetch :3.27
docker compose up -d ps-server         # recreate only ps-server
docker compose logs --tail=30 ps-server
# expect: "[signedPdfBuffer] index rebuilt from disk { entries: N, basePath: '/signed-output' }"
#         "PadSign Server listening on port 3001"
```

Run the smoke test (§6). If green, promote to prod by repeating §2–§4 on the prod
host inside the maintenance window.

---

## 5. Roll out the Padsign Manager (operator desktops)

The receive-back client lives in the Manager/Listener (`virtual printer` repo, **`v1.2.0`+** — the release that introduced the receive-back polling client). On each operator desktop:
1. Build/distribute the new installer:
   `powershell -ExecutionPolicy Bypass -File scripts/create-setup.ps1` (from `virtual printer`), ship `out/installer/Padsign-Setup.cmd`. Confirm the Manager window title reads `Padsign Manager v1.2.0` (or later) after install.
2. In the Manager Setup tab set: `Signed Output Folder` = `D:\VM\SignedDocs`,
   plus the existing `Company` (e.g. `Acme` or `Acme-Branch`), `Email`, API URL
   (`https://padsign.trustlynx.com/api/registerPDF`) and the `REGISTER_PDF_API_KEY` bearer.
3. Save → installs/updates config at `%LOCALAPPDATA%\Padsign\padsign.json`
   (`ReceiveBackEnabled`, `ReceiveBackPollSeconds`=5, `ReceiveBackTimeoutMinutes`=30 default).
4. Start the listener.

---

## 6. Smoke test (run against the deployed server)

Through nginx the routes are under `/api`. Use the deployment's `REGISTER_PDF_API_KEY`.

```bash
BASE=https://padsign.trustlynx.com
KEY=<REGISTER_PDF_API_KEY>

# auth enforced
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/api/signedPdf/pending?email=a@x.com&company=Acme"          # 401
# empty pending for an unused pair (valid auth)
curl -s -H "Authorization: Bearer $KEY" "$BASE/api/signedPdf/pending?email=nobody@x.com&company=Acme"        # []
# control-char docid rejected
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $KEY" "$BASE/api/signedPdf?docid=%01"     # 400
# idempotent ack of unknown id
curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"docid":"none"}' "$BASE/api/signedPdf/ack"   # {"acknowledged":true,"removed":false}
```

Then a **real round trip** (the manual part — needs a human):
1. Print from the originating line-of-business application (or the Manager test) → register a PDF for a known `email`+`company`.
2. Sign it on the tablet (browser SPA + Keycloak).
3. The Manager polls `pending`, downloads, saves to `D:\VM\SignedDocs\<documentNumber>_<timestamp>.pdf`, and acks.
4. Confirm the local file appears and the server-side `/signed-output` copy + its `.meta.json` sidecar are deleted within seconds of the ack (`docker compose logs ps-server | grep "acknowledged + removed"`).

---

## 7. Rollback (fast)

```bash
# revert compose image tag to the previous good one
#   ps-server.image: mihailsgordijenko/ps-server:3.27  ->  :3.26
docker compose up -d ps-server
```
To also disable the new behaviour without rolling the image, set
`DOCUMENT_ROUTING.enabled: false` (and revert `USER_ENTRY_TTL_MS` if desired) in
`config/config.js`, then `docker compose restart ps-server`. The buffer is
ack-driven with no janitor, so disabling routing simply stops new entries; any
already-buffered files remain on disk under `/signed-output` until acked or
removed manually.

---

## 8. Notes / gotchas

- **Image must be rebuilt** for the endpoints — they are baked into ps-server, not
  bind-mounted. A config-only change cannot add them.
- **Lowering `USER_ENTRY_TTL_MS` to 10 min** shortens the idle eviction window for
  *all* sessions on that deployment, not just the receive-back desktops — confirm that's acceptable for
  the target before promoting.
- **No email/alerting**: undelivered/failed cases are log-only by design. Watch
  `docker compose logs ps-server | grep -E "signedPdfBuffer|documentRouting"`.
- **Buffer growth**: with no time-expiry, a desktop that never acks leaves files
  accumulating under `/signed-output`. Monitor disk; housekeeping there is manual.
