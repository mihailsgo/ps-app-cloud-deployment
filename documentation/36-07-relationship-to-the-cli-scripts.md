# 36.7 Relationship to the CLI scripts

## The scripts remain the source of truth

Everything the wizard does, it does by calling
`installation-scripts/bootstrap.sh`, `upgrade.sh`, `validate-config.sh`, and
`validate-certs.sh` as child processes and reading their output — it never
reimplements config rewriting, Keycloak realm/client creation, or `docker
compose` orchestration itself. This is a deliberate design choice, not a
current-version limitation: the tricky, already-tested logic (Keycloak
setup, `awk`/`perl` config rewriting, TLS chain validation) stays in exactly
one place.

A practical consequence: running the scripts directly from the CLI, with or
without the wizard ever having been used on this deployment, behaves
identically. Nothing about the wizard's presence in this repo or in
`docker-compose.yml` changes what `bootstrap.sh --host ... --company-role
...` does when you run it by hand.

## What the wizard adds on top

- Inline, pre-flight validation (TLS certificate checks) instead of a
  mid-script failure.
- Live, per-step progress instead of a scrolling terminal log.
- A persistent dashboard showing current versions and health, so you don't
  need to remember CLI flags to check on a deployment later.

## What stays CLI-only

- **Additional Keycloak users** (`bootstrap.sh --users
  "user:pass:role,..."`). The wizard creates the default admin account and
  the demo `test` user, same as running `bootstrap.sh` with no `--users`
  flag. If you need named extra users at bootstrap time, pass the flag
  directly:

  ```bash
  ./installation-scripts/bootstrap.sh --host ... --company-role ... \
    --admin-pass ... --users "alice:Passw0rd!:padsign-admin,bob:Passw0rd!:psapp-integration"
  ```

## How the wizard reads script output

The scripts print human-readable progress — `Step N/8: ...` markers,
ad hoc `<name>: OK`/`WARNING` lines, and the cleaner `OK`/`FAIL`/`WARN`
helper convention `validate-certs.sh`/`validate-config.sh` already use.
Rather than adding a machine-readable output mode to the scripts, the wizard
parses this existing output directly (`deployment-wizard/lib/outputParser.js`).
This keeps the scripts themselves completely unmodified for the wizard's
sake, at the cost of a coupling: if a script's wording changes, the wizard's
parsing needs a matching update. See
[36.6 Troubleshooting the wizard](36-06-troubleshooting-the-wizard.md) for
what that looks like in practice.
