# 11. Document routing and receive-back

What ps-server does with a document once it is signed. **Document
routing** runs post-signing actions you configure: save the signed PDF into
a folder structure on the host, and/or send it (or just its metadata) to a
webhook. **Receive-back** builds on the filesystem action: the Padsign
Manager on the desktop that printed a document collects the signed PDF and
saves it locally.

The signed document is always stored in the PadSign archive (DMSS),
whether routing is on or not. Routing adds copies and notifications.

## How it is configured

Everything is in the `DOCUMENT_ROUTING` block of `config/config.js`
([7.4 Server config.js](07-04-server-config-js.md)). ps-server reads the file
only when it starts, so after an edit:

```bash
cd /opt/padsign
docker compose restart ps-server
docker compose logs --tail 30 ps-server     # expect "PadSign Server listening on port 3001"
```

`docker compose up -d` alone does not restart ps-server for a change to
`config.js`.

The shipped `config/config.js` has routing **on**, with the `filesystem`
strategy writing to `/signed-output` in the layout receive-back uses, and
both webhook examples off. A `config.js` without any `DOCUMENT_ROUTING`
block gets one from `upgrade.sh` or `configure-host.sh` with everything off.
That added block uses a different `pathTemplate`,
`{company}/{date:YYYY-MM}/{company}_{clientName}_{date:YYYY-MM-DD_HHmm}.pdf`:
it has no `{email}` folder and the time stops at the minute, so two
documents for the same client in one minute overwrite each other. If you
want the layout described on this page, replace it with the shipped
template shown below.
Turn the master switch on or off with
[9.4 Toggling features](09-04-toggling-features.md):

```bash
./installation-scripts/toggle-features.sh --enable-routing    # master switch + filesystem strategy on
./installation-scripts/toggle-features.sh --disable-routing   # master switch off; strategy settings kept
```

`bootstrap.sh --enable-routing` does the same at install time; with the
shipped `config.js` it changes nothing, because routing is already on.
Leaving the flag out does not turn routing off. Webhooks,
per-company strategies and path templates are configured by editing
`config.js`.

## The DOCUMENT_ROUTING block

```js
DOCUMENT_ROUTING: {
  enabled: true,        // master switch; false: no strategy runs
  skipDemo: true,       // demo-mode documents are never routed (only an explicit false changes this)
  strategies: [
    {
      type: "filesystem",
      enabled: true,
      basePath: "/signed-output",
      pathTemplate: "{company}/{email}/{date:YYYY-MM}/{documentNumber}_{date:YYYY.MM.DD_HH:mm:ss}.pdf",
      createDirectories: true
    },
    {
      type: "webhook",
      enabled: false,
      url: "https://example.com/api/signing-status",
      method: "POST",
      headers: {},
      includeFile: false,
      timeoutMs: 10000,
      retries: 3,
      retryBaseDelayMs: 1000
    }
  ]
}
```

- Strategies run one after the other, in the order listed. Each has its own
  `enabled` flag, and one failing never stops the next.
- Only `filesystem` and `webhook` exist. Another `type` is logged and
  skipped.
- Any strategy can carry `company: "<name>"`: it then runs only for
  documents of that company (compared trimmed and case-insensitively). A
  strategy without `company` runs for every company. One deployment can so
  deliver to a separate webhook per customer.

## When routing runs

- **With sealing on** (the default): right after the sealed PDF is stored
  in the archive.
- **With sealing off** (`RUN_STAMPING_REQUEST: false` in
  `config/constants.json`): right after the visual signature, when the
  tablet reports completion.
- **When signing fails** (including a seal that was skipped because the
  sealing service was unavailable): only the enabled webhook strategies run,
  with a `document.signing_error` event. Filesystem strategies never run on
  errors.

Routing runs in the background: it never delays or fails the signing
itself. It needs the document's session in ps-server's memory. A document
whose session is gone (ps-server restarted, or the pad timeout
`PAD_ARRIVAL_TIMEOUT_MS` / idle timeout `USER_ENTRY_TTL_MS` passed) is
not routed; it is still in the archive.

## Filesystem strategy

