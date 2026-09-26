---
name: padsign-deploy
description: Deploy, upgrade, validate, or troubleshoot a PadSign 2.0 stack (ps-server + ps-client + Keycloak + DMSS) using the scripts in installation-scripts/. Use when the user asks to deploy/install/bootstrap PadSign on a new host, upgrade image versions, rotate the Keycloak backend secret, validate config consistency, switch hostnames, renew the TLS certificate, enable document routing / demo mode / local e-sealing, or diagnose a broken deployment.
---

# PadSign 2.0 Deployment

This skill orchestrates deployments of the PadSign 2.0 application using this repo's `installation-scripts/`. The repo ships pre-built Docker images; the application source lives in a separate repository and is not built here.

## Pick the right path first

Decide which workflow the user actually needs before doing anything:

| User intent | Script | Notes |
|---|---|---|
| First-time deploy on a host | `bootstrap.sh` | End-to-end: backups → config rewrite → Keycloak realm → image pull → start → verify |
| Bump `ps-server` and/or `ps-client` image tags | `upgrade.sh` | Only restarts the changed services; Keycloak/DMSS/nginx stay up |
| Preview what an upgrade would change, without writing anything | `upgrade.sh [same args] --plan-only` | Read-only; renders every pending config migration and exits 0 |
| Sanity-check files after manual edits or before handoff | `validate-config.sh --host <h>` | Read-only; exits non-zero on failure |
| Change the hostname of a LIVE deployment | `update-hostname.sh --host <new> [--cert-crt/--cert-key]` with `KEYCLOAK_ADMIN_PASSWORD` exported | Rewrites configs (incl. compose `KC_HOSTNAME` + nginx alias), syncs the Keycloak client's redirect URIs, recreates keycloak + nginx, restarts ps-server. Users sign in again (the token issuer changes). Do NOT use bare `configure-host.sh` for this — it skips the Keycloak sync. |
| Renew the TLS certificate (hostname unchanged) | `renew-cert.sh --host <h> --cert-crt <crt> --cert-key <key>` | Pure cert swap; restarts nginx and verifies the served cert over the wire |
| Toggle features after go-live (routing / demo / local e-sealing) | `toggle-features.sh --enable-*/--disable-*` | Restarts only what each change needs; demo mode needs no restart |
| Just rotate the backend client secret into config.js | `configure-host.sh --host <h>` with `CONFIGURE_HOST_BACKEND_SECRET` exported | Standalone; no other side effects. `--backend-secret <s>` also works but puts the secret in `ps` |
| Confirm nginx is actually serving the certificate that is on disk | `verify-served-cert.sh` | Read-only wire check; catches a renewal that landed on disk but never reached nginx. File-level checks cannot see this. |
| Check a live host for drift from a clean baseline | `diff-baseline-overlay.sh --baseline <git-ref-or-path>` | Read-only; diffs the four per-host-mutated files and classifies each difference as expected overlay or unexpected drift; secret values print as `<redacted>`. See `documentation/41-baseline-overlay-reconciliation.md`. |
| Move a hand-customised host onto "release tag + explicit environment overlay", or keep one in sync | `overlay.sh capture --from <deployed-dir> --baseline <tag-checkout> --out <overlay-dir>` → `apply` → `verify --live <deployed-dir>`; next release: `rebase --overlay <old> --out <new>` | Operator procedure is `documentation/42-*` (needs a maintenance window for the cut-over). The overlay dir holds secrets: keep it outside every checkout, mode 700. Capture never reads `signed-output/`/`docs/`; apply/verify never start or stop containers. A captured file the review marks OBSOLETE: `overlay.sh drop --overlay <dir> <path>...` (never delete it under `files/`) |
| Restore Keycloak admin access when no credential works | `documentation/42-02` K1 (non-disruptive options) then K2 (`kc.sh bootstrap-admin`, needs Keycloak stopped ~1 min on the default H2 DB) | Never reset the Keycloak volume; never put the password on a command line |
| Provision/remove a short-lived, single-purpose test login without touching the shared `test` account | `smoke-user.sh create --host <h> --company-role <role>` / `smoke-user.sh delete --host <h> --username <name>` | Never grants `padsign-admin`; requires the realm and role to already exist (run `keycloak-bootstrap.sh` first); the generated password is shown once at an interactive terminal only, never in a capturable log; pass the admin password via `KEYCLOAK_ADMIN_PASSWORD`, not `--admin-pass` |
| Run every post-deploy check in one pass (redirects, portal config, Keycloak discovery, protected API behavior, TLS, optional signing smoke test) | `postdeploy-check.sh --host <h> [--company-role <role>] [--signing-smoke]` | Orchestrates `validate-config.sh` + `verify-keycloak.sh` + `verify-served-cert.sh` plus new checks it owns directly; writes `deployment-evidence.json` at the end. `--signing-smoke` runs `signing-smoke.sh` (below) and needs an interactive terminal |
| Prove a live (even production) deployment can sign, as a real user, without touching customer data or routing | `signing-smoke.sh --host <h> [--with-seal]` with `KEYCLOAK_ADMIN_PASSWORD` exported | A person must approve the login on Keycloak's device page in a browser; the script never sees the smoke user's password. Uses the demo path and drops the document's user entry before anything can route it; deletes its temporary client, smoke user and archive document. Never pass `--with-seal` on a customer host without the owner's say-so: it applies their real e-seal. See documentation/40-05 |
| Observability snapshot (health, restarts, cert expiry, stamping/archive/routing failure counts, disk usage, unacknowledged receive-back buffer) | `monitor-status.sh [--host <h>]` | Read-only report. Add `--alert` (from cron) to exit 1 and POST to `ALERT_WEBHOOK_URL` in `.env` when thresholds are crossed. A Microsoft Teams (Workflows) URL needs `ALERT_WEBHOOK_FORMAT=teams` (auto-detected from its host; a 202 is not proof it was posted). `--test-webhook` sends one test message and prints the HTTP status; never print the URL itself. On an overlay-managed host the URL goes in the overlay's `env` or a root-only env file, not the checkout's `.env`; see documentation/40-03 |
| Check that a DMSS image (container-signature / digital-stamping) actually boots and seals with this repo's config — required before approving a DMSS bump, including Renovate's | `dmss-seal-smoke.sh [--cs-image <ref>] [--stamp-image <ref>]` | Throwaway compose project, no host ports, never touches the running stack; 3 consecutive seals because one seal misses the profile-ratchet bug. See documentation/39 |
| Undo a bad `upgrade.sh` run (bad tag, broken image) | `rollback.sh [--to latest\|<snapshot>] [--yes]` (or `upgrade.sh ... --rollback-on-failure` up front) | Restores the `ps-server`/`ps-client` image that was running when `upgrade.sh` took its snapshot (`tag@digest`, also after a `git pull` that already moved the pins) + `config/config.js`, and exits 1 if the restored containers run anything else; never touches `signed-output/`, `docs/`, `nginx/nginx.conf`, `config/constants.json` or the git checkout |

