# 9.11 Start at boot, backups and customized hosts

Three things every production host needs beyond the stack itself: a boot
hook that starts it after a reboot, backups you can rebuild from, and, on a
host whose configuration goes beyond what the scripts write, a way to keep
those customizations explicit so upgrades do not lose them.

## Starting the stack at boot

After a reboot Docker restarts containers by their `restart:` policy, in no
particular order and without the dependency waits of
[9.9](09-09-health-checks-and-startup.md). Every service uses
`restart: unless-stopped`, so any service stopped with `docker compose stop`
before the reboot stays down. Install one systemd unit that runs
`docker compose up -d` from the deployment directory at boot.

The unit ships as `installation-scripts/assets/padsign.service.example`:

```ini
[Unit]
Description=PadSign stack (docker compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/padsign
Type=oneshot
RemainAfterExit=yes
User=root
ExecStart=/bin/sh -c "for i in 1 2 3 4 5; do /usr/bin/docker compose up -d && exit 0; echo compose up attempt $i failed, retrying in 30s; sleep 30; done; exit 1"
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
```

Install and enable it:

```bash
cd /opt/padsign
sudo install -m 644 -o root -g root installation-scripts/assets/padsign.service.example /etc/systemd/system/padsign.service
sudo systemctl daemon-reload
sudo systemctl enable padsign.service
```

`enable` takes effect at the next boot; nothing starts or stops now. If
your deployment lives somewhere other than `/opt/padsign`, change
`WorkingDirectory` in the installed file.

Why it is written this way:

- **No `-f docker-compose.yml`.** An explicit `-f` makes compose ignore
  `COMPOSE_FILE` and `COMPOSE_PROFILES` in `.env`. The stack would start
  without local e-sealing's profile, and on a customized host without the
  overlay's storage mounts and image overrides.
- **`stop`, never `down`.** `down` removes the containers. Run against
  another directory with the same compose project name, for example an
  older release directory, it tears down the running stack. `stop` keeps the
  containers, and the next boot's `up -d` starts them.
- **Five attempts, and `TimeoutStartSec=0`.** On a cold boot every Java
  service starts at once. One that is slower than its health-check window
  makes `up -d` fail with `dependency failed to start: ... is unhealthy`
  and leaves nginx stopped. `up -d` itself waits for the dependencies, so a
  retry usually succeeds; `TimeoutStartSec=0` stops systemd from killing
  that wait.

Check:

```bash
systemctl is-enabled padsign.service          # enabled
systemctl cat padsign.service | grep -E '^(WorkingDirectory|Exec)'
```

The real proof is a planned reboot: afterwards every service is healthy,
nginx included, without anyone running `docker compose up -d`.

A host with another boot hook for the stack (an older unit, an
`@reboot` cron line, `/etc/rc.local`) must have only one. Disable the others,
and check that none runs `docker compose down -v`, which deletes the
Keycloak volume.

Cron jobs and timers that run this repository's scripts
(`monitor-status.sh`, `verify-served-cert.sh`, backups) start with
`cd /opt/padsign`, like the examples in [9.3](09-03-monitoring-the-served-certificate.md)
and [9.10](09-10-monitoring-and-alerting.md).

## Backups

What to back up, and why:

| Item | Where | Holds | Secret |
|---|---|---|---|
| `.env` | `/opt/padsign/.env` | Keycloak's first-boot admin password, `COMPOSE_PROFILES`, alert webhook URL | yes |
| `config/` | `/opt/padsign/config/` | `config.js` (backend client secret, API keys, session secret, e-sealing credentials, routing), `constants.json`, `keycloak.js`, logo | yes |
| nginx configuration and certificates | `nginx/nginx.conf`, `nginx/certs/` | hostname, TLS certificate and **private key** | yes |
| `docker-compose.yml` | `/opt/padsign/docker-compose.yml` | image pins, hostname, local e-sealing entries | no |
| DMSS configuration | `dmss-container-and-signature-services/`, `dmss-archive-services/`, `dmss-archive-services-fallback/`, and with local e-sealing `dmss-digital-stamping-service/` | the deployment's visual-PDF signing CA (`dmssrootca.p12`) and its password, signing profiles, your sealing keystore | yes |
| Keycloak data | Docker volume `<project>_keycloak_data` (mounted at `/opt/keycloak/data`) | realm, clients, users, password hashes | yes |
| Signed documents | `signed-output/` (ps-server's routing archive and receive-back buffer) and `docs/` (the fallback archive's store) | customer documents | personal data |
| Host-level state | `/etc/systemd/system/padsign.service`, your cron files and timers, certbot's `/etc/letsencrypt/` (with its `live/` symlinks), wrapper scripts and env files | how the host starts and renews | partly |

