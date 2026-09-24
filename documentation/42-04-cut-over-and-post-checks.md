# 42.4 Cut-over and post-checks (#7)

C1-C3 change nothing that is running. The interruption is C4 only: the
application and Keycloak are unavailable for roughly 1-3 minutes, and about
1 minute more if the 42.2 K2 break-glass rides along. In the rehearsal, the
Keycloak part of the switch (stop, volume backup, start from the new checkout)
took about 40 s.

Set these from the capture output (42.3 O3):

```bash
PROJECT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["project_name"])' "$OVERLAY/MANIFEST.json")"
KC_VOLUME="${PROJECT}_keycloak_data"
SIGNED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["storage"]["/signed-output"]["source"])' "$OVERLAY/MANIFEST.json")"
DOCS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["storage"]["/docs"]["source"])' "$OVERLAY/MANIFEST.json")"
docker volume inspect "$KC_VOLUME" --format '{{.Name}} created {{.CreatedAt}}'   # must exist
```

## C1: apply the overlay onto the clean checkout

```bash
cd "$NEW"
./installation-scripts/overlay.sh apply --overlay "$OVERLAY" 2>&1 | tee "$EVID/C1-apply.log"; echo "exit=${PIPESTATUS[0]}"
git status --short | tee "$EVID/C1-git-status.txt"
```

- **Check:** `exit=0`. `git status` lists **only** the files `apply` printed (overlay overrides as `M`, overlay extra files as `??`). `.env`, the certificates and `.overlay-applied.json` are git-ignored and do not appear. `config/config.js` is now mode `0640` or tighter.
- If `apply` refuses with `the release changed ... since the overlay was captured`, the tag differs from the checkout you captured against. Re-run 42.3 O3 against this `$NEW`.
- **Rollback:** `rm -rf "$NEW"` and re-clone (42.3 O2). Nothing live changed.
- **Evidence:** `C1-apply.log`, `C1-git-status.txt` (paths only).

## C2: least-privilege storage permissions, in place

The documents stay where they are. Only permission bits change, never
content.

```bash
stat -c '%a %U:%G %n' "$SIGNED" "$DOCS" | tee "$EVID/C2-storage-modes-before.txt"
FALLBACK_IMG="$(cd "$NEW" && docker compose config --images | grep dmss-archive-services-fallback)"
SPRING_GID="$(docker run --rm --entrypoint id "$FALLBACK_IMG" -g spring)"; echo "spring gid=$SPRING_GID"
sudo chmod 750 "$SIGNED"                       # ps-server runs as root; nobody else needs access
sudo chgrp "$SPRING_GID" "$DOCS" && sudo chmod 770 "$DOCS"   # fallback archive runs as uid 999 / gid spring
sudo find "$SIGNED" "$DOCS" -perm -0002 ! -type l -exec chmod o-w {} +   # no world-writable entries left inside
stat -c '%a %U:%G %n' "$SIGNED" "$DOCS" | tee "$EVID/C2-storage-modes-after.txt"
sudo find "$SIGNED" "$DOCS" -perm -0002 ! -type l | wc -l      # 0
```

These are the same modes `installation-scripts/lib/dir-permissions.sh` sets on
new deployments. Its header explains why each is enough.

- **Check:** the old stack keeps writing, since it is still running. Watch for 5 minutes: `cd "$OLD" && docker compose logs --since 5m dmss-archive-services-fallback ps-server 2>&1 | grep -ci 'permission denied'` must print 0.
- **Rollback:** `sudo chmod <mode from C2-storage-modes-before.txt> "$SIGNED" "$DOCS"`, only if a service really cannot write.
- **Evidence:** the two mode files.

## C3: verify before touching anything live

