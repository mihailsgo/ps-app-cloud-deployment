# 10.4 Existing deployment

This page covers switching on local e-sealing, with the demo keystore, on a
deployment that is already running in external mode. The existing setup keeps
working until the upgrade script switches `STAMP_MODE` to `"local"`, and you
can switch back at any time with
[10.5 Switching modes](10-05-switching-modes.md).

Already on a current release? `toggle-features.sh --enable-local-eseal`
([10.5](10-05-switching-modes.md)) does the same provisioning without an
upgrade. Use this page when you are also bringing the checkout and images up
to date.

## Step 1: Check the ps-server image

The ps-server tag must be at least the `local-eseal` minimum in
`release/capabilities.json`:

```bash
cd /opt/padsign
python3 -m json.tool release/capabilities.json | grep -A3 '"local-eseal"'
grep 'mihailsgordijenko/ps-server' docker-compose.yml
```

If the tag is older, `upgrade.sh --enable-local-eseal` stops with
`ERROR: --enable-local-eseal requires mihailsgordijenko/ps-server:<min> or newer`
and exits 2. It changes nothing when it stops. In that case, pass the current
release's ps-server tag in the same command (Step 4). The tag is in
[14.3 Release snapshot](14-03-release-snapshot.md). The ps-client tag does not
matter for local e-sealing.

## Step 2: Update the checkout

Update the repository in `/opt/padsign` as described in
[9.5 Upgrading](09-05-upgrading.md): stash this host's edits, pull, and restore
them. Then continue straight to Step 3. Do not run `docker compose up`,
`toggle-features.sh` or any other script in between.

Check that the pulled version includes local e-sealing:

```bash
./installation-scripts/upgrade.sh --help | grep -- --enable-local-eseal
ls installation-scripts/assets/dmss-digital-stamping-service/seal/seal.p12
grep -A2 '"LocalDemo"' dmss-container-and-signature-services/documentsigningprofiles.json
```

All three commands must print something. If any prints nothing, the checkout
is not a release with local e-sealing.

## Step 3: Preview the changes

```bash
./installation-scripts/upgrade.sh --enable-local-eseal --plan-only
```

This lists each configuration change the upgrade would make, and writes
nothing. See [9.7 Previewing upgrade changes](09-07-previewing-upgrade-changes.md).

## Step 4: Run the upgrade

```bash
./installation-scripts/upgrade.sh --enable-local-eseal
# or, if Step 1 showed an older ps-server:
./installation-scripts/upgrade.sh --server-tag <current release tag> --enable-local-eseal
```

In the wizard, open the Dashboard's upgrade panel, tick **Enable local
e-sealing**, then choose **Preview changes**.