If the user is vague ("deploy padsign"), ask which of these they want — the wrong choice is destructive (e.g. running `bootstrap.sh` against a live deployment re-runs the Keycloak bootstrap and may rewrite configs).

## Required inputs by workflow

### `bootstrap.sh` (fresh deployment)

Required — refuse to run without all three:
- `--host` (DNS name; must already resolve to this server in production)
- `--company-role` (e.g. `"Acme"` — becomes a Keycloak realm role; users get assigned to it)
- `--admin-pass` (Keycloak master admin password; never use `admin` in production). Prefer exporting `KEYCLOAK_ADMIN_PASSWORD` (read with `read -rs`) instead: the flag puts it in `ps` for the whole run

Strongly recommended:
- `--cert-crt` and `--cert-key` (PEM). If omitted, the script expects `installation-scripts/certs/<host>.crt|.key` to already exist.

Optional flags:
- `--users "user1:pass1:role,user2:pass2:role"` to seed extra users
- `--enable-routing` to turn on filesystem document routing
- `--enable-demo` to enable client DEMO mode
- `--enable-local-eseal` to provision the local e-sealing stack (stamping container + demo seal.p12; external e-sealing stays the default without it)
- `--allow-self-signed` to skip cert chain verification for dev/test self-signed certs (all other cert checks still run)
- `--realm` (default `padsign`), `--admin-user` (default `admin`)

If the user gives partial input, ask for the missing required fields in one pass.

