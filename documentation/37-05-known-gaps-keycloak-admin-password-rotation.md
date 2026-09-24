# 37.5 Known gap: Keycloak admin password rotation

Settings deliberately does **not** offer a way to change the Keycloak
admin password on a live deployment. This is a documented gap, not an
oversight.

> This page assumes you have **some** currently-working Keycloak credential
> to log in with. If nothing authenticates at all — no admin password, no
> test-user password, nothing — see
> [14.7 Break-glass admin recovery](14-07-break-glass-admin-recovery.md)
> instead.

## Why

`docker-compose.yml`'s `keycloak` service takes `KEYCLOAK_ADMIN` /
`KEYCLOAK_ADMIN_PASSWORD` environment variables, but Keycloak only
consumes them to create its master-realm admin account **the first time
it boots against an empty database volume**. On an already-initialized,
already-live Keycloak, rewriting those env vars in `docker-compose.yml`
(which is exactly what `configure-host.sh --admin-user/--admin-pass`
does) has no effect on the real, live admin password — it would silently
look like it worked while changing nothing. No script in this repository
performs an actual `kcadm update-user`/`set-password` against a live
instance, and building one is a meaningfully different (and riskier)
change than anything else in Settings: a mistake here risks locking out
Keycloak admin access entirely, with no `configure-host.sh`-style
idempotent-and-safe-to-retry story to fall back on.

## The manual workaround

Rotate the Keycloak admin password directly, using whichever credential
still works to log in:

**Via the admin console** (`https://<host>/auth/admin/`):
Master realm → Users → the admin account → Credentials tab → Reset
Password.

**Via `kcadm` directly on the host:**

Neither password goes on a command line, not `docker compose`'s on the host
and not kcadm's inside the container (container processes are host
processes, so their command lines are in the host's `ps` too). The current
password reaches kcadm as `KC_CLI_PASSWORD`, which it reads when
`--password` is absent. The new one goes to the admin REST endpoint as JSON
on stdin, written by bash's `printf` builtin, which starts no process.
`kcadm.sh set-password` is not used because it only takes the new password
as `--new-password` on its command line.

```bash
 read -rs CUR_PW && read -rs NEW_PW                    # leading space: kept out of history (HISTCONTROL=ignorespace)
KC_CLI_PASSWORD="$CUR_PW" docker compose exec -T -e KC_CLI_PASSWORD keycloak sh -lc \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user <current-admin-user> </dev/null'
bs='\' dq='"'; v=${NEW_PW//"$bs"/"$bs$bs"}; v=${v//"$dq"/"$bs$dq"}   # JSON-escape \ and "
printf '{"type":"password","value":"%s","temporary":false}' "$v" | docker compose exec -T keycloak sh -lc \
  'K=/opt/keycloak/bin/kcadm.sh; id=$($K get users -r master -q username=<current-admin-user> -q exact=true --fields id --format csv --noquotes </dev/null | tail -n 1 | tr -d "\r"); [ -n "$id" ] && [ "$id" != id ] && $K update users/$id/reset-password -r master -f - -n && echo PASSWORD-SET'
docker compose exec -T keycloak sh -c 'rm -f "$HOME/.keycloak/kcadm.config"'   # end the admin session
unset CUR_PW NEW_PW v
```

Store the new value in your secret manager. **Do not** write it into
`docker-compose.yml`'s `KEYCLOAK_ADMIN_PASSWORD`. That file is tracked and
usually world-readable, and Keycloak never reads the variable again on an
existing volume. Disaster recovery restores the Keycloak data volume, which
already carries the real credential
([42.6](42-06-living-with-an-overlay.md)). The full managed-credential
procedure is [42.2](42-02-keycloak-admin-access-and-smoke-identity.md).
