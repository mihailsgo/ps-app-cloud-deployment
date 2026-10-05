# 7.6 Environment variables and .env

This page lists the environment variables the stack and the installation
scripts use, and how the `.env` file next to `docker-compose.yml` fits in.

## The .env file

`.env` sits in the deployment directory (`/opt/padsign/.env`). It is
git-ignored and mode `600`. Only `docker compose` reads it, as the user who
runs it. No container reads it directly. When `bootstrap.sh` runs as root, it
gives the file to the owner of the deployment directory so that user can
still run `docker compose`.

`.env.example`, next to it, is a tracked reference that lists and explains
every variable `docker-compose.yml` reads from `.env`. It is never read
itself: copy a line into `.env` only when you need it.

| Key | Written by | Meaning |
|-----|-----------|---------|
| `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD` | `bootstrap.sh` / `configure-host.sh --admin-pass` | Keycloak's master-realm admin password, passed to the keycloak container as `KEYCLOAK_ADMIN_PASSWORD`. Used **only on Keycloak's first boot** against an empty `keycloak_data` volume ([8.3](08-03-admin-password-and-break-glass.md)). |
| `COMPOSE_PROFILES` | `--enable-local-eseal` / `toggle-features.sh` | `local-eseal` makes a plain `docker compose up -d` include the stamping service ([10](10-local-e-sealing.md)). Do not add `wizard` here: start the wizard on demand ([3.1](03-01-starting-the-wizard.md)). |
| `ALERT_WEBHOOK_URL` | you | Where `monitor-status.sh --alert` posts alerts ([9.10](09-10-monitoring-and-alerting.md)). An exported variable of the same name wins over `.env`. |
| `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME` | `overlay.sh` | Only on hosts run as release baseline plus overlay ([9.11](09-11-start-at-boot-backups-and-customized-hosts.md)). `COMPOSE_FILE` names `docker-compose.yml`, the overlay's `compose.overlay.yml` and `.overlay-wizard.yml`, which mounts the overlay directory into the Deployment Wizard ([9.12](09-12-monitoring-from-the-wizard.md#on-an-overlay-managed-checkout)). |
| `WIZARD_BIND_ADDRESS` | you | Host address the Deployment Wizard's port 8443 is published on. Unset, it is `127.0.0.1` (reach it through an SSH tunnel). `0.0.0.0` opens it on all interfaces: only on a trusted admin network, because Docker-published ports bypass host firewalls such as `ufw`, and `validate-config.sh` warns ([3.1](03-01-starting-the-wizard.md#reaching-the-wizard-without-a-tunnel-wizard_bind_address)). |
| `WIZARD_TLS_SANS` | you | Extra names or IPv4 addresses, comma-separated, for the wizard's self-signed certificate, when you browse to it by the host's address instead of through the tunnel ([3.1](03-01-starting-the-wizard.md#the-wizards-certificate-names-wizard_tls_sans)). |

`bootstrap.sh` double-quotes the admin password and escapes `\`, `"` and `$`,
which compose reads back exactly. A password containing a newline or tab is
refused.

Variables exported in your shell override `.env` for compose. This is why the
admin password variable is called `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD` and not
`KEYCLOAK_ADMIN_PASSWORD`. You export `KEYCLOAK_ADMIN_PASSWORD` for the
scripts (below). If compose read that name, an exported current password
would change the keycloak container's definition and recreate it on the next
`docker compose up`.

## Keycloak container

Set in the `keycloak` service of `docker-compose.yml`:

| Variable | Value | Meaning |
|----------|-------|---------|
| `KEYCLOAK_ADMIN` | `admin` | Master-realm admin username. `--admin-user` changes it. First boot only. |
| `KEYCLOAK_ADMIN_PASSWORD` | `${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}` | Admin password, taken from `.env`. Without it, the demo default `admin` applies and `validate-config.sh` warns. First boot only. |
| `KC_HOSTNAME` | the deployment host | Keycloak's fixed frontend hostname. It decides the token issuer and the login form's URLs. `configure-host.sh` sets it. A hand edit needs `docker compose up -d keycloak`. |
| `KC_HTTP_RELATIVE_PATH` | `/auth` | Keycloak is served under `/auth`. |
| `KC_PROXY_HEADERS` | `xforwarded` | Trust nginx's `X-Forwarded-*` headers. |
| `KC_HOSTNAME_STRICT` | `false` | Relaxed hostname checks behind the TLS-terminating nginx. |
| `KC_HEALTH_ENABLED` | `true` | Health endpoints on the management port 9000, used by the container health check. |

Keycloak runs with `command: start-dev` and an embedded H2 database. This is
not production-grade: see
[6. Production hardening](06-production-hardening.md#2-keycloak).

## Other containers

| Service | Variable | Meaning |
|---------|----------|---------|
| ps-server | `NO_PROXY`, `no_proxy` | Internal names that bypass any proxy. |
| ps-server | `HTTP_PROXY`, `HTTPS_PROXY` (and lower case) | Empty, so no host proxy settings leak in. Set them if ps-server must reach an external e-sealing or customer-data service through a proxy. |
| ps-server | `SESSION_SECRET` | Not read by ps-server 3.33+; has no effect. |
| ps-server | `ALLOW_INSECURE_TLS` | Not set by default. `true` turns insecure TLS on even when `config/config.js` has `ALLOW_INSECURE_TLS: false`. It can only turn it on: `false` (or any other value) does not turn it off when `config/config.js` has `true` ([7.4](07-04-server-config-js.md)). |
| DMSS services | `SPRING_CONFIG_LOCATION` / `SPRING_CONFIG_ADDITIONAL_LOCATION` | Point the Spring services at their mounted `application.yml`. |
| dmss-container-and-signature-services | `SPRING_SECURITY_USER_NAME`, `SPRING_SECURITY_USER_PASSWORD` | Only with local e-sealing. Container-signature's Basic-auth credentials, which must match `STAMP_LOCAL` in `config/config.js`. Ship as `user` / `changeit`: rotate them ([6](06-production-hardening.md)). |
| wizard | `WIZARD_PORT`, `HOST_PROJECT_DIR`, `WIZARD_TLS_SANS` | The wizard's port, the project path, and extra names or IPs for its self-signed certificate. `WIZARD_TLS_SANS` is taken from `.env` (see above); no compose edit is needed ([3.1](03-01-starting-the-wizard.md)). |

## Variables the installation scripts read

Pass secrets to the scripts through the environment, not as flags. A
command-line argument is visible to every local user in `ps` and lands in
shell history:

```bash
read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD   # nothing is echoed
./installation-scripts/verify-keycloak.sh --host padsign.example.com --company-role "Acme"
unset KEYCLOAK_ADMIN_PASSWORD
```

| Variable | Used by | Meaning |
|----------|---------|---------|
| `KEYCLOAK_ADMIN`, `KEYCLOAK_ADMIN_PASSWORD` | `bootstrap.sh`, `keycloak-bootstrap.sh`, `verify-keycloak.sh`, `smoke-user.sh`, `upgrade.sh` | Keycloak admin login, instead of `--admin-user` / `--admin-pass`. `upgrade.sh` falls back to the keycloak container's own environment when they are not set. |
| `CONFIGURE_HOST_ADMIN_PASS`, `CONFIGURE_HOST_BACKEND_SECRET` | `configure-host.sh` | The admin password to store in `.env` and the backend client secret to write into `config/config.js`, instead of `--admin-pass` / `--backend-secret`. |
| `KC_HOSTNAME` | `keycloak-bootstrap.sh`, `verify-keycloak.sh` | Default for `--host`. |

## If docker-compose.yml carries the admin password inline

`docker-compose.yml` is a tracked file. A real password in it shows up in
`git diff`, in the git objects of every `git stash` an upgrade takes
([9.5](09-05-upgrading.md)), and to every local user, because the file is mode
`644`. If `validate-config.sh` reports
`docker-compose.yml, a tracked file, carries the Keycloak admin password
inline`, move the password to `.env`.

**Before you pull a new release**, run this in the deployment directory. It
prints only its last line:

```bash
cd /opt/padsign
umask 077
python3 - <<'PY'
import os, re
with open("docker-compose.yml", encoding="utf-8", newline="") as fh:
    compose = fh.read()
m = re.search(r"^[ \t]*-[ \t]*KEYCLOAK_ADMIN_PASSWORD=([^\r\n]*)", compose, re.M)
value = m.group(1).strip().strip("\"'") if m else ""
if value in ("", "admin") or value.startswith("$"):
    raise SystemExit("nothing to move: no inline password, or already a reference")
quoted = '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'
lines = []
if os.path.exists(".env"):
    with open(".env", encoding="utf-8") as fh:
        lines = [l for l in fh.read().splitlines() if not l.startswith("KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD=")]
lines.append("KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD=" + quoted)
with open(".env", "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
os.chmod(".env", 0o600)
# Back to the release's own value: git then sees no local change on that line.
with open("docker-compose.yml", "w", encoding="utf-8", newline="") as fh:
    fh.write(compose[:m.start(1)] + "admin" + compose[m.end(1):])
print("moved to .env (mode 600); docker-compose.yml line reset to the release value")
PY
```

Then pull as usual ([9.5](09-05-upgrading.md)). Do not run `docker compose up`
in between: until the pull brings the release's `docker-compose.yml`, the line
says `admin`. After the pull, the compose line reads the same value from
`.env`, so the keycloak container's definition does not change and nothing
restarts. `validate-config.sh` then reports `Keycloak's first-boot admin
password is read from KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD (.env)`.

**Already pulled, and `git stash pop` reported a conflict in
`docker-compose.yml`?** Resolve it as [9.5](09-05-upgrading.md) describes, with
one exception: for this line keep the release's
`${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}` and drop your inline line. Drop
the stash entry too, because a conflicted pop keeps it and it still holds the
password. Then let `configure-host.sh` write `.env`:

```bash
read -rs CONFIGURE_HOST_ADMIN_PASS && export CONFIGURE_HOST_ADMIN_PASS   # the admin password; nothing is echoed
./installation-scripts/configure-host.sh --host padsign.example.com
unset CONFIGURE_HOST_ADMIN_PASS
```

`configure-host.sh --host` also rewrites every hostname setting and the certificate paths for
that host, and copies `installation-scripts/certs/<host>.crt`/`.key` into `nginx/certs/` if they
exist. Use exactly the hostname already deployed, so those stay as they are.

`configure-host.sh` only rewrites files and restarts nothing. It also
replaces any inline value it still finds with the release's reference. Store
the **current** admin password. Keycloak ignores the value on an existing
volume, but `upgrade.sh` falls back to it when you have not exported
`KEYCLOAK_ADMIN_PASSWORD` ([8.2](08-02-token-audience.md)).

Either way, older stashes, commits and `docker-compose.yml.bak` copies may
still contain the old inline value. Drop stashes you no longer need and
delete stale `.bak` files. If the checkout, including `.git`, was ever
readable by other users, treat the password as exposed and rotate it
([8.3](08-03-admin-password-and-break-glass.md)).
