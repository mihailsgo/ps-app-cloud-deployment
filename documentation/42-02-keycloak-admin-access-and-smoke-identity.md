# 42.2 Keycloak admin access and the disposable smoke identity (#6)

Goal: an authorised operator can log in to Keycloak administration with a
credential held in your secret manager; a disposable smoke-test user can be
created, used for a real browser login, and deleted, twice in a row, without
restarting Keycloak; no shared or known-default credential is left behind.

Each step lists **Do / Check / Rollback / Evidence**. Run everything from the
directory the stack currently runs from: `$OLD` before the 42.4 cut-over,
`$NEW` after it.

`kcadm.sh` keeps its login session in a config file inside the Keycloak
container. End every admin session with the cleanup in K3, or a valid admin
refresh token sits in the container filesystem.

## K1: non-disruptive recovery (zero interruption)

Try these in order. The first one that works ends K1.

**K1a: a credential you already have.** Take the candidate from your
password manager, an old ticket, or the value the old `docker-compose.yml`
carries in `KEYCLOAK_ADMIN_PASSWORD`. That value is only what Keycloak was
first booted with and may be stale. The issue reports it no longer works.

```bash
cd "$OLD"
 read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD      # paste; nothing is echoed
KC_SECRET="$KEYCLOAK_ADMIN_PASSWORD" docker compose exec -T -e KC_SECRET keycloak sh -lc \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user admin --password "$KC_SECRET" >/dev/null && echo ADMIN-LOGIN-OK'
```

- **Check:** `ADMIN-LOGIN-OK`. Anything else is `Invalid user credentials`.
  Try each candidate once. Don't loop: if brute-force detection is enabled on
  the master realm, repeated failures temporarily lock the account.
- **Rollback:** none needed; this changes nothing.
- **Evidence:** `echo "K1a: <candidate source> -> ok|failed" >> "$EVID/K-log.txt"`. Record the source, never the value.

**K1b: someone is still signed in to the admin console**
(`https://$HOST/auth/admin/master/console/`). That person can create a
temporary admin: *Users → Add user* in realm `master`, set a password, then
*Role mapping → Assign role → admin*. There is no interruption. Continue at K3
with that account.

**K1c: a still-valid kcadm session inside the container** (rare; only if
someone ran a Keycloak script in roughly the last 30 minutes):

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get realms --fields realm 2>&1 | head -3
```

If it lists realms, you are authenticated. Go to K3.

## K2: break-glass recovery (a short Keycloak outage; users stay signed in)

Only if all of K1 failed. **Zero-interruption recovery is not possible on the
default configuration.** `kc.sh bootstrap-admin` must open the database, and
with the default `start-dev` H2 database a second process is refused while
Keycloak runs. This was verified: it fails with "Database may be already in
use" and leaves the running Keycloak untouched.

What users experience, measured on this stack: Keycloak is unavailable for
about **1 minute** (stop 2 s + recovery 41 s + start 15 s = 58 s). During
that minute ps-server cannot validate tokens (it introspects every request),
so API calls fail and users have to retry. **Users are not logged out.**
Keycloak 26 persists SSO sessions in its database: a refresh token issued
before the restart still worked after it.

**Do it inside the 42.4 cut-over window** (step C4 has the slot). The
cut-over recreates Keycloak anyway, so the recovery adds its ~40 s to one
planned interruption instead of causing a second one. Standalone, it is:

```bash
cd "$OLD"                                  # or "$NEW" during the cut-over: same project, same volume
 read -rs RECOVERY_PW && export RECOVERY_PW # a strong temporary password; put it in the secret manager first
docker compose config --volumes            # must list keycloak_data: you are in the right project
docker compose stop keycloak
docker compose run --rm --no-deps -e RECOVERY_PW keycloak \
  bootstrap-admin user --username temp-admin --password:env RECOVERY_PW --no-prompt 2>&1 \
  | grep -E 'KC-SERVICES0077|ERROR|Exception' | tee -a "$EVID/K2-bootstrap-admin.txt"
