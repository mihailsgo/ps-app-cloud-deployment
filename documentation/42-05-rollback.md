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
| 42.2 K3 | admin password changed | set it back from the secret manager's previous version (same `reset-password` command) | none |
| 42.2 K4b | the `padsign-backend-audience` mapper on `padsign-client` | not needed: harmless on every Keycloak version. To remove it anyway, see 42.2 K4b | none |
| 42.2 K5 | one smoke user at a time | `smoke-user.sh delete` (idempotent) | none |
| 42.2 K6 | `test` user deleted / secrets rotated | recreate `test` with `keycloak-bootstrap.sh` (**rotates its password**); for rotated secrets, 42.6 with the previous value | none / ps-server restart |
| 42.4 C1 | files inside `$NEW` only | `rm -rf "$NEW"`, re-clone | none |
| 42.4 C2 | permission bits on the storage directories | `sudo chmod <mode from C2-storage-modes-before.txt>` | none |
| 42.4 C4/C5 | containers now run from `$NEW` | **R3**, plus **R4** if the cut-over moved Keycloak to the release's version (gate G1) | 1-3 min |
| 42.4 C7 | old working tree archived and removed | `sudo tar xzf "$BACKUP/old-deployment-dir.tgz" -C "$OLD"`, then **R3** | 1-3 min |

## R3: switch back to the old directory

```bash
date -u +%FT%TZ | tee "$EVID/R3-start.txt"
(cd "$NEW" && docker compose stop)
# Only if C4 re-owned docs/ for a fallback image with another uid (42.4 C2):
[ "$FB_IDS" = "$OLD_FB_IDS" ] || sudo chown -R "$OLD_FB_IDS" "$DOCS"
(cd "$OLD" && docker compose up -d)
# The old stack may predate the health checks: nginx and ps-server then start
# before container-signature is ready. Wait for it before anyone signs.
cs_up=no
for i in $(seq 1 60); do
  if grep -q '"status":"UP"' < <(cd "$OLD" && docker compose exec -T dmss-container-and-signature-services \
       curl -sf http://localhost:8092/actuator/health </dev/null 2>/dev/null); then cs_up=yes; break; fi
  sleep 10
done
echo "container-signature actuator UP: ${cs_up} at $(date -u +%FT%TZ)" | tee "$EVID/R3-container-signature.txt"
sleep 35   # one ps-server circuit-breaker cooldown (DEPENDENCY_CB_COOLDOWN_MS, 30 s by default)
(cd "$OLD" && docker compose ps --format '{{.Service}} {{.Status}} {{.Health}}') | tee "$EVID/R3-compose-ps.txt"
date -u +%FT%TZ | tee "$EVID/R3-end.txt"
```

Rehearsed twice: forward → back → forward. The realm and its users were
intact after every switch, and the storage fingerprints were unchanged.

- **Check:**
  - all services `Up`, and `healthy` where a health check exists;
  - `R3-container-signature.txt` says `UP: yes`, and the `sleep 35` after it
    has run. Do not declare the rollback done, or run a smoke sign, before
    that. `UP: no` after the 10 minutes the loop waits: see
    `docker compose logs dmss-container-and-signature-services` (from `$OLD`);
  - `docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$(cd "$OLD" && docker compose ps -q ps-server)"` prints `$OLD`. Check ps-server, not Keycloak: 42.4 C4 explains why Keycloak's label can keep naming the other directory;
  - a smoke login works (42.2 K5);
  - the storage-integrity check (42.4 C5) reports 0.

**Why the wait.** A stack from before the release's health checks (and their
`depends_on: condition: service_healthy`) starts nginx and ps-server as soon
as their containers exist. container-signature needs minutes to boot, so the
first signing attempts return `502`. After `DEPENDENCY_CB_FAILURE_THRESHOLD`
(5) failures in a row, ps-server's circuit breaker for container-signature
opens: for `DEPENDENCY_CB_COOLDOWN_MS` (30 s) it answers
`VISUAL_SIGNATURE_CIRCUIT_OPEN` without trying, then lets one request
through. That request closes the breaker if it succeeds and opens it for
another 30 s if it fails, so the breaker keeps reopening until
container-signature is up. On the demo host, a rollback to
container-signature 24.3.0.49.2 took 3 min 33 s to report `UP` on its
actuator, and signing failed for about 3.5 minutes. The loop waits for `UP`,
and the `sleep 35` outlasts a cooldown that started just before it, so the
next signing request is let through and succeeds. If `config/config.js` on
`$OLD` sets another `DEPENDENCY_CB_COOLDOWN_MS`, sleep that long plus a few
seconds instead. The stacks of this release have the health checks, so a
cut-over to them (42.4 C4) waits for container-signature by itself.
- **What it does not undo:** Keycloak changes made while the new checkout ran (users, roles, the K3 password). They live in the shared volume, which is what you want. If you must undo those too, use R4. After a Keycloak version move, R4 is required anyway (next point), and it undoes them.
- **Keycloak version:** R3 alone is enough only if the cut-over kept the
  host's Keycloak version (gate G1). The recommended default moves the host
  to the release's Keycloak. Its first start upgrades the Keycloak database in
  place. In the G1 rehearsal, 26.3.2 still started on a volume that 26.7.4 had
  migrated, but it warned `Possibly incorrect state of migration`, and
  Keycloak does not support downgrades. So after a Keycloak move, R3 needs
  **R4** as well. Restore the C4 backup, which was taken before the new
  Keycloak's first start, before `(cd "$OLD" && docker compose up -d)`.
  The audience mapper from 42.2 K4b is in that backup too, because K4b ran
  before C4.

## R4: restore the Keycloak volume from the C4 backup

Loses every Keycloak change made after the backup (new users, password
changes, sessions). Use it when Keycloak cannot start, when its data is wrong, or
when R3 follows a cut-over that moved Keycloak to a newer version (gate G1).

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
