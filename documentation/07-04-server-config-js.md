# 7.4 Server: config/config.js

`config/config.js` configures ps-server. It is a Node module
(`module.exports = { ... }`), so it can contain comments, but it must stay
valid JavaScript. ps-server reads it once at startup. Apply every change with:

```bash
docker compose restart ps-server
```

The file holds credentials. It is kept at mode `640` with the ps-server
image's group ([6. Production hardening](06-production-hardening.md#5-files-and-permissions)).
To read it, work as root or as a member of that group.

`configure-host.sh` rewrites the hostname in every `https://<host>/auth`,
`/archive/api/` and `/container/api/` URL and in `ALLOWED_ORIGINS`, and sets
`DEMO_COMPANY_ROLE`. `bootstrap.sh` also writes the backend client secret and
generates `REGISTER_PDF_API_KEY` and `SESSION_SECRET`.

Defaults below are the values in the shipped file. `<host>` is your
hostname.

## Service endpoints

| Key | Default | Meaning |
|-----|---------|---------|
| `PORT` | `3001` | Port ps-server listens on inside the Docker network. nginx proxies `/api/` to it. |
| `ARCHIVE_API_BASE_URL` | `"https://<host>/archive/api/"` | Archive service base URL. |
| `CREATE_DOCUMENT_API_URL` | `"https://<host>/archive/api/document/create"` | Archive endpoint that creates a document. |
| `DOCUMENT_DOWNLOAD_API_URL` | `"https://<host>/archive/api/document/"` | Archive endpoint to download a document by ID. |
| `VISUAL_SIGNATURE_API_TEMPLATE` | `"https://<host>/container/api/signing/visual/pdf/{docid}/sign"` | Visual-signature call. ps-server replaces `{docid}`. |
| `FORM_FILL_API_URL` | `"https://<host>/container/api/forms/fill/template/application"` | Template form fill (`+ <lang>`). Not used in the standard flow. |
| `DEFAULT_DOCUMENT_JSON` | `{ objectName: "template", contentType: "application/pdf", documentType: "DMSSDoc", documentFilename: "template.pdf" }` | Metadata sent when ps-server creates an archive document. |

ps-server reaches these URLs through nginx, using the network alias that
maps `<host>` to nginx inside the Docker network.

## Authentication and CORS