Writes the signed PDF to `basePath` + `pathTemplate`. The file is a
durable archive: ps-server never deletes it.

| Field | Default | Meaning |
|---|---|---|
| `basePath` | required | Root directory inside the ps-server container |
| `pathTemplate` | `{docid}-sealed.pdf` | Sub-directories and file name below `basePath` |
| `createDirectories` | `true` | Create missing directories |
| `bufferOnly` | `false` | `true`: no durable archive; the written file is only the receive-back copy and is deleted when a Manager collects it |
| `bufferPath` | `<basePath>/.padsign-buffer` | Where the receive-back copy and its `.meta.json` file go |
| `company` | none | Run only for this company |

`/signed-output` in the container is `/opt/padsign/signed-output/` on the
host (the `./signed-output:/signed-output` volume of ps-server in
`docker-compose.yml`). The directory is mode 750 and owned by the user the
ps-server image runs as; `upgrade.sh` creates and re-owns it, and
`validate-config.sh` checks it. Never make it world-writable: it holds real
signed documents.

A file that already exists at the resolved path is overwritten. Include
`{docid}`, or a time down to the second, if names could repeat.

### Path template tokens

| Token | Value | Example |
|---|---|---|
| `{docid}` | archive document id | `a1b2c3d4-e5f6-...` |
| `{company}` | company of the signing session (Keycloak role, or `company` of the upload) | `Acme` |
| `{email}` | email of the signing session | `user@example.com` |
| `{clientName}` | `clientName` given at upload | `John_Doe` |
| `{signerName}` | customer name from the customer-data lookup (Virtual Printer flow) | `Anna_Bērziņa` |
| `{documentNumber}` | document number read from the PDF's barcode (Virtual Printer flow) | `100542` |
| `{customerId}` | customer id read from the PDF's barcode (Virtual Printer flow) | `4711` |
| `{lng}` | session language | `LV` |
| `{date:FORMAT}` | current time in **UTC**; `YYYY`, `YY`, `MM`, `DD`, `HH`, `mm`, `ss`. `{date}` alone is `YYYY-MM-DD` | `{date:YYYY-MM}` → `2026-04` |

A token without a value becomes `unknown`. In every value, the characters
`<>:"/\|?*`, control characters and runs of whitespace become `_`, so
`My Company` gives `My_Company`, `HH:mm:ss` gives `14_38_36`, and no value
can add a directory level. The shipped template gives:

```text
Acme/user@example.com/2026-04/100542_2026.04.22_14_38_36.pdf
```

Signers sharing `company=Acme` get a folder per email under `Acme/`; a
separate company such as `Acme-Branch` gets its own top-level folder.
`{signerName}`, `{documentNumber}` and `{customerId}` need the
customer-data lookup of the Virtual Printer flow (`CUSTOMER_DATA_*` in
`config.js`, [7.4](07-04-server-config-js.md)).

## Webhook strategy

Sends a JSON `POST` to your endpoint for each signed document, and for
each signing error.

| Field | Default | Meaning |
|---|---|---|
| `url` | required | Endpoint |
| `method` | `POST` | HTTP method |
| `headers` | `{}` | Extra headers, for example `{ "Authorization": "Bearer <token>" }` |
| `includeFile` | `false` | Add the signed PDF, base64-encoded (success events only) |
| `timeoutMs` | `10000` | Timeout per attempt |
| `retries` | `3` | Total attempts, including the first |
| `retryBaseDelayMs` | `1000` | Waits `retryBaseDelayMs × attempt` between attempts |
| `company` | none | Run only for this company |

Authentication is by static headers only (a bearer token or an API-key
header). Retries happen on connection errors, timeouts, `429` and any `5xx`;
other `4xx` answers fail at once.

Success event:

```json
{
  "event": "document.signed",
  "timestamp": "2026-04-14T10:30:00.000Z",
  "document": {
    "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "filename": "a1b2c3d4-e5f6-7890-abcd-ef1234567890-sealed.pdf",
    "sizeBytes": 245760
  },
  "signer": { "email": "user@example.com", "company": "Acme", "clientName": "John Doe", "language": "LV" },
  "archiveUrl": "https://padsign.example.com/archive/api/document/a1b2c3d4-.../download"
}
```