```bash
cd "$NEW"
./installation-scripts/overlay.sh verify --overlay "$OVERLAY" --live "$OLD" 2>&1 | tee "$EVID/C3-verify.log"; echo "exit=${PIPESTATUS[0]}"
./installation-scripts/validate-config.sh --host "$HOST" 2>&1 | tee "$EVID/C3-validate-config.log"; echo "exit=${PIPESTATUS[0]}"
docker compose pull 2>&1 | tail -3                   # pre-pull every image; running containers are untouched
```

- **Check `verify`:** `RESULT: OK`. It fails on:
  - a git-visible change the overlay does not declare;
  - a compose project name that would start Keycloak on an empty volume;
  - a missing Keycloak volume;
  - storage mounts that are not the existing documents, or that are world-writable;
  - unresolved merge conflicts.

  Every `WARN` under *Effective model vs the running host* is a behaviour
  change the cut-over would introduce. Each one must be ported (42.3 O4) or
  recorded as intentional.
- **Check gate G1:** `K-log.txt` has `K4b: audience mapper -> present|created` (42.2 K4b). The exception is when G1 chose to keep the host's current Keycloak through the overlay. Without the mapper, the release's Keycloak rejects every portal API call after C4.
- **Check `validate-config`:** `All checks passed.`
  - It now reads the **effective** compose model (release file + overlay), so the port-binding check covers overlay-published ports too.
  - `Secret hygiene` WARN lines ("still the value shipped in the public repository") are 42.2 K6 work. They don't block the cut-over, but they do block sign-off.
- **Rollback:** nothing to roll back.
- **Evidence:** both logs, which print field names and paths, never values.

## C4: the cut-over (maintenance window, interruption starts)

```bash
date -u +%FT%TZ | tee "$EVID/C4-window-start.txt"
(cd "$OLD" && docker compose stop)                                   # whole old stack, Keycloak included
TAR_IMG="$(cd "$NEW" && docker compose config --images | grep -m1 '^nginx')"   # any local image that has tar
docker run --rm -v "$KC_VOLUME":/v:ro -v "$BACKUP":/b "$TAR_IMG" \
  tar czf "/b/keycloak_data-$(date -u +%Y%m%dT%H%M%SZ).tgz" -C /v .
sha256sum "$BACKUP"/keycloak_data-*.tgz | tee "$EVID/C4-keycloak-backup.sha256"
# --- optional: 42.2 K2 break-glass goes HERE, run from "$NEW" (Keycloak is already stopped) ---
cd "$NEW" && docker compose up -d
for i in $(seq 1 60); do
  pending="$(docker compose ps --format '{{.Service}} {{.Health}}' | awk '$2!="" && $2!="healthy"' | wc -l)"
  [ "$pending" = 0 ] && break; sleep 5
done
docker compose ps --format '{{.Service}} {{.Status}} {{.Health}}' | tee "$EVID/C4-compose-ps.txt"
date -u +%FT%TZ | tee "$EVID/C4-window-end.txt"
```

- **Check:**
  - Every service with a health check reports `healthy`.
  - `docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$(docker compose ps -q keycloak)"` prints `$NEW`.
  - `docker volume ls | grep keycloak_data` shows **only** `$KC_VOLUME`: no second, empty volume was created.
- **Rollback:** 42.5 R3. Stop from `$NEW` and start from `$OLD`. That needs the same project, volume and storage, so it takes minutes.
- **Evidence:** window start/end, backup checksum (the tarball stays in `$BACKUP`: it contains the realm, the client secrets and password hashes), `C4-compose-ps.txt`.

## C5: post-checks (interruption over)

```bash
cd "$NEW"
 read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD      # from the secret manager
./installation-scripts/postdeploy-check.sh --host "$HOST" --company-role "$ROLE" 2>&1 | tee "$EVID/C5-postdeploy.log"; echo "exit=${PIPESTATUS[0]}"
cp deployment-evidence.json "$EVID/C5-deployment-evidence.json"
./installation-scripts/overlay.sh verify --overlay "$OVERLAY" 2>&1 | tee "$EVID/C5-verify.log"
./installation-scripts/monitor-status.sh --host "$HOST" 2>&1 | tee "$EVID/C5-monitor-status.log"
```

