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
- Then cut over exactly as 42.4 C4-C5. Roll back with 42.5 R3, pointed at
  the previous release directory.
- Do **not** use `upgrade.sh` (without `--plan-only`), `rollback.sh` or the
  deployment wizard's *Upgrade* on an overlay-managed checkout. They rewrite
  tracked files in place. The previous directory is the rollback.

If `--plan-only` lists a pending migration, the overlay's copy of
`config.js` is missing something the release's scripts expect. Take it to
the release owner rather than hand-editing.

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
