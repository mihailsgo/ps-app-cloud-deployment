# 42.6 Living with an overlay: upgrades, value changes, certificates, rebuilds

Once a host runs as "tag + overlay", **every change goes through the
overlay**. A hand edit in the checkout makes `overlay.sh verify` fail with
`modified but NOT declared in the overlay (undocumented drift)`. That failure
is the point: drift can no longer be introduced silently.

**Overlays are versioned and immutable.** Every change writes a **new**
overlay directory, for example `/etc/padsign/overlay/<YYYYMMDD>-<what>`. The
previous release checkout plus the previous overlay stays a complete,
tested rollback target.

## Upgrading to a new release

```bash
OLD_OVERLAY=/etc/padsign/overlay/<current>; NEW_OVERLAY=/etc/padsign/overlay/$(date +%Y%m%d)-$NEXT_TAG
NEXT=/opt/padsign/releases/$NEXT_TAG
git clone --branch "$NEXT_TAG" <repo-url> "$NEXT" && cd "$NEXT"
./installation-scripts/overlay.sh rebase --overlay "$OLD_OVERLAY" --out "$NEW_OVERLAY"
./installation-scripts/overlay.sh apply  --overlay "$NEW_OVERLAY"
./installation-scripts/overlay.sh verify --overlay "$NEW_OVERLAY" --live "$NEW"   # --live = the checkout running today
./installation-scripts/upgrade.sh --server-tag <pinned> --client-tag <pinned> --plan-only   # expect: no pending migrations
```

- `rebase` 3-way merges the release's changes to every file the overlay
  overrides under the overlay's edits. In the rehearsal, a new config field
  and the host's webhook/stamping edits both survived.
- A real conflict (both sides changed the same lines) is reported per file.
  `apply` refuses until you resolve the `<<<<<<<` blocks in
  `$NEW_OVERLAY/files/...` and run `overlay.sh rehash --overlay "$NEW_OVERLAY"`.
- `verify --live` should show only the release's intended changes, typically
  the ps-server/ps-client image bump.
- Then cut over with 42.4 C2-C5, the previous release directory being the
  old one: `OLD="$NEW"; NEW="$NEXT"; OVERLAY="$NEW_OVERLAY"`, and the 42.4
  variables (`PROJECT`, `SIGNED`, `DOCS`, ...) set from that overlay. Run C2
  even when the storage modes are already right. It sets `PS_IDS`, `FB_IDS`
  and `OLD_FB_IDS`, and C4 uses them to re-own the storage when an image of
  the new release runs as another uid. Without them C4's `chown` lines fail
  or are skipped. In C4, `ps-server`'s `working_dir` label must name the new
  directory. Keycloak's usually keeps naming the previous one: its
  definition is the same in both releases, so compose does not recreate it
  (42.4 C4).
- Roll back with 42.5 R3, pointed at the previous release directory.
- Do **not** use `upgrade.sh` (without `--plan-only`), `rollback.sh` or the
  deployment wizard's *Upgrade* on an overlay-managed checkout. They rewrite
  tracked files in place. The previous directory is the rollback.

If `--plan-only` lists a pending migration, the overlay's copy of
`config.js` is missing something the release's scripts expect. Take it to
the release owner rather than hand-editing. Two entries are not that:

- `signed-output`: since v1.0.44 the check reads the storage mounts of the
  effective compose model, which on this host come from `compose.overlay.yml`
  (outside the checkout). Before v1.0.44 it looked for `signed-output/` and
  `docs/` inside the checkout and reported `[WILL APPLY] signed-output` on
  every overlay host. From v1.0.44 on, a pending `signed-output` means the
  release's `docker-compose.yml` and the overlay both lack the ps-server
  mount, or a store mounted from inside the checkout is missing. Take that to
  the release owner.
- `keycloak-backend-audience` with *Could not check right now*: the probe
  could not log in to Keycloak (by default it uses the container's
  first-boot password, which the overlay does not carry), so nothing is
  known to be pending. Run the plan again with the admin password in the
  environment (`read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD`),
  or check the mapper with 42.2 K4b.

