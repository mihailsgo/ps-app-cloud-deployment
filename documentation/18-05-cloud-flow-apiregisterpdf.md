# 18.5 Cloud Flow: /api/registerPDF

Purpose
- Upload a ready PDF to Archive and make it available to the SPA for viewing and signing.
- Protected by an API key carried in the `Authorization: Bearer` header, configured in server `config/config.js` as `REGISTER_PDF_API_KEY`.

## Reading the API key

The `REGISTER_PDF_API_KEY` shipped in this public repository is known to
everyone, so a fresh `bootstrap.sh` replaces it with a random one
(`tlx_pdf_` + 64 hex characters) and never prints it: not to the terminal, not
to the deployment wizard's run log. Read it when you configure a client (the
Virtual Printer / Padsign Manager Setup tab, a 3rd-party uploader), from inside
ps-server, so it appears on your terminal only:

```bash
docker compose exec -T ps-server node -p 'require("/usr/src/app/config.js").REGISTER_PDF_API_KEY' </dev/null
```

That works for anyone who may run `docker compose` here, although
`config/config.js` itself is mode 640 (it reads the file as ps-server's own
user; per-company keys are `.REGISTER_PDF_API_KEYS`). With ps-server down,
read the file as root or as a member of its group:

```bash
sudo python3 -c 'import re; print(re.search(r"REGISTER_PDF_API_KEY\s*:\s*[\"\x27]([^\"\x27]+)", open("config/config.js").read()).group(1))'
```

Hand it over like any other credential, not in a ticket or chat. A key that
still equals the shipped one is a `validate-config.sh` WARN; its fix,
`./installation-scripts/configure-host.sh --host <host> --generate-secrets`
then `docker compose restart ps-server`, means giving every client the new
key.

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
- `429` JSON: queue overload (`REGISTER_PDF_QUEUE_FULL`)
- `503` JSON: queue timeout or dependency circuit open (`REGISTER_PDF_QUEUE_TIMEOUT`, `ARCHIVE_CIRCUIT_OPEN`)
- `502/503/504`: deterministic upstream/archive failures with `errorCode`
- `500` JSON: unhandled internal server error

Example (curl)
```bash
curl -X POST "https://<host>/api/registerPDF" \
  -H "Authorization: Bearer ${REGISTER_PDF_API_KEY}" \
  -F "file=@/path/to/file.pdf;type=application/pdf" \
  -F "email=user@example.com" \
  -F "company=<your-company>" \
  -F "clientName=John Doe"
```

Example (HTTPie)
```bash
http -f POST https://<host>/api/registerPDF \
  Authorization:"Bearer ${REGISTER_PDF_API_KEY}" \
  file@/path/to/file.pdf email=user@example.com company=<your-company> clientName='John Doe'
```

Follow-up in SPA
- The SPA, once an authenticated user is logged in to Keycloak, requests `/api/latestUser` with the same `email` and `company`. Ensure the `company` matches a role assigned to that user to enable the email/company polling mode.
- The viewer constructs the download URL as: `PS_DOWNLOAD_API + <docId> + "/download"`.

Related configuration
- `REGISTER_PDF_API_KEY` (server): API key expected in `Authorization` header for this endpoint.
- `ARCHIVE_API_BASE_URL` and `CREATE_DOCUMENT_API_URL` (server): Where the PDF is persisted.
- `PS_DOWNLOAD_API` (client): Used by the viewer to fetch the registered PDF by `docId`.
- `USER_POLLING_FREQUENCY` (client): Controls how often the SPA checks for the registered PDF.
- `REGISTER_PDF_MAX_CONCURRENCY`, `REGISTER_PDF_QUEUE_MAX_SIZE`, `REGISTER_PDF_QUEUE_WAIT_MS`: Throughput and backpressure tuning.
- `REGISTER_PDF_UPSTREAM_TIMEOUT_MS`, `REGISTER_PDF_UPSTREAM_RETRIES`: Archive upstream reliability tuning.
- `DEPENDENCY_CB_FAILURE_THRESHOLD`, `DEPENDENCY_CB_COOLDOWN_MS`: Fail-fast protection during dependency outages.

Behavior flags and defaults
- `ENABLE_PERSONAL_CODE_VALIDATION`: When `true`, validates Latvian personal code format on specific routes. Default: `false`. API is not relevant for cloud instance.
- `DEFAULT_DOCUMENT_JSON`: JSON payload sent when creating a new archive document. Includes `objectName`, `contentType`, `documentType`, `documentFilename`.

Authentication and security
- `KEYCLOAK_CONFIG`: Backend Keycloak adapter configuration. Important fields:
  - `realm`: Keycloak realm, default `"padsign"`.
  - `auth-server-url`: Base URL to Keycloak, default `"https://padsign.trustlynx.com/auth"`.
  - `resource`: Backend client (confidential) ID, default `"padsign-backend"`.
  - `credentials.secret`: Client secret for the confidential backend client.
- `REGISTER_PDF_API_KEY`: Static API key protecting the `/api/registerPDF` endpoint (sent as `Authorization: Bearer <key>` by 3rd-party uploaders). `bootstrap.sh` replaces the shipped value with a random one; see *Reading the API key* above.

---

