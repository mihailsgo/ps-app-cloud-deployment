# 36.4 Upgrade walkthrough

The dashboard (step 8 of the onboarding flow, or `https://<host>:8443/dashboard`
directly on a return visit) shows:

- **Current versions** — the `ps-server`/`ps-client` image tags read
  directly out of `docker-compose.yml`.
- **Health checks** — the same live checklist as
  [validate-config.sh](06-validating-configuration.md), refreshed every time
  you load the page.
- **Upgrade panel** — wired to
  [upgrade.sh](05-upgrading-an-existing-deployment.md).

## The upgrade panel's three states

The panel shows exactly one of three things, decided by comparing the
installed tags against `documentation/01-release-snapshot.md` in this
checkout:

| State | What you see | What to click |
|---|---|---|
| **Up to date** | A green tick and "You're on the latest version" | Nothing needed. **Deploy a specific version instead** opens the manual form. |
| **Update available** | The newer version named, alongside your current one | **Preview upgrade to `<tag>`** — no tags to type. |
| **Unknown** | The manual tag form directly | Fill in the tags yourself (see below). |

The **unknown** state means the wizard couldn't determine a latest version
at all — usually because this checkout has no
`documentation/01-release-snapshot.md`. It shows the manual form rather than
guessing, since claiming "up to date" or naming an available version it
can't actually resolve would be misleading either way.

## The manual tag form

Enter the tag(s) you want (leave either blank to leave that image
untouched — same rule as the CLI: `upgrade.sh --server-tag X.XX` alone is
valid, so is `--client-tag` alone), optionally tick **Enable local
e-sealing**, and click **Preview changes**. **Use recommended version instead**
returns you to whichever of the two automatic states applies.

## The preview step

Both routes lead to a **preview** rather than straight to a run. The wizard
executes `upgrade.sh --plan-only` — which writes nothing and touches no
container — and shows the image-tag change plus every configuration migration
that would fire, with the exact text each would add. You then choose **Apply**
or **Cancel**.

This gate cannot be bypassed from the UI, and it is enforced server-side:
`/api/deploy` no longer accepts an upgrade request at all.

For a routine version bump the preview will usually report *no configuration
changes* — the migrations are additive and already satisfied. That is the
expected, reassuring result. Full detail, including why customised values are
never overwritten, is in
[36.9 Previewing configuration changes](36-09-previewing-configuration-changes.md).

## Live progress

After Apply, the flow lands on the identical live-progress view from the
fresh-install flow, this time running `upgrade.sh`'s own 6 steps (a `4b`
sub-step appears when local e-sealing is being enabled). Nothing about the
progress-tracking or error-surfacing differs between a bootstrap and an
upgrade — it's the same underlying mechanism pointed at a different script,
which is deliberate: it proves the wizard isn't special-cased to
`bootstrap.sh`.

A failed upgrade offers **Retry** (re-runs the same tags without retyping
them), **Back to Dashboard**, and **Copy log**.

Only one deploy/upgrade run can be active at a time. While one is running,
the top bar's Dashboard/Settings/Log Out controls are greyed out with a
"Run in progress — navigation locked" note, and unlock themselves the moment
the run finishes. If you navigate away and come back, the dashboard shows a
banner linking to the in-progress run.

`upgrade.sh`'s own `--enable-local-eseal` version guard still applies — if
your current (or newly-requested) `ps-server` tag predates the version that
understands local e-sealing, the run will fail fast with the script's own
explanatory error, exactly as it would from the CLI.

Managing additional Keycloak users (the CLI's `--users` flag on
`bootstrap.sh`) is not available in the wizard — see
[36.7 Relationship to the CLI scripts](36-07-relationship-to-the-cli-scripts.md).
