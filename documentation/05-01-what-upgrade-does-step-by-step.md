# 5.1 What upgrade does (step by step)

## See it before you run it

```bash
./installation-scripts/upgrade.sh --server-tag 3.28 --client-tag 8.39 --plan-only
```

`--plan-only` evaluates every configuration migration below and prints exactly
what would change, then exits 0. It writes nothing, starts nothing and touches
no container, so it is safe against a live deployment. Add
`--plan-format machine` for the delimiter-framed form the deployment wizard
consumes.

**Steps 3-6 are additive.** Each is guarded by a presence check and only fires
when its target is absent, so a value you have customised — a document-routing
path, a real `seal.p12`, a non-default stamping `baseUrl` — is detected and
left alone. `--plan-only` reports those as *already applied*. Step 2 (image
tags) always rewrites, because it is the change you asked for. Step 7
(`compose-hostname`) is the one migration that corrects an existing value: it
fires only when `KC_HOSTNAME` or the nginx network alias names a different
host than `nginx/nginx.conf` serves, a mismatch that never works. Details in
[36.9 Previewing configuration changes](36-09-previewing-configuration-changes.md).

## The steps

1. **Backs up** `docker-compose.yml` and `config/config.js` (`.bak` files)
2. **Updates image tags** in `docker-compose.yml` - replaces `ps-server:X.XX` and/or `ps-client:X.XX` with the new versions
3. **Ensures `DOCUMENT_ROUTING`** config block exists in `config.js` (appends if missing, disabled by default - does not overwrite existing settings)
4. **Ensures `signed-output` volume mount** exists in `docker-compose.yml` for ps-server
5. **Creates `signed-output/` (mode 750) and `docs/` (mode 770, group-owned for
   dmss-archive-services-fallback's `spring` user) directories** if they don't
   exist - see
   [installation-scripts/lib/dir-permissions.sh](../installation-scripts/lib/dir-permissions.sh)
   for why those modes and not 777
6. **(`--enable-local-eseal` only)** Stages `dmss-digital-stamping-service/` from
   `installation-scripts/assets/`, appends the gated compose service block,
   patches `dmss-container-and-signature-services/application.yml` to use the
   in-network stamping host, pins `SPRING_SECURITY_USER_*` env vars on
   container-signature, flips `STAMP_MODE` to `"local"` in `config/config.js`,
   and activates the `local-eseal` compose profile in `.env`. See
   [Enabling local e-sealing](04-enabling-local-e-sealing.md#4-enabling-local-e-sealing) above.
7. **Aligns the compose hostname (`compose-hostname`)** - if the keycloak
   service's `KC_HOSTNAME` or the nginx service's first network alias names a
   different host than `nginx/nginx.conf`'s `server_name`, rewrites it to that
   host. Typically the shipped `padsign.trustlynx.com`, left behind on
   deployments configured before `configure-host.sh` rewrote it: Keycloak then
   issues tokens for, and sends logins to, `padsign.trustlynx.com`. Never adds a
   `KC_HOSTNAME` or an alias list that isn't there, and is skipped when
   `nginx.conf` doesn't name exactly one host. Changing `KC_HOSTNAME` changes the
   token issuer, so signed-in users sign in again
8. **Pulls new Docker images** - only the services being upgraded
9. **Restarts changed containers** - only ps-server and/or ps-client and
   the new stamping service if applicable; DMSS stays running, and Keycloak
   stays running unless step 7 changed `KC_HOSTNAME` (then it is recreated and
   waited for)
10. **Restarts nginx** to pick up any config changes - recreated instead if
    step 7 changed its network alias, since a restart keeps the old definition
11. **Verifies** ps-server startup and prints running container versions
12. **Records deployment evidence** - writes `deployment-evidence.json`
    (git-ignored) with this repo's git revision/dirty flag, the pinned image
    tags and their OCI revision labels, sha256 checksums of the four
    per-host-mutated config files, and which optional features are enabled
13. **Prints rollback command** in case anything goes wrong

