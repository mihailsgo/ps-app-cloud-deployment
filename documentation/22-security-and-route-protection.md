# 22. Security and Route Protection

- TLS termination: All external traffic enters via NGINX on 443; HTTP 80 redirects to HTTPS.
- Public routes:
  - `/portal/*` serves the SPA. The SPA itself gates features by user auth state.
  - `/auth/*` proxies to Keycloak for login, tokens, and account management.
  - `/api/*` proxies to the backend (ps-server). Authentication depends on endpoint:
    - external integration endpoints accept API key bearer token (`REGISTER_PDF_API_KEY`)
    - internal operator endpoints require Keycloak bearer token
  - `/container/api/*` and `/archive/api/*` proxy to DMSS services. For production, restrict these (IP allowlist, mTLS) or enforce JWT on the services.
- SPA authentication (frontend): Uses Keycloak (public client). Recommended flow is Authorization Code with PKCE. The SPA obtains an access token and attaches it as `Authorization: Bearer <token>` to API calls.
- Backend enforcement (ps-server): applies auth by endpoint, including API-key protection for external registration endpoints and Keycloak JWT validation for internal operator endpoints. CORS should be restricted to known origins in `config/config.js`.
- Header forwarding (DMSS): `dmss-container-and-signature-services` is configured to forward `Authorization` and other headers to the archive service. Align DMSS auth to your policy.
- Enabling JWT on DMSS Archive (recommended for prod): In `dmss-archive-services/application.yml` set `authentication.jwt.enabled: true` and configure either `useCert: true` with a public key/cert or a shared `secret`, and set `validation: true`.
- NGINX hardening: If DMSS endpoints should not be directly reachable from the internet, remove or restrict the `/container/api` and `/archive/api` locations, or protect them with allowlists or client certificates.
- Keycloak admin: Limit admin console access (IP allowlist/VPN) and change the default admin password immediately.

## Protecting `/archive/api` and `/container/api` with an Authorization header

The recommended pattern needs no application changes and is enforced entirely at nginx:

- Add `satisfy any; allow <docker-subnet>; deny all; auth_basic ...;` to both locations. Internal ps-server traffic reaches nginx through the Docker network alias and passes on source IP alone; every outside caller must send `Authorization: Basic ...`. Credentials live in an `htpasswd` file dropped into the already-mounted `nginx/certs` folder.
- Firewall the published host ports (84, 86, 93, 3001, 8080) against outside access, otherwise nginx can be bypassed by calling the services directly.

### The document download route

`GET /archive/api/document/{docid}/download` accepts either credential, so it works for both callers:

- the pad browser (`ps-client` 8.38+) sends the user's Keycloak Bearer token
- a 3rd-party system sends the same `Authorization: Basic ...` credential used for `/archive/api` and `/container/api`

Keep the Docker-subnet `allow` (ps-server's own internal downloads send no credential at all) and add both `auth_basic` and an `auth_request` check against Keycloak's userinfo endpoint to the same location; `satisfy any` grants access if either one passes.

Copy-paste instructions with the exact nginx blocks: https://github.com/mihailsgo/tl-service-route-protection

