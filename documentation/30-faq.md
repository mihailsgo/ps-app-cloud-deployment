# 30. FAQ

## 30.1 How does the solution handle a large number of documents sent at the same time (or almost at the same time)?

- `/api/registerPDF` is protected with an internal in-memory queue and concurrency limits.
- Throughput and backpressure are controlled by:
  - `REGISTER_PDF_MAX_CONCURRENCY`
  - `REGISTER_PDF_QUEUE_MAX_SIZE`
  - `REGISTER_PDF_QUEUE_WAIT_MS`
  - `REGISTER_PDF_UPSTREAM_TIMEOUT_MS`
  - `REGISTER_PDF_UPSTREAM_RETRIES`
- When limits are reached, backend returns deterministic overload/timeout responses (for example `429` queue full, `503` queue timeout or circuit open), instead of unstable random behavior.

## 30.2 How are errors handled if `ps-server` is not available when `registerPDF` is called?

- If `ps-server` is unavailable, the caller will receive a gateway/network failure from the front proxy layer (for example upstream `5xx`).
- If `ps-server` is available but dependencies are unstable, register flow returns controlled errors (`502/503/504` with `errorCode`, `429`, `503` queue timeout/circuit-open).
- For completed signing workflows, optional callback can report failures with technical details in `status`, for example:
  - `status: "error: <technical details>"`

## 30.3 How are repeated or parallel document-processing scenarios handled (same document in multiple sessions, repeated signing attempts)?

- Backend has duplicate/parallel protection controls:
  - `DOC_OPERATION_LOCK_TTL_MS`
  - `IDEMPOTENCY_TTL_MS`
- Signing-related operations (`/api/visual-signature`, `/api/stamp`) use idempotency/lock behavior to reduce accidental duplicate processing.
- User-document registration state is in-memory and is cleaned by:
  - `/api/removeUser` (external integration flow, API key)
  - `/api/cleanupUser` (internal flow, Keycloak protected)
- Important behavior note: in-memory state is non-persistent; service restart clears current runtime registrations/locks.

## 30.4 What software is used on tablets, and what is available there?

- No special native tablet app is required.
- Tablet users access the web portal (`/portal`) in a browser.
- Available capabilities in the portal:
  - Keycloak login
  - document rendering (PDF)
  - visual signature placement
  - optional digital stamp stage (depends on `RUN_STAMPING_REQUEST`)
  - callback-enabled workflow completion reporting (if enabled)

## 30.5 What is the integration flow from a 3rd-party system, and what response is returned after signing?

- 3rd-party system sends documents to backend API-key-protected endpoints:
  - `/api/registerPDF` (multipart upload; primary production flow)
  - legacy-compatible endpoints `/api/registerUser` and `/api/registerUserPDF` may still exist for integration compatibility
- Success response for `/api/registerPDF` is `201` with JSON containing `docId`.
- Operator opens/signs document in portal.
- If document routing is enabled (`DOCUMENT_ROUTING.enabled=true` in `config.js`), the server triggers configured post-signing actions (filesystem save, webhook delivery). Webhooks receive both success (`document.signed`) and error (`document.signing_error`) events with retry logic.
  - Note: The previous client-side callback (`PDF_SIGNING_STATUS_CALLBACK`) is deprecated. Use the server-side `DOCUMENT_ROUTING` webhook strategy instead.

## 30.6 What is the final signed document format, and how does signature/stamp appear?

- Final output remains PDF.
- Visual signature is placed into PDF content via the visual-signature service flow.
- Optional digital stamp is applied via stamping service (`/api/stamp`) when enabled.
- Resulting PDF may include:
  - visible signature graphics/text in document content
  - digital signature/stamp metadata visible in PDF signature panel (viewer-dependent)

