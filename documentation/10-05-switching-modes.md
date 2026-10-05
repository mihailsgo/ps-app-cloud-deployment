# 10.5 Switching modes

This page covers switching a running deployment between external and local
e-sealing. Use `installation-scripts/toggle-features.sh`. It changes the
settings, restarts only the services that need it, and then checks the result.
The Deployment Wizard's **Settings** page runs the same script from its
**Local e-sealing** switch. For the script's other feature flags, see
[9.4 Toggling features](09-04-toggling-features.md).

Run it from `/opt/padsign`. If you have just pulled a new release, run
`upgrade.sh` before this script ([9.5 Upgrading](09-05-upgrading.md)).

## External to local

```bash
cd /opt/padsign
./installation-scripts/toggle-features.sh --enable-local-eseal
```

The script:

1. Checks that the ps-server tag in `docker-compose.yml` meets the
   `local-eseal` minimum in `release/capabilities.json`. If the tag is older,
   it stops with exit code 2 before changing anything. Upgrade ps-server first
   ([10.4](10-04-existing-deployment.md)).
2. Runs `configure-host.sh --enable-local-eseal`, which makes the changes
   listed in [10.3](10-03-fresh-install.md#what-the-flag-changes). This works
   even if local e-sealing has never been enabled on this host, because the
   demo files are copied in when they are missing.
3. Runs `docker compose up -d dmss-container-and-signature-services dmss-digital-stamping-service`
   (container-signature is recreated if its environment changed), then
   restarts `ps-server`.
4. Prints `Local e-sealing: OK (STAMP_MODE=local)`.

The hostname is read from `nginx/nginx.conf`. Pass `--host padsign.example.com`
only if the script cannot find it.

## Local to external

```bash
./installation-scripts/toggle-features.sh --disable-local-eseal
```

The script sets `STAMP_MODE: "external"`, removes `local-eseal` from
`COMPOSE_PROFILES` in `.env` (and deletes the line if nothing else is left in
it), stops `dmss-digital-stamping-service`, restarts `ps-server`, and prints
`Local e-sealing: OK (STAMP_MODE=external)`.

It leaves some things in place on purpose, so that switching back is a single
command:

- the `STAMP_LOCAL` block in `config.js`
- the files in `dmss-digital-stamping-service/`, including your keystore
- the `SPRING_SECURITY_USER_*` variables on container-signature
- the patched `baseUrl`

External mode ignores all of them.

External mode needs working provider credentials. `STAMP_API_KEY`,
`STAMP_COMPANY_ID` and `STAMP_COMPANY_SECRET` in `config/config.js` must hold
your provider's values, not the shipped `CHANGE_ME`.

## Checking the active mode

```bash
grep -E 'STAMP_MODE' config/config.js
grep -E '^COMPOSE_PROFILES' .env
docker compose ps dmss-digital-stamping-service
docker compose logs --tail 50 ps-server | grep '\[stamp\] mode='   # after the next seal
```

## Switching by hand

Use this if you cannot run the script. Both edits are needed, and they must
agree (see [10. Local e-sealing](10-local-e-sealing.md#how-the-mode-is-selected)).

**To local.** This works only on a host where local e-sealing has already been
provisioned once. The `STAMP_LOCAL` block, the `SPRING_SECURITY_USER_*`
variables and the patched `baseUrl` must already be in place.

1. In `config/config.js`, set `STAMP_MODE: "local",`.
2. In `.env`, add `COMPOSE_PROFILES=local-eseal`. If a `COMPOSE_PROFILES=`
   line already exists, append `,local-eseal` to it.
3. Apply the change:
   ```bash
   docker compose up -d                 # starts the stamping container
   docker compose restart ps-server     # ps-server reads config.js only at start-up
   ```

**To external.**

1. In `config/config.js`, set `STAMP_MODE: "external",`. Leave the
   `STAMP_LOCAL` block where it is.
2. In `.env`, remove `local-eseal` from `COMPOSE_PROFILES`. Delete the line if
   nothing else is left in it.
3. Apply the change:
   ```bash
   docker compose stop dmss-digital-stamping-service
   docker compose restart ps-server
   ```
