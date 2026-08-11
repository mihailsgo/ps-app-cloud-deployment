# 36.9 Previewing configuration changes

Every upgrade now goes through a preview. Before anything is written, the
wizard shows which configuration migrations would run and the exact text each
would add. You then choose **Apply** or **Cancel**.

This exists to answer one question an operator could not previously answer:
*will this upgrade disturb the settings we customised for this client?*

## The additive-only guarantee

`upgrade.sh` never overwrites a configuration value you have set. Every
configuration migration is guarded by a presence check and only fires when its
target is **absent**:

| Migration | Fires only when |
|---|---|
| `document-routing` | `config/config.js` contains no `DOCUMENT_ROUTING` key at all |
| `signed-output` | `docker-compose.yml` has no `signed-output` volume mount, or the `signed-output/` or `docs/` directory is missing |
| `local-eseal` | (only with `--enable-local-eseal`) whichever of its six parts are not yet in place |

So a customised `DOCUMENT_ROUTING` block — your own `basePath`, your own
`pathTemplate`, your own webhook URL — is read by the guard, found, and left
untouched. The preview reports it as **already applied**. The same holds for a
real `seal.p12` keystore and a non-default `baseUrl`: the demo artefacts are
staged with `cp -n`, which never overwrites, and the `baseUrl` patch only
matches the exact stock value.

Image tags are the one thing an upgrade always rewrites — but that is the
change you asked for, so it is shown as read-only context at the top of the
preview rather than as a migration.

## Reading the preview

Each migration shows one of two states:

- **WILL APPLY** — expanded, with the exact text that would be written.
- **APPLIED** — collapsed. Nothing would be written for it.

If every migration is already applied you get a single green panel: *"No
configuration changes. This upgrade will only pull images and restart
containers."* **This is the normal result for a routine version bump** and is
the reassurance the preview exists to give. It does not mean something went
wrong.

`local-eseal` is deliberately reported as **one** item covering four files.
Its six edits — compose service, `baseUrl`, Spring Security credentials,
`STAMP_MODE`/`STAMP_LOCAL`, `COMPOSE_PROFILES`, demo assets — are a single
semantic unit. Applying some but not others produces a stack that starts
normally and then fails at signing time, so they are never split.

## From the command line

The preview is not wizard-only. The same plan is available from a shell, and
is safe to run against a live deployment — it writes nothing, starts nothing,
and touches no container:

```bash
./installation-scripts/upgrade.sh --server-tag 3.28 --client-tag 8.39 --plan-only
```

Add `--enable-local-eseal` to see what enabling local e-sealing would change.
`--plan-format machine` emits the delimiter-framed form the wizard consumes;
the default `text` is the readable one.

Because the plan is generated from the same guards the real run uses, it
cannot disagree with what an unflagged run would do. A useful property to
check on any deployment: run a real upgrade, then re-run `--plan-only` — every
migration should report *already applied*.

## What the preview does not cover

- **Settings changes** (hostname, certificate renewal, feature toggles). Those
  run through `configure-host.sh`, which is not yet plan-aware. See
  [37. Settings](37-settings-post-go-live-changes.md).
- **Declining an individual migration.** The preview is read-only: Apply
  applies everything in the plan, Cancel applies nothing. Per-migration opt-out
  is deliberately deferred until there is evidence operators need it.
- **Anything outside configuration files.** Keycloak realm state, container
  images and volumes are not modelled.