Then:

1. **Browser smoke test, twice:** 42.2 K5, both runs. It proves real browser
   login, role mapping and API calls (no `401` after login) on the new checkout.
   `C5-postdeploy.log` must also contain `OK   padsign-client access tokens carry
   padsign-backend in aud (token introspection)` (gate G1).
2. **External stamping:** run one signing flow that e-seals (19.2), or at
   least check `C5-monitor-status.log`'s stamping failure count. Also check
   `docker compose logs --since 30m ps-server | grep -ciE 'stamp.*(error|fail)'`, which should be 0.
3. **Routing:** if the filesystem strategy is on, the signed document from
   step 2 appears under `$SIGNED` along the configured `pathTemplate`. If a
   webhook strategy is on, the receiving system confirms delivery.
4. **Certificate:** `postdeploy-check.sh` ran `verify-served-cert.sh`. The
   served fingerprint equals `openssl x509 -in nginx/certs/$HOST.crt -noout -fingerprint -sha256`.
5. **Storage untouched:** no existing document changed or disappeared. New
   ones may have appeared.

```bash
for pair in "signed-output:$SIGNED" "docs:$DOCS"; do
  name="${pair%%:*}"; dir="${pair#*:}"
  fingerprint "$dir" > "$BACKUP/C5-$name.sha256"          # fingerprint(): defined in 42.1 Step 0
  echo "$name: $(comm -23 <(sort "$BACKUP/00-$name.sha256") <(sort "$BACKUP/C5-$name.sha256") | wc -l) pre-existing file(s) changed or missing"
done | tee "$EVID/C5-storage-integrity.txt"                         # both must say 0
```

- **Rollback:** any failed check → 42.5 R3.
- **Evidence:** every file named above. `deployment-evidence.json` records:
  - the source revision (`deployment_repo.revision` = the tag's commit), plus `modified_tracked_files` = exactly the overlay's files;
  - the running image digests;
  - sha256 of `config.js`, `constants.json`, `nginx.conf`, `docker-compose.yml`, every DMSS `application.yml` and `compose.overlay.yml`;
  - `compose_files` in effect, and `overlay` (directory, MANIFEST checksum, baseline commit).

## C6: observation period

Keep `$OLD` exactly as it is for an agreed period (for example 72 hours):
it is the instant-rollback target. Run `monitor-status.sh` daily, and add the
output to the evidence.

## C7: decommission the old working tree (storage stays)

After the observation period, remove the old checkout's secrets and
operational backups from disk. **The storage directories stay where they are:
the new checkout mounts them.**

```bash
cd "$OLD"
ls -A | grep -vxE 'signed-output|docs'                          # review what will be archived and removed
sudo tar --exclude=./signed-output --exclude=./docs -czf "$BACKUP/old-deployment-dir.tgz" .
sudo chmod 600 "$BACKUP/old-deployment-dir.tgz"; sha256sum "$BACKUP/old-deployment-dir.tgz" >> "$EVID/C7-archive.sha256"
sudo find "$OLD" -mindepth 1 -maxdepth 1 ! -name signed-output ! -name docs -exec rm -rf -- {} +
ls -A "$OLD"                                                     # only: docs signed-output
```

- **Check:** `ls -A "$OLD"` shows only the two storage directories, and the C5 storage-integrity check still reports 0.
- **Rollback:** `sudo tar xzf "$BACKUP/old-deployment-dir.tgz" -C "$OLD"` restores the old checkout. Then use 42.5 R3.
- **Evidence:** archive checksum. The retention period for `$BACKUP` is the one decided in 42.1.

Moving the storage itself somewhere outside `/opt` (for example
`/srv/padsign/`) is a separate, later change. It needs ps-server and the
fallback archive stopped for the move, and a new overlay capture afterwards.
It is deliberately not part of this migration, which does not touch the
documents at all.
