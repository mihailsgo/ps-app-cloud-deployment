# 5. Upgrading an Existing Deployment

To move an already-deployed instance to the **current release** (`ps-server:3.27`,
`ps-client:8.38` — see [1. Release Snapshot](01-release-snapshot.md)):

```bash
./installation-scripts/upgrade.sh --server-tag 3.27 --client-tag 8.38
# Add --enable-local-eseal to also provision the local stamping stack.
# Any combination is valid; --enable-local-eseal alone is allowed too.
```

The script only changes what you ask it to — it pulls the new image(s), restarts
just those containers, and prints a rollback command. It is safe to re-run.

> Upgrading across several releases, or enabling local e-sealing at the same
> time? [4.4 Existing deployment (upgrade an already-deployed instance)](04-04-existing-deployment-upgrade-an-already-deployed-instance.md)
> is the complete phase-by-phase walkthrough — preview, upgrade, verification,
> credential rotation, and rollback.

> Pass the tags for the version you are moving to. The examples use the current
> release; substitute newer tags as they ship. Older tags are valid too (e.g. for
> a controlled rollback).

> Prefer a browser over the CLI? [36. Deployment Wizard](36-deployment-wizard.md)'s
> dashboard has an Upgrade panel that wraps this same script with live progress.

## Sub-sections

- [5.1 What upgrade does (step by step)](05-01-what-upgrade-does-step-by-step.md)
- [5.2 Upgrade to the current release (authenticated PDF download + signed-PDF receive-back)](05-02-upgrade-to-the-current-release.md)

