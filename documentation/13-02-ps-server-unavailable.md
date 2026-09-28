# 13.2 What happens if ps-server is unavailable when `registerPDF` is called?

- **ps-server is down or restarting:** nginx cannot reach it and answers
  with a gateway error (`502` or `504`). Nothing is registered; the caller
  should retry later. While ps-server is unhealthy, nginx itself may not be
  running after a restart of the stack, and the connection is refused
  ([9.9 Health checks and startup](09-09-health-checks-and-startup.md)).
- **ps-server runs but a dependency is unstable:** the upload returns a
  controlled error with an `errorCode`: `502` / `503` / `504` for classified
  archive failures, `429` when the queue is full, `503` for a queue timeout
  or an open circuit breaker ([13.1](13-01-many-documents-at-once.md)).
- **Registrations are kept in memory.** A ps-server restart clears
  documents that were registered but not yet signed; they have to be sent
  again. Documents already signed are in the archive.

For failures **after** registration, during signing, enable a webhook in
document routing: it receives a `document.signing_error` event with the
technical details of what failed, next to the `document.signed` event on
success ([11. Document routing and receive-back](11-document-routing-and-receive-back.md#webhook-strategy)).
The older client-side status callback (`PDF_SIGNING_STATUS_CALLBACK` in
`constants.json`) is deprecated: nothing reads it.

`monitor-status.sh --alert` alerts on a ps-server that is down or
unhealthy, and on repeated archive failures
([9.10 Monitoring and alerting](09-10-monitoring-and-alerting.md)).
