# 5.2 Upgrade to the current release (authenticated PDF download + signed-PDF receive-back)

Use this when an instance is **already deployed on an older tag** and you want to
move it to the current release: the tags this checkout's `docker-compose.yml`
pins, described in [1. Release Snapshot](01-release-snapshot.md)
(`ps-server:3.30` + `ps-client:8.40` at the time of writing). The two features
this page walks through arrived in `ps-server:3.27` / `ps-client:8.38` and are
retained by every later tag.

What you get:
- **`ps-server:3.27`** — adds the signed-PDF **receive-back** buffer + endpoints
  (`GET /api/signedPdf/pending`, `GET /api/signedPdf`, `POST /api/signedPdf/ack`)
  that the Padsign Manager polls to pull a signed PDF back onto the originating
  desktop. Retains the `STAMP_MODE` local e-sealing dispatch from `:3.26`.
- **`ps-client:8.38`** — the pad browser downloads archive PDFs with the user's
  Keycloak Bearer token instead of an anonymous URL load, so
  `GET /archive/api/document/{docid}/download` can be closed behind
  authentication at nginx (see
  [22. Security and Route Protection](22-security-and-route-protection.md)).
  No operator action required — the image is drop-in compatible whether or not
  the route is protected. Retains the automatic dark-mode support from `:8.37`.

The receive-back endpoints are **always present** in `:3.27`, but only return
documents when document routing is switched on (next step). Upgrading the image
alone is safe and changes no behaviour until you enable routing.

