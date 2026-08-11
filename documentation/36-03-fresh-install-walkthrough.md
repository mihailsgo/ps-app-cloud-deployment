# 36.3 Fresh-install walkthrough

Eight steps, each mapping directly to something
[bootstrap.sh](03-quick-start-new-deployment.md) already does.

1. **Welcome & environment check** — confirms the wizard can reach the
   Docker daemon and shows the mounted project directory. A red check here
   almost always means the container is missing its
   `/var/run/docker.sock` mount.
2. **Host & company info** — hostname, company/role name, Keycloak realm
   name, admin username and password. A live (informational only) hint
   shows whether the hostname currently resolves from this host — it never
   blocks you from continuing, since some deployments only resolve via
   internal DNS or a hosts-file entry added later.
3. **TLS certificate** — upload or paste a fullchain certificate and its
   matching private key. Validated immediately using the exact same checks
   as [validate-certs.sh](11-01-tls-prerequisites-for-installation-scripts.md):
   chain completeness, key match, hostname match, expiry. You cannot proceed
   until it passes (or you explicitly check "allow self-signed" for a
   development/internal deployment).
4. **Feature toggles** — document routing, demo mode, local e-sealing. All
   off by default; each has a one-line explanation.
5. **Review & confirm** — every value you entered, shown as the equivalent
   `bootstrap.sh` command line would look. The admin password is masked
   behind a reveal toggle. Nothing is written to disk or Docker yet.
6. **Deploy** — click "Confirm & Deploy" and watch bootstrap.sh's actual
   8 steps run live, each as its own row with a spinner while it's running
   and a check or cross once it finishes. Step 5 (Keycloak) pauses with no
   output for up to a minute by design — that's `bootstrap.sh` itself
   capturing the output so it can filter a secret out of the log before
   printing it, not the wizard hanging. On failure the screen offers
   **Retry** (re-runs the identical command with the same answers, admin
   password included — nothing to re-enter), **Back to Review**, and
   **Copy log**.
7. **Verify & go-live checklist** — the same checks as
   [validate-config.sh](06-validating-configuration.md), plus a reminder to
   delete the demo `test` Keycloak user before production use. Failures are
   shown but never block you from continuing — fix them at your own pace.
8. **Dashboard** — where you land from here on. See
   [36.4 Upgrade walkthrough](36-04-upgrade-walkthrough.md).

Steps 1-7 carry a clickable progress rail: any step you've already been
through can be revisited without clicking Next through the ones in between.
The server enforces the same bound the rail draws, so a hand-typed URL can't
skip ahead of where you've actually got to. **Save & Exit** on the rail
stores your answers (everything except the Keycloak admin password) and
offers to resume them next time you unlock the wizard.

If anything fails partway through, `bootstrap.sh`'s own backups
(`config/config.js.bak`, etc., created in its step 1) are exactly what you'd
have if you'd run it from the CLI — restore them the same way the script's
own error message describes. Prefer the **Retry** button for a transient
failure: it re-runs the same script with the same arguments rather than
starting a fresh flow.
