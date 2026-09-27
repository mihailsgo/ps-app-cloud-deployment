# 14.6 Create Client for Backend (Manual)

`keycloak-bootstrap.sh` creates this client for you ([14.2](14-02-automated-setup-recommended.md)). Use these steps only for a manual setup. Labels are those of the Keycloak 26 admin console.

ps-server uses this client to introspect the portal's tokens, and in demo mode to get its own service-account token for the visual-signature call. Nobody logs in through it, so it needs no redirect URIs.

1. In the `padsign` realm, go to **Clients** -> **Create client**.
2. **General settings:**
   - **Client type**: `OpenID Connect`
   - **Client ID**: `padsign-backend`
3. **Capability config:**
   - **Client authentication**: `On` (a confidential client with a secret)
   - **Authentication flow**: `Service accounts roles` on; `Standard flow`, `Direct access grants` and `Implicit flow` off
4. **Login settings:** leave every URI field empty.
5. **Save**.
6. Open the **Credentials** tab and copy the **Client secret** into `KEYCLOAK_CONFIG.credentials.secret` in `config/config.js` ([16.1](16-01-update-server-config.md)).
