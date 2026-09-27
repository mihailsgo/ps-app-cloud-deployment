# 8.3 Admin password and break-glass recovery

This page covers where the Keycloak master-realm admin password comes from,
how to change it on a running deployment, and how to recover when no
credential works at all.

## Where the password comes from

The keycloak service in `docker-compose.yml` sets `KEYCLOAK_ADMIN` and
`KEYCLOAK_ADMIN_PASSWORD`. The password comes from
`KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD` in `.env`, which `bootstrap.sh
--admin-pass` writes ([7.6](07-06-environment-variables.md)).

Keycloak uses these values **only the first time it starts against an empty
`keycloak_data` volume**, to create the admin account. After that the
password lives in Keycloak's database. Editing `.env` or re-running
`configure-host.sh --admin-pass` and restarting then changes nothing in
Keycloak, although it looks as if it worked. No PadSign script, and no page in
the wizard's Settings, changes the admin password of a running Keycloak. Use
one of the methods below.

## Changing the password (you can still log in)

### Admin console

Open `https://padsign.example.com/auth/admin/`, log in to the **master**
realm, then go to **Users** → your admin account → **Credentials** →
**Reset password**. Turn **Temporary** off.

### Command line

Neither password appears on a command line, neither on the host nor inside
the container (container processes show up in the host's `ps` too). The
current password reaches kcadm as `KC_CLI_PASSWORD`. The new one goes to the
admin REST endpoint as JSON on standard input, written by bash's `printf`
builtin, which starts no process.

```bash
cd /opt/padsign
read -rs CUR_PW && read -rs NEW_PW   # current, then new password; nothing is echoed
KC_CLI_PASSWORD="$CUR_PW" docker compose exec -T -e KC_CLI_PASSWORD keycloak sh -lc \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user admin </dev/null'
bs='\' dq='"'; v=${NEW_PW//"$bs"/"$bs$bs"}; v=${v//"$dq"/"$bs$dq"}   # JSON-escape \ and "
printf '{"type":"password","value":"%s","temporary":false}' "$v" | docker compose exec -T keycloak sh -lc \
  'K=/opt/keycloak/bin/kcadm.sh; id=$($K get users -r master -q username=admin -q exact=true --fields id --format csv --noquotes </dev/null | tail -n 1 | tr -d "\r"); [ -n "$id" ] && [ "$id" != id ] && $K update users/$id/reset-password -r master -f - -n && echo PASSWORD-SET'
docker compose exec -T keycloak sh -c 'rm -f "$HOME/.keycloak/kcadm.config"'   # end the admin session
unset CUR_PW NEW_PW v
```

Replace `admin` in both commands if your admin account has another name.
`PASSWORD-SET` confirms the change.

### Afterwards

- Store the new password in your secret manager.
- **Do not** write it into `docker-compose.yml`. That file is tracked and
  world-readable ([7.6](07-06-environment-variables.md)).
- Updating `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD` in `.env` is optional.
  Keycloak never reads it again on this volume, but `upgrade.sh` falls back
  to it when you have not exported `KEYCLOAK_ADMIN_PASSWORD`
  ([8.2](08-02-token-audience.md)). Changing `.env` recreates the keycloak
  container on the next `docker compose up -d`, which means a short Keycloak
  restart.
- A restore of the `keycloak_data` volume brings back the password that was
  current when the backup was taken.

## Break-glass: no credential works

Use this when **nothing** authenticates: no admin password, no other admin
account. Resetting through `.env` does not work here (see above). The only
way to make Keycloak read `.env` again is to delete its volume, which
destroys the realm, every client and every user. That is a last resort, and
no script does it.

Keycloak's own recovery command, `kc.sh bootstrap-admin user`, creates a new
temporary administrator directly in the **existing** database. It does not
wipe any realm, client or user. See Keycloak's documentation:
<https://www.keycloak.org/server/bootstrap-admin-recovery>.

**Keycloak must be stopped while the command runs.** With the embedded H2
database this is enforced: if Keycloak is running, the command fails with
"Database may be already in use" and changes nothing.

Plan for Keycloak to be unavailable for about a minute. During that time
ps-server cannot validate tokens, so portal API calls fail and users have to
retry. Users are not logged out: Keycloak keeps SSO sessions in its database,
so refresh tokens issued before the restart still work. Schedule it like any
other short restart.

```bash
cd /opt/padsign

# 1. Stop Keycloak. Nothing else in the stack needs to stop.
docker compose stop keycloak

# 2. Run the recovery command against the same volume, as a one-off
#    container (the normal server does not start).
read -rs RECOVERY_PW && export RECOVERY_PW   # a strong temporary password; nothing is echoed
docker compose run --rm --no-deps -e RECOVERY_PW keycloak bootstrap-admin user \
  --username temp-admin --password:env RECOVERY_PW --no-prompt

# 3. Start Keycloak normally.
docker compose up -d keycloak
```

Step 2 prints a line like:

```
INFO  [org.keycloak.services] (main) KC-SERVICES0077: Created temporary admin user with username temp-admin
```

The account is always created in the **master** realm.

### After recovery

1. Check that the temporary account works:

   ```bash
   KC_CLI_PASSWORD="$RECOVERY_PW" docker compose exec -T -e KC_CLI_PASSWORD keycloak sh -lc \
     '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user temp-admin </dev/null'
   ```

2. Use it to reset the real admin account's password, in the admin console
   or with the command-line steps above (log in as `temp-admin`, reset the
   password of `admin`). Store the new password in your secret manager.
3. **Delete the temporary account** once you are done, and end the kcadm
   session:

   ```bash
   docker compose exec -T keycloak sh -lc \
     "/opt/keycloak/bin/kcadm.sh delete users/\$(/opt/keycloak/bin/kcadm.sh get users -r master -q username=temp-admin -q exact=true --fields id --format csv --noquotes | tail -n 1 | tr -d '\r') -r master"
   docker compose exec -T keycloak sh -c 'rm -f "$HOME/.keycloak/kcadm.config"'
   unset RECOVERY_PW
   ```

4. For routine smoke tests from now on, use `smoke-user.sh`
   ([8.1](08-01-automated-setup.md#disposable-smoke-test-users)).

### Record the credential

Record who owns this deployment's Keycloak admin credential, where it is
stored (your password manager or vault), when break-glass was last tested
and when the next rotation is due. Keep these records in your operations
documentation, never in this repository. A shared credential that no one owns
is what makes a recovery like this necessary.