> **Already using receive-back? Read this before moving to `ps-server:3.30`.**
> From `3.30`, `GET /api/signedPdf?docid=` and `POST /api/signedPdf/ack` only
> act on a document the caller can prove it owns (psapp-saas#18). Under the
> legacy shared `REGISTER_PDF_API_KEY` that means sending the matching `email`
> + `company`, and the current Padsign Manager (v1.2.0) sends only `docid` on
> those two calls. So on a deployment where routing and the Manager are
> already live, delivery stops after the upgrade: both calls return `404`,
> the documents stay pending on the server, nothing is lost. Before
> upgrading, give each receive-back company its own key in
> `REGISTER_PDF_API_KEYS` (config only, no Manager change; psapp's
> `docs/document-routing-spec.md`, *Migrating to per-company keys*; capability
> `per-company-api-keys`), or roll out a Manager build that sends `email` +
> `company`. `3.30` also keeps the filesystem archive after ack (it no longer
> deletes `signed-output/{company}/{email}/...` files), so plan for that
> directory to grow. See [1. Release Snapshot](01-release-snapshot.md).

---

## Step 1 — bump the images

```bash
cd /path/to/ps-app-cloud-deployment
./installation-scripts/upgrade.sh --server-tag 3.30 --client-tag 8.40
```

This backs up `docker-compose.yml` + `config/config.js`, rewrites the image tags,
ensures the `signed-output` volume mount + directory exist, appends a
`DOCUMENT_ROUTING` block **disabled by default** if one is missing (it never
overwrites existing settings), pulls the new images, restarts only ps-server /
ps-client, and prints a rollback command. Full breakdown:
[5.1 What upgrade does](05-01-what-upgrade-does-step-by-step.md).

> If you also run `--enable-local-eseal`, the current tag clears that flag's
> pre-flight guard automatically (the minimum it checks is the `local-eseal`
> entry in `release/capabilities.json`).

## Step 2 — enable receive-back (only if you want documents delivered back)

Edit the bind-mounted `config/config.js` and turn on routing + the filesystem
strategy:

```js
DOCUMENT_ROUTING: {
  enabled: true,
  skipDemo: true,                 // demo-mode documents are never buffered
  strategies: [
    {
      type: "filesystem",
      enabled: true,
      basePath: "/signed-output", // already bind-mounted to ps-server
      pathTemplate: "{company}/{email}/{date:YYYY-MM}/{documentNumber}_{date:YYYY.MM.DD_HH:mm:ss}.pdf",
      createDirectories: true
    }
  ]
}
```

ps-server `require()`-caches `config.js`, so the edit only takes effect after a
restart:

```bash
docker compose restart ps-server
docker compose logs --tail=30 ps-server
# expect: "[signedPdfBuffer] index rebuilt from disk { entries: N, basePath: '/signed-output' }"
#         "PadSign Server listening on port 3001"
```

For the full per-company / dual-mode routing options and the optional direct-API
webhook channel, see the
[35. Receive-back deployment runbook](35-receive-back-deployment-runbook.md) and
[18.4 Server: config/config.js](18-04-server-configconfigjs.md).

## Step 3 — roll out the Padsign Manager (`v1.2.0`+)

The receive-back client lives in the Manager/Listener (`virtual printer` repo,
**v1.2.0+**). On each desktop:

1. Build/ship the installer: `powershell -ExecutionPolicy Bypass -File scripts/create-setup.ps1`
   (from `virtual printer`), distribute `out/installer/Padsign-Setup.cmd`. After
   install the Manager window title should read `Padsign Manager v1.2.0` (or later).
2. In the Setup tab set the `Signed Output Folder` (default `D:\VM\SignedDocs`),
   plus the existing `Company`, `Email`, API URL, and `REGISTER_PDF_API_KEY`.
3. Save and start the listener.

Full desktop steps + verification: [35. Receive-back deployment runbook](35-receive-back-deployment-runbook.md).

## Verify

```bash
docker ps --format '  {{.Names}}: {{.Image}} ({{.Status}})' | grep -E 'ps-server|ps-client'
#   expect the tags you passed above (ps-server:3.30 and ps-client:8.40)
```

Then sign a (non-demo) document for a known `email`+`company`; the Manager should
poll `pending`, download to the `Signed Output Folder`, and ack (the server then
deletes its buffered copy).

## Rollback

**Use `installation-scripts/rollback.sh`** (see [40.4 Rollback](40-04-rollback.md)) —
every `upgrade.sh` run writes a timestamped pre-upgrade snapshot first, and
`rollback.sh` restores from it, pulls, restarts, and waits for the restored
services to report healthy:

```bash
./installation-scripts/rollback.sh --yes
```

This restores the exact `tag@sha256:digest` that was pinned immediately
before the upgrade — not just the tag — taken from the snapshot's own copy of
`docker-compose.yml` (falling back to the registry digest its manifest
recorded for the running container), rather than re-deriving it.

If no snapshot exists (a deployment upgraded before `rollback.sh` existed, or
`.rollback-snapshots/` was pruned/lost), reconstruct manually: look up the
digest that was approved for the tag you're going back to — either
`git log -p -- release/approved-digests.json` in this repo, or the matching
`CHANGELOG.md` entry — and pin it explicitly:

```bash
./installation-scripts/upgrade.sh --server-tag 3.27 --client-tag 8.37 --allow-unapproved
# upgrade.sh refuses any tag this checkout's release/approved-digests.json
# does not approve, and an older release's tag is no longer the approved one,
# hence --allow-unapproved (recorded in deployment-evidence.json). The tag is
# left unpinned - pin the digest that was approved for :3.27 / :8.37 (from
# the git history above), confirming it with:
#   docker buildx imagetools inspect mihailsgordijenko/ps-server:3.27
# Edit docker-compose.yml + release/approved-digests.json together, then:
./installation-scripts/validate-config.sh
```

> Note: if you protected the download route per
> [22. Security and Route Protection](22-security-and-route-protection.md),
> rolling the client back below the `closable-download-route` minimum in
> `release/capabilities.json` requires re-opening that route first, otherwise
> pads cannot render PDFs.

To keep the current `ps-server` tag but stop delivering documents back, set
`DOCUMENT_ROUTING.enabled: false` and `docker compose restart ps-server`.
