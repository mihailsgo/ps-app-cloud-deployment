# 7.5 The /api/registerPDF integration API

`POST /api/registerPDF` is how a third-party system or the Padsign Virtual
Printer hands a PDF to PadSign for signing. ps-server stores the PDF in the
archive and queues it for the signer. The portal then shows it on the
tablet of the user whose `email` and `company` match. The call is
authenticated with an API key, not with a Keycloak token.

## Reading the API key

The `REGISTER_PDF_API_KEY` shipped in this public repository is known to
everyone, so `bootstrap.sh` replaces it with a random key (`tlx_pdf_` plus 64
hex characters) and never prints it, neither to the terminal nor to the
wizard's run log. Read it from inside ps-server when you configure a client
(the Virtual Printer / Padsign Manager, a third-party uploader). It then
appears on your terminal only:

```bash
cd /opt/padsign
docker compose exec -T ps-server node -p 'require("/usr/src/app/config.js").REGISTER_PDF_API_KEY' </dev/null
```

This works for anyone allowed to run `docker compose` on the host, even
though `config/config.js` itself is mode `640`. Per-company keys are in
`.REGISTER_PDF_API_KEYS`. If ps-server is down, read the file as root or as a
member of its group:

```bash
sudo python3 -c 'import re; print(re.search(r"REGISTER_PDF_API_KEY\s*:\s*[\"\x27]([^\"\x27]+)", open("config/config.js").read()).group(1))'
```

Hand the key over like any other credential, never in a ticket or chat.

If `validate-config.sh` warns that the key still equals the shipped one,
generate a new one, then give it to every client:

```bash
./installation-scripts/configure-host.sh --host padsign.example.com --generate-secrets
docker compose restart ps-server
```

## Per-company keys

Besides the shared `REGISTER_PDF_API_KEY`, `config/config.js` can list one key
per company:

```js
REGISTER_PDF_API_KEYS: [
  { company: "Acme", key: "tlx_pdf_<64 random hex characters>" }
],
```

ps-server checks these entries first, then the shared key. On every
endpoint, both kinds of key authenticate the caller in the same way. The
difference is on the receive-back endpoints (`/api/signedPdf*`): a
per-company key limits the caller to that company's documents. Under the
shared key, the caller must send the matching `email` and `company`. `company`
must match, ignoring case, the company value that company's clients send.
Generate a separate random key for each company (for example
`echo "tlx_pdf_$(openssl rand -hex 32)"`) and restart ps-server after adding
it. Receive-back is described in
[11. Document routing and receive-back](11-document-routing-and-receive-back.md).

## Request

- **Method:** `POST`
- **URL:** `https://padsign.example.com/api/registerPDF`
- **Auth:** `Authorization: Bearer <REGISTER_PDF_API_KEY>`
- **Content-Type:** `multipart/form-data`
- **Fields:**
  - `file`: the PDF (`application/pdf`, at most 10 MB)
  - `email`: the signer's or session's email identifier
  - `company`: the company. It must match a Keycloak realm role of the portal
    user whose tablet should show the document.
  - `clientName` (optional, alias `clientname`): display name shown in the
    portal
  - `source` (optional): `virtual-printer` turns on the customer-data lookup
    ([7.4](07-04-server-config-js.md#customer-data-lookup-virtual-printer))

```bash
curl -X POST "https://padsign.example.com/api/registerPDF" \
  -H "Authorization: Bearer ${REGISTER_PDF_API_KEY}" \
  -F "file=@/path/to/file.pdf;type=application/pdf" \
  -F "email=user@example.com" \
  -F "company=Acme" \
  -F "clientName=John Doe"
```

## Behaviour

1. ps-server uploads the PDF to the archive (`CREATE_DOCUMENT_API_URL`) and
   keeps `{ email, company, document }` in memory.
2. The portal, signed in as a user with the `company` role, polls
   `/api/latestUser` with its Keycloak token and shows the document.
3. The viewer downloads it from `PS_DOWNLOAD_API + <docId> + "/download"`.

Registrations live in memory only. A ps-server restart clears documents that
were not yet signed, and unsigned documents leave the tablet after
`PAD_ARRIVAL_TIMEOUT_MS`.

## Responses

| Status | Body | Meaning |
|--------|------|---------|
| `201` | `{ "message": "PDF registered successfully", "docId": "<uuid>" }` | Registered. |
| `400` | `{ "error": "Please provide all required fields: file, email, company" }` | A field is missing. |
| `400` | `{ "error": "Only PDF files are allowed" }` | Not a PDF. |
| `401` | `{ "error": "Invalid API key" }` or `Authorization header required` | Wrong or missing key. |
| `429` | `REGISTER_PDF_QUEUE_FULL` | Too many uploads in progress: retry later. |
| `503` | `REGISTER_PDF_QUEUE_TIMEOUT`, `ARCHIVE_CIRCUIT_OPEN` | Queue wait exceeded, or the archive is failing and the circuit breaker is open. |
| `502` / `503` / `504` | with an `errorCode` | Archive upstream failure. |
| `500` | error | Unhandled server error. |

Retry `429` and `503` with a back-off. Throughput and retry behaviour are tuned
with the `REGISTER_PDF_*` and `DEPENDENCY_CB_*` keys
([7.4](07-04-server-config-js.md#load-and-resilience)).

## Related configuration

| Key | File | Role |
|-----|------|------|
| `REGISTER_PDF_API_KEY`, `REGISTER_PDF_API_KEYS` | `config.js` | The accepted keys. |
| `ARCHIVE_API_BASE_URL`, `CREATE_DOCUMENT_API_URL`, `DEFAULT_DOCUMENT_JSON` | `config.js` | Where and how the PDF is stored. |
| `PS_DOWNLOAD_API` | `constants.json` | Where the viewer fetches the document. |
| `USER_POLLING_FREQUENCY` | `constants.json` | How often the portal checks for a new document. |
