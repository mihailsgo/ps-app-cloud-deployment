# 13.5 What is the integration flow from a third-party system, and what comes back after signing?

1. **Send the document.** The third-party system calls
   `POST /api/registerPDF` (multipart upload with `file`, `email`,
   `company` and optionally `clientName`), authenticated with an API key in
   the `Authorization: Bearer` header. Success is `201` with the document id:
   `{ "message": "PDF registered successfully", "docId": "<uuid>" }`.
   Details and all responses: [7.5 registerPDF API](07-05-register-pdf-api.md).
   The older endpoints `/api/registerUser` and `/api/registerUserPDF` remain
   for existing integrations.
2. **Sign.** The user signed in on the tablet for that `email` and
   `company` sees the document, signs it, and it is sealed when sealing is
   on.
3. **Get the result.** With document routing on
   (`DOCUMENT_ROUTING.enabled: true` in `config/config.js`), ps-server runs
   the configured actions ([11. Document routing and receive-back](11-document-routing-and-receive-back.md)):
   - a **webhook** receives `document.signed` (document id, size, signer,
     archive download URL, and with `includeFile: true` the signed PDF) or
     `document.signing_error` (what failed), with retries;
   - a **filesystem** copy of the signed PDF is written under
     `signed-output/`;
   - the **Padsign Manager** collects the signed PDF back to the desktop
     that sent it (receive-back).

   A webhook can be scoped to one company, so each integrating customer
   gets its own endpoint and token.

The signed document is also always in the PadSign archive, available by
its document id.

The older client-side status callback (`PDF_SIGNING_STATUS_CALLBACK` in
`constants.json`) is deprecated. Use the server-side webhook instead.
