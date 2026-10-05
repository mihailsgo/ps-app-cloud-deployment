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
`DEMO_COMPANY_ROLE`. An in-network DMSS address
([below](#how-ps-server-reaches-the-dmss-services)) names no host and is left
as it is. `bootstrap.sh` also writes the backend client secret and
generates `REGISTER_PDF_API_KEY` and `SESSION_SECRET`.

Defaults below are the values in the shipped file. `<host>` is your
hostname.

## Service endpoints

| Key | Default | Meaning |
|-----|---------|---------|
| `PORT` | `3001` | Port ps-server listens on inside the Docker network. nginx proxies `/api/` to it. |
| `ARCHIVE_API_BASE_URL` | `"http://dmss-archive-services:8090/api/"` | Archive service base URL. |
| `CREATE_DOCUMENT_API_URL` | `"http://dmss-archive-services:8090/api/document/create"` | Archive endpoint that creates a document. |
| `DOCUMENT_DOWNLOAD_API_URL` | `"http://dmss-archive-services:8090/api/document/"` | Archive endpoint to download a document by ID. |
| `VISUAL_SIGNATURE_API_TEMPLATE` | `"http://dmss-container-and-signature-services:8092/api/signing/visual/pdf/{docid}/sign"` | Visual-signature call. ps-server replaces `{docid}`. |
| `FORM_FILL_API_URL` | `"http://dmss-container-and-signature-services:8092/api/forms/fill/template/application"` | Template form fill (`+ <lang>`). Not used in the standard flow. |
| `ARCHIVE_PUBLIC_BASE_URL` | `"https://<host>/archive/api/"` | Optional. The archive address a webhook receiver can reach: the `archiveUrl` field of webhook payloads ([11](11-document-routing-and-receive-back.md)) uses it, and nothing else does. Left out, the payload carries `ARCHIVE_API_BASE_URL`. Needs the ps-server image named by the `dmss-internal-urls` capability in [`release/capabilities.json`](../release/capabilities.json); an older one ignores it. |
| `DEFAULT_DOCUMENT_JSON` | `{ objectName: "template", contentType: "application/pdf", documentType: "DMSSDoc", documentFilename: "template.pdf" }` | Metadata sent when ps-server creates an archive document. |

### How ps-server reaches the DMSS services

The five addresses above can take two forms, and either works. The code
only joins them with a path, and each key can differ from the others.

| Form | Example | ps-server's calls |
|---|---|---|
| In-network (shipped) | `http://dmss-archive-services:8090/api/` | Go straight to the service by its Docker service name. nginx is not involved, so its `/archive/api/` and `/container/api/` routes can be closed ([6.1](06-01-route-protection.md#closing-the-routes-after-switching-ps-server-to-in-network-addresses)). |
| Public | `https://<host>/archive/api/` | Leave the stack, enter again through nginx's network alias and take a TLS hop each way. The two nginx routes must stay reachable from the Docker network. |

A host installed with a release that shipped the public form keeps it. A
plain `upgrade.sh` never changes these keys; you decide when to switch. From
the deployment directory:

```bash
# See exactly what would change (writes nothing)
./installation-scripts/upgrade.sh --use-internal-dmss-urls --plan-only

# Switch: rewrites the five keys, recreates ps-server
./installation-scripts/upgrade.sh --use-internal-dmss-urls

# Switch back (needs the two nginx routes open to ps-server)
./installation-scripts/upgrade.sh --use-public-dmss-urls
```

What `--use-internal-dmss-urls` does:

- It rewrites each of the five keys that holds `https://<host>/archive/api/...`
  or `https://<host>/container/api/...` to the in-network address with the same
  path. A key that holds anything else (an address of your own, an
  expression) is left as it is, and a key already in-network is not touched,
  so a second run changes nothing.
- When `config.js` has no `ARCHIVE_PUBLIC_BASE_URL`, it adds one with the
  public archive address you had, so webhook payloads keep the `archiveUrl`
  receivers can open. It adds two comment lines above the key; `--use-public-dmss-urls`
  removes exactly that key again, and a key you wrote yourself is never
  removed.
- It refuses to run unless the ps-server image you run is new enough to read
  `ARCHIVE_PUBLIC_BASE_URL` (the `dmss-internal-urls` capability). Until a
  ps-server release has it, `upgrade.sh` says so and exits without changing
  anything; `--use-public-dmss-urls` has no such requirement.
- It takes a rollback snapshot first like any upgrade, and recreates the
  ps-server container so it reads the new `config.js`
  ([9.8](09-08-rollback.md)).

`--use-public-dmss-urls` writes the public form back with the host from
`ARCHIVE_PUBLIC_BASE_URL`, or from `nginx/nginx.conf` when there is none.
A customized (overlay) host is not edited in place: make the same change in
a new overlay version ([9.11](09-11-start-at-boot-backups-and-customized-hosts.md)).

**What protects these calls.** Neither DMSS service checks a credential, so
ps-server sends none to the archive. The Docker network is the protection:
the DMSS ports are published on `127.0.0.1` only, and any container that
shares the network can read and write documents. Keep it that way, and do
not publish the DMSS ports on a public interface. The PadSign application
repository documents the same design in `documentation/dmss-internal-urls.md`.

`validate-config.sh` accepts both forms, flags a key that names the wrong
service or a public address on another host, and warns about a mix of the two
or an enabled webhook without a usable public archive address
([5.2](05-02-validating-configuration.md)).

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

## Signing audit log

`AUDIT_LOG` controls the signing audit log, one JSON line per signing event
([9.13 Signing activity log](09-13-signing-activity-log.md)). Every event goes to
ps-server's standard output; the block decides whether it is also written to files.

```js
AUDIT_LOG: { enabled: true, dir: "/signed-output/.padsign-audit", retentionMonths: 12 },
```

| Key | Default | Meaning |
|-----|---------|---------|
| `AUDIT_LOG.enabled` | `true` | Append events to `<dir>/audit-YYYY-MM.jsonl` (one file per UTC month). `false` writes to standard output only. |
| `AUDIT_LOG.dir` | `"/signed-output/.padsign-audit"` | Directory for the files, inside ps-server's container. This default is `signed-output/.padsign-audit/` on the host. |
| `AUDIT_LOG.retentionMonths` | `12` | Files older than this many months are deleted at startup and daily. `0` keeps everything. |

The log records signers' e-mail addresses, so set `retentionMonths` to your retention policy.
An older ps-server ignores the block. `upgrade.sh` adds it to a `config.js` that lacks it
([9.6](09-06-what-upgrade-does.md)).

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
