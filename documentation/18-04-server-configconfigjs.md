# 18.4 Server: config/config.js

Service endpoints and templates
- `CONTAINER_API_BASE_URL`: Base URL for container/signature service. Default: `"https://padsign.trustlynx.com/container/api/"`.
- `ARCHIVE_API_BASE_URL`: Base URL for archive/document service. Default: `"https://padsign.trustlynx.com/archive/api/"`.
- `CREATE_DOCUMENT_API_URL`: Archive endpoint to create a new document. Default: `<ARCHIVE_API_BASE_URL>document/create`.
- `FORM_FILL_API_URL`: Container endpoint to fill a template with field data. Final URL is `FORM_FILL_API_URL + <lng>`. Default: `"https://padsign.trustlynx.com/container/api/forms/fill/template/application"`. API is not relevant for cloud instance.
- `DOCUMENT_DOWNLOAD_API_URL`: Archive endpoint to download a document by ID. Default: `<ARCHIVE_API_BASE_URL>document/`. API is not relevant for cloud instance.
- `VISUAL_SIGNATURE_API_TEMPLATE`: Template URL for visual signature call; `"{docid}"` is replaced by the backend. Default: `"https://padsign.trustlynx.com/container/api/signing/visual/pdf/{docid}/sign"`.
- `STAMP_API_URL`: e-seal service endpoint used by stamping flow when enabled.

Files and directories
- `TEMPLATE_DIRECTORY`: Legacy template path prefix (not used by standard cloud flows). Default: `"/Repos/psapp/client/public/template"`.
- `DEFAULT_TEMPLATE_FILENAME`: Filename presented to archive service when uploading a template stream. Default: `"template.pdf"`.
- `TEMP_DIRECTORY`: Local directory for temporary PDFs produced by form fill. Default: `"./tmp/"`. Not relevant for cloud instance.
- `DOCUMENT_OUTPUT_DIRECTORY`: Directory where saved PDFs/XMLs are written. Default: `"/PSDOCS/out/"`. Not relevant for cloud instance.
- `READONLY_PDF_DIRECTORY`: Directory to search for readonly PDFs by naming pattern. Default: `"/PSDOCS/in/"`. API is not relevant for cloud instance.

Server and CORS
- `PORT`: Port the Node server listens on. Default: `3001`.
- `ALLOWED_ORIGINS`: Array of origins allowed by CORS. Must include the browser origins that call the backend through nginx. Default: `['https://padsign.trustlynx.com:5173', 'https://padsign.trustlynx.com']`.
- `REGISTER_PDF_API_KEY`: API key used by external integrations for API-key protected endpoints.
- `ALLOW_INSECURE_TLS`: Optional TLS relaxation for troubleshooting only (keep `false` in production).
- `SESSION_SECRET`: Session secret for backend internals.
- `REGISTER_PDF_UPSTREAM_TIMEOUT_MS`, `REGISTER_PDF_UPSTREAM_RETRIES`: Upstream retry/timeout controls for register flow.
- `REGISTER_PDF_MAX_CONCURRENCY`, `REGISTER_PDF_QUEUE_MAX_SIZE`, `REGISTER_PDF_QUEUE_WAIT_MS`: In-memory queue controls for burst handling.
- `DEPENDENCY_CB_FAILURE_THRESHOLD`, `DEPENDENCY_CB_COOLDOWN_MS`: Circuit breaker thresholds/cooldown.
- `DOC_OPERATION_LOCK_TTL_MS`, `IDEMPOTENCY_TTL_MS`: Duplicate/parallel signing protection controls.
- `USER_ENTRY_TTL_MS`, `USER_STATE_CLEANUP_MS`: In-memory state retention and cleanup interval.
- `PRIVILEGED_API_ROLES`: Optional role allowlist for privileged internal cleanup operations.

Document routing (post-signing actions)
- `DOCUMENT_ROUTING`: Configures what happens after a document is signed. Disabled by default.
  - `enabled` (boolean): Master switch. Default: `false`.
  - `skipDemo` (boolean): Skip routing for demo-mode documents. Default: `true`.
  - `strategies` (array): List of routing actions. Each has `type`, `enabled`, and type-specific options.
  - Strategy `"filesystem"`: Saves PDF to disk with configurable folder structure. Options: `basePath`, `pathTemplate` (supports `{company}`, `{date:YYYY-MM}`, `{docid}`, `{email}`, `{lng}` tokens), `createDirectories`.
  - Strategy `"webhook"`: POSTs document metadata (and optionally the file) to a URL with retry logic. Options: `url`, `method`, `headers`, `includeFile`, `timeoutMs`, `retries`, `retryBaseDelayMs`. Sends `document.signed` events on success and `document.signing_error` on failure.
  - Future strategy types (`s3`, `sftp`, `email`) can be added without breaking existing config.

Customer Data lookup (virtual-printer flow)
- `CUSTOMER_DATA_API_URL`, `CUSTOMER_DATA_API_KEY`, `CUSTOMER_DATA_API_KEY_HEADER`: external customer data service called by ps-server when `POST /api/registerPDF` receives `source=virtual-printer`. The server scans page 1 of the PDF (position-independent text-layer extraction via `pdfjs-dist`) for two barcode-backed identifiers:
  - `customerId` (5-digit) → `GET {URL}{customerId}` with the configured header resolves a customer name, stored as `signerName` for the visual signature (`Signed by: <resolved name>`).
  - `documentNumber` (6-digit) → exposed as `{documentNumber}` in the filesystem routing `pathTemplate`, so signed files are named like `100542_2026.04.22_14_38_36.pdf`.
  Feature is disabled until `CUSTOMER_DATA_API_KEY` is non-empty. Default key header: `api_key`.
- `CUSTOMER_DATA_CACHE_TTL_MS`: in-memory cache TTL for customer lookups. Default: `3600000` (1 hour).
- `CUSTOMER_DATA_TIMEOUT_MS`: HTTP timeout per request. Default: `10000`.
- `CUSTOMER_DATA_RETRIES`: retry count for transient 5xx / timeout errors. Default: `2`.
- Signer name composition: `CustomerFirstName + " " + CustomerLastName` for individuals, or `CustomerLastName` alone for organizations (empty first name).
- Filesystem `pathTemplate` tokens extended with `{documentNumber}`, `{signerName}`, `{customerId}`, and the `ss` seconds format; `{date:...}` output is sanitized so `HH:mm:ss` becomes `HH_mm_ss`. Default template: `{company}/{date:YYYY-MM}/{documentNumber}_{date:YYYY.MM.DD_HH:mm:ss}.pdf`.
- Non-blocking: if the barcode is missing, the customer is not found, or the API is down, signing proceeds with the default fallback (email or name+surname) and the upload is not rejected. Filename falls back to `unknown_<date>.pdf`.

---

