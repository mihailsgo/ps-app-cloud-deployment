# 30.3 How are repeated or parallel document-processing scenarios handled (same document in multiple sessions, repeated signing attempts)?

- Backend has duplicate/parallel protection controls:
  - `DOC_OPERATION_LOCK_TTL_MS`
  - `IDEMPOTENCY_TTL_MS`
- Signing-related operations (`/api/visual-signature`, `/api/stamp`) use idempotency/lock behavior to reduce accidental duplicate processing.
- User-document registration state is in-memory and is cleaned by:
  - `/api/removeUser` (external integration flow, API key)
  - `/api/cleanupUser` (internal flow, Keycloak protected)
- Important behavior note: in-memory state is non-persistent; service restart clears current runtime registrations/locks.

