# 3.4 Troubleshooting the wizard

Fixes for problems with the wizard itself: reaching it, unlocking it, and runs that fail or seem
stuck. For problems with PadSign after the install, see [12. Troubleshooting](12-troubleshooting.md).

## The browser cannot reach https://localhost:8443

1. Check the container is running and healthy:

   ```bash
   docker ps --filter name=padsign-wizard
   ```

2. Check its log for a start-up error: `docker logs padsign-wizard`.
3. Check the SSH tunnel is still open (`ssh -L 8443:localhost:8443 user@padsign.example.com`) and
   that nothing else on your workstation uses local port 8443. If something does, tunnel from
   another local port ([3.1](03-01-starting-the-wizard.md#4-open-an-ssh-tunnel-and-browse-to-the-wizard)).
   Browsing to the host's own address instead of `localhost` does not work: the wizard listens on
   the host's loopback address only, unless `WIZARD_BIND_ADDRESS` is set in `.env`
   ([3.1](03-01-starting-the-wizard.md#reaching-the-wizard-without-a-tunnel-wizard_bind_address)).
4. Make sure you typed `https://`, not `http://`. The wizard only serves HTTPS.

## The browser warns "connection is not private"

Expected. The wizard uses its own self-signed certificate
([3.3 How the wizard works](03-03-how-the-wizard-works.md#two-certificates)). Click through the
warning (in Chrome: **Advanced** -> **Proceed to localhost**).

If the browser reports a **name mismatch** and will not let you continue, you are using an address
the wizard's certificate does not cover. Use the SSH tunnel and `https://localhost:8443`, or add the
address with `WIZARD_TLS_SANS` in `.env`
([3.1](03-01-starting-the-wizard.md#the-wizards-certificate-names-wizard_tls_sans)).

## "Invalid token" or lost token

The token changes every time the container starts. Read the current one:

```bash
docker logs padsign-wizard
```

If the log holds several start-up banners, use the last one. To get a fresh token, restart the
wizard from `/opt/padsign`:

```bash
docker compose --profile wizard restart wizard
docker logs padsign-wizard
```

A restart discards unsaved answers in an install that is in progress (use **Save & Exit** first to
keep them). Nothing already written to disk is affected.

## The container will not start or exits immediately

- Confirm you started it from `/opt/padsign` with
  `docker compose --profile wizard up -d wizard`, and not with plain `sudo`
  ([3.1](03-01-starting-the-wizard.md#2-start-the-wizard-from-optpadsign)). Started from the wrong
  directory, the wizard gets the wrong path and later runs fail with path errors.
- Confirm `/var/run/docker.sock` exists on the host and your user can use Docker
  (`docker ps` works without `sudo`).
- Confirm nothing else on the host listens on port 8443.

## Step 1 shows Docker as FAIL

The wizard cannot reach the Docker daemon. The container was started without its
`/var/run/docker.sock` mount, or the socket is not accessible. Recreate it from `/opt/padsign` with
`docker compose --profile wizard up -d wizard`, using the unmodified `wizard` service from
`docker-compose.yml`.

## The Welcome screen shows DEPLOYED_STOPPED or the Dashboard instead of a fresh install

The directory has been installed before (`docker-compose.yml.bak` exists). **DEPLOYED_STOPPED** means
the stack is installed but not running; start it with `docker compose up -d` from `/opt/padsign`, or
run the install again from the Welcome screen if a previous attempt failed partway. If you meant to
install on a clean host, check you started the wizard in the right directory.

## Settings and Upgrade are disabled, with an "overlay-managed" banner

The deployment directory contains `.overlay-applied.json`: the host runs from an environment
overlay, and the wizard does not change it ([3.3, Overlay-managed hosts](03-03-how-the-wizard-works.md#overlay-managed-hosts)).
A request made anyway is answered with *This host is overlay-managed* and HTTP 409. Make the change
on the host through a new overlay version
([9.11](09-11-start-at-boot-backups-and-customized-hosts.md#living-with-an-overlay)).

## A run seems stuck

- In an install, **step 5 (Keycloak)** prints nothing for up to a minute or two, and **step 7**
  waits until every service is healthy, which can take several minutes on a first start. That is
  the script, not the wizard.
- Open the **Raw output** panel on the progress screen to see the script's latest output.
- Only one install, upgrade or settings run can happen at a time. If the wizard says a run is
  already in progress but you cannot see it, the wizard may have restarted during the run. Check the
  stack directly (`docker compose ps`, `docker compose logs keycloak`, `docker compose logs
  ps-server`) to see whether the script finished.

## A run failed

The progress screen shows a red banner with the script's exit code, marks the failed step
**FAILED** and offers three buttons:

- **Retry** re-runs the same script with the same arguments; you re-enter nothing. Use it for a
  transient failure: a slow or rate-limited image pull, a service that was not ready yet, a brief
  network problem.
- **Back to ...** returns to the screen the run started from (Review, Dashboard or Settings) so you
  can change an input.
- **Copy log** copies the full output to the clipboard. Always copy it before you ask for help.

Retry only works while the wizard still holds the run in memory. After a wizard restart it reports
that the run is no longer available; start the action again from its own screen.

A failure that repeats after one or two retries is a real problem with the host or its inputs. Read
the error in the log (the script usually prints what to fix), fix it, and run again. If you cannot
resolve it, send the copied log to TrustLynx support ([14.5 Support](14-05-support.md)).

If an install fails partway, the configuration files were backed up in step 1 (`*.bak`). The
script's error message says how to restore them, exactly as for a command-line install
([4.1 What bootstrap does](04-01-what-bootstrap-does.md)).

## Live progress shows raw lines instead of named steps

The wizard reads the scripts' normal text output to build the step list. If it cannot recognise the
output, it shows the lines as they are. The script still runs correctly; only the display is
affected. Follow the result in the **Raw output** panel and report it to TrustLynx support.
