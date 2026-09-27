# 3.3 How the wizard works

This page explains what the wizard is, what it can do on your host, and how access to it is
controlled, so you can decide how to run it safely.

## It runs the installation scripts

The wizard does not have its own install logic. Every action runs one of the scripts in
`installation-scripts/` as a child process and reads its output:

| Wizard action | Script it runs |
|---|---|
| Certificate check (step 3) | `validate-certs.sh` |
| Deploy (step 6) | `bootstrap.sh` |
| Verify & Go-Live (step 7) | `validate-config.sh` |
| Upgrade (Dashboard) | `upgrade.sh`, previewed first with `upgrade.sh --plan-only` ([9.7](09-07-previewing-upgrade-changes.md)) |
| Settings: hostname, certificate, features | `update-hostname.sh`, `renew-cert.sh`, `toggle-features.sh` ([9.1](09-01-changing-hostname.md), [9.2](09-02-renewing-the-tls-certificate.md), [9.4](09-04-toggling-features.md)) |

So an install done in the wizard is the same as one done with
[4. Install from the command line](04-install-from-the-command-line.md), and you can use the CLI
scripts at any time on a wizard-installed host. The wizard adds certificate checks before anything
is written, step-by-step progress, a dashboard and a retry button.

One option is CLI-only: extra Keycloak users at install time (`bootstrap.sh --users`,
[4.2 Bootstrap parameters](04-02-bootstrap-parameters.md)). The wizard creates the admin account
and the demo `test` user only; add other users in the Keycloak admin console afterwards.

## No database of its own

The wizard stores nothing about your deployment. Each time a page loads it looks at the host: the
`docker-compose.yml.bak` backup that `bootstrap.sh` and `upgrade.sh` leave behind, and the output of `docker compose ps`. From these it
decides whether the deployment is **FRESH** (show the install flow), **DEPLOYED** (show the
Dashboard), **DEPLOYED_STOPPED** (installed but not running) or **UNKNOWN**. Every value on the
Dashboard and Settings pages is read from the files on disk and from Docker.

Your answers during the install are kept in your browser session in the wizard's memory. If the
wizard container restarts mid-install you lose those answers, never anything already written to
disk. **Save & Exit** writes them to `.wizard-saved-progress.json` in the deployment directory
(mode 600) so you can resume later; the Keycloak admin password is left out.

One wizard serves one deployment: the one in the directory it was started from.

## Two certificates

The wizard needs HTTPS before your PadSign certificate is installed, so it generates its own
self-signed certificate every time it starts and uses it only for port 8443. Your browser warns
about it; that is expected. The PadSign certificate you upload in step 3 is the one nginx serves to
users on port 443. [3.1 Starting the wizard](03-01-starting-the-wizard.md#the-wizards-certificate-names-wizard_tls_sans)
explains which names the wizard's certificate covers.

## Access: a token, not a password

At every start the wizard generates a random access token and prints it only to its own log
(`docker logs padsign-wizard`). There are no user accounts. A browser session stays unlocked for up
to two hours, then you enter the token again. Restarting the container invalidates the old token and
every open session.

## The most privileged container in the stack

The wizard mounts `/var/run/docker.sock` so it can run `docker compose` for you. No other PadSign
service does. Access to the Docker socket is equivalent to root access on the host: whoever
controls the wizard can start privileged containers and read or change any file on the host. The
deployment directory it mounts also contains your secrets (`.env`, `config/config.js`, the TLS key)
and the `.git` directory.

The protection is who can reach port 8443 and who holds the token:

- **Keep port 8443 on loopback** and use the SSH tunnel from [3.1](03-01-starting-the-wizard.md).
  By default the port is published on `127.0.0.1` only, so the network cannot reach it. If you set
  `WIZARD_BIND_ADDRESS` in `.env` to open it on a network interface, a network firewall in front of
  the host is what keeps it private: Docker-published ports bypass host firewalls such as `ufw`
  ([2.3 Network and firewall](02-03-network-and-firewall.md)).
- **Treat the token as a credential.** Anyone who can run `docker logs` on the host can read it.
- **Stop the wizard when you are done**: `docker compose --profile wizard stop wizard` from
  `/opt/padsign`. Otherwise `restart: unless-stopped` brings it back after a reboot.

How the wizard handles the Keycloak admin password:

- It is never on a command line. The wizard passes it to the scripts in the
  `KEYCLOAK_ADMIN_PASSWORD` environment variable, which only the same user and root can read,
  unlike command-line arguments, which every local user sees in `ps`.
- It is never written to disk by the wizard, never logged, and never put in the session cookie.
- After a run it stays in the wizard's memory so **Retry** can repeat the run without asking you
  again. Stopping the wizard clears it.

Nothing the wizard does needs more access than an operator running the scripts by hand from a shell
on the host. The difference is who can trigger it: anyone with the token and a route to port 8443.

## Keyboard and screen-reader use

Every control can be reached with `Tab` and has a visible focus ring. The progress rail is a list of
links. Dialogs keep focus inside while open and close with `Esc`. Live progress and the final result
are announced to screen readers. Buttons that are waiting for something (**Next: Feature Toggles**,
**Continue to Verify**) say in plain text what unlocks them. A "Skip to main content" link comes
first on every page.