`.rollback-snapshots/`, `*.bak` and `deployment-evidence.json` are
working files of the scripts and need no separate backup; the evidence file
is useful for recording which revision you backed up. If you moved the
archive service's database off its default in-memory setting
(`dmss-archive-services/application.yml`), back up that database too.

A backup run, into a root-only directory:

```bash
cd /opt/padsign
BACKUP=/var/backups/padsign/$(date -u +%Y%m%dT%H%M%SZ)
sudo install -d -m 700 "$BACKUP"

# 1. configuration, certificates and DMSS settings
sudo tar czf "$BACKUP/config.tgz" .env config nginx/nginx.conf nginx/certs docker-compose.yml \
  dmss-container-and-signature-services dmss-archive-services dmss-archive-services-fallback \
  $(ls -d dmss-digital-stamping-service deployment-evidence.json 2>/dev/null)

# 2. signed documents (keeps owners and modes)
sudo tar czf "$BACKUP/documents.tgz" signed-output docs

# 3. Keycloak volume: stop Keycloak for a consistent copy (logins pause for about a minute)
KC_VOLUME="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/keycloak/data"}}{{.Name}}{{end}}{{end}}' "$(docker compose ps -q keycloak)")"
TAR_IMG="$(docker compose config --images | grep -m1 '^nginx')"      # a local image that has tar
docker compose stop keycloak
docker run --rm -v "$KC_VOLUME":/v:ro -v "$BACKUP":/b "$TAR_IMG" tar czf /b/keycloak_data.tgz -C /v .
docker compose start keycloak

# 4. host-level state: list the files your host actually has
sudo tar czf "$BACKUP/host-state.tgz" /etc/systemd/system/padsign.service /etc/cron.d/padsign-monitor
echo "$KC_VOLUME" | sudo tee "$BACKUP/keycloak-volume-name" >/dev/null
sudo sh -c 'cd "$1" && sha256sum *.tgz > SHA256SUMS' _ "$BACKUP"
```

Keycloak runs on an embedded H2 database in its data volume
([6. Production hardening](06-production-hardening.md)), so copy it only while
Keycloak is stopped. Copy the backup directory off the host to wherever
your secret-bearing backups go, and keep at least the backup from before
the last upgrade.

## Disaster recovery

To rebuild the deployment on a new host from the backups above:

1. **Prepare the host** ([2.1 Host and software](02-01-host-and-software.md))
   and point DNS at it.
2. **Check out the same release** you backed up. The revision is in the
   backed-up `deployment-evidence.json` (`deployment_repo.revision`):

   ```bash
   sudo install -d -o "$USER" -g "$USER" /opt/padsign
   git clone <repository URL> /opt/padsign && cd /opt/padsign
   git checkout <revision or release tag>
   ```

3. **Restore configuration and documents** over the checkout (as root, so
   owners and modes come back as they were). Copy the backup directory to
   the new host first:

   ```bash
   BACKUP=/var/backups/padsign/<timestamp>
   sudo sh -c 'cd "$1" && sha256sum -c SHA256SUMS' _ "$BACKUP"
   sudo tar xzf "$BACKUP/config.tgz" -C /opt/padsign
   sudo tar xzf "$BACKUP/documents.tgz" -C /opt/padsign
   ```

4. **Restore the Keycloak volume** under the name compose will use, with
   compose's labels so compose adopts it. The name is in
   `keycloak-volume-name`; it is `<project>_keycloak_data`, where the project
   is the directory name (`padsign`) unless `.env` sets
   `COMPOSE_PROJECT_NAME`:

   ```bash
   KC_VOLUME="$(sudo cat "$BACKUP/keycloak-volume-name")"
   docker volume create --label com.docker.compose.project="${KC_VOLUME%_keycloak_data}" \
     --label com.docker.compose.volume=keycloak_data "$KC_VOLUME"
   docker compose pull
   TAR_IMG="$(docker compose config --images | grep -m1 '^nginx')"
   docker run --rm -v "$KC_VOLUME":/v -v "$BACKUP":/b:ro "$TAR_IMG" tar xzf /b/keycloak_data.tgz -C /v
   ```

