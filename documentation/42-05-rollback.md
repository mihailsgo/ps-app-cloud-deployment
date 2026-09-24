# 42.5 Rollback

Two properties make every rollback here short and data-safe:

- **The old directory is left intact** until 42.4 C7. It still has its own
  compose file, config and certificates, and it uses the **same** compose
  project name, Keycloak volume and signed-document directories as the new
  checkout.
- **Nothing in this runbook writes to signed-document storage** except the
  running application itself. C2 changes permission bits only. Rolling back
  never needs a document restore.

## Per-step rollback

| Step | What changed | Rollback | Interruption |
|---|---|---|---|
| 42.1 Step 0, 42.3 O1-O5 | nothing on the live stack (inventory files, a new checkout, the overlay directory) | `rm -rf "$NEW" "$OVERLAY"` if you abandon the change | none |
| 42.2 K1 | nothing | none | none |
| 42.2 K2 | one extra master-realm admin (`temp-admin`) in the Keycloak DB | delete `temp-admin` (42.2 K3). If Keycloak will not start → **R4** | Keycloak restart, ~1 min |
| 42.2 K3 | admin password changed | set it back from the secret manager's previous version (same `set-password` command) | none |
| 42.2 K5 | one smoke user at a time | `smoke-user.sh delete` (idempotent) | none |
| 42.2 K6 | `test` user deleted / secrets rotated | recreate `test` with `keycloak-bootstrap.sh` (**rotates its password**); for rotated secrets, 42.6 with the previous value | none / ps-server restart |
| 42.4 C1 | files inside `$NEW` only | `rm -rf "$NEW"`, re-clone | none |
| 42.4 C2 | permission bits on the storage directories | `sudo chmod <mode from C2-storage-modes-before.txt>` | none |
| 42.4 C4/C5 | containers now run from `$NEW` | **R3** | 1-3 min |
| 42.4 C7 | old working tree archived and removed | `sudo tar xzf "$BACKUP/old-deployment-dir.tgz" -C "$OLD"`, then **R3** | 1-3 min |

## R3: switch back to the old directory

```bash
date -u +%FT%TZ | tee "$EVID/R3-start.txt"
(cd "$NEW" && docker compose stop)
(cd "$OLD" && docker compose up -d)
(cd "$OLD" && docker compose ps --format '{{.Service}} {{.Status}} {{.Health}}') | tee "$EVID/R3-compose-ps.txt"
date -u +%FT%TZ | tee "$EVID/R3-end.txt"
```

Rehearsed twice: forward → back → forward. The realm and its users were
intact after every switch, and the storage fingerprints were unchanged.

- **Check:**
  - all services `Up`, and `healthy` where a health check exists;
  - `docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$(cd "$OLD" && docker compose ps -q keycloak)"` prints `$OLD`;
  - a smoke login works (42.2 K5);
  - the storage-integrity check (42.4 C5) reports 0.
- **What it does not undo:** Keycloak changes made while the new checkout ran (users, roles, the K3 password). They live in the shared volume, which is what you want. If you must undo those too, use R4.
- **Keycloak version:** R3 is only this simple because the overlay keeps the
  host's Keycloak version (gate G1). If you deliberately moved Keycloak to a
  newer version during the cut-over, its database schema may have been
  upgraded, and the old Keycloak may refuse it. Then R3 needs **R4**.

## R4: restore the Keycloak volume from the C4 backup

Loses every Keycloak change made after the backup (new users, password
changes, sessions). Use it only when Keycloak cannot start, or its data is wrong.

```bash
DIR="$OLD"      # or "$NEW": whichever directory you are rolling back TO
(cd "$DIR" && docker compose stop keycloak)
BK="$(ls -1 "$BACKUP"/keycloak_data-*.tgz | tail -n 1)"; sha256sum -c "$EVID/C4-keycloak-backup.sha256"
TAR_IMG="$(cd "$DIR" && docker compose config --images | grep -m1 '^nginx')"
docker run --rm -v "$KC_VOLUME":/v -v "$BACKUP":/b:ro "$TAR_IMG" \
  sh -c 'find /v -mindepth 1 -delete && tar xzf "/b/$1" -C /v' _ "$(basename "$BK")"
(cd "$DIR" && docker compose up -d keycloak)
```

- **Check:** the checksum verifies before the restore. Keycloak starts. The admin login from the secret manager works. The realm's users are the pre-cut-over set.
- The same restore, onto a freshly created volume, is the disaster-recovery rebuild in 42.6, which was rehearsed end-to-end.
