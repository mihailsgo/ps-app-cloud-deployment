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
| `docker-compose.yml` | `ps-server`/`ps-client` image tags, the `signed-output` volume mount, `KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD`, keycloak's `KC_HOSTNAME`, nginx's network alias, the optional local-eseal service block + its `SPRING_SECURITY_USER_*` env |

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

## Secrets in the drift report

Every `DRIFT:` line goes through `installation-scripts/lib/redact.py`. A
changed `STAMP_API_KEY`, `SESSION_SECRET`, keystore password, `Authorization`
header or compose `*_PASSWORD` / `*_TOKEN` variable is shown as `<redacted>`,
so the output can be pasted into a ticket. Before that change, those lines
were printed verbatim.

## From "seeing drift" to an explicit overlay: `overlay.sh`

`diff-baseline-overlay.sh` answers "what differs". `overlay.sh` turns the
answer into a deployment model:

- **`capture`** writes everything environment-specific into a protected
  directory outside the checkout: the host's edits 3-way merged onto the
  release, certificates, `.env`, the compose project that owns the Keycloak
  volume, where the signed documents live, a `compose.overlay.yml`, and a
  redacted `DEVIATIONS.md`.
- **`apply`** puts it onto a clean checkout of a release tag.
- **`verify`** proves every git-visible change is declared in the overlay,
  and that Keycloak data and document storage will be reused.
- **`rebase`** carries the overlay onto the next release.

The operator procedure, which was rehearsed end-to-end on throwaway stacks,
is [42. Host reconciliation runbook](42-host-reconciliation-runbook.md).

## What still needs a human on the real host

Running that procedure. It needs:

- SSH access, a maintenance window and the real credentials;
- decisions only the service owner can make: the release tag, the credential
  owner and secret manager, backup retention, and which captured deviations
  are intentional;
- a rehearsal of the rebuild on a spare host.

[42.7](42-07-evidence-and-sign-off.md) maps each acceptance criterion of
psapp-saas#7 to the evidence that closes it.

See [psapp-saas#7](https://github.com/mihailsgo/psapp-saas/issues/7) for the
full acceptance criteria and current status.
