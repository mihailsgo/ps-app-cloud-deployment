# 9.6 What upgrade does

What `installation-scripts/upgrade.sh` does, in the order it prints it.
The procedure around it is in [9.5 Upgrading](09-05-upgrading.md).

```bash
./installation-scripts/upgrade.sh [--server-tag X] [--client-tag Y] [--enable-local-eseal]
```

At least one of the three is required. `--plan-only` stops after the
checks marked *(also in --plan-only)* below and prints the plan instead
([9.7](09-07-previewing-upgrade-changes.md)).

## Pre-flight: before anything is written or pulled

A failure here changes nothing: no snapshot, no backup, no edit, no pull.

1. **Capability gates** *(also in --plan-only)*. With `--enable-local-eseal`,
   the resulting ps-server tag must be at or above the `local-eseal` minimum
   in `release/capabilities.json`; each `--require-capability NAME` is
   checked the same way. Refused with exit 2 and the command to re-run with
   a newer tag.
2. **Approved-tag gate** *(also in --plan-only)*. A `--server-tag` /
   `--client-tag` must be the tag `release/approved-digests.json` approves.
   Any other tag stops the run with exit 2 (`Refusing to upgrade to a tag
   release/approved-digests.json does not approve`) unless
   `--allow-unapproved` is given, which prints a warning banner.
3. **Image signatures** (`Pre-flight: verifying image signatures...`). Each
   requested ps-server / ps-client image is checked with cosign against
   `release/cosign.pub`, together with its signed SBOM and provenance, by
   the approved digest. A signature that does not verify stops the upgrade
   with exit 1. Without cosign (version 3 or newer) on the host this is a
   warning only, unless `PADSIGN_REQUIRE_SIGNATURES=1` is set, which makes
   it a refusal.
4. **config.js readability** (`Pre-flight: checking that the ps-server image
   can read config/config.js...`), whenever the run (re)starts ps-server. The
   ps-server image the upgrade ends on is asked which user it runs as, and
   must be able to read `config/config.js`. If it cannot, the run stops with
   exit 1 and prints the fix, for example
   `sudo chgrp 1000 config/config.js && sudo chmod 640 config/config.js`.
   Without docker this only warns.

The first line of the run shows the change, for example
`ps-server: <running tag> → <new tag>`. The "from" side is the tag that is
**running**, not the one `docker-compose.yml` pins; after the `git pull` of
[9.5](09-05-upgrading.md) the pin already names the new release, and the run
prints a `NOTE` saying so.

## The steps

**Step 1/6: Backing up.**
Writes a rollback snapshot to `.rollback-snapshots/<UTC timestamp>/`
(mode 700, files 600) holding `docker-compose.yml`, `config/config.js` and a
`manifest.json` of the ps-server / ps-client images that are running (tag
and registry digest). The last five snapshots are kept. It also writes
owner-only `docker-compose.yml.bak` and `config/config.js.bak`.
[9.8 Rollback](09-08-rollback.md) restores from the snapshot.

**Step 2/6: Updating image tags.**
Rewrites the ps-server and/or ps-client `image:` line in
`docker-compose.yml` to the new tag, pinned to the digest
`release/approved-digests.json` approves. A tag let through by
`--allow-unapproved` is left without a digest, with a note that
`validate-config.sh` fails until it is approved and pinned.

**Step 3/6: Ensuring DOCUMENT_ROUTING config.**
If `config/config.js` has no `DOCUMENT_ROUTING` key at all, appends a block
with routing and both strategies disabled. An existing block is never
changed ([11](11-document-routing-and-receive-back.md)).

**Step 4/6: Ensuring signed-output volume.**
Adds `./signed-output:/signed-output` to ps-server's volumes unless the
effective compose model (`docker-compose.yml` plus any `COMPOSE_FILE`
overlay or `docker-compose.override.yml`) already mounts `/signed-output`
for it. Creates `signed-output/` (mode 750) and `docs/` (mode 770) when
they are missing, and re-owns either tree to the user its container image
runs as whenever something in it belongs to another user. When the operator
is not root, the re-own runs through a one-shot container of that image. If
a tree still cannot be made writable, the upgrade stops here, before any
container is recreated. Stores mounted from outside the checkout are never
created or re-owned.