## Changing a value in the overlay (rotate a secret, flip a flag)

For example rotating `REGISTER_PDF_API_KEY` or `SESSION_SECRET` (42.2 K6),
the backend client secret, or setting `API_PROTECT_LOGS_ENABLED: false`:

```bash
NEW_OVERLAY=/etc/padsign/overlay/$(date +%Y%m%d)-rotate
cp -a "$OVERLAY" "$NEW_OVERLAY"
umask 077; openssl rand -hex 32 > "$BACKUP/register_pdf_api_key.new"     # the value never touches argv or history
python3 - "$NEW_OVERLAY/files/config/config.js" "$BACKUP/register_pdf_api_key.new" <<'PY'
import re, sys
path, value = sys.argv[1], open(sys.argv[2]).read().strip()
text = open(path).read()
new, n = re.subn(r'(REGISTER_PDF_API_KEY\s*:\s*")[^"]*(")', lambda m: m.group(1) + value + m.group(2), text)
assert n == 1, "field not found exactly once"
open(path, "w").write(new)
print("REGISTER_PDF_API_KEY updated")
PY
cd "$NEW"
./installation-scripts/overlay.sh rehash --overlay "$NEW_OVERLAY"
./installation-scripts/overlay.sh apply  --overlay "$NEW_OVERLAY" --force   # re-apply onto the same checkout
./installation-scripts/overlay.sh verify --overlay "$NEW_OVERLAY"
docker compose restart ps-server                                          # config.js is read once at start
shred -u "$BACKUP/register_pdf_api_key.new"                               # after it is in the secret manager / sent to integrators
```

`OVERLAY=$NEW_OVERLAY` from here on. Roll back by applying the previous
overlay with `--force` and restarting ps-server.

## Moving Keycloak to the release's version

This applies only if gate G1 (42.1) kept the host's Keycloak through a
`keycloak:` image entry in `compose.overlay.yml`. Before you start, 42.2 K4b
must print `AUDIENCE-MAPPER-PRESENT` from `$NEW`. Without the mapper, every
portal API call returns `401` on the new Keycloak.

It needs a short window. Keycloak restarts, which took about 15-25 s in the
rehearsals, and API calls fail during that time. Users stay signed in.

```bash
NEW_OVERLAY=/etc/padsign/overlay/$(date +%Y%m%d)-keycloak
cp -a "$OVERLAY" "$NEW_OVERLAY"
"${EDITOR:-vi}" "$NEW_OVERLAY/compose.overlay.yml"          # delete the keycloak: entry (its image override)
cd "$NEW"
./installation-scripts/overlay.sh apply  --overlay "$NEW_OVERLAY" --force   # points COMPOSE_FILE at the new overlay
./installation-scripts/overlay.sh verify --overlay "$NEW_OVERLAY"
docker compose config --images | grep keycloak                             # now the release's pinned image
docker compose pull keycloak
# --- window starts ---
docker compose stop keycloak
TAR_IMG="$(docker compose config --images | grep -m1 '^nginx')"
docker run --rm -v "$KC_VOLUME":/v:ro -v "$BACKUP":/b "$TAR_IMG" \
  tar czf "/b/keycloak_data-$(date -u +%Y%m%dT%H%M%SZ).tgz" -C /v .
sha256sum "$BACKUP"/keycloak_data-*.tgz | tail -n 1 | tee "$EVID/KC-move-backup.sha256"
docker compose up -d keycloak
until docker compose exec -T keycloak bash -c 'echo > /dev/tcp/localhost/8080' 2>/dev/null; do sleep 3; done
 read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD      # from the secret manager
./installation-scripts/postdeploy-check.sh --host "$HOST" --company-role "$ROLE" 2>&1 | tee "$EVID/KC-move-postdeploy.log"
```

