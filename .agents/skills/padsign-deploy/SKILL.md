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
| Change the hostname of a LIVE deployment | `update-hostname.sh --host <new> --admin-pass <p> [--cert-crt/--cert-key]` | Rewrites configs, syncs the Keycloak client's redirect URIs, restarts nginx + ps-server. Do NOT use bare `configure-host.sh` for this — it skips the Keycloak sync. |
| Renew the TLS certificate (hostname unchanged) | `renew-cert.sh --host <h> --cert-crt <crt> --cert-key <key>` | Pure cert swap; restarts nginx and verifies the served cert over the wire |
| Toggle features after go-live (routing / demo / local e-sealing) | `toggle-features.sh --enable-*/--disable-*` | Restarts only what each change needs; demo mode needs no restart |
| Just rotate the backend client secret into config.js | `configure-host.sh --host <h> --backend-secret <s>` | Standalone; no other side effects |
| Confirm nginx is actually serving the certificate that is on disk | `verify-served-cert.sh` | Read-only wire check; catches a renewal that landed on disk but never reached nginx. File-level checks cannot see this. |

If the user is vague ("deploy padsign"), ask which of these they want — the wrong choice is destructive (e.g. running `bootstrap.sh` against a live deployment re-runs the Keycloak bootstrap and may rewrite configs).

## Required inputs by workflow

### `bootstrap.sh` (fresh deployment)

Required — refuse to run without all three:
- `--host` (DNS name; must already resolve to this server in production)
- `--company-role` (e.g. `"Acme"` — becomes a Keycloak realm role; users get assigned to it)
- `--admin-pass` (Keycloak master admin password; never use `admin` in production)

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

### `validate-config.sh`

`--host` is optional but should be passed whenever known — it's the only check that catches hostname drift between `nginx.conf`, `constants.json`, and `config.js`.

## How to run

The scripts are bash. On Linux/macOS run them directly; on Windows use Git Bash, WSL, or invoke via the Bash tool. There is a `keycloak-bootstrap.ps1` PowerShell companion for the Keycloak step only — there is **no** PowerShell port of `bootstrap.sh` / `upgrade.sh` / `configure-host.sh`, so don't try to translate them on the fly.

Bootstrap requires: `docker`, `docker compose` v2, `awk`, `perl`, `python3`, `curl`, `openssl`. Verify with `command -v` if a run fails on a fresh machine.

## Safety rules

1. **Always check current state first.** Before any script run: `docker ps`, `git status`, and `ls config/*.bak` to see if a previous run is in flight or left state behind.
2. **The scripts auto-backup to `*.bak`** — but only the last run's backup. If you're about to re-run `bootstrap.sh`/`configure-host.sh` and `.bak` files already exist from a known-good state, copy them aside first (`config.js.bak.good` etc.).
3. **Never commit `nginx/certs/*.key`, the captured backend secret, or any Keycloak admin password.** `nginx/certs/` is git-ignored; double-check `git status` before committing after a deploy.
4. **The Keycloak backend client secret is captured from `keycloak-bootstrap.sh` stdout.** If `bootstrap.sh` fails after step 4 but before step 5, the secret is lost — re-running bootstrap regenerates it (idempotent realm setup, but secret rotates). Note this if asked to "resume" a partial bootstrap.
5. **Encrypted private keys break nginx startup.** If `--cert-key` points at an encrypted PEM, `configure-host.sh` exits with an error unless `--allow-encrypted-key` is set. Decrypt with `openssl pkey -in encrypted.key -out plain.key` rather than bypassing.
6. **Rollback is documented in each script's final output** — surface that command verbatim if a step fails. Do not invent rollback procedures.
7. **Don't run destructive Docker commands without asking** — `docker compose down -v` wipes the Keycloak realm volume and forces a re-bootstrap.

## Verification after any deploy/upgrade

The scripts already do basic checks. Add these if the user wants a thorough handoff:

- `bash installation-scripts/validate-config.sh --host <host>` — exit 0 means files are consistent
- `docker compose ps` — all services should be `running` / `healthy`
- `docker compose logs ps-server | grep "PadSign Server listening"` — backend boot
- `curl -ksI https://<host>/` — expect `301` to `/portal/`
- `curl -ksI https://<host>/auth/realms/padsign/.well-known/openid-configuration` — expect `200` (Keycloak realm reachable)
- `bash installation-scripts/verify-served-cert.sh --host <host>` — exit 0 means nginx is serving the certificate that is on disk (see documentation/11-02)

If any of these fail, surface the exact failing command and its output to the user; don't paraphrase.

## Files this skill touches (and the source of truth for each)

| File | Edited by | Holds |
|---|---|---|
| `nginx/nginx.conf` | `configure-host.sh` | server_name, cert paths, root→/portal/ redirect |
| `config/constants.json` | `configure-host.sh` (Python JSON edit) | client-side Keycloak URLs, redirect URIs, download API |
| `config/config.js` | `configure-host.sh` + `upgrade.sh` | server-side service URLs, backend secret, ALLOWED_ORIGINS, DEMO_COMPANY_ROLE, DOCUMENT_ROUTING, CUSTOMER_DATA_* |
| `docker-compose.yml` | `upgrade.sh` (image tags) + `configure-host.sh` (volume mount) | image tags, volumes, network |
| `nginx/certs/<host>.{crt,key}` | `configure-host.sh` copies from `installation-scripts/certs/` | TLS material — git-ignored |

When the user asks to change something in these files manually, prefer running the appropriate script (with the right flag) over hand-editing — the scripts encode constraints (JSON validation, hostname escaping, redirect placement) that are easy to break.

## When NOT to use this skill

- Building or releasing new `ps-server` / `ps-client` images — that happens in the application source repo, not here.
- Editing application behavior (signing flows, UI, API logic) — also in the application source repo.
- Integrations that only consume PadSign's public endpoints (e.g. virtual printer, external signing frontends) — they are downstream consumers, not deployment concerns.
