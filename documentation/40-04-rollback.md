# 40.4 Rollback

`upgrade.sh` previously kept a single, overwritten-every-run `.bak` copy of `docker-compose.yml` and `config/config.js`, and printed a manual `cp ...bak ...` command at the end — nothing executed it, and re-running `upgrade.sh` destroyed the only backup generation that existed. There was no automated rollback.

## What changed

`upgrade.sh`'s Step 1 now writes a **timestamped, non-overwriting** snapshot (`installation-scripts/lib/rollback-snapshot.sh`, new) to `.rollback-snapshots/<UTC-timestamp>/` at the repo root **before** touching anything: a copy of `docker-compose.yml` and `config/config.js` — the exact two files `upgrade.sh` mutates, nothing from `configure-host.sh`'s territory (`nginx/nginx.conf`, `config/constants.json`) — plus a `manifest.json` recording the prior `ps-server`/`ps-client` tags, their resolved image digests, and the deployment repo's git revision. A `latest` pointer file tracks the newest snapshot; the last 5 are kept, older ones pruned. This directory is gitignored — it holds a copy of `config.js`, which carries this deployment's real secrets once `configure-host.sh` has customized it.

`installation-scripts/rollback.sh` (new):

```bash
./installation-scripts/rollback.sh --yes            # restore the latest pre-upgrade snapshot
./installation-scripts/rollback.sh --to 20260922T193336Z --yes
```

It restores **only** `docker-compose.yml`'s `ps-server`/`ps-client` image lines (a targeted `sed`, the same mechanism `upgrade.sh` uses to bump them, run in reverse — not a wholesale file overwrite, so an unrelated `docker-compose.yml` edit made after the snapshot survives) and `config/config.js` (restored verbatim from the snapshot), then pulls and restarts the affected services and waits for them to report healthy using the health checks from [40.1](40-01-health-checks-and-startup-order.md). It never touches `signed-output/`, `docs/`, `nginx/nginx.conf`, or `config/constants.json`. It writes deployment evidence at the end, same as `upgrade.sh`. Since [psapp-saas#11](https://github.com/mihailsgo/psapp-saas/issues/11) (image digest pinning), it restores the exact `tag@sha256:digest` the snapshot's manifest recorded, not just the tag — see *Known limitation* below.

**Signatures.** `rollback.sh` does not verify image signatures. It only ever restores a pin that was deployed before, and it is the emergency path, so it should not be the step that discovers a missing cosign. `validate-config.sh` still checks the restored pin afterwards: the pre-signing releases `ps-server:3.28` / `ps-client:8.39` are exempt by exact digest ([40.2](40-02-post-deploy-validation.md#image-signatures-cosign)), so rolling back to them from the first signed release does not fail validation.

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

**Resolved as of psapp-saas#11.** This section originally said rollback restored by image tag only, because `docker-compose.yml` didn't pin by digest yet, and that the snapshot manifest recorded the running digest without `rollback.sh` acting on it. `docker-compose.yml` now pins every image by digest, and `rollback.sh` writes back the exact `tag@sha256:digest` that was pinned immediately before the upgrade being undone — not just the tag. It takes the digest from the snapshot's own copy of `docker-compose.yml` when that copy pins the same tag (the reviewed, approved pin that was deployed), and otherwise from the snapshot's `manifest.json`. A snapshot with neither has no digest; `rollback.sh` falls back to restoring the bare tag in that case and prints a reminder that the result needs to be re-pinned by hand (`documentation/39-release-procedure.md`).

The manifest's digest is the **registry** digest of the image the pre-upgrade container was running (`digest_running` in `installation-scripts/lib/digests.sh`, read from the image's `RepoDigests`), the same kind of value `docker-compose.yml` pins and `release/approved-digests.json` approves. Snapshots written before that helper existed recorded `docker inspect --format '{{.Image}}'` instead, which is the local image ID: equal to the pulled digest under Docker's containerd image store (where this was first tested), but the image *config* digest under the classic overlay2 store, which `docker pull` rejects (`unexpected media type application/octet-stream`). Preferring the snapshot's compose pin is what keeps those older snapshots restorable. `deployment-evidence.json`'s `image_digests` switched to the same registry digest, so it can be compared with `release/approved-digests.json` directly.

This fix was verified in isolation — the exact `sed` substitution was run against a copy of the real digest-pinned `docker-compose.yml`, for both the digest-available and no-digest-recorded cases, and produced the expected `tag@digest` and bare-tag output respectively. It was later exercised live by the psapp-saas#12 rehearsal above (restore of `ps-server:3.28@sha256:98bb0577…` and `ps-client:8.39@sha256:8722d407…`).

A second, narrower limitation remains: `rollback.sh` only knows about the one snapshot it's restoring. If `configure-host.sh` or `toggle-features.sh` changed `config/config.js` *after* that snapshot was taken, restoring it will revert those changes too — there's no drift detection between "what this snapshot captured" and "what's changed since." This is stated in the script's own `--help` output, not just here.
