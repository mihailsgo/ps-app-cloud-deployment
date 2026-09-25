# 5. Upgrading an Existing Deployment

To move an already-deployed instance to the **current release** (the tags this
checkout's `docker-compose.yml` pins, described in
[1. Release Snapshot](01-release-snapshot.md) - `ps-server:3.30`,
`ps-client:8.40` at the time of writing):

```bash
./installation-scripts/upgrade.sh --server-tag 3.30 --client-tag 8.40
# Add --enable-local-eseal to also provision the local stamping stack.
# Any combination is valid; --enable-local-eseal alone is allowed too.
```

> **First bring this checkout to the new release.** On a bootstrapped host a
> plain `git pull` aborts, because `bootstrap.sh` left this host's hostname
> and secrets in `config/config.js`, `config/constants.json`,
> `docker-compose.yml` and `nginx/nginx.conf`. Stash them, pull, pop them
> back and check `git stash list` is empty, as in
> [4.4 Phase 1](04-04-existing-deployment-upgrade-an-already-deployed-instance.md#phase-1---update-the-deployment-scripts-and-configs)
> (which also covers a conflict on `git stash pop`). Then run `upgrade.sh`
> straight away: the pull already pins the new tags in `docker-compose.yml`
> while the old containers are still running, so no `docker compose up`
> in between.

The script only changes what you ask it to — it pulls the new image(s), restarts
just those containers, and prints a rollback command. It is safe to re-run.
A requested tag must be the one `release/approved-digests.json` approves. The
script pins that approved digest too, so the deployment ends digest-pinned and
`validate-config.sh` passes. Any other tag is **refused** (exit 2) before
anything is pulled or modified, and `--plan-only` reports the same refusal. To
move to a new tag, approve it first
(see [39. Release Procedure](39-release-procedure.md) steps 4-5).

For an emergency hotfix only, `--allow-unapproved` lets an unapproved tag
through. The script prints a loud warning, leaves the tag without a digest pin,
and records the override in `deployment-evidence.json` as
`"unapproved_override"`. `validate-config.sh` and `postdeploy-check.sh` keep
failing until the tag is approved and pinned:

```bash
./installation-scripts/upgrade.sh --server-tag 3.31 --allow-unapproved --plan-only   # review first
./installation-scripts/upgrade.sh --server-tag 3.31 --allow-unapproved
```

> Coming from `ps-server:3.28` or older? `3.30` runs as a non-root user
> (uid 1000) on Node 24, and on a deployment that already uses signed-PDF
> receive-back it stops the current Padsign Manager's downloads and acks
> under the legacy shared API key until that company gets its own key.
> Check [1. Release Snapshot](01-release-snapshot.md) and the callout in
> [5.2](05-02-upgrade-to-the-current-release.md) before upgrading.

> Upgrading across several releases, or enabling local e-sealing at the same
> time? [4.4 Existing deployment (upgrade an already-deployed instance)](04-04-existing-deployment-upgrade-an-already-deployed-instance.md)
> is the complete phase-by-phase walkthrough — preview, upgrade, verification,
> credential rotation, and rollback.

> Pass the tags for the version you are moving to. The examples use the current
> release; substitute newer tags once they are approved in the checkout you
> pulled. To go back to an older release, use `rollback.sh`
> ([40.4 Rollback](40-04-rollback.md)), not `upgrade.sh` with an older tag.

> Prefer a browser over the CLI? [36. Deployment Wizard](36-deployment-wizard.md)'s
> dashboard has an Upgrade panel that wraps this same script with live progress.

## Sub-sections

- [5.1 What upgrade does (step by step)](05-01-what-upgrade-does-step-by-step.md)
- [5.2 Upgrade to the current release (authenticated PDF download + signed-PDF receive-back)](05-02-upgrade-to-the-current-release.md)