### `upgrade.sh` (version bump)

At least one of `--server-tag` or `--client-tag` is required (exception: `--enable-local-eseal` alone is valid — it opts an existing deployment into local e-sealing without a tag bump). Confirm the target tags exist on Docker Hub before running (current registry: `mihailsgordijenko/ps-server` and `mihailsgordijenko/ps-client`). If the user just says "upgrade", check `git log --oneline -- docker-compose.yml` for the recent bump pattern before guessing. Run `upgrade.sh [same args] --plan-only` first and show the user the pending config migrations — the deployment wizard enforces this preview as a mandatory gate, and CLI runs should match that discipline.

A requested tag must be the one `release/approved-digests.json` approves. Any other tag is refused with exit 2 (`ERROR: Refusing to upgrade to a tag release/approved-digests.json does not approve: ...`) before anything is pulled or modified, and `--plan-only` refuses the same way. Tell the user which tag is approved and point them at documentation/39-release-procedure.md to approve a new one. `--allow-unapproved` is an emergency-hotfix override: it prints a warning banner, leaves the tag without a digest pin, records it in `deployment-evidence.json` as `"unapproved_override"`, and `validate-config.sh`/`postdeploy-check.sh` keep failing until the tag is approved. See safety rule 11.

Every `upgrade.sh` run also applies the `keycloak-backend-audience` migration: it adds an audience mapper to `padsign-client` in the live Keycloak realm, because Keycloak 26.4.12/26.6.2/26.7.0+ otherwise reject ps-server's token introspection and every portal API call 401s. It needs the Keycloak admin credentials, which default to the keycloak container's own `KEYCLOAK_ADMIN_PASSWORD`. If the operator changed that password in the admin console, pass `KEYCLOAK_ADMIN_PASSWORD=...` in the environment. If the run prints `WARNING: could not add padsign-backend...`, surface it to the user, because the upgrade continues regardless (see documentation/14-08-token-audience-for-introspection.md).

### Image signatures (cosign)

`upgrade.sh` verifies the cosign signature, SBOM and provenance attestations of each requested ps-server / ps-client image against `release/cosign.pub` before it rewrites or pulls anything, and `validate-config.sh` checks the pinned digests the same way. If either reports that a signature does not verify, stop and surface it to the user: do not work around it by editing `release/cosign.pub` or `release/unsigned-legacy-images.json`. A `WARN ... cosign is not installed` means the check did not run; tell the user (install recipe in documentation/40-02-post-deploy-validation.md). `ps-server:3.28` / `ps-client:8.39` warn as pre-signing releases, which is expected.

### `validate-config.sh`

