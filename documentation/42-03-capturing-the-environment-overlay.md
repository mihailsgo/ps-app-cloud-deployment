# 42.3 Capturing the environment overlay (#7)

Everything in this section is **read-only on the live host**. Nothing is
stopped, restarted or edited in `$OLD`. It was rehearsed against a simulated
host: its whole tree was byte-identical before and after capture.

## O1: pick and tag the baseline (release owner)

The baseline must be a **tag**, so that "what the host runs" is a name
anyone can check out again. As of 2026-09-23 this repository has no tag for
its current release line (the last release tag is older than the
single-commit public history). The release owner:

1. Chooses the commit. It must satisfy gate G2 in 42.1: its
   `docker-compose.yml` pins the ps-server/ps-client versions the host runs
   today, digest-pinned per [39](39-release-procedure.md).
2. Tags and pushes it: `git tag -a v1.0.22 -m "..." <commit> && git push origin v1.0.22`.

Operator check: `git ls-remote --tags <repo-url> "$TAG"` returns exactly one line.

## O2: fresh checkout of the tag

```bash
sudo install -d -o "$USER" -g "$USER" "$(dirname "$NEW")"
git clone --branch "$TAG" <repo-url> "$NEW"
git -C "$NEW" status --porcelain | wc -l          # 0
git -C "$NEW" describe --tags --exact-match       # prints $TAG
git -C "$NEW" rev-parse HEAD > "$EVID/O2-baseline-revision.txt"
```

- **Check:** clean, on the tag. `$NEW` must be a different directory from `$OLD`. Its directory name does not matter: the overlay pins the compose project name.
- **Rollback:** `rm -rf "$NEW"`.
- **Evidence:** `O2-baseline-revision.txt`.

## O3: capture

Run the **new** checkout's tool against the old directory. The host may not
even have `overlay.sh`.

```bash
cd "$NEW"
./installation-scripts/overlay.sh capture --from "$OLD" --baseline "$NEW" --out "$OVERLAY" 2>&1 | tee "$EVID/O3-capture.log"; echo "exit=${PIPESTATUS[0]}"
```

Useful facts about what capture does:

- **Host is a git checkout:** capture uses the host's own `HEAD` as "the release the host was deployed from". It 3-way merges **only the host's edits** onto the new release's version of each file, so a stale host's old release content is not carried forward. The log says `host was deployed from: <commit> ... 3-way merged`.
- **Host is not a git checkout** (files copied by hand): pass `--host-base <ref-or-clean-dir>` if you know which release it was copied from. Without it, differing files are carried **whole**, capture prints a `WARN ... carried WHOLE`, and every `-` line in those files' diff in `DEVIATIONS.md` is new-release content the overlay would drop. Merge it in by hand under `$OVERLAY/files/`, then run `overlay.sh rehash --overlay "$OVERLAY"`.
- **Release content is never captured.** Scripts, docs and tooling that differ are reported under *Found in the tree, NOT captured* ("upstream it or drop it"). Applying an old script over the new release would silently downgrade it.
- **Never captured:** `signed-output/` and `docs/` are not even read; operational backups (`*.bak*`, `retired-*`) are only listed; `installation-scripts/certs/*` staging copies are only listed, because `nginx/certs/` is what gets captured.
- **docker-compose.yml is never applied wholesale.** It is saved as `reference/docker-compose.live.yml`, and its differences appear under COMPOSE-DIFFERENCES for you to port (O4).

Checks: `exit=0` above (a non-zero exit with `FAIL` lines means merge conflicts to resolve, see below), then:

```bash
grep -E 'Compose project|Storage|WARN|FAIL' "$EVID/O3-capture.log"
cat "$EVID/00-keycloak-volume.txt"                    # must be <that project>_keycloak_data
stat -c '%a %n' "$OVERLAY" "$OVERLAY"/env "$OVERLAY"/certs/* 2>/dev/null   # 700 / 600
```

- The **compose project** must be the one whose `<project>_keycloak_data` volume holds the live realm. If it is wrong, stop: a wrong project name means Keycloak starts on an **empty** volume after cut-over.
- The two **Storage** lines are where the signed documents are today. They become the new checkout's mounts.
- **Rollback:** `rm -rf "$OVERLAY"`; nothing else was touched.
- **Evidence:** `cp "$OVERLAY/DEVIATIONS.md" "$OVERLAY/MANIFEST.json" "$EVID/"`. Both are redacted or non-secret (paths, modes, hashes, redacted diffs). **Never** copy `files/`, `certs/`, `env` or `compose.overlay.yml` into the evidence bundle; they hold secrets.