docker compose up -d keycloak
# wait until Keycloak accepts connections (works with or without a compose healthcheck)
until docker compose exec -T keycloak bash -c 'echo > /dev/tcp/localhost/8080' 2>/dev/null; do sleep 3; done
```

- **Check:** the output contains `KC-SERVICES0077: Created temporary admin user with username temp-admin`, and Keycloak accepts connections again. Then log in as `temp-admin`, with the same command as K1a but using `--user temp-admin` and `KC_SECRET="$RECOVERY_PW"`.
- **Rollback:** if `bootstrap-admin` errors, nothing was written. Run `docker compose up -d keycloak` and you are exactly where you started. If Keycloak will not start afterwards, restore the volume backup taken in 42.4 C4 (42.5 R4).
- **Evidence:** `K2-bootstrap-admin.txt` holds the log lines, which were verified to contain no password. Also record the outage start and end times.

`--password:env` makes Keycloak read the value from the environment. It never
reaches a command line. The account is always created in the `master` realm.

## K3: set the permanent admin credential and record it

```bash
 read -rs NEW_ADMIN_PW && export NEW_ADMIN_PW   # generate it IN the secret manager and paste it here
# (still logged in from K1/K2 inside the container)
KC_SECRET="$NEW_ADMIN_PW" docker compose exec -T -e KC_SECRET keycloak sh -lc \
  '/opt/keycloak/bin/kcadm.sh set-password -r master --username admin --new-password "$KC_SECRET" && echo PASSWORD-SET'
KC_SECRET="$NEW_ADMIN_PW" docker compose exec -T -e KC_SECRET keycloak sh -lc \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user admin --password "$KC_SECRET" >/dev/null && echo ADMIN-LOGIN-OK'
# remove the temporary break-glass account (K2 only)
docker compose exec -T keycloak sh -lc \
  'id=$(/opt/keycloak/bin/kcadm.sh get users -r master -q username=temp-admin --fields id --format csv | tail -n 1 | tr -d "\r\""); [ -n "$id" ] && [ "$id" != id ] && /opt/keycloak/bin/kcadm.sh delete users/$id -r master && echo TEMP-ADMIN-DELETED'
# end the kcadm session: do not leave an admin refresh token in the container
docker compose exec -T keycloak sh -c 'rm -f "$HOME/.keycloak/kcadm.config"'
unset RECOVERY_PW NEW_ADMIN_PW
```

- **Check:** `PASSWORD-SET`, then `ADMIN-LOGIN-OK` with the new value, then `TEMP-ADMIN-DELETED` (K2 only). A browser login to the admin console with the new value also works.
- **Rollback:** if `set-password` fails, nothing changed and the K1/K2 credential still works.
- **Evidence:** in the ticket, record who, when, the secret-manager entry path, and that the temp admin was deleted. Never record the value.

Then fill in the record [14.7](14-07-break-glass-admin-recovery.md) asks
for: **credential owner**, **secret storage location**, **date break-glass
was last tested** (today, if you ran K2), and the **next rotation date**. Keep
that record in your operations system, not in this repository.

## K4: prove the managed credential is the one in use

From a fresh shell, fetch the value from the secret manager (never type it
from memory) and repeat the K1a login. This is the "authorised operator
authenticates using a managed secret" acceptance check. Record
`K4: login with secret-manager value -> ok` in `K-log.txt`.

## K5: disposable smoke identity, twice in a row

List the company roles to pick the configured one. Never pick
`padsign-admin`; the script refuses it anyway.

```bash
KC_SECRET="$KEYCLOAK_ADMIN_PASSWORD" docker compose exec -T -e KC_SECRET keycloak sh -lc \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user admin --password "$KC_SECRET" >/dev/null &&
   /opt/keycloak/bin/kcadm.sh get roles -r padsign --fields name --format csv'
