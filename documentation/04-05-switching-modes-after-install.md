# 4.5 Switching modes after install

Once the local stack is provisioned, switching between external and local
e-sealing is purely a configuration change. **No scripts to run** - just
edit two files in any text editor (`vi`, `nano`, VS Code over SSH, etc.)
and restart the services that read those files.

There are two files involved:

- `config/config.js` - holds `STAMP_MODE`, which tells `ps-server` which
  e-sealing path to use on every `/api/stamp` request.
- `.env` - holds `COMPOSE_PROFILES`, which tells `docker compose` whether
  to start the `dmss-digital-stamping-service` container.

The two values must agree. The recipes below show exactly which line to
change in each file.

---

## From Local back to External

**File 1 of 2: `config/config.js`**

Open the file in an editor and find the `STAMP_MODE` field near the top
of the `module.exports = {...}` block. Change its value from `"local"` to
`"external"`:

```js
// config/config.js  (excerpt - top of the exported config object)
module.exports = {
  // ...

  //
  // ─── E-SEALING MODE ────────────────────────────────────────────
  //
  STAMP_MODE: "external",   // ← change this line  (was: "local")

  STAMP_LOCAL: {
    // (leave this block in place; it is ignored when STAMP_MODE is "external")
    url:      "http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo",
    username: "user",
    password: "changeit",
  },

  // ...
};
```

Save and close.

**File 2 of 2: `.env`** (next to `docker-compose.yml`)

Open `.env` and **delete** (or comment out with `#`) the
`COMPOSE_PROFILES=local-eseal` line:

```
# .env  (before)
COMPOSE_PROFILES=local-eseal      # ← delete this entire line
```

```
# .env  (after)
# (line removed)
```

Save and close.

**Apply the change**

```bash
docker compose restart ps-server                                          # picks up the config.js edit
docker compose --profile local-eseal down dmss-digital-stamping-service   # optional - stops the now-unused stamping container
```

From now on every `/api/stamp` request from the SPA goes to the external
cloud e-sealing service (`eseal.trustlynx.com`). Confirm with:

```bash
docker compose logs ps-server --tail 20 | grep '\[stamp\] mode='
# expect: [stamp] mode=external ...
```

---

## From External back to Local

(Use this after you have run `bootstrap.sh --enable-local-eseal` or
`upgrade.sh --enable-local-eseal` at least once. The stamping
container's compose service block and the demo keystore must already
exist on disk - the script invocation puts them there.)

**File 1 of 2: `config/config.js`**

Open the file and change `STAMP_MODE` from `"external"` to `"local"`:

```js
// config/config.js  (excerpt)
module.exports = {
  // ...

  //
  // ─── E-SEALING MODE ────────────────────────────────────────────
  //
  STAMP_MODE: "local",      // ← change this line  (was: "external")

  STAMP_LOCAL: {
    url:      "http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo",
    username: "user",
    password: "changeit",
    // timeoutMs: 30000,    // optional override of the default 30s upstream timeout
  },

  // ...
};
```

Save and close.

**File 2 of 2: `.env`**

Open `.env` and add the `COMPOSE_PROFILES=local-eseal` line if it is
missing. If `COMPOSE_PROFILES=` already exists with other profiles, add
`local-eseal` to the comma-separated list:

```
# .env  (before - line missing or another profile only)
# (no COMPOSE_PROFILES line)
```

```
# .env  (after - new line added)
COMPOSE_PROFILES=local-eseal      # ← add this line
```

Save and close.

**Apply the change**

```bash
docker compose up -d                # starts the stamping container (now part of the active profile set)
docker compose restart ps-server    # picks up the config.js edit so STAMP_MODE=local takes effect
```

Confirm with:

```bash
docker compose ps | grep dmss-digital-stamping-service    # should now appear as Up
docker compose logs ps-server --tail 20 | grep '\[stamp\] mode='
# expect: [stamp] mode=local ...
```
