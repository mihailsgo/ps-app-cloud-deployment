# 42.7 Evidence and sign-off

## Where everything goes

| Location | Holds | Sensitive? | Leaves the host? |
|---|---|---|---|
| `$EVID` (mode 700) | logs, redacted reports, checksums, mode listings, `deployment-evidence.json` copies | no, once it passes the scan below | yes: attach to the change ticket |
| `$BACKUP` (mode 700) | Keycloak volume tarballs, the old deployment-dir archive, storage fingerprint manifests (file names can contain personal data), generated key files | **yes** | only to your secret-bearing backup store |
| `$OVERLAY` (mode 700) | the overlay itself: config files with secrets, TLS key, `.env`, `compose.overlay.yml` | **yes** | only to your secret-bearing backup store |
| Secret manager | the Keycloak admin credential, rotated API keys and secrets | **yes** | n/a |
| Change ticket | the decisions: every DEVIATIONS.md entry marked INTENTIONAL / OBSOLETE / UPSTREAM; credential owner; secret-manager entry **paths** (never values); window times | no | yes |

The three pieces #7 names explicitly are all inside
`$EVID/C5-deployment-evidence.json` (written by `postdeploy-check.sh`):

| Required | Field |
|---|---|
| Source revision | `deployment_repo.revision` (the tag's commit, cross-check against `O2-baseline-revision.txt`); `deployment_repo.modified_tracked_files`; `overlay.baseline_commit` |
| Configuration checksums | `config_checksums`: `config/config.js`, `config/constants.json`, `nginx/nginx.conf`, `docker-compose.yml`, each DMSS `application.yml` and `documentsigningprofiles.json`, and the compose overlay file |
| Image digests | `image_digests`: the running container image id per service; the pinned `tag@sha256` lines are in `docker-compose.yml` / `compose.overlay.yml` |

`overlay.manifest_sha256` ties the evidence to the exact overlay version that
was applied.

## Secret scan before the evidence leaves the host

```bash
# 1. anything that looks like an assignment of a secret-bearing key to a real value
grep -rnEi "(secret|passw(or)?d|api[_-]?key|token|authorization|credential)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[^<\"'[:space:],]{6,}" "$EVID" | grep -v '<redacted>'
# 2. private key material
grep -rlE 'BEGIN [A-Z ]*PRIVATE KEY' "$EVID"
# 3. the live values themselves: pipe each current secret from your secret manager, without echoing it
#    e.g.:  <secret-manager-cli> get padsign/<env>/keycloak-admin | grep -rlFf - "$EVID"
```

Commands 1 and 2 must print nothing. Command 3 must list no files. If
anything is found, remove or redact that file, and treat the value as exposed
(rotate it). Then run the scan again.

## Sign-off checklist

### #6: managed Keycloak admin access and a disposable smoke identity

- [ ] An authorised operator authenticated to Keycloak administration with the value from the secret manager (42.2 K4; `K-log.txt`).
- [ ] A disposable user was created with exactly one configured company role, used for a real browser login, and deleted, with no Keycloak restart. Done **twice in a row**, and documented (42.2 K5; `K5-smoke.txt`, identical `StartedAt` before and after each run).
- [ ] Passwords, client secrets and tokens are absent from all logs and retained artefacts: the scan above passes; the 42.1 leak-sweep counts are 0 on a re-run; `validate-config.sh` shows `API_PROTECT_LOGS_ENABLED is off`.
- [ ] Break-glass procedure tested (42.2 K2, or an earlier rehearsal on a spare host) and **credential owner recorded** (42.2 K3), with a next-rotation date.
- [ ] No known-default or shared long-lived smoke password remains:
  - the shared `test` user is deleted (`verify-keycloak.sh`: `no shared 'test' user`);
  - old documented passwords are removed;
  - `validate-config.sh` shows no "still the value shipped in the public repository" warnings (42.2 K6).

### #7: clean release baseline plus an explicit environment overlay

- [ ] A fresh host can be deployed from a tagged baseline plus the overlay with no manual file edits: rehearse the 42.6 *Rebuilding the host* flow on a spare host from the real overlay and backups, and attach its log.
- [ ] A documented diff lists every intentional environment deviation: `DEVIATIONS.md` with every entry decided in the ticket (42.3 O4), plus the `verify --live` WARN list with decisions (42.4 C3).
- [ ] Git status on the deployed baseline is clean after deployment: `C1-git-status.txt` and `C5-verify.log`. See the note below.
- [ ] No credentials, private keys, certificates or operational backups are tracked or left unprotected in the working tree:
  - `C5-verify.log` shows no ignored-file warnings;
  - secret-bearing file modes are OK;
  - the old tree is decommissioned (42.4 C7).
- [ ] No deployment file or directory requires mode 777: `C2-storage-modes-after.txt` and `validate-config.sh`'s "not world-writable" lines; `find "$NEW" "$SIGNED" "$DOCS" -perm -0002 ! -type l | wc -l` returns 0.
- [ ] Upgrade and rollback rehearsed while preserving certificates, routing, external stamping and document storage:
  - rollback: 42.5 R3 forward → back → forward during the window, with C5's checks after each direction. If the cut-over moved Keycloak to the release's version (42.1 G1), the back direction includes R4;
  - upgrade: 42.6 `rebase` to the next tag when it exists.
- [ ] Configuration checksums and source revision recorded: `C5-deployment-evidence.json`.
- [ ] Keycloak (gate G1): the host runs the release's Keycloak, and `C5-postdeploy.log` shows `OK   padsign-client access tokens carry padsign-backend in aud`. `K-log.txt` has the 42.2 K4b line. Or the ticket records the decision to keep the host's Keycloak for now, with a date for the 42.6 move.

**Note on "git status is clean".** The release's own scripts rewrite tracked
files in place (`configure-host.sh` writes the hostname into
`nginx/nginx.conf`, for example), so the overlay's files necessarily appear as
modified in `git status`. `overlay.sh verify` enforces the property that
matters: **every** git-visible change is declared in the overlay, byte for
byte, and nothing else changed. Making `git status` literally empty would
require teaching every script (and the deployment wizard) to read per-host
files from outside the checkout. That is a larger change for the maintainers
to decide on, and it is not done here.
