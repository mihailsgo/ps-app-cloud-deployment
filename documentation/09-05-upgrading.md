# 9.5 Upgrading

This is the procedure for moving a running deployment to a newer release:
update the checkout, preview what the upgrade will change, run
`upgrade.sh`, and verify. The same procedure applies whether you skip one
release or several. For the step-by-step behaviour of the script see
[9.6 What upgrade does](09-06-what-upgrade-does.md), for reading the
preview [9.7 Previewing upgrade changes](09-07-previewing-upgrade-changes.md),
and for undoing an upgrade [9.8 Rollback](09-08-rollback.md).

A customized host that runs from an environment overlay upgrades
differently: see [9.11, Customized hosts (overlay)](09-11-start-at-boot-backups-and-customized-hosts.md#customized-hosts-overlay).

## Before you start

- **Read the release notes.** `CHANGELOG.md` in the new release lists what
  changed, with an *Upgrade impact* note where you have to act. Read every
  release between the one you run and the target. The image versions of the
  current release are in [14.3 Release snapshot](14-03-release-snapshot.md).
- **Moving `ps-client` from `8.40` or older to `8.41` or later?** The new
  PDF viewer (Syncfusion 34) needs a new licence key in
  `config/constants.json`, which `upgrade.sh` never edits, and `git stash
  pop` conflicts on it. Do [New Syncfusion key for ps-client 8.41+](#new-syncfusion-key-for-ps-client-841)
  between the pull and `upgrade.sh`, or the pads show a licence banner over
  the document.
- **Using receive-back with the Padsign Manager?** The current ps-server
  serves a signed PDF and accepts its acknowledgement only from a caller
  that proves it owns the document. Under the single shared
  `REGISTER_PDF_API_KEY`, the Padsign Manager's download and ack calls then
  return `404` and documents stay pending (nothing is lost). Give each
  receive-back company its own key in `REGISTER_PDF_API_KEYS` before you
  upgrade: [11, Per-company API keys](11-document-routing-and-receive-back.md#per-company-api-keys).
- **Take a backup** of configuration, certificates, the Keycloak volume and
  the document stores ([9.11, Backups](09-11-start-at-boot-backups-and-customized-hosts.md#backups)).
- **Plan a short maintenance window.** ps-server, ps-client and nginx are
  recreated. Keycloak and the DMSS services are recreated too when the
  release changes their definition (the Java services then take a few
  minutes to become healthy); otherwise they keep running.
- **Note what runs now**, in case you need to compare later:

  ```bash
  cd /opt/padsign
  docker compose images ps-server ps-client
  ./installation-scripts/validate-config.sh --host padsign.example.com
  ```

## Step 1: Update the checkout

`/opt/padsign` is a git checkout of this repository. Updating it brings the
new scripts, the new `release/approved-digests.json` (which tags are
approved) and a `docker-compose.yml` that pins the new images:

```bash
cd /opt/padsign
git remote -v            # the repository you cloned from
git status --short       # expect modified host files, see below
git checkout main        # the release branch; safe if you are already on it
```

A plain `git pull` refuses to run on a deployed host, because the host's
own settings are edits to tracked files. Handle them as described in the
next section, then continue with step 2.

## Local changes to tracked files

`bootstrap.sh` and the other scripts write this host's hostname, secrets
and settings into files the repository tracks, so on every deployed host
`git status --short` shows them as modified (` M`):

| File | What the host changed |
|---|---|
| `config/config.js` | hostname URLs, the Keycloak backend client secret, the generated `REGISTER_PDF_API_KEY`, the company role, `DOCUMENT_ROUTING`, `STAMP_MODE` / `STAMP_LOCAL`, your e-sealing credentials |
| `config/constants.json` | hostname, Keycloak URL, `DEMO_MODE` |
| `docker-compose.yml` | `KC_HOSTNAME`, the nginx network alias, image pins, and with local e-sealing the stamping service and `SPRING_SECURITY_USER_*` |
| `nginx/nginx.conf` | `server_name`, certificate paths |
| `dmss-container-and-signature-services/dmssrootca.p12` and `application.yml` | the deployment's own visual-PDF signing CA and its keystore password; with local e-sealing, the stamping service URL |
| `dmss-digital-stamping-service/...` | with local e-sealing: your production keystore and its settings |

These edits **are** this deployment's configuration. Never discard them with
`git checkout -- .`, `git restore .` or `git reset --hard`. Untracked files
(`.env`, `nginx/certs/`, `signed-output/`, `docs/`, `*.bak`,
`.rollback-snapshots/`) are git-ignored and not touched by any of the steps
below.

`git pull` stops with:

```
error: Your local changes to the following files would be overwritten by merge:
	docker-compose.yml
Please commit your changes or stash them before you merge.
Aborting
```

### Stash or commit?

You can set the edits aside for the pull (**stash**, recommended) or keep
them as a local commit that each release is merged into (**commit**).

| | Stash | Commit |
|---|---|---|
| What stays in git | nothing; the edits are uncommitted again after the pull | a local commit holding the host's secrets |
| Every upgrade | stash, pull, pop | merge the new release |
| Conflicts | on `git stash pop` | on `git merge` |
| Risk | none beyond the pull | the commit must never be pushed; tools that compare against the checkout's `HEAD` need to be told the release it came from (below) |

Use the stash unless you have a reason to keep the host's configuration in
local git history.

### Stash, pull, pop

```bash
cd /opt/padsign
git stash push -m "padsign host config before pull $(date +%Y%m%d-%H%M%S)"
git pull                 # fast-forward to the new release
git stash pop
git stash list           # expect no output
git status --short       # the same " M" files as before
```

If your `docker-compose.yml` still carries the Keycloak admin password
inline (a `KEYCLOAK_ADMIN_PASSWORD=<value>` line instead of
`KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}`), move
it before you stash: put `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD=<value>` into
`.env` (mode 600) and replace the line with the release's form, as
[7.6 Environment variables](07-06-environment-variables.md) shows. Otherwise
the stash carries the inline password and `git stash pop` conflicts on that
line.

### When `git stash pop` reports a conflict

`git stash pop` usually applies cleanly, because releases rarely change
the lines the host wrote. If it prints `CONFLICT (content): Merge conflict
in <file>`, the stash entry is **kept** (`git stash list` still shows it)
and the file contains markers:

```
<<<<<<< Updated upstream
    image: 'mihailsgordijenko/ps-server:<new tag>@sha256:...'
=======
    image: 'mihailsgordijenko/ps-server:<old tag>@sha256:...'
>>>>>>> Stashed changes
```

The upper half is the new release, the lower half is this host's edit.
Resolve each conflicted file by hand:

- **keep the host's value** for anything host-specific: the hostname
  (`KC_HOSTNAME`, `server_name`, the nginx alias, URLs), the Keycloak admin
  user, the backend client secret, `REGISTER_PDF_API_KEY(S)`,
  `SESSION_SECRET`, certificate paths, e-sealing credentials, and feature
  settings (`DEMO_MODE`, `DOCUMENT_ROUTING`, `STAMP_MODE`, `STAMP_LOCAL`);
- **keep the host's DMSS addresses** in `config/config.js`
  (`ARCHIVE_API_BASE_URL`, `CREATE_DOCUMENT_API_URL`,
  `DOCUMENT_DOWNLOAD_API_URL`, `VISUAL_SIGNATURE_API_TEMPLATE`,
  `FORM_FILL_API_URL`). The release ships them as in-network addresses, a host
  installed earlier has the public form on the same lines, and keeping yours
  is what leaves ps-server on the public addresses until you switch with
  `upgrade.sh --use-internal-dmss-urls`
  ([7.4](07-04-server-config-js.md#how-ps-server-reaches-the-dmss-services)).
  Drop the release's new `ARCHIVE_PUBLIC_BASE_URL` key with its comment
  lines: it names the demo host, and a host on the public addresses does not
  need it;
- **take the release's version** of everything else: new keys, comments,
  health checks, and the `image:` lines (they are the release's approved
  pins, the tags you pass to `upgrade.sh`);
- **`PDF_RENDER_SYNCFUSION_SECRET_KEY` in `config/constants.json`** takes the
  release's value too (unless you use your own Syncfusion licence). It
  conflicts together with the neighbouring `PDF_TEST_PATH`: keep the
  release's key line and this host's `PDF_TEST_PATH` line
  ([New Syncfusion key for ps-client 8.41+](#new-syncfusion-key-for-ps-client-841));
- **the Keycloak admin password** never goes back into
  `docker-compose.yml`: take the release's line and keep the value in `.env`.

A binary file such as a keystore cannot be merged. Keep the host's copy:

```bash
git checkout --theirs -- dmss-container-and-signature-services/dmssrootca.p12   # "theirs" = the stash
```

Then check that no markers remain, unstage, and drop the entry `pop` kept:

```bash
grep -n '^<<<<<<<\|^=======\|^>>>>>>>' docker-compose.yml config/config.js \
  config/constants.json nginx/nginx.conf       # expect no output
git restore --staged .   # back to plain local edits, nothing staged
git stash list           # your entry, e.g. stash@{0}: On main: padsign host config ...
git stash drop stash@{0}
git stash list           # expect no output
```

Until you drop it, the entry still holds your original edits:
`git stash show -p stash@{0}` shows them.

### Keeping the host's edits as a local commit

Once, on a local branch that is never pushed:

```bash
cd /opt/padsign
git switch -c host-config
git add -u               # tracked files only
git commit -m "Host configuration for padsign.example.com"
```

At each upgrade, merge the new release into it:

```bash
git fetch origin
git merge origin/main    # resolve conflicts with the rules above, then git commit
```

Two consequences: `git push` from this checkout would publish the host's
secrets, so do not configure a push remote you can write to; and
`overlay.sh capture` compares against the checkout's `HEAD` by default, so
pass it the release you merged (`--host-base origin/main`).
`diff-baseline-overlay.sh` has no default and stops with
`ERROR: --baseline is required`; always pass `--baseline origin/main`
([9.11](09-11-start-at-boot-backups-and-customized-hosts.md#customized-hosts-overlay)).

### Go straight on to the upgrade

After the pull, `docker-compose.yml` already pins the new images while the
old containers are still running. Any `docker compose up` in this window,
or a script that runs one (`toggle-features.sh`, `update-hostname.sh`),
would start the new images without `upgrade.sh`'s checks, backups,
rollback snapshot and migrations. Only the read-only preview belongs
between the pull and the upgrade.

## New Syncfusion key for ps-client 8.41+

Only when the tag you are moving `ps-client` to is `8.41` or later and the
host runs `8.40` or older. Do this after the pull and before `upgrade.sh`.

`ps-client` `8.41` and later run the Syncfusion 34 PDF viewer, and a
Syncfusion key only licenses the versions it was issued for. With the key
that `8.40` and older use (issued for 27.x), the new viewer shows *"The
included Syncfusion® key and package versions do not match"* across the top
of the document. The key is `PDF_RENDER_SYNCFUSION_SECRET_KEY` in the
bind-mounted `config/constants.json`.

The release that pins `ps-client:8.41` ships the new key. On a bootstrapped
host, `git stash pop` after the pull **conflicts** on it: the key line sits
next to `PDF_TEST_PATH`, which `bootstrap.sh` / `configure-host.sh` set to
this host's hostname, and git treats two changed neighbouring lines as one
conflict:

```
<<<<<<< Updated upstream
    "PDF_RENDER_SYNCFUSION_SECRET_KEY": "<the release's new key>",
    "PDF_TEST_PATH": "https://padsign.example.com/template",
=======
    "PDF_RENDER_SYNCFUSION_SECRET_KEY": "<the old key>",
    "PDF_TEST_PATH": "https://<this host>/template",
>>>>>>> Stashed changes
```

Keep the **upper** key line and the **lower** `PDF_TEST_PATH` line, remove
the rest, then finish the pop as in
[When `git stash pop` reports a conflict](#when-git-stash-pop-reports-a-conflict)
(`git restore --staged .`, `git stash drop`). Check that the key is now the
release's:

```bash
git diff -- config/constants.json | grep SYNCFUSION   # expect no output
```

- **Your own Syncfusion licence** instead of the repository's key: generate
  a 34.x key in your Syncfusion account (*License & Downloads* > *Get License
  Key*, version `34.x.x`) and put that in instead. The `grep` above then
  shows your key, which is expected.
- **Customized (overlay) host:** the overlay carries its own
  `constants.json`, so `overlay.sh rebase` reports the same conflict in
  `$NEW_OVERLAY/files/config/constants.json`. Resolve it the same way, then
  run `overlay.sh rehash --overlay "$NEW_OVERLAY"`
  ([9.11, Upgrading an overlay host](09-11-start-at-boot-backups-and-customized-hosts.md#upgrading-an-overlay-host)).

`upgrade.sh` recreates `ps-client`, so the container picks up the edited
file. Afterwards, check what the pads are served and reload a pad page (no
banner):

```bash
curl -s https://padsign.example.com/portal/constants.json | grep SYNCFUSION   # the new key
```

The key is valid for 8 Syncfusion major versions from 34, so later client
releases keep it. Rolling `ps-client` back to `8.40` or older needs the old
key back: [9.8, Rolling ps-client back across the Syncfusion 34 boundary](09-08-rollback.md#rolling-ps-client-back-across-the-syncfusion-34-boundary).

## Step 2: Preview the changes

Read the tags the pulled `docker-compose.yml` pins, and preview:

```bash
cd /opt/padsign
grep -oE 'mihailsgordijenko/ps-(server|client):[0-9.]+' docker-compose.yml
./installation-scripts/upgrade.sh --server-tag <server tag> --client-tag <client tag> --plan-only
```

`--plan-only` writes nothing and starts or restarts nothing. It prints the
image change (from the running tag to the new one) and every configuration
migration that would run, with the exact text it would add. For a routine
release it normally ends with *No configuration changes*. Add
`--enable-local-eseal` to see what enabling local e-sealing would change.
A plain upgrade never changes how ps-server reaches the DMSS services; a host
that runs on the public addresses switches when you decide to
([7.4](07-04-server-config-js.md#how-ps-server-reaches-the-dmss-services)).
How to read the output: [9.7](09-07-previewing-upgrade-changes.md).

A tag the new `release/approved-digests.json` does not approve is refused
here (exit 2) and by the real run.

## Step 3: Run the upgrade

```bash
cd /opt/padsign
 read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD   # only if the admin password was changed since Keycloak's first boot
./installation-scripts/upgrade.sh --server-tag <server tag> --client-tag <client tag>
unset KEYCLOAK_ADMIN_PASSWORD
```

The admin password is used for one step: making sure `padsign-backend` is
in the access-token audience of `padsign-client`
([8.2 Token audience](08-02-token-audience.md)). Without the variable the
script uses the password the Keycloak container was started with, which is
right until someone changes the password in the admin console. If Keycloak
cannot be reached, that step prints a warning with the fix and the upgrade
continues.

What you see: a few pre-flight checks, then `Step 1/6` to `Step 6/6`
(with sub-steps `4b` to `4e`), the running container versions, and
`Upgrade complete!` with the rollback command. Details:
[9.6](09-06-what-upgrade-does.md).

If the new services do not become healthy, the script prints
`UPGRADE FAILED`, the reason and the exact `rollback.sh` command, and exits
`1`. See [9.8 Rollback](09-08-rollback.md).

## Step 4: Verify

```bash
cd /opt/padsign
./installation-scripts/postdeploy-check.sh --host padsign.example.com --company-role "<company role>"
./installation-scripts/upgrade.sh --server-tag <server tag> --client-tag <client tag> --plan-only
```

`postdeploy-check.sh` runs the configuration, Keycloak, redirect, portal,
API-protection and TLS checks ([5.3 Post-deploy checks](05-03-post-deploy-checks.md)).
The second preview must report every migration as *already applied*.

Then sign one document end to end ([5.4 Signing smoke test](05-04-signing-smoke-test.md)).
With receive-back in use, check that a Padsign Manager receives it.

## Upgrading from the wizard

The wizard's **Dashboard** shows the running `ps-server` / `ps-client`
versions, the health checklist and an **Upgrade** panel. Update the
checkout first (step 1, on the host), then start the wizard.

The panel compares the pinned versions with what
`release/approved-digests.json` approves:

| State | What you see | What to do |
|---|---|---|
| Up to date | "You're on the latest version" | Nothing. **Deploy a specific version instead** opens the manual form |
| Update available | The new version next to the current one | **Preview upgrade to `<tag>`** |
| Unknown | The manual tag form | Enter the tags (leave one blank to keep that image), optionally tick **Enable local e-sealing**, click **Preview changes** |

Every route goes through the preview, *Review this upgrade*
(`upgrade.sh --plan-only`). Choose **Apply and upgrade** (labelled **Pull
images and restart** when no configuration would change) or **Cancel**. The
wizard cannot skip the preview, and it has no `--allow-unapproved`: an
unapproved tag shows the refusal instead of a plan. After you apply, the
live progress follows `upgrade.sh`'s steps. A failed
run offers **Retry**, **Back to Dashboard** and **Copy log**. The wizard
has no rollback button: use `rollback.sh` on the host
([9.8](09-08-rollback.md)).

On an overlay-managed host the panel offers no upgrade and the server
refuses one: upgrade it as in
[9.11, Upgrading an overlay host](09-11-start-at-boot-backups-and-customized-hosts.md#upgrading-an-overlay-host).

## Options

| Option | Use |
|---|---|
| `--server-tag X` / `--client-tag Y` | The ps-server / ps-client tag to move to. Either alone is valid |
| `--enable-local-eseal` | Also provision local e-sealing; valid on its own ([10.4 Existing deployment](10-04-existing-deployment.md)) |
| `--use-internal-dmss-urls` / `--use-public-dmss-urls` | Switch the five DMSS addresses in `config.js` to the in-network form, or back to the public one. Valid on its own, never part of a plain upgrade, and not combined with each other ([7.4](07-04-server-config-js.md#how-ps-server-reaches-the-dmss-services)) |
| `--plan-only [--plan-format text\|machine]` | Preview only ([9.7](09-07-previewing-upgrade-changes.md)) |
| `--require-capability NAME` | Refuse unless the resulting tags are new enough for a capability in `release/capabilities.json`, e.g. `closable-download-route` before closing the download route ([6.1 Route protection](06-01-route-protection.md)). Repeatable |
| `--health-timeout N` | Seconds to wait for the restarted services to be healthy (default 480) |
| `--rollback-on-failure` | Run `rollback.sh --yes` automatically when the upgrade fails. The upgrade still exits `1` |
| `--allow-unapproved` | Emergency hotfix only, on TrustLynx support's instruction: lets a tag through that `release/approved-digests.json` does not approve. It is not digest-pinned, `validate-config.sh` and `postdeploy-check.sh` fail until it is approved, and the override is recorded in `deployment-evidence.json` |

To go back to an older release, use `rollback.sh`, not `upgrade.sh` with
an older tag: the new checkout does not approve an older tag.

## Hosts without git access

On a host that cannot reach the git remote, download the release archive
on a machine that can, copy it to the host and unpack it next to the
deployment. Copy the release's files over the deployment, except the host
files in the table above, which you merge by hand with the same rules as
for a conflict. Never delete `.env`, `nginx/certs/`, `signed-output/`,
`docs/`, the `*.bak` files or `.rollback-snapshots/`. Then continue with
step 2.
