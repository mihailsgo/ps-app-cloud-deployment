## Keycloak Configuration

# Keycloak Integration Guide for PadSign Application

This guide provides step-by-step instructions for setting up Keycloak authentication for the PadSign application in a containerized environment.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Keycloak Setup](#keycloak-setup)
4. [Client Configuration](#client-configuration)
5. [Server Configuration](#server-configuration)
6. [Environment Variables](#environment-variables)
7. [Testing the Integration](#testing-the-integration)
8. [Troubleshooting](#troubleshooting)

## Overview

The PadSign application uses Keycloak for authentication and authorization. The setup includes:
- **Keycloak Server**: Containerized authentication server
- **Client Application**: React frontend with Keycloak integration
- **Server Application**: Node.js backend with Keycloak middleware

## Prerequisites

- Docker and Docker Compose installed
- Domain name configured (e.g., `padsign.trustlynx.com`)
- SSL certificates for HTTPS
- Access to Keycloak admin panel

## Keycloak Setup

### 1. Start Keycloak Container

The Keycloak container is defined in `docker-compose.yml`:

```yaml
keycloak:
  image: quay.io/keycloak/keycloak:26.3.2
  environment:
    - KEYCLOAK_ADMIN=admin
    - KEYCLOAK_ADMIN_PASSWORD=admin
    - KC_HOSTNAME=padsign.trustlynx.com
    - KC_HTTP_RELATIVE_PATH=/auth
    - KC_PROXY=edge
    - KC_HOSTNAME_STRICT=false
    - KC_HOSTNAME_STRICT_HTTPS=false
    - KC_PROXY_HEADERS=xforwarded
  command: start-dev
  ports:
    - "8080:8080"
  restart: unless-stopped
  volumes:
    - keycloak_data:/opt/keycloak/data
```

### 2. Access Keycloak Admin Panel

1. Start the containers:
   ```bash
   docker-compose up -d
   ```

2. Access Keycloak admin panel:
   ```
   https://padsign.trustlynx.com/auth/
   ```
   - Username: `admin`
   - Password: `admin`

### 3. Create Realm

1. Log in to Keycloak admin panel
2. Click "Create Realm"
3. Enter realm name: `padsign`
4. Click "Create"

### 4. Create Client for Frontend

1. In the `padsign` realm, go to "Clients" ? "Create"
2. Configure the client:
   - **Client ID**: `padsign-client`
   - **Client Protocol**: `openid-connect`
   - **Root URL**: `https://padsign.trustlynx.com/portal/`
   - create user, as user role setup the company name.

<img width="2252" height="774" alt="image" src="https://github.com/user-attachments/assets/adc1cea1-ba42-415e-bd13-73697c35ff0b" />


4. Go to "Settings" tab and configure:
   - **Access Type**: `public`
   - **Valid Redirect URIs**: 
     - `https://padsign.trustlynx.com/portal/*`
     - `https://padsign.trustlynx.com/portal/`
     - `https://padsign.trustlynx.com/portal`
   - **Valid Post Logout Redirect URIs**:
     - `https://padsign.trustlynx.com/portal/*`
     - `https://padsign.trustlynx.com/portal/`
     - `https://padsign.trustlynx.com/portal`
   - **Web Origins**:
     - `https://padsign.trustlynx.com/portal/`
     - `https://padsign.trustlynx.com/portal`
     - `https://padsign.trustlynx.com`

5. Save the configuration

### 5. Create Client for Backend

1. Create another client for the backend:
   - **Client ID**: `padsign-backend`
   - **Client Protocol**: `openid-connect`
   - **Access Type**: `confidential`

2. Go to "Credentials" tab and copy the client secret

3. Configure settings:
   - **Valid Redirect URIs**: `https://padsign.trustlynx.com/auth/realms/padsign/protocol/openid-connect/auth`

## Client Configuration

### 1. Update Constants File

Edit `client/public/constants.json` to match your domain:

```json
{
  "KEYCLOAK_URL": "https://padsign.trustlynx.com/auth",
  "KEYCLOAK_REALM": "padsign",
  "KEYCLOAK_CLIENT_ID": "padsign-client",
  "KEYCLOAK_REDIRECT_URI": "https://padsign.trustlynx.com/portal/",
  "KEYCLOAK_POST_LOGOUT_REDIRECT_URI": "https://padsign.trustlynx.com/portal/"
}
```

### 2. Environment Variables (Optional)

You can override constants using environment variables:

```bash
# Development
VITE_HOST=padsign.trustlynx.com
VITE_PORT=5173

# Production
# Set these in your deployment environment
```

## Server Configuration

### 1. Update Server Config

Edit `server/config.js` to include Keycloak configuration:

```javascript
module.exports = {
  // ... other config
  keycloak: {
    realm: "padsign",
    "auth-server-url": "https://padsign.trustlynx.com/auth",
    resource: "padsign-backend",
    "credentials": {
      "secret": "YOUR_CLIENT_SECRET_HERE"
    }
  }
};
```

### 2. Replace Client Secret

Replace `YOUR_CLIENT_SECRET_HERE` with the actual client secret from the `padsign-backend` client in Keycloak.

## Environment Variables

### Keycloak Container Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KEYCLOAK_ADMIN` | Admin username | `admin` |
| `KEYCLOAK_ADMIN_PASSWORD` | Admin password | `admin` |
| `KC_HOSTNAME` | Keycloak hostname | `padsign.trustlynx.com` |
| `KC_HTTP_RELATIVE_PATH` | Auth path | `/auth` |
| `KC_PROXY` | Proxy mode | `edge` |

### Client Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VITE_HOST` | Development host | `padsign.trustlynx.com` |
| `VITE_PORT` | Development port | `5173` |

## Testing the Integration

### 1. Build and Deploy

```bash
# Build client
cd client
npm run build

# Restart containers
docker-compose restart nginx
```

### 2. Test Authentication Flow

1. Access the application: `https://padsign.trustlynx.com/portal/`
2. You should be redirected to Keycloak login
3. Log in with valid credentials
4. You should be redirected back to the application
5. Test logout functionality

### 3. Verify Configuration

Check these URLs are accessible:
- Keycloak admin: `https://padsign.trustlynx.com/auth/`
- Application: `https://padsign.trustlynx.com/portal/`

## Troubleshooting

### Common Issues

#### 1. "Invalid redirect URI" Error

**Cause**: Redirect URI doesn't match Keycloak client configuration

**Solution**:
1. Check Keycloak client settings
2. Ensure URIs in `constants.json` match Keycloak configuration
3. Verify domain name is correct

#### 2. CORS Errors

**Cause**: Web origins not configured properly

**Solution**:
1. Add your domain to "Web Origins" in Keycloak client
2. Include both with and without trailing slash

#### 3. Authentication Fails

**Cause**: Client secret mismatch or configuration error

**Solution**:
1. Verify client secret in `server/config.js`
2. Check realm name matches
3. Ensure client IDs are correct

#### 4. Container Communication Issues

**Cause**: Network configuration problems

**Solution**:
1. Check Docker network configuration

# Configuration Constants Reference

This document describes all configurable values exposed in the two runtime configuration files used by this project:

- Client runtime config: `config/constants.json`
- Backend server config: `config/config.js`

It explains what each constant does, default values present in the repo, and how deployers can change them for their environment.

Cloud usage note
- This deployment primarily uses the upload flow via `/api/registerPDF` and then renders via `/api/latestUser?email=...&company=...`. Any item below explicitly marked “API is not relevant for cloud instance” is not used in this flow and can be ignored for cloud deployments.

## Cloud Essentials (TL;DR)

Client essentials (constants.json)
- `KEYCLOAK_URL`, `KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID`, `KEYCLOAK_REDIRECT_URI`, `KEYCLOAK_POST_LOGOUT_REDIRECT_URI`
- `PS_API_ACTUAL_USER` (polls `/api/latestUser`)
- `USER_POLLING_FREQUENCY`
- `PS_DOWNLOAD_API` (viewer downloads archive doc)
- `PDF_RENDER_SYNCFUSION_SECRET_KEY`
- `PDF_SIGNATURE_X`, `PDF_SIGNATURE_Y`, `PDF_SIGNATURE_ZOOM`, `PDF_SIGNATURE_PAGE`
- `PDF_ZOOM_VALUE`, `MAX_ZOOM`, `MIN_ZOOM`, `DEFAULT_PAGE_SIZE`, `EXTRA_HEIGHT_MARGIN_PX`, `OPACITY_DELAY`
- `CANVA_WIDTH`, `CANVA_HEIGHT`
- `RUN_STAMPING_REQUEST` (optional)
- `PDF_SIGNING_STATUS_CALLBACK`, `PDF_SIGNING_STATUS_CALLBACK_ENABLED` (optional)
- Branding: `PS_PAGE_TITLE`, `PS_LOGO_PATH`, `PS_DEFAULT_LOGO_PATH`, `SHOW_USER_DATA_BOX`

Server essentials (config.js)
- `KEYCLOAK_CONFIG`, `ALLOWED_ORIGINS`, `PORT`
- `REGISTER_PDF_API_KEY`
- `ARCHIVE_API_BASE_URL`, `CONTAINER_API_BASE_URL`
- `CREATE_DOCUMENT_API_URL`, `DEFAULT_DOCUMENT_JSON`
- `VISUAL_SIGNATURE_API_TEMPLATE`
- `STAMP_API_TEMPLATE` (optional)

### Cloud minimal examples

Client `constants.json` (essential keys only; keep TRANSLATIONS from default)
```json
{
  "PS_PAGE_TITLE": "TrustLynx",
  "PS_LOGO_PATH": "/portal/logo.png",
  "PS_DEFAULT_LOGO_PATH": "/portal/logo.png",
  "KEYCLOAK_URL": "https://padsign.trustlynx.com/auth",
  "KEYCLOAK_REALM": "padsign",
  "KEYCLOAK_CLIENT_ID": "padsign-client",
  "KEYCLOAK_REDIRECT_URI": "https://padsign.trustlynx.com/portal/",
  "KEYCLOAK_POST_LOGOUT_REDIRECT_URI": "https://padsign.trustlynx.com/portal/",
  "PS_API_ACTUAL_USER": "/api/latestUser",
  "USER_POLLING_FREQUENCY": 5000,
  "PS_DOWNLOAD_API": "https://padsign.trustlynx.com/archive/api/document/",
  "PDF_RENDER_SYNCFUSION_SECRET_KEY": "<your-syncfusion-license>",
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
  "PDF_SIGNING_STATUS_CALLBACK": "",
  "PDF_SIGNING_STATUS_CALLBACK_ENABLED": false,
  "SHOW_USER_DATA_BOX": false
  /* Keep TRANSLATIONS, DEFAULT_LANGUAGE from default file */
}
```

Server `config.js` (cloud-focused)
```js
module.exports = {
  PORT: 3001,
  CONTAINER_API_BASE_URL: "https://padsign.trustlynx.com/container/api/",
  ARCHIVE_API_BASE_URL: "https://padsign.trustlynx.com/archive/api/",
  CREATE_DOCUMENT_API_URL: "https://padsign.trustlynx.com/archive/api/document/create",
  VISUAL_SIGNATURE_API_TEMPLATE: "https://padsign.trustlynx.com/container/api/signing/visual/pdf/{docid}/sign",
  STAMP_API_TEMPLATE: "https://padsign.trustlynx.com/container/api/stamping/pdf/stamp/{docid}/as/{company}",
  ALLOWED_ORIGINS: [
    'https://padsign.trustlynx.com:5173',
    'https://padsign.trustlynx.com'
  ],
  DEFAULT_DOCUMENT_JSON: {
    objectName: "template",
    contentType: "application/pdf",
    documentType: "DMSSDoc",
    documentFilename: "template.pdf"
  },
  KEYCLOAK_CONFIG: {
    realm: "padsign",
    "auth-server-url": "https://padsign.trustlynx.com/auth",
    resource: "padsign-backend",
    credentials: { secret: "<backend-client-secret>" },
    "bearer-only": true
  },
  REGISTER_PDF_API_KEY: "<strong-api-key>"
};
```

## How configuration is loaded

- Client (SPA): On load, the SPA fetches `/portal/constants.json` at runtime and merges it into the app. In Docker, this is provided by the `ps-client` container and is volume‑mounted from `./config/constants.json`. Changing this file takes effect on next page load (no rebuild required).
- Server (Node backend): The server reads `config.js` at startup. In Docker, this is provided to the `ps-server` container as `/usr/src/app/config.js` and volume‑mounted from `./config/config.js`. Changing this file requires a container restart.

Docker Compose mappings (see `docker-compose.yml`):
- `./config/constants.json` → `ps-client:/usr/share/nginx/html/portal/constants.json`
- `./config/config.js` → `ps-server:/usr/src/app/config.js`

> Note: There is a second `server/config.js` kept for local development of the backend; production deployments should use `config/config.js` via Compose.

---

## Client: config/constants.json

Branding and UI
- `PS_PAGE_TITLE`: Window title and logo alt text. Default: `"TrustLynx"`.
- `PS_LOGO_PATH`: Path to logo used in header. Default: `"/portal/logo.png"`.
- `PS_DEFAULT_LOGO_PATH`: Fallback logo if `PS_LOGO_PATH` missing. Default: `"/portal/logo.png"`.
- `SHOW_USER_DATA_BOX`: Toggle small user-info box for authenticated users. Default: `false`.

Authentication (Keycloak)
- `KEYCLOAK_URL`: Base URL to Keycloak auth server. Default: `"https://padsign.trustlynx.com/auth"`.
- `KEYCLOAK_REALM`: Realm name. Default: `"padsign"`.
- `KEYCLOAK_CLIENT_ID`: Public client ID used by the SPA. Default: `"padsign-client"`.
- `KEYCLOAK_REDIRECT_URI`: SPA redirect URI after login. Default: `"https://padsign.trustlynx.com/portal/"`.
- `KEYCLOAK_POST_LOGOUT_REDIRECT_URI`: Redirect URI after logout. Default: `"https://padsign.trustlynx.com/portal/"`.

Data polling and backend endpoints
- `PS_API_ACTUAL_USER`: Path to latest user API (proxied by nginx to backend). Used by polling worker. Default: `"/api/latestUser"`.
- `USER_POLLING_FREQUENCY`: Polling interval in ms for `/latestUser`. Default: `5000`.
- `TL_CREATE_DOC_API`: Path (legacy/unused in SPA) for creating a document via backend. Default: `"/api/document/create"`. API is not relevant for cloud instance.
- `TL_CREATE_DOC_BODY`: JSON payload (legacy/unused in SPA) describing document defaults when creating via backend; see also server `DEFAULT_DOCUMENT_JSON`. API is not relevant for cloud instance.
- `PS_API_GEN_DOC`: Path to backend’s doc ID generator. Default: `"/api/getDocID"`. API is not relevant for cloud instance.
- `PS_API_SAVE_DOC_IN_STORAGE`: Path to backend endpoint that downloads a generated PDF into `DOCUMENT_OUTPUT_DIRECTORY`. Default: `"/api/save"`. API is not relevant for cloud instance.
- `PS_API_GEN_XML`: Path to backend XML generation endpoint. Default: `"/api/xml"`. API is not relevant for cloud instance.
- `PS_API_REMOVE_USER`: Path to remove user/cleanup endpoint. Default: `"/api/removeUser"`.
- `TL_FILL_PDF_AND_UPDATE_DOC`: Path to backend PDF form fill and upload endpoint. Default: `"/api/fillPDF"`. API is not relevant for cloud instance.

PDF rendering, download, and signature overlay
- `PS_DOWNLOAD_API`: Archive service base used by the viewer to open PDFs in readonly mode. Final URL: `PS_DOWNLOAD_API + <docId> + "/download"`. Default: `"https://padsign.trustlynx.com/archive/api/document/"`.
- `PDF_TEST_PATH`: Base URL to static templates for interactive mode. Viewer uses `PDF_TEST_PATH + "_" + <lng> + ".pdf"` (e.g., `/portal/template_LV.pdf`). Default: `"https://padsign.trustlynx.com/template"` (override to your SPA path if hosting templates with the client). API is not relevant for cloud instance.
- `PDF_RENDER_SYNCFUSION_SECRET_KEY`: Syncfusion viewer license key used at runtime. Default: present key in repo (replace with your own license key).
- `PDF_TEMPLATE_ID`: Template ID (legacy/unused in current code path). Not relevant for cloud instance.
- `PDF_SIGNATURE_X`: X position for visual signature overlay (px units, service‑specific). Default: `-250`.
- `PDF_SIGNATURE_Y`: Y position for visual signature overlay. Default: `-100`.
- `PDF_SIGNATURE_ZOOM`: Scale for signature image in overlay. Default: `100`.
- `PDF_SIGNATURE_PAGE`: Page index for the overlay (special value `10000` instructs service to place at last page). Default: `10000`.
- `PDF_ZOOM_VALUE`: Initial zoom level in viewer. Default: `"125"`.
- `MAX_ZOOM`: Max zoom allowed. Default: `125`.
- `MIN_ZOOM`: Min zoom allowed. Default: `125`.
- `DEFAULT_PAGE_SIZE`: CSS height for PDF viewer container. Default: `"7800px"`.
- `EXTRA_HEIGHT_MARGIN_PX`: Extra pixels added to computed PDF height to prevent clipping. Default: `2500`.
- `OPACITY_DELAY`: Delay (ms) before removing loading overlays after viewer load. Default: `4000`.

Signature pad and phone prefixing
- `CANVA_WIDTH`: Signature canvas width (px). Default: `300`.
- `CANVA_HEIGHT`: Signature canvas height (px). Default: `100`.
- `COUNTRY_SELECTOR`: HTML snippet injected near phone field to pick country code. Default: dropdown for LV/EE/LT. Not relevant for cloud instance.
- `COUNTRY_SELECTION_SELECTOR_APPEND_DELAY`: Retry interval (ms) to insert `COUNTRY_SELECTOR`. Default: `1000`. Not relevant for cloud instance.
- `DEFAULT_PHONE_PREFIX`: Fallback country prefix when selector unavailable. Default: `"371"`. Not relevant for cloud instance.

Form field behavior and mappings
- `FORM_FIELDS`: Map of PDF form field names to types (`Text`, `Checkbox`, `Multiselection`, etc.). Used to coerce values before sending to backend. Not relevant for cloud instance.
- `PS_USER_DATA_FIELD_NAMES`: List of text fields that should auto‑fill with composed user data. Default: `GDPR_client_data`, `GPDR_signer_data`, `SA_client_data`, `SA_signer_data`, `VID_client_data`, `VID_signer_data`. Not relevant for cloud instance.
- `PS_LOCATION_DATA_FIELD_NAMES`: List of text fields that should auto‑fill with current date/location. Default includes three `*_locationdate` fields. Not relevant for cloud instance.
- `CHECKBOX_GROUP_VID`: Two checkbox field names that must be mutually exclusive (component enforces this). Default: `VID_agree_checkbox`, `VID_disagree_checkbox`. Not relevant for cloud instance.
- `SURVEY_MAPPING`: Numeric → label mapping for survey choice display (currently not used in rendering logic). Not relevant for cloud instance.
- `HIDDEN_FIELDS`: Fields to hide per language (currently not active in code; kept for future use). Not relevant for cloud instance.

Localization and text
- `DEFAULT_LANGUAGE`: Default language code for UI and date formatting. Default: `"LV"`.
- `LV_MONTHS_LIST` / `EN_MONTHS_LIST`: Month names used to build `getCurrentDate()` texts placed into PDF fields. Not relevant for cloud instance.
- `TRANSLATIONS`: String resources for UI and notifications in `LV` and `EN`. Update to localize texts.

Workflow toggles and callbacks
- `RUN_STAMPING_REQUEST`: When `true`, triggers a backend call to stamp the PDF after signing. Default: `false`.
- `PDF_SIGNING_STATUS_CALLBACK`: Optional external webhook URL to notify when a PDF is signed. Default: `"https://example.com/api/signing-status"`.
- `PDF_SIGNING_STATUS_CALLBACK_ENABLED`: Enables the webhook above when `true`. Default: `false`.

Misc
- `PS_PAGE_REFRESH_TIME`: Legacy/unused; kept for compatibility. Not relevant for cloud instance.
- `STAMP_COMPANY_NAME`: Legacy/unused in current backend proxy; kept for compatibility. Not relevant for cloud instance.

---

## Server: config/config.js

Service endpoints and templates
- `CONTAINER_API_BASE_URL`: Base URL for container/signature service. Default: `"https://padsign.trustlynx.com/container/api/"`.
- `ARCHIVE_API_BASE_URL`: Base URL for archive/document service. Default: `"https://padsign.trustlynx.com/archive/api/"`.
- `CREATE_DOCUMENT_API_URL`: Archive endpoint to create a new document. Default: `<ARCHIVE_API_BASE_URL>document/create`.
- `FORM_FILL_API_URL`: Container endpoint to fill a template with field data. Final URL is `FORM_FILL_API_URL + <lng>`. Default: `"https://padsign.trustlynx.com/container/api/forms/fill/template/application"`. API is not relevant for cloud instance.
- `DOCUMENT_DOWNLOAD_API_URL`: Archive endpoint to download a document by ID. Default: `<ARCHIVE_API_BASE_URL>document/`. API is not relevant for cloud instance.
- `VISUAL_SIGNATURE_API_TEMPLATE`: Template URL for visual signature call; `"{docid}"` is replaced by the backend. Default: `"https://padsign.trustlynx.com/container/api/signing/visual/pdf/{docid}/sign"`.
- `STAMP_API_TEMPLATE`: Template URL for stamping; `"{docid}"` is replaced. If your target requires a company, also provide `{company}` replacement. Default: `"https://padsign.trustlynx.com/container/api/stamping/pdf/stamp/{docid}/as/{company}"`.

Files and directories
- `TEMPLATE_DIRECTORY`: Path prefix to template PDFs used by `/getDocID`. The server appends `"_" + <lng> + ".pdf"`, so the final path should resolve to files like `.../template_LV.pdf` and `.../template_EN.pdf`. Default: `"/Repos/psapp/client/public/template"`. API is not relevant for cloud instance.
- `DEFAULT_TEMPLATE_FILENAME`: Filename presented to archive service when uploading a template stream. Default: `"template.pdf"`.
- `TEMP_DIRECTORY`: Local directory for temporary PDFs produced by form fill. Default: `"./tmp/"`. Not relevant for cloud instance.
- `DOCUMENT_OUTPUT_DIRECTORY`: Directory where saved PDFs/XMLs are written. Default: `"/PSDOCS/out/"`. Not relevant for cloud instance.
- `READONLY_PDF_DIRECTORY`: Directory to search for readonly PDFs by naming pattern. Default: `"/PSDOCS/in/"`. API is not relevant for cloud instance.

Server and CORS
- `PORT`: Port the Node server listens on. Default: `3001`.
- `ALLOWED_ORIGINS`: Array of origins allowed by CORS. Must include the browser origins that call the backend through nginx. Default: `['https://padsign.trustlynx.com:5173', 'https://padsign.trustlynx.com']`.

---

## Cloud Flow: /api/registerPDF

Purpose
- Upload a ready PDF to Archive and make it available to the SPA for viewing and signing.
- Protected by an API key carried in the `Authorization: Bearer` header, configured in server `config/config.js` as `REGISTER_PDF_API_KEY`.

Endpoint
- Method: `POST`
- URL: `/api/registerPDF`
- Auth: `Authorization: Bearer <REGISTER_PDF_API_KEY>` (NOT a Keycloak token)
- Content-Type: `multipart/form-data`
- Body fields:
  - `file`: The PDF file (must be `application/pdf`; max 10 MB)
  - `email`: End user or session email identifier (string)
  - `company`: Company identifier (string). For SPA auto-detection, it should match a Keycloak realm role name assigned to the operator using the SPA.
  - `clientName` (optional): Friendly display name for UI (alias: `clientname`).

Behavior
- On success, backend uploads the PDF to Archive (`CREATE_DOCUMENT_API_URL`), stores `{ email, company, doc }` in memory, and returns `201` with the document ID.
- SPA polls `/api/latestUser?email=<email>&company=<company>` with a Keycloak Bearer token and will display the document for viewing/signing.
- Data is kept in memory (non-persistent). A server restart clears registrations.

Responses
- `201` JSON: `{ "message": "PDF registered successfully", "docId": "<uuid>" }`
- `400` JSON: `{ "error": "Please provide all required fields: file, email, company" }`
- `400` JSON: `{ "error": "Only PDF files are allowed" }`
- `401` JSON: `{ "error": "Invalid API key" }` (or `Authorization header required`)
- `500` JSON: `{ "error": "Failed to upload PDF to archive service" }` or `{ "error": "Internal server error" }`

Example (curl)
```bash
curl -X POST "https://padsign.trustlynx.com/api/registerPDF" \
  -H "Authorization: Bearer ${REGISTER_PDF_API_KEY}" \
  -F "file=@/path/to/file.pdf;type=application/pdf" \
  -F "email=user@example.com" \
  -F "company=Adenta" \
  -F "clientName=John Doe"
```

Example (HTTPie)
```bash
http -f POST https://padsign.trustlynx.com/api/registerPDF \
  Authorization:"Bearer ${REGISTER_PDF_API_KEY}" \
  file@/path/to/file.pdf email=user@example.com company=Adenta clientName='John Doe'
```

Follow-up in SPA
- The SPA, once an authenticated user is logged in to Keycloak, requests `/api/latestUser` with the same `email` and `company`. Ensure the `company` matches a role assigned to that user to enable the email/company polling mode.
- The viewer constructs the download URL as: `PS_DOWNLOAD_API + <docId> + "/download"`.

Related configuration
- `REGISTER_PDF_API_KEY` (server): API key expected in `Authorization` header for this endpoint.
- `ARCHIVE_API_BASE_URL` and `CREATE_DOCUMENT_API_URL` (server): Where the PDF is persisted.
- `PS_DOWNLOAD_API` (client): Used by the viewer to fetch the registered PDF by `docId`.
- `USER_POLLING_FREQUENCY` (client): Controls how often the SPA checks for the registered PDF.

Behavior flags and defaults
- `ENABLE_PERSONAL_CODE_VALIDATION`: When `true`, validates Latvian personal code format on specific routes. Default: `false`. API is not relevant for cloud instance.
- `DEFAULT_DOCUMENT_JSON`: JSON payload sent when creating a new archive document. Includes `objectName`, `contentType`, `documentType`, `documentFilename`.

Authentication and security
- `KEYCLOAK_CONFIG`: Backend Keycloak adapter configuration. Important fields:
  - `realm`: Keycloak realm, default `"padsign"`.
  - `auth-server-url`: Base URL to Keycloak, default `"https://padsign.trustlynx.com/auth"`.
  - `resource`: Backend client (confidential) ID, default `"padsign-backend"`.
  - `credentials.secret`: Client secret for the confidential backend client.
  - `bearer-only`: `true` in this config so the backend does not initiate browser logins.
- `REGISTER_PDF_API_KEY`: Static API key protecting the `/api/registerPDF` endpoint (sent as `Authorization: Bearer <key>` by 3rd‑party uploaders). Replace with a strong secret for production.

---

## Changing values safely

- Update `config/constants.json` to tune client behavior, UI, and runtime endpoints. Most changes apply on page reload. Avoid committing real secrets (e.g., Syncfusion license) to VCS.
- Update `config/config.js` to point the backend to your DMSS services, tune storage paths, and set auth. Restart `ps-server` after changes. Treat the Keycloak secret and API key as sensitive.

## Quick verification

- Client loads `constants.json`: Open the browser DevTools network tab and verify `/portal/constants.json` loads and values match your changes.
- Backend uses `config.js`: Check `ps-server` logs on startup. You should see the configured port, output folder, and realm printed.

## Notes

- Some keys in `constants.json` are currently legacy or reserved for future functionality (e.g., `PDF_TEMPLATE_ID`, `PS_PAGE_REFRESH_TIME`, `STAMP_COMPANY_NAME`, parts of `HIDDEN_FIELDS`). They are documented above for completeness.
- If you need environment‑based switching, consider generating these files at deploy time (e.g., mounting environment‑specific variants) rather than baking many conditionals into the code.
2. Verify nginx proxy settings
3. Ensure containers can reach each other

### Debug Steps

1. **Check Keycloak Logs**:
   ```bash
   docker-compose logs keycloak
   ```

2. **Check Application Logs**:
   ```bash
   docker-compose logs ps-server
   docker-compose logs nginx
   ```

3. **Verify Network Connectivity**:
   ```bash
   docker-compose exec keycloak ping ps-server
   ```

4. **Test Keycloak Endpoints**:
   ```bash
   curl https://padsign.trustlynx.com/auth/realms/padsign/.well-known/openid_configuration
   ```

## Security Considerations

1. **Change Default Passwords**: Update `KEYCLOAK_ADMIN_PASSWORD`
2. **Use Strong Client Secrets**: Generate secure secrets for backend clients
3. **Enable HTTPS**: Always use HTTPS in production
4. **Regular Updates**: Keep Keycloak updated
5. **Monitor Logs**: Regularly check authentication logs

## Production Deployment

### 1. Environment Variables

Set production environment variables:

```bash
# Keycloak
KEYCLOAK_ADMIN_PASSWORD=your_secure_password
KC_HOSTNAME=your-production-domain.com

# Client
VITE_HOST=your-production-domain.com
```

### 2. SSL Certificates

Ensure SSL certificates are properly configured in nginx:

```nginx
ssl_certificate     /etc/nginx/certs/your-domain.crt;
ssl_certificate_key /etc/nginx/certs/your-domain.key;
```

### 3. Database Persistence

For production, use a persistent database instead of the default H2:

```yaml
keycloak:
  environment:
    - KC_DB=postgres
    - KC_DB_URL=jdbc:postgresql://postgres:5432/keycloak
    - KC_DB_USERNAME=keycloak
    - KC_DB_PASSWORD=your_db_password
```

## Support

For issues related to:
- **Keycloak Configuration**: Check Keycloak documentation
- **Application Integration**: Review this guide
- **Container Issues**: Check Docker and Docker Compose logs

## Additional Resources

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Keycloak JavaScript Adapter](https://www.keycloak.org/docs/latest/securing_apps/#_javascript_adapter)
- [Docker Compose Documentation](https://docs.docker.com/compose/)

# PS App Cloud Deployment - Deployment Guide

This repository contains a complete, containerized deployment of the PS App platform behind an HTTPS reverse proxy with Keycloak-based authentication and a set of DMSS services for document archiving, container creation, and digital signatures.

Use this guide to configure, run, and operate the stack in local, staging, or production environments.

---

## Overview

- Reverse proxy and TLS termination via NGINX.
- Authentication and authorization via Keycloak.
- PS Client (SPA) served via container.
- PS Server (Node.js backend) with configurable endpoints and Keycloak integration.
- DMSS services for archive, container/signature, and a local fallback archive.
- Docker Compose orchestration with a persistent volume for Keycloak data.

---

## Architecture

Services defined in `docker-compose.yml`:

- NGINX: Public entrypoint on ports 80/443; routes to backend services and Keycloak.
- Keycloak: Identity provider; exposed on port 8080 and proxied at `/auth` through NGINX.
- PS Client: SPA served by its own NGINX; proxied by the public NGINX at `/portal`.
- PS Server: Backend API consumed by PS Client; proxied by the public NGINX at `/api`.
- DMSS Container and Signature Services: PDF/container operations, signing flows, Smart-ID/Mobile-ID.
- DMSS Archive Services: Archive API; configured with in-memory DB by default.
- DMSS Archive Services Fallback: Filesystem-based fallback archive; stores files in `./docs`.

High-level routing:

- `https://<host>/portal/...` -> `ps-client`
- `https://<host>/auth/...` -> `keycloak`
- `https://<host>/api/...` -> `ps-server`
- `https://<host>/container/api/...` -> `dmss-container-and-signature-services`
- `https://<host>/archive/api/...` -> `dmss-archive-services` (fallback to `dmss-archive-services-fallback` as configured)

---

## Prerequisites

- Docker Desktop 4.x (Docker Engine 20+; Compose v2).
- A DNS name you control (production) or a local hostname mapping (development).
- TLS certificate and key for your hostname (PEM). Self-signed is acceptable for local testing.
- Open host ports: 80, 443, 8080, 3001, 84, 86, 93.
- Suggested resources: 4 vCPU, 6-8 GB RAM.

Optional (local):

- mkcert (included as `nginx/mkcert.exe` for Windows) to generate a locally trusted certificate.

---

## Domain and TLS Certificates

The NGINX virtual host is configured for `padsign.trustlynx.com` out of the box. Update this to your hostname and provide matching certificates.

1) Replace server_name and cert paths

- Edit `nginx/nginx.conf` and change:
  - `server_name` to your hostname, e.g. `example.yourdomain.com`.
  - `ssl_certificate` and `ssl_certificate_key` to your certificate files in `nginx/certs`.

2) Provide certificates

- Place your certificate and key files in `nginx/certs/`.
- Ensure file names match those referenced in `nginx/nginx.conf`.

Local option (Windows):

- Generate a local cert: `nginx/mkcert.exe example.local` and then point `ssl_certificate` and `ssl_certificate_key` to the generated files.

3) DNS or hosts entry

- Production: Point your domain's A/AAAA record to the host running this stack.
- Local: Add a hosts entry mapping your hostname to `127.0.0.1` (or the Docker host IP) and use a locally trusted cert.

---

## Configuration

Review and adjust these files before running:

- `docker-compose.yml`
  - `KC_HOSTNAME` should match your hostname.
  - Host ports 80/443, 8080, 3001, 84, 86, 93 must be free.
  - Note: `ps-client` defines a bind mount `./client/docker/nginx.conf`. If you don't intend to override the client image's NGINX, remove this mount or create the file.

- `nginx/nginx.conf`
  - Update `server_name` and TLS files.
  - Proxy targets are pre-wired to internal services; `/archive/api` and `/container/api` routes target host ports `86` and `84` via `host.docker.internal` (intentional for Windows/macOS). Keep the published host ports in `docker-compose.yml` aligned with these.

- `config/config.js` (PS Server)
  - Update all hardcoded URLs from `https://padsign.trustlynx.com/...` to your hostname.
  - Set `KEYCLOAK_CONFIG` for your realm and backend client secret.
  - Adjust CORS: `ALLOWED_ORIGINS` should include your portal origin(s).
  - Set directories: `DOCUMENT_OUTPUT_DIRECTORY`, `READONLY_PDF_DIRECTORY` to writable paths where required by your runtime.

- `config/constants.json` (PS Client)
  - Change `KEYCLOAK_URL`, `KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID`, and redirect URIs to match your hostname and Keycloak setup.
  - Update `PS_DOWNLOAD_API` and any other absolute URLs.
  - Optional: Branding (logo, page title) and UX parameters.

- `dmss-container-and-signature-services/application.yml`
  - `archive-services.baseUrl` and `fallbackUrl` point to internal service names and typically do not need changes.
  - Trust stores and certificate files referenced under `/confs` must exist in `dmss-container-and-signature-services/`.

- `dmss-archive-services/application.yml`
  - Default uses in-memory HSQL database. For persistence, configure Postgres (uncomment and set `spring.datasource.*`) and provide the DB instance.

- `dmss-archive-services-fallback/application.yml`
  - File paths point to `/docs` inside the container. The `./docs` folder on the host is bind-mounted; ensure it exists and is writable.

- Keycloak database persistence
  - A named Docker volume `keycloak_data` is created by compose and used for Keycloak; back it up for production.

Secrets and credentials

- Do not commit real client secrets, keystore passwords, or API keys.
- Replace placeholder values before going live and rotate any credentials found in this repo.

---

## Security and Route Protection

- TLS termination: All external traffic enters via NGINX on 443; HTTP 80 redirects to HTTPS.
- Public routes:
  - `/portal/*` serves the SPA. The SPA itself gates features by user auth state.
  - `/auth/*` proxies to Keycloak for login, tokens, and account management.
  - `/api/*` proxies to the backend (ps-server). This route requires a valid Bearer token.
  - `/container/api/*` and `/archive/api/*` proxy to DMSS services. For production, restrict these (IP allowlist, mTLS) or enforce JWT on the services.
- SPA authentication (frontend): Uses Keycloak (public client). Recommended flow is Authorization Code with PKCE. The SPA obtains an access token and attaches it as `Authorization: Bearer <token>` to API calls.
- Backend enforcement (ps-server): Configured as a bearer-only confidential client. It validates incoming JWTs from Keycloak and only serves `/api/*` when a valid token is present. CORS should be restricted to known origins in `config/config.js`.
- Header forwarding (DMSS): `dmss-container-and-signature-services` is configured to forward `Authorization` and other headers to the archive service. Align DMSS auth to your policy.
- Enabling JWT on DMSS Archive (recommended for prod): In `dmss-archive-services/application.yml` set `authentication.jwt.enabled: true` and configure either `useCert: true` with a public key/cert or a shared `secret`, and set `validation: true`.
- NGINX hardening: If DMSS endpoints should not be directly reachable from the internet, remove or restrict the `/container/api` and `/archive/api` locations, or protect them with allowlists or client certificates.
- Keycloak admin: Limit admin console access (IP allowlist/VPN) and change the default admin password immediately.

## Data Flow

```mermaid
flowchart TD
  U[User Browser] -->|HTTPS 443| N[NGINX];
  N -->|portal| C[ps-client SPA];
  N -->|auth| K[Keycloak];
  N -->|api| B[ps-server];
  B -->|REST| CS[DMSS Container/Signature];
  B -->|REST| AR[DMSS Archive];
  CS -->|fallback on error| FB[DMSS Archive Fallback];
  C -->|OIDC redirects| K;
```

Legend: portal = /portal/*, auth = /auth/*, api = /api/*

```mermaid
sequenceDiagram
  autonumber
  participant Browser
  participant NGINX
  participant Keycloak
  participant Backend as ps-server
  participant DMSSCS as DMSS Container/Signature
  participant DMSSAR as DMSS Archive

  Browser->>NGINX: GET /portal/*
  Browser->>Keycloak: OIDC login (via /auth/*)
  Keycloak-->>Browser: Authorization code
  Browser->>Keycloak: Exchange code + PKCE for tokens
  Keycloak-->>Browser: Access token (JWT)
  Browser->>NGINX: GET /api/resource (Authorization: Bearer <token>)
  NGINX->>Backend: Proxy /api/*
  Backend->>Backend: Verify JWT (Keycloak realm config)
  Backend-->>NGINX: 200 OK / data
  NGINX-->>Browser: 200 OK / data
  Backend->>DMSSCS: Call container/signature API (forward Authorization)
  DMSSCS->>DMSSAR: Call archive API (forward headers)
  DMSSAR-->>DMSSCS: Response
  DMSSCS-->>Backend: Response
```

---

## Running the Stack

1) Prepare folders

- Ensure `./nginx/certs` contains your TLS cert and key.
- Ensure `./docs` exists (used by fallback archive service).

2) Start services

```sh
docker compose up -d
```

3) Verify

- Portal: `https://<host>/portal/`
- API: `https://<host>/api/health` (if exposed by ps-server) or check container logs
- Keycloak: `https://<host>/auth/`
- DMSS health (Spring Boot): `/actuator/health` on the service base paths if enabled
- run /registerPDF API and recieve status code = 201
  
![alt text](image.png)

4) Logs

```sh
docker compose ps
docker compose logs -f nginx
# or a specific service, e.g.
docker compose logs -f ps-server
```

5) Stop / remove

```sh
docker compose down
# Add -v to remove named volumes if required
```

---

## Local Development Tips

- Hosts entry: map your chosen hostname to 127.0.0.1.
- Certificates: use mkcert to create a locally trusted cert and point `nginx/nginx.conf` to it.
- `host.docker.internal`: The public NGINX forwards to 84 and 86 on the host for container/signature and archive services; these are published by compose. This is intentional for Windows/macOS; Linux users may prefer service-name routing (requires editing `nginx/nginx.conf`).
- Client NGINX override: If `./client/docker/nginx.conf` does not exist locally, remove that bind mount from `docker-compose.yml` or create the file to avoid a bind error.

---

## Production Hardening

- Replace all sample secrets and keystore passwords.
- Use managed TLS (for example, certbot/ACME or cloud load balancer) and rotate certificates.
- Enable persistent databases for DMSS Archive Services and other stateful components.
- Configure Keycloak for production (HTTPS, hostname, external DB if needed).
- Tighten CORS in `config/config.js` and `config/constants.json` to explicit origins.
- Limit management/actuator exposure to internal networks.
- Consider placing the public NGINX behind a cloud or hardware load balancer.

---

## Troubleshooting

- Port conflicts: Ensure host ports 80/443/8080/3001/84/86/93 are free before starting.
- TLS/hostname mismatch: Align `server_name`, certificate CN/SANs, and all application URLs with your actual hostname.
- Keycloak login issues: Check SPA client redirect URIs and Web Origins. Verify `KEYCLOAK_CONFIG` in `config/config.js` (backend client secret and realm).
- Bind mount errors for ps-client: If Docker reports a missing `./client/docker/nginx.conf`, either create the file or remove the bind from `docker-compose.yml`.
- Self-signed certificate warnings: Trust the local root (mkcert) or install a valid certificate.
- DMSS service connectivity: Review `dmss-container-and-signature-services/application.yml` for endpoints and modes (TEST vs PROD). Check that truststores and referenced files exist under `dmss-container-and-signature-services/`.

---

## File Map and References

- Compose: `docker-compose.yml`
- Public NGINX: `nginx/nginx.conf`, `nginx/certs/`
- PS Server config: `config/config.js`
- PS Client config: `config/constants.json`
- DMSS Container and Signature Service config: `dmss-container-and-signature-services/application.yml`
- DMSS Container and Signature ancillary files: `dmss-container-and-signature-services/*.p12`, `dmss-container-and-signature-services/*.yaml`, `dmss-container-and-signature-services/documentsigningprofiles.json`
- DMSS Archive Services config: `dmss-archive-services/application.yml`, `dmss-archive-services/mappings.json`
- DMSS Archive Fallback config: `dmss-archive-services-fallback/application.yml`, host data dir `./docs`

---

## Notes on Security

- Treat any secrets present in this repository as placeholders only; rotate them prior to deployment.
- Restrict admin endpoints and Keycloak admin console to trusted networks.
- Regularly back up the `keycloak_data` volume and any persistent stores you configure.
