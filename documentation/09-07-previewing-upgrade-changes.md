# 9.7 Previewing upgrade changes

Before an upgrade changes anything, `upgrade.sh --plan-only` shows which
configuration migrations would run and the exact text each would write. It
answers the question: *will this upgrade touch the settings we customised?*
The wizard's Upgrade panel always shows this preview (*Review this
upgrade*) before it offers **Apply and upgrade**, or **Pull images and
restart** when no configuration would change.

```bash
cd /opt/padsign
./installation-scripts/upgrade.sh --server-tag <server tag> --client-tag <client tag> --plan-only
```

It writes no file and starts, stops or recreates no container. It reads
the configuration files, the running containers' image versions, and the
Keycloak realm (a read-only query in the Keycloak container), so it is safe
on a live deployment. It exits `0` after printing the plan, or `2` when a
tag is not approved or a capability gate fails.

Add `--enable-local-eseal` to see what enabling local e-sealing would
change. `--plan-format machine` prints a delimiter-framed form for tools
(the wizard uses it); the default `text` form is for people.

## Migrations never overwrite your values

Each migration checks whether its target is already there and runs only
when it is missing:

| Migration | Runs only when |
|---|---|
| `document-routing` | `config/config.js` has no `DOCUMENT_ROUTING` key at all |
| `signed-output` | the effective compose model does not mount `/signed-output` for ps-server, or a `signed-output/` or `docs/` store it mounts from inside the checkout is missing. A store mounted from outside the checkout never counts |
| `compose-hostname` | Keycloak's `KC_HOSTNAME` or nginx's network alias in `docker-compose.yml` names a different host than `server_name` in `nginx/nginx.conf` |
| `local-eseal` | only with `--enable-local-eseal`: whichever of its six parts are not in place yet |
| `keycloak-backend-audience` | the `padsign-client` access token does not carry `padsign-backend` in its audience |

So a customised `DOCUMENT_ROUTING` block (your own `basePath`,
`pathTemplate`, webhook URL) is found and left alone, and the preview
reports it as *already applied*. The same holds for your own `seal.p12`
keystore (demo files are copied only where no file exists) and a
non-default stamping `baseUrl` (only the exact stock value is changed).

`compose-hostname` is the one migration that corrects an existing value.
That value never works: with a different host in `KC_HOSTNAME`, Keycloak
sends browsers to that host at login and writes it into every token's
issuer. The migration only rewrites entries that exist, is skipped when
`nginx.conf` does not name exactly one host, and recreates Keycloak when it
runs, so signed-in users sign in again.

The image tags are always rewritten, because that is the change you asked
for. They are shown at the top of the plan, not as a migration.

## Reading the plan

The text form looks like this:

```
========================================
PadSign Upgrade — PLAN ONLY (nothing was changed)
========================================

  Image tags:
    ps-server: <running tag> → <new tag>   (approved; pinned to its approved digest)
    ps-client: <running tag> → <new tag>   (approved; pinned to its approved digest)

  Configuration migrations:

    [already applied] document-routing
        Add DOCUMENT_ROUTING block (disabled by default)
        files: config/config.js

    [already applied] signed-output
    ...

  No configuration changes. Running this upgrade would only pull images
  and restart containers.

  Nothing has been modified. Re-run without --plan-only to apply.
========================================
```

- `[WILL APPLY]` is followed by the exact text that would be written.
- `[already applied]` means nothing would be written for it.
- *No configuration changes* is the normal result for a routine release.
  It does not mean something is wrong.
- The "from" tag is the one **running**. After the `git pull`,
  `docker-compose.yml` already pins the new tag, and the plan prints a
  `NOTE: docker-compose.yml pins ps-server <new> but <old> is running`
  line. That is expected.

In the wizard, **WILL APPLY** items are expanded with their text and
**APPLIED** items are collapsed. If every item is applied you get one green
panel: *No configuration changes. This upgrade will only pull images and
restart containers.*

`local-eseal` is always one item, although it edits several files (compose
service, `baseUrl`, Spring Security credentials, `STAMP_MODE` /
`STAMP_LOCAL`, `COMPOSE_PROFILES`, demo files). Applying only some of them
gives a stack that starts and then fails when it seals, so they are never
split.

### keycloak-backend-audience: "Could not check right now"

The plan logs in to Keycloak to check the mapper. When it cannot (Keycloak
not running, or the admin password changed since Keycloak's first boot),
the item shows *Could not check right now* with the reason. Nothing is known
to be pending. Export the current password and run the plan again:

```bash
 read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD
./installation-scripts/upgrade.sh --server-tag <server tag> --client-tag <client tag> --plan-only
unset KEYCLOAK_ADMIN_PASSWORD
```

## The plan matches the run

The plan is built from the same checks the real run uses, so it cannot
disagree with what the same arguments would do. A useful check after any
upgrade: run `--plan-only` again with the same tags. Every migration must
report *already applied*.

## Unapproved tags

A tag `release/approved-digests.json` does not approve never reaches the
plan: `--plan-only` refuses it with exit 2, and the wizard shows the first
line of the refusal instead of a plan and offers no way to apply. The
command-line `--allow-unapproved` (emergency hotfix only) makes the plan
list the tag under `UNAPPROVED OVERRIDE`.

## What the preview does not cover

- Settings changes (hostname, certificate, feature toggles). Those run
  through `configure-host.sh` and have no preview. See
  [9.1](09-01-changing-hostname.md), [9.2](09-02-renewing-the-tls-certificate.md)
  and [9.4](09-04-toggling-features.md).
- Choosing individual migrations. **Apply and upgrade** applies the whole
  plan, **Cancel** applies nothing.
- The pre-flight checks that need the registry: image signatures and
  whether the new ps-server image can read `config/config.js` run only in
  the real upgrade ([9.6](09-06-what-upgrade-does.md)).
