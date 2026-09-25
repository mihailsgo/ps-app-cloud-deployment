# 5.1 What upgrade does (step by step)

## See it before you run it

```bash
./installation-scripts/upgrade.sh --server-tag 3.32 --client-tag 8.40 --plan-only
```

`--plan-only` evaluates every configuration migration below and prints exactly
what would change, then exits 0. It writes nothing, starts nothing and touches
no container, so it is safe against a live deployment. Add
`--plan-format machine` for the delimiter-framed form the deployment wizard
consumes.

**"From" is what is running.** The `ps-server: X → Y` lines (plan and real run)
take X from the running container, not from `docker-compose.yml`. After the
`git pull` of [4.4](04-04-existing-deployment-upgrade-an-already-deployed-instance.md)
Phase 1, `docker-compose.yml` already pins the new release while the old one
still runs, and the upgrade says so:

```
    ps-server: 3.28 → 3.30   (approved; pinned to its approved digest)
      NOTE: docker-compose.yml pins ps-server 3.30 but 3.28 is running - the rollback snapshot records 3.28@sha256:98bb0577..., the running image
```

In the machine plan, `server_tag_from` / `client_tag_from` are the running tags
and `server_tag_pinned` / `client_tag_pinned` what `docker-compose.yml` pins.
Without docker (or with the service stopped) "from" is the pin, as before.

**Steps 3-7 are additive.** Each is guarded by a presence check and only fires
when its target is absent, so a value you have customised — a document-routing
path, a real `seal.p12`, a non-default stamping `baseUrl` — is detected and
left alone. `--plan-only` reports those as *already applied*. Step 2 (image
tags) always rewrites, because it is the change you asked for. Step 7
(`compose-hostname`) is the one migration that corrects an existing value: it
fires only when `KC_HOSTNAME` or the nginx network alias names a different
host than `nginx/nginx.conf` serves, a mismatch that never works. Details in
[36.9 Previewing configuration changes](36-09-previewing-configuration-changes.md).

## Before any step: the approved-tag gate

A `--server-tag` / `--client-tag` must be the tag `release/approved-digests.json`
approves for that image. Any other tag stops the run with exit 2 before step 1,
so nothing is backed up, edited or pulled. `--plan-only` refuses the same way,
and so does the deployment wizard's preview, which runs it. `--allow-unapproved`
lets a hotfix tag through (see [5. Upgrading an Existing Deployment](05-upgrading-an-existing-deployment.md)):
the plan then lists it under `UNAPPROVED OVERRIDE` (machine format:
`unapproved_override=<image>:<tag>:<approved tag>`), and a real run prints a
warning banner and records it in `deployment-evidence.json`.

Then, still **before anything is written or pulled**, the real run verifies the
**cosign signature** of each requested `ps-server` / `ps-client` image, and its
signed SBOM and provenance attestations, against `release/cosign.pub` - by the
approved digest, or (for a tag let through by `--allow-unapproved`) by the
digest the tag resolves to now. A signature that does not verify stops the
upgrade before step 1, so no snapshot, backup or edit is left behind. No cosign
on the host only warns (it refuses under `CI=true` or
`PADSIGN_REQUIRE_SIGNATURES=1`); `ps-server:3.28` / `ps-client:8.39`, released
before signing existed, pass with a warning. `--plan-only` does not run this
check. See [40.2](40-02-post-deploy-validation.md#image-signatures-cosign).

Last before step 1: whenever the run (re)starts ps-server (`--server-tag`, or
`--enable-local-eseal`), the **ps-server image it ends on must be able to read
`config/config.js`**. The requested tag's approved digest (or, without
`--server-tag`, the current pin) is asked which uid:gid it runs as, and, when
the owner/group/mode bits say no, reads the file from inside a one-shot
container. If it cannot, the upgrade stops with exit 1, nothing written, and
prints the fix, for example:

```
ERROR: mihailsgordijenko/ps-server:3.32@sha256:cff423bc... runs as 1000:1000 and cannot read config/config.js
       (root:root (0:0), mode 640). ps-server would crash-loop with EACCES after the
       restart, and nginx would never start. Fix, then re-run:
         sudo chgrp 1000 config/config.js && sudo chmod 640 config/config.js
```

That is the move from a root ps-server (3.29 and older) to 3.30 or later (uid 1000)
with a `config.js` someone restricted to `root:root` 640. Without docker it
only warns. `--plan-only` does not run it.

## The steps