5. **Start and check:**

   ```bash
   docker compose up -d
   ./installation-scripts/validate-config.sh --host padsign.example.com
   ./installation-scripts/postdeploy-check.sh --host padsign.example.com --company-role "<company role>"
   ```

   `validate-config.sh` names any `signed-output/` or `docs/` ownership that
   does not match the users the images run as, with the fix.

6. **Restore host-level state**: the boot unit
   ([above](#starting-the-stack-at-boot)), cron jobs and timers, certificate
   renewal, and the alerting configuration.

Rehearse this once on a spare host before you rely on it.

## Customized hosts (overlay)

Some hosts carry changes beyond what the scripts write: another DMSS image
version, an extra service such as a certificate renewer, storage mounted
from another disk, hand-tuned `nginx.conf` or DMSS settings. Kept as edits
in the checkout, they are easy to lose in an upgrade and impossible to tell
apart from accidental drift.

An **environment overlay** keeps them explicit. The host runs a clean
checkout of a release tag plus an overlay directory outside the checkout
(for example `/etc/padsign/overlay/<date>-<what>`, mode 700) that holds
everything environment-specific:

| In the overlay | Content |
|---|---|
| `files/` | the host's versions of tracked files (config, nginx, DMSS settings), merged onto the release's |
| `certs/` | the TLS certificate and key |
| `env` | the `.env` to write, including `COMPOSE_PROJECT_NAME` (which owns the Keycloak volume) |
| `compose.overlay.yml` | compose changes merged on top of the release's `docker-compose.yml`: storage mounts, image overrides, extra services |
| `approved-digests.json` | approvals for images the overlay adds or replaces |
| `MANIFEST.json`, `DEVIATIONS.md` | checksums, storage paths, and a redacted list of every deviation from the release |

`installation-scripts/overlay.sh` manages it: `capture`, `apply`, `verify`,
`rebase`, `rehash` and `drop` (see `--help`). The overlay holds secrets:
back it up with your other secret-bearing backups. For the first move of a
long-customized host onto an overlay, contact TrustLynx support.

### Is this host customized?

Compare the checkout with the release it came from:

```bash
cd /opt/padsign
./installation-scripts/diff-baseline-overlay.sh --baseline HEAD
```

It diffs `nginx/nginx.conf`, `config/constants.json`, `config/config.js` and
`docker-compose.yml` and sorts every difference into **expected overlay**
(values the scripts set: hostname, certificate paths, secrets, company role,
routing, e-seal mode, image pins, the signed-output mount, local e-sealing
entries) and **unexpected drift** (anything else). Secrets in the report
are shown as `<redacted>`. It exits non-zero when it finds drift:

```
== nginx/nginx.conf ==
  OK   only expected overlay values differ
== docker-compose.yml ==
  FAIL 1 unexpected drift line(s):
    DRIFT:     # hand-added debug directive
```

`--baseline` also takes a release tag, another ref, or a path to a clean
checkout. A host with only expected overlay values needs no overlay: the
normal upgrade ([9.5](09-05-upgrading.md)) keeps those.

### Moving a host onto an overlay

Each release runs from its own directory; the directory the host runs from
today (`$OLD`) stays untouched until the cut-over and remains the rollback.

```bash
OLD=/opt/padsign                                   # the running, customized checkout
TAG=<release tag>                                  # e.g. vX.Y.Z, see git tag
NEW=/opt/padsign-releases/$TAG
OVERLAY=/etc/padsign/overlay/$(date +%Y%m%d)-initial

# 1. clean checkout of the release
sudo install -d -o "$USER" -g "$USER" "$(dirname "$NEW")"
git clone --branch "$TAG" <repository URL> "$NEW" && cd "$NEW"

# 2. capture (read-only on $OLD)
sudo install -d -m 700 -o "$USER" -g "$USER" "$(dirname "$OVERLAY")"
./installation-scripts/overlay.sh capture --from "$OLD" --baseline "$NEW" --out "$OVERLAY"
```

Capture merges only the host's own edits onto the release's files (it uses
`$OLD`'s git `HEAD` as the release the host came from; pass
`--host-base <ref>` if `$OLD` is not a git checkout or holds local commits).
It never reads `signed-output/` or `docs/`, never copies scripts or
documentation, and saves the live `docker-compose.yml` under
`reference/` rather than applying it. It also lists host boot and cron
hooks that name `$OLD` or run `docker compose`.

3. **Review** `$OVERLAY/DEVIATIONS.md` and decide for every entry: keep,
   drop (`overlay.sh drop --overlay "$OVERLAY" <path>`), or report it to
   TrustLynx support as belonging in the release. Port the compose
   differences you keep into `$OVERLAY/compose.overlay.yml` (pin images by
   digest, and approve each in `$OVERLAY/approved-digests.json`). If capture
   reported merge conflicts, resolve the `<<<<<<<` blocks under
   `$OVERLAY/files/` and run `overlay.sh rehash --overlay "$OVERLAY"`.
4. **Apply and verify**, still without touching the running stack:

   ```bash
   cd "$NEW"
   ./installation-scripts/overlay.sh apply  --overlay "$OVERLAY"
   ./installation-scripts/overlay.sh verify --overlay "$OVERLAY" --live "$OLD"
   ./installation-scripts/validate-config.sh --host padsign.example.com
   ```

   `verify` checks that every change in the checkout is declared in the
   overlay, that secret files are not world-readable, that the compose
   project reuses the existing Keycloak volume, that the storage mounts point
   at the existing documents, that the effective compose model matches the
   running host, and that no boot or cron hook still starts the stack from
   `$OLD`.
5. **Cut over** in a maintenance window, after a backup:

   ```bash
   (cd "$OLD" && docker compose stop)
   cd "$NEW" && docker compose up -d
   sudo sed -i "s#^WorkingDirectory=.*#WorkingDirectory=$NEW#" /etc/systemd/system/padsign.service
   sudo systemctl daemon-reload
   ```

   Then check: every service healthy, nginx included; `docker volume ls |
   grep keycloak_data` shows **one** volume (a second, empty one means the
   project name is wrong and Keycloak started empty); and
   `docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' ps-server`
   prints `$NEW`. Repoint cron jobs at `$NEW`, then run
   `postdeploy-check.sh` ([5.3](05-03-post-deploy-checks.md)).

To go back: `(cd "$NEW" && docker compose stop) && cd "$OLD" && docker compose up -d`,
and set `WorkingDirectory` back.

Instead of editing `WorkingDirectory` at each cut-over you can make it a
symlink that you repoint (`sudo ln -sfn "$NEW" <link>`); the comment in the
unit file explains how compose resolves it. Then run commands from the
resolved directory (`cd -P <link>`): a plain `cd` through the link makes
compose see other bind-mount paths and recreate every container.

### Living with an overlay

Once a host runs as "tag + overlay", every change goes through the overlay.
A hand edit in the checkout makes `overlay.sh verify` fail with
`modified but NOT declared in the overlay (undocumented drift)`.

Overlays are versioned: every change writes a **new** overlay directory,
and the previous one stays a complete rollback target.

Do not run these on an overlay-managed checkout, because they rewrite
tracked files in place: `upgrade.sh` (except `--plan-only`), `rollback.sh`,
and the wizard's **Upgrade**. `toggle-features.sh`, `update-hostname.sh`
and `renew-cert.sh` work, but re-capture afterwards as in
[Certificate renewal on a customized host](#certificate-renewal-on-a-customized-host),
or the next `apply` undoes them.

### Upgrading an overlay host

```bash
NEXT_TAG=<new release tag>
NEXT=/opt/padsign-releases/$NEXT_TAG
NEW_OVERLAY=/etc/padsign/overlay/$(date +%Y%m%d)-$NEXT_TAG
git clone --branch "$NEXT_TAG" <repository URL> "$NEXT" && cd "$NEXT"
./installation-scripts/overlay.sh rebase --overlay "$OVERLAY" --out "$NEW_OVERLAY"
./installation-scripts/overlay.sh apply  --overlay "$NEW_OVERLAY"
./installation-scripts/overlay.sh verify --overlay "$NEW_OVERLAY" --live "$NEW"   # $NEW = the directory running today
./installation-scripts/upgrade.sh --server-tag <pinned> --client-tag <pinned> --plan-only
```

`rebase` 3-way merges the release's changes into every file the overlay
carries, so new release settings and the host's edits both survive. A real
conflict is reported per file; `apply` refuses until you resolve the
`<<<<<<<` blocks in `$NEW_OVERLAY/files/` and run `overlay.sh rehash`.
`verify --live` should show only the release's intended changes, typically
the ps-server / ps-client image bump. The plan should report no pending
migrations; one that is pending means the overlay's copy of a file lacks
something the release expects, so contact TrustLynx support rather than
editing by hand. A `keycloak-backend-audience` item with *Could not check
right now* only means the plan could not log in to Keycloak; export
`KEYCLOAK_ADMIN_PASSWORD` and run it again.

Then cut over from `$NEW` to `$NEXT` as in step 5 above. The previous
release directory with the previous overlay is the rollback.

The release that moves `ps-client` to `8.41` (Syncfusion 34) changes the
licence key in `config/constants.json`, which the overlay carries because
the hostname in it differs from the release. `rebase` then reports a
conflict on the key line and the neighbouring `PDF_TEST_PATH`: keep the
release's key and the overlay's `PDF_TEST_PATH`, then `rehash`
([9.5, New Syncfusion key](09-05-upgrading.md#new-syncfusion-key-for-ps-client-841)).
Rolling back to a release directory on `8.40` or older is fine: its own
overlay copy still has the old key.

## Changing a value in the overlay

For example rotating `REGISTER_PDF_API_KEY`, changing a webhook URL, or
adding `ALERT_WEBHOOK_URL` to `env`:

```bash
NEW_OVERLAY=/etc/padsign/overlay/$(date +%Y%m%d)-<what>
cp -a "$OVERLAY" "$NEW_OVERLAY"
"${EDITOR:-vi}" "$NEW_OVERLAY/files/config/config.js"     # or env, compose.overlay.yml, files/nginx/nginx.conf ...
cd "$NEW"                                                  # the checkout running today
./installation-scripts/overlay.sh rehash --overlay "$NEW_OVERLAY"
./installation-scripts/overlay.sh apply  --overlay "$NEW_OVERLAY" --force   # re-apply onto the same checkout
./installation-scripts/overlay.sh verify --overlay "$NEW_OVERLAY"
docker compose restart ps-server                          # what the change needs, see below
```

`OVERLAY=$NEW_OVERLAY` from here on. What to restart:

| Changed | Then |
|---|---|
| `files/config/config.js` | `docker compose restart ps-server` (it reads `config.js` only at start) |
| `files/config/constants.json` | `docker compose restart ps-client`, then reload the portal ([7.2](07-02-how-configuration-is-loaded.md#when-a-change-takes-effect)) |
| `files/nginx/nginx.conf` | `docker compose exec -T nginx nginx -t && docker compose exec -T nginx nginx -s reload` |
| `files/dmss-*/...` | `docker compose restart <that service>` |
| `compose.overlay.yml` or `env` | `docker compose up -d` (recreates what changed) |
| `env`, alerting keys only | nothing; only `monitor-status.sh` reads them |

To undo, apply the previous overlay with `--force` and restart the same
service.

## Certificate renewal on a customized host

`renew-cert.sh` writes `nginx/certs/` in the checkout, but the overlay
still holds the old certificate, and the next `apply` would reinstall it.
Renew, then capture the checkout into a new overlay version:

```bash
cd "$NEW"                                  # the checkout running today
./installation-scripts/renew-cert.sh --host padsign.example.com --cert-crt <crt> --cert-key <key>
./installation-scripts/overlay.sh capture --from "$NEW" --baseline "$TAG" \
  --out /etc/padsign/overlay/$(date +%Y%m%d)-cert
./installation-scripts/verify-served-cert.sh
```

`$TAG` is the release tag `$NEW` was cloned from. Capturing an
overlay-managed checkout carries over the `compose.overlay.yml` in effect,
the overrides, the project name and the storage mounts, and picks up the new
certificate. Use the new directory as `OVERLAY` from here on. The same
re-capture works after `toggle-features.sh` or `update-hostname.sh`.

An automated renewer has the same effect as `renew-cert.sh`: re-capture
after each renewal, or have it write into the overlay's `certs/`, then run
`overlay.sh rehash`, `overlay.sh apply --force` and restart nginx.
