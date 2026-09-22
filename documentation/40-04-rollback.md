# 40.4 Rollback

`upgrade.sh` previously kept a single, overwritten-every-run `.bak` copy of `docker-compose.yml` and `config/config.js`, and printed a manual `cp ...bak ...` command at the end — nothing executed it, and re-running `upgrade.sh` destroyed the only backup generation that existed. There was no automated rollback.

## What changed

`upgrade.sh`'s Step 1 now writes a **timestamped, non-overwriting** snapshot (`installation-scripts/lib/rollback-snapshot.sh`, new) to `.rollback-snapshots/<UTC-timestamp>/` at the repo root **before** touching anything: a copy of `docker-compose.yml` and `config/config.js` — the exact two files `upgrade.sh` mutates, nothing from `configure-host.sh`'s territory (`nginx/nginx.conf`, `config/constants.json`) — plus a `manifest.json` recording the prior `ps-server`/`ps-client` tags, their resolved image digests, and the deployment repo's git revision. A `latest` pointer file tracks the newest snapshot; the last 5 are kept, older ones pruned. This directory is gitignored — it holds a copy of `config.js`, which carries this deployment's real secrets once `configure-host.sh` has customized it.

`installation-scripts/rollback.sh` (new):

```bash
./installation-scripts/rollback.sh --yes            # restore the latest pre-upgrade snapshot
./installation-scripts/rollback.sh --to 20260922T193336Z --yes
```

It restores **only** `docker-compose.yml`'s `ps-server`/`ps-client` image tag lines (a targeted `sed`, the same mechanism `upgrade.sh` uses to bump them, run in reverse — not a wholesale file overwrite, so an unrelated `docker-compose.yml` edit made after the snapshot survives) and `config/config.js` (restored verbatim from the snapshot), then pulls and restarts the affected services and waits for them to report healthy using the health checks from [40.1](40-01-health-checks-and-startup-order.md). It never touches `signed-output/`, `docs/`, `nginx/nginx.conf`, or `config/constants.json`. It writes deployment evidence at the end, same as `upgrade.sh`.

## Tested, for real, against the local stack

Both required failure scenarios were actually run, not just described — see the PR description for the full command transcripts. In outline:

1. **Failed client deployment**: `upgrade.sh --client-tag 99.99.99` (a tag that doesn't exist) → snapshot written, `docker-compose.yml` mutated, `docker compose pull` fails as expected, deployment left in a broken (bad-tag) state. `rollback.sh --yes` → `ps-client` tag restored to `8.39`, container recreated, all 8 services report `healthy` again.
2. **Failed server deployment**: same shape, `upgrade.sh --server-tag 9.99.99` → `rollback.sh --yes` → `ps-server` restored to `3.28`, stack healthy again.
3. **Document storage untouched**: a marker file written into `signed-output/` before either failure scenario was still present, byte-identical, after both rollbacks.
4. **Idempotency**: running `rollback.sh --yes` a second time immediately after a successful rollback made no further changes (tag `sed` matched nothing to change, `config.js` copy was byte-identical) and still exited `0`.

## Known limitation, stated plainly

Rollback restores by **image tag**, not by digest, because `docker-compose.yml` doesn't pin by digest yet ([psapp-saas#11](https://github.com/mihailsgo/psapp-saas/issues/11) is tracked separately and had not landed at the time this was written). The snapshot manifest **does** record the actual running image digest at snapshot time (via `docker inspect`), so the evidence exists — `rollback.sh` just doesn't act on it yet. If a tag is ever force-pushed to a different image on the registry between the original deployment and a later rollback, restoring "the same tag" would not restore the same bits. Once #11 lands digest-pinning in `docker-compose.yml`, `rollback.sh` should restore by digest instead of by tag.

A second, narrower limitation: `rollback.sh` only knows about the one snapshot it's restoring. If `configure-host.sh` or `toggle-features.sh` changed `config/config.js` *after* that snapshot was taken, restoring it will revert those changes too — there's no drift detection between "what this snapshot captured" and "what's changed since." This is stated in the script's own `--help` output, not just here.