With `includeFile: true` it also carries
`"file": { "content": "<base64 PDF>", "contentType": "application/pdf", "filename": "<docid>-sealed.pdf" }`.
`archiveUrl` may require a Keycloak token when the download route is
protected ([6.1 Route protection](06-01-route-protection.md)). It is built
from `ARCHIVE_PUBLIC_BASE_URL` in `config/config.js` when that is set, and
otherwise from `ARCHIVE_API_BASE_URL`: with ps-server on the in-network
addresses ([7.4](07-04-server-config-js.md#how-ps-server-reaches-the-dmss-services))
set `ARCHIVE_PUBLIC_BASE_URL` to `https://<host>/archive/api/`, or the
receiver is given an address inside the Docker network that it cannot open.
An older ps-server ignores the key; `validate-config.sh` warns when that
would affect an enabled webhook.

Error event: the same `document` (id only), `signer` and `archiveUrl`,
with `"event": "document.signing_error"` and `"error": "<what failed>"`.

A delivery that still fails after the last attempt is logged as
`[documentRouting:webhook] PERMANENT FAILURE after retries` with the URL,
company, docid and final status. ps-server sends no alert itself;
`monitor-status.sh --alert` turns that line into the
`routing_webhook_permanent_failure` alert
([9.10](09-10-monitoring-and-alerting.md)).

Example: deliver the signed file to one customer's system only.

```js
{
  type: "webhook",
  enabled: true,
  company: "Acme-DirectAPI",
  url: "https://customer.example.com/padsign/signed",
  method: "POST",
  includeFile: true,
  headers: { "Authorization": "Bearer <customer token>" },
  timeoutMs: 10000,
  retries: 5,
  retryBaseDelayMs: 1000
}
```

## Receive-back to the Padsign Manager

The Padsign Manager (Virtual Printer) on a Windows desktop prints a
document to PadSign, where it is signed on a tablet. Receive-back returns
the signed PDF to that desktop. Desktops usually sit behind NAT, so the
Manager **polls** ps-server; nothing is pushed to it:

1. The Manager uploads the printed PDF (`POST /api/registerPDF`) with its
   `email` and `company`.
2. The document is signed on the tablet.
3. The filesystem strategy writes the archive file and a receive-back copy
   under `<basePath>/.padsign-buffer/` with a `.meta.json` file.
4. The Manager asks for its pending documents
   (`GET /api/signedPdf/pending?email=&company=`), downloads each
   (`GET /api/signedPdf?docid=`), saves it into its **Signed Output Folder**
   under the name ps-server gives, and acknowledges it
   (`POST /api/signedPdf/ack`).
5. The acknowledgement deletes the receive-back copy. The archive file in
   `signed-output/{company}/{email}/...` stays.

A pending document never expires: a desktop that is offline for days gets
it when it comes back, and ps-server rebuilds the pending list from the
`.meta.json` files when it restarts.

`.padsign-buffer/` sits inside `basePath`. If you expose signed documents
to users as a file share, share a sub-directory (for example
`signed-output/Acme/`) rather than `basePath` itself. Moving `bufferPath`
outside `basePath` also hides it, but ps-server rebuilds the pending list
only from below the `basePath` of each enabled filesystem strategy, so
entries pending there are not recovered after a restart.

### Requirements

- ps-server at or above the `receive-back` and `durable-routing-archive`
  minimums in `release/capabilities.json` (the current release is).
- Routing on, with an enabled `filesystem` strategy (the shipped
  configuration).
- **A per-company API key for each receive-back company** (next section).
- Padsign Manager 1.2.0 or later on each desktop. Contact TrustLynx support
  for the installer.

### Per-company API keys

ps-server serves a signed PDF, and accepts its acknowledgement, only from
a caller that proves it owns the document. The Padsign Manager sends only
the `docid` when it downloads and acknowledges. Under the single shared
`REGISTER_PDF_API_KEY` that proof is missing, so those calls return `404`
and documents stay pending (nothing is lost). A **per-company key** proves
the company by itself, with no change on the desktop.

1. Generate a new random key for each company, never reusing the shared key
   or another company's key:

   ```bash
   printf 'tlx_pdf_%s\n' "$(openssl rand -hex 32)"
   ```

2. Add it to `config/config.js`. `company` must match, ignoring case, the
   **Company** that company's Manager installations send:

   ```js
   REGISTER_PDF_API_KEYS: [
     { company: "Acme", key: "tlx_pdf_..." },
     { company: "Acme-Branch", key: "tlx_pdf_..." }
   ],
   ```

3. `docker compose restart ps-server`.
4. Put the new key into that company's Manager installations
   (**Authentication Header Value**, next section).

The shared `REGISTER_PDF_API_KEY` keeps working for uploads and for
companies not moved yet. With a per-company key, `pending` is always
answered for the key's company; asking for another company returns `403`.
A wrong owner answers `404`, the same as a document that does not exist.

Hand keys over like any other credential, never in a ticket or chat. To
read the shared key, see [7.5 registerPDF API](07-05-register-pdf-api.md).

### Setting up the Padsign Manager

In the Manager's **Setup** tab, on each desktop:

| Field | Value |
|---|---|
| API URL | `https://padsign.example.com/api/registerPDF` |
| Authentication Header Name / Value | `Authorization` / `Bearer <the company's key>` |
| Email | the email of the Keycloak user signed in on the tablet that shows this desk's documents; with the shipped template also the folder under the company |
| Company | the company name: the Keycloak realm role that tablet user has, and the key's `company` |
| Signed Output Folder | where signed PDFs are saved, for example `C:\PadSign\SignedDocs` |

Save, then start the listener. The Manager polls every 5 seconds for 30
minutes after each upload, and checks for anything pending when it starts.

The file name comes from ps-server. On the wire it is folded to ASCII
(`Anna_Bērziņa_100542.pdf` is sent as `Anna_Berzina_100542.pdf`); the file
on the server keeps its real name.

## Verifying it works

Watch ps-server's log while you sign a (non-demo) document:

```bash
docker compose logs -f ps-server | grep -E 'documentRouting|signedPdfBuffer'
```

Expected lines: `[documentRouting:filesystem] saved`, for webhooks
`[documentRouting:webhook] delivered`, and after the Manager collects the
document `[signedPdfBuffer] acknowledged + removed from buffer`. At start,
ps-server logs `[signedPdfBuffer] index rebuilt from disk` with the number
of pending entries.

The receive-back endpoints from the command line:

```bash
BASE=https://padsign.example.com
 read -rs KEY                                           # a per-company key, not echoed
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/api/signedPdf/pending?email=a@example.com&company=Acme"   # 401: key required
curl -s -H "Authorization: Bearer $KEY" "$BASE/api/signedPdf/pending?email=nobody@example.com&company=Acme"  # [] or the pending list
curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"docid":"none"}' "$BASE/api/signedPdf/ack"                                              # {"acknowledged":true,"removed":false}
unset KEY
```

Then a real round trip: print from the line-of-business application, sign
on the tablet, and check that the PDF appears in the Signed Output Folder
and that `signed-output/<company>/<email>/...` holds the archive copy.

## Operating it

- **Storage grows.** Nothing deletes the archive files in `signed-output/`.
  Plan retention and disk space, and include the directory in backups
  ([9.11](09-11-start-at-boot-backups-and-customized-hosts.md#backups)).
- **Uncollected documents.** `monitor-status.sh --alert` raises
  `buffer_growth` and `buffer_stale` when documents wait too long, and
  `routing_failure` / `routing_webhook_permanent_failure` for failed
  actions ([9.10](09-10-monitoring-and-alerting.md)). ps-server sends no
  email or alert itself.
- **Turning it off.** `toggle-features.sh --disable-routing` stops new
  copies and webhooks. Documents already pending stay on disk until a
  Manager collects them or you remove them.
- **Session timeouts.** `USER_ENTRY_TTL_MS` (idle) and
  `PAD_ARRIVAL_TIMEOUT_MS` (hard limit after the document reaches the pad)
  decide how long a document can wait for signing and still be routed
  ([7.4](07-04-server-config-js.md)). They apply to every session on the
  deployment.
