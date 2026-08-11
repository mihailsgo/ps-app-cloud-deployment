# 36.6 Troubleshooting the wizard

## Can't reach `https://<host>:8443`

- Confirm the container is running: `docker ps --filter name=padsign-wizard`.
- Check the container's own logs for a startup error:
  `docker logs padsign-wizard`.
- Confirm port 8443 isn't blocked by a firewall between your browser and the
  host.

## Lost or don't have the access token

The token is only ever printed to the container's logs, regenerated fresh
on every start:

```bash
docker logs padsign-wizard
```

If you need a new one, restart the container — a new token is generated
automatically:

```bash
docker compose restart wizard
```

Note this ends any in-progress onboarding session's in-browser form state
(nothing already written to disk is affected).

## Browser warns "connection is not private"

Expected — see [36.1 Concepts and access model](36-01-concepts-and-access-model.md).
Proceed past the warning (in Chrome: "Advanced" → "Proceed to `<host>`
(unsafe)"). This is the wizard's own throwaway certificate, unrelated to the
real PadSign hostname certificate you upload during the flow.

## Container won't start / exits immediately

- Confirm you ran `docker compose --profile wizard up -d wizard` **from the
  project root** — see [36.2 Starting the wizard](36-02-starting-the-wizard.md)
  for why this matters. Running it from any other directory can produce
  confusing path-related failures once a deploy/upgrade actually tries to
  run `docker compose` against the wrong location.
- Confirm `/var/run/docker.sock` exists on the host and the user running
  `docker compose` has permission to access it.

## A deploy/upgrade seems stuck

- Step 5 of a **bootstrap** run (Keycloak) is expected to show no new output
  for up to a minute — this is `bootstrap.sh` itself, not the wizard. Give
  it up to 2 minutes before assuming it's actually stuck.
- Check the collapsible "Raw output" panel on the live-progress screen for
  the actual script output, or `docker logs padsign-wizard` for the wizard's
  own process logs.
- Only one deploy/upgrade run is allowed at a time. If you get "a
  deploy/upgrade run is already in progress" but don't see one in the UI,
  the wizard container may have restarted mid-run — check
  `docker compose logs` for the affected services (`keycloak`, `ps-server`,
  etc.) directly to see whether the underlying script actually finished.

## A deploy/upgrade/settings run failed — what now?

The progress screen shows a red banner with the script's exit code, marks
the failed step **FAILED**, and offers three actions:

- **Retry** — re-runs the *identical* script with the *identical*
  arguments. Nothing is re-entered, including a bootstrap's Keycloak admin
  password, so a retry can't accidentally differ from what just ran. Right
  choice for a transient failure: a slow or rate-limited image pull, a
  dependency container not up yet, a brief network blip.
- **Back to …** — returns to the screen you launched from (Review,
  Dashboard, or Settings) so you can change an input before trying again.
- **Copy log** — copies the complete raw output to your clipboard. Always
  do this before escalating; it's the same text the collapsible **Raw
  output** panel shows.

Retry only works while the wizard container has the original run in memory.
If the container restarted since the failure, Retry reports that the run is
no longer available — start the action again from its own screen instead.

Don't retry the same failure more than once or twice. A failure that
reproduces is a real problem in the underlying script or environment, not
something a retry will clear — send the copied log on.

## The wizard's own regexes stop matching a script's output

The wizard parses the existing human-readable output of `bootstrap.sh` /
`upgrade.sh` / `validate-config.sh` / `validate-certs.sh` rather than a
dedicated machine-readable format (see
[36.7 Relationship to the CLI scripts](36-07-relationship-to-the-cli-scripts.md)).
If one of those scripts' wording changes without a matching update to
`deployment-wizard/lib/outputParser.js`, live progress can degrade to
generic/raw lines instead of structured steps — the underlying script still
runs correctly either way, only the wizard's display is affected. Anyone
changing wording in `installation-scripts/*.sh` should re-run
`deployment-wizard/test/*.test.js` and refresh its fixtures.
