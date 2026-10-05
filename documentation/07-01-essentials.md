# 7.1 Essentials

This page lists the values that matter on every deployment, with minimal
examples for `padsign.example.com`. `bootstrap.sh` sets the host-specific
ones. Every other value can stay as shipped until you have a reason to
change it.

## Client (`config/constants.json`)

- Keycloak: `KEYCLOAK_URL`, `KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID`,
  `KEYCLOAK_REDIRECT_URI`, `KEYCLOAK_POST_LOGOUT_REDIRECT_URI` (the three
  URLs may be left out for a ps-client that defaults them to its own origin:
  [7.3](07-03-client-constants-json.md#authentication-keycloak))
- Document polling: `PS_API_ACTUAL_USER` (polls `/api/latestUser`),
  `USER_POLLING_FREQUENCY`
- Viewer download: `PS_DOWNLOAD_API`
- Viewer licence: `PDF_RENDER_SYNCFUSION_SECRET_KEY`
- Signature placement: `PDF_SIGNATURE_X`, `PDF_SIGNATURE_Y`,
  `PDF_SIGNATURE_ZOOM`, `PDF_SIGNATURE_PAGE`
- Viewer layout: `PDF_ZOOM_VALUE`, `MAX_ZOOM`, `MIN_ZOOM`,
  `DEFAULT_PAGE_SIZE`, `EXTRA_HEIGHT_MARGIN_PX`, `OPACITY_DELAY`
- Signature pad: `CANVA_WIDTH`, `CANVA_HEIGHT`
- E-sealing after signing: `RUN_STAMPING_REQUEST`
- Demo mode: `DEMO_MODE`
- Branding: `PS_PAGE_TITLE`, `PS_LOGO_PATH`, `PS_DEFAULT_LOGO_PATH`,
  `SHOW_USER_DATA_BOX`, `SHOW_SIGNER_NAME`

Full list: [7.3](07-03-client-constants-json.md).

## Server (`config/config.js`)

- Keycloak and CORS: `KEYCLOAK_CONFIG`, `ALLOWED_ORIGINS`, `PORT`
- Integration API key: `REGISTER_PDF_API_KEY` (optionally per-company
  `REGISTER_PDF_API_KEYS`)
- DMSS services: `ARCHIVE_API_BASE_URL`, `CREATE_DOCUMENT_API_URL`,
  `DOCUMENT_DOWNLOAD_API_URL`, `VISUAL_SIGNATURE_API_TEMPLATE`,
  `FORM_FILL_API_URL` (in-network addresses by default; the optional
  `ARCHIVE_PUBLIC_BASE_URL` is what webhook payloads carry as `archiveUrl`),
  `DEFAULT_DOCUMENT_JSON`
- E-sealing: `STAMP_MODE` (`"external"` when absent, or `"local"`), with
  `STAMP_API_URL` / `STAMP_API_KEY` / `STAMP_COMPANY_ID` /
  `STAMP_COMPANY_SECRET` for external mode, or `STAMP_LOCAL` for local mode
- Load and resilience: `REGISTER_PDF_MAX_CONCURRENCY`,
  `REGISTER_PDF_QUEUE_MAX_SIZE`, `REGISTER_PDF_QUEUE_WAIT_MS`,
  `REGISTER_PDF_UPSTREAM_TIMEOUT_MS`, `REGISTER_PDF_UPSTREAM_RETRIES`,
  `DEPENDENCY_CB_FAILURE_THRESHOLD`, `DEPENDENCY_CB_COOLDOWN_MS`
- Duplicate and parallel signing protection: `DOC_OPERATION_LOCK_TTL_MS`,
  `IDEMPOTENCY_TTL_MS`
- In-memory state: `USER_ENTRY_TTL_MS`, `USER_STATE_CLEANUP_MS`,
  `PAD_ARRIVAL_TIMEOUT_MS`
- Roles: `PRIVILEGED_API_ROLES`
- After signing: `DOCUMENT_ROUTING`

Full list: [7.4](07-04-server-config-js.md).

## Minimal client example

Keep `TRANSLATIONS` and `DEFAULT_LANGUAGE` from the shipped file:

```json
{
  "PS_PAGE_TITLE": "TrustLynx",
  "PS_LOGO_PATH": "/portal/logo.png",
  "PS_DEFAULT_LOGO_PATH": "/portal/logo.png",
  "KEYCLOAK_URL": "https://padsign.example.com/auth",
  "KEYCLOAK_REALM": "padsign",
  "KEYCLOAK_CLIENT_ID": "padsign-client",
  "KEYCLOAK_REDIRECT_URI": "https://padsign.example.com/portal/",
  "KEYCLOAK_POST_LOGOUT_REDIRECT_URI": "https://padsign.example.com/portal/",
  "PS_API_ACTUAL_USER": "/api/latestUser",
  "PS_API_CLEANUP_USER": "/api/cleanupUser",
  "PS_API_DEMO_UPLOAD": "/api/demo/upload",
  "PS_API_DEMO_UPLOAD_VERSION": "/api/demo/upload/version",
  "PS_API_DEMO_FILL_BY_DOCID": "/api/demo/fill-by-docid",
  "DEMO_MODE": "DISABLE",
  "USER_POLLING_FREQUENCY": 5000,
  "PS_DOWNLOAD_API": "https://padsign.example.com/archive/api/document/",
  "PDF_RENDER_SYNCFUSION_SECRET_KEY": "<keep the shipped value>",
  "PDF_SIGNATURE_X": -250,
  "PDF_SIGNATURE_Y": -100,
  "PDF_SIGNATURE_ZOOM": 100,
  "PDF_SIGNATURE_PAGE": 10000,
  "PDF_ZOOM_VALUE": "125",
  "MAX_ZOOM": 125,
  "MIN_ZOOM": 125,
  "DEFAULT_PAGE_SIZE": "7800px",
  "EXTRA_HEIGHT_MARGIN_PX": 2500,
  "OPACITY_DELAY": 4000,
  "CANVA_WIDTH": 300,
  "CANVA_HEIGHT": 100,
  "RUN_STAMPING_REQUEST": false,
  "SHOW_USER_DATA_BOX": false,
  "SHOW_SIGNER_NAME": false
}
```

## Minimal server example

External e-sealing. The Keycloak secret is written by `bootstrap.sh`, and the
e-sealing values come from your provider:

```js
module.exports = {
  PORT: 3001,
  ARCHIVE_API_BASE_URL: "http://dmss-archive-services:8090/api/",
  CREATE_DOCUMENT_API_URL: "http://dmss-archive-services:8090/api/document/create",
  VISUAL_SIGNATURE_API_TEMPLATE: "http://dmss-container-and-signature-services:8092/api/signing/visual/pdf/{docid}/sign",
  ARCHIVE_PUBLIC_BASE_URL: "https://padsign.example.com/archive/api/",
  STAMP_MODE: "external",
  STAMP_API_URL: "<e-seal endpoint from your provider>",
  STAMP_API_KEY: "<e-seal-api-key>",
  STAMP_COMPANY_ID: "<e-seal-company-id>",
  STAMP_COMPANY_SECRET: "<e-seal-company-secret>",
  ALLOWED_ORIGINS: ['https://padsign.example.com'],
  DEFAULT_DOCUMENT_JSON: {
    objectName: "template",
    contentType: "application/pdf",
    documentType: "DMSSDoc",
    documentFilename: "template.pdf"
  },
  KEYCLOAK_CONFIG: {
    realm: "padsign",
    "auth-server-url": "https://padsign.example.com/auth",
    resource: "padsign-backend",
    credentials: { secret: "<backend-client-secret>" },
    "bearer-only": true
  },
  REGISTER_PDF_API_KEY: "<generated by bootstrap.sh>",
  SESSION_SECRET: "<generated by bootstrap.sh>",
  REGISTER_PDF_UPSTREAM_TIMEOUT_MS: 15000,
  REGISTER_PDF_UPSTREAM_RETRIES: 3,
  REGISTER_PDF_MAX_CONCURRENCY: 4,
  REGISTER_PDF_QUEUE_MAX_SIZE: 100,
  REGISTER_PDF_QUEUE_WAIT_MS: 30000,
  DEPENDENCY_CB_FAILURE_THRESHOLD: 5,
  DEPENDENCY_CB_COOLDOWN_MS: 30000,
  USER_ENTRY_TTL_MS: 600000,
  USER_STATE_CLEANUP_MS: 60000,
  PAD_ARRIVAL_TIMEOUT_MS: 600000,
  DOC_OPERATION_LOCK_TTL_MS: 45000,
  IDEMPOTENCY_TTL_MS: 600000,
  PRIVILEGED_API_ROLES: ["padsign-admin", "psapp-integration"],
  DOCUMENT_ROUTING: {
    enabled: false,
    skipDemo: true,
    strategies: []
  }
};
```

Start from the shipped `config/config.js` rather than from this example. It
has more keys (customer-data lookup, routing strategies) that this example
leaves out.
