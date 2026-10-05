# 13.3 How are repeated or parallel processing of the same document handled?

The same document in several sessions, a double tap on the tablet, or a
retried request:

- **Per-document lock.** The visual signature (`/api/visual-signature`)
  and the seal (`/api/stamp`) share a lock per document, so two operations
  on the same document do not run at the same time
  (`DOC_OPERATION_LOCK_TTL_MS`, shipped `45000`).
- **Idempotency.** Both accept an `X-Idempotency-Key` header. A repeated
  request with the same key within `IDEMPOTENCY_TTL_MS` (shipped `600000`,
  10 minutes) gets the first answer again, marked
  `X-Idempotency-Replay: true`, instead of signing twice.
- **Retries.** Both retry transient upstream errors up to 3 times, behind a
  circuit breaker.
- **Session clean-up.** A document's registration is removed by
  `/api/removeUser` (integration flow, API key) or `/api/cleanupUser`
  (portal flow, Keycloak token), which the portal calls after a successful
  signing. Registrations also expire: `USER_ENTRY_TTL_MS` (idle time) and
  `PAD_ARRIVAL_TIMEOUT_MS` (hard limit after the document reaches the pad),
  both 10 minutes in the shipped configuration.
- **A failed step keeps the session**, so the user can retry signing.

This state is held in ps-server's memory. A restart clears current
registrations, locks and idempotency records.

Settings: [7.4 Server config.js](07-04-server-config-js.md).
