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

**Steps 3-7 are additive.** Each is guarded by a presence check and only fires
when its target is absent, so a value you have customised — a document-routing
path, a real `seal.p12`, a non-default stamping `baseUrl` — is detected and
left alone. `--plan-only` reports those as *already applied*. Step 2 (image
tags) is the one step that always rewrites, because it is the change you asked
for. Details in
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
8. **Pulls new Docker images** - only the services being upgraded
9. **Restarts changed containers** - only ps-server and/or ps-client and
   the new stamping service if applicable; Keycloak, DMSS, nginx stay running
10. **Restarts nginx** to pick up any config changes
11. **Verifies** ps-server startup and prints running container versions
12. **Records deployment evidence** - writes `deployment-evidence.json`
    (git-ignored) with this repo's git revision/dirty flag, the pinned image
    tags and their OCI revision labels, sha256 checksums of the four
    per-host-mutated config files, and which optional features are enabled
13. **Prints rollback command** in case anything goes wrong

