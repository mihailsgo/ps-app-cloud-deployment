# 14.7 Break-glass: recovering when no Keycloak credential works at all

This is for a different, more severe situation than [37.5 Known gap: Keycloak
admin password rotation](37-05-known-gaps-keycloak-admin-password-rotation.md).
That page covers rotating the admin password when you still have **some**
currently-working credential to log in with. This page is for when **nothing**
authenticates at all — no documented admin password, no documented test-user
password, nothing — which is exactly the situation that leaves a deployment
unable to complete authenticated verification or provision any login.

Once you've recovered a working admin session with the steps below, finish the
job using [37.5](37-05-known-gaps-keycloak-admin-password-rotation.md)'s
existing kcadm workflow to set the password you actually intend to keep.

## Why "just reset it in docker-compose.yml" doesn't work here

`docker-compose.yml`'s `KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD` env vars are
only consumed by Keycloak the first time it boots against an **empty** data
volume (see [17.1](17-01-keycloak-container-environment-variables.md)).
Editing them and restarting an already-initialized Keycloak changes nothing on
the live instance — it would silently look like it worked while doing nothing.
The only way to reset the volume and have those env vars take effect again is
to delete it, which destroys the realm, every client, and every user. That is
a last resort, not a break-glass step, and this repo has no script that does
it.

## The recovery mechanism: Keycloak's own `bootstrap-admin` command

Keycloak ships an admin-recovery command specifically for this situation:
`kc.sh bootstrap-admin user`. It creates a new administrator account directly
in the **existing** database — it does not wipe any realm, client, or user
data. It was verified hands-on for this doc against this repo's exact pinned
image (`quay.io/keycloak/keycloak:26.3.2`), run locally with
`docker compose up -d keycloak` and no other services running. It was **not**
run against any live production deployment — verify it there yourself before
relying on it, and see the caveats below.

**Prerequisite: Keycloak must be stopped.** Per Keycloak's own documentation
(<https://www.keycloak.org/server/bootstrap-admin-recovery>), all Keycloak
nodes using the database must be stopped before running this command. That
means a brief planned outage — seconds, in local testing — during which
active users will need to re-authenticate once Keycloak is back. This is a
materially smaller disruption than deleting the volume (no data is lost,
existing sessions just need to re-login), but it is not zero-interruption;
schedule it like any other brief restart.

```bash
# 1. Stop Keycloak. Nothing else in the stack needs to stop.
docker compose stop keycloak

# 2. Run the recovery command against the same volume, as a one-off
#    container (this does NOT start the normal server process).
export RECOVERY_PW='<pick a strong temporary password>'
docker compose run --rm -e RECOVERY_PW keycloak bootstrap-admin user \
  --username temp-admin --password:env RECOVERY_PW --no-prompt

# 3. Bring Keycloak back up normally.
docker compose up -d keycloak
```

Expected output from step 2 includes a line like:
```
INFO  [org.keycloak.services] (main) KC-SERVICES0077: Created temporary admin user with username temp-admin
```

The account is always created in the **master** realm, regardless of which
realm (e.g. `padsign`) you're actually troubleshooting.

## After recovery

1. Confirm the temporary account works:
   ```bash
   docker compose exec -T keycloak sh -lc \
     "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user temp-admin --password '<RECOVERY_PW>'"
   ```
2. Use it to either fix the real admin account's password (via the admin
   console, or [37.5](37-05-known-gaps-keycloak-admin-password-rotation.md)'s
   `kcadm.sh set-password` steps) — or just keep using it and record it
   properly (see below).
3. **Delete the temporary account once you're done with it** — Keycloak's own
   guidance is that it should exist only for as long as necessary:
   ```bash
   docker compose exec -T keycloak sh -lc \
     "/opt/keycloak/bin/kcadm.sh delete users/\$(/opt/keycloak/bin/kcadm.sh get users -r master -q username=temp-admin --fields id --format csv | tail -n 1 | tr -d '\r\"') -r master"
   ```
4. Once admin access works again, use
   [`smoke-user.sh`](14-02-automated-setup-recommended.md#disposable-smoke-test-users)
   for routine smoke-testing instead of touching the shared `test` account.

## Where the real credential belongs

This repo does not choose or wire up a secret-management system — that
decision, and who owns it, belongs to whoever operates each deployment.
Record both of these somewhere durable before you close out a recovery:

- **Credential owner:** _\<record who is accountable for this deployment's
  Keycloak admin credential\>_
- **Secret storage:** _\<point this at your organization's approved
  secret-management system — a password manager, a vault, whatever you
  actually use\>_

An undocumented shared credential with no owner is exactly the situation that
made this recovery necessary in the first place.