- **Check:** `postdeploy-check.sh` passes, including `OK   padsign-client access tokens carry padsign-backend in aud (token introspection)`. `docker compose logs keycloak | grep -m1 'Updating database'` shows the in-place database upgrade (42.1 G1). A 42.2 K5 smoke login loads the portal with no `401`.
- **Rollback:** the previous overlay plus the backup you just took. Stop Keycloak and restore that backup with 42.5 R4, but check it against `KC-move-backup.sha256` rather than the C4 file. Then `overlay.sh apply --overlay "$OVERLAY" --force` and `docker compose up -d keycloak`. Starting the old image on the upgraded database without the restore is not supported (42.1 G1).
- **Evidence:** the backup checksum, `KC-move-postdeploy.log`, and `OVERLAY=$NEW_OVERLAY` recorded in the ticket.

## Moving the DMSS fallback archive to the release's version

This applies if `compose.overlay.yml` kept the host's older
`dmss-archive-services-fallback` image, for example 24.0.5, and the host now
moves to the release's (24.1.7). The two run as different users: 24.0.5 as
999:1000 (`spring`), 24.1.7 as 10001:10001. The archive under `$DOCS`
belongs to the old uid, so 24.1.7 cannot write into it, and every document
that falls back to it fails. Re-own the tree before 24.1.7 starts, and not
earlier: a re-own while 24.0.5 still runs stops that one from writing.

When the move comes with a cut-over to a new checkout, 42.4 C2 and C4 already
do this (C4 re-owns `$DOCS` once the old stack has stopped), and 42.5 R3 has
the reverse. This section is for moving later, as an overlay change on the
checkout that is running. It needs a short window: the fallback archive is
down from the `stop` until the new container reports healthy.

```bash
NEW_OVERLAY=/etc/padsign/overlay/$(date +%Y%m%d)-dmss-fallback
cp -a "$OVERLAY" "$NEW_OVERLAY"
"${EDITOR:-vi}" "$NEW_OVERLAY/compose.overlay.yml"     # delete dmss-archive-services-fallback's image: line; KEEP its /docs volume
"${EDITOR:-vi}" "$NEW_OVERLAY/approved-digests.json"   # delete that image's entry, now unused
cd "$NEW"
DOCS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["storage"]["/docs"]["source"])' "$NEW_OVERLAY/MANIFEST.json")"
img_ids() { docker run --rm --entrypoint sh "$1" -c 'echo "$(id -u):$(id -g)"'; }
OLD_FB_IDS="$(img_ids "$(docker inspect -f '{{.Config.Image}}' dmss-archive-services-fallback)")"   # the running (old) one
./installation-scripts/overlay.sh apply  --overlay "$NEW_OVERLAY" --force
./installation-scripts/overlay.sh verify --overlay "$NEW_OVERLAY"
FB_IMG="$(docker compose config --images | grep dmss-archive-services-fallback)"   # now the release's pinned image
docker compose pull dmss-archive-services-fallback
FB_IDS="$(img_ids "$FB_IMG")"
echo "running $OLD_FB_IDS, release's $FB_IDS" | tee "$EVID/DMSS-move-ids.txt"
stat -c '%a %u:%g %n' "$DOCS" | tee "$EVID/DMSS-move-docs-before.txt"
# --- window starts: the fallback archive is down ---
docker compose stop dmss-archive-services-fallback
[ "$FB_IDS" = "$OLD_FB_IDS" ] || sudo chown -R "$FB_IDS" "$DOCS"
sudo chmod 770 "$DOCS"
docker compose up -d dmss-archive-services-fallback
until [ "$(docker inspect -f '{{.State.Health.Status}}' dmss-archive-services-fallback)" = healthy ]; do sleep 5; done
# --- window ends ---
stat -c '%a %u:%g %n' "$DOCS" | tee "$EVID/DMSS-move-docs-after.txt"
```

