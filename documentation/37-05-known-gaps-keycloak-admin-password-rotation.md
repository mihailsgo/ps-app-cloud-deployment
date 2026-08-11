# 37.5 Known gap: Keycloak admin password rotation

Settings deliberately does **not** offer a way to change the Keycloak
admin password on a live deployment. This is a documented gap, not an
oversight.

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

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080/auth --realm master \
  --user <current-admin-user> --password <current-admin-password>

docker compose exec keycloak /opt/keycloak/bin/kcadm.sh set-password \
  -r master --username <current-admin-user> --new-password '<new-password>'
```

After rotating it, update `docker-compose.yml`'s `KEYCLOAK_ADMIN_PASSWORD`
too — not because Keycloak reads it again, but so a future full
re-provision from an empty volume (disaster recovery, a fresh
environment) creates the account with the password you actually intend to
use going forward.
