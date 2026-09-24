# 41. Baseline/overlay reconciliation

Tooling for telling a clean release baseline apart from the per-host overlay
`configure-host.sh` / `upgrade.sh` apply on top of it, and for recording what
was actually deployed. Written for
[psapp-saas#7](https://github.com/mihailsgo/psapp-saas/issues/7), which asks
for a specific already-deployed host to be reconciled with a clean checkout.
**This page covers the repo-side tooling only** — see the last section for
what that issue still needs a human with access to the real host to do.

## The baseline/overlay model that already exists

`configure-host.sh` and `upgrade.sh` already separate "what the release
provides" from "what gets rewritten per deployment." The complete list of
fields either script mutates:

| File | Fields the overlay sets |
|---|---|
| `nginx/nginx.conf` | `server_name`, TLS cert paths, root→`/portal/` redirect |
| `config/constants.json` | `KEYCLOAK_URL`, `KEYCLOAK_REDIRECT_URI`, `KEYCLOAK_POST_LOGOUT_REDIRECT_URI`, `PS_DOWNLOAD_API`, `PDF_TEST_PATH`, `DEMO_MODE` |
| `config/config.js` | hostname-embedded service URLs, Keycloak backend `secret`, `DEMO_COMPANY_ROLE`, the `DOCUMENT_ROUTING` block, `STAMP_MODE`/`STAMP_LOCAL` |
| `docker-compose.yml` | `ps-server`/`ps-client` image tags, the `signed-output` volume mount, `KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD`, the optional local-eseal service block + its `SPRING_SECURITY_USER_*` env |

Anything that changes in these files but isn't in this table is drift, not
overlay — a hand edit that a plain `git pull`/`merge` on the host risks
silently clobbering, and that this repo previously had no way to detect.

## Checking a live host for drift: `diff-baseline-overlay.sh`

```bash
# On the host, inside its checkout:
git fetch origin
./installation-scripts/diff-baseline-overlay.sh --baseline origin/main
```

Diffs the four files above between `--baseline` (a git ref, or a path to a
clean checkout directory if the host's git history isn't usable) and the live
checkout, and classifies every difference as **expected overlay** (matches a
row in the table above) or **unexpected drift** (everything else). Exits
non-zero and prints each drifted line if any unexpected drift is found — read
the output directly, it isn't paraphrased.

```
== nginx/nginx.conf ==
  OK   only expected overlay values differ
== docker-compose.yml ==
  FAIL 1 unexpected drift line(s):
    DRIFT:     # hand-added debug directive
```

**Known limitation:** the tool's allow-list is a second, purpose-built copy of
the same field knowledge `configure-host.sh`/`upgrade.sh` encode (which
already each carry their own copies of some of this - e.g. both independently
implement the `DOCUMENT_ROUTING` block insertion). If either script starts
rewriting a new field, this list needs a matching update, or that field will
show up as false-positive drift. Unifying all of these behind one shared
pattern source is real follow-up work, not done here.

## What gets deployed: `deployment-evidence.json`

`bootstrap.sh` and `upgrade.sh` both write `deployment-evidence.json` (repo
root, git-ignored) at the end of a successful run:

```json
{
  "schema_version": 1,
  "generated_at": "2026-09-22T17:21:43Z",
  "script": "bootstrap.sh",
  "deployment_repo": { "revision": "...", "branch": "main", "dirty": false },
  "image_tags": { "ps-server": "3.28", "ps-client": "8.39" },
  "image_revisions": { "ps-server": "...", "ps-client": "..." },
  "config_checksums": {
    "config/config.js": "...", "config/constants.json": "...",
    "nginx/nginx.conf": "...", "docker-compose.yml": "..."
  },
  "enabled_features": { "document_routing": true, "demo_mode": false, "local_eseal": false }
}
```

`deployment_repo.revision`/`.dirty` mirror the same "-dirty" convention
`psapp/scripts/build-image.sh` already stamps on images (see
[39. Release Procedure](39-release-procedure.md)), applied here to this
repo's own checkout instead of the application image.
`image_revisions` reads each image's OCI `image.revision` label the same way
that document already recommends checking manually — best-effort, `null` if
Docker isn't reachable or the image predates that stamping. Nothing in this
file is a secret: it deliberately records derived, already-non-secret state,
never the raw CLI arguments (`--admin-pass`, `--backend-secret`, `--users`)
a script ran with.

## Directory permissions: `installation-scripts/lib/dir-permissions.sh`

`signed-output/` and `docs/` no longer get `chmod 777`. See the header
comment in
[`lib/dir-permissions.sh`](../installation-scripts/lib/dir-permissions.sh)
for the reasoning. Each directory is owned by the uid its container image
actually runs as, resolved from the pinned image at run time (ps-server: root
up to 3.29, uid 1000 from the Node 24 image on; dmss-archive-services-fallback:
999:1000 up to 24.0.5, 10001:10001 in 24.1.x), and re-owned when that
changes. `validate-config.sh` now actively fails if
either directory is world-writable, so drift back to 777 on a live host is
caught by the tool operators already run.

## What this does *not* do — still needs a human on the real host

This tooling gives an operator a way to *see* baseline-vs-overlay drift and
*record* what was deployed. It does not, and cannot, by itself:

- Reconcile any specific already-deployed host's actual current state —
  that needs someone with SSH/console access to run
  `diff-baseline-overlay.sh` there and decide what to do with what it finds.
- Move secrets, certificates, or operational backups out of a live host's
  working tree, or decide where they should live instead (secrets manager,
  protected path, retention policy) — an infrastructure decision, not a
  script.
- Rehearse an upgrade or rollback against a real deployment while preserving
  certificates, routing, external stamping, and document storage — needs a
  real stack and a maintenance window.
- Guarantee "a fresh host can be deployed with no manual file edits" or that
  "git status is clean after deployment" — those are claims about a specific
  host's outcome, not something a repo-side script can attest to on its own.

See [psapp-saas#7](https://github.com/mihailsgo/psapp-saas/issues/7) for the
full acceptance criteria and current status.
