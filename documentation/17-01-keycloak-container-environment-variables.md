# 17.1 Keycloak Container Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KEYCLOAK_ADMIN` | Admin username | `admin` |
| `KEYCLOAK_ADMIN_PASSWORD` | Admin password. `docker-compose.yml` sets it to `${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}`: the value comes from `.env`, never from the tracked file | `admin` when `.env` does not set it |
| `KC_HOSTNAME` | Keycloak's fixed frontend hostname: sets the token issuer and the login form's URLs. Rewritten to the deployment host by `configure-host.sh` | `padsign.trustlynx.com` (repo baseline) |
| `KC_HTTP_RELATIVE_PATH` | Auth path | `/auth` |
| `KC_PROXY` | Proxy mode | `edge` |

> `KEYCLOAK_ADMIN_PASSWORD` is only read on Keycloak's **first** boot against an
> empty volume - see [37.5](37-05-known-gaps-keycloak-admin-password-rotation.md)
> for changing it on a live deployment, or
> [14.7](14-07-break-glass-admin-recovery.md) if no credential works at all.

## Where the admin password lives: `.env`, not `docker-compose.yml`

`docker-compose.yml` is a tracked file. A real password in it shows up in
`git diff`, is stored in the git objects of every `git stash` taken during an
upgrade ([4.4](04-04-existing-deployment-upgrade-an-already-deployed-instance.md)
Phase 1), and is readable by every local user (the file is mode 644). So the
release's compose file only names a variable:

```yaml
      - KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}
```

and `bootstrap.sh` (through `configure-host.sh`) writes the value into `.env`
next to it: git-ignored, created mode 600, and owned by the owner of the
deployment directory when bootstrap runs as root, so `docker compose` still
works for that user. The value is double-quoted with `\`, `"` and `$`
escaped, which compose reads back exactly; a password with a newline or tab
is refused. (The old inline form did not survive such characters: compose
expanded `$NAME` / `${NAME}` inside it and YAML cut it at ` #`, so Keycloak
got another password than the scripts logged in with.) No container reads `.env`; only `docker compose` does, as the
user who runs it.

The variable is deliberately not called `KEYCLOAK_ADMIN_PASSWORD`. Operators
export that name for the scripts (`read -rs KEYCLOAK_ADMIN_PASSWORD`), and
compose lets the shell environment override `.env`: an exported current
password would change the keycloak container's definition and recreate it on
the next `docker compose up`.

Without `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD` in `.env`, the demo default
`admin` applies, exactly as before, and `validate-config.sh` warns.

## Deployments bootstrapped before v1.0.42

Up to v1.0.41, `bootstrap.sh` wrote the password straight into
`docker-compose.yml` (`- KEYCLOAK_ADMIN_PASSWORD=<value>`). Such a deployment
keeps booting as it is: compose uses the inline value, and Keycloak ignores
it anyway once its volume is initialized. `validate-config.sh` warns
`docker-compose.yml, a tracked file, carries the Keycloak admin password
inline`.

**Move it before you pull the new release**, so the stash taken during the
pull no longer carries it and `git stash pop` has nothing to conflict on:

```bash
cd /opt/psapp
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

Nothing is printed but the last line. Then pull as usual (4.4 Phase 1) and do
not run `docker compose up` in between: until the pull brings the new
`docker-compose.yml`, the file says `admin`. After the pull the compose line
reads the same value from `.env`, so the keycloak container's definition does
not change and nothing restarts. `validate-config.sh` then reports
`Keycloak's first-boot admin password is read from
KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD (.env)`.

**Already pulled, and `git stash pop` reported a conflict in
`docker-compose.yml`?** Resolve it as
[4.4 Phase 1](04-04-existing-deployment-upgrade-an-already-deployed-instance.md#phase-1---update-the-deployment-scripts-and-configs)
describes, with one exception: for this line keep the release's
`${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}` (the *Updated upstream* side)
and drop your inline line. Do drop the stash entry as 4.4 says: a conflicted
pop keeps it, and it still holds the inline password. Then let
`configure-host.sh` write `.env`:

```bash
 read -rs CONFIGURE_HOST_ADMIN_PASS && export CONFIGURE_HOST_ADMIN_PASS   # the admin password; nothing is echoed
./installation-scripts/configure-host.sh --host <your-host>
unset CONFIGURE_HOST_ADMIN_PASS
```

Either way, stashes and commits from **earlier** upgrades still contain the
old inline value, and so does `docker-compose.yml.bak` if an older script
wrote one. Drop stashes you no longer need, delete stale `.bak` copies, and if
the checkout (its `.git` included) was ever readable by other users, treat
the password as exposed and rotate it
([37.5](37-05-known-gaps-keycloak-admin-password-rotation.md)).

`configure-host.sh` only rewrites files (idempotently) and restarts nothing.
It also replaces an inline value it still finds with the release's reference.
Which password you store makes no difference to an initialized Keycloak; the
current admin password is the useful one, because `upgrade.sh` falls back to
the keycloak container's own `KEYCLOAK_ADMIN_PASSWORD` when you have not
exported one ([14.8](14-08-token-audience-for-introspection.md)).