- **Check:** `DMSS-move-docs-after.txt` shows `770 10001:10001` (or whatever `FB_IDS` says). `./installation-scripts/validate-config.sh --host "$HOST"` prints `OK   docs directory owned by 10001:10001 (the user trustlynx/dmss-archive-services-fallback:24.1.7@sha256:... runs as)`. `docker compose logs --since 10m dmss-archive-services-fallback 2>&1 | grep -ci 'permission denied'` prints 0. The C5 storage-integrity check (42.4) still reports 0.
- **Rollback:** stop the fallback, give the tree back to the old uid, and start the previous overlay's image: `docker compose stop dmss-archive-services-fallback && sudo chown -R "$OLD_FB_IDS" "$DOCS"`, then `overlay.sh apply --overlay "$OVERLAY" --force` and `docker compose up -d dmss-archive-services-fallback`. This re-owns what 24.1.7 wrote in the meantime too. Whether 24.0.5 reads documents 24.1.7 wrote has not been rehearsed.
- **Evidence:** the three `DMSS-move-*` files, and `OVERLAY=$NEW_OVERLAY` recorded in the ticket.

## Certificate renewal

`renew-cert.sh` writes `nginx/certs/` in the checkout. On an overlay-managed
host, also refresh the overlay, or the next `apply` would reinstall the old
certificate:

```bash
./installation-scripts/renew-cert.sh --host "$HOST" --cert-crt <crt> --cert-key <key>
./installation-scripts/overlay.sh capture --from "$NEW" --baseline "$TAG" --out /etc/padsign/overlay/$(date +%Y%m%d)-cert
```

Re-capturing from the overlay-managed checkout itself was tested: it carries
over the `compose.overlay.yml` already in effect, the overrides, the project
name and the storage mounts, and picks up the new certificate. The same
re-capture works after `toggle-features.sh` or `update-hostname.sh`. An
automated renewer that writes into `nginx/certs/` has the same effect as
`renew-cert.sh`: re-capture after each renewal, or point the renewer at the
overlay's `certs/` and re-apply.

## Rebuilding the host (disaster recovery)

What you need:

- the tag;
- the overlay directory (its backup, 42.3 O5);
- the latest Keycloak volume backup (42.4 C4, or your regular backups);
- the signed-document storage backup.

```bash
git clone --branch "$TAG" <repo-url> "$NEW" && cd "$NEW"
# 1. storage back to the paths the overlay mounts (MANIFEST.json "storage")
sudo mkdir -p "$(dirname "$SIGNED")" && sudo tar xzf <storage-backup.tgz> -C "$(dirname "$SIGNED")"
# 2. Keycloak volume, with compose's own labels so compose adopts it
docker volume create --label com.docker.compose.project="$PROJECT" --label com.docker.compose.volume=keycloak_data "$KC_VOLUME"
docker run --rm -v "$KC_VOLUME":/v -v <dir-with-backup>:/b:ro <image with tar> tar xzf /b/<keycloak_data-*.tgz> -C /v
# 3. overlay, verify, start
./installation-scripts/overlay.sh apply  --overlay "$OVERLAY"
./installation-scripts/overlay.sh verify --overlay "$OVERLAY"
docker compose up -d
```

Rehearsed: containers, network, Keycloak volume and both checkouts were
deleted, then rebuilt with exactly these steps. **Zero files were edited by
hand.** The realm and its users came back, and the signed documents (as read
by the real ps-server image) and the fallback archive were byte-identical.
This is the "fresh host from a tagged baseline plus the environment overlay,
with no manual file edits" acceptance check. Repeat it once on a real
spare host before you rely on it.

## Backups and retention

| Item | Where | Sensitive | Suggested retention (the owner decides) |
|---|---|---|---|
| Overlay directories | `/etc/padsign/overlay/*` + its off-host backup | yes: config secrets, TLS key | current + previous release's |
| Keycloak volume tarballs | `$BACKUP` | yes: realm, client secrets, password hashes | until the next successful release + 30 days |
| Old deployment-dir archive (42.4 C7) | `$BACKUP` | yes | same |
| Storage fingerprint manifests | `$BACKUP` | personal data in file names | same as the change record |
| `.bak` files, `.rollback-snapshots/` | should not exist on an overlay-managed checkout | yes | `verify` warns if they appear inside the checkout |