If capture reports merge conflicts (`FAIL <file>: N merge conflict(s)`),
edit `$OVERLAY/files/<file>`. Keep the host side or the release side of each
`<<<<<<<` / `>>>>>>>` block, then run
`./installation-scripts/overlay.sh rehash --overlay "$OVERLAY"`. `apply`
refuses while markers remain.

## O4: review every deviation, and port the compose differences

Open `$OVERLAY/DEVIATIONS.md`. **For every entry, record a decision in the
change ticket:** INTENTIONAL (keep in the overlay), OBSOLETE (drop it), or
UPSTREAM (belongs in the release, so raise an issue). That annotated file *is*
the "documented diff that lists every intentional environment deviation".

What to confirm explicitly, because #7 names these:

| Must be preserved | Where it lives in the overlay | How to confirm |
|---|---|---|
| External stamping mode | `files/config/config.js`: no `STAMP_MODE: "local"`; the host's own `STAMP_API_URL`/`STAMP_COMPANY_ID`, plus key and secret (redacted in the report); `env` has no `COMPOSE_PROFILES=...local-eseal` | `grep -n 'STAMP_MODE\|STAMP_API_URL' "$OVERLAY/files/config/config.js"`; `grep COMPOSE_PROFILES "$OVERLAY/env"` |
| Routing configuration | `files/config/config.js`, the `DOCUMENT_ROUTING` block exactly as the host has it | the config.js diff in DEVIATIONS.md shows the host's strategies and URLs (tokens redacted) |
| Certificate integration | `certs/` (copied from `nginx/certs/`, mode 0600); a renewal job becomes an entry in `compose.overlay.yml` or stays a host cron job | `openssl x509 -in "$OVERLAY/certs/$HOST.crt" -noout -subject -enddate -fingerprint -sha256`, compared with the served certificate (`verify-served-cert.sh` in 42.4) |
| DMSS version overlay | image overrides in `compose.overlay.yml`, plus any `files/dmss-*/…` overrides | COMPOSE-DIFFERENCES lists every `dmss-*` `image` difference |
| Signed-document storage | the storage mounts `compose.overlay.yml` already contains (generated) | the two paths match the 42.1 inventory |

Then edit `$OVERLAY/compose.overlay.yml`. Capture generated it with only the
storage mounts. Port each INTENTIONAL compose difference. Merge rules that
matter:

- `image:` replaces. Pin by digest. For the image a service runs today:
  `docker image inspect --format '{{index .RepoDigests 0}}' <image:tag>`. `overlay.sh verify` warns about unpinned overlay images.
- `volumes:` merge by container path: a same-target entry replaces the release's. `environment:` merges by variable name.
- `ports:` and other lists **append**. To replace, use `ports: !override` (Compose ≥ 2.24.4), as the rehearsal did for a non-default Keycloak port.
- Relative paths resolve against the **new checkout**. An absolute path pointing into `$OLD` (other than storage) makes `verify` warn.
- Never override `mihailsgordijenko/ps-server` / `ps-client` (gate G2).
- `KEYCLOAK_ADMIN*` differences are first-boot-only. Do not carry them (see 42.2 K6).
- Gate G1: if the release pins Keycloak 26.7.4, add the host's current Keycloak image here.

Example, shaped like the rehearsal (values illustrative):

```yaml
services:
  keycloak:
    image: "quay.io/keycloak/keycloak:26.3.2@sha256:<digest the host runs>"
  dmss-archive-services:
    image: "trustlynx/dmss-archive-services:<host version>@sha256:<digest>"
  cert-renewer:                     # a host-only service, ported as-is
    image: "<image>@sha256:<digest>"
    volumes:
      - ./nginx/certs:/certs        # now the NEW checkout's certs directory
```

- **Check:** every COMPOSE-DIFFERENCES line is either ported or recorded as OBSOLETE. `verify --live` in 42.4 C3 proves it.
- **Rollback:** edit again. Nothing live depends on the overlay yet.
- **Evidence:** the annotated decisions in the ticket. `sha256sum "$OVERLAY/compose.overlay.yml" >> "$EVID/O4-overlay.sha256"` (hash only).

## O5: protect the overlay

```bash
sudo chown -R "$USER":"$USER" "$OVERLAY" && chmod 700 "$OVERLAY"
find "$OVERLAY" -type f -exec chmod go-rwx {} +
```

Back the overlay directory up to wherever your secret-bearing backups go
(it is small), and record where in the ticket. Together with a clean checkout
of `$TAG` and backups of the Keycloak volume and the storage, it is
everything needed to rebuild the host (42.6).