**Step 4b/6: Enabling local e-sealing** (only with `--enable-local-eseal`).
Each part is applied only if it is not in place yet: stages
`dmss-digital-stamping-service/` from `installation-scripts/assets/`
(never overwriting existing files), appends the profile-gated
`dmss-digital-stamping-service` service to `docker-compose.yml`, points
`digital-stamping-service.baseUrl` in
`dmss-container-and-signature-services/application.yml` at the in-network
stamping service (only when it still has the stock value), adds
`SPRING_SECURITY_USER_NAME` / `SPRING_SECURITY_USER_PASSWORD` to the
container-signature service, sets `STAMP_MODE: "local"` with a `STAMP_LOCAL`
block in `config/config.js`, and adds `local-eseal` to `COMPOSE_PROFILES`
in `.env`. See [10.4 Existing deployment](10-04-existing-deployment.md).

**Step 4c/6: Ensuring padsign-backend is in the padsign-client token audience.**
Always runs. Adds an `oidc-audience-mapper` to `padsign-client` in the live
Keycloak realm unless a mapper already puts `padsign-backend` into the
access token's audience. Current Keycloak versions refuse ps-server's token
introspection without it, and every authenticated portal call returns
`401`. Admin credentials come from `KEYCLOAK_ADMIN` /
`KEYCLOAK_ADMIN_PASSWORD` when exported, otherwise from the running Keycloak
container's environment. If Keycloak cannot be reached or the login fails,
it prints a `WARNING` with the fix and the upgrade continues
([8.2 Token audience](08-02-token-audience.md)).

**Step 4d/6: Ensuring KC_HOSTNAME and nginx alias match the served hostname.**
If Keycloak's `KC_HOSTNAME` or nginx's first network alias in
`docker-compose.yml` names another host than `server_name` in
`nginx/nginx.conf`, rewrites it to that host, and marks Keycloak and/or
nginx for recreation in step 5. It never adds a `KC_HOSTNAME` or an alias
that is not there, and is skipped when `nginx.conf` does not name exactly
one host. A changed `KC_HOSTNAME` changes the token issuer, so users sign in
again.

**Step 4e/6: Re-applying the config/config.js ownership model.**
Steps 3 and 4b rewrite `config/config.js`. This step sets its group to the
group of the ps-server image step 2 pinned and its mode to 640, and checks
from inside that image that it can read the file. If the group cannot be
set, the file is made readable again and the fix is printed.

**Step 5/6: Pulling images and restarting.**
Pulls and recreates ps-server and/or ps-client, and
`dmss-digital-stamping-service` when it runs or `--enable-local-eseal` is
given. Services they depend on (Keycloak, the DMSS services) are recreated
too when the release changed their definition in `docker-compose.yml`, for
example their logging or restart policy; otherwise they keep running. With
`--enable-local-eseal` it also recreates
`dmss-container-and-signature-services` and ps-server so they pick up the
new settings. Keycloak is also recreated (and waited for) when step 4d
changed `KC_HOSTNAME`. nginx is always recreated, which reloads
`nginx.conf` and the certificates. A failed pull or `docker compose up`
ends the run as a failed upgrade (below).

**Step 6/6: Waiting for restarted services to be healthy.**
Waits up to `--health-timeout` seconds (default 480) for every restarted
service and nginx to report healthy
([9.9 Health checks and startup](09-09-health-checks-and-startup.md)).
It fails at once when a service reports `unhealthy`, exits, or restarts
twice while waiting, and prints that service's last health-probe output
and last 15 log lines. On success it prints the running ps-server,
ps-client and nginx containers and `All restarted services healthy.`, then
re-checks the ownership of `signed-output/` and `docs/`.

## After the steps

- **Recording deployment evidence.** Writes `deployment-evidence.json`
  (git-ignored, no secrets): this checkout's git revision and whether it has
  local changes, the image tags and digests, checksums of `config.js`,
  `constants.json`, `nginx.conf` and `docker-compose.yml`, and which
  optional features are on. The previous file is kept as
  `deployment-evidence.json.previous`.
- **Rollback command.** The run ends with `Upgrade complete!` and
  `Rollback: ./installation-scripts/rollback.sh --yes   (restores snapshot ...)`.

## When the upgrade fails

A failure in step 5 or 6 prints `UPGRADE FAILED: <reason>` and
`docker compose ps`, writes deployment evidence, and prints the exact
rollback command for the snapshot from step 1:

```
UPGRADE FAILED: services did not become healthy

Roll back with:
  ./installation-scripts/rollback.sh --to 20260923T105025Z --yes
```

With `--rollback-on-failure` it runs that command itself. Either way the
upgrade exits `1`.

## What upgrade never changes

`nginx/nginx.conf`, `config/constants.json`, the TLS certificates,
Keycloak's admin password, the DMSS images, and your documents in
`signed-output/` and `docs/` (apart from their ownership). Hostname and
certificate changes are [9.1](09-01-changing-hostname.md) and
[9.2](09-02-renewing-the-tls-certificate.md).
