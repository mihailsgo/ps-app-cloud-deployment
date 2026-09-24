# 42.1 Before you start

## Decide these first (write them in the change ticket)

| Input | Example | Who decides |
|---|---|---|
| Change / ticket id | `CHG-1234` | operator |
| Maintenance window for the cut-over (Keycloak and the app are unavailable for roughly 1-3 minutes) | low-traffic hour, announced to users | service owner |
| Release tag to use as the baseline | `v1.0.26` | release owner (see gate G2) |
| **Keycloak admin credential owner** (a named person or role, not "ops") | | service owner |
| **Where the admin credential is stored** (your approved password manager or vault entry) | `vault: padsign/<env>/keycloak-admin` | security owner |
| Backup location and retention for this change | `/var/backups/padsign/CHG-1234`, keep 30 days after the next successful release | service owner |

This repository does not choose a secret manager or a retention period. Those
are yours. The runbook only needs to know where the credential goes, and
never needs the value.

## Shell variables used throughout

Set these once per shell. Nothing secret goes into them.

```bash
HOST=padsign.example.com                    # the public hostname
OLD=/opt/psapp                              # the directory the stack runs from TODAY
TAG=v1.0.26                                 # the release tag chosen as baseline (gate G2)
NEW=/opt/padsign/releases/$TAG              # fresh checkout of $TAG (created in 42.3)
OVERLAY=/etc/padsign/overlay/$(date +%Y%m%d) # created by `overlay.sh capture`; outside every checkout
EVID=/var/lib/padsign/evidence/CHG-1234     # evidence bundle (42.7)
BACKUP=/var/backups/padsign/CHG-1234        # SENSITIVE backups: Keycloak volume, moved .bak files
ROLE="Your Company"                         # the configured company role (see 42.2 K5 to list roles)
export HISTCONTROL=ignorespace              # a command typed with a leading space stays out of history

sudo install -d -m 700 -o "$USER" -g "$USER" "$EVID" "$BACKUP" "$(dirname "$OVERLAY")"
```

The user running this needs Docker access on the host (the `docker` group)
and `sudo` for `/etc`, `/var` and the `chgrp` in 42.4 C2.

## Step 0: read-only inventory (no interruption)

Record what is there before anything changes. Every command is read-only.

```bash
cd "$OLD"
{ date -u; hostname; docker version --format 'engine {{.Server.Version}}'; docker compose version; } > "$EVID/00-host.txt"
(git rev-parse HEAD && git status --porcelain) > "$EVID/00-old-git.txt" 2>&1 || echo "not a git checkout" > "$EVID/00-old-git.txt"
docker compose ps --format '{{.Service}} {{.Status}} {{.Health}}' > "$EVID/00-compose-ps.txt"
for c in $(docker compose ps -q); do
  docker inspect --format '{{.Name}} {{.Config.Image}} {{.Image}} project={{index .Config.Labels "com.docker.compose.project"}} restarts={{.RestartCount}}' "$c"
done > "$EVID/00-running-images.txt"
docker volume ls --format '{{.Name}}' | grep keycloak_data > "$EVID/00-keycloak-volume.txt"
sha256sum config/config.js config/constants.json nginx/nginx.conf docker-compose.yml dmss-*/application.yml > "$EVID/00-old-config.sha256" 2>/dev/null
stat -c '%a %U:%G %n' config/config.js .env nginx/certs/* signed-output docs 2>/dev/null > "$EVID/00-modes.txt"
find "$OLD" -xdev -perm -0002 ! -type l -printf '%m %p\n' 2>/dev/null > "$EVID/00-world-writable.txt"
find "$OLD" -xdev \( -name '*.bak*' -o -name '*.orig' -o -name 'retired-*' \) -printf '%m %s %p\n' 2>/dev/null > "$EVID/00-backups-in-tree.txt"
```

Signed-document storage: take a content fingerprint so you can prove later
that nothing changed it. The file **names** can contain personal data
(DOCUMENT_ROUTING's default `pathTemplate` includes the signer's email), so the
manifest goes to `$BACKUP`. Only its checksum and counts go into the evidence:

```bash
fingerprint() { sudo sh -c 'cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum' _ "$1"; }
for d in signed-output docs; do
  fingerprint "$OLD/$d" > "$BACKUP/00-$d.sha256"
  printf '%s files=%s manifest_sha256=%s\n' "$d" "$(wc -l < "$BACKUP/00-$d.sha256")" "$(sha256sum < "$BACKUP/00-$d.sha256" | cut -c1-64)"
done > "$EVID/00-storage-fingerprint.txt"
```

If `signed-output/` or `docs/` is not directly under `$OLD` on your host (a
hand-edited compose can mount them from elsewhere), use the paths
`overlay.sh capture` reports in 42.3. It reads them from the effective compose
model.

Leak sweep (counts only; nothing printed):

