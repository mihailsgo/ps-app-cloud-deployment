# 7. Configuration reference

This section describes every file you configure PadSign with, what each value
does, and how to apply a change. `bootstrap.sh` (or the wizard) fills in the
host-specific values for you. Use this reference when you tune a deployment
afterwards or need to know what a value means.

## Sub-sections

- [7.1 Essentials](07-01-essentials.md)
- [7.2 How configuration is loaded](07-02-how-configuration-is-loaded.md)
- [7.3 Client: config/constants.json](07-03-client-constants-json.md)
- [7.4 Server: config/config.js](07-04-server-config-js.md)
- [7.5 The /api/registerPDF integration API](07-05-register-pdf-api.md)
- [7.6 Environment variables and .env](07-06-environment-variables.md)

## The configuration files

| File | Read by | What it controls |
|------|---------|------------------|
| `config/config.js` | ps-server | Service URLs, Keycloak backend client, CORS, API key, e-sealing mode and credentials, queue and timeout tuning, document routing, customer-data lookup ([7.4](07-04-server-config-js.md)) |
| `config/constants.json` | ps-client (the browser SPA) | Keycloak public client, download URL, PDF viewer and signature placement, branding, translations ([7.3](07-03-client-constants-json.md)) |
| `config/keycloak.js` | ps-client | Where the SPA's Keycloak login goes. It derives everything from the page's own origin, so it normally needs no edits ([7.3](07-03-client-constants-json.md#configkeycloakjs)) |
| `config/TLlogo.png` | ps-client | The logo, served as `/portal/logo.png` |
| `nginx/nginx.conf` | nginx | `server_name`, TLS certificate paths, reverse-proxy routes ([6.1](06-01-route-protection.md)) |
| `docker-compose.yml` | Docker Compose | Services, image pins, ports, volumes, the Keycloak container's environment ([7.6](07-06-environment-variables.md)) |
| `.env` | Docker Compose | The Keycloak first-boot admin password, active compose profiles, optional alert webhook ([7.6](07-06-environment-variables.md)) |
| `dmss-archive-services/application.yml` | dmss-archive-services | Archive database and authentication |
| `dmss-container-and-signature-services/application.yml` | dmss-container-and-signature-services | Archive URLs, visual-PDF signing CA, stamping-service URL, trust lists |
| `dmss-container-and-signature-services/documentsigningprofiles.json` | dmss-container-and-signature-services | Signing profiles ([10.7](10-07-adding-a-signing-profile.md)) |
| `dmss-digital-stamping-service/application.yml` | dmss-digital-stamping-service | Local e-sealing: company to keystore mapping ([10](10-local-e-sealing.md)) |
| `dmss-archive-services-fallback/application.yml` | dmss-archive-services-fallback | Filesystem archive under `/docs` (the host's `./docs`) |

`configure-host.sh` rewrites the hostname in `nginx/nginx.conf`,
`config/constants.json`, `config/config.js` and `docker-compose.yml`. To
change the hostname, use `update-hostname.sh` rather than editing by hand
([9.1](09-01-changing-hostname.md)).

## Two ways into ps-server

- **Integration flow (API key).** A third-party system or the Padsign Virtual
  Printer registers documents with `REGISTER_PDF_API_KEY` as a bearer token:
  `/api/registerPDF`, `/api/registerUser`, `/api/registerUserPDF`,
  `/api/removeUser`, and the receive-back endpoints `/api/signedPdf*`
  ([7.5](07-05-register-pdf-api.md)).
- **Portal flow (Keycloak token).** The signed-in SPA calls
  `/api/latestUser`, `/api/visual-signature`, `/api/stamp`,
  `/api/fillPDFDemo`, `/api/cleanupUser` and the `/api/demo/*` endpoints with
  the user's Keycloak access token. ps-server validates the token against
  Keycloak as `padsign-backend` ([8.2](08-02-token-audience.md)).

## Changing values safely

1. Edit the file. Keep a copy first. The scripts keep their own `*.bak`
   files, but they overwrite them on every run.
2. Apply the change the way the file needs
   ([7.2](07-02-how-configuration-is-loaded.md)). For example,
   `config/config.js` needs `docker compose restart ps-server`.
3. Run `./installation-scripts/validate-config.sh --host padsign.example.com`
   ([5.2](05-02-validating-configuration.md)).

Never commit real secrets. `config/config.js` and `docker-compose.yml` are
tracked files, so keep the checkout private
([6. Production hardening](06-production-hardening.md)).
