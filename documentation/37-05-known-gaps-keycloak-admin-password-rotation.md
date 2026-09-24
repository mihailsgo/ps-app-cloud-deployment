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

Both passwords travel through the environment, never the command line
(command lines are visible in `ps` and shell history):

```bash
 read -rs CUR_PW && read -rs NEW_PW                    # leading space: kept out of history (HISTCONTROL=ignorespace)
KC_SECRET="$CUR_PW" docker compose exec -T -e KC_SECRET keycloak sh -lc \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user <current-admin-user> --password "$KC_SECRET"'
KC_SECRET="$NEW_PW" docker compose exec -T -e KC_SECRET keycloak sh -lc \
  '/opt/keycloak/bin/kcadm.sh set-password -r master --username <current-admin-user> --new-password "$KC_SECRET"'
docker compose exec -T keycloak sh -c 'rm -f "$HOME/.keycloak/kcadm.config"'   # end the admin session
unset CUR_PW NEW_PW
```

Store the new value in your secret manager. **Do not** write it into
`docker-compose.yml`'s `KEYCLOAK_ADMIN_PASSWORD`. That file is tracked and
usually world-readable, and Keycloak never reads the variable again on an
existing volume. Disaster recovery restores the Keycloak data volume, which
already carries the real credential
([42.6](42-06-living-with-an-overlay.md)). The full managed-credential
procedure is [42.2](42-02-keycloak-admin-access-and-smoke-identity.md).