```bash
grep -cE -- '--admin-pass|--backend-secret|KEYCLOAK_ADMIN_PASSWORD=|RECOVERY_PW=' ~/.bash_history 2>/dev/null
sudo sh -c "grep -cE -- '--admin-pass|--backend-secret|KEYCLOAK_ADMIN_PASSWORD=' /root/.bash_history" 2>/dev/null
docker compose logs ps-server 2>&1 | grep -c '\[apiProtect\] Bearer token'   # >0: bearer tokens were logged
grep -nE '^\s*API_PROTECT_LOGS_ENABLED' config/config.js
```

Any non-zero count is a finding for 42.2 K6. Bearer tokens expire within
minutes, but the log lines stay until the ps-server container is recreated
(the cut-over does that). The passwords in shell history must be rotated.

## Go / no-go gates

**G1: Keycloak version and the token audience mapper.** Check which Keycloak
the chosen release pins and which one the host runs:

```bash
git -C "$NEW" show "$TAG":docker-compose.yml 2>/dev/null | grep -oE 'keycloak/keycloak:[0-9.]+'   # after 42.3 O2
grep keycloak "$EVID/00-running-images.txt"
```

The repository pins `quay.io/keycloak/keycloak:26.7.4`. Moving the host onto
it during the cut-over is fine, **provided the realm has the
`padsign-backend-audience` mapper first**:

- Keycloak 26.4.12, 26.6.2, 26.7.0 and later answer ps-server's token
  introspection only when `padsign-backend` is in the token's audience.
- Without the mapper, the portal login works but every API call returns
  `401`, and Keycloak logs `Client 'padsign-backend' is not in the token
  audience`.
- Current releases handle this automatically. `keycloak-bootstrap.sh` creates
  the mapper in new realms, and `upgrade.sh`'s `keycloak-backend-audience`
  migration adds it to existing ones
  ([14.8](14-08-token-audience-for-introspection.md)).
- An overlay-managed host never runs `upgrade.sh` for real (42.6), so you add
  and confirm the mapper by hand in **42.2 K4b**, on the Keycloak the host runs
  today.
- Older Keycloak ignores the mapper, so adding it early changes nothing for
  users.

**Go** when K4b prints `AUDIENCE-MAPPER-PRESENT`. After the cut-over, 42.4 C5
confirms it again through `verify-keycloak.sh`.

If K1 fails, admin access only comes back through the K2 break-glass inside
the cut-over window. Then K4b cannot run before the cut-over. In that case,
keep the host's current Keycloak for this cut-over (see the end of this gate)
and move Keycloak afterwards as its own change, once K4b is done.

Moving to the pinned Keycloak is the recommended default. Staying on an older
26.x keeps the host exposed to CVE-2026-37979 and the other CVEs fixed in
26.6.2 (14.8). The caution that remains is **rollback**. The first start of
26.7.4 on the host's existing Keycloak database upgrades that database in
place. A rehearsal on a throwaway `start-dev` (H2) volume created on 26.3.2
showed:

- **Forward (26.3.2 → 26.7.4):** Keycloak logged `Updating database`, then
  migrated the realm model to 26.4.0, 26.4.3 and 26.6.1. The realm and its
  users were intact.
- **Back (26.7.4 → 26.3.2):** 26.3.2 still started on the migrated volume, and
  the data was readable. But it warned `Possibly incorrect state of migration.
  You are trying to run server version '26.3.2' against database, which was
  already migrated to newer version '26.7.4'`. Keycloak does not support
  downgrades, so do not rely on that.

That rehearsal used this repository's default H2 database. A host on an
external database has not been rehearsed (see G3).

So if you move Keycloak in the cut-over, a rollback to the old directory
(42.5 R3) must also restore the Keycloak volume backup taken in 42.4 C4
(42.5 R4). That restore loses every Keycloak change made since the backup. The
C4 backup is taken after the old Keycloak stops and before the new one first
starts, so it is always a clean pre-upgrade copy. If you want the first
cut-over to keep R3 as a plain directory switch, keep the host's current
Keycloak image through the overlay (42.3 O4). Then move Keycloak soon after as
its own change (42.6), with K4b already done. Record the choice in the ticket.

**G2: application versions.** The migration should change *where the
configuration lives*, not *what runs*. Compare the ps-server/ps-client
versions the tag pins with the running ones (`00-running-images.txt`). If
they differ, ask the release owner for a tag whose `docker-compose.yml` pins
the host's current versions (a normal release commit per
[39. Release Procedure](39-release-procedure.md)), and upgrade later with
42.6. Never override `mihailsgordijenko/ps-server` or `ps-client` in the
overlay, or the next upgrade would silently change nothing.

**G3: Keycloak database mode.** The break-glass path in 42.2 depends on it:

```bash
docker compose exec -T keycloak sh -c 'echo "KC_DB=${KC_DB:-dev-file (H2)}"'; grep -n 'command:' docker-compose.yml | head -3
```

`start-dev` / H2 (this repository's default) means `bootstrap-admin` needs
Keycloak stopped (verified). An external database changes that analysis, and
this runbook has not rehearsed it.

**G4: storage and volumes are identified.** You know the Keycloak volume name
(`00-keycloak-volume.txt`) and the absolute paths of `signed-output` and
`docs`.