kc_started() { docker inspect -f '{{.State.StartedAt}}' "$(docker compose ps -q keycloak)"; }
```

Then, **at an interactive, unrecorded terminal** (the password is written to
the terminal only):

```bash
kc_started | tee -a "$EVID/K5-smoke.txt"
./installation-scripts/smoke-user.sh create --host "$HOST" --company-role "$ROLE" | tee -a "$EVID/K5-smoke.txt"
```

In a **private browser window**, open `https://$HOST/portal/`, log in with the
printed username and the password shown on the terminal, and check:

- the browser lands back on the portal (no "Update your account information" form, which was the bug this release fixes);
- the portal loads its data: no `401` responses in the browser's network panel right after login. A `401` here, after a successful login, is the Keycloak 26.7.4 audience regression from gate G1;
- no admin-only UI is visible;
- optionally, a signing flow per [19.2](19-02-test-authentication-flow.md).

Then close the window and delete the user:

```bash
./installation-scripts/smoke-user.sh delete --host "$HOST" --username smoke-XXXXXXXX | tee -a "$EVID/K5-smoke.txt"
kc_started | tee -a "$EVID/K5-smoke.txt"    # unchanged: Keycloak was never restarted
```

**Repeat the whole K5 block a second time.** Both runs must pass.

- **Check:** for each run, the `StartedAt` lines match, the browser login succeeded, and `delete` printed `Deleted user`. A second `delete` of the same name prints `not found` (idempotent).
- **Rollback:** `smoke-user.sh delete` (idempotent). A smoke user whose password was lost (non-interactive run) must be deleted, not reused.
- **Evidence:** `K5-smoke.txt` holds the usernames, role and timestamps. stdout never carries the password, which was verified. Add a note per run: "browser login ok, portal loaded, no 401".

## K6: retire stale and shared credentials

| What | Do | Check |
|---|---|---|
| The shared demo `test` user | Confirm with integrators that nothing logs in as `test`, then `kcadm.sh delete users/<id> -r padsign` (same pattern as the temp-admin delete) | `verify-keycloak.sh` now reports `no shared 'test' user (recommended for production ...)` as OK |
| Documented copies of the old test-user password and old admin password | Remove them from runbooks, tickets, wikis and mail; replace each with a pointer to the secret-manager entry | nothing left to find |
| `KEYCLOAK_ADMIN_PASSWORD` in compose | Nothing to do: it is read only on Keycloak's **first** boot against an **empty** volume. After the 42.4 migration the new checkout carries the release's placeholder. `validate-config.sh` warns about it as a known first-boot default. | the warning is expected; the real credential lives in the Keycloak volume and your secret manager |
| Values shipped in this public repository still in use (`validate-config.sh`: "... is still the value shipped in the public repository") | Rotate `REGISTER_PDF_API_KEY` (coordinate with every `/api/registerPDF` integrator) and `SESSION_SECRET`, using 42.6 *Changing a value in the overlay* | `validate-config.sh` no longer warns about them |
| Secrets found by the 42.1 leak sweep | Rotate every credential that appeared in shell history. Delete the history lines (`history -d <n>`, or edit the file). Tokens in `ps-server` logs expire within minutes, and the log itself goes when the cut-over recreates the container | the 42.1 counts are 0 on re-run |
| `API_PROTECT_LOGS_ENABLED: true` | Set it to `false` in the overlay's `config.js` (42.6) | `validate-config.sh` OK line |

**Recommended, owner's decision:** if `config/config.js` was world-readable
(`00-modes.txt`), anyone with a shell on the host could read the backend
client secret and the stamping credentials. Rotating the backend client
secret takes regenerating it in Keycloak (*Clients → padsign-backend →
Credentials → Regenerate*), then the 42.6 value change and a ps-server
restart. For the stamping credentials, coordinate with your e-sealing
provider.
