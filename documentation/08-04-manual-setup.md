# 8.4 Manual setup (fallback only)

**Use this page only if the automated setup ([8.1](08-01-automated-setup.md))
cannot run in your environment.** `bootstrap.sh` and `keycloak-bootstrap.sh`
create exactly what is described here. The steps reproduce their result in
the Keycloak 26 admin console, with the same labels. `<host>` is your
hostname, for example `padsign.example.com`.

Open `https://<host>/auth/admin/` and log in to the master realm as the
admin ([8. Keycloak](08-keycloak.md#the-admin-console)).

## 1. Realm

1. Open the realm selector and choose **Create realm**.
2. **Realm name:** `padsign`. Leave **Enabled** on.
3. **Create**.

Do everything below in realm `padsign`.

## 2. Realm roles

Under **Realm roles** → **Create role**, create:

- `padsign-admin`
- `psapp-integration`
- `<CompanyRole>`: your company name, the same value you would pass as
  `--company-role`, for example `Acme`

## 3. Frontend client `padsign-client`

1. **Clients** → **Create client**.
2. **General settings:**
   - **Client type:** `OpenID Connect`
   - **Client ID:** `padsign-client`
   - **Name:** `padsign-client`
3. **Capability config:**
   - **Client authentication:** Off (a public client: the SPA cannot keep a
     secret)
   - **Authentication flow:** **Standard flow** on; **Direct access grants**
     and **Implicit flow** off
4. **Login settings:**
   - **Root URL:** `https://<host>/portal/`
   - **Home URL:** `https://<host>/portal/`
   - **Valid redirect URIs:** `https://<host>/portal/*`,
     `https://<host>/portal/`, `https://<host>/portal`
   - **Valid post logout redirect URIs:** `https://<host>/portal/*`,
     `https://<host>/portal/`, `https://<host>/portal`
   - **Web origins:** `https://<host>/portal/`, `https://<host>/portal`
5. **Save**. On the **Settings** tab, also set **Admin URL** to
   `https://<host>/portal/` and save again.

## 4. Audience mapper on `padsign-client`

This mapper is required. Without it every authenticated portal API call
returns `401` on current Keycloak releases ([8.2](08-02-token-audience.md)).

1. **Clients** → `padsign-client` → **Client scopes** tab →
   `padsign-client-dedicated`.
2. **Configure a new mapper** (or **Add mapper** → **By configuration**) →
   **Audience**.
3. Set exactly what `keycloak-bootstrap.sh` sets:

   | Field | Value |
   |-------|-------|
   | **Name** | `padsign-backend-audience` |
   | **Included Client Audience** | `padsign-backend` |
   | **Included Custom Audience** | empty |
   | **Add to ID token** | Off |
   | **Add to access token** | On |
   | **Add to token introspection** | On |

4. **Save**.

The mapper type is `oidc-audience-mapper`. It stores the audience as the
config key `included.client.audience`, which is what `verify-keycloak.sh` and
`upgrade.sh` look for. A command-line version is in
[8.2](08-02-token-audience.md#command-line).

## 5. Backend client `padsign-backend`

ps-server uses this client to introspect the portal's tokens, and in demo
mode to get its own service-account token. Nobody logs in through it, so it
needs no URLs.

1. **Clients** → **Create client**.
2. **General settings:**
   - **Client type:** `OpenID Connect`
   - **Client ID:** `padsign-backend`
   - **Name:** `padsign-backend`
3. **Capability config:**
   - **Client authentication:** On (a confidential client with a secret)
   - **Authentication flow:** **Service accounts roles** on; **Standard
     flow**, **Direct access grants** and **Implicit flow** off
4. **Login settings:** leave every field empty.
5. **Save**.
6. Open the **Credentials** tab and copy the **Client secret**.

## 6. Write the secret into `config/config.js`

```bash
cd /opt/padsign
read -rs CONFIGURE_HOST_BACKEND_SECRET && export CONFIGURE_HOST_BACKEND_SECRET   # paste the secret; nothing is echoed
./installation-scripts/configure-host.sh --host <host>
unset CONFIGURE_HOST_BACKEND_SECRET
docker compose restart ps-server
```

`configure-host.sh --host` also rewrites every hostname setting and the certificate paths for
that host, and copies `installation-scripts/certs/<host>.crt`/`.key` into `nginx/certs/` if they
exist. Use exactly the hostname already deployed, so those stay as they are.

This sets `KEYCLOAK_CONFIG.credentials.secret`. The rest of
`KEYCLOAK_CONFIG` must read:

```js
KEYCLOAK_CONFIG: {
  realm: "padsign",
  "auth-server-url": "https://<host>/auth",
  resource: "padsign-backend",
  credentials: { secret: "<the client secret>" },
  "bearer-only": true
},
```

The key must be named `KEYCLOAK_CONFIG` ([7.4](07-04-server-config-js.md#authentication-and-cors)).

## 7. Users

Under **Users** → **Add user**, create each portal user:

1. Fill in **Username**, **Email**, **First name** and **Last name**. Keycloak
   26's user profile requires all of them. Without them the first login
   stops at an "Update your account information" form.
2. **Create**, then on **Credentials** → **Set password** set a password with
   **Temporary** off (or on, if the user should choose their own).
3. On **Role mapping** → **Assign role**, give the user their `<CompanyRole>`
   realm role.

ps-server reads the company from the first non-default realm role in the
token, so keep `padsign-admin` and other roles off ordinary portal users.
For a one-off test login, use `smoke-user.sh` instead
([8.1](08-01-automated-setup.md#disposable-smoke-test-users)).

## 8. Verify

```bash
read -rs KEYCLOAK_ADMIN_PASSWORD && export KEYCLOAK_ADMIN_PASSWORD
./installation-scripts/verify-keycloak.sh --host <host> --company-role "<CompanyRole>"
unset KEYCLOAK_ADMIN_PASSWORD
```

Every line should read `OK`. Then log in at `https://<host>/portal/`.
