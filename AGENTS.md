# AGENTS.md — PadSign deployment package

Guidance for AI coding agents (and people) working in this repository. The
operator documentation is in [README.md](README.md) and `documentation/`;
this file is about how to change the repository safely.

## What this repository is

The public, customer-facing Docker Compose deployment package for PadSign
2.0 by TrustLynx. It contains no PadSign application source: `ps-server`,
`ps-client` and the DMSS services ship as signed, digest-pinned images. It
does contain its own deployment tooling: `installation-scripts/` (bash +
stdlib Python) and the optional Deployment Wizard (`deployment-wizard/`, a
Node/Express app that wraps those scripts).

Delivery target is **Linux only**. Windows is at most a development
convenience; validate shell behaviour on Linux.

## Layout

| Path | What it is |
| --- | --- |
| `docker-compose.yml` | Every service. Optional services are profile-gated: `local-eseal` (stamping), `wizard` |
| `config/` | ps-server `config.js`, ps-client `constants.json`, `keycloak.js` |
| `nginx/nginx.conf` | Reverse proxy and TLS termination (`nginx/certs/` is git-ignored) |
| `dmss-*/` | Spring configuration for the DMSS services |
| `installation-scripts/` | `bootstrap.sh`, `upgrade.sh`, `rollback.sh`, `validate-config.sh` and helpers; `lib/` shared code; `tests/` hermetic test suites |
| `deployment-wizard/` | Wizard source and its `node --test` suite |
| `release/` | `approved-digests.json`, `capabilities.json`, `cosign.pub` — the release's approved images |
| `documentation/` | Operator guide, 14 sections (see Documentation conventions) |

## Rules that are easy to break

**Public repository.** Nothing tracked may contain a secret, a real
customer or host name, an internal URL, a personal path, or an issue link to
a private repository. Demo values that must ship are listed by sha256 in
`installation-scripts/lib/secret_hygiene.py` (and CA fingerprints in
`lib/visual-pdf-ca.sh`), never duplicated elsewhere.

**Default behaviour is invariant.** A plain `docker compose up -d` on a
fresh checkout must behave as before any opt-in feature existed: profile-gated
services stay off, `STAMP_MODE` defaults to `"external"`.

**Wrap, don't reimplement.** The wizard never rewrites configuration or runs
compose orchestration itself; it runs the scripts (`lib/scriptRunner.js`)
and parses their stdout (`lib/outputParser.js`). If you change an
`echo`/`printf` in `installation-scripts/*.sh`, refresh
`deployment-wizard/test/fixtures/` and run the wizard tests.

**Config migrations go in `upgrade.sh`'s migration table.** Each migration
is a `mig_<id>_needed` predicate, a `mig_<id>_body` and a `mig_<id>_apply`,
built from shared `need_*` predicates so `--plan-only` cannot disagree with a
real run. Never add a straight-line edit.

**Compose edits anchor on structure, not a neighbouring line.** Inserts into
a service's `environment:` list track the service block and the list (see
the `SPRING_SECURITY_USER_*` insert and `lib/compose-hostname.sh`); a line
anchor produced invalid YAML on real deployments whose key order differed.

**Secrets never go on a command line**, including kcadm's inside the
Keycloak container (the host's `ps` lists it). Use
`kc_exec_with_cli_password` / `kc_set_password` (`lib/kcadm.sh`); pass the
admin password as `KEYCLOAK_ADMIN_PASSWORD` in the environment; write `.env`
values with `lib/secret_hygiene.py env-set` (`SECRET_VALUE`, never argv);
back up config files with `backup_owner_only`; print config through
`lib/redact.py`.

**`config/config.js` must stay readable by the ps-server image's uid**
(1000). Never `chmod o-rwx` / `chmod 640` it by hand; the model is
`secure_config_js` in `lib/dir-permissions.sh`.

**Pipefail and stdin.** Scripts run under `set -euo pipefail`, often from an
`ssh … bash -s` heredoc. Never pipe a producer into a reader that exits early
(`grep -q`, `head`) when the result decides an `if` — use
`grep -q PATTERN < <(producer)`. Give every `docker compose exec -T` a
`</dev/null`. `tests/test-pipefail-and-stdin.sh` lints both.

**`KC_HOSTNAME` is not inert.** Keycloak 26 uses it as the token issuer and
login URL. `configure-host.sh` rewrites it with the nginx network alias; both
take effect only on container recreate (`docker compose up -d`), never on
`restart`.

**Overlay hosts** (a checkout with `.overlay-applied.json`) are never edited
in place and never upgraded with `upgrade.sh`; changes go through a new
overlay version (`installation-scripts/overlay.sh`, documentation 9.11). When
you change what `configure-host.sh` / `upgrade.sh` rewrite, keep
`RELEASE_CONTENT_PREFIXES` in `lib/overlay.py` in step.

**Images.** Every image is pinned `tag@sha256` and must be approved in
`release/approved-digests.json`; never hardcode a digest or a minimum tag in
a script (read `approved-digests.json` / `capabilities.json`).

## Testing

```bash
./installation-scripts/tests/run-all.sh
```

runs `bash -n`, shellcheck (when installed), every `installation-scripts/tests/test-*.sh`,
the documentation checks (`tests/test-docs.sh`: links, doc references in code,
leak patterns), `docker compose config` for each profile (when Docker is
available) and the wizard's `npm test`. CI runs the same script.

The suites take seconds on Linux and minutes under Git Bash, where every
process start costs 50-150 ms (`test-rollback.sh`: 7-12 minutes, 30 on a
busy machine). Each suite sources `tests/lib/watchdog.sh`, which stops it
after `TEST_WATCHDOG_SECS` (default 600 on Linux, 3600 under Git Bash,
`0` = off) with exit 124, prints what is still running, and lets a
`timeout` or Ctrl-C from outside finish the suite's EXIT trap. Do not wrap a
suite in a short `timeout`. A new suite sources the watchdog right after
its `trap ... EXIT`, and gives the scripts it runs `</dev/null` and a short
`--health-timeout`, so nothing can wait on a terminal or on a health check
its stubs never answer.

## Documentation conventions

- `README.md` opens with a short copy-paste install (wizard first, CLI as the
  alternative) and then the contents list, one entry per page. No version
  numbers in the README.
- Every H2 section is `documentation/NN-<slug>.md`, every H3 is
  `documentation/NN-MM-<slug>.md`, and each page title carries its number
  (`# 9.5 Upgrading`). Sections follow the operator's journey: 1 Overview,
  2 Prerequisites, 3 Wizard install, 4 CLI install, 5 First login and
  verification, 6 Production hardening, 7 Configuration, 8 Keycloak,
  9 Operations, 10 Local e-sealing, 11 Routing and receive-back,
  12 Troubleshooting, 13 FAQ, 14 Reference.
- Scripts print documentation paths (`documentation/09-05-upgrading.md`);
  renaming a page means updating them. `tests/test-docs.sh` fails on a
  dangling reference.
- Describe how things are, not how they changed: no "new", "now supports",
  or dated what's-new sections. `CHANGELOG.md` holds customer release notes.
- Examples use `padsign.example.com` and the install location `/opt/padsign`.
