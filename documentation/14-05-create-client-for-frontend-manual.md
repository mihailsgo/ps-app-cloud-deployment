# 14.5 Create Client for Frontend (Manual)

`keycloak-bootstrap.sh` creates this client for you ([14.2](14-02-automated-setup-recommended.md)). Use these steps only for a manual setup. Labels are those of the Keycloak 26 admin console.

1. In the `padsign` realm, go to **Clients** -> **Create client**.
2. **General settings:**
   - **Client type**: `OpenID Connect`
   - **Client ID**: `padsign-client`
3. **Capability config:**
   - **Client authentication**: `Off` (a public client: the SPA cannot keep a secret)
   - **Authentication flow**: `Standard flow` on; `Direct access grants` and `Implicit flow` off
4. **Login settings:**
   - **Root URL**: `https://<host>/portal/`
   - **Valid redirect URIs**:
     - `https://<host>/portal/*`
     - `https://<host>/portal/`
     - `https://<host>/portal`
   - **Valid post logout redirect URIs**:
     - `https://<host>/portal/*`
     - `https://<host>/portal/`
     - `https://<host>/portal`
   - **Web origins**:
     - `https://<host>/portal/`
     - `https://<host>/portal`
     - `https://<host>`

<img width="2252" height="774" alt="image" src="https://github.com/user-attachments/assets/adc1cea1-ba42-415e-bd13-73697c35ff0b" />

5. **Save**.
6. Add the `padsign-backend` audience mapper - required on Keycloak 26.4.12 /
   26.6.2 / 26.7.0 and newer, or every authenticated portal API call returns 401.
   Steps in [14.8 Token audience for introspection](14-08-token-audience-for-introspection.md).
7. Create the portal users and give each one a realm role named after their company (the value `keycloak-bootstrap.sh` takes as `--company-role`, [3.2](03-02-bootstrap-parameters.md)). ps-server reads the company from the first non-default realm role in the token, so keep `padsign-admin` and other roles off ordinary portal users.
