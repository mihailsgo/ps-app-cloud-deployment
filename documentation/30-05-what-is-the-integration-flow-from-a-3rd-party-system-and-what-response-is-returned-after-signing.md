# 30.5 What is the integration flow from a 3rd-party system, and what response is returned after signing?

- 3rd-party system sends documents to backend API-key-protected endpoints:
  - `/api/registerPDF` (multipart upload; primary production flow)
  - legacy-compatible endpoints `/api/registerUser` and `/api/registerUserPDF` may still exist for integration compatibility
- Success response for `/api/registerPDF` is `201` with JSON containing `docId`.
- Operator opens/signs document in portal.
- If document routing is enabled (`DOCUMENT_ROUTING.enabled=true` in `config.js`), the server triggers configured post-signing actions (filesystem save, webhook delivery). Webhooks receive both success (`document.signed`) and error (`document.signing_error`) events with retry logic.
  - Note: The previous client-side callback (`PDF_SIGNING_STATUS_CALLBACK`) is deprecated. Use the server-side `DOCUMENT_ROUTING` webhook strategy instead.

