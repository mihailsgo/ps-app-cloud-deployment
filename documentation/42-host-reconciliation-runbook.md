# 42. Host reconciliation runbook: Keycloak admin recovery and baseline + overlay migration

This is the operator runbook for the two host-side P0 items
[psapp-saas#6](https://github.com/mihailsgo/psapp-saas/issues/6) (restore
managed Keycloak admin access and a disposable smoke-test identity) and
[psapp-saas#7](https://github.com/mihailsgo/psapp-saas/issues/7) (reconcile a
hand-customised deployed host with a clean release baseline plus an explicit
environment overlay). Both need a person on the host with real credentials.
Nothing in this repository has been run against a live PadSign host. Every
step here was rehearsed end-to-end against throwaway, isolated Docker Compose
projects on Linux (see *What was rehearsed* below), and the results are
quoted where they matter.

## Sub-sections

- [42.1 Before you start](42-01-before-you-start.md): inputs, access, the secret-handling rules, the read-only inventory, and the go/no-go gates.
- [42.2 Keycloak admin access and the disposable smoke identity (#6)](42-02-keycloak-admin-access-and-smoke-identity.md)
- [42.3 Capturing the environment overlay (#7)](42-03-capturing-the-environment-overlay.md)
- [42.4 Cut-over and post-checks (#7)](42-04-cut-over-and-post-checks.md)
- [42.5 Rollback](42-05-rollback.md): per step, and all the way back.
- [42.6 Living with an overlay: upgrades, value changes, certificates, rebuilds](42-06-living-with-an-overlay.md)
- [42.7 Evidence and sign-off](42-07-evidence-and-sign-off.md): where every artefact goes, the secret scan, and the acceptance-criteria checklist.

## The model in one paragraph

The deployed host becomes **a clean checkout of a tagged release** (never
hand-edited) plus **an overlay directory outside that checkout**. The overlay
holds everything specific to this environment: the files that differ from the
release (with the host's edits 3-way merged onto the release's versions), TLS
certificates, the `.env` values, the compose project name that owns the
Keycloak data volume, where the signed documents already live, and a
`compose.overlay.yml` for compose-level differences such as the DMSS version
overlay. `installation-scripts/overlay.sh` captures it, applies it, verifies
it, and carries it forward to the next release. Signed-document storage is
never moved, copied or rewritten by any step: the new checkout mounts the
documents where they already are.

## Order of work

```
42.1  inventory + gates              (read-only, no interruption)
42.2  K1 try non-disruptive admin recovery   ──► works? ──► K3..K6 (K4b: token audience mapper, gate G1)
                         │ no
                         ▼
      K2 break-glass: fold it into the 42.4 cut-over window (one interruption, not two)
42.3  capture + review overlay       (read-only on the live host)
42.4  apply, verify, fix storage modes, plan boot/cron hooks   (no interruption)
      cut-over window: stop → back up Keycloak volume → [K2] → repoint boot/cron hooks → start from new checkout (~1-3 min)
      post-checks, smoke identity twice (K5), retire stale credentials (K6), one controlled reboot (C6)
42.5  rollback at any point: start the old directory again (same volume, same storage)
42.7  evidence bundle + sign-off
```

## Secret-handling rules (apply to every step)

1. **Never put a secret on a command line.** Command lines are visible to
   every local user (`ps`, `/proc/<pid>/cmdline`) and recorded by audit
   tooling and shell history. Read secrets with `read -rs VAR` (no echo), pass
   them through the environment, and `unset` them afterwards. Every script
   used here reads `KEYCLOAK_ADMIN_PASSWORD` from the environment, so omit
   `--admin-pass`. Processes inside the Keycloak container count too: they
   are ordinary host processes, so their command lines are in the host's
   `ps` as well. That is why the scripts give kcadm the admin password as
   `KC_CLI_PASSWORD` (no `--password`) and set user passwords with JSON on
   stdin (no `--new-password`). Measured on a Linux host with its own Docker
   engine, sampling `ps -ww -eo args` while `keycloak-bootstrap.sh` (twice),
   `verify-keycloak.sh` and `smoke-user.sh create` / `delete` ran: with
   v1.0.37 the admin password was in 443 of 7047 snapshots and each
   generated password in 82 to 84; with v1.0.40, none of them in any
   snapshot. An earlier version of this rule reported 0 of 1578 for
   v1.0.26. It was wrong, most likely because that `ps` cut lines off at
   the terminal width: an 80-column `ps -eo args`, sampled in the same
   v1.0.37 run, found the password in 0 snapshots, since kcadm's command
   lines reach the password well past column 80. Sample with `ps -ww`, on
   the Docker host itself (a Docker Desktop engine runs its containers in
   a separate VM, out of reach of the host's `ps`).
2. **Generated passwords are shown once, on the terminal only**
   (`print_secret`, `installation-scripts/lib/kcadm.sh`). If your SSH session
   is recorded (`script`, tmux logging, a PAM/bastion session recorder), that
   recording will contain them. Run `smoke-user.sh create` from an unrecorded
   session, or treat the recording as a secret.
3. **Reports are redacted by design.** `overlay.sh` and
   `diff-baseline-overlay.sh` print `<redacted>` for every secret-bearing key
   (`installation-scripts/lib/redact.py`). The overlay *directory* itself holds
   real secrets (config files, keys) and must stay mode `0700`, outside every
   checkout, and must never be attached to a ticket.
4. **Evidence gets a secret scan before it leaves the host** (42.7).

## What was rehearsed, and where

All on real Linux userlands (Ubuntu 24.04 and Debian 12; Docker Engine 28-29, Docker Compose v5), using
throwaway compose projects with unique names that were torn down afterwards:

| Rehearsal | Result |
|---|---|
| `smoke-user.sh` create → real browser-flow login (authorization code + PKCE, the SPA's flow) → delete, twice in a row, on the pinned Keycloak 26.7.4 | Passed both cycles once a real bug was fixed: Keycloak 26's user profile requires first and last names, so the created user was sent to an "update profile" form instead of back to the portal. The Keycloak container was never restarted, and the generated and admin passwords never appeared on stdout or stderr. |
| `kc.sh bootstrap-admin` while Keycloak keeps running (default `start-dev`, H2 database) | Refused safely: "Database may be already in use". The running Keycloak was unaffected. Zero-downtime recovery via this command is not possible on this configuration. |
| `bootstrap-admin` with Keycloak stopped, measuring the outage and session survival | Keycloak was unavailable for 57.9 s (stop 2.2 s, recovery 40.7 s, start 15.0 s). Existing SSO sessions survived: a pre-restart refresh token still worked. The original admin and all users were intact, and the recovery password never appeared in output. |
| Simulated stale, hand-customised host → capture → apply onto a fresh checkout → verify → Keycloak cut-over → rollback → cut forward | The realm and its users survived every switch through the pinned project name. The real ps-server image in the new checkout saw the existing signed documents byte-identical. The host tree was byte-identical before and after capture. No test secret appeared in any report or in the deployment evidence. |
| Next release changes a file the overlay replaces | `apply` refused. `rebase` merged the release's change under the host's edits into a new overlay, and the old overlay was unchanged. A genuinely conflicting change was reported, and `apply` was blocked until it was resolved. |
| Existing Keycloak 26.3.2 `start-dev` (H2) volume started on the pinned 26.7.4, then on 26.3.2 again (gate G1; plain `docker run`, no compose project) | Forward: `Updating database`, realm model migrated to 26.4.0, 26.4.3 and 26.6.1; realm and users intact. Back: 26.3.2 started and read the data, but warned `Possibly incorrect state of migration ... already migrated to newer version '26.7.4'`. Keycloak does not support downgrades, so rollback after a Keycloak move restores the C4 backup (R4). |
| The 42.2 K4b audience-mapper block, on throwaway Keycloak 26.3.2 and 26.7.4 containers | Same result on both versions for each case: no `padsign-client`, wrong admin password, absent, created, present, and a repeated add (no duplicate mapper). No kcadm session file was left behind. |
| Disaster recovery: containers, volume and checkouts deleted, then rebuilt from the release + the overlay + backups | The realm and users came back, and the signed documents and fallback archive were byte-identical. Zero files were edited by hand. |