The script runs its usual steps ([9.6 What upgrade does](09-06-what-upgrade-does.md))
and adds `Step 4b/6: Enabling local e-sealing...`. It makes the same changes as
the fresh-install flag ([10.3](10-03-fresh-install.md#what-the-flag-changes)).
On a current checkout, the stamping files and the compose service block are
already part of the release, so expect this output:

```
Step 4b/6: Enabling local e-sealing...
  Stamping artifacts already present (preserved)
  Compose service block already present
  Patched dmss-container-and-signature-services/application.yml baseUrl
  Pinned Spring Security creds on container-signature
  Inserted STAMP_MODE=local + STAMP_LOCAL in config.js
  Wrote COMPOSE_PROFILES=local-eseal to .env
```

If you run it again, the remaining lines also say `already …`. The step is
safe to repeat.

In `Step 5/6` the script pulls and starts `dmss-digital-stamping-service`,
using the image `docker-compose.yml` pins (`trustlynx/digital-stamping-service:24.0.3.1`
in this release, see [14.3](14-03-release-snapshot.md)). It then runs
`docker compose up -d` for `dmss-container-and-signature-services` and
`ps-server`. That recreates a container only when its definition in
`docker-compose.yml` changed. `Step 6/6` waits for them to report healthy.
The default limit is 480 seconds (`--health-timeout`).

ps-server reads `config/config.js` only when it starts. If ps-server was not
recreated in `Step 5/6` (for example because no ps-server tag was given, so
its compose definition stayed the same), it still runs with the old
`config.js` and keeps using external e-sealing. Check its start time, and
restart it if it did not start during the upgrade:

```bash
docker compose ps ps-server          # CREATED / STATUS show when it last started
docker compose restart ps-server
```

A restart is harmless when ps-server was already recreated. The same applies
to `dmss-container-and-signature-services`, which reads the patched
`baseUrl` in its `application.yml` only when it starts: if it did not start
during the upgrade, run `docker compose restart dmss-container-and-signature-services`.

**Downtime.** While container-signature and ps-server restart, signing and
sealing are unavailable. For container-signature this is roughly a minute,
because its JVM has to start again. nginx, Keycloak, the archive services and
ps-client keep running. If signing must not be interrupted, schedule a
maintenance window.

## Step 5: Make the portal request the seal

If `RUN_STAMPING_REQUEST` is not already `true` in `config/constants.json`,
set it. Then run `docker compose restart ps-client` and reload the portal.

## Step 6: Verify the demo seal

Run the checks in [10.9 Verifying it works](10-09-verifying-it-works.md). The
quickest proof that the whole chain works is to seal a PDF directly through
container-signature. Port 84 is bound to `127.0.0.1`, so run this on the
deployment host itself, or through `ssh -L 84:localhost:84 <host>`:

```bash
curl -sS -u user:changeit -X POST \
    -F "file=@/path/to/any-small.pdf;type=application/pdf" \
    -o /tmp/demo-sealed.pdf -w "HTTP=%{http_code} bytes=%{size_download}\n" \
    http://localhost:84/api/eseal/document/profile/LocalDemo
grep -aoE '/Type\s*/Sig|/ByteRange\s*\[[^]]+\]' /tmp/demo-sealed.pdf
```

Then sign a document in the portal. Download its sealed version from the
archive, which is bound to `127.0.0.1:86`, and run the same `grep`:

```bash
docker compose logs ps-server | grep -E 'docId|docid' | tail -5   # find the document id
curl -fsS "http://localhost:86/api/document/<docid>/download" -o /tmp/portal-sealed.pdf
```

## If the upgrade fails

| Symptom | Cause | What to do |
|---|---|---|
| `ERROR: --enable-local-eseal requires mihailsgordijenko/ps-server:<min> or newer` | ps-server is older than the minimum | Run the command again with `--server-tag <current release tag>`. Nothing was changed. |
| `UPGRADE FAILED: could not pull images for: …` | Network, registry or disk-space problem while pulling | Fix the cause (check `df -h`), then run the same command again. The steps already done report `already …`. |
| `Conflict. The container name "/dmss-digital-stamping-service" is already in use` | A container left over from an earlier attempt | `docker rm -f dmss-digital-stamping-service`, then run the command again. |
| `dmss-digital-stamping-service` is `Restarting` or `unhealthy` | Keystore missing, wrong password, or wrong alias | `docker compose logs --tail 200 dmss-digital-stamping-service`, then check `dmss-digital-stamping-service/application.yml` against the keystore ([10.6](10-06-production-key-and-certificate.md#step-2-check-the-keystore)). |
| `UPGRADE FAILED: services did not become healthy` | A recreated service did not start | The script prints a `rollback.sh` command. See [9.8 Rollback](09-08-rollback.md). |

To go back to external e-sealing, run
`./installation-scripts/toggle-features.sh --disable-local-eseal`
([10.5](10-05-switching-modes.md)). `rollback.sh` restores the previous
ps-server and ps-client images and `config/config.js` from the snapshot the
upgrade took. It does not restore `.env`. After a rollback, also run
`toggle-features.sh --disable-local-eseal` if the stamping container should
stay off.

## Next: production

The demo keystore gives a seal that is cryptographically valid but not
trusted. Before production:

1. Get a signing certificate and build a keystore from it, then rotate the
   three `changeit` passwords:
   [10.6 Production key and certificate](10-06-production-key-and-certificate.md).
2. Add a production profile and company, and keep `LocalDemo` as a known-good
   fallback: [10.7 Adding a signing profile](10-07-adding-a-signing-profile.md).
3. For `LT` or `LTA`, connect a TSA and OCSP:
   [10.8 TSA and OCSP for LT and LTA](10-08-tsa-and-ocsp-for-lt-and-lta.md).
4. Check the result with an external verifier:
   [10.10 Verifying signatures end-to-end](10-10-verifying-signatures-end-to-end.md).