`--host` is optional but should be passed whenever known — it's the only check that catches hostname drift between `nginx.conf`, `constants.json`, `config.js`, and compose's keycloak `KC_HOSTNAME` (a mismatch there sends browsers to that other host at login and stamps it into every token's issuer).

Its image-digest section checks the *effective* compose model (`docker-compose.yml` plus any `COMPOSE_FILE` overlay, every profile enabled), not `docker-compose.yml` alone. An image an overlay adds or replaces FAILs unless it is digest-pinned and approved, by `release/approved-digests.json` or, on an overlay host, by the overlay's own `approved-digests.json` (documentation/42-03). Don't "fix" such a FAIL by editing `release/approved-digests.json` on a host; approving an image is a reviewed change.

## How to run

The scripts are bash. On Linux/macOS run them directly; on Windows use Git Bash, WSL, or invoke via the Bash tool. There is **no** PowerShell port of any of them (including `keycloak-bootstrap.sh`), so don't try to translate them on the fly.

Bootstrap requires: `docker`, `docker compose` v2, `awk`, `perl`, `python3`, `curl`, `openssl`. Verify with `command -v` if a run fails on a fresh machine.

## Safety rules

1. **Always check current state first.** Before any script run: `docker ps`, `git status`, and `ls config/*.bak` to see if a previous run is in flight or left state behind.
2. **The scripts auto-backup to `*.bak`** — but only the last run's backup. If you're about to re-run `bootstrap.sh`/`configure-host.sh` and `.bak` files already exist from a known-good state, copy them aside first (`config.js.bak.good` etc.).
3. **Never commit `nginx/certs/*.key`, the captured backend secret, or any Keycloak admin password.** `nginx/certs/` is git-ignored; double-check `git status` before committing after a deploy.
4. **The Keycloak backend client secret is captured from `keycloak-bootstrap.sh` stdout.** If `bootstrap.sh` fails after step 4 but before step 5, the secret is lost — re-running bootstrap regenerates it (idempotent realm setup, but secret rotates). Note this if asked to "resume" a partial bootstrap.
5. **Encrypted private keys break nginx startup.** If `--cert-key` points at an encrypted PEM, `configure-host.sh` exits with an error unless `--allow-encrypted-key` is set. Decrypt with `openssl pkey -in encrypted.key -out plain.key` rather than bypassing.
6. **Rollback after a bad `upgrade.sh` run is `rollback.sh [--to latest] --yes`**, not a hand-typed `cp`. Every `upgrade.sh` run writes a timestamped snapshot first; `rollback.sh` restores from it and waits for health checks to pass. Don't invent a different rollback procedure.
7. **Don't run destructive Docker commands without asking** — `docker compose down -v` wipes the Keycloak realm volume and forces a re-bootstrap.
8. **Never echo a generated Keycloak password to a stream a caller could capture or retain** (CI output, a redirected file, the deployment wizard's live log). `keycloak-bootstrap.sh` and `smoke-user.sh` both write generated passwords only via `print_secret()` (`installation-scripts/lib/kcadm.sh`), which goes straight to `/dev/tty` and is invisible to stdout/stderr redirection. If you add a script that generates a credential, reuse that helper rather than a plain `echo`.
9. **Never put a secret on a command line**: not in a script's `docker compose exec` string, not in a suggested command. Argv is readable by every local user (`ps`) and recorded by audit tooling and shell history. That includes kcadm's argv inside the Keycloak container: container processes are host processes, so the host's `ps -ww` lists it. Use `kc_exec_with_cli_password` (`lib/kcadm.sh`) for a kcadm login (the password goes in the container's `KC_CLI_PASSWORD`, no `--password`), `kc_set_password` to set a user's password (JSON on stdin; never `kcadm set-password --new-password`), `KEYCLOAK_ADMIN_PASSWORD` in the environment when one script or the wizard calls another (never `--admin-pass`), `--password:env` for `kc.sh bootstrap-admin`, and `read -rs VAR` for operator input. Anything that prints config lines goes through `installation-scripts/lib/redact.py`.
10. **An overlay-managed checkout (`.overlay-applied.json` exists) is never edited in place.** Changes go through a new overlay version (`documentation/42-06`); `upgrade.sh`, `rollback.sh` and the wizard's Upgrade rewrite tracked files and make `overlay.sh verify` fail. So `upgrade.sh`'s `keycloak-backend-audience` migration never runs there. Before the host moves to the pinned Keycloak, the audience mapper is checked and added with `documentation/42-02` K4b (gate G1 in `42-01`). `upgrade.sh --plan-only` is read-only and is part of the release update (42.6); from v1.0.44 it reads the overlay's storage mounts, so a pending `signed-output` there is real and goes to the release owner. Tell which checkout the stack runs from by ps-server's `com.docker.compose.project.working_dir` label, not Keycloak's (42.4 C4).
11. **Never add `--allow-unapproved` on your own.** Use it only when the user explicitly asks to deploy an unapproved tag as a hotfix, after showing them the `--plan-only` output with the `UNAPPROVED OVERRIDE` line. Afterwards, tell them the host fails validation until the tag is approved and pinned.
12. **Driving the scripts non-interactively** (`ssh host 'bash -s' <<EOF`, CI heredocs, `curl | bash`): before v1.0.43 every Keycloak step (`kc_exec`) read the caller's stdin to EOF, so `bootstrap.sh`, `keycloak-bootstrap.sh`, `verify-keycloak.sh`, `smoke-user.sh`, `postdeploy-check.sh` and `upgrade.sh` silently swallowed the rest of the heredoc. On an older checkout give each script `</dev/null`. On a bootstrapped host `git pull` needs `git stash push` / `git stash pop` around it (`documentation/04-04` Phase 1), and `upgrade.sh` runs straight after the pull.
13. **Never restrict `config/config.js` with a plain `chmod o-rwx` / `chmod 640`.** From 3.30 ps-server runs as uid 1000; a root-owned 640 file crash-loops it with `EACCES` and takes nginx down with it. Use the fix `validate-config.sh` prints (`chgrp <image gid>` + `chmod 640`), or re-run `configure-host.sh` as root. `upgrade.sh` refuses up front (exit 1, nothing changed) when the ps-server image it would start cannot read the file: apply the fix it prints and re-run it, never work around the check. `REGISTER_PDF_API_KEY` is generated at bootstrap and never printed: show it (documentation/18-05) only when the user needs it to configure a client, and never paste it into a ticket.

## Verification after any deploy/upgrade

Run `bash installation-scripts/postdeploy-check.sh --host <host> [--company-role <role>]` — it chains `validate-config.sh`, `verify-keycloak.sh`, `verify-served-cert.sh`, and its own redirect/portal-config/Keycloak-discovery/protected-API checks into one pass and writes `deployment-evidence.json`. `docker compose ps` should show every service `healthy`, not just `running` — a service still `starting` or `unhealthy` means don't consider the deploy done yet.

- `bash installation-scripts/diff-baseline-overlay.sh --baseline <ref>` — exit 0 means no unexpected drift from the baseline (see documentation/41)

For a point-in-time health/observability snapshot (not part of deploy verification, useful for a handoff or a support ticket): `bash installation-scripts/monitor-status.sh --host <host>`.

If any check fails, surface the exact failing command and its output to the user; don't paraphrase.

## Files this skill touches (and the source of truth for each)

| File | Edited by | Holds |
|---|---|---|
| `nginx/nginx.conf` | `configure-host.sh` | server_name, cert paths, root→/portal/ redirect |
| `config/constants.json` | `configure-host.sh` (Python JSON edit) | client-side Keycloak URLs, redirect URIs, download API |
| `config/config.js` | `configure-host.sh` + `upgrade.sh` | server-side service URLs, backend secret, the `REGISTER_PDF_API_KEY` / `SESSION_SECRET` that `configure-host.sh --generate-secrets` (bootstrap) generates, ALLOWED_ORIGINS, DEMO_COMPANY_ROLE, DOCUMENT_ROUTING, CUSTOMER_DATA_*. Group = the ps-server image's gid, mode 640 (`lib/dir-permissions.sh` `secure_config_js`, re-applied by `upgrade.sh` after its own edits) |
| `docker-compose.yml` | `upgrade.sh` (image tags, `compose-hostname` migration) + `configure-host.sh` (volume mount, keycloak `KC_HOSTNAME`, nginx network alias, Keycloak admin user) - hostname fields via `lib/compose-hostname.sh` | image tags, volumes, network, per-service `healthcheck:`/`depends_on: condition: service_healthy` (see documentation/40-01). Tracked and world-readable: never a secret. The admin password is only referenced, `${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}` |
| `.env` | `configure-host.sh --admin-pass` (via `lib/secret_hygiene.py env-set`), local-eseal (`COMPOSE_PROFILES`) | `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD`, `COMPOSE_PROFILES` - git-ignored, mode 600 (documentation/17-01) |
| `nginx/certs/<host>.{crt,key}` | `configure-host.sh` copies from `installation-scripts/certs/` | TLS material — git-ignored |
| `signed-output/`, `docs/` | `bootstrap.sh`/`upgrade.sh` via `lib/dir-permissions.sh` | mode 750/770, never 777 — see that file's header for why |
| `deployment-evidence.json` | `bootstrap.sh`/`upgrade.sh`/`postdeploy-check.sh` via `lib/deployment-evidence.sh` | git revision, image tags/revisions/digests, config checksums, restart counts, `unapproved_override` (tags deployed with `--allow-unapproved`) - git-ignored |

When the user asks to change something in these files manually, prefer running the appropriate script (with the right flag) over hand-editing — the scripts encode constraints (JSON validation, hostname escaping, redirect placement) that are easy to break.

## When NOT to use this skill

- Building or releasing new `ps-server` / `ps-client` images — that happens in the application source repo, not here.
- Editing application behavior (signing flows, UI, API logic) — also in the application source repo.
- Integrations that only consume PadSign's public endpoints (e.g. virtual printer, external signing frontends) — they are downstream consumers, not deployment concerns.