1. **Backs up** `docker-compose.yml` and `config/config.js` (`.bak` files, mode
   `0600`: `config.js.bak` holds the same secrets as `config.js`), and
   writes the rollback snapshot `rollback.sh` restores from
   (`.rollback-snapshots/<UTC timestamp>/`, mode 700, files 600: it holds a copy
   of `config.js`). The snapshot's `manifest.json` records the `ps-server` /
   `ps-client` image that is **running** (tag and registry digest), not the one
   `docker-compose.yml` pins, plus the pins under `compose_pins`; the two differ
   after a `git pull`, and step 1 prints a `NOTE` when they do. See
   [40.4 Rollback](40-04-rollback.md#rollback-restores-what-was-running-not-what-docker-composeyml-pinned)
2. **Updates image tags** in `docker-compose.yml` - replaces `ps-server:X.XX` and/or `ps-client:X.XX` with the new versions, pinned to the digest `release/approved-digests.json` approves (left unpinned only for a tag let through by `--allow-unapproved`)
3. **Ensures `DOCUMENT_ROUTING`** config block exists in `config.js` (appends if missing, disabled by default - does not overwrite existing settings)
4. **Ensures `signed-output` volume mount** exists in `docker-compose.yml` for ps-server,
   unless the effective compose model (`docker-compose.yml` plus any
   `COMPOSE_FILE` overlay or `docker-compose.override.yml`) already mounts
   `/signed-output` for it
5. **Creates `signed-output/` (mode 750) and `docs/` (mode 770) if missing, and
   re-owns either tree to the uid its container image runs as** whenever
   anything in it belongs to someone else - e.g. the root-owned
   `{company}/...` directories and `.padsign-buffer/` entries a pre-Node-24
   ps-server wrote, which the non-root Node 24 image cannot write into or
   delete from. Uses the image being upgraded TO, runs through a one-shot
   container when the operator isn't root, re-checks after the restart, and
   stops the upgrade before any container is recreated if the tree still
   isn't writable - see
   [installation-scripts/lib/dir-permissions.sh](../installation-scripts/lib/dir-permissions.sh)
   for why those modes and not 777. These are the directories the effective
   compose model mounts. One it mounts from outside the checkout (an
   environment overlay's storage, [42](42-host-reconciliation-runbook.md)) is
   the documents' existing home: it is never created or re-owned here, and
   `validate-config.sh` checks it
6. **(`--enable-local-eseal` only)** Stages `dmss-digital-stamping-service/` from
   `installation-scripts/assets/`, appends the gated compose service block,
   patches `dmss-container-and-signature-services/application.yml` to use the
   in-network stamping host, pins `SPRING_SECURITY_USER_*` env vars on
   container-signature, flips `STAMP_MODE` to `"local"` in `config/config.js`,
   and activates the `local-eseal` compose profile in `.env`. See
   [Enabling local e-sealing](04-enabling-local-e-sealing.md#4-enabling-local-e-sealing) above.
7. **Ensures `padsign-backend` is in the `padsign-client` access-token audience**
   (always, not flag-gated) - adds an `oidc-audience-mapper` to `padsign-client`
   in the live Keycloak realm unless a mapper already grants that audience.
   Keycloak 26.4.12 / 26.6.2 / 26.7.0 and newer refuse ps-server's token
   introspection without it, so every authenticated portal API call returns 401.
   Admin credentials come from `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` if
   set, otherwise from the running keycloak container's own environment. If
   Keycloak cannot be reached, the step prints a warning with the fix and the
   upgrade continues. See
   [14.8 Token audience for introspection](14-08-token-audience-for-introspection.md).
8. **Aligns the compose hostname (`compose-hostname`)** - if the keycloak
   service's `KC_HOSTNAME` or the nginx service's first network alias names a
   different host than `nginx/nginx.conf`'s `server_name`, rewrites it to that
   host. Typically the shipped `padsign.trustlynx.com`, left behind on
   deployments configured before `configure-host.sh` rewrote it: Keycloak then
   issues tokens for, and sends logins to, `padsign.trustlynx.com`. Never adds a
   `KC_HOSTNAME` or an alias list that isn't there, and is skipped when
   `nginx.conf` doesn't name exactly one host. Changing `KC_HOSTNAME` changes the
   token issuer, so signed-in users sign in again
9. **Re-applies `config/config.js`'s ownership model** (printed as step 4e):
   group = the gid of the ps-server image step 2 pinned, mode 640, read back
   from inside that image, the same code `configure-host.sh` ends with. Steps
   3 and 6 rewrite `config.js` with `perl -i`, which keeps the file's group
   only if the user running the upgrade may set it; a user who is neither root
   nor in that group would otherwise leave a 640 file ps-server 3.30 cannot
   open. When the group cannot be restored, the file is made readable again
   and the fix is printed ([22](22-security-and-route-protection.md#secrets-on-the-host))
10. **Pulls new Docker images** - only the services being upgraded
11. **Restarts changed containers** - only ps-server and/or ps-client and
   the new stamping service if applicable; DMSS stays running, and Keycloak
   stays running unless step 8 changed `KC_HOSTNAME` (then it is recreated and
   waited for)
12. **Restarts nginx** to pick up any config changes - recreated instead if
    step 8 changed its network alias, since a restart keeps the old definition
13. **Waits for the restarted services to be healthy** and prints running container versions; exits 1 if they are not healthy in time (`--health-timeout`), running `rollback.sh` first when `--rollback-on-failure` was given
14. **Records deployment evidence** - writes `deployment-evidence.json`
    (git-ignored) with this repo's git revision/dirty flag, the pinned image
    tags and their OCI revision labels, sha256 checksums of the four
    per-host-mutated config files, and which optional features are enabled
15. **Prints rollback command** in case anything goes wrong. `rollback.sh`
    restores the running image the step 1 snapshot recorded and exits 1 if the
    restored containers do not run exactly that digest. After a successful
    upgrade, entries of an earlier rollback's `.rollback-applied.json` whose
    pins this run replaced are dropped