| Key | Default | Meaning |
|-----|---------|---------|
| `KEYCLOAK_CONFIG` | see below | Keycloak adapter settings for the confidential backend client. |
| `ALLOWED_ORIGINS` | `['https://<host>:5173', 'https://<host>']` | Origins allowed by CORS. The portal origin `https://<host>` is enough in production. The `:5173` entry is a development origin you can remove. |
| `REGISTER_PDF_API_KEY` | public value, replaced by `bootstrap.sh` | Shared API key for the integration endpoints ([7.5](07-05-register-pdf-api.md)). |
| `REGISTER_PDF_API_KEYS` | not set | Optional per-company keys, a list of `{ company: "Acme", key: "tlx_pdf_..." }`. They are checked before `REGISTER_PDF_API_KEY`. A caller using one is scoped to that company on the receive-back endpoints ([7.5](07-05-register-pdf-api.md#per-company-keys)). |
| `SESSION_SECRET` | public value, replaced by `bootstrap.sh` | Signs ps-server's session cookie. Changing it only ends existing sessions. The `SESSION_SECRET` environment variable overrides it if set. |
| `PRIVILEGED_API_ROLES` | `["padsign-admin", "psapp-integration"]` | Realm roles allowed to run the privileged internal cleanup operations. |
| `API_PROTECT_LOGS_ENABLED` | `false` | Logs every bearer-token validation, including the raw token. Keep it `false`. `validate-config.sh` fails if it is `true`. |
| `ALLOW_INSECURE_TLS` | `false` | Disables TLS certificate verification for ps-server's outgoing calls. Only for troubleshooting a test host with a self-signed certificate. Never enable it in production. |

`KEYCLOAK_CONFIG`:

```js
KEYCLOAK_CONFIG: {
  realm: "padsign",
  "auth-server-url": "https://padsign.example.com/auth",
  resource: "padsign-backend",
  credentials: { secret: "<padsign-backend client secret>" },
  "bearer-only": true
},
```

- `resource` is the backend client and `secret` is its client secret. The
  shipped file has `CHANGE_ME` here, and `bootstrap.sh` writes the real
  value ([8.1](08-01-automated-setup.md)).
- The key must be named `KEYCLOAK_CONFIG`. A block with another name is
  ignored, and ps-server then rejects every portal call.

## E-sealing (`/api/stamp`)

| Key | Default | Meaning |
|-----|---------|---------|
| `STAMP_MODE` | not set, meaning `"external"` | Which e-sealer `/api/stamp` calls: `"external"` (also used when the key is missing or unknown) or `"local"`. Switch it with `toggle-features.sh` ([10.5](10-05-switching-modes.md)). |
| `STAMP_API_URL` | a demo endpoint | External mode: the cloud e-seal endpoint for your account. |
| `STAMP_API_KEY`, `STAMP_COMPANY_ID`, `STAMP_COMPANY_SECRET` | `CHANGE_ME` | External mode: sent as the `X-API-KEY`, `X-COMPANY-ID` and `X-COMPANY-SECRET` headers. Your e-sealing provider issues them. |
| `STAMP_LOCAL` | not set | Local mode, written by `--enable-local-eseal`: `url` (container-signature's `/api/eseal/document/profile/<profile>` endpoint), `username` / `password` (container-signature's Basic auth, which must match its `SPRING_SECURITY_USER_*`), `timeoutMs` (default `30000`). See [10. Local e-sealing](10-local-e-sealing.md). |

ps-server ignores the block for the mode that is not selected.
`RUN_STAMPING_REQUEST` in `constants.json` decides whether the portal calls
`/api/stamp` at all ([7.3](07-03-client-constants-json.md#workflow)).

If you raise `STAMP_LOCAL.timeoutMs` or the `REGISTER_PDF_*` timeouts, also
raise `proxy_read_timeout` in the `/api/` location of `nginx/nginx.conf`
(shipped as `180s`) to about three times the timeout plus a margin.
Otherwise nginx answers `504` before ps-server does.

## Load and resilience

| Key | Default | Meaning |
|-----|---------|---------|
| `REGISTER_PDF_MAX_CONCURRENCY` | `4` | `/api/registerPDF` uploads processed at once. |
| `REGISTER_PDF_QUEUE_MAX_SIZE` | `100` | Uploads that may wait in the queue. Beyond that the call gets `429`. |
| `REGISTER_PDF_QUEUE_WAIT_MS` | `30000` | Longest wait in the queue before `503`. |
| `REGISTER_PDF_UPSTREAM_TIMEOUT_MS` | `15000` | Timeout per archive upload attempt. |
| `REGISTER_PDF_UPSTREAM_RETRIES` | `3` | Archive upload attempts. |
| `DEPENDENCY_CB_FAILURE_THRESHOLD` | `5` | Consecutive archive failures that open the circuit breaker. |
| `DEPENDENCY_CB_COOLDOWN_MS` | `30000` | How long the breaker stays open (calls fail fast with `503`). |
| `DOC_OPERATION_LOCK_TTL_MS` | `45000` | Lock that stops the same document from being signed twice in parallel. |
| `IDEMPOTENCY_TTL_MS` | `600000` | How long a repeated request is recognised as a duplicate. |

## In-memory state

Registered documents waiting for a signer are held in ps-server's memory,
so a ps-server restart clears them.

| Key | Default | Meaning |
|-----|---------|---------|
| `USER_ENTRY_TTL_MS` | `600000` (10 min) | How long an idle registration is kept. |
| `USER_STATE_CLEANUP_MS` | `60000` | Cleanup interval. |
| `PAD_ARRIVAL_TIMEOUT_MS` | `600000` (10 min) | Hard limit after which an unsigned document leaves the tablet, whatever the activity. The next `/api/latestUser` poll returns empty. |

## Files and directories

| Key | Default | Meaning |
|-----|---------|---------|
| `TEMP_DIRECTORY` | `"./tmp/"` | Temporary PDFs from form fill. |
| `DOCUMENT_OUTPUT_DIRECTORY` | `"/PSDOCS/out/"` | Target of `/api/save`. Not used in the standard flow. |
| `READONLY_PDF_DIRECTORY` | `"/PSDOCS/in/"` | Read-only PDF lookup. Not used in the standard flow. |

Signed documents written by document routing go to `/signed-output`
(the host's `./signed-output/`), not to these directories.

## Demo mode and validation

| Key | Default | Meaning |
|-----|---------|---------|
| `DEMO_COMPANY_ROLE` | `CHANGE_ME`, set by `--company-role` | Company used for a demo upload when the user has no company realm role. |
| `DEMO_MAX_FILE_SIZE_MB` | `10` | Largest PDF `/api/demo/upload` accepts (`413` above it). |
| `ENABLE_PERSONAL_CODE_VALIDATION` | `false` | When `true`, personal codes must match the Latvian format `DDMMYY-NNNNN`. |

Demo mode itself is `DEMO_MODE` in `constants.json`.

## Document routing (after signing)

`DOCUMENT_ROUTING` decides what happens to a document once it is signed:
save it to the filesystem, POST it to a webhook, or both.

```js
DOCUMENT_ROUTING: {
  enabled: true,          // master switch
  skipDemo: true,         // no routing for demo-mode documents
  strategies: [ /* { type: "filesystem" | "webhook", enabled, ... } */ ]
},
```

The shipped `config/config.js` has routing on, with the `filesystem`
strategy enabled (`basePath: "/signed-output"`) and two example `webhook`
strategies disabled. Turn routing on or off with `toggle-features.sh`
([9.4](09-04-toggling-features.md)). Disabling only flips `enabled`, so the
strategy settings are kept. If an older `config.js` has no
`DOCUMENT_ROUTING` block, `upgrade.sh` and `configure-host.sh` add one with
routing disabled and a different `pathTemplate` (no `{email}` folder; see
[11](11-document-routing-and-receive-back.md#how-it-is-configured)). The
`--enable-routing` flag of `bootstrap.sh` and the wizard's **Document routing**
toggle only switch routing on; leaving them out never turns it off.

Strategy options, `pathTemplate` tokens, per-company strategies, the
receive-back buffer (`bufferOnly`, `bufferPath`) and the `webhook` events are
described in [11. Document routing and receive-back](11-document-routing-and-receive-back.md).

## Customer data lookup (Virtual Printer)

When `/api/registerPDF` receives `source=virtual-printer`, ps-server reads
page 1 of the PDF for two barcode-backed numbers:

- a 5-digit `customerId`. ps-server calls `GET {CUSTOMER_DATA_API_URL}{customerId}`
  with the configured key header and uses the resolved name as the signer
  name in the visual signature. Individuals get `first name + last name`,
  organisations only the last name.
- a 3 to 7 digit `documentNumber`, available as `{documentNumber}` in the
  filesystem routing `pathTemplate`.

| Key | Default | Meaning |
|-----|---------|---------|
| `CUSTOMER_DATA_API_URL` | `""` | Customer data service base URL. |
| `CUSTOMER_DATA_API_KEY` | `""` | API key. The lookup is off while this is empty. |
| `CUSTOMER_DATA_API_KEY_HEADER` | `"api_key"` | Header the key is sent in. |
| `CUSTOMER_DATA_CACHE_TTL_MS` | `3600000` | Cache lifetime for lookups. |
| `CUSTOMER_DATA_TIMEOUT_MS` | `10000` | Timeout per request. |
| `CUSTOMER_DATA_RETRIES` | `2` | Retries on a timeout or `5xx`. |

The lookup never blocks signing. If the barcode is missing, the customer is
not found or the service is down, signing continues with the default signer
name (email, or name and surname), and the routed file is named
`unknown_<date>.pdf`.
