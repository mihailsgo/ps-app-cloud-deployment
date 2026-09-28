# 9.8 Rollback

Use `rollback.sh` to undo an `upgrade.sh` run: it puts back the ps-server
and ps-client images that were **running** just before that upgrade (exact
tag and digest) and the `config/config.js` of that moment, restarts them,
and checks that the restored containers run exactly those images.

Every `upgrade.sh` run writes the snapshot this uses in its step 1
([9.6](09-06-what-upgrade-does.md)). A failed upgrade prints the command
for its own snapshot.

## Rolling back

```bash
cd /opt/padsign
./installation-scripts/rollback.sh                          # latest snapshot, asks for confirmation
./installation-scripts/rollback.sh --yes                    # the same, no prompt
./installation-scripts/rollback.sh --to 20260923T105025Z --yes   # a specific snapshot
```

Snapshots are the timestamped directories in `.rollback-snapshots/`
(mode 700). The last five upgrades are kept:

```bash
sudo ls .rollback-snapshots/
```

Run `rollback.sh` as the user that ran `upgrade.sh`, or as root. Another
user cannot read the snapshots and gets exit 2 with the owner named.

| Option | Use |
|---|---|
| `--to latest\|<snapshot>` | Which snapshot to restore (default `latest`, the most recent upgrade) |
| `--yes` | Skip the confirmation prompt. Required without an interactive terminal |
| `--health-timeout N` | Seconds to wait for the restored services to be healthy (default 480) |

`upgrade.sh --rollback-on-failure` runs `rollback.sh --to <its snapshot> --yes`
by itself when the upgrade fails.

## What you see

After the confirmation, four steps:

1. **Restoring image tags in docker-compose.yml**: `ps-server -> <tag>@<digest>`
   and the same for ps-client. Only those two `image:` lines change; any
   other edit to `docker-compose.yml` since the snapshot stays.
2. **Restoring config/config.js from snapshot.**
3. **Pulling and restarting**, then waiting for the restored services and
   nginx to be healthy.
4. **Checking the restored containers run the recorded images**:
   `ps-server: running <tag>@<digest> - the image the snapshot recorded`.

It ends with `Rollback complete.`

## What rollback never touches

- `signed-output/` and `docs/` (your documents);
- `nginx/nginx.conf` and `config/constants.json` (hostname, certificate
  paths, `DEMO_MODE`);
- Keycloak's admin credentials and realm;
- the git checkout. `release/approved-digests.json` still approves the
  release you rolled back from.

`config/config.js` is restored **as a whole** from the snapshot. A change
made to it after that upgrade, for example by `configure-host.sh`,
`toggle-features.sh` or another `upgrade.sh`, is reverted too. Re-apply it
after the rollback.

### Rolling ps-client back across the Syncfusion 34 boundary

`config/constants.json` is not restored, and it holds the PDF viewer's
Syncfusion licence key, which must match the client image (`8.40` and
older: Syncfusion 27; `8.41` and later: Syncfusion 34). A rollback from
`8.41` or later to `8.40` or older leaves the new key in place, and the old
viewer shows a licence banner over the document. Put the old key back by
hand. The key the release replaced is in the repository's history:

```bash
git log -p -S PDF_RENDER_SYNCFUSION_SECRET_KEY -- config/constants.json | grep '^-.*SYNCFUSION'
# the first line is the key 8.40 and older use; edit it into
# config/constants.json, then:
docker compose restart ps-client
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Rolled back (or already in that state); the restored services are healthy and run the recorded digests |
| `1` | `ROLLBACK APPLIED BUT NOT HEALTHY` (restored, but a service did not become healthy), `ROLLBACK FAILED` (a restored container runs another image), or refused because a recorded image could not be identified (nothing changed) |
| `2` | Argument error, or no snapshot found or readable |

Running it twice against the same snapshot is safe: the second run changes
nothing and exits `0`.

## validate-config.sh after a rollback

After a verified rollback, `rollback.sh` writes `.rollback-applied.json`
(git-ignored, image references only). `validate-config.sh` then reports the
restored ps-server / ps-client pins as a **WARN**, not a FAIL, when that file
names exactly that tag and digest and an earlier committed revision of
`release/approved-digests.json` approved it:

```
  WARN ps-server: rolled back to mihailsgordijenko/ps-server:<tag> by rollback.sh (snapshot <name>, <time>) - approved by release commit <commit>, not by this checkout's release/approved-digests.json (which approves <new tag>). Roll forward with upgrade.sh --server-tag <new tag> once the cause of the rollback is fixed
```

A pin no committed release ever approved (for example an
`--allow-unapproved` hotfix) still FAILs. A checkout unpacked from an
archive has no git history, so its restored pins also FAIL.

## Rolling forward again

Once the cause is fixed, run the upgrade again
([9.5, Step 3](09-05-upgrading.md#step-3-run-the-upgrade)). A successful
upgrade removes the rollback marker entries it replaced, and
`validate-config.sh` reports the pins as approved again.

## Restoring by hand

When there is no snapshot, or `rollback.sh` refuses because it cannot
identify a recorded image:

1. Find the digest that ran before: in the snapshot's manifest
   (`sudo cat .rollback-snapshots/<name>/manifest.json`, `image_digests`) or
   in `deployment-evidence.json.previous`.
2. Find its tag: `git log -p -- release/approved-digests.json`, or pull it
   and read its version label:

   ```bash
   docker pull mihailsgordijenko/ps-server@<digest>
   docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
     mihailsgordijenko/ps-server@<digest>
   ```

3. Write `mihailsgordijenko/ps-server:<tag>@<digest>` (and the same for
   ps-client) into `docker-compose.yml`, restore `config/config.js` from the
   snapshot or `config/config.js.bak` if needed, and start them:

   ```bash
   docker compose up -d ps-server ps-client
   ./installation-scripts/validate-config.sh --host padsign.example.com
   ```

If you closed the archive download route ([6.1 Route protection](06-01-route-protection.md)),
rolling ps-client back below the `closable-download-route` minimum in
`release/capabilities.json` needs that route opened again first, or the
tablets cannot display PDFs.

## Customized hosts

On an overlay-managed host, do not use `rollback.sh`: the previous release
directory with the previous overlay is the rollback
([9.11](09-11-start-at-boot-backups-and-customized-hosts.md#customized-hosts-overlay)).
