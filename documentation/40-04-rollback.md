# 40.4 Rollback

`upgrade.sh` previously kept a single, overwritten-every-run `.bak` copy of `docker-compose.yml` and `config/config.js`, and printed a manual `cp ...bak ...` command at the end — nothing executed it, and re-running `upgrade.sh` destroyed the only backup generation that existed. There was no automated rollback.

## What changed

`upgrade.sh`'s Step 1 now writes a **timestamped, non-overwriting** snapshot (`installation-scripts/lib/rollback-snapshot.sh`, new) to `.rollback-snapshots/<UTC-timestamp>/` at the repo root **before** touching anything: a copy of `docker-compose.yml` and `config/config.js` — the exact two files `upgrade.sh` mutates, nothing from `configure-host.sh`'s territory (`nginx/nginx.conf`, `config/constants.json`) — plus a `manifest.json` recording the `ps-server`/`ps-client` image that is **running** (tag and registry digest, see [below](#rollback-restores-what-was-running-not-what-docker-composeyml-pinned)), what `docker-compose.yml` pinned for each, and the deployment repo's git revision. A `latest` pointer file tracks the newest snapshot; the last 5 are kept, older ones pruned. This directory is gitignored — it holds a copy of `config.js`, which carries this deployment's real secrets once `configure-host.sh` has customized it. For the same reason `.rollback-snapshots/` is mode `700` and every file in it `600`, whatever the umask; a snapshot directory an older `upgrade.sh` left at `755`/`644` is tightened on the next run. `config/config.js` itself keeps its own mode: `rollback.sh` copies onto the existing file, so ps-server can still read it.

`installation-scripts/rollback.sh` (new):

```bash
./installation-scripts/rollback.sh --yes            # restore the latest pre-upgrade snapshot
./installation-scripts/rollback.sh --to 20260922T193336Z --yes
```

It restores **only** `docker-compose.yml`'s `ps-server`/`ps-client` image lines (a targeted `sed`, the same mechanism `upgrade.sh` uses to bump them, run in reverse — not a wholesale file overwrite, so an unrelated `docker-compose.yml` edit made after the snapshot survives) and `config/config.js` (restored verbatim from the snapshot), then pulls and restarts the affected services and waits for them to report healthy using the health checks from [40.1](40-01-health-checks-and-startup-order.md). It then checks that each restored container runs exactly the digest the snapshot recorded, and exits `1` if one does not. It never touches `signed-output/`, `docs/`, `nginx/nginx.conf`, `config/constants.json` or the git checkout. It writes deployment evidence at the end, same as `upgrade.sh`. Since [psapp-saas#11](https://github.com/mihailsgo/psapp-saas/issues/11) (image digest pinning), it restores the exact `tag@sha256:digest` of the image that was running when the snapshot was taken, not just the tag — see *Known limitation* below.

Run it as the user that ran `upgrade.sh`, or as root. A user who cannot read the mode-`700` `.rollback-snapshots/` gets exit `2` with the directory's owner named, instead of "no snapshot found".

## Rollback restores what was running, not what docker-compose.yml pinned

The documented upgrade path ([4.4](04-04-existing-deployment-upgrade-an-already-deployed-instance.md) Phase 1, then [5](05-upgrading-an-existing-deployment.md)) is `git pull` first, then `upgrade.sh`. The pull alone already moves `docker-compose.yml` to the new release's pins, while the containers keep running the old release until `upgrade.sh` recreates them. Up to v1.0.40, the snapshot read its tags from that already-pulled `docker-compose.yml`, so on the documented path it recorded the release being upgraded **to**. Found on a real Ubuntu 24.04 host (Docker 28.5.1, Compose v2.40.0) bootstrapped at release commit `7d8f643` (`ps-server:3.28` / `ps-client:8.39`), after `git stash; git pull; git stash pop`:

- `upgrade.sh --plan-only` and the real run printed `ps-server: 3.30 → 3.30`.
- The manifest said `image_tags: {ps-server: "3.30", ps-client: "8.40"}` next to the correct running digests `98bb0577…` (3.28) and `8722d407…` (8.39). The snapshot's copy of `docker-compose.yml` pinned 3.30 / 8.40.
- `rollback.sh --yes` preferred that copy's pin, printed `ps-server -> 3.30@sha256:cdcabd7d…` and `Rollback complete`, exited `0`, and `validate-config.sh` passed. The stack was still on 3.30 / 8.40.

Earlier rehearsals missed it because they changed tags with `upgrade.sh` inside one checkout, without a `git pull` first. Now:

- **The snapshot records the running image.** For each of `ps-server` / `ps-client` the manifest (`schema_version: 2`) records the registry digest the container runs (`digest_running`, `lib/digests.sh`) and its tag: the tag in the container's own image reference (what compose created it from), else the image's `org.opencontainers.image.version` label, else its only local tag. `image_sources` says which. What `docker-compose.yml` pinned is kept separately under `compose_pins`. A service that is not running falls back to the pin, and the manifest says so.
- **`upgrade.sh` says when the two differ**, in the plan and in the run:

  ```
  ps-server: 3.28 → 3.30   (approved; pinned to its approved digest)
    NOTE: docker-compose.yml pins ps-server 3.30 but 3.28 is running - the rollback snapshot records 3.28@sha256:98bb0577..., the running image
  ```

  The "from" side of every `old → new` line is the running tag. The machine plan's `server_tag_from` / `client_tag_from` are the running tags too, and new `server_tag_pinned` / `client_tag_pinned` fields carry the pins, so the deployment wizard's preview no longer shows 3.30 → 3.30 as "no change".
- **`rollback.sh` restores the recorded running image and verifies it.** After the health wait it reads what each restored container runs and fails with `ROLLBACK FAILED: ps-server: running <digest>, but the snapshot recorded <digest> (<tag>)` and exit `1` if it is not the recorded digest. It never prints `Rollback complete` for a stack that is still on the release being rolled back from.
- **Snapshots written by an older `upgrade.sh` (`schema_version: 1`) still work.** Their `image_digests` were always read from the running container, so when they disagree with the snapshot's `docker-compose.yml` copy, `rollback.sh` trusts the digest, prints a `WARNING` naming both, and looks the digest's tag up: `release/approved-digests.json`, `release/unsigned-legacy-images.json`, earlier committed revisions of `release/approved-digests.json`, the snapshot's compose copy, then the local image's OCI version label. The oldest snapshots recorded the local image ID instead of the registry digest (see *Known limitation*); an ID that is still on the host is mapped to its registry digest, and one that is not makes `rollback.sh` restore the compose copy's pin and then verify by image ID, failing loudly if that is the wrong image. A digest that differs from the pin and whose tag nothing names is refused before anything changes (exit `1`, see *Restoring by hand*).

### validate-config.sh after a rollback

`rollback.sh` does not touch the git checkout, so `release/approved-digests.json` and the release snapshot doc still name the release rolled back from. Restored pins that no approval covers would be an unapproved digest (FAIL). After a verified rollback, `rollback.sh` writes `.rollback-applied.json` at the repo root (gitignored, image references only, no secrets). `validate-config.sh` reports a `ps-server` / `ps-client` pin as a **WARN** instead of a FAIL only when both hold:

1. `.rollback-applied.json` names exactly that tag and digest, and
2. an earlier **committed** revision of `release/approved-digests.json` approved that digest for that tag (`git log`; a `.zip`-unpacked checkout has no history and still FAILs).

For the rollback from 3.30 / 8.40 to `3.28@98bb0577…` / `8.39@8722d407…` that means (from the rehearsal below):

```
  WARN Release snapshot ps-server (3.30) != docker-compose (3.28): rollback.sh restored 3.28 - see Image digest pinning below
  WARN ps-server: rolled back to mihailsgordijenko/ps-server:3.28 by rollback.sh (snapshot 20260925T..., ...) - approved by release commit ..., not by this checkout's release/approved-digests.json (which approves 3.30). Roll forward with upgrade.sh --server-tag 3.30 once the cause of the rollback is fixed
  WARN ps-server (mihailsgordijenko/ps-server:3.28): released before image signing existed; exempt by exact digest in release/unsigned-legacy-images.json
```

A rollback to a pin no committed release ever approved (an `--allow-unapproved` hotfix) still FAILs, with the reason. `check-digest-drift.sh` prints the same finding as a `WARNING`, not as drift. The next successful `upgrade.sh` removes the marker entries whose pins it replaced.

### Restoring by hand

When `rollback.sh` refuses (a recorded digest no release file, git history or local image can name) or there is no snapshot, pin the image by hand. Take the digest from the snapshot's `manifest.json` (`sudo cat .rollback-snapshots/<name>/manifest.json`, `image_digests`) or from `deployment-evidence.json.previous`, find its tag with `docker buildx imagetools inspect mihailsgordijenko/ps-server@<digest>` (the `org.opencontainers.image.version` label) or `git log -p -- release/approved-digests.json`, write `mihailsgordijenko/ps-server:<tag>@<digest>` into `docker-compose.yml`, and run `docker compose up -d ps-server ps-client`.

**Signatures.** `rollback.sh` does not verify image signatures. It only ever restores a pin that was deployed before, and it is the emergency path, so it should not be the step that discovers a missing cosign. `validate-config.sh` still checks the restored pin afterwards: the pre-signing releases `ps-server:3.28` / `ps-client:8.39` are exempt by exact digest ([40.2](40-02-post-deploy-validation.md#image-signatures-cosign)), so rolling back to them from the first signed release is a signature WARN, not a FAIL. Whether the restored digest passes the approved-digest gate is a separate question, answered in [validate-config.sh after a rollback](#validate-configsh-after-a-rollback).

## Failed deployments now fail

`upgrade.sh` used to finish with `Upgrade complete!` and exit `0` for any image that pulled: `docker compose up -d` returns once the container is created, and step 6 only printed a warning if a log line was missing. A broken image that pulls fine was reported as a successful upgrade.

`upgrade.sh`, `rollback.sh` and `bootstrap.sh` now call `wait_for_healthy` (`installation-scripts/lib/health-wait.sh`) on the services they (re)started (plus `nginx`, which they restart). It returns as soon as every one is healthy, and fails fast when one reports `unhealthy`, has exited, or restarts twice while waiting (crash loop); otherwise it times out (`--health-timeout`, default 300s; 600s for `bootstrap.sh`, whose first Keycloak boot is slow). On failure it prints the service, its last health-probe output and its last 15 log lines.

A failed `upgrade.sh` then writes deployment evidence, prints `docker compose ps`, and prints the exact rollback command for the snapshot it took in step 1:

```
UPGRADE FAILED: services did not become healthy
Roll back with:
  ./installation-scripts/rollback.sh --to 20260923T105025Z --yes
```

With `--rollback-on-failure`, it runs that command itself. The upgrade still exits `1` either way, so a pipeline sees that the upgrade failed even when the rollback succeeded. A failed image pull or `docker compose up` goes through the same path.

`rollback.sh` now exits `1` (`ROLLBACK APPLIED BUT NOT HEALTHY`) when the restored services do not become healthy, instead of warning after 60 seconds and exiting `0`.

> **Re-running these rehearsals.** `upgrade.sh` now refuses a tag `release/approved-digests.json` does not approve (psapp-saas#11), and the broken-release tags below (`3.97`, `8.97`, `99.99.99`) are never approved. Add `--allow-unapproved` to reproduce them; the run then also records the override in `deployment-evidence.json` as `"unapproved_override"`. `rollback.sh` has no such gate: it restores the pin the snapshot recorded.

### Rehearsed against a live, isolated copy of this stack (psapp-saas#12)

Run on 2026-09-23 against this repo's `docker-compose.yml` under a separate compose project with renamed containers and remapped ports. The "broken release" was a local-only image tagged `ps-server:3.97` / `ps-client:8.97` built `FROM` the real 3.28 / 8.39 image with a command that exits `1`, so it pulls (with `pull_policy: never` in the test override) and starts, then crash-loops - the case the old script reported as success.

| Rehearsal | Result |
|---|---|
| `upgrade.sh --server-tag 3.97 --rollback-on-failure` | Detected after ~24s (`FAILED: ps-server is unhealthy` + the container's own `simulated broken release` log lines). Auto-rollback restored `ps-server:3.28@sha256:98bb0577…` - the exact digest from the snapshot manifest, the first live run of the digest-exact restore - and all 7 services were healthy. Upgrade exit `1`, 83s total. |
| `upgrade.sh --client-tag 8.97` (no auto-rollback) | Detected after ~20s, exit `1`, printed `rollback.sh --to 20260923T105025Z --yes`. Running it restored `ps-client:8.39@sha256:8722d407…`, services healthy, exit `0`. Running it again was a no-op, exit `0`. |
| `rollback.sh` with a fault that survives the rollback (test override making ps-client's healthcheck always fail) | `ROLLBACK APPLIED BUT NOT HEALTHY`, exit `1`. |
| Document storage | A marker file in `signed-output/` had the same SHA-256 before and after all of the above. `config/config.js` came back byte-identical. |

## Tested, for real, against the local stack

Both required failure scenarios were actually run, not just described — see the PR description for the full command transcripts. In outline:

1. **Failed client deployment**: `upgrade.sh --client-tag 99.99.99` (a tag that doesn't exist) → snapshot written, `docker-compose.yml` mutated, `docker compose pull` fails as expected, deployment left in a broken (bad-tag) state. `rollback.sh --yes` → `ps-client` tag restored to `8.39`, container recreated, all 8 services report `healthy` again.
2. **Failed server deployment**: same shape, `upgrade.sh --server-tag 9.99.99` → `rollback.sh --yes` → `ps-server` restored to `3.28`, stack healthy again.
3. **Document storage untouched**: a marker file written into `signed-output/` before either failure scenario was still present, byte-identical, after both rollbacks.
4. **Idempotency**: running `rollback.sh --yes` a second time immediately after a successful rollback made no further changes (tag `sed` matched nothing to change, `config.js` copy was byte-identical) and still exited `0`.

## Known limitation, stated plainly

**Resolved as of psapp-saas#11.** This section originally said rollback restored by image tag only, because `docker-compose.yml` didn't pin by digest yet, and that the snapshot manifest recorded the running digest without `rollback.sh` acting on it. `docker-compose.yml` now pins every image by digest, and `rollback.sh` writes back the exact `tag@sha256:digest` of the image that was running immediately before the upgrade being undone — not just the tag. Up to v1.0.40 it preferred the digest the snapshot's own copy of `docker-compose.yml` pinned, which after a `git pull` ahead of the upgrade was the new release's (see [above](#rollback-restores-what-was-running-not-what-docker-composeyml-pinned)); it now uses the manifest's running digest, and the compose copy only for a schema-1 snapshot whose digest cannot be identified, verified afterwards. A snapshot with no digest at all falls back to restoring the bare tag and prints a reminder that the result needs to be re-pinned by hand (`documentation/39-release-procedure.md`).

The manifest's digest is the **registry** digest of the image the pre-upgrade container was running (`digest_running` in `installation-scripts/lib/digests.sh`: the digest in the container's own image reference, else the image's `RepoDigests`), the same kind of value `docker-compose.yml` pins and `release/approved-digests.json` approves. Snapshots written before that helper existed recorded `docker inspect --format '{{.Image}}'` instead, which is the local image ID: equal to the pulled digest under Docker's containerd image store (where this was first tested), but the image *config* digest under the classic overlay2 store, which `docker pull` rejects (`unexpected media type application/octet-stream`). `rollback.sh` maps such an ID to the image's registry digest while the image is still on the host. `deployment-evidence.json`'s `image_digests` switched to the same registry digest, so it can be compared with `release/approved-digests.json` directly.

This fix was verified in isolation — the exact `sed` substitution was run against a copy of the real digest-pinned `docker-compose.yml`, for both the digest-available and no-digest-recorded cases, and produced the expected `tag@digest` and bare-tag output respectively. It was later exercised live by the psapp-saas#12 rehearsal above (restore of `ps-server:3.28@sha256:98bb0577…` and `ps-client:8.39@sha256:8722d407…`).

A second, narrower limitation remains: `rollback.sh` only knows about the one snapshot it's restoring. If `configure-host.sh` or `toggle-features.sh` changed `config/config.js` *after* that snapshot was taken, restoring it will revert those changes too — there's no drift detection between "what this snapshot captured" and "what's changed since." This is stated in the script's own `--help` output, not just here.
